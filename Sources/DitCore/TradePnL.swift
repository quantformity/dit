import Foundation

// MARK: - Transaction-level P&L (the `dit tx pnl` view)
//
// "What did each transaction earn?" — the finest honest slice of the
// ledger. This is NOT a second financial model: the cost-basis rules
// are copied literally from the window engine (see
// ``PnLWindow/compute(portfolio:window:accounts:perAccount:symbols:currencies:reportingCurrency:market:fx:)``)
// so a lifetime run of this view reconciles, to the cent, with
// `dit pnl` over the full ledger for the same scope. If that ever
// stops being true here, at least one of the two views is wrong.
//
// Two row kinds, never conflated:
// - BOOKED: what one transaction contributed to realized P&L AT THE
//   MOMENT IT BOOKED — a sale's gain over the average cost standing
//   at that date, a dividend net of its fee, a GIC redemption against
//   its recorded principal. Exact ledger facts, no prices needed.
// - OPEN: unrealized P&L of positions still held at `asOf`, valued at
//   the last STORED close. Reported per position (account × symbol),
//   because average cost genuinely cannot split an open position back
//   into the buys that formed it — inventing a per-lot mark would be
//   a fabricated number, so the tool refuses and shows the position.
//
// Honesty rules carried over verbatim from the window engine: a
// position without a usable price pair is DASHED, never guessed; a
// series stored in a foreign currency is never used; oversold sales
// are flagged as untracked shorts and mark their currency's totals
// incomplete; a redemption without its recorded purchase is skipped
// (inventing a principal would fabricate P&L).

/// One booked P&L event (a sale, dividend, or GIC redemption), in its
/// recorded currency. `pnl` is exact ledger arithmetic — the fees are
/// already netted (buys carry fees INTO cost, events net them OUT).
public struct TradePnLBookedRow: Sendable {
    /// The transaction that booked the amount (short-form id shown
    /// with the row; `tx show` opens it in full).
    public let txID: UUID
    /// Transaction date.
    public let date: Date
    /// Account display name the event happened in.
    public let accountName: String
    /// Ticker, or "GIC: <product>" for cash P&L without a position.
    public let symbol: String
    /// "sell", "dividend", or "gic-redemption".
    public let kind: String
    /// Currency the amounts are RECORDED in (never converted here —
    /// see ``TradePnLReport/perCurrency`` for the units rule).
    public let currency: Currency
    /// The P&L this one transaction booked (may be negative).
    public let pnl: Decimal
    /// Human explanation of where the number came from (proceeds,
    /// cost removed, etc.) — the view must be checkable by hand.
    public let detail: String
    /// true when the number is knowingly incomplete (e.g. a sale
    /// beyond the tracked holding — the short itself is not tracked).
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

/// A position still open at `asOf`, with its mark-to-what-we-have.
/// `unrealized == nil` means NO usable close was stored — a dash,
/// which is NOT zero (the renderer must never print 0.00 for it).
public struct TradePnLOpenRow: Sendable {
    public let accountName: String
    public let symbol: String
    /// Currency of BOTH the ledger cost and (when present) the quote.
    public let currency: Currency
    /// Shares still held.
    public let shares: Decimal
    /// Remaining cost basis, fees included (average-cost pool).
    public let cost: Decimal
    /// Last stored close on/before `asOf`; `nil` = no usable history.
    public let mark: Decimal?
    /// The day that close belongs to (`nil` with `mark`).
    public let markDay: Date?
    /// true when the close is a DERIVED proxy, not an observed quote.
    public let derived: Bool
    /// shares × mark − cost, or `nil` when unmarked.
    public let unrealized: Decimal?

