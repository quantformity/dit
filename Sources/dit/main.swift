import DirectInvestTracker
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

/// dit — the command line for DirectInvestTracker.
///
/// A thin shell: parse arguments → load → mutate or derive → save →
/// render. Every rule with financial meaning (derivation, mutation
/// validation, rendering) lives in the library and is tested there.
///
/// Conventions:
/// - flags > env vars (`DIT_BACKEND`, `DIT_STORE_URL`) > defaults;
/// - dates are `YYYY-MM-DD`, amounts are plain decimals — invalid
///   input is a usage error (exit 2), never silently repaired;
/// - account references resolve by name (case-insensitive) or
///   UUID/unique prefix — ambiguity is reported, never guessed;
/// - destructive commands confirm (or require `--yes`);
/// - mutating commands make exactly one atomic save.
///
/// Exit codes: 0 success · 1 runtime error · 2 usage error.
@main
enum Main {

    // MARK: - Errors

    private struct ParseError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// The store exists but holds no portfolio — a runtime condition
    /// for write commands (exit 1), printed plainly for read commands.
    private struct NoPortfolio: LocalizedError {
        let path: String
        var errorDescription: String? { "no portfolio found at \(path)" }
    }

    // MARK: - Parsed invocation

    private struct Global {
        var display: Currency = .cad
        var backend: String?
        var store: String?
        var offline = false
    }

    private struct Invocation {
        var group = "summary"          // "summary", "accounts", "account", …
        var sub: String?               // "account add" → group "account", sub "add"
        var rest: [String] = []        // options/positionals for the command
        var help = false
    }

