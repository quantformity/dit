import Foundation

// MARK: - Market coverage audit (the `dit market coverage` view)
//
// One question, answered offline: "for what my ledger holds, what
// does the market store KNOW — and where would a historical report
// have to dash?" Deliberately NOT a second financial model: it reads
// the same sources the reporting views read (daily symbol series for
// prices, FXClock chains for conversions) and states facts only —
// no valuations, no percentages, no fabricated denominators.
//
// Honesty rules:
// - A series stored in a DIFFERENT currency than the position is
//   NEVER usable (the summary and P&L views refuse it). Coverage
//   must say so out loud — a green check on data that will never be
//   read is a lie of a different colour.
// - Missing days are only gaps when they are long (≥ 10): weekday-
//   sampled series always lack weekends, and holiday clusters run to
//   8-9 days. Anything shorter is calendar dust, not a hole.
// - FX coverage is the CHAIN (direct pair, inverted twin, USD
//   triangulation) plus whether it is FRESH ENOUGH TO USE at each
//   reporting boundary. A chain of 8-month-old legs EXISTS but
//   converts NOTHING honestly (the FX clock refuses it) — reported
//   as stale, never as covered.
// - Only what the ledger actually holds is checked; a missing series
//   nobody needs is not a gap, and is never listed.

/// Coverage facts for one held instrument, per recorded currency (the
/// same ticker held in USD and CAD needs two different series).
public struct SymbolCoverage: Sendable {
    public let symbol: String
    /// Currency the position is RECORDED in.
    public let currency: Currency
    /// Accounts currently holding it (sorted).
    public let accounts: [String]

    /// true when SOME series exists under this symbol.
    public let seriesFound: Bool
    /// Series currency label (`.unknown` = an unlabelled import,
    /// which the reporting views take at face value for the
    /// position's currency). nil when no series exists.
    public let seriesCurrency: Currency?
    /// true when the series COULD be read for this position: same
    /// currency or unlabelled. A mismatch is a stated fact, not a
    /// silent exclusion.
    public let usableSource: Bool
    /// true when any in-window point carries a derivation label
    /// (proxy/backfill history — approximations, not quotes).
    public let derived: Bool
    /// Stored closes inside the checked window.
    public let pointsInWindow: Int
    /// First and last in-window close (nil when none).
    public let windowRange: (first: Date, last: Date)?
    /// Last close at or before the checked day — may predate the
    /// window (a series that stopped long ago).
    public let lastClose: Date?
    /// Full stored series range (may lie entirely outside the window
    /// — "the series exists but starts DATE" is a stated fact).
    public let seriesRange: (first: Date, last: Date)?
    /// Days between `lastClose` and the checked day (0 = a close ON
    /// the checked day exists). nil = nothing stored at or before it.
    public let staleDays: Int?
    /// Longest run of missing days inside the window, reported only
    /// when ≥ 10 days (weekend/holiday dust stays silent).
    public let longestGap: (days: Int, from: Date, to: Date)?

    /// true when this position's price situation is NOT a hard gap:
    /// a usable series exists. (Staleness and gaps are separate,
    /// softer facts; `false` here means drift and P&L dash for this
    /// symbol at every boundary, by the reporting views' own rules.)
    public var measurable: Bool { seriesFound && usableSource }

    public init(symbol: String, currency: Currency, accounts: [String],
                seriesFound: Bool, seriesCurrency: Currency?, usableSource: Bool,
                derived: Bool, pointsInWindow: Int, windowRange: (first: Date, last: Date)?,
                lastClose: Date?, seriesRange: (first: Date, last: Date)?,
                staleDays: Int?, longestGap: (days: Int, from: Date, to: Date)?) {
        self.symbol = symbol
        self.currency = currency
        self.accounts = accounts
        self.seriesFound = seriesFound
        self.seriesCurrency = seriesCurrency
        self.usableSource = usableSource
        self.derived = derived
        self.pointsInWindow = pointsInWindow
        self.windowRange = windowRange
        self.lastClose = lastClose
        self.seriesRange = seriesRange
        self.staleDays = staleDays
        self.longestGap = longestGap
    }
}

