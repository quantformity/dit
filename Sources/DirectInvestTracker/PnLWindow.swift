import Foundation

// MARK: - Window P&L engine (the `dit pnl` view)
//
// "What did these positions earn between two dates?" answered from the
// ledger and the market store — never from the network. Two honest
// components per position, both reported, never conflated:
//
// - REALIZED: what the ledger booked inside the window (sale gains over
//   cost, GIC redemption gains, dividends net of fees), using EXACTLY
//   the cost-basis rules of ``AccountBalances/compute(account:transactions:rate:lastPrice:dayPrices:)``
//   — a window slice reconciles with the full-history figures by construction.
// - POSITION CHANGE: mark-to-market drift across the window, valued
//   with stored daily closes at the two boundaries (the last close
//   strictly before `start` versus the last close on or before `end`).
//   Without BOTH boundary closes the change is dashed, never guessed.
//
// The components add WITHOUT double counting: a position marked 400 at
// the window start, bought at cost 100 and sold inside the window at
// 350, books realized +250 (proceeds − cost) and position change −300
// (last mark before the window − cost, released by the sale): the sum
// −50 is the true economic change since the window opened. A quiet
// position that merely drifted IS part of historical P&L, so rows are
// not limited to traded positions — but a position without a usable
// price pair contributes NOTHING (no row, no half-truth), and its
// symbol is named in the report notes instead.

/// One P&L line: what one symbol did inside the window, in its own
/// trading currency. `nil` positionChange/total means "not computable"
/// (no price pair), which renderers must show as a dash — it is NOT
/// zero, and the per-currency totals drop out of any combined number
/// that would have needed it.
public struct PnLRow: Sendable {
    /// Ticker, or a label like "GIC: HISA Savings" for cash P&L that
    /// has no position to track.
    public let symbol: String
    /// true when the line is cash P&L without a position (GIC
    /// redemption) — there is no market series to look up, by design.
    public let isCashPnL: Bool
    /// Every account the line touches (joined in aggregate mode).
    public let accountNames: [String]
    public let currency: Currency
    /// Booked income inside the window (exact ledger fact).
    public let realized: Decimal
    /// Mark-to-market change across the window; `nil` = no price pair.
    public let positionChange: Decimal?
    /// realized + positionChange; `nil` when the change is unknown —
    /// a half-truth would be worse than a dash.
    public let total: Decimal?
    /// true when any boundary price came from derived (proxy) history.
    public let usedDerivedHistory: Bool

    public init(symbol: String, isCashPnL: Bool, accountNames: [String], currency: Currency,
                realized: Decimal, positionChange: Decimal?, total: Decimal?,
                usedDerivedHistory: Bool = false) {
        self.symbol = symbol
        self.isCashPnL = isCashPnL
        self.accountNames = accountNames
        self.currency = currency
        self.realized = realized
        self.positionChange = positionChange
        self.total = total
        self.usedDerivedHistory = usedDerivedHistory
    }
}

/// Per-currency column totals (native, exact when complete). `nil`
/// positionChange/total means at least one contributing row lacked a
/// price pair.
public struct CurrencyPnL: Sendable {
    public let currency: Currency
    /// Exact booked income (always computable from the ledger).
    public let realized: Decimal
    /// Exact when every contributing row had a price pair.
    public let positionChange: Decimal?
    /// realized + positionChange when exact; `nil` otherwise.
    public let total: Decimal?
    /// Rows whose position change could not be computed (counted on
    /// the rows actually reported, including dashed ones).
    public let incompletePositions: Int

    public init(currency: Currency, realized: Decimal, positionChange: Decimal?,
                total: Decimal?, incompletePositions: Int) {
        self.currency = currency
        self.realized = realized
        self.positionChange = positionChange
        self.total = total
        self.incompletePositions = incompletePositions
    }
}