    // MARK: - Entry point

    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        var invocation = Invocation()
        var global = Global()
        do {
            let parsed = try parse(argv)
            invocation = parsed.invocation
            global = parsed.global
            if invocation.help {
                print(helpText(for: invocation))
                return
            }
            try await run(invocation, global: global)
        } catch let error as ParseError {
            printErr("error: \(error.message)")
            printErr(helpText(for: invocation))
            exit(2)
        } catch let error as LocalizedError {
            printErr("error: \(error.errorDescription ?? "\(error)")")
            exit(1)
        } catch {
            printErr("error: \(error)")
            exit(1)
        }
    }

    /// Splits argv into command words, global options, and the rest.
    ///
    /// Command words are the leading bare tokens: one for plain
    /// commands, two for groups (`account add`). Global options may
    /// appear anywhere and are consumed here; everything else is passed
    /// to the command's own option scanner. A non-dash token is a
    /// command word only while the command still accepts words, so
    /// `dit accounts TD` keeps `TD` as a positional and
    /// `dit --store PATH summary` still selects summary.
    private static func parse(_ argv: [String]) throws -> (invocation: Invocation, global: Global) {
        var invocation = Invocation()
        var global = Global()
        var words: [String] = []
        var rest: [String] = []
        let groups: Set<String> = ["account", "tx", "transaction", "ticker", "store", "quote", "help"]
        let globalValueOptions: Set<String> = ["display", "backend", "store"]

        var i = 0
        while i < argv.count {
            let token = argv[i]
            if token == "-h" || token == "--help" {
                invocation.help = true
                i += 1
                continue
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                var key = body
                var inline: String?
                if let eq = body.firstIndex(of: "=") {
                    key = String(body[..<eq])
                    inline = String(body[body.index(after: eq)...])
                }
                if globalValueOptions.contains(key) {
                    let value: String
                    if let inline {
                        value = inline
                        i += 1
                    } else {
                        guard i + 1 < argv.count else {
                            throw ParseError("missing value for --\(key)")
                        }
                        value = argv[i + 1]
                        i += 2
                    }
                    switch key {
                    case "display":
                        guard let currency = Currency(rawValue: value), currency != .unknown else {
                            throw ParseError(
                                "unknown display currency '\(value)' — use e.g. CAD, USD, JPY, or GBp")
                        }
                        global.display = currency
                    case "backend":
                        guard value == "file" || value == "sqlite" else {
                            throw ParseError("unknown backend '\(value)' — use 'file' or 'sqlite'")
                        }
                        global.backend = value
                    case "store":
                        global.store = value
                    default:
                        break
                    }
                    continue
                }
                if key == "offline" {
                    if inline != nil { throw ParseError("--offline is a flag and takes no value") }
                    global.offline = true
                    i += 1
                    continue
                }
            }
            if !token.hasPrefix("-") {
                if words.isEmpty {
                    words.append(token)
                    i += 1
                    continue
                }
                if words.count == 1, groups.contains(words[0]) {
                    words.append(token)
                    i += 1
                    continue
                }
            }
            rest.append(token)
            i += 1
        }

        invocation.group = words.first ?? "summary"
        if words.count > 1 { invocation.sub = words[1] }
        invocation.rest = rest
        return (invocation, global)
    }

    // MARK: - Dispatch

    private static func run(_ invocation: Invocation, global: Global) async throws {
        switch (invocation.group, invocation.sub) {
        case ("summary", _), ("", _):
            try await summary(global: global)
        case ("accounts", _):
            try await accountsList(global: global)
        case ("account", nil), ("account", "list"):
            try await accountsList(global: global)
        case ("account", "show"):
            try await accountShow(invocation.rest, global: global)
        case ("account", "add"):
            try await accountAdd(invocation.rest, global: global)
        case ("account", "edit"):
            try await accountEdit(invocation.rest, global: global)
        case ("account", "close"):
            try await accountClose(invocation.rest, global: global)
        case ("account", "delete"), ("account", "remove"):
            try await accountDelete(invocation.rest, global: global)
        case ("account", let sub?):
            throw ParseError("unknown account subcommand '\(sub)' — use list, show, add, edit, close, or delete")
        case ("tx", let sub?), ("transaction", let sub?):
            throw ParseError("'tx \(sub)' is planned for a later release")
        case ("tx", nil), ("transaction", nil):
            throw ParseError("tx commands are planned for a later release — see 'dit help tx'")
        case ("ticker", _):
            throw ParseError("ticker commands are planned for a later release")
        case ("store", _):
            throw ParseError("store commands are planned for a later release — "
                + "for now configure with --backend/--store (or DIT_BACKEND/DIT_STORE_URL)")
        case ("quote", _):
            throw ParseError("quote lookup is planned for a later release")
        case ("help", let topic):
            print(helpText(for: Invocation(group: topic ?? "usage", sub: nil, rest: [])))
        default:
            throw ParseError("unknown command '\(invocation.group)' — run 'dit help' for usage")
        }
    }

    // MARK: - summary / accounts (read-only)

    private static func summary(global: Global) async throws {
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            print("No portfolio found (store: \(configuration.backend.rawValue) at \(configuration.url.path)).")
            print("Add accounts and transactions first.")
            return
        }
        if portfolio.accounts.isEmpty {
            print("The portfolio has no accounts yet.")
            return
        }

        let cache = MarketDataCache()
        var notes: [String] = []
        var summary: PortfolioSummary

        if global.offline {
            notes.append("offline mode: positions at cost basis, no FX conversion")
            summary = portfolio.summary(displayCurrency: global.display)
        } else {
            let plan = portfolio.marketDataPlan(displayCurrency: global.display)
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
            summary = portfolio.summary(from: cache, displayCurrency: global.display, maxAge: 3 * 86_400)
        }

        print(SummaryRenderer.render(summary, notes: notes))
        print("")
        print("Store: \(configuration.url.path)")
    }

    private static func accountsList(global: Global) async throws {
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            print("No portfolio found (store: \(configuration.backend.rawValue) at \(configuration.url.path)).")
            print("Add accounts and transactions first.")
            return
        }
        if portfolio.accounts.isEmpty {
            print("The portfolio has no accounts yet.")
            return
        }
        print("Accounts:")
        let rows = portfolio.accounts.map { account in
            [
                account.displayName,
                account.institution ?? "",
                account.reportingCurrency.rawValue,
                account.taxable ? "yes" : "no",
                account.closedDate == nil ? "" : "closed \(shortDate(account.closedDate!))",
            ]
        }
        for line in Table.render(headers: ["Name", "Institution", "Ccy", "Taxable", "Status"], rows: rows) {
            print("  \(line)")
        }
    }

    // MARK: - account commands

    private static func accountShow(_ args: [String], global: Global) async throws {
        let options = try Options(args)
        guard let reference = options.positionals.first else {
            throw ParseError("usage: dit account show <account>")
        }
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            throw NoPortfolio(path: configuration.url.path)
        }
        let account = try AccountRef(reference).resolve(in: portfolio)
        let balances = AccountBalances.compute(
            account: account,
            transactions: portfolio.transactions(in: account.id)
        )

        print("Account:")
        let rows = [
            [account.displayName, account.institution ?? "", account.reportingCurrency.rawValue,
             account.taxable ? "yes" : "no"],
        ]
        for line in Table.render(headers: ["Name", "Institution", "Ccy", "Taxable"], rows: rows) {
            print("  \(line)")
        }
        print("  ID:        \(account.id.uuidString)")
        if let number = account.accountNumber { print("  Number:    \(number)") }
        print("  Opened:    \(account.openedDate.map(shortDate) ?? "—")")
        print("  Closed:    \(account.closedDate.map(shortDate) ?? "—")")
        if let notes = account.notes { print("  Notes:     \(notes)") }

        print("\nBalances (offline derivation: positions at cost basis, no FX applied):")
        let cash = balances.cashByCurrency.sorted { $0.key < $1.key }.map { money($0.value, $0.key) }
        print("  Cash:        \(cash.isEmpty ? "—" : cash.joined(separator: ", "))")
        let gics = balances.gicValueByCurrency.sorted { $0.key < $1.key }
            .map { "\(money($0.value, $0.key)) at par" }
        print("  GICs:        \(gics.isEmpty ? "—" : gics.joined(separator: ", "))")
        let dividends = balances.dividendsByCurrency.sorted { $0.key < $1.key }.map { money($0.value, $0.key) }
        print("  Dividends:   \(dividends.isEmpty ? "—" : dividends.joined(separator: ", "))")
        print("  Realized PL: \(money(balances.realizedPnL ?? 0, account.reportingCurrency))")
        if balances.positions.isEmpty {
            print("  Positions:   —")
        } else {
            print("  Positions:")
            for position in balances.positions {
                print("    \(position.symbol)  \(trim(position.shares)) @ \(trim(position.averageCostPerShare))"
                    + " = \(money(position.costBasis, position.currency)) cost basis")
            }
        }
    }

    private static func accountAdd(_ args: [String], global: Global) async throws {
        let options = try Options(
            args,
            valueOptions: ["currency", "name", "institution", "number", "opened", "closed", "notes"],
            flagOptions: ["taxable", "non-taxable"]
        )
        guard options.positionals.isEmpty else {
            throw ParseError("unexpected argument '\(options.positionals[0])' — account add takes no positionals")
        }
        let currencyRaw = try options.require("currency")
        guard let currency = Currency(rawValue: currencyRaw), currency != .unknown else {
            throw ParseError("unknown currency '\(currencyRaw)' — use e.g. CAD, USD, JPY, or GBp")
        }
        let taxable = try taxableFlag(options)
        let account = Account(
            reportingCurrency: currency,
            name: options["name"],
            institution: options["institution"],
            accountNumber: options["number"],
            taxable: taxable ?? true,
            openedDate: try options["opened"].map(parseDate),
            closedDate: try options["closed"].map(parseDate),
            notes: options["notes"]
        )
        let (store, portfolio) = try await requirePortfolio(global: global)
        let (updated, notes) = try portfolio.addingAccount(account)
        try await store.save(updated)
        for note in notes { print(note) }
        print("id: \(account.id.uuidString)")
    }

    private static func accountEdit(_ args: [String], global: Global) async throws {
        let options = try Options(
            args,
            valueOptions: ["name", "institution", "number", "currency", "opened", "closed", "notes"],
            flagOptions: ["taxable", "non-taxable"]
        )
        guard let reference = options.positionals.first else {
            throw ParseError("usage: dit account edit <account> [options]")
        }
        let (store, portfolio) = try await requirePortfolio(global: global)
        let account = try AccountRef(reference).resolve(in: portfolio)
        var currency: Currency?
        if let raw = options["currency"] {
            guard let parsed = Currency(rawValue: raw), parsed != .unknown else {
                throw ParseError("unknown currency '\(raw)' — use e.g. CAD, USD, JPY, or GBp")
            }
            currency = parsed
        }
        let (updated, notes) = try portfolio.updatingAccount(
            id: account.id,
            name: options["name"],
            institution: options["institution"],
            accountNumber: options["number"],
            currency: currency,
            taxable: try taxableFlag(options),
            opened: try options["opened"].map(parseDate),
            closed: try options["closed"].map(parseDate),
            notes: options["notes"]
        )
        try await store.save(updated)
        for note in notes { print(note) }
    }

    private static func accountClose(_ args: [String], global: Global) async throws {
        let options = try Options(args, valueOptions: ["date"])
        guard let reference = options.positionals.first else {
            throw ParseError("usage: dit account close <account> [--date YYYY-MM-DD]")
        }
        let (store, portfolio) = try await requirePortfolio(global: global)
        let account = try AccountRef(reference).resolve(in: portfolio)
        let date = try options["date"].map(parseDate) ?? Date()
        let (updated, notes) = try portfolio.closingAccount(id: account.id, on: date)
        try await store.save(updated)
        for note in notes { print(note) }
    }

    private static func accountDelete(_ args: [String], global: Global) async throws {
        let options = try Options(args, flagOptions: ["force", "yes"])
        guard let reference = options.positionals.first else {
            throw ParseError("usage: dit account delete <account> [--force] [--yes]")
        }
        let (store, portfolio) = try await requirePortfolio(global: global)
        let account = try AccountRef(reference).resolve(in: portfolio)
        let count = portfolio.transactions(in: account.id).count

        var impact = "This will remove account '\(account.displayName)'"
        if count > 0 {
            guard options.has("force") else {
                throw ParseError(
                    "account '\(account.displayName)' has \(count) transaction"
                        + "\(count == 1 ? "" : "s") and deleting the account removes them too — "
                        + "add --force if that is really what you want")
            }
            impact += " and its \(count) transaction\(count == 1 ? "" : "s")"
        }
        impact += "."
        guard confirm(impact, yes: options.has("yes")) else {
            print("cancelled")
            return
        }
        let (updated, notes) = try portfolio.removingAccount(id: account.id, force: options.has("force"))
        try await store.save(updated)
        for note in notes { print(note) }
    }

    // MARK: - Helpers

    /// The two-step storage read: the factory decides backend and
    /// location (flags merged over environment variables), then the
    /// middle layer loads the document.
    private static func openStore(global: Global) throws
        -> (PortfolioStore, DataStoreFactory.Configuration)
    {
        var environment = ProcessInfo.processInfo.environment
        if let backend = global.backend { environment[DataStoreFactory.backendKey] = backend }
        if let store = global.store { environment[DataStoreFactory.storeURLKey] = store }
        let factory = DataStoreFactory(environment: environment)
        let configuration = try factory.configuration()
        return (PortfolioStore(store: try factory.make()), configuration)
    }

    private static func requirePortfolio(global: Global) async throws
        -> (store: PortfolioStore, portfolio: Portfolio)
    {
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            throw NoPortfolio(path: configuration.url.path)
        }
        return (store, portfolio)
    }

    private static func taxableFlag(_ options: Options) throws -> Bool? {
        var answers: [Bool] = []
        if let taxable = options.flag("taxable") { answers.append(taxable) }
        if let nonTaxable = options.flag("non-taxable") { answers.append(!nonTaxable) }
        if Set(answers).count > 1 {
            throw ParseError("--taxable and --non-taxable contradict each other")
        }
        return answers.first
    }

    private static func parseDate(_ raw: String) throws -> Date {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day),
              let date = utcDate(year: year, month: month, day: day)
        else {
            throw ParseError("invalid date '\(raw)' — expected YYYY-MM-DD")
        }
        return date
    }

    private static func utcDate(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func money(_ amount: Decimal, _ currency: Currency) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let value = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
        return "\(currency.rawValue) \(value)"
    }

    private static func trim(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return ["quote data as of \(formatter.string(from: newest)) — market may be closed, prices may be stale"]
    }

    /// Destructive-operation gate: `--yes` passes; a terminal prompts
    /// for the literal word "yes"; a non-interactive run refuses.
    private static func confirm(_ message: String, yes: Bool) -> Bool {
        if yes { return true }
        guard isatty(fileno(stdin)) == 1 else {
            printErr(message)
            printErr("refusing to continue without --yes on a non-interactive terminal")
            exit(1)
        }
        print(message)
        print("Type 'yes' to confirm: ", terminator: "")
        guard let line = readLine() else { return false }
        return line.trimmingCharacters(in: .whitespaces).lowercased() == "yes"
    }

    private static func printErr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: - Options scanner

    /// Minimal `--key value` / `--key=value` / `--flag` scanner.
    /// Unknown options are errors — a typo'd flag must never silently
    /// change what gets written.
    private struct Options {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        /// Explicit `--flag=false` values; a flag set here overrides its
        /// presence (bare `--flag` means true).
        var flagValues: [String: Bool] = [:]
        var positionals: [String] = []

        init(_ args: [String],
             valueOptions: Set<String> = [],
             flagOptions: Set<String> = []) throws {
            var i = 0
            while i < args.count {
                let token = args[i]
                if token == "-h" || token == "--help" { i += 1; continue }
                if token.hasPrefix("--") {
                    let body = String(token.dropFirst(2))
                    var key = body
                    var inline: String?
                    if let eq = body.firstIndex(of: "=") {
                        key = String(body[..<eq])
                        inline = String(body[body.index(after: eq)...])
                    }
                    if valueOptions.contains(key) {
                        if let inline {
                            values[key] = inline
                        } else {
                            guard i + 1 < args.count else {
                                throw ParseError("missing value for --\(key)")
                            }
                            values[key] = args[i + 1]
                            i += 1
                        }
                    } else if flagOptions.contains(key) {
                        if let inline {
                            switch inline.lowercased() {
                            case "true", "yes": flagValues[key] = true
                            case "false", "no": flagValues[key] = false
                            default:
                                throw ParseError("--\(key) is a flag — pass it, omit it, "
                                    + "or write --\(key)=true / --\(key)=false")
                            }
                        } else {
                            flags.insert(key)
                        }
                    } else {
                        throw ParseError("unknown option '\(token)'")
                    }
                } else if token.hasPrefix("-") && token.count > 1 {
                    throw ParseError("unknown option '\(token)'")
                } else {
                    positionals.append(token)
                }
                i += 1
            }
        }

        subscript(_ key: String) -> String? { values[key] }
        func has(_ key: String) -> Bool { flags.contains(key) }
        /// nil = not passed; true/false = passed (bare or `=true/false`).
        func flag(_ key: String) -> Bool? {
            if let explicit = flagValues[key] { return explicit }
            return flags.contains(key) ? true : nil
        }
        func require(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else {
                throw ParseError("missing required option --\(key)")
            }
            return value
        }
    }

    // MARK: - Help

    private static func helpText(for invocation: Invocation) -> String {
        switch (invocation.group, invocation.sub) {
        case ("", _), ("summary", _):
            return """
            USAGE: dit [summary] [--display CCY] [--offline] [--backend file|sqlite] [--store PATH]

              Portfolio summary: totals, per-currency rows, per-account
              values, holdings. Costs the network unless --offline.
              --display must be a supported currency code (e.g. CAD, USD, GBp).
            """
        case ("accounts", _), ("account", nil), ("account", "list"):
            return """
            USAGE:
              dit accounts | dit account list                 list accounts
              dit account show <account>                      details + balances
              dit account add --currency CCY [options]        create an account
              dit account edit <account> [options]            change values
              dit account close <account> [--date D]          mark closed
              dit account delete <account> [--force] [--yes]

              <account> is a name (case-insensitive) or UUID/unique prefix.
              Add/edit options: --name, --institution, --number, --currency,
              --taxable, --non-taxable, --opened, --closed, --notes.
            """
        case ("account", "show"):
            return """
            USAGE: dit account show <account>

              Account details plus balances derived from its transactions,
              computed offline: positions show at cost basis and foreign
              amounts stay unconverted (no FX is applied).
            """
        case ("account", "add"):
            return """
            USAGE: dit account add --currency CCY [--name NAME] [--institution NAME]
                     [--number MASKED] [--taxable|--non-taxable]
                     [--opened YYYY-MM-DD] [--closed YYYY-MM-DD] [--notes TEXT]

              --currency is required (it defines how the account reports its
              totals). Accounts are taxable unless --non-taxable is given.
              --closed is accepted for importing already-closed accounts.
            """
        case ("account", "edit"):
            return """
            USAGE: dit account edit <account> [--name NAME] [--institution NAME]
                     [--number MASKED] [--currency CCY] [--taxable|--non-taxable]
                     [--opened YYYY-MM-DD] [--closed YYYY-MM-DD] [--notes TEXT]

              Only the supplied options change; history is never rewritten.
            """
        case ("account", "close"):
            return """
            USAGE: dit account close <account> [--date YYYY-MM-DD]

              Marks the account closed (default: today). Its history remains
              visible; closed accounts are excluded from current totals.
            """
        case ("account", "delete"):
            return """
            USAGE: dit account delete <account> [--force] [--yes]

              Removes the account. If it has transactions, --force is
              required (they are deleted too — the ledger is the source of
              truth). Without --yes an interactive confirmation is demanded;
              non-interactive runs must pass --yes.
            """
        case ("tx", _), ("transaction", _):
            return """
            tx commands (list, show, deposit, withdraw, buy, sell, dividend,
            gic, gic-redeem, fx, edit, delete) are planned for a later release.
            """
        case ("ticker", _):
            return "ticker commands are planned for a later release."
        case ("store", _):
            return """
            store commands (path, export, import) are planned for a later
            release. For now, configuration: --backend file|sqlite and
            --store PATH (or DIT_BACKEND / DIT_STORE_URL).
            """
        case ("quote", _):
            return "quote lookup is planned for a later release."
        default:
            return """
            USAGE: dit [command] [options]

              dit                        portfolio summary (default)
              dit summary [options]      portfolio summary
              dit accounts               list accounts
              dit account <sub> [args]   manage accounts (see: dit account --help)
              dit help [command]         help

              Global options: --display CCY, --offline, --backend file|sqlite,
              --store PATH, -h/--help. Flags override environment variables.
              Exit codes: 0 success, 1 runtime error, 2 usage error.
            """
        }
    }
}