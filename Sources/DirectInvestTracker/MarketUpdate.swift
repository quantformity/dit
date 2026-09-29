import Foundation

// MARK: - Provider contract for daily data

/// One fetched end-of-day series (daily closes for a symbol or FX pair).
/// An empty `points` means "the provider knows nothing for this range"
/// — it is NOT a transport failure.
public struct DailySeries: Sendable {
    /// The provider-side ticker queried (e.g. "CAD=X"), for reporting.
    public let symbol: String
    public let currency: Currency
    public let points: [DailyPrice]

    public init(symbol: String, currency: Currency, points: [DailyPrice]) {
        self.symbol = symbol
        self.currency = currency
        self.points = points
    }
}

/// A market-data provider that can also answer "what were the daily
/// closes between two days?" — the fetch half of the market store.
///
/// `quotes`/`rate` are inherited from ``QuoteProvider``; the valuation
/// read path uses those, the `dit market` update commands use all
/// three. Providers skip unknown symbols by returning empty results;
/// they throw only for real failures (network down, malformed answer).
public protocol PriceDataProvider: QuoteProvider {
    /// Daily closes from `from` to `to`, inclusive. May be empty.
    func dailySeries(_ symbol: String, from: Date, to: Date) async throws -> DailySeries
}

// MARK: - Holding windows

/// An inclusive range of UTC days during which something was held.
public struct DayWindow: Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = DailyPrice.utcDay(start)
        self.end = DailyPrice.utcDay(end)
    }

    public func contains(_ day: Date) -> Bool {
        let day = DailyPrice.utcDay(day)
        return day >= start && day <= end
    }
}

extension Portfolio {
    /// The days each traded symbol was actually held, per symbol.
    ///
    /// Replays each account's ledger (the source of truth) and marks a
    /// day as held when the account held more than zero shares of the
    /// symbol at any point that day — the buy day counts, the
    /// sold-to-zero day still counts (the position existed that
    /// morning), and a symbol sold everywhere before the snapshot stops
    /// needing prices after that. A still-open position runs through
    /// `end`. Windows from several accounts are merged when they
    /// touch or overlap, so a symbol held in four accounts fetches one
    /// history, not four.
    ///
    /// This is what makes `dit market history` "only the asset I had a
    /// position in, on each day in history": a symbol held from 2025
    /// until May 2026 fetches nothing after May 2026, and a symbol
    /// never held fetches no history at all.
    public func holdingWindows(through end: Date) -> [String: [DayWindow]] {
        // Gather raw windows first (accounts are visited in storage
        // order, so they arrive out of chronological order), then sort
        // and merge — assuming chronological arrival would silently
        // swallow windows that begin before an already-recorded one.
        var raw: [String: [DayWindow]] = [:]

        func record(symbol: String, window: DayWindow) {
            raw[symbol, default: []].append(window)
        }

        let endDay = DailyPrice.utcDay(end)
        for account in accounts {
            // Per symbol: shares at the current point of the replay,
            // plus the day the currently-open holding window began.
            var state: [String: (shares: Decimal, open: Date?)] = [:]
            for tx in transactions(in: account.id).sorted(by: { $0.date < $1.date }) {
                switch tx.kind {
                case .stockPurchase(let details):
                    var entry = state[details.ticker] ?? (0, nil)
                    if entry.shares == 0 {
                        entry.open = DailyPrice.utcDay(tx.date)
                    }
                    entry.shares += details.shares
                    state[details.ticker] = entry
                case .stockSale(let details):
                    guard var entry = state[details.ticker], entry.shares > 0 else { continue }
                    entry.shares -= details.shares
                    if entry.shares <= 0, let openedDay = entry.open {
                        // Sold to zero (or beyond): held through the day
                        // of the sale, including a short beyond tracking.
                        record(symbol: details.ticker,
                               window: DayWindow(start: openedDay, end: DailyPrice.utcDay(tx.date)))
                        entry = (0, nil)
                    }
                    state[details.ticker] = entry
                default:
                    continue
                }
            }
            for (symbol, entry) in state where entry.shares > 0 {
                if let openedDay = entry.open {
                    record(symbol: symbol, window: DayWindow(start: openedDay, end: endDay))
                }
            }
        }

        // Sort + merge each symbol's windows: overlapping or touching
        // (within one day) windows become one fetch range.
        var result: [String: [DayWindow]] = [:]
        for (symbol, windows) in raw {
            var merged: [DayWindow] = []
            for window in windows.sorted(by: { $0.start < $1.start }) {
                if var last = merged.last, window.start <= last.end.addingTimeInterval(86_400) {
                    if window.end > last.end { last.end = window.end }
                    merged[merged.count - 1] = last
                } else {
                    merged.append(window)
                }
            }
            result[symbol] = merged
        }
        return result
    }
}