/// A whole window report: rows, per-currency totals, and the combined
/// total converted to the reporting currency (only when every currency
/// converted honestly).
public struct PnLReport: Sendable {
    /// The resolved window (inclusive UTC days).
    public struct Window: Sendable {
        /// Inclusive first day of the window.
        public let start: Date
        /// Inclusive last day of the window.
        public let end: Date
        /// Human label: "1y", "ytd", "custom", "full history".
        public let label: String
        /// true when the window starts at the ledger's first activity.
        public let fromLedgerStart: Bool

        public init(start: Date, end: Date, label: String, fromLedgerStart: Bool = false) {
            self.start = start
            self.end = end
            self.label = label
            self.fromLedgerStart = fromLedgerStart
        }
    }

    /// One line of position-level P&L, per account (requested scope)
    /// or aggregated across accounts (portfolio scope).
    public let window: Window
    /// true = specific accounts requested (rows carry account names);
    /// false = portfolio-level aggregate (rows merge across accounts).
    public let perAccount: Bool
    public let rows: [PnLRow]
    public let perCurrency: [CurrencyPnL]
    public let reportingCurrency: Currency
    /// Σ per-currency totals converted at stored latest rates; `nil`
    /// when any currency is unconvertible OR any total is incomplete.
    public let combinedTotal: Decimal?
    /// Rates actually used for the combined total (for labelling).
    public let conversionUsed: [(from: Currency, to: Currency, rate: Decimal)]
    /// Currencies whose total could NOT be combined (missing rate).
    public let unconvertedCurrencies: [Currency]
    /// Currency totals withheld because of missing price data.
    public let incompleteCurrencies: [Currency]
    /// Untracked shorts CREATED inside the window (liability beyond
    /// the model — totals covering it are knowingly incomplete).
    public let untrackedShorts: [(accountName: String, symbol: String, currency: Currency, shares: Decimal)]
    /// Footnotes (dashes explained, proxy history used, conversion
    /// rates quoted with dates, untracked shorts).
    public let notes: [String]
    /// Count of ledger events inside the window in scope (any kind).
    /// Zero means a quiet window; the renderer says so quietly.
    public let activityCount: Int
    /// true when the window contains at least one transaction in scope
    /// (empty windows print a quiet note, not an error).
    public var hadActivity: Bool { activityCount > 0 }

    public init(window: Window, perAccount: Bool, rows: [PnLRow], perCurrency: [CurrencyPnL],
                reportingCurrency: Currency, combinedTotal: Decimal?,
                conversionUsed: [(from: Currency, to: Currency, rate: Decimal)],
                unconvertedCurrencies: [Currency] = [], incompleteCurrencies: [Currency] = [],
                untrackedShorts: [(accountName: String, symbol: String, currency: Currency, shares: Decimal)] = [],
                notes: [String] = [], activityCount: Int = 0) {
        self.window = window
        self.perAccount = perAccount
        self.rows = rows
        self.perCurrency = perCurrency
        self.reportingCurrency = reportingCurrency
        self.combinedTotal = combinedTotal
        self.conversionUsed = conversionUsed
        self.unconvertedCurrencies = unconvertedCurrencies
        self.incompleteCurrencies = incompleteCurrencies
        self.untrackedShorts = untrackedShorts
        self.notes = notes
        self.activityCount = activityCount
    }

    public var isEmpty: Bool { rows.isEmpty }
}

/// Window resolution + computation for the `dit pnl` command. Pure
/// functions over (ledger + market store), no network, no state.
public enum PnLWindow {

    // MARK: Window resolution

