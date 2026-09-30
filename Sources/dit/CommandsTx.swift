import DirectInvestTracker
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - tx commands

func txCommand(_ sub: String, _ args: [String], global: Global) async throws {
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

func txList(_ args: [String], global: Global) async throws {
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
        guard let target = kindAliases[normalizeToken(kind)] else {
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

    // Statement mode: with NO trade filter (no kind/ticker/since/
    // until/limit), the list becomes a bank-statement view — Debit
    // / Credit / running Balance per account + currency, derived
    // live from the ledger. A filtered subset would make running
    // balances theater, so any filter keeps the plain list.
    let statementMode = options["kind"] == nil && options["ticker"] == nil
        && options["since"] == nil && options["until"] == nil && options["limit"] == nil
    if statementMode {
        let rows: [StatementRow]
        if let accountRef = options["account"] {
            let account = try resolveAccount(accountRef, in: portfolio)
            rows = LedgerStatement.rows(account: account,
                                        transactions: portfolio.transactions(in: account.id))
        } else {
            rows = LedgerStatement.rows(portfolio: portfolio)
        }
        print("Transactions — \(scope) (\(rows.count) shown — statement view)")
        guard !rows.isEmpty else { return }
        // Multi-currency accounts get ONE BALANCE COLUMN PER CURRENCY,
        // for every currency present ANYWHERE in the displayed history
        // (even if a purse later empties — its column stays, showing
        // '—', because "no cash here" is information, not absence of
        // data). Dedicated columns stay comparable top-to-bottom; a
        // joined money string drifts. Up to four currencies; beyond
        // that the joined single column returns (table width trumps).
        var involved: Set<Currency> = []
        for row in rows {
            row.debits.forEach { involved.insert($0.currency) }
            row.credits.forEach { involved.insert($0.currency) }
            row.cashAfter.forEach { involved.insert($0.currency) }
        }
        let currencies = involved.sorted { $0.rawValue < $1.rawValue }
        let splitBalances = (2...4).contains(currencies.count)
        let statementRows: [[String]]
        let headers: [String]
        var legend: [String]
        if splitBalances {
            headers = ["ID", "Date", "Account", "Detail", "Debit", "Credit"]
                + currencies.map { "Bal \($0.rawValue)" }
            statementRows = rows.map { row -> [String] in
                let tx = row.transaction
                let accountName = portfolio.accountName(for: tx.accountID)
                let debit = row.debits.map { "-\(money($0.amount, $0.currency))" }
                    .joined(separator: " ")
                let credit = row.credits.map { money($0.amount, $0.currency) }
                    .joined(separator: " ")
                // Column header names the currency, so cells hold bare
                // numbers; '—' means NO cash in that currency here.
                let balances = currencies.map { currency -> String in
                    guard let entry = row.cashAfter.first(where: { $0.currency == currency }) else {
                        return "\u{2014}"
                    }
                    return amountOnly(entry.amount)
                }
                return [String(tx.id.uuidString.prefix(8)), shortDate(tx.date), accountName,
                        tx.summaryLine, debit, credit] + balances
            }
            legend = [
                "  Debit/Credit/Bal columns are cash, derived on the fly \u{2014} nothing is",
                "  stored, and positions or GICs never appear in a cash column. Each",
                "  'Bal CCY' column is THAT account's running cash in that currency",
                "  (never summed across accounts); '\u{2014}' means no cash in that currency at",
                "  that point. Any filter (--kind/--ticker/--since/--until/--limit)",
                "  gives the plain list instead.",
            ]
        } else {
            headers = ["ID", "Date", "Account", "Detail", "Debit", "Credit", "Balance after"]
            statementRows = rows.map { row -> [String] in
                let tx = row.transaction
                let accountName = portfolio.accountName(for: tx.accountID)
                let debit = row.debits.map { "-\(money($0.amount, $0.currency))" }
                    .joined(separator: " ")
                let credit = row.credits.map { money($0.amount, $0.currency) }
                    .joined(separator: " ")
                let balance = row.cashAfter.isEmpty ? "\u{2014}"
                    : row.cashAfter.map { money($0.amount, $0.currency) }.joined(separator: " ")
                return [String(tx.id.uuidString.prefix(8)), shortDate(tx.date), accountName,
                        tx.summaryLine, debit, credit, balance]
            }
            legend = [
                "  Debit/Credit/Balance are cash, derived on the fly \u{2014} nothing is",
                "  stored, and positions or GICs never appear in a cash column. Balance =",
                "  cash left in THAT account (per currency) after the event. Any filter",
                "  (--kind/--ticker/--since/--until/--limit) gives the plain list instead.",
            ]
        }
        for line in Table.render(headers: headers,
                                 rows: statementRows,
                                 leftColumns: [0, 1, 2, 3]) {
            print("  \(line)")
        }
        print()
        legend.forEach { print($0) }
        return
    }

    // Deterministic order: date, then storage order for equal dates.
    var orderedTx = Replay.ordered(txs)
    if let raw = options["limit"] {
        guard let n = Int(raw), n > 0 else {
            throw ParseError("--limit needs a positive number (got '\(raw)')")
        }
        orderedTx = Array(orderedTx.suffix(n)) // keep the most recent
    }

    print("Transactions — \(scope) (\(orderedTx.count) shown)")
    guard !orderedTx.isEmpty else { return }
    let rows = orderedTx.map { tx -> [String] in
        [String(tx.id.uuidString.prefix(8)), shortDate(tx.date),
         portfolio.accountName(for: tx.accountID), tx.kind.kindName, tx.summaryLine]
    }
    for line in Table.render(headers: ["ID", "Date", "Account", "Kind", "Detail"],
                             rows: rows, leftColumns: [0, 1, 2, 3, 4]) {
        print("  \(line)")
    }
}

func txShow(_ args: [String], global: Global) async throws {
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

func txCashEntry(deposit: Bool, _ args: [String], global: Global) async throws {
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

func txTrade(buy: Bool, _ args: [String], global: Global) async throws {
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
        let held = portfolio.trackedSharesHeld(accountID: account.id, symbol: symbol)
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

func txDividend(_ args: [String], global: Global) async throws {
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

func txGicPurchase(_ args: [String], global: Global) async throws {
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

func txGicRedeem(_ args: [String], global: Global) async throws {
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

func txFx(_ args: [String], global: Global) async throws {
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

/// Edit *values only*. Kind and account are not editable: those
/// changes describe a different event, which must be a new record
/// (delete + re-add), keeping the correction visible.
func txEdit(_ args: [String], global: Global) async throws {
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
func editedKind(tx: Transaction, options: Options) throws -> Transaction.Kind? {
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

func txDelete(_ args: [String], global: Global) async throws {
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