// MARK: - Update engine

/// The outcome of one market-store update run, as report lines plus
/// counters. The CLI prints it; tests assert on it.
public struct MarketUpdateReport: Sendable {
    public var lines: [String] = []
    /// Lookups that failed (no data or provider error) — reported, not
    /// hidden; a silent market store is a lying market store.
    public var failures: [String] = []
    /// Daily points written this run.
    public var pointsStored: Int = 0
    /// Series that needed no fetch at all (covered through their window).
    public var seriesSkipped: Int = 0
    /// Series that were fetched (whether or not new days resulted).
    public var seriesFetched: Int = 0
}

/// Fills the market store from a provider.
///
/// The two `dit market` commands live here:
/// - ``updateLatest(portfolio:displayCurrency:now:)`` — refresh the
///   one "latest" snapshot per held symbol and needed FX pair (the
///   store keeps only the latest of each);
/// - ``updateHistory(portfolio:displayCurrency:eraseFirst:today:)`` —
///   fill daily closes for the days each symbol was actually held,
///   fetching only what the store does not have yet; `eraseFirst`
///   implements the wipe-and-refill option.
///
/// The provider is injected, so the engine and its incremental rules
/// are testable without a network.
public struct MarketUpdater: Sendable {
    let provider: any PriceDataProvider
    let store: MarketStore

    public init(provider: any PriceDataProvider, store: MarketStore) {
        self.provider = provider
        self.store = store
    }

    // MARK: Latest

    /// Refresh the "latest price" section for everything the portfolio
    /// currently holds. No positions (or an empty portfolio) is a
    /// normal quiet no-op, not a failure.
    public func updateLatest(portfolio: Portfolio,
                             displayCurrency: Currency,
                             now: Date = .now) async throws -> MarketUpdateReport {
        var report = MarketUpdateReport()
        let plan = portfolio.marketDataPlan(displayCurrency: displayCurrency)
        guard !plan.symbols.isEmpty || !plan.fxCurrencies.isEmpty else {
            report.lines.append("no open positions and no foreign cash — nothing to update")
            return report
        }

        var data = try await store.load()
        data.updatedAt = now

        if !plan.symbols.isEmpty {
            let quotes = try await provider.quotes(for: plan.symbols)
            let found = Set(quotes.map(\.symbol))
            for missing in plan.symbols where !found.contains(missing) {
                report.failures.append("no quote: \(missing)")
            }
            for quote in quotes {
                data.replaceLatest(quote)
                let asOf = quote.asOf.map(Self.stamp) ?? "unknown time"
                report.lines.append("\(quote.symbol) \(Self.trim(quote.price)) \(quote.currency.rawValue) (as of \(asOf))")
            }
        }
        for currency in plan.fxCurrencies {
            do {
                let rate = try await provider.rate(from: plan.hub, to: currency)
                data.replaceLatest(rate)
                report.lines.append("\(plan.hub.rawValue)/\(currency.rawValue) \(Self.trim(rate.rate))")
            } catch {
                report.failures.append("\(plan.hub.rawValue)/\(currency.rawValue) rate failed: \(error)")
            }
        }
        try await store.save(data)
        return report
    }

    // MARK: History

