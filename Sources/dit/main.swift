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
            try await txCommand(sub, invocation.rest, global: global)
        case ("tx", nil), ("transaction", nil):
            try await txCommand("list", invocation.rest, global: global)
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
        case "buy", "sell", "dividend", "gic", "gic-redeem", "fx":
            throw ParseError("'dit tx \(sub)' arrives in a later release — for now: "
                + "edit existing records with 'dit tx edit', and the read commands work today")
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
            let account = try AccountRef(accountRef).resolve(in: portfolio)
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
        let (store, portfolio) = try await requirePortfolio(global: global)
        let account = try AccountRef(reference).resolve(in: portfolio)
        let amount = try parseDecimal(amountRaw, option: "--amount")

        var currency = account.reportingCurrency
        if let raw = options["currency"] {
            guard let parsed = Currency(rawValue: raw), parsed != .unknown else {
                throw ParseError("unknown currency '\(raw)' — use e.g. CAD, USD, JPY, or GBp")
            }
            currency = parsed
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
        let (store, portfolio) = try await requirePortfolio(global: global)
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
        let (store, portfolio) = try await requirePortfolio(global: global)
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
            USAGE: dit tx <command> [options]

              dit tx list [filters]               transactions (all accounts by default)
              dit tx show <id>                    one transaction, in full
              dit tx deposit  --account A --amount N [options]
              dit tx withdraw --account A --amount N [options]
              dit tx edit <id> [--date D] [--fee F] [value options]
              dit tx delete <id> [--yes]

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
                dit tx edit 9F2C6D1A --fee 0 --date 2026-05-05
                dit tx delete 9F2C6D1A
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
              dit tx <sub> [args]        list & manage transactions (see: dit tx --help)
              dit help [command]         help

              Global options: --display CCY, --offline, --backend file|sqlite,
              --store PATH, -h/--help. Flags override environment variables.
              Exit codes: 0 success, 1 runtime error, 2 usage error.
            """
        }
    }
}