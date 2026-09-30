import DirectInvestTracker
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - account commands

func accountShow(_ args: [String], global: Global) async throws {
    let options = try Options(args, flagOptions: ["history"])
    guard let reference = options.positionals.first else {
        throw ParseError("usage: dit account show <account> [--history]")
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

    // ONE history order for both renderers — Replay's rule (date,
    // then storage order), shared with 'tx list' and the statement
    // so one ledger prints identically everywhere.
    let historyTx = options.has("history")
        ? Replay.ordered(portfolio.transactions(in: account.id))
        : []

    if global.json {
        // Same stable history order as the table (date, then
        // storage order); FULL ids here — a caller can pipe them
        // straight into 'tx show'/'tx edit'.
        let historyJSON = options.has("history")
            ? historyTx.map { tx in
                (tx.id.uuidString, tx.date, tx.kindName, tx.summaryLine, tx.currency.rawValue)
            }
            : nil
        print(JSONOutput.accountJSON(account: account, balances: balances, history: historyJSON))
        return
    }

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

    if options.has("history") {
        // The account's full ledger, oldest first — the same rows as
        // `dit tx list --account …`, shown here so one command
        // answers both "what does it hold" and "how did it get
        // there". Stable order (date, then storage order) keeps
        // output identical between runs. Offline by construction:
        // everything comes from the ledger document.
        let indexed = historyTx
        print("\nHistory (\(indexed.count) transaction(s), oldest first):")
        if indexed.isEmpty {
            print("  — no activity recorded —")
        } else {
            let rows = indexed.map { tx -> [String] in
                [String(tx.id.uuidString.prefix(8)), shortDate(tx.date),
                 tx.kindName, tx.summaryLine]
            }
            for line in Table.render(headers: ["ID", "Date", "Kind", "Detail"],
                                     rows: rows, leftColumns: [0, 1, 2, 3]) {
                print("  \(line)")
            }
            print("\n  Filter deeper: 'dit tx list --account \"\(account.displayName)\" "
                + "--kind/--ticker/--since/--until/--limit'; edit with 'dit tx show <id>'.")
        }
    }
}

func accountAdd(_ args: [String], global: Global) async throws {
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

func accountEdit(_ args: [String], global: Global) async throws {
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

func accountClose(_ args: [String], global: Global) async throws {
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

func accountDelete(_ args: [String], global: Global) async throws {
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

func tickerList(global: Global) async throws {
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

func tickerShow(_ args: [String], global: Global) async throws {
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

func tickerAdd(_ args: [String], global: Global) async throws {
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

func tickerEdit(_ args: [String], global: Global) async throws {
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

func tickerDelete(_ args: [String], global: Global) async throws {
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