    /// Fill the daily history, incrementally.
    ///
    /// For every symbol the ledger ever held, the engine computes the
    /// holding windows (``Portfolio/holdingWindows(through:)``) and
    /// asks the provider only for the range the coverage watermark has
    /// not verified yet — from the day after the watermark, starting at
    /// the first holding day for series never fetched before. A
    /// successful fetch advances the watermark even when it produced no
    /// new points, so holidays and no-data days are never re-requested.
    /// `eraseFirst` drops all stored series (watermarks included) —
    /// the wipe-and-refill option.
    public func updateHistory(portfolio: Portfolio,
                              displayCurrency: Currency,
                              eraseFirst: Bool = false,
                              today: Date = .now) async throws -> MarketUpdateReport {
        var report = MarketUpdateReport()
        var data = try await store.load()
        if eraseFirst {
            report.lines.append("erased stored history (\(data.series.count) series) — refetching everything")
            data.eraseSeries()
        }

        let todayDay = DailyPrice.utcDay(today)
        let windows = portfolio.holdingWindows(through: today)
        let plan = portfolio.marketDataPlan(displayCurrency: displayCurrency)
        guard !windows.isEmpty || !plan.fxCurrencies.isEmpty else {
            report.lines.append("nothing has ever been held — no history to fetch")
            return report
        }

        // --- equity series ---
        for symbol in windows.keys.sorted() {
            let symbolWindows = windows[symbol]!
            guard let windowStart = symbolWindows.map(\.start).min(),
                  var windowEnd = symbolWindows.map(\.end).max() else { continue }
            windowEnd = min(windowEnd, todayDay)

            let existing = data.series[symbol]
            let coveredThrough = existing?.coveredThrough
            let alreadyCovered = coveredThrough.map { $0 >= windowEnd } ?? false
            if alreadyCovered {
                report.seriesSkipped += 1
                report.lines.append("\(symbol): history complete through \(Self.stampDay(windowEnd)) — skipped")
                continue
            }

            // Fetch only what is behind no watermark: from the day
            // after it, or from the first holding day if never fetched.
            let fetchStart: Date
            if let coveredThrough {
                fetchStart = DailyPrice.utcDay(coveredThrough).addingTimeInterval(86_400)
            } else {
                fetchStart = windowStart
            }
            let fetchEnd = windowEnd
            guard fetchStart <= fetchEnd else {
                report.seriesSkipped += 1
                continue
            }

            do {
                report.seriesFetched += 1
                let fetched = try await provider.dailySeries(symbol, from: fetchStart, to: fetchEnd)
                // Keep only days inside a holding window — history for
                // days the symbol was not held is not "our" history.
                let inside = fetched.points.filter { point in
                    symbolWindows.contains { $0.contains(point.day) }
                }
                let added = data.mergeSeries(symbol: symbol, currency: fetched.currency,
                                             points: inside, through: fetchEnd)
                report.pointsStored += added
                if added == 0 {
                    report.lines.append("\(symbol): nothing new for \(Self.stampDay(fetchStart)) … \(Self.stampDay(fetchEnd)) (already covered, no data, or not held)")
                } else {
                    report.lines.append("\(symbol): +\(added) daily closes (\(Self.stampDay(fetchStart)) … \(Self.stampDay(fetchEnd)))")
                }
            } catch {
                report.failures.append("\(symbol): history fetch failed: \(error)")
            }
        }

        // --- FX pair history ---
        // A pair is filled from the first day any money existed in the
        // portfolio (the pair only ever serves valuation) through today.
        // Tail-filled: requests start one day past the watermark, and a
        // series is considered current when it reaches within three
        // days of today (weekends, and "yesterday's close is today's
        // best known rate").
        let earliestOverall = portfolio.transactions.map(\.date).min()
        for currency in plan.fxCurrencies {
            guard let pairTicker = plan.hub.quoteTicker(against: currency) else { continue }
            let pairKey = "\(plan.hub.rawValue)/\(currency.rawValue)"
            guard let start = earliestOverall else { continue }
            let existing = data.series[pairKey]
            if let lastDay = existing?.coveredThrough, lastDay >= todayDay.addingTimeInterval(-86_400 * 3) {
                report.seriesSkipped += 1
                report.lines.append("\(pairKey): history current through \(Self.stampDay(lastDay)) — skipped")
                continue
            }
            let fetchStart: Date
            if let covered = existing?.coveredThrough {
                fetchStart = DailyPrice.utcDay(covered).addingTimeInterval(86_400)
            } else {
                fetchStart = DailyPrice.utcDay(start)
            }
            guard fetchStart <= todayDay else { continue }
            do {
                report.seriesFetched += 1
                let fetched = try await provider.dailySeries(pairTicker, from: fetchStart, to: todayDay)
                let added = data.mergeSeries(symbol: pairKey, currency: currency,
                                             points: fetched.points, through: todayDay)
                report.pointsStored += added
                report.lines.append("\(pairKey): +\(added) daily rates (\(Self.stampDay(fetchStart)) … \(Self.stampDay(todayDay)))")
            } catch {
                report.failures.append("\(pairKey): history fetch failed: \(error)")
            }
        }

        data.updatedAt = today
        try await store.save(data)
        return report
    }

    // MARK: Helpers

    static func stamp(_ date: Date?) -> String {
        guard let date else { return "unknown time" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func stampDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func trim(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}
