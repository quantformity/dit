import Foundation

// MARK: - Transaction-level P&L (the `dit tx pnl` view)
//
// "What did each transaction earn?" — the finest honest slice of the
// ledger. Numbers here are TRANSACTION ATTRIBUTIONS under FIFO lot
// matching: every buy opens a lot; a sale realizes its gain against
// the OLDEST open lots it consumed. Two facts about that choice,
// stated so no reader mistakes attribution for accounting:
//
// 1. The ledger's own accounting stays AVERAGE COST (AccountBalances
//    and the window engine). A multi-lot sale therefore shows a
//    DIFFERENT slice here than a `dit pnl` window slice — different
//    attribution, same underlying facts. This file must stay a view
//    of the ledger, never a rival authority.
// 2. The SPLIT is method-dependent, the TOTAL is not: per-transaction
//    attributions always sum to the position's lifetime P&L (proceeds
//    + final mark − cost), which is exactly what a full-history
//    `dit pnl` run reports for the same scope. That identity is
//    pinned by tests (unit + an e2e helper). If it ever breaks here,
//    one of the two views is wrong.
//
// Honesty rules carried over from the window engine, verbatim in
// spirit: a lot without a usable price pair is DASHED, never
// guessed; a series stored in a foreign currency is never used;
// oversold sales are flagged as untracked shorts and mark their
// currency's totals incomplete; a redemption without its recorded
// purchase is skipped (inventing a principal would fabricate P&L).
// Unknowns never get a manufactured number, and a withheld total is
// never replaced by a half-total.

/// One booked P&L event (a sale, dividend, or GIC redemption), in its
/// recorded currency. `pnl` is exact ledger arithmetic — fees are
/// already netted (buys carry fees INTO lot cost, events net them
/// OUT).
public struct TradePnLBookedRow: Sendable {
    /// The transaction that booked the amount (`tx show` opens it).
    public let txID: UUID
    /// Transaction date.
    public let date: Date
    /// Account display name the event happened in.
    public let accountName: String
    /// Ticker, or "GIC: <product>" for cash P&L without a position.
    public let symbol: String
    /// "sell", "dividend", or "gic-redemption".
    public let kind: String
    /// Currency the amounts are RECORDED in (never converted here).
    public let currency: Currency
    /// The P&L this one transaction booked under FIFO attribution
    /// (may be negative).
    public let pnl: Decimal
    /// Human explanation of where the number came from (proceeds,
    /// which lots were consumed, etc.) — checkable by hand.
    public let detail: String
    /// true when the number is knowingly incomplete (a sale beyond
    /// the tracked holdings — the short itself is not tracked).
    public let incomplete: Bool

    public init(txID: UUID, date: Date, accountName: String, symbol: String, kind: String,
                currency: Currency, pnl: Decimal, detail: String, incomplete: Bool = false) {
        self.txID = txID
        self.date = date
        self.accountName = accountName
        self.symbol = symbol
        self.kind = kind
        self.currency = currency
        self.pnl = pnl
        self.detail = detail
        self.incomplete = incomplete
    }
}

/// One still-open BUY (a lot) with what remains of it at `asOf`.
/// `unrealized == nil` means NO usable close was stored for its
/// symbol — a dash, which is NOT zero, and it withholds the whole
/// currency's total (a half-total would silently omit it).
public struct TradePnLOpenRow: Sendable {
    public let accountName: String
    /// The BUY transaction this lot came from.
    public let txID: UUID
    /// Purchase date.
    public let buyDate: Date
    public let symbol: String
    /// Currency of BOTH the ledger cost and (when present) the quote.
    public let currency: Currency
    /// Shares originally bought.
    public let boughtShares: Decimal
    /// Shares of this lot still held.
    public let heldShares: Decimal
    /// Remaining cost basis of the held shares, fees included.
    public let cost: Decimal
    /// Last stored close on/before `asOf`; `nil` = no usable history.
    public let mark: Decimal?
    /// The day that close belongs to (`nil` with `mark`).
    public let markDay: Date?
    /// true when the close is a DERIVED proxy, not an observed quote.
    public let derived: Bool
    /// heldShares × mark − cost, or `nil` when unmarked.
    public let unrealized: Decimal?

