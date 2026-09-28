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

    /// A failed live price lookup (exit 1). Recording `--price` by
    /// hand is always the escape hatch — a fetched price is a
    /// convenience, never the only path.
    private struct LookupError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// A filesystem-level failure (export/backup/import IO) — a runtime
    /// error (exit 1), distinct from a usage error (exit 2).
    private struct StoreError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
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
        // After an option only stage 2 understands (e.g. --kind), bare
        // tokens are option values or positionals — never a subcommand.
        // Stage 1-consumed options (--display/--store/--offline…) keep
        // the command-word stream open: 'dit account --display USD show TD'.
        var opaqueOptionSeen = false
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
                        global.display = try Self.parseCurrency(value, option: "--display")
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
                if words.count == 1, groups.contains(words[0]), !opaqueOptionSeen {
                    words.append(token)
                    i += 1
                    continue
                }
            }
            if token.hasPrefix("--") && !token.hasPrefix("---") {
                opaqueOptionSeen = true
            }
            rest.append(token)
            i += 1
        }

        invocation.group = words.first ?? ""
        if words.first != nil && words.count > 1 { invocation.sub = words[1] }
        invocation.rest = rest
        return (invocation, global)
    }

    // MARK: - Dispatch

    private static func run(_ invocation: Invocation, global: Global) async throws {
        switch (invocation.group, invocation.sub) {
        case ("", _), ("summary", _):
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
            try await txCommand(sub, invocation.rest, global: global)
        case ("tx", nil), ("transaction", nil):
            try await txCommand("list", invocation.rest, global: global)
        case ("ticker", nil), ("ticker", "list"), ("ticker", "ls"):
            try await tickerList(global: global)
        case ("ticker", "show"):
            try await tickerShow(invocation.rest, global: global)
        case ("ticker", "add"):
            try await tickerAdd(invocation.rest, global: global)
        case ("ticker", "edit"):
            try await tickerEdit(invocation.rest, global: global)
        case ("ticker", "delete"), ("ticker", "remove"):
            try await tickerDelete(invocation.rest, global: global)
        case ("ticker", let sub?):
            throw ParseError("unknown ticker subcommand '\(sub)' — use list, show, add, edit, or delete")
        case ("store", nil), ("store", "path"):
            try await storePath(global: global)
        case ("store", "export"):
            try await storeExport(invocation.rest, global: global)
        case ("store", "backup"):
            try await storeBackup(invocation.rest, global: global)
        case ("store", "import"):
            try await storeImport(invocation.rest, global: global)
        case ("store", let sub?):
            throw ParseError("unknown store subcommand '\(sub)' — use path, export, backup, or import")
        case ("quote", let symbol?):
            try await quoteLookup(symbol, invocation.rest, global: global)
        case ("quote", _):
            throw ParseError("usage: dit quote <SYMBOL> [SYMBOL ...] — see 'dit help quote'")
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
        notes.append(contentsOf: untrackedShortNotes(summary))

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
        let account = try resolveAccount(reference, in: portfolio)
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
        let currency = try parseCurrency(try options.require("currency"), option: "--currency")
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
        let (store, portfolio) = try await portfolioForMutation(global: global)
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
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let account = try resolveAccount(reference, in: portfolio)
        var currency: Currency?
        if let raw = options["currency"] {
            currency = try parseCurrency(raw, option: "--currency")
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
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let account = try resolveAccount(reference, in: portfolio)
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
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let account = try resolveAccount(reference, in: portfolio)
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

    // MARK: - ticker commands

    private static func tickerList(global: Global) async throws {
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            print("No portfolio found (store: \(configuration.backend.rawValue) at \(configuration.url.path)).")
            return
        }
        guard !portfolio.tickers.isEmpty else {
            print("The ticker registry is empty — 'dit ticker add SYM' registers an instrument.")
            return
        }
        print("Registry:")
        let rows = portfolio.tickers.sorted { $0.symbol < $1.symbol }.map { entry in
            [
                entry.symbol,
                entry.name ?? "—",
                entry.currency == .unknown ? "—" : entry.currency.rawValue,
                entry.tags.isEmpty ? "" : entry.tags.sorted().map(\.displayValue).joined(separator: ", "),
                "\(portfolio.transactions(for: entry.symbol).count)",
            ]
        }
        for line in Table.render(headers: ["Symbol", "Name", "Ccy", "Tags", "Txns"], rows: rows) {
            print("  \(line)")
        }
    }

    private static func tickerShow(_ args: [String], global: Global) async throws {
        let options = try Options(args)
        guard let symbolRaw = options.positionals.first else {
            throw ParseError("usage: dit ticker show <symbol>")
        }
        let symbol = try requireSymbol(symbolRaw)
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            throw NoPortfolio(path: configuration.url.path)
        }
        guard let entry = portfolio[ticker: symbol] else {
            throw LookupError("no registry entry for '\(symbol)' — 'dit ticker add \(symbol)' creates one")
        }
        print("Ticker: \(entry.symbol)")
        print("  Name:      \(entry.name ?? "—")")
        print("  Currency:  \(entry.currency == .unknown ? "unknown" : entry.currency.rawValue)")
        print("  Tags:      \(entry.tags.isEmpty ? "—" : entry.tags.sorted().map(\.displayValue).joined(separator: ", "))")
        print("  Notes:     \(entry.notes ?? "—")")
        print("  Referenced by \(portfolio.transactions(for: entry.symbol).count) transaction(s)")
    }

    private static func tickerAdd(_ args: [String], global: Global) async throws {
        let options = try Options(
            args, valueOptions: ["name", "currency", "tags", "notes"])
        guard options.positionals.count == 1 else {
            throw ParseError("usage: dit ticker add <symbol> [--name NAME] [--currency CCY] "
                + "[--tags a,b] [--notes TEXT]")
        }
        var currency: Currency
        if let raw = options["currency"] {
            currency = try parseCurrency(raw, option: "--currency")
        } else {
            currency = .unknown
        }
        let entry = EquityTicker(
            symbol: try requireSymbol(options.positionals[0]),
            name: options["name"],
            currency: currency,
            tags: parseTags(options["tags"]),
            notes: options["notes"])
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let (updated, notes) = try portfolio.addingTicker(entry)
        try await store.save(updated)
        for note in notes { print(note) }
    }

    private static func tickerEdit(_ args: [String], global: Global) async throws {
        let options = try Options(
            args, valueOptions: ["name", "currency", "tags", "notes"])
        guard let symbolRaw = options.positionals.first else {
            throw ParseError("usage: dit ticker edit <symbol> [--name NAME] [--currency CCY] "
                + "[--tags a,b] [--notes TEXT]")
        }
        guard let _ = options["name"] ?? options["currency"] ?? options["tags"] ?? options["notes"] else {
            throw ParseError("nothing to edit — pass --name, --currency, --tags, or --notes")
        }
        var currency: Currency?
        if let raw = options["currency"] {
            currency = try parseCurrency(raw, option: "--currency")
        }
        let tags: Set<Tag>?
        if options["tags"] != nil {
            tags = parseTags(options["tags"])
        } else {
            tags = nil
        }
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let (updated, notes) = try portfolio.updatingTicker(
            symbol: try requireSymbol(symbolRaw),
            name: options["name"],
            currency: currency,
            tags: tags,
            notes: options["notes"])
        try await store.save(updated)
        for note in notes { print(note) }
    }

    private static func tickerDelete(_ args: [String], global: Global) async throws {
        let options = try Options(args, flagOptions: ["yes"])
        guard let symbolRaw = options.positionals.first else {
            throw ParseError("usage: dit ticker delete <symbol> [--yes]")
        }
        let symbol = try requireSymbol(symbolRaw)
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            throw NoPortfolio(path: configuration.url.path)
        }
        guard portfolio[ticker: symbol] != nil else {
            throw LookupError("no registry entry for '\(symbol)' — nothing to remove")
        }
        let referencing = portfolio.transactions(for: symbol).count
        if referencing > 0 {
            let impact = "This will remove the registry entry '\(symbol)'. "
                + "\(referencing) transaction\(referencing == 1 ? "" : "s") reference it; "
                + "they are unaffected (the registry is display metadata only)."
            guard confirm(impact, yes: options.has("yes")) else {
                print("cancelled")
                return
            }
        }
        let (updated, notes) = try portfolio.removingTicker(symbol: symbol)
        try await store.save(updated)
        for note in notes { print(note) }
    }

    /// Comma-separated tag list ("dividend, core") → normalized tags.
    private static func parseTags(_ raw: String?) -> Set<Tag> {
        guard let raw else { return [] }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Tag($0) })
    }

    // MARK: - store commands

    private static func fileStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func storePath(global: Global) async throws {
        let (store, configuration) = try openStore(global: global)
        var body = [
            "Backend:  \(configuration.backend.rawValue) (flags > \(DataStoreFactory.backendKey) > default)",
            "Location: \(configuration.url.path)",
        ]
        let portfolio = try await store.load()
        if let portfolio {
            body.append("Document: present — \(portfolio.accounts.count) account(s), \(portfolio.transactions.count) transaction(s), \(portfolio.tickers.count) ticker(s) registered")
        } else {
            body.append("Document: empty (no portfolio recorded yet)")
        }
        if let keys = try? await store.keys(), !keys.isEmpty {
            body.append("Keys: \(keys.joined(separator: ", "))")
        }
        print("Store configuration:")
        for line in body {
            print("  \(line)")
        }
    }

    private static func storeExport(_ args: [String], global: Global) async throws {
        let options = try Options(args, valueOptions: ["to", "account"])
        guard options.positionals.isEmpty else {
            throw ParseError("unexpected argument '\(options.positionals[0])' — use: dit store export [--to FILE] [--account NAME]")
        }
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            throw NoPortfolio(path: configuration.url.path)
        }
        var scoped = portfolio
        var scopeNote = "the full portfolio"
        if let ref = options["account"] {
            let account = try resolveAccount(ref, in: portfolio)
            let transactions = portfolio.transactions(in: account.id)
            let symbols = Set(transactions.compactMap(\.ticker).map { $0.uppercased() })
            scoped = Portfolio(
                accounts: [account],
                transactions: transactions,
                tickers: portfolio.tickers.filter { symbols.contains($0.symbol) }
            )
            scopeNote = "account '\(account.displayName)'"
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(scoped)
        } catch {
            throw StoreError("could not encode the export: \(error.localizedDescription)")
        }
        let baseDir: URL
        if configuration.backend == .file {
            baseDir = configuration.url
        } else {
            baseDir = configuration.url.deletingLastPathComponent()
        }
        let target: URL
        if let raw = options["to"] {
            target = URL(fileURLWithPath: raw, isDirectory: false)
        } else {
            target = baseDir.appendingPathComponent("dit-portfolio-\(fileStamp()).json")
        }
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw StoreError("could not write '\(target.path)': \(error.localizedDescription)")
        }
        print("Exported \(scopeNote): \(scoped.accounts.count) account(s), \(scoped.transactions.count) transaction(s), \(scoped.tickers.count) ticker(s) registered")
        print("  → \(target.path)")
        if scoped.accounts.count != 1 {
            print("  note: this is a multi-account export — 'dit store import' needs one account per file; re-run with --account <name>")
        }
    }

    /// Shared by `store backup` (explicit) and `store import` (automatic
    /// pre-import). Returns the copies made.
    private static func backupStore(global: Global, to directory: URL? = nil) throws -> [URL] {
        let (_, configuration) = try openStore(global: global)
        let fm = FileManager.default
        let stamp = fileStamp()
        var copies = [URL]()
        switch configuration.backend {
        case .file:
            let source = configuration.url
            let contents = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
            guard !contents.isEmpty else {
                throw StoreError("the file store at '\(source.path)' is missing or empty — nothing to back up")
            }
            let destDir = directory ?? source.deletingLastPathComponent()
            let destination = destDir.appendingPathComponent(source.lastPathComponent + ".bak-\(stamp)")
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination) // stale same-second target would merge
            }
            try fm.copyItem(at: source, to: destination)
            copies.append(destination)

        case .sqlite:
            var dbPath = configuration.url
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dbPath.path, isDirectory: &isDirectory), isDirectory.boolValue {
                dbPath.appendPathComponent("portfolio.sqlite")
            }
            guard fm.fileExists(atPath: dbPath.path) else {
                throw StoreError("the sqlite database at '\(dbPath.path)' does not exist yet — nothing to back up")
            }
            let destDir = directory ?? dbPath.deletingLastPathComponent()
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            for suffix in ["", ".wal", ".shm"] {
                let source = URL(fileURLWithPath: dbPath.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                let destination = destDir.appendingPathComponent(dbPath.lastPathComponent + ".bak-\(stamp)\(suffix)")
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: source, to: destination)
                copies.append(destination)
            }
        }
        return copies
    }

    private static func storeBackup(_ args: [String], global: Global) async throws {
        let options = try Options(args, valueOptions: ["to"])
        guard options.positionals.isEmpty else {
            throw ParseError("unexpected argument '\(options.positionals[0])' — use: dit store backup [--to DIR]")
        }
        let directory = options["to"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let copies = try backupStore(global: global, to: directory)
        print("Backed up the store:")
        for url in copies {
            print("  → \(url.path)")
        }
    }

    private static func storeImport(_ args: [String], global: Global) async throws {
        let options = try Options(args, flagOptions: ["merge", "force", "yes"])
        guard let raw = options.positionals.first else {
            throw ParseError("usage: dit store import FILE [--merge] [--force] [--yes]")
        }
        guard options.positionals.count == 1 else {
            throw ParseError("unexpected argument '\(options.positionals[1])' — use: dit store import FILE [--merge] [--force] [--yes]")
        }
        let file = URL(fileURLWithPath: raw, isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ParseError("cannot read '\(raw)': \(error.localizedDescription)")
        }
        let incoming: Portfolio
        do {
            incoming = try JSONDecoder().decode(Portfolio.self, from: data)
        } catch {
            throw ParseError("'\(raw)' is not a dit portfolio export (decode failed: \(error.localizedDescription))")
        }

        // Validate first — a malformed file must neither take a backup
        // nor touch the store.
        let (store, configuration) = try openStore(global: global)
        let current = try await store.load() ?? Portfolio()
        let mode: Portfolio.ImportMode = options.has("merge") ? .merge : .replace
        let imported = try current.importing(incoming, mode: mode)
        let account = incoming.accounts[0]

        if mode == .replace {
            // Replace is destructive for that account's ledger — gate it
            // like every other destructive operation, then back up so a
            // bad import is one --store flag away.
            guard confirm(
                "Replace the record and ledger of '\(account.displayName)' with \(incoming.transactions.count) imported transaction(s)?",
                yes: options.has("yes"))
            else {
                throw LookupError("aborted — the store is unchanged")
            }
            if !options.has("force") {
                do {
                    let copies = try backupStore(global: global)
                    print("Store backed up before import:")
                    for url in copies { print("  → \(url.path)") }
                } catch {
                    printErr("warning: automatic pre-import backup failed: \(error) — continuing without a backup")
                }
            }
        }
        do {
            try await store.save(imported.portfolio)
        } catch {
            throw StoreError("could not save the portfolio: \(error.localizedDescription)")
        }
        for note in imported.notes { print(note) }
        print("Store: \(configuration.url.path)")
    }

    // MARK: - quote

    private static func quoteLookup(_ first: String, _ rest: [String], global: Global) async throws {
        guard !global.offline else {
            throw ParseError("'dit quote' needs the network for live prices — drop --offline (offline mode exists to *avoid* fetching)")
        }
        let options = try Options(rest)
        let positionals = [first] + options.positionals
        let symbols = try positionals.map { try requireSymbol($0) }
        guard !symbols.isEmpty else {
            throw ParseError("usage: dit quote <SYMBOL> [SYMBOL ...]")
        }

        let provider = YahooQuoteProvider()
        let quotes: [MarketQuote]
        do {
            quotes = try await provider.quotes(for: symbols)
        } catch {
            throw LookupError("live quote fetch failed: \(error)")
        }
        let bySymbol = Dictionary(uniqueKeysWithValues: quotes.map { ($0.symbol, $0) })
        let rows = symbols.map { symbol -> [String] in
            guard let quote = bySymbol[symbol] else {
                return [symbol, "(none)", "", "", ""]
            }
            return [
                quote.symbol,
                trim(quote.price),
                quote.currency == .unknown ? "??" : quote.currency.rawValue,
                quote.asOf.map(Self.quoteStamp) ?? "unknown",
                quote.source ?? "?",
            ]
        }
        print("Live quotes:")
        for line in Table.render(headers: ["Symbol", "Price", "Ccy", "AsOf", "Source"], rows: rows) {
            print("  \(line)")
        }
        let missing = symbols.filter { bySymbol[$0] == nil }
        if !missing.isEmpty {
            print("no quote found: \(missing.joined(separator: ", "))")
        }
        guard !bySymbol.isEmpty else {
            throw LookupError("no live quotes available for: \(symbols.joined(separator: ", "))")
        }
    }

    // MARK: - Account reference resolution (with did-you-mean)

    /// Resolve an account reference, softening a misspelled name with a
    /// did-you-mean hint when the portfolio contains a close match.
    private static func resolveAccount(_ raw: String, in portfolio: Portfolio) throws -> Account {
        do {
            return try AccountRef(raw).resolve(in: portfolio)
        } catch let error as AccountRef.ResolutionError {
            switch error {
            case .empty:
                throw ParseError("an account name or UUID is required")
            case .notFound(let query):
                let candidates = portfolio.accounts.map(\.displayName)
                if let hint = Self.didYouMean(query, among: candidates) {
                    throw LookupError("no account matches '\(query)' — \(hint) — use the exact name (see 'dit accounts') or a UUID prefix")
                }
                throw LookupError("no account matches '\(query)' — use the exact name (see 'dit accounts') "
                    + "or a UUID prefix; if this portfolio should have one, start with 'dit account add'")
            case .ambiguous(let query, let matches):
                throw LookupError("'\(query)' is ambiguous — it matches: \(matches.joined(separator: ", ")). "
                    + "Use a longer name or the full UUID.")
            }
        }
    }

    /// Cheap fuzzy match (equality, substring, two-letter prefix) —
    /// enough for short account names, no dependencies. Returns nil when
    /// nothing is plausibly close, instead of a useless guess.
    private static func didYouMean(_ query: String, among candidates: [String]) -> String? {
        let lowercasedQuery = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard lowercasedQuery.count >= 2 else { return nil }
        var best: String? = nil
        var bestScore = 0
        for candidate in candidates {
            let lowered = candidate.lowercased()
            var score = 0
            if lowered == lowercasedQuery {
                return candidate
            }
            if lowered.contains(lowercasedQuery) || lowercasedQuery.contains(lowered) {
                score = (candidate.count <= 16) ? 3 : 2
            } else if lowered.hasPrefix(String(lowercasedQuery.prefix(2))) {
                score = 1
            }
            if score > bestScore {
                best = candidate
                bestScore = score
            }
        }
        guard bestScore > 0, let hit = best else { return nil }
        return "did you mean '\(hit)'?"
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

    /// Mutations tolerate an empty store: a brand-new user must be able
    /// to `account add` / `tx deposit` against nothing at all. Reads keep
    /// the friendly "no portfolio yet" message instead.
    private static func portfolioForMutation(global: Global) async throws
        -> (store: PortfolioStore, portfolio: Portfolio)
    {
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            _ = configuration
            return (store, Portfolio())
        }
        return (store, portfolio)
    }

    // MARK: - tx commands

    private static func txCommand(_ sub: String, _ args: [String], global: Global) async throws {
        // 'dit tx 9F2C6D1A' shows that transaction: a run of 8+ hex
        // characters is a reference, never a subcommand word.
        if sub.count >= 8, sub.allSatisfy(\.isHexDigit) {
            try await txShow([sub], global: global)
            return
        }
        switch sub {
        case "list", "ls":
            try await txList(args, global: global)
        case "show":
            try await txShow(args, global: global)
        case "deposit":
            try await txCashEntry(deposit: true, args, global: global)
        case "withdraw", "withdrawal":
            try await txCashEntry(deposit: false, args, global: global)
        case "buy":
            try await txTrade(buy: true, args, global: global)
        case "sell":
            try await txTrade(buy: false, args, global: global)
        case "dividend":
            try await txDividend(args, global: global)
        case "gic":
            try await txGicPurchase(args, global: global)
        case "gic-redeem", "redeem":
            try await txGicRedeem(args, global: global)
        case "fx":
            try await txFx(args, global: global)
        case "edit":
            try await txEdit(args, global: global)
        case "delete", "remove":
            try await txDelete(args, global: global)
        default:
            throw ParseError("unknown tx subcommand '\(sub)' — see 'dit help tx'")
        }
    }

    private static func txList(_ args: [String], global: Global) async throws {
        let options = try Options(
            args,
            valueOptions: ["account", "kind", "ticker", "since", "until", "limit"])
        guard options.positionals.isEmpty else {
            throw ParseError("unexpected argument '\(options.positionals[0])' — "
                + "filter with --account/--kind/--ticker (or 'dit tx show <id>')")
        }
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            print("No portfolio found (store: \(configuration.backend.rawValue) at \(configuration.url.path)).")
            return
        }
        var txs = portfolio.transactions
        var scope = "all accounts"
        if let accountRef = options["account"] {
            let account = try resolveAccount(accountRef, in: portfolio)
            txs = portfolio.transactions(in: account.id)
            scope = "'\(account.displayName)'"
        }
        if let kind = options["kind"] {
            guard let target = Self.kindAliases[normalizeToken(kind)] else {
                throw ParseError("unknown kind '\(kind)' — one of: deposit, withdrawal, buy, sell, "
                    + "dividend, gic, gic-redeem, fx (or the canonical names)")
            }
            txs = txs.filter { $0.kind.kindName == target }
        }
        if let ticker = options["ticker"] {
            let symbol = ticker.trimmingCharacters(in: .whitespaces).uppercased()
            txs = txs.filter { $0.ticker == symbol }
        }
        if let since = options["since"] {
            let start = try parseDate(since)
            txs = txs.filter { $0.date >= start }
        }
        if let until = options["until"] {
            let end = try parseDate(until).addingTimeInterval(86_399) // inclusive through that day
            txs = txs.filter { $0.date <= end }
        }

        // Deterministic order: date, then storage order for equal dates.
        var indexed = txs.enumerated().sorted { lhs, rhs in
            if lhs.element.date != rhs.element.date { return lhs.element.date < rhs.element.date }
            return lhs.offset < rhs.offset
        }
        if let raw = options["limit"] {
            guard let n = Int(raw), n > 0 else {
                throw ParseError("--limit needs a positive number (got '\(raw)')")
            }
            indexed = Array(indexed.suffix(n)) // keep the most recent
        }

        print("Transactions — \(scope) (\(indexed.count) shown)")
        guard !indexed.isEmpty else { return }
        let rows = indexed.map { entry -> [String] in
            let tx = entry.element
            let accountName = portfolio.accounts.first { $0.id == tx.accountID }?.displayName ?? "—"
            return [String(tx.id.uuidString.prefix(8)), shortDate(tx.date), accountName,
                    tx.kind.kindName, tx.summaryLine]
        }
        for line in Table.render(headers: ["ID", "Date", "Account", "Kind", "Detail"],
                                 rows: rows, leftColumns: [0, 1, 2, 3, 4]) {
            print("  \(line)")
        }
    }

    private static func txShow(_ args: [String], global: Global) async throws {
        let options = try Options(args)
        guard let reference = options.positionals.first else {
            throw ParseError("usage: dit tx show <id>")
        }
        let (store, configuration) = try openStore(global: global)
        guard let portfolio = try await store.load() else {
            throw NoPortfolio(path: configuration.url.path)
        }
        let tx = try TransactionRef(reference).resolve(in: portfolio)
        let accountName = portfolio.accounts.first { $0.id == tx.accountID }?.displayName ?? "—"
        print("Transaction:")
        print("  ID:        \(tx.id.uuidString)")
        print("  Date:      \(shortDate(tx.date))")
        print("  Account:   \(accountName)")
        print("  Currency:  \(tx.currency.rawValue)")
        print("  Details:   \(tx.summaryLine)")
        if case .gicPurchase(let gic) = tx.kind {
            print("  Terms:     compounds \(gic.compounding.rawValue), "
                + "early redemption \(gic.redeemable ? "allowed" : "not permitted")")
        }
        print("  Fee:       \(tx.fee.map { money($0, tx.currency) } ?? "—")")
    }

    private static func txCashEntry(deposit: Bool, _ args: [String], global: Global) async throws {
        let options = try Options(
            args,
            valueOptions: ["account", "amount", "currency", "date", "fee"])
        guard options.positionals.isEmpty else {
            throw ParseError("unexpected argument '\(options.positionals[0])' — "
                + "the account goes in --account")
        }
        let reference = try options.require("account")
        let amountRaw = try options.require("amount")
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let account = try resolveAccount(reference, in: portfolio)
        let amount = try parseDecimal(amountRaw, option: "--amount")

        var currency = account.reportingCurrency
        if let raw = options["currency"] {
            currency = try parseCurrency(raw, option: "--currency")
        }
        var fee: Decimal?
        if let feeRaw = options["fee"] {
            let value = try parseDecimal(feeRaw, option: "--fee")
            fee = value == 0 ? nil : value
        }
        let kind: Transaction.Kind = deposit ? .deposit(amount: amount) : .withdrawal(amount: amount)
        let tx = Transaction(
            date: try options["date"].map(parseDate) ?? Date(),
            accountID: account.id,
            currency: currency,
            kind: kind,
            fee: fee)
        let (updated, notes) = try portfolio.addingTransaction(tx)
        try await store.save(updated)
        for note in notes { print(note) }
        if !deposit, notes.contains(where: { $0.hasPrefix("warning") }) {
            print("(recorded anyway — the ledger records what happened, not what should fit)")
        }
    }

    // MARK: Entry commands — buy, sell, dividend, gic, gic-redeem, fx

    private static func txTrade(buy: Bool, _ args: [String], global: Global) async throws {
        let options = try Options(
            args,
            valueOptions: ["account", "ticker", "shares", "price", "currency", "date", "fee"])
        try rejectPositionals(options, hint: "a trade takes only --options (see 'dit help tx')")
        let reference = try options.require("account")
        let symbolRaw = try options.require("ticker")
        let sharesRaw = try options.require("shares")
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let account = try resolveAccount(reference, in: portfolio)
        let symbol = try requireSymbol(symbolRaw)
        if portfolio[ticker: symbol] == nil, let hint = didYouMean(symbol, among: portfolio.tickers.map(\.symbol)) {
            printErr("hint: '\(symbol)' is not registered — \(hint); register it with 'dit ticker add \(symbol)' (the trade is recorded either way)")
        }
        let shares = try parseDecimal(sharesRaw, option: "--shares")
        guard shares > 0 else { throw ParseError("--shares must be greater than 0") }

        // Price: given, or fetched live. No silent zero anywhere — a
        // trade without a trustworthy price is refused, not recorded
        // at 0 (which would fabricate a worthless position).
        var price: Decimal
        var priceNote: String
        var quoteCurrency: Currency?
        if let raw = options["price"] {
            let value = try parseDecimal(raw, option: "--price")
            guard value >= 0 else { throw ParseError("--price cannot be negative") }
            price = value
            priceNote = "\(trim(value)) recorded as entered"
        } else {
            guard !global.offline else {
                throw ParseError("--price was omitted and --offline is set — prices are only "
                    + "fetched online; pass --price to record this trade")
            }
            let cache = MarketDataCache()
            do {
                try await YahooQuoteProvider().refresh(cache, symbols: [symbol])
            } catch {
                throw LookupError("price lookup for '\(symbol)' failed: \(error) — "
                    + "pass --price to record a price yourself")
            }
            guard let quote = cache.quote(for: symbol), quote.price > 0 else {
                throw LookupError("no price found for '\(symbol)' — check the symbol "
                    + "(Yahoo format: SHOP.TO, AAPL) or pass --price")
            }
            price = quote.price
            if quote.currency != .unknown { quoteCurrency = quote.currency }
            priceNote = "\(trim(quote.price)) \(quote.currency.rawValue) via "
                + "\(quote.source ?? "yahoo") as of \(quoteStamp(quote.asOf))"
        }

        let defaultCurrency = quoteCurrency
            ?? portfolio.suggestedCurrency(accountID: account.id, symbol: symbol)
        let details = StockDetails(ticker: symbol, shares: shares, price: price)
        let tx = Transaction(
            date: try options["date"].map(parseDate) ?? Date(),
            accountID: account.id,
            currency: try entryCurrency(options, fallback: defaultCurrency),
            kind: buy ? .stockPurchase(details) : .stockSale(details),
            fee: try entryFee(options))

        // The twin of the withdrawal overdraft warning: selling more than
        // the account holds is recorded (it may well have happened), but
        // it is announced.
        var shortNote: String?
        if !buy {
            var held: Decimal = 0
            for other in portfolio.transactions where other.accountID == account.id {
                switch other.kind {
                case .stockPurchase(let d) where d.ticker == symbol: held += d.shares
                case .stockSale(let d) where d.ticker == symbol: held -= d.shares
                default: break
                }
            }
            if held - shares < 0 {
                shortNote = "warning: '\(account.displayName)' ends up SHORT "
                    + "\(trim(shares - held)) \(symbol) — double-check that this sale happened"
            }
        }

        let (updated, notes) = try portfolio.addingTransaction(tx)
        try await store.save(updated)
        print("price: \(priceNote)")
        for note in notes { print(note) }
        if let shortNote { print(shortNote) }
    }

    private static func txDividend(_ args: [String], global: Global) async throws {
        let options = try Options(
            args,
            valueOptions: ["account", "ticker", "amount", "currency", "date", "fee"])
        try rejectPositionals(options, hint: "a dividend takes only --options (see 'dit help tx')")
        let reference = try options.require("account")
        let symbolRaw = try options.require("ticker")
        let amountRaw = try options.require("amount")
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let account = try resolveAccount(reference, in: portfolio)
        let symbol = try requireSymbol(symbolRaw)
        if portfolio[ticker: symbol] == nil, let hint = didYouMean(symbol, among: portfolio.tickers.map(\.symbol)) {
            printErr("hint: '\(symbol)' is not registered — \(hint); register it with 'dit ticker add \(symbol)' (the entry is recorded either way)")
        }
        let amount = try parseDecimal(amountRaw, option: "--amount")
        guard amount > 0 else { throw ParseError("--amount must be greater than 0") }
        let tx = Transaction(
            date: try options["date"].map(parseDate) ?? Date(),
            accountID: account.id,
            currency: try entryCurrency(
                options,
                fallback: portfolio.suggestedCurrency(accountID: account.id, symbol: symbol)),
            kind: .dividend(DividendDetails(ticker: symbol, amount: amount)),
            fee: try entryFee(options))
        let (updated, notes) = try portfolio.addingTransaction(tx)
        try await store.save(updated)
        for note in notes { print(note) }
    }

    private static func txGicPurchase(_ args: [String], global: Global) async throws {
        let options = try Options(
            args,
            valueOptions: ["account", "product", "principal", "rate", "compounding",
                           "maturity", "currency"],
            flagOptions: ["redeemable"])
        try rejectPositionals(options, hint: "a GIC takes only --options (see 'dit help tx')")
        let reference = try options.require("account")
        let product = try options.require("product")
        let principalRaw = try options.require("principal")
        let rateRaw = try options.require("rate")
        let maturityRaw = try options.require("maturity")
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let account = try resolveAccount(reference, in: portfolio)
        let principal = try parseDecimal(principalRaw, option: "--principal")
        guard principal > 0 else { throw ParseError("--principal must be greater than 0") }
        var compounding = GICCompounding.annual
        if let raw = options["compounding"] {
            guard let parsed = GICCompounding.allCases
                .first(where: { normalizeToken($0.rawValue) == normalizeToken(raw) }) else {
                throw ParseError("unknown compounding '\(raw)' — one of: "
                    + GICCompounding.allCases.map(\.rawValue).joined(separator: ", "))
            }
            compounding = parsed
        }
        let redeemable = options.flag("redeemable") == true
        let tx = Transaction(
            date: try options["date"].map(parseDate) ?? Date(),
            accountID: account.id,
            currency: try entryCurrency(options, fallback: account.reportingCurrency),
            kind: .gicPurchase(GICDetails(
                product: product,
                principal: principal,
                rate: try parseRate(rateRaw),
                compounding: compounding,
                maturityDate: try parseDate(maturityRaw),
                redeemable: redeemable)))
        let (updated, notes) = try portfolio.addingTransaction(tx)
        try await store.save(updated)
        for note in notes { print(note) }
        print("recorded as compounding \(compounding.rawValue), early redemption "
            + (redeemable ? "allowed" : "not permitted")
            + " — correct with 'dit tx edit <id>' if that is wrong")
    }

    private static func txGicRedeem(_ args: [String], global: Global) async throws {
        let options = try Options(
            args,
            valueOptions: ["account", "gic", "proceeds", "currency", "date", "fee"])
        try rejectPositionals(options, hint: "name the GIC with --gic (see 'dit help tx')")
        let reference = try options.require("account")
        let gicRaw = try options.require("gic")
        let proceedsRaw = try options.require("proceeds")
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let account = try resolveAccount(reference, in: portfolio)
        // Redeeming names its GIC — product name or transaction id.
        // No match or an ambiguous one lists the account's live GICs;
        // a redemption is never attributed by guesswork.
        let purchase = try portfolio.findGICPurchase(accountID: account.id, reference: gicRaw)
        let proceeds = try parseDecimal(proceedsRaw, option: "--proceeds")
        guard proceeds > 0 else { throw ParseError("--proceeds must be greater than 0") }
        let tx = Transaction(
            date: try options["date"].map(parseDate) ?? Date(),
            accountID: account.id,
            // Proceeds arrive in whatever currency the GIC was taken in.
            currency: try entryCurrency(options, fallback: purchase.currency),
            kind: .gicRedemption(GICRedemptionDetails(purchaseID: purchase.id, proceeds: proceeds)),
            fee: try entryFee(options))
        let (updated, notes) = try portfolio.addingTransaction(tx)
        try await store.save(updated)
        for note in notes { print(note) }
        print("against '\(purchase.summaryLine)' "
            + "[\(String(purchase.id.uuidString.prefix(8)))]")
        if case .gicPurchase(let details) = purchase.kind, proceeds < details.principal {
            print("warning: a redemption ENDS the GIC here — the remaining "
                + "\(trim(details.principal - proceeds)) \(purchase.currency.rawValue) of principal is booked "
                + "as gone with this redemption (all-or-nothing model). If only part came back, "
                + "delete this redemption and record what actually happened instead")
        }
    }

    private static func txFx(_ args: [String], global: Global) async throws {
        let options = try Options(
            args,
            valueOptions: ["account", "from", "to", "from-amount", "to-amount", "date", "fee"])
        try rejectPositionals(options, hint: "a currency conversion takes only --options "
            + "(see 'dit help tx')")
        let reference = try options.require("account")
        let fromRaw = try options.require("from")
        let toRaw = try options.require("to")
        let fromAmountRaw = try options.require("from-amount")
        let toAmountRaw = try options.require("to-amount")
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let account = try resolveAccount(reference, in: portfolio)
        let from = try parseCurrency(fromRaw, option: "--from")
        let to = try parseCurrency(toRaw, option: "--to")
        guard from != to else {
            throw ParseError("--from and --to must differ — that is not a conversion")
        }
        let fromAmount = try parseDecimal(fromAmountRaw, option: "--from-amount")
        let toAmount = try parseDecimal(toAmountRaw, option: "--to-amount")
        guard fromAmount > 0, toAmount > 0 else {
            throw ParseError("--from-amount and --to-amount must both be greater than 0 — "
                + "both sides of a conversion are facts you know")
        }
        let tx = Transaction(
            date: try options["date"].map(parseDate) ?? Date(),
            accountID: account.id,
            currency: to,
            kind: .fxConversion(FXDetails(
                fromCurrency: from, fromAmount: fromAmount, toAmount: toAmount)),
            fee: try entryFee(options))
        let (updated, notes) = try portfolio.addingTransaction(tx)
        try await store.save(updated)
        for note in notes { print(note) }
    }

    // MARK: Entry helpers

    private static func rejectPositionals(_ options: Options, hint: String) throws {
        guard let first = options.positionals.first else { return }
        throw ParseError("unexpected argument '\(first)' — \(hint)")
    }

    private static func requireSymbol(_ raw: String) throws -> String {
        let symbol = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty else { throw ParseError("--ticker cannot be empty") }
        return symbol
    }

    /// The currency a new entry is recorded in: `--currency` (known
    /// code, case-insensitive) overrides the command's own default.
    private static func entryCurrency(_ options: Options, fallback: Currency) throws -> Currency {
        guard let raw = options["currency"] else { return fallback }
        return try parseCurrency(raw, option: "--currency")
    }

    private static func parseCurrency(_ raw: String, option: String) throws -> Currency {
        if let exact = Currency(rawValue: raw), exact != .unknown { return exact }
        if let match = Currency.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }),
           match != .unknown {
            return match
        }
        throw ParseError("unknown currency '\(raw)' for \(option) — use e.g. CAD, USD, JPY, or GBp")
    }

    /// Entry fee: zero means "no fee", negative is a usage error.
    private static func entryFee(_ options: Options) throws -> Decimal? {
        guard let raw = options["fee"] else { return nil }
        let value = try parseDecimal(raw, option: "--fee")
        guard value >= 0 else { throw ParseError("--fee cannot be negative") }
        return value == 0 ? nil : value
    }

    /// --rate is a percentage: "4.1" means 4.1 %.
    private static func parseRate(_ raw: String) throws -> Decimal {
        let cleaned = raw.hasSuffix("%") ? String(raw.dropLast()) : raw
        let percent = try parseDecimal(cleaned, option: "--rate")
        guard percent >= 0, percent <= 1000 else {
            throw ParseError("--rate must be a percentage between 0 and 1000 (got '\(raw)')")
        }
        return percent / 100
    }

    private static func quoteStamp(_ date: Date?) -> String {
        guard let date else { return "an unknown time" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Edit *values only*. Kind and account are not editable: those
    /// changes describe a different event, which must be a new record
    /// (delete + re-add), keeping the correction visible.
    private static func txEdit(_ args: [String], global: Global) async throws {
        let options = try Options(
            args,
            valueOptions: ["date", "fee", "amount", "shares", "price", "principal", "rate",
                           "maturity", "compounding", "product", "proceeds",
                           "from-amount", "to-amount"])
        guard let reference = options.positionals.first else {
            throw ParseError("usage: dit tx edit <id> [value options] — see 'dit help tx'")
        }
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let tx = try TransactionRef(reference).resolve(in: portfolio)

        var edits: [TransactionEdit] = []
        if let raw = options["date"] { edits.append(.date(try parseDate(raw))) }
        if let raw = options["fee"] {
            let value = try parseDecimal(raw, option: "--fee")
            edits.append(.fee(value == 0 ? nil : value))
        }
        if let kind = try editedKind(tx: tx, options: options) { edits.append(.kind(kind)) }
        guard !edits.isEmpty else {
            throw ParseError("nothing to edit — pass --date, --fee, or a value option "
                + "valid for kind '\(tx.kind.kindName)'")
        }
        let (updated, notes) = try portfolio.editingTransaction(id: tx.id, edits)
        try await store.save(updated)
        for note in notes { print(note) }
    }

    /// Translate value flags into a replacement payload for the *same*
    /// kind. Any option that does not belong to the kind is an error —
    /// no silent dropping, no cross-kind guesses.
    private static func editedKind(tx: Transaction, options: Options) throws -> Transaction.Kind? {
        func decimal(_ key: String) throws -> Decimal? {
            guard let raw = options[key] else { return nil }
            return try parseDecimal(raw, option: "--\(key)")
        }
        func used(_ keys: String...) -> Bool { keys.contains { options[$0] != nil } }
        func rejected(_ keys: [String]) -> ParseError {
            // Name only the options the user actually passed.
            let passed = keys.filter { options[$0] != nil }
            return ParseError("\(passed.map { "--\($0)" }.joined(separator: ", ")) does not apply to "
                + "'\(tx.kind.kindName)' — edits change values within the same kind only; "
                + "to record a different event, delete this one and add the right one")
        }

        switch tx.kind {
        case .deposit, .withdrawal:
            if used("shares", "price", "principal", "rate", "maturity", "compounding",
                    "product", "proceeds", "from-amount", "to-amount") {
                throw rejected(["shares", "price", "principal", "rate", "maturity",
                                "compounding", "product", "proceeds", "from-amount", "to-amount"])
            }
            guard used("amount") else { return nil }
            let amount = try decimal("amount")!
            return tx.kind.kindName == "deposit" ? .deposit(amount: amount) : .withdrawal(amount: amount)

        case .stockPurchase(let details), .stockSale(let details):
            if used("amount", "principal", "rate", "maturity", "compounding", "product",
                    "proceeds", "from-amount", "to-amount") {
                throw rejected(["amount", "principal", "rate", "maturity", "compounding",
                                "product", "proceeds", "from-amount", "to-amount"])
            }
            guard used("shares", "price") else { return nil }
            let shares = try decimal("shares") ?? details.shares
            let price = try decimal("price") ?? details.price
            let replacement = StockDetails(ticker: details.ticker, shares: shares, price: price)
            return tx.kind.kindName == "stockPurchase" ? .stockPurchase(replacement) : .stockSale(replacement)

        case .dividend(let details):
            if used("shares", "price", "principal", "rate", "maturity", "compounding",
                    "product", "proceeds", "from-amount", "to-amount") {
                throw rejected(["shares", "price", "principal", "rate", "maturity", "compounding",
                                "product", "proceeds", "from-amount", "to-amount"])
            }
            guard used("amount") else { return nil }
            return .dividend(DividendDetails(ticker: details.ticker, amount: try decimal("amount")!))

        case .gicPurchase(let details):
            if used("amount", "shares", "price", "proceeds", "from-amount", "to-amount") {
                throw rejected(["amount", "shares", "price", "proceeds", "from-amount", "to-amount"])
            }
            guard used("principal", "rate", "maturity", "compounding", "product") else { return nil }
            var rate = details.rate
            if let raw = options["rate"] {
                // --rate is a percentage: "4.1" means 4.1 %.
                let cleaned = raw.hasSuffix("%") ? String(raw.dropLast()) : raw
                let percent = try parseDecimal(cleaned, option: "--rate")
                guard percent >= 0, percent <= 1000 else {
                    throw ParseError("--rate must be a percentage between 0 and 1000 (got '\(raw)')")
                }
                rate = percent / 100
            }
            var compounding = details.compounding
            if let raw = options["compounding"] {
                guard let parsed = GICCompounding.allCases
                    .first(where: { normalizeToken($0.rawValue) == normalizeToken(raw) }) else {
                    throw ParseError("unknown compounding '\(raw)' — one of: "
                        + GICCompounding.allCases.map(\.rawValue).joined(separator: ", "))
                }
                compounding = parsed
            }
            let maturity = try options["maturity"].map(parseDate) ?? details.maturityDate
            return .gicPurchase(GICDetails(
                product: options["product"] ?? details.product,
                principal: try decimal("principal") ?? details.principal,
                rate: rate,
                compounding: compounding,
                maturityDate: maturity,
                redeemable: details.redeemable))

        case .gicRedemption(let details):
            if used("amount", "principal", "rate", "from-amount", "to-amount") {
                throw rejected(["amount", "principal", "rate", "from-amount", "to-amount"])
            }
            guard used("proceeds") else { return nil }
            return .gicRedemption(GICRedemptionDetails(
                purchaseID: details.purchaseID,
                proceeds: try decimal("proceeds")!))

        case .fxConversion(let details):
            if used("amount", "shares", "price", "principal", "rate", "maturity",
                    "compounding", "product", "proceeds") {
                throw rejected(["amount", "shares", "price", "principal", "rate", "maturity",
                                "compounding", "product", "proceeds"])
            }
            guard used("from-amount", "to-amount") else { return nil }
            return .fxConversion(FXDetails(
                fromCurrency: details.fromCurrency,
                fromAmount: try decimal("from-amount") ?? details.fromAmount,
                toAmount: try decimal("to-amount") ?? details.toAmount))
        }
    }

    private static func txDelete(_ args: [String], global: Global) async throws {
        let options = try Options(args, flagOptions: ["yes"])
        guard let reference = options.positionals.first else {
            throw ParseError("usage: dit tx delete <id> [--yes]")
        }
        let (store, portfolio) = try await portfolioForMutation(global: global)
        let tx = try TransactionRef(reference).resolve(in: portfolio)
        // Compute once: the notes *are* the impact preview.
        let (updated, notes) = try portfolio.removingTransaction(id: tx.id)
        let impact = "This will remove '\(shortDate(tx.date)) \(tx.summaryLine)'.\n"
            + notes.dropFirst().map { "  \($0)" }.joined(separator: "\n")
        guard confirm(impact, yes: options.flag("yes") == true) else {
            print("cancelled")
            return
        }
        try await store.save(updated)
        for note in notes { print(note) }
    }

    // MARK: - Helpers

    /// Lowercased, dashes/underscores removed — so "gic-redeem",
    /// "GICRedemption", and "gic_redemption" all match the same thing.
    private static func normalizeToken(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private static let kindAliases: [String: String] = [
        "deposit": "deposit",
        "withdraw": "withdrawal", "withdrawal": "withdrawal",
        "buy": "stockPurchase", "purchase": "stockPurchase", "stockpurchase": "stockPurchase",
        "sell": "stockSale", "stocksale": "stockSale",
        "dividend": "dividend",
        "gic": "gicPurchase", "gicpurchase": "gicPurchase",
        "gicredeem": "gicRedemption", "gicredemption": "gicRedemption",
        "fx": "fxConversion", "fxconversion": "fxConversion",
    ]

    private static func parseDecimal(_ raw: String, option: String) throws -> Decimal {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Decimal(string: trimmed) else {
            throw ParseError("invalid number for \(option): '\(raw)'")
        }
        return value
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

    /// A sale below zero is recorded (the cash is a fact) but the short
    /// liability it created is outside the model — so it gets stated in
    /// the summary's footnotes, never quietly omitted from the totals.
    private static func untrackedShortNotes(_ summary: PortfolioSummary) -> [String] {
        summary.untrackedShorts.map { flag in
            "untracked short: \(flag.accountName) sold \(trim(flag.shares)) \(flag.symbol) "
                + "(\(flag.currency.rawValue)) beyond its holding — cash shows the proceeds, "
                + "the short itself is not tracked, so totals here are incomplete"
        }
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
        case ("", _):
            return """
            USAGE: dit [command] [options]

              dit                        portfolio summary (default)
              dit summary [options]      portfolio summary
              dit accounts               list accounts
              dit account <sub> [args]   manage accounts (see: dit account --help)
              dit tx <sub> [args]        list & manage transactions (see: dit tx --help)
              dit ticker <sub> [args]    manage the instrument registry (see: dit ticker --help)
              dit store <sub> [args]     path / export / backup / import (see: dit store --help)
              dit quote <SYM> [...]      live price lookup (see: dit quote --help)
              dit help [command]         help

              Global options: --display CCY, --offline, --backend file|sqlite,
              --store PATH, -h/--help. Flags override environment variables.
              Exit codes: 0 success, 1 runtime error, 2 usage error.

              Group help: dit help <group> — e.g. 'dit help account'.
            """
        case ("summary", _):
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
            USAGE: dit tx <command> [options]

              dit tx list [filters]               transactions (all accounts by default)
              dit tx show <id>                    one transaction, in full
              dit tx deposit  --account A --amount N [options]
              dit tx withdraw --account A --amount N [options]
              dit tx buy|sell --account A --ticker SYM --shares N
                              [--price P] [--currency CCY] [--fee F] [--date D]
              dit tx dividend --account A --ticker SYM --amount N
                              [--currency CCY] [--fee F] [--date D]
              dit tx gic --account A --product NAME --principal N --rate PCT
                         --maturity YYYY-MM-DD [--compounding KIND] [--redeemable]
              dit tx gic-redeem --account A --gic NAME|ID --proceeds N
                              [--currency CCY] [--fee F] [--date D]
              dit tx fx --account A --from CCY --to CCY
                        --from-amount N --to-amount M [--fee F] [--date D]
              dit tx edit <id> [--date D] [--fee F] [value options]
              dit tx delete <id> [--yes]

              buy/sell without --price fetches the latest quote (a lookup
              failure aborts; under --offline pass --price instead). A
              sale bigger than the holding is recorded but flagged.
              Entry currency defaults to the fetched quote's currency,
              else the ticker's known trading currency, else the
              account's — --currency overrides.
              --gic names the redeemed GIC by product name or id; no
              match lists the account's live GICs.

              Filters: --account A, --kind K, --ticker SYM, --since D,
              --until D, --limit N (most recent N).
              <id> comes from the ID column of 'dit tx list'; 8 characters
              usually identify a transaction uniquely.

              --kind values: deposit, withdrawal, buy, sell, dividend, gic,
              gic-redeem, fx (canonical names like stockPurchase work too).

              Edit rule: values only, within the kind's own fields (a
              deposit takes --amount; trades --shares/--price; a GIC
              --principal/--rate/--maturity/--compounding/--product; ...).
              Changing WHAT a transaction is (kind, account, ticker) is
              delete + re-add — the correction stays visible in the ledger.

              EXAMPLES
                dit tx --limit 10
                dit tx list --account "Wells Fargo" --kind sell
                dit tx deposit --account TD --amount 1000
                dit tx deposit --account TD --amount 500 --currency USD --date 2026-04-01
                dit tx buy --account TD --ticker SHOP.TO --shares 10 --price 180
                dit tx sell --account TD --ticker SHOP.TO --shares 4
                dit tx dividend --account TD --ticker AAPL --amount 12
                dit tx gic --account TD --product "5-Year GIC" --principal 10000 \\
                    --rate 4.1 --maturity 2031-01-09
                dit tx gic-redeem --account TD --gic "5-Year GIC" --proceeds 10410
                dit tx fx --account TD --from CAD --to USD --from-amount 1000 --to-amount 740
                dit tx edit 9F2C6D1A --fee 0 --date 2026-05-05
                dit tx delete 9F2C6D1A
            """
        case ("ticker", _):
            return """
            USAGE:
              dit ticker | dit ticker list              list the instrument registry
              dit ticker add <symbol> [options]         register an instrument
              dit ticker show <symbol>                  entry details + references
              dit ticker edit <symbol> [options]        update one entry
              dit ticker delete <symbol> [--yes]        remove an entry

              Options: --name NAME, --currency CCY (the currency the
              instrument trades in), --tags a,b, --notes TEXT.
              The registry is display metadata: trades for a symbol work
              with or without an entry, and deleting an entry never
              touches the ledger. Deleting an entry that transactions
              reference is gated by confirmation.

              EXAMPLES
                dit ticker add BRK.B --name "Berkshire Hathaway" --currency USD
                dit ticker edit shop.to --tags "dividend, core"
                dit ticker list
            """
        case ("store", _):
            return """
            USAGE: dit store <path|export|backup|import> [options]

              dit store path              where the store lives (backend + location)
              dit store export [options]  write a JSON copy of the portfolio
              dit store backup            timestamped copy of the store file(s)
              dit store import FILE [options]

              export options: --to FILE, --account NAME (a single-account
              file can be imported; a multi-account export cannot)
              import options: --merge (append instead of replace),
              --force (skip the automatic pre-import backup), --yes
              backup options:  --to DIR

              IMPORT SEMANTICS — an import file is single-account. The
              default (replace) swaps that account's record and ledger for
              the file's contents, taking an automatic backup of the store
              first (unless --force). --merge appends instead: new
              transactions (never duplicates by ID), a new account if the
              ID is unknown, new ticker symbols only. Other accounts are
              never touched.

              EXAMPLES
                dit store path
                dit store export --account TFSA --to ~/Exports/tfsa.json
                dit store backup
                dit store import ~/Exports/tfsa.json --merge --yes
            """
        case ("quote", _):
            return """
            USAGE: dit quote <SYMBOL> [SYMBOL ...]

              dit quote SHOP.TO AAPL     live last prices from Yahoo Finance

              Prints a table (symbol, price, currency, as-of time, source).
              Needs the network — --offline is refused here. Exit non-zero
              only when *none* of the requested symbols returned a quote;
              partial misses are listed and not an error.
            """
        default:
            return """
            USAGE: dit [command] [options]

              dit                        portfolio summary (default)
              dit summary [options]      portfolio summary
              dit accounts               list accounts
              dit account <sub> [args]   manage accounts (see: dit account --help)
              dit tx <sub> [args]        list & manage transactions (see: dit tx --help)
              dit ticker <sub> [args]    manage the instrument registry (see: dit ticker --help)
              dit store <sub> [args]     path / export / backup / import (see: dit store --help)
              dit quote <SYM> [...]      live price lookup (see: dit quote --help)
              dit help [command]         help

              Global options: --display CCY, --offline, --backend file|sqlite,
              --store PATH, -h/--help. Flags override environment variables.
              Exit codes: 0 success, 1 runtime error, 2 usage error.
            """
        }
    }
}