/// Coverage facts for one FX chain a foreign-currency amount would
/// need to combine into the reporting currency.
public struct FXChainCoverage: Sendable {
    public let from: Currency
    public let to: Currency
    /// How the chain composes from stored data at all (direct pair /
    /// inverted twin / USD cross), however old — nil when NO path
    /// exists ("no chain", not "a stale one").
    public let chainLabel: String?
    /// true when the FX clock would ANSWER right now at the checked
    /// day (chain exists AND every leg is within the staleness limit)
    /// — the strict "would a conversion succeed" flag.
    public let usableNow: Bool
    /// Newest stored close anywhere along the chain, however old
    /// (nil = no pair data stored at all).
    public let lastAsOf: Date?
    /// Days between `lastAsOf` and the checked day.
    public let staleDays: Int?
    /// Reporting boundaries checked for convertibility (the period
    /// ends the P&L time-series WOULD use for this window).
    public let boundariesTotal: Int
    /// Boundaries where NO chain could supply a rate — each one
    /// makes that period's converted column dash.
    public let boundariesMissing: Int
    /// Earliest missing boundary (for the printout).
    public let missingExample: Date?

    public init(from: Currency, to: Currency, chainLabel: String?, usableNow: Bool,
                lastAsOf: Date?, staleDays: Int?, boundariesTotal: Int,
                boundariesMissing: Int, missingExample: Date?) {
        self.from = from
        self.to = to
        self.chainLabel = chainLabel
        self.usableNow = usableNow
        self.lastAsOf = lastAsOf
        self.staleDays = staleDays
        self.boundariesTotal = boundariesTotal
        self.boundariesMissing = boundariesMissing
        self.missingExample = missingExample
    }
}

/// The whole audit: one row per held instrument, one per needed FX
/// chain, plus the window it was checked over.
public struct CoverageReport: Sendable {
    /// The day freshness is measured against (usually "today").
    public let asOf: Date
    /// Inclusive start of the window gaps/convertibility were checked.
    public let windowStart: Date
    /// The slicing `--time-series` would use for this window (echoed
    /// so the FX boundary counts read honestly).
    public let seriesGranularity: SeriesGranularity
    public let symbols: [SymbolCoverage]
    public let fx: [FXChainCoverage]

    /// true when every symbol has usable, audit-date-current data
    /// and every needed FX chain answers at the audit date AND at
    /// every period end. `--strict` exits 1 when this is false.
    public var complete: Bool {
        symbols.allSatisfy { $0.measurable && ($0.staleDays.map { $0 <= 7 } ?? false) }
            && fx.allSatisfy { $0.usableNow && $0.boundariesMissing == 0 }
    }

    public init(asOf: Date, windowStart: Date, seriesGranularity: SeriesGranularity,
                symbols: [SymbolCoverage], fx: [FXChainCoverage]) {
        self.asOf = asOf
        self.windowStart = windowStart
        self.seriesGranularity = seriesGranularity
        self.symbols = symbols
        self.fx = fx
    }

    public var isEmpty: Bool { symbols.isEmpty && fx.isEmpty }
}

extension Transaction {
    /// The ticker this event references (nil for cash-only events).
    var referencedTicker: String? {
        switch kind {
        case .stockPurchase(let details), .stockSale(let details): return details.ticker
        case .dividend(let details): return details.ticker
        default: return nil
        }
    }
}

/// Pure coverage computation over (ledger + stored market data). No
/// network, no valuations — the same sources the reports read,
/// audited.
public enum MarketCoverage {

    /// Missing-day runs shorter than this are calendar dust
    /// (weekends ≤ 3, holiday clusters ≤ 9 in weekday-sampled data).
    public static let gapReportLimitDays = 10