    public init(accountName: String, txID: UUID, buyDate: Date, symbol: String,
                currency: Currency, boughtShares: Decimal, heldShares: Decimal,
                cost: Decimal, mark: Decimal?, markDay: Date?, derived: Bool = false,
                unrealized: Decimal?) {
        self.accountName = accountName
        self.txID = txID
        self.buyDate = buyDate
        self.symbol = symbol
        self.currency = currency
        self.boughtShares = boughtShares
        self.heldShares = heldShares
        self.cost = cost
        self.mark = mark
        self.markDay = markDay
        self.derived = derived
        self.unrealized = unrealized
    }
}

/// Per-currency totals, kept NATIVE — money never adds across
/// currencies on one line.
public struct CurrencyTradePnL: Sendable {
    public let currency: Currency
    /// Exact booked totals (every booked row is an exact fact).
    public let booked: Decimal
    /// `nil` when at least one open lot in this currency could not be
    /// marked (or involved an untracked short) — whole or nothing.
    public let open: Decimal?
    /// booked + open when both are exact; `nil` otherwise.
    public let total: Decimal?

    public init(currency: Currency, booked: Decimal, open: Decimal?, total: Decimal?) {
        self.currency = currency
        self.booked = booked
        self.open = open
        self.total = total
    }
}

/// A whole transaction-level report: booked events, open lots,
/// per-currency totals, and the footnotes naming every dash and every
/// knowingly-incomplete figure.
public struct TradePnLReport: Sendable {
    /// Date the open marks were taken "as of" (inclusive).
    public let asOf: Date
    public let booked: [TradePnLBookedRow]
    public let open: [TradePnLOpenRow]
    public let perCurrency: [CurrencyTradePnL]
    public let notes: [String]

    public init(asOf: Date, booked: [TradePnLBookedRow], open: [TradePnLOpenRow],
                perCurrency: [CurrencyTradePnL], notes: [String] = []) {
        self.asOf = asOf
        self.booked = booked
        self.open = open
        self.perCurrency = perCurrency
        self.notes = notes
    }

    public var isEmpty: Bool { booked.isEmpty && open.isEmpty }
}

/// Lifetime transaction-level P&L for a scope of accounts. Pure
/// function over (ledger + stored market data), no network, no state.
public enum TradePnL {