    public init(accountName: String, symbol: String, currency: Currency, shares: Decimal,
                cost: Decimal, mark: Decimal?, markDay: Date?, derived: Bool = false,
                unrealized: Decimal?) {
        self.accountName = accountName
        self.symbol = symbol
        self.currency = currency
        self.shares = shares
        self.cost = cost
        self.mark = mark
        self.markDay = markDay
        self.derived = derived
        self.unrealized = unrealized
    }
}

/// Per-currency totals, kept NATIVE — money never adds across
/// currencies on one line (see the reporting rules; conversion here
/// would need a DATED rate, which this view deliberately avoids).
public struct CurrencyTradePnL: Sendable {
    public let currency: Currency
    /// Exact booked totals (every booked row is an exact fact).
    public let booked: Decimal
    /// `nil` when at least one open row in this currency could not be
    /// marked (or involved an untracked short) — a half-total is
    /// worse than no total.
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

/// A whole transaction-level report: the booked events, the open
/// positions, per-currency totals, and the footnotes naming every
/// dash and every knowingly-incomplete figure.
public struct TradePnLReport: Sendable {
    /// Date the open marks were taken "as of" (inclusive).
    public let asOf: Date
    public let booked: [TradePnLBookedRow]
    public let open: [TradePnLOpenRow]
    public let perCurrency: [CurrencyTradePnL]
    /// Footnotes: dashed symbols, derived proxies, untracked shorts,
    /// skipped redemptions.
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
    ///     the open rows — realized rows stay exact.
    ///   - symbols: optional ticker whitelist (normalized uppercase);
    ///     GIC cash P&L rows (symbol "GIC: …") are never filtered out
    ///     by a ticker list, matching the window engine.
    ///   - currencies: optional currency whitelist (rows outside are
    ///     dropped entirely — filter, not display option).
    /// - Returns: rows sorted chronologically (booked) and by
    ///   account/symbol (open), totals kept native per currency.
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

            // One chronological replay per account: average-cost pools
            // per (currency, symbol), GIC principals by purchase id.
            var pools: [PositionKey: (shares: Decimal, cost: Decimal)] = [:]
            var gics: [UUID: (key: PositionKey, principal: Decimal)] = [:]

            for tx in history {
                let fee = tx.fee ?? 0
                switch tx.kind {
                case .stockPurchase(let d):
                    let key = PositionKey(currency: tx.currency, symbol: d.ticker)
                    let cur = pools[key] ?? (0, 0)
                    pools[key] = (cur.shares + d.shares,
                                  cur.cost + d.shares * d.price + fee)

                case .stockSale(let d):
                    let key = PositionKey(currency: tx.currency, symbol: d.ticker)
                    let cur = pools[key] ?? (0, 0)
                    let costRemoved: Decimal
                    if cur.shares > 0, d.shares >= cur.shares {
                        costRemoved = cur.cost // full liquidation: exact
                    } else if cur.shares > 0 {
                        costRemoved = cur.cost * d.shares / cur.shares
                    } else {
                        costRemoved = 0 // sale with no tracked position
                    }
                    let proceeds = d.shares * d.price
                    let pnl = (proceeds - fee) - costRemoved
                    let short = d.shares > max(0, cur.shares)
                    if short {
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
                            detail: "\(TextFormat.quantity(d.shares)) sh @ \(TextFormat.quantity(d.price))"
                                + " − cost \(TextFormat.money(costRemoved))"
                                + (short ? " (short sale — incomplete)" : ""),
                            incomplete: short))
                    }
                    pools[key] = (max(0, cur.shares - d.shares),
                                  max(0, cur.cost - costRemoved))

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

            // MARK: open positions (after the replay: what is left)
            for (key, pool) in pools where pool.shares > 0 {
                guard passesFilter(symbol: key.symbol, currency: key.currency,
                                   symbols: symbols, currencies: currencies) else { continue }
                // Series currency rule, verbatim from the window
                // engine: exact currency match or UNLABELLED series is
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
                open.append(TradePnLOpenRow(
                    accountName: account.displayName, symbol: key.symbol, currency: key.currency,
                    shares: pool.shares, cost: pool.cost,
                    mark: point?.price, markDay: point.map { $0.day },
                    derived: point.map { $0.via != nil } ?? false,
                    unrealized: point.map { pool.shares * $0.price - pool.cost }))
            }
        }

        booked.sort { ($0.date, $0.accountName, $0.symbol) < ($1.date, $1.accountName, $1.symbol) }
        open.sort { ($0.accountName, $0.symbol) < ($1.accountName, $1.symbol) }

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
            // Once a currency's open total goes nil (some position
            // cannot be marked), it STAYS nil — a later markable row
            // must not resurrect a total that silently omits a
            // sibling. Same "whole or nothing" rule as the window
            // engine's complete-flag.
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
        var notes: [String] = []
        if !dashedSymbols.isEmpty {
            notes.append("no usable daily history for: \(dashedSymbols.sorted().joined(separator: ", ")) —"
                + " those positions show a DASHED unrealized P&L; a dash is not zero and totals"
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

    /// Ticker/currency whitelist check; GIC cash rows ("GIC: …") are
    /// exempt from the ticker list, exactly like the window engine.
    private static func passesFilter(symbol: String, currency: Currency,
                                     symbols: Set<String>?,
                                     currencies: Set<Currency>?) -> Bool {
        if let symbols, !symbol.hasPrefix("GIC:"), !symbols.contains(symbol) { return false }
        if let currencies, !currencies.contains(currency) { return false }
        return true
    }
}