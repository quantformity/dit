import DirectInvestTracker
import Foundation

/// dit — the command line for DirectInvestTracker.
///
/// Thin shell over the library: load the portfolio from the configured
/// backend, fetch the market data the portfolio needs, and render the
/// summary. All the substance (derivation, rendering, fetch planning)
/// lives in the library and is tested there.
@main
enum Main {

    private static let usage = """
    dit — direct investment tracker

    USAGE: dit [command] [options]

    COMMANDS:
      summary     Portfolio summary: totals, per-currency breakdown,
                  per-account values, holdings table (default)
      accounts    List accounts
      help        Show this message

    OPTIONS:
      --display <CCY>   Display currency, ISO code (default CAD)
      --backend <name>  file | sqlite (overrides DIT_BACKEND)
      --store <path>    Store path (overrides DIT_STORE_URL)
      --offline         Skip the market-data fetch: positions at cost
                        basis, no FX conversion

    STORE (environment variables; command-line options win):
      DIT_BACKEND     file (default) | sqlite
      DIT_STORE_URL   store path (default ~/Library/Application Support/DirectInvestTracker)
    """

    static func main() async {
        // --- Parse -----------------------------------------------------
        enum Command: String { case summary, accounts, help }
        var command: Command = .summary
        var display: Currency = .cad
        var offline = false
        var backend: String?
        var store: String?

        do {
            var index = 1
            let args = CommandLine.arguments
            while index < args.count {
                switch args[index] {
                case "-h", "--help":
                    command = .help
                case "--display":
                    index += 1
                    guard index < args.count else {
                        throw UsageError("--display needs a value (e.g. --display CAD)")
                    }
                    let raw = args[index].uppercased()
                    guard let currency = Currency(rawValue: raw), currency != .unknown else {
                        throw UsageError("unknown currency '\(args[index])'")
                    }
                    display = currency
                case "--offline":
                    offline = true
                case "--backend":
                    index += 1
                    guard index < args.count else {
                        throw UsageError("--backend needs a value (file | sqlite)")
                    }
                    let raw = args[index].lowercased()
                    guard ["file", "sqlite"].contains(raw) else {
                        throw UsageError("unknown backend '\(args[index])' (expected: file | sqlite)")
                    }
                    backend = raw
                case "--store":
                    index += 1
                    guard index < args.count, !args[index].isEmpty else {
                        throw UsageError("--store needs a path")
                    }
                    store = args[index]
                default:
                    if args[index].hasPrefix("-") {
                        throw UsageError("unknown option '\(args[index])'")
                    }
                    guard let parsed = Command(rawValue: args[index]) else {
                        throw UsageError("unknown command '\(args[index])'")
                    }
                    command = parsed
                }
                index += 1
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n\n\(usage)\n".utf8))
            exit(2)
        }

        if command == .help {
            print(usage)
            return
        }

        // --- Load the portfolio -----------------------------------------
        // Command-line options override the environment; the factory
        // stays the single place that interprets the configuration.
        var environment = ProcessInfo.processInfo.environment
        if let backend { environment[DataStoreFactory.backendKey] = backend }
        if let store { environment[DataStoreFactory.storeURLKey] = store }
        let factory = DataStoreFactory(environment: environment)
        do {
            let configuration = try factory.configuration()
            let store = try factory.make()
            let portfolio = try await PortfolioStore(store: store).load()

            guard let portfolio else {
                print("No portfolio found (store: \(configuration.backend.rawValue) at \(configuration.url.path)).")
                print("Add accounts and transactions first.")
                return
            }
            if portfolio.accounts.isEmpty {
                print("The portfolio has no accounts yet.")
                return
            }

            switch command {
            case .accounts:
                listAccounts(portfolio)
            case .summary:
                await showSummary(portfolio, display: display, offline: offline, storeURL: configuration.url)
            case .help:
                print(usage)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: Commands

    private static func listAccounts(_ portfolio: Portfolio) {
        let rows = portfolio.accounts.map { account in
            let name = account.name?.trimmingCharacters(in: .whitespaces)
            return [
                (name?.isEmpty == false ? name! : "Account \(account.id.uuidString.prefix(4))"),
                account.institution ?? "",
                account.reportingCurrency.rawValue,
                account.taxable ? "yes" : "no"
            ]
        }
        print("Accounts:")
        for line in Table.render(headers: ["Name", "Institution", "Ccy", "Taxable"], rows: rows) {
            print("  \(line)")
        }
    }

    private static func showSummary(
        _ portfolio: Portfolio,
        display: Currency,
        offline: Bool,
        storeURL: URL
    ) async {
        let cache = MarketDataCache()
        var notes: [String] = []
        var summary: PortfolioSummary

        if offline {
            notes.append("offline mode: positions at cost basis, no FX conversion")
            summary = portfolio.summary(displayCurrency: display)
        } else {
            let plan = portfolio.marketDataPlan(displayCurrency: display)
            let provider = YahooQuoteProvider()

            if plan.symbols.isEmpty {
                notes.append("no open positions — no quotes to fetch")
            } else {
                do {
                    try await provider.refresh(cache, symbols: plan.symbols)
                } catch {
                    notes.append("quote fetch failed: \(error) — positions at cost basis")
                }
            }
            for currency in plan.fxCurrencies {
                do {
                    try await provider.refresh(cache, from: plan.hub, to: currency)
                } catch {
                    notes.append("\(plan.hub.rawValue)-\(currency.rawValue) rate fetch failed: \(error)")
                }
            }
            notes.append(contentsOf: stalenessNotes(cache: cache, symbols: plan.symbols))
            summary = portfolio.summary(from: cache, displayCurrency: display, maxAge: 3 * 86_400)
        }

        print(SummaryRenderer.render(summary, notes: notes))
        print("")
        print("Store: \(storeURL.path)")
    }

    // MARK: Helpers

    /// The strict 60 s freshness rule would blank out every price the
    /// moment a market closes — but outside market hours the last
    /// close *is* the best known price. So the summary tolerates
    /// quotes up to three days old (weekends, holidays) and reports
    /// their age here instead of pretending the data is live.
    private static func stalenessNotes(cache: MarketDataCache, symbols: [String]) -> [String] {
        var newest: Date?
        for symbol in symbols {
            if let asOf = cache.quote(for: symbol)?.asOf {
                if newest == nil || asOf > newest! { newest = asOf }
            }
        }
        guard let newest, Date().timeIntervalSince(newest) > 60 else { return [] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateStyle = .medium
        f.timeStyle = .short
        return ["quote data as of \(f.string(from: newest)) — market may be closed, prices may be stale"]
    }

    private struct UsageError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}