    /// Resolve the report window. One rule for every mode: the window
    /// is the inclusive span of UTC days, and the P&L it reports is
    /// "between the close before the first day and the close of the
    /// last day". Horizon tokens: `Nd`, `Nw`, `Nm`, `Ny` (N ≥ 1,
    /// calendar units ending at `to`) and `ytd`.
    ///
    /// - `--horizon H`: window (shift(H, from=to), to], e.g. `5d`
    ///   ending 2026-09-30 → 2026-09-26 … 2026-09-30 (5 days).
    /// - explicit `--from/--to`: exactly those days, inclusive.
    /// - neither: the FULL ledger — from the earliest transaction date
    ///   (or `to` when the ledger is empty).
    /// - `--to` alone: from the earliest transaction date to `to`.
    ///
    /// Throws ``WindowError`` for malformed tokens and reversed ranges
    /// — the CLI maps them to usage errors; nothing is silently
    /// clamped or widened.
    public enum WindowError: Error, CustomStringConvertible {
        case badHorizon(String)
        case reversed(from: String, to: String)

        public var description: String {
            switch self {
            case .badHorizon(let token):
                return "unknown horizon '\(token)' — use Nd/Nw/Nm/Ny (e.g. 5d, 2w, 3m, 1y) or 'ytd'"
            case .reversed(let from, let to):
                return "--to '\(to)' is before --from '\(from)' — the window runs empty; swap them"
            }
        }
    }