    /// Compute the report.
    ///
    /// - Parameters:
    ///   - portfolio: ledger source.
    ///   - accounts: scope (resolved by the CLI).
    ///   - asOf: last day open marks may use (inclusive).
    ///   - market: stored daily closes; `nil` or missing series dash
    ///     the open lots — booked (realized) rows stay exact.
    ///   - symbols: optional ticker whitelist (normalized uppercase);
    ///     GIC cash rows (symbol "GIC: …") are never filtered out by
    ///     a ticker list, matching the window engine.
    ///   - currencies: optional currency whitelist (rows outside are
    ///     dropped entirely — filter, not display option).
    /// - Returns: booked rows chronological, open lots chronological
    ///   by purchase date; totals kept native per currency.
    public static func compute(portfolio: Portfolio,
                               accounts: [Account],
                               asOf: Date,
                               market: MarketData?,
                               symbols: Set<String>?,
                               currencies: Set<Currency>?) -> TradePnLReport {
        var booked: [TradePnLBookedRow] = []
        var open: [TradePnLOpenRow] = []
        var dashedSymbols = Set<String>()
        var proxySymbols = Set<String>()
        var shortFlags: [String] = []
        var skippedRedemptions: [String] = []

        for account in accounts {
            let history = Replay.ordered(portfolio.transactions(in: account.id))

            // One chronological FIFO replay per account: each buy
            // opens a lot (fees join its cost); each sale consumes
            // from the OLDEST lots first. Cost fragments come out at
            // lot.cost × shares/lot.held — the same division pattern
            // (and dust scale) as the average-cost engines.
            var lots: [PositionKey: [Lot]] = [:]
            var gics: [UUID: (key: PositionKey, principal: Decimal)] = [:]

            for tx in history {
                let fee = tx.fee ?? 0
                switch tx.kind {
                case .stockPurchase(let d):
                    let key = PositionKey(currency: tx.currency, symbol: d.ticker)
                    lots[key, default: []].append(Lot(txID: tx.id, date: tx.date,
                                                      bought: d.shares, held: d.shares,
                                                      cost: d.shares * d.price + fee))

                case .stockSale(let d):
                    let key = PositionKey(currency: tx.currency, symbol: d.ticker)
                    var need = d.shares
                    var costRemoved: Decimal = 0
                    var consumed: [(date: Date, shares: Decimal)] = []
                    var queue = lots[key] ?? []
                    for index in queue.indices where need > 0 {
                        let take = min(need, queue[index].held)
                        let costFragment = queue[index].cost * take / queue[index].held
                        costRemoved += costFragment
                        queue[index].cost -= costFragment
                        queue[index].held -= take
                        consumed.append((queue[index].date, take))
                        need -= take
                    }
                    lots[key] = queue.filter { $0.held > 0 }
                    let short = need  // shares sold with no lot behind them
                    let pnl = (d.shares * d.price - fee) - costRemoved
                    if short > 0 {
                        shortFlags.append("\(account.displayName) sold "
                            + "\(TextFormat.quantity(d.shares)) \(d.ticker) (\(tx.currency.rawValue)) "
                            + "beyond its holding — the short itself is not tracked, "
                            + "totals covering it are incomplete")
                    }
                    if passesFilter(symbol: d.ticker, currency: tx.currency,
                                    symbols: symbols, currencies: currencies) {
                        booked.append(TradePnLBookedRow(
                            txID: tx.id, date: tx.date, accountName: account.displayName,
                            symbol: d.ticker, kind: "sell", currency: tx.currency, pnl: pnl,
                            detail: "\(TextFormat.quantity(d.shares)) sh @ "
                                + "\(TextFormat.quantity(d.price)) − cost "
                                + "\(TextFormat.money(costRemoved))\(lotSource(consumed))"
                                + (short > 0 ? " (short sale — incomplete)" : ""),
                            incomplete: short > 0))
                    }

                case .gicPurchase(let d):
                    gics[tx.id] = (PositionKey(currency: tx.currency, symbol: "GIC: " + d.product),
                                   d.principal)

                case .gicRedemption(let d):
                    // Same rule as the window engine: a redemption
                    // without its purchase IN THE HISTORY is skipped —
                    // inventing a principal would fabricate P&L. The
                    // skip is named in the notes, never silent.
                    guard let gic = gics.removeValue(forKey: d.purchaseID) else {
                        skippedRedemptions.append("\(account.displayName): redemption of "
                            + "\(d.proceeds.description) \(tx.currency.rawValue) without a "
                            + "recorded purchase — skipped, no principal was guessed")
                        continue
                    }
                    let pnl = (d.proceeds - fee) - gic.principal
                    if currencies == nil || currencies!.contains(tx.currency) {
                        booked.append(TradePnLBookedRow(
                            txID: tx.id, date: tx.date, accountName: account.displayName,
                            symbol: gic.key.symbol, kind: "gic-redemption",
                            currency: tx.currency, pnl: pnl,
                            detail: "proceeds \(TextFormat.money(d.proceeds)) − principal "
                                + "\(TextFormat.money(gic.principal))"))
                    }

                case .dividend(let d):
                    let pnl = d.amount - fee
                    if passesFilter(symbol: d.ticker, currency: tx.currency,
                                    symbols: symbols, currencies: currencies) {
                        booked.append(TradePnLBookedRow(
                            txID: tx.id, date: tx.date, accountName: account.displayName,
                            symbol: d.ticker, kind: "dividend", currency: tx.currency, pnl: pnl,
                            detail: "income net of fee"))
                    }

                default:
                    // deposit / withdrawal / fxConversion: cash
                    // movement, never P&L.
                    break
                }
            }

            // MARK: open lots (after the replay: what each buy still holds)
            for (key, queue) in lots {
                guard !queue.isEmpty else { continue }
                guard passesFilter(symbol: key.symbol, currency: key.currency,
                                   symbols: symbols, currencies: currencies) else { continue }
                // Series currency rule, verbatim from the window
                // engine: exact match or UNLABELLED series is
                // trusted; a series explicitly in a DIFFERENT currency
                // is a different instrument and is never used.
                let series = market?.series[key.symbol]
                let seriesUsable = series.map { $0.currency == key.currency || $0.currency == .unknown } ?? false
                let point = seriesUsable ? market?.point(onOrBefore: asOf, for: key.symbol) : nil
                if point == nil {
                    dashedSymbols.insert(key.symbol)
                } else if point!.via != nil {
                    proxySymbols.insert(key.symbol)
                }
                for lot in queue where lot.held > 0 {
                    open.append(TradePnLOpenRow(
                        accountName: account.displayName, txID: lot.txID, buyDate: lot.date,
                        symbol: key.symbol, currency: key.currency,
                        boughtShares: lot.bought, heldShares: lot.held, cost: lot.cost,
                        mark: point?.price, markDay: point.map { $0.day },
                        derived: point.map { $0.via != nil } ?? false,
                        unrealized: point.map { lot.held * $0.price - lot.cost }))
                }
            }
        }

        booked.sort { ($0.date, $0.accountName, $0.symbol) < ($1.date, $1.accountName, $1.symbol) }
        open.sort { ($0.buyDate, $0.accountName, $0.symbol) <
                   ($1.buyDate, $1.accountName, $1.symbol) }

        // MARK: per-currency totals (native; nil = withheld, never guessed)
        var grouped: [Currency: (booked: Decimal, open: Decimal?, short: Bool)] = [:]
        for row in booked {
            var entry = grouped[row.currency] ?? (0, 0, false)
            entry.booked += row.pnl
            if row.incomplete { entry.short = true }
            grouped[row.currency] = entry
        }
        for row in open {
            var entry = grouped[row.currency] ?? (0, 0, false)
            // Once a currency's open total goes nil (a lot cannot be
            // marked), it STAYS nil — a later markable lot must not
            // resurrect a total that silently omits a sibling.
            if let unrealized = row.unrealized, entry.open != nil {
                entry.open = entry.open! + unrealized
            } else {
                entry.open = nil
            }
            grouped[row.currency] = entry
        }
        let perCurrency = grouped.map { currency, entry -> CurrencyTradePnL in
            // Untracked shorts make booked totals knowingly incomplete
            // too (the liability beyond the holding is not tracked).
            if entry.short {
                return CurrencyTradePnL(currency: currency, booked: entry.booked, open: nil, total: nil)
            }
            return CurrencyTradePnL(currency: currency, booked: entry.booked,
                                    open: entry.open,
                                    total: entry.open.map { entry.booked + $0 })
        }.sorted { $0.currency.rawValue < $1.currency.rawValue }

        // MARK: notes (label what the numbers cannot say)
        var notes: [String] = [
            "attribution: FIFO lots (the ledger's own accounting is average cost — "
                + "per-transaction slices may differ from 'dit pnl' windows; "
                + "lifetime totals reconcile with it)"
        ]
        if !dashedSymbols.isEmpty {
            notes.append("no usable daily history for: \(dashedSymbols.sorted().joined(separator: ", ")) —"
                + " lots in those symbols show a DASHED unrealized P&L; a dash is not zero and totals"
                + " covering it are withheld. Fill the store with 'dit market history --all'.")
        }
        if !proxySymbols.isEmpty {
            notes.append("marks marked * used DERIVED proxy history (\(proxySymbols.sorted().joined(separator: ", ")))"
                + " — approximations, not quotes")
        }
        notes.append(contentsOf: shortFlags)
        notes.append(contentsOf: skippedRedemptions)

        return TradePnLReport(asOf: asOf, booked: booked, open: open,
                              perCurrency: perCurrency, notes: notes)
    }