    /// Audit what the market store knows for what the accounts hold.
    ///
    /// - Parameters:
    ///   - portfolio: ledger source (holdings replayed up to `asOf`).
    ///   - accounts: scope (resolved by the CLI).
    ///   - asOf: the day freshness is measured against.
    ///   - windowStart: gap window start (nil = the ledger's first
    ///     transaction — the whole span someone could report over).
    ///   - reportingCurrency: conversions are checked toward this.
    ///   - market: stored data (`nil` = empty store: every row then
    ///     honestly reports the absence).
    public static func report(portfolio: Portfolio,
                              accounts: [Account],
                              asOf: Date,
                              windowStart: Date?,
                              reportingCurrency: Currency,
                              market: MarketData?) -> CoverageReport {
        let asOfDay = DailyPrice.utcDay(asOf)

        // MARK: what the ledger holds at the checked day (replay of
        // transactions ≤ asOf through the EXACT AccountBalances rules
        // — coverage asks what valuation and P&L need, never a
        // private notion of "held").
        var holders: [String: [(account: String, currency: Currency)]] = [:]
        var currencies = Set<Currency>()
        for account in accounts {
            let history = portfolio.transactions(in: account.id)
                .filter { DailyPrice.utcDay($0.date) <= asOfDay }
            let balances = AccountBalances.compute(account: account, transactions: history)
            for position in balances.positions where position.shares != 0 {
                holders[position.symbol, default: []]
                    .append((account.displayName, position.currency))
                currencies.insert(position.currency)
            }
            for (currency, amount) in balances.cashByCurrency where amount != 0 {
                currencies.insert(currency)
            }
            for (currency, amount) in balances.gicValueByCurrency where amount != 0 {
                currencies.insert(currency)
            }
        }

        // Default gap window: the whole ledger history up to the
        // checked day (a hole anywhere in the years someone reports
        // over matters; --from narrows it). Each ROW then checks
        // from when ITS data was first needed — the day the ledger
        // first referenced that symbol/currency — because data
        // before anyone traded is nobody's gap.
        let ledgerStart = portfolio.transactions
            .filter { DailyPrice.utcDay($0.date) <= asOfDay }
            .map { DailyPrice.utcDay($0.date) }
            .min() ?? asOfDay
        let windowStart = min(windowStart.map(DailyPrice.utcDay) ?? ledgerStart, asOfDay)
        let window = PnLReport.Window(start: windowStart, end: asOfDay, label: "coverage")
        let granularity = PnLWindow.autoGranularity(window: window)
        let scopedAccounts = Set(accounts.map(\.id))
        let scopedTransactions = portfolio.transactions
            .filter { scopedAccounts.contains($0.accountID)
                && DailyPrice.utcDay($0.date) <= asOfDay
                && DailyPrice.utcDay($0.date) >= windowStart }
        // Which currencies a referenced symbol is held in (a USD
        // dividend on a USD position needs the USD chain too).
        let currencyOfSymbol: [String: Set<Currency>] = Dictionary(
            uniqueKeysWithValues: holders.map { symbol, entries in
                (symbol, Set(entries.map(\.currency)))
            })

        // MARK: symbol rows — one per (symbol, recorded currency)
        var symbolRows: [SymbolCoverage] = []
        for (symbol, entries) in holders.sorted(by: { $0.key < $1.key }) {
            // Data has been needed since the FIRST ledger event
            // referencing the symbol (buy, sell, or dividend).
            let needStart = scopedTransactions
                .filter { $0.referencedTicker == symbol }
                .map { DailyPrice.utcDay($0.date) }
                .min() ?? windowStart
            for (currency, owners) in Dictionary(grouping: entries, by: \.currency)
                .sorted(by: { $0.key.rawValue < $1.key.rawValue })
            {
                let accountNames = owners.map(\.account).sorted()
                guard let series = market?.series[symbol], !series.points.isEmpty else {
                    symbolRows.append(SymbolCoverage(
                        symbol: symbol, currency: currency, accounts: accountNames,
                        seriesFound: false, seriesCurrency: nil, usableSource: false,
                        derived: false, pointsInWindow: 0, windowRange: nil,
                        lastClose: nil, seriesRange: nil, staleDays: nil, longestGap: nil))
                    continue
                }
                let usable = series.currency == currency || series.currency == .unknown
                let inWindow = series.points.filter { $0.day >= needStart && $0.day <= asOfDay }
                let last = series.points.last { $0.day <= asOfDay }
                symbolRows.append(SymbolCoverage(
                    symbol: symbol, currency: currency, accounts: accountNames,
                    seriesFound: true, seriesCurrency: series.currency,
                    usableSource: usable,
                    derived: inWindow.contains { $0.via != nil },
                    pointsInWindow: inWindow.count,
                    windowRange: inWindow.first.map { first in
                        (first.day, inWindow[inWindow.count - 1].day)
                    },
                    lastClose: last?.day,
                    seriesRange: (series.points.first!.day, series.points.last!.day),
                    staleDays: last.map { PnLWindow.utcDaydiff($0.day, asOfDay) },
                    longestGap: usable
                        ? longestGap(days: Set(series.points.map(\.day)),
                                     from: needStart, to: asOfDay)
                        : nil))
            }
        }

        // MARK: FX chain rows — only for currencies the scope USES
        // (a chain nobody needs is nobody's gap). Freshness uses the
        // SAME rule the reports use: FXClock, 7-day limit.
        let clock = FXClock(series: market?.series ?? [:])
        let deep = FXClock(series: market?.series ?? [:], maxStalenessDays: 36_500)
        let boundaries = PnLWindow.seriesBuckets(window: window, granularity: granularity)
            .map(\.end)
        var fxRows: [FXChainCoverage] = []
        for currency in currencies.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard currency != reportingCurrency, currency != .unknown,
                  reportingCurrency != .unknown else { continue }
            // Conversion has been needed since the first ledger event
            // EXPRESSED in this currency (before that there was
            // nothing to convert, so earlier dark stretches are not
            // this portfolio's gap).
            let needStart = scopedTransactions
                .filter { tx in
                    tx.currency == currency
                        || currencyOfSymbol[tx.referencedTicker ?? ""]?.contains(currency) == true
                }
                .map { DailyPrice.utcDay($0.date) }
                .min() ?? asOfDay
            // The deep clock answers "does ANY chain exist at all,
            // however old"; the fresh clock answers "would it be
            // used". Both facts print — they lead to different
            // remedies (import a pair vs fill a range).
            let deepest = deep.quote(from: currency, to: reportingCurrency, on: asOfDay)
            let rowBoundaries = boundaries.filter { $0 >= needStart }
            var missing = 0
            var example: Date?
            for boundary in rowBoundaries
            where clock.quote(from: currency, to: reportingCurrency, on: boundary) == nil {
                missing += 1
                if example == nil { example = boundary }
            }
            fxRows.append(FXChainCoverage(
                from: currency, to: reportingCurrency,
                chainLabel: deepest.map { d in
                    d.via ?? "\(currency.rawValue)/\(reportingCurrency.rawValue) direct"
                },
                usableNow: clock.quote(from: currency, to: reportingCurrency,
                                       on: asOfDay) != nil,
                lastAsOf: deepest?.asOf,
                staleDays: deepest.map { PnLWindow.utcDaydiff($0.asOf, asOfDay) },
                boundariesTotal: rowBoundaries.count,
                boundariesMissing: missing,
                missingExample: example))
        }