    /// The INCLUSIVE first day of a horizon window ending at `to`.
    /// Days/weeks are day counts (`5d` = five days, today included);
    /// months/years are calendar shifts (1m back from Sep 30 lands
    /// Aug 31 — one full calendar month to the last day, no hardcoded
    /// 30). Malformed tokens throw — a typo'd horizon must error,
    /// never silently report a different period.
    static func shiftBack(_ token: String, to: Date) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func shifted(_ component: Calendar.Component, _ value: Int) -> Date? {
            calendar.date(byAdding: component, value: value, to: to)
                .map { utcDay($0) }
        }
        let lowered = token.lowercased()
        if lowered == "ytd" {
            let year = calendar.component(.year, from: to)
            var components = DateComponents()
            components.year = year
            components.month = 1
            components.day = 1
            return calendar.date(from: components) ?? to
        }
        let digits = token.prefix { $0.isNumber }
        let unit = String(token.dropFirst(digits.count)).lowercased()
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits), n >= 1, n <= 999,
              ["d", "w", "m", "y"].contains(unit) else {
            throw WindowError.badHorizon(token)
        }
        switch unit {
        case "d":
            return shifted(.day, -(n - 1)) ?? to
        case "w":
            return shifted(.day, -(7 * n - 1)) ?? to
        case "m":
            // Calendar shift by n months, then one day forward so the
            // span covers exactly n calendar months ending at `to`.
            guard let monthShift = calendar.date(byAdding: .month, value: -n, to: to),
                  let start = calendar.date(byAdding: .day, value: 1, to: monthShift) else {
                throw WindowError.badHorizon(token)
            }
            return utcDay(start)
        default:
            guard let yearShift = calendar.date(byAdding: .year, value: -n, to: to),
                  let start = calendar.date(byAdding: .day, value: 1, to: yearShift) else {
                throw WindowError.badHorizon(token)
            }
            return utcDay(start)
        }
    }

    /// Build the window from user input. `horizon` and explicit dates
    /// are mutually exclusive — the CLI enforces that; here an
    /// unexpected horizon wins (defensive, never silent).
    public static func resolveWindow(horizon: String?, from explicitFrom: Date?,
                                     to explicitTo: Date?, now: Date,
                                     ledgerStart: Date?) throws -> PnLReport.Window {
        let to = explicitTo.map(utcDay) ?? utcDay(now)
        if let horizon {
            // One rule for every horizon: shiftBack already names the
            // first day INSIDE the window (inclusive through `to`).
            let start = try shiftBack(horizon, to: to)
            return PnLReport.Window(start: start, end: to, label: horizon.lowercased(),
                                    fromLedgerStart: false)
        }
        if let explicitFrom {
            let from = utcDay(explicitFrom)
            if to < from {
                throw WindowError.reversed(from: TextFormat.day(from), to: TextFormat.day(to))
            }
            return PnLReport.Window(start: from, end: to, label: "custom", fromLedgerStart: false)
        }
        // Full time series (or --to alone): start at the ledger's
        // first transaction. No baseline prices are needed (nothing
        // was held before the first trade), so this window computes
        // exactly whenever end prices exist.
        if let ledgerStart {
            return PnLReport.Window(start: utcDay(ledgerStart), end: to, label: "full history",
                                    fromLedgerStart: true)
        }
        return PnLReport.Window(start: to, end: to, label: "full history", fromLedgerStart: true)
    }

    // MARK: Computation

    /// Compute the window report.
    ///
    /// - Parameters:
    ///   - portfolio: ledger source.
    ///   - window: inclusive day range (start may be ledger start).
    ///   - accounts: scope (resolved by the CLI). Portfolio-level calls
    ///     pass ALL accounts and `perAccount: false`.
    ///   - perAccount: keep rows keyed per account.
    ///   - symbols: optional ticker whitelist (normalized, uppercase).
    ///   - currencies: optional currency whitelist (rows outside are
    ///     dropped entirely — filter, not display option).
    ///   - reportingCurrency: currency for the combined total.
    ///   - market: stored daily closes + latest rates (`nil` = no
    ///     market data: the report degrades to realized-only).
    ///   - rate: converter `rate(from, to)` for the combined total
    ///     (`nil` = never convert, per-currency totals stay native).
    public static func compute(portfolio: Portfolio,
                               window: PnLReport.Window,
                               accounts: [Account],
                               perAccount: Bool,
                               symbols: Set<String>?,
                               currencies: Set<Currency>?,
                               reportingCurrency: Currency,
                               market: MarketData?,
                               rate: FXRate?) -> PnLReport {
        var notes: [String] = []
        var shortFlags: [(accountName: String, symbol: String, currency: Currency, shares: Decimal)] = []
        var raw: [Raw] = []
        var activity = 0
        /// Symbols in scope whose drift could not be measured (no
        /// usable series at a needed boundary) — reported in the
        /// footnotes, never hidden.
        var unmeasured = Set<String>()

        for account in accounts {
            let history = Replay.ordered(portfolio.transactions(in: account.id))
            guard !history.isEmpty else { continue }
            let inWindow = history.filter { utcDay($0.date) >= window.start && utcDay($0.date) <= window.end }
            activity += inWindow.count

            // MARK: two replays — boundary snapshots
            // "before" replays everything strictly before the window;
            // "after" replays everything through the window end. Both
            // share the prefix, so the DIFFERENCE of their realized
            // totals is exactly what the window booked (reconciles
            // with AccountBalances.compute by construction).
            var before = State()
            var after = State()
            for tx in history {
                let day = utcDay(tx.date)
                if day < window.start { apply(tx, to: &before) }
                if day <= window.end { apply(tx, to: &after) }
            }

            // MARK: candidate lines (positions at either boundary, or
            // income booked inside — dividends included without a position)
            var keys = Set(before.positions.filter { $0.value.shares != 0 || $0.value.cost != 0 }.map(\.key))
            keys.formUnion(after.positions.filter { $0.value.shares != 0 || $0.value.cost != 0 }.map(\.key))
            keys.formUnion(before.realized.keys)
            keys.formUnion(after.realized.keys)

            for key in keys {
                if let only = symbols, !key.symbol.hasPrefix("GIC:"), !only.contains(key.symbol) { continue }
                if let only = currencies, !only.contains(key.currency) { continue }
                let open = before.positions[key] ?? (shares: 0, cost: 0)
                let close = after.positions[key] ?? (shares: 0, cost: 0)
                let booked = (after.realized[key] ?? 0) - (before.realized[key] ?? 0)

                // MARK: position change (mark-to-mark across the window)
                var change: Decimal? = 0
                var derived = false
                let priced = !key.symbol.hasPrefix("GIC:") // GIC P&L is fully booked at redemption
                if priced {
                    // No boundary position (a dividend paid while flat,
                    // a ticker born AND closed inside the window) is
                    // fully determined by the ledger — no price pair is
                    // ever needed for it.
                    let noBoundary = open.shares == 0 && close.shares == 0
                    // A series stored in a different currency than the
                    // position is NOT used — money never converts by
                    // accident here (the FX honesty rules).
                    // Series currency: an exact match is trusted; an
                    // UNLABELLED series (currency unknown — plain
                    // "SYMBOL,DATE,PRICE" imports carry no currency) is
                    // taken at face value as quoted IN the position's
                    // currency, because that is what a user pasting
                    // closes for their own holding means. A series
                    // explicitly in a DIFFERENT currency is never used —
                    // it is a different instrument, and mixing them
                    // would be a silent FX error.
                    let seriesUsable = market?.series[key.symbol].map { $0.currency == key.currency || $0.currency == .unknown } ?? false
                    guard noBoundary || seriesUsable else {
                        if open.shares != 0 || close.shares != 0 { unmeasured.insert(key.symbol) }
                        if booked != 0 {
                            // Ledger fact without market context: show
                            // the realized number, withhold the total.
                            raw.append(Raw(symbol: key.symbol, isCashPnL: false,
                                           accountName: account.displayName,
                                           currency: key.currency, realized: booked, change: nil,
                                           derived: false))
                        }
                        continue
                    }
                    var openMark: Decimal = 0
                    var closeMark: Decimal = 0
                    if !noBoundary, open.shares > 0 {
                        if let baseline = market?.point(strictlyBefore: window.start, for: key.symbol) {
                            openMark = open.shares * baseline.price - open.cost
                            if baseline.via != nil { derived = true }
                        } else {
                            change = nil
                        }
                    }
                    if change != nil, !noBoundary, close.shares > 0 {
                        if let last = market?.point(onOrBefore: window.end, for: key.symbol) {
                            closeMark = close.shares * last.price - close.cost
                            if last.via != nil { derived = true }
                        } else {
                            change = nil
                        }
                    }
                    if change != nil {
                        change = closeMark - openMark
                    }
                }
                if change == nil, booked == 0 {
                    // Quiet and unmeasurable: no row (nothing to say),
                    // but the symbol stays on the unmeasured list.
                    if open.shares != 0 || close.shares != 0 { unmeasured.insert(key.symbol) }
                    continue
                }

                // Only emit rows that actually say something: booked
                // facts, or measurable drift. Quiet zero-drift positions
                // stay out of the table.
                guard booked != 0 || change.map({ $0 != 0 }) == true else { continue }
                raw.append(Raw(symbol: key.symbol, isCashPnL: !priced, accountName: account.displayName,
                               currency: key.currency, realized: booked, change: change,
                               derived: derived))
            }

            // Untracked shorts CREATED inside the window (diff of the
            // boundary snapshots; carried shorts are not window news).
            for (key, shares) in after.shorts {
                let grew = shares - (before.shorts[key] ?? 0)
                guard grew > 0 else { continue }
                if let only = symbols, !only.contains(key.symbol) { continue }
                if let only = currencies, !only.contains(key.currency) { continue }
                shortFlags.append((account.displayName, key.symbol, key.currency, grew))
            }
        }

        // MARK: rows
        var rows: [PnLRow]
        if perAccount {
            rows = raw.map { item in
                PnLRow(symbol: item.symbol, isCashPnL: item.isCashPnL, accountNames: [item.accountName],
                       currency: item.currency, realized: item.realized,
                       positionChange: item.change,
                       total: item.change.map { item.realized + $0 },
                       usedDerivedHistory: item.derived)
            }
        } else {
            var groups: [String: (symbol: String, isCashPnL: Bool, accounts: [String],
                                  currency: Currency, realized: Decimal, change: Decimal?,
                                  derived: Bool)] = [:]
            for item in raw {
                let id = "\(item.currency.rawValue)|\(item.symbol)"
                var entry = groups[id] ?? (item.symbol, item.isCashPnL, [], item.currency, 0, 0, false)
                entry.accounts.append(item.accountName)
                entry.realized += item.realized
                if let change = item.change { entry.change = (entry.change ?? 0) + change }
                else { entry.change = nil }
                entry.derived = entry.derived || item.derived
                groups[id] = entry
            }
            rows = groups.values.map { entry in
                PnLRow(symbol: entry.symbol, isCashPnL: entry.isCashPnL,
                       accountNames: Array(Set(entry.accounts)).sorted(),
                       currency: entry.currency, realized: entry.realized,
                       positionChange: entry.change,
                       total: entry.change.map { entry.realized + $0 },
                       usedDerivedHistory: entry.derived)
            }
        }
        rows.sort { ($0.currency.rawValue, $0.symbol) < ($1.currency.rawValue, $1.symbol) }

        // MARK: per-currency totals
        var grouped: [Currency: (realized: Decimal, change: Decimal, complete: Bool, incomplete: Int)] = [:]
        for row in rows {
            var entry = grouped[row.currency] ?? (0, 0, true, 0)
            entry.realized += row.realized
            if let change = row.positionChange {
                entry.change += change
            } else if !row.isCashPnL {
                entry.complete = false
                entry.incomplete += 1
            }
            grouped[row.currency] = entry
        }
        let perCurrency = grouped.map { currency, entry in
            CurrencyPnL(currency: currency, realized: entry.realized,
                        positionChange: entry.complete ? entry.change : nil,
                        total: entry.complete ? entry.realized + entry.change : nil,
                        incompletePositions: entry.incomplete)
        }.sorted { $0.currency.rawValue < $1.currency.rawValue }

        // MARK: combined total in the reporting currency
        var combined: Decimal? = 0
        var used: [(from: Currency, to: Currency, rate: Decimal)] = []
        var unconverted: [Currency] = []
        var withheld: [Currency] = []
        for total in perCurrency {
            guard let amount = total.total else {
                withheld.append(total.currency)
                combined = nil
                continue
            }
            if total.currency == reportingCurrency { combined = (combined ?? 0) + amount; continue }
            guard let rate, let value = rate(total.currency, reportingCurrency) else {
                withheld.append(total.currency)
                unconverted.append(total.currency)
                combined = nil
                continue
            }
            combined = (combined ?? 0) + amount * value
            used.append((total.currency, reportingCurrency, value))
        }

        // MARK: notes (label what the numbers cannot say)
        let dashed = Set(rows.filter { $0.positionChange == nil && !$0.isCashPnL }.map(\.symbol))
        let unmeasuredList = dashed.union(unmeasured).sorted()
        if !unmeasuredList.isEmpty {
            notes.append("no usable daily history for: \(unmeasuredList.joined(separator: ", ")) — rows"
                + " involving those symbols carry dashed Position Δ/Total (quiet ones are left out of"
                + " the table entirely); fill the store with 'dit market history --all'. Withheld"
                + " totals are never guessed — and drop out of the combined total")
        }
        let proxy = Array(Set(rows.filter(\.usedDerivedHistory).map(\.symbol))).sorted()
        if !proxy.isEmpty {
            notes.append("position changes marked * used DERIVED proxy history (\(proxy.joined(separator: ", ")))"
                + " — approximations, not quotes")
        }
        notes.append(contentsOf: shortFlags.map { flag in
            "untracked short: \(flag.accountName) sold \(TextFormat.quantity(flag.shares)) \(flag.symbol)"
                + " (\(flag.currency.rawValue)) beyond its holding — the short itself is not tracked,"
                + " totals for its window are incomplete"
        })
        if !unconverted.isEmpty {
            notes.append("not converted: no stored rate for "
                + unconverted.map { "\($0.rawValue)→\(reportingCurrency.rawValue)" }.joined(separator: ", ")
                + " — combined total withheld, per-currency totals stay exact")
        }
        return PnLReport(window: window, perAccount: perAccount, rows: rows,
                         perCurrency: perCurrency, reportingCurrency: reportingCurrency,
                         combinedTotal: combined, conversionUsed: used,
                         unconvertedCurrencies: unconverted, incompleteCurrencies: withheld,
                         untrackedShorts: shortFlags, notes: notes, activityCount: activity)
    }

    // MARK: Replay internals

    /// Boundary state of the ledger. The rules are kept literally
    /// parallel to ``AccountBalances/compute(account:transactions:rate:lastPrice:dayPrices:)``
    /// — same average-cost math, same fees-in-cost rule, same
    /// "redemption without purchase is skipped" honesty.
    private struct State {
        var positions: [PositionKey: (shares: Decimal, cost: Decimal)] = [:]
        var realized: [PositionKey: Decimal] = [:]
        var shorts: [PositionKey: Decimal] = [:]
        var gics: [UUID: (key: PositionKey, principal: Decimal)] = [:]
    }

    private static func apply(_ tx: Transaction, to state: inout State) {
        switch tx.kind {
        case .stockPurchase(let details):
            let key = PositionKey(currency: tx.currency, symbol: details.ticker)
            let current = state.positions[key] ?? (shares: 0, cost: 0)
            state.positions[key] = (current.shares + details.shares,
                                    current.cost + details.amount + (tx.fee ?? 0))
        case .stockSale(let details):
            let key = PositionKey(currency: tx.currency, symbol: details.ticker)
            let current = state.positions[key] ?? (shares: 0, cost: 0)
            let costOfSharesSold: Decimal
            if current.shares > 0, details.shares >= current.shares {
                costOfSharesSold = current.cost // full liquidation: exact
            } else if current.shares > 0 {
                costOfSharesSold = current.cost * details.shares / current.shares
            } else {
                costOfSharesSold = 0 // sale with no tracked position
            }
            state.realized[key, default: 0] += (details.amount - (tx.fee ?? 0)) - costOfSharesSold
            if details.shares > max(0, current.shares) {
                state.shorts[key, default: 0] += details.shares - max(0, current.shares)
            }
            state.positions[key] = (max(0, current.shares - details.shares),
                                    max(0, current.cost - costOfSharesSold))
        case .gicPurchase(let details):
            state.gics[tx.id] = (PositionKey(currency: tx.currency, symbol: "GIC: " + details.product),
                                 details.principal)
        case .gicRedemption(let details):
            // Same rule as compute: a redemption without its purchase
            // in the history is SKIPPED — inventing a principal would
            // fabricate P&L.
            if let gic = state.gics.removeValue(forKey: details.purchaseID) {
                state.realized[gic.key, default: 0] += (details.proceeds - (tx.fee ?? 0)) - gic.principal
            }
        case .dividend(let details):
            let key = PositionKey(currency: tx.currency, symbol: details.ticker)
            state.realized[key, default: 0] += details.amount - (tx.fee ?? 0)
        default:
            // deposit / withdrawal / fxConversion: cash movement, never P&L.
            break
        }
    }

    // MARK: UTC day helpers (the ruler every boundary is measured on)

    /// The UTC-midnight day containing `date`.
    static func utcDay(_ date: Date) -> Date {
        DailyPrice.utcDay(date)
    }

    /// `date` shifted by whole UTC days (negative = earlier).
    static func addDays(_ date: Date, _ days: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// A line under construction (per account, per key) before rows
    /// are grouped for the requested scope.
    private struct Raw {
        var symbol: String
        var isCashPnL: Bool
        var accountName: String
        var currency: Currency
        var realized: Decimal
        var change: Decimal?
        var derived: Bool
    }
}