    /// " (from 2026-06-10 buy)" / " (from 2 buys: …)" — names the
    /// consumed lots, cap two dates plus a count, so the biggest
    /// sale's detail stays readable.
    private static func lotSource(_ consumed: [(date: Date, shares: Decimal)]) -> String {
        let dates = consumed.map { TextFormat.day($0.date) }
        guard dates.count > 1 else { return " (from \(dates.first ?? "?") buy)" }
        return " (from \(dates.count) buys: \(dates.prefix(2).joined(separator: ", "))"
            + (dates.count > 2 ? " +\(dates.count - 2) more" : "") + ")"
    }

    /// Ticker/currency whitelist check; GIC cash rows ("GIC: …") are
    /// exempt from the ticker list, exactly like the window engine.
    private static func passesFilter(symbol: String, currency: Currency,
                                     symbols: Set<String>?,
                                     currencies: Set<Currency>?) -> Bool {
        if let symbols, !symbol.hasPrefix("GIC:"), !symbols.contains(symbol) { return false }
        if let currencies, !currencies.contains(currency) { return false }
        return true
    }

    /// One buy, tracked until its last share is sold.
    private struct Lot {
        var txID: UUID
        var date: Date
        var bought: Decimal   // shares originally bought
        var held: Decimal     // shares still open
        var cost: Decimal     // remaining cost of the held shares
    }
}