        return CoverageReport(asOf: asOfDay, windowStart: windowStart,
                              seriesGranularity: granularity,
                              symbols: symbolRows, fx: fxRows)
    }

    /// Longest run of days WITHOUT a stored close inside the window
    /// (inclusive), reported only when ≥ `gapReportLimitDays`. A run
    /// reaching the window end is staleness territory (reported via
    /// `staleDays`), unless the whole window is dark — which is a
    /// gap, not staleness: there would have been NO price anywhere
    /// in it.
    static func longestGap(days: Set<Date>, from: Date, to: Date)
        -> (days: Int, from: Date, to: Date)? {
        let total = PnLWindow.utcDaydiff(from, to) + 1
        guard total > gapReportLimitDays else { return nil }
        if days.isDisjoint(with: (0..<total).map { PnLWindow.addDays(from, $0) }) {
            return (total, from, to)   // fully dark window
        }
        var best: (days: Int, from: Date, to: Date)?
        var runStart: Date?
        var cursor = from
        func closeRun(before day: Date) {
            guard let start = runStart else { return }
            let length = PnLWindow.utcDaydiff(start, day)
            if best == nil || length > best!.days {
                best = (length, start, PnLWindow.addDays(day, -1))
            }
            runStart = nil
        }
        for _ in 0..<total {
            if !days.contains(cursor) {
                if runStart == nil { runStart = cursor }
            } else {
                closeRun(before: cursor)
            }
            cursor = PnLWindow.addDays(cursor, 1)
        }
        // A run still open at the window end is TRAILING darkness —
        // staleDays reports that; only fully-dark windows and runs
        // closed by later data are gaps here.
        guard let found = best, found.days >= gapReportLimitDays else { return nil }
        return found
    }
}