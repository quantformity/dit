import XCTest
@testable import DirectInvestTracker

// MARK: - Test doubles

/// A scripted ``PriceDataProvider``: canned series, recorded requests.
/// Tests assert both outcomes (what got stored) and behaviour (which
/// ranges were ever fetched — the "fetch only what is missing" rule).
actor StubMarketProvider: PriceDataProvider {
    struct Request: Hashable {
        let symbol: String
        let from: Date
        let to: Date
    }

    private(set) var quoteRequests: [[String]] = []
    private(set) var rateRequests: [(Currency, Currency)] = []
    private(set) var seriesRequests: [Request] = []

    /// Canned latest prices; anything else is "no quote".
    var lastPrices: [String: (Decimal, Currency)] = [:]
    /// Canned daily closes per symbol, keyed by UTC day string.
    var daily: [String: [(String, Decimal)]] = [:]
    /// Symbols whose every lookup throws (transport failure simulation).
    var failing: Set<String> = []

    func quotes(for symbols: [String]) async throws -> [MarketQuote] {
        quoteRequests.append(symbols.sorted())
        return symbols.compactMap { (symbol: String) -> MarketQuote? in
            guard let (price, currency) = lastPrices[symbol] else { return nil }
            return MarketQuote(symbol: symbol, currency: currency, price: price,
                               asOf: Date(timeIntervalSince1970: 0), source: "stub")
        }
    }

    func rate(from: Currency, to: Currency) async throws -> ExchangeRate {
        rateRequests.append((from, to))
        return ExchangeRate(base: from, quote: to, rate: Decimal(string: "1.4")!,
                            asOf: Date(timeIntervalSince1970: 0),
                            source: "stub")
    }

    func dailySeries(_ symbol: String, from: Date, to: Date) async throws -> DailySeries {
        seriesRequests.append(.init(symbol: symbol, from: DailyPrice.utcDay(from),
                                    to: DailyPrice.utcDay(to)))
        guard !failing.contains(symbol) else {
            throw YahooQuoteError.network(message: "stub failure for \(symbol)")
        }
        let template = daily[symbol] ?? []
        let points: [DailyPrice] = template.compactMap { dayString, price in
            guard let day = Self.day(dayString) else { return nil }
            guard day >= DailyPrice.utcDay(from), day <= DailyPrice.utcDay(to) else { return nil }
            return DailyPrice(day: day, price: price)
        }
        return DailySeries(symbol: symbol, currency: .usd, points: points)
    }

    static func day(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }
}

// MARK: - Store layer

final class MarketStoreTests: XCTestCase {

    private func makeStore() -> MarketStore {
        MarketStore(store: MemoryDataStore())
    }

    func testRoundTripThroughBackend() async throws {
        let store = makeStore()
        var data = MarketData()
        data.replaceLatest(MarketQuote(symbol: "AAPL", currency: .usd, price: 250,
                                       asOf: Date(timeIntervalSince1970: 100), source: "stub"))
        data.replaceLatest(ExchangeRate(base: .usd, quote: .cad, rate: Decimal(string: "1.37")!,
                                        asOf: nil, source: "stub"))
        data.mergeSeries(symbol: "AAPL", currency: .usd, points: [
            DailyPrice(day: StubMarketProvider.day("2026-01-05")!, price: 240),
            DailyPrice(day: StubMarketProvider.day("2026-01-06")!, price: 242),
        ])
        try await store.save(data)

        let loaded = try await store.load()
        XCTAssertEqual(loaded.latestQuotes.count, 1)
        XCTAssertEqual(loaded.latestQuotes.first?.price, 250)
        XCTAssertEqual(loaded.latestRates.first?.rate, 1.37)
        XCTAssertEqual(loaded.series["AAPL"]?.points.count, 2)
        XCTAssertEqual(loaded.price(onOrBefore: StubMarketProvider.day("2026-01-31")!, for: "AAPL"), 242)
        XCTAssertEqual(loaded.price(onOrBefore: StubMarketProvider.day("2026-01-05")!, for: "AAPL"), 240)
        // Before any stored day: no price, no crash.
        XCTAssertNil(loaded.price(onOrBefore: StubMarketProvider.day("2026-01-01")!, for: "AAPL"))
    }

    func testStrictlyBeforeNeverReturnsTheQuotedDayItself() {
        var data = MarketData()
        data.mergeSeries(symbol: "TSLA.NE", currency: .cad, points: [
            DailyPrice(day: StubMarketProvider.day("2026-01-02")!, price: 29.5),          // Friday
            DailyPrice(day: StubMarketProvider.day("2026-01-05")!, price: 30,
                       via: "derived via TSLA ÷ 16.2645"),                                 // Monday
            DailyPrice(day: StubMarketProvider.day("2026-01-06")!, price: 31),             // Tuesday
        ])
        // A Tuesday quote is compared to Monday — never to Tuesday itself,
        // even though Tuesday's close is already stored.
        let monday = data.point(strictlyBefore: StubMarketProvider.day("2026-01-06")!, for: "TSLA.NE")
        XCTAssertEqual(monday?.price, 30)
        XCTAssertNotNil(monday?.via)   // provenance survives for labelling
        // A Sunday quote (weekend echo of Monday) looks back past the
        // weekend gap to Friday.
        XCTAssertEqual(data.point(strictlyBefore: StubMarketProvider.day("2026-01-04")!, for: "TSLA.NE")?.price, 29.5)
        XCTAssertNil(data.point(strictlyBefore: StubMarketProvider.day("2026-01-02")!, for: "TSLA.NE"))
        XCTAssertNil(data.point(strictlyBefore: StubMarketProvider.day("2026-01-06")!, for: "GHOST"))
    }

    func testLatestSectionKeepsOnlyTheNewestPerSymbol() async throws {
        var data = MarketData()
        data.replaceLatest(MarketQuote(symbol: "AAPL", currency: .usd, price: 250))
        data.replaceLatest(MarketQuote(symbol: "AAPL", currency: .usd, price: 255))
        XCTAssertEqual(data.latestQuotes.count, 1)
        XCTAssertEqual(data.latestQuotes.first?.price, 255)
    }

    func testMergeKeepsStoredDaysAndAddsMissing() async throws {
        let store = makeStore()
        var data = MarketData()
        data.mergeSeries(symbol: "AAPL", currency: .usd, points: [
            DailyPrice(day: StubMarketProvider.day("2026-01-05")!, price: 240),
        ])
        try await store.save(data)

        var reloaded = try await store.load()
        // Same day arrives with a different price: stored value wins,
        // nothing is added ("fetch only what is missing" rule).
        let added = reloaded.mergeSeries(symbol: "AAPL", currency: .usd, points: [
            DailyPrice(day: StubMarketProvider.day("2026-01-05")!, price: 999),
            DailyPrice(day: StubMarketProvider.day("2026-01-06")!, price: 242),
        ])
        XCTAssertEqual(added, 1)
        let series = reloaded.series["AAPL"]!
        XCTAssertEqual(series.points.count, 2)
        XCTAssertEqual(series.points.first { $0.day == StubMarketProvider.day("2026-01-05")! }?.price, 240)
    }

    func testCorruptDocumentDecodesToEmpty() async throws {
        // A corrupt market document must never brick the CLI: it is a
        // refetchable cache, not the ledger.
        let memory = MemoryDataStore()
        try await memory.save(Data("this is not json".utf8), key: MarketStore.documentKey)
        let loaded = try await MarketStore(store: memory).load()
        XCTAssertTrue(loaded.latestQuotes.isEmpty)
        XCTAssertTrue(loaded.series.isEmpty)
    }
}

// MARK: - Update engine

final class MarketUpdaterTests: XCTestCase {

    private func utc(_ iso: String) -> Date {
        guard let date = StubMarketProvider.day(iso) else {
            preconditionFailure("bad test date \(iso)")
        }
        return date
    }

    /// One CAD account holding AAPL (USD) bought 2025-01-02, fully sold
    /// 2025-03-05; TSLA (USD) still open (bought 2025-01-02).
    private func makePortfolio() -> Portfolio {
        let account = Account(reportingCurrency: .cad, name: "Test")
        return Portfolio(
            accounts: [account],
            transactions: [
                Transaction(date: utc("2025-01-02"), accountID: account.id, currency: .usd,
                            kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 10, price: 200))),
                Transaction(date: utc("2025-01-02"), accountID: account.id, currency: .usd,
                            kind: .stockPurchase(StockDetails(ticker: "TSLA", shares: 5, price: 300))),
                Transaction(date: utc("2025-03-05"), accountID: account.id, currency: .usd,
                            kind: .stockSale(StockDetails(ticker: "AAPL", shares: 10, price: 210))),
            ],
            tickers: [
                EquityTicker(symbol: "AAPL", currency: .usd),
                EquityTicker(symbol: "TSLA", currency: .usd),
            ]
        )
    }

    // MARK: Holding windows

    func testHoldingWindowsFollowTheLedger() {
        let windows = makePortfolio().holdingWindows(through: utc("2025-06-30"))
        // Sold-out symbol: window ends on the sell day, not after.
        XCTAssertEqual(windows["AAPL"]?.count, 1)
        XCTAssertEqual(windows["AAPL"]?.first?.start, utc("2025-01-02"))
        XCTAssertEqual(windows["AAPL"]?.first?.end, utc("2025-03-05"))
        // Still-open symbol: window runs through the query date.
        XCTAssertEqual(windows["TSLA"]?.first?.end, utc("2025-06-30"))
    }

    func testHoldingWindowsMergeAcrossAccounts() {
        let a = Account(reportingCurrency: .cad, name: "A")
        let b = Account(reportingCurrency: .usd, name: "B")
        let portfolio = Portfolio(
            accounts: [a, b],
            transactions: [
                // B holds TSLA Jan 10 → Jan 20; A holds it Jan 15 onward.
                Transaction(date: utc("2025-01-10"), accountID: b.id, currency: .usd,
                            kind: .stockPurchase(StockDetails(ticker: "TSLA", shares: 1, price: 10))),
                Transaction(date: utc("2025-01-15"), accountID: a.id, currency: .usd,
                            kind: .stockPurchase(StockDetails(ticker: "TSLA", shares: 1, price: 10))),
                Transaction(date: utc("2025-01-20"), accountID: b.id, currency: .usd,
                            kind: .stockSale(StockDetails(ticker: "TSLA", shares: 1, price: 12))),
            ])
        // The two overlapping windows merge into one fetch range.
        let windows = portfolio.holdingWindows(through: utc("2025-01-31"))["TSLA"]
        XCTAssertEqual(windows?.count, 1)
        XCTAssertEqual(windows?.first?.start, utc("2025-01-10"))
        XCTAssertEqual(windows?.first?.end, utc("2025-01-31"))
    }

    // MARK: Latest

    func testLatestUpdateStoresQuotesAndRate() async throws {
        let provider = StubMarketProvider()
        // Note the sold-out AAPL is NOT in the plan — "latest" tracks
        // OPEN positions only (the history engine covers the past).
        await provider.setLastPrices(["TSLA": (350, .usd)])
        let store = MarketStore(store: MemoryDataStore())
        let updater = MarketUpdater(provider: provider, store: store)

        let report = try await updater.updateLatest(portfolio: makePortfolio(),
                                                    displayCurrency: .cad,
                                                    now: utc("2025-06-30"))
        let data = try await store.load()
        XCTAssertEqual(report.failures, [])
        let stored = data.latestQuotes.map(\.symbol).sorted()
        XCTAssertEqual(stored, ["TSLA"])
        XCTAssertEqual(data.latestRates.count, 1)
        XCTAssertTrue(report.latestRows.contains { $0.name == "USD/CAD" && $0.price == "1.4" })
        XCTAssertTrue(report.latestRows.contains { $0.name == "TSLA" })
    }

    func testLatestUpdateReportsMissingQuotesLoudly() async throws {
        let provider = StubMarketProvider()
        // TSLA is held but the provider has nothing → reported, not
        // silently skipped.
        let store = MarketStore(store: MemoryDataStore())
        let report = try await MarketUpdater(provider: provider, store: store)
            .updateLatest(portfolio: makePortfolio(), displayCurrency: .cad)
        XCTAssertEqual(report.failures, ["no quote: TSLA"])
    }

    func testLatestUpdateWithoutPositionsIsQuiet() async throws {
        let provider = StubMarketProvider()
        let store = MarketStore(store: MemoryDataStore())
        let empty = Portfolio()
        // USD display = the hub, so an empty portfolio needs neither
        // quotes nor FX: the quiet no-op path.
        let report = try await MarketUpdater(provider: provider, store: store)
            .updateLatest(portfolio: empty, displayCurrency: .usd)
        XCTAssertTrue(report.lines.first?.contains("nothing to update") == true)
    }

    // MARK: History

    func testHistoryStoresOnlyHeldDays() async throws {
        let provider = StubMarketProvider()
        // Script AAPL data beyond the holding window (Jan–Jun); only
        // Jan 2 … Mar 5 was held.
        var script: [(String, Decimal)] = []
        var day = utc("2025-01-01")
        while day <= utc("2025-06-30") {
            script.append((StubMarketProvider.stamp(day), 200))
            day = day.addingTimeInterval(86_400)
        }
        await provider.setDaily(["AAPL": script])
        let store = MarketStore(store: MemoryDataStore())
        var portfolio = makePortfolio()
        portfolio.transactions.removeAll { $0.summaryLine.contains("TSLA") }

        let report = try await MarketUpdater(provider: provider, store: store)
            .updateHistory(portfolio: portfolio, displayCurrency: .cad,
                           today: utc("2025-06-30"))
        let series = try await store.load().series["AAPL"]
        let days = try XCTUnwrap(series?.points.map(\.day))
        // Held 2025-01-02 … 2025-03-05 = 63 days; no data before the
        // buy or after the sell was stored.
        XCTAssertEqual(days.count, 63)
        XCTAssertEqual(days.first, utc("2025-01-02"))
        XCTAssertEqual(days.last, utc("2025-03-05"))
        // And the watermark marks the window covered …
        XCTAssertEqual(series?.coveredThrough, utc("2025-03-05"))
        // … so a second run fetches NOTHING.
        let requestsAfter = await provider.seriesRequestCount
        let report2 = try await MarketUpdater(provider: provider, store: store)
            .updateHistory(portfolio: portfolio, displayCurrency: .cad,
                           today: utc("2025-06-30"))
        let requestsLater = await provider.seriesRequestCount
        XCTAssertEqual(requestsAfter, requestsLater, "second run must not re-fetch")
        XCTAssertTrue(report2.historyRows.contains { $0.name == "AAPL" && $0.first == "2025-01-02" && $0.last == "2025-03-05" && $0.count == 63 && $0.added == 0 })
        XCTAssertTrue(report2.historyRows.allSatisfy { $0.added == 0 }, "second run changes no coverage")
        _ = report
    }

    func testHistoryIncrementalAddsOnlyNewDays() async throws {
        // Position stays open; first fill ends May 1 (watermark), one
        // week later two new closes appear and only those are fetched.
        let account = Account(reportingCurrency: .usd, name: "B")
        let portfolio = Portfolio(
            accounts: [account],
            transactions: [
                Transaction(date: utc("2025-04-01"), accountID: account.id, currency: .usd,
                            kind: .stockPurchase(StockDetails(ticker: "NVDA", shares: 1, price: 100))),
            ],
            tickers: [EquityTicker(symbol: "NVDA", currency: .usd)])

        let provider1 = StubMarketProvider()
        var first: [(String, Decimal)] = []
        var day = utc("2025-04-01")
        while day <= utc("2025-05-01") {
            first.append((StubMarketProvider.stamp(day), 100))
            day = day.addingTimeInterval(86_400)
        }
        await provider1.setDaily(["NVDA": first])
        let store = MarketStore(store: MemoryDataStore())
        _ = try await MarketUpdater(provider: provider1, store: store)
            .updateHistory(portfolio: portfolio, displayCurrency: .cad,
                           today: utc("2025-05-01"))
        let storedAfterFirst = try await store.load().series["NVDA"]?.points.count

        // Two days later: provider now answers up to May 3.
        var second = first
        second.append(("2025-05-02", 101))
        second.append(("2025-05-03", 102))
        let provider2 = StubMarketProvider()
        await provider2.setDaily(["NVDA": second])
        let report2 = try await MarketUpdater(provider: provider2, store: store)
            .updateHistory(portfolio: portfolio, displayCurrency: .cad,
                           today: utc("2025-05-03"))
        XCTAssertEqual(report2.pointsStored, 2)
        XCTAssertEqual(report2.seriesFetched, 1)
        let now = try await store.load().series["NVDA"]
        XCTAssertEqual(now?.points.count, storedAfterFirst! + 2)
        // Fetch range began at the day after the old watermark (May 2).
        let request = await provider2.lastSeriesRequest
        XCTAssertEqual(request?.symbol, "NVDA")
        XCTAssertEqual(request?.from, utc("2025-05-02"))
        XCTAssertEqual(request?.to, utc("2025-05-03"))
    }

    func testHistoryRebuildRefetchesEverything() async throws {
        let provider1 = StubMarketProvider()
        await provider1.setDaily(["AAPL": [("2025-02-03", 200)]])
        let store = MarketStore(store: MemoryDataStore())
        let updater1 = MarketUpdater(provider: provider1, store: store)
        _ = try await updater1.updateHistory(portfolio: makePortfolio(), displayCurrency: .cad,
                                             today: utc("2025-06-30"))
        let firstCount = await provider1.seriesRequestCount

        let provider2 = StubMarketProvider()
        await provider2.setDaily(["AAPL": [("2025-02-03", 200), ("2025-03-01", 210)]])
        let report = try await MarketUpdater(provider: provider2, store: store)
            .updateHistory(portfolio: makePortfolio(), displayCurrency: .cad,
                           mode: .rebuild, today: utc("2025-06-30"))
        // AAPL refetched AND TSLA (open position) too: nothing is
        // exempt from a wipe-and-refill.
        let requests = await provider2.seriesRequestSymbols
        XCTAssertTrue(requests.contains("AAPL"))
        XCTAssertTrue(requests.contains("TSLA"))
        XCTAssertGreaterThanOrEqual(report.pointsStored, 2)
        let reloaded = try await store.load()
        // Whole-window re-fetch restored the sold-out symbol's history.
        XCTAssertGreaterThanOrEqual(reloaded.series["AAPL"]?.points.count ?? 0, 2)
        _ = firstCount
    }

    func testHistoryRefillFindsGapsTheWatermarkWalkedPast() async throws {
        // First pass: provider knows ONE close; the fetch still marks
        // the whole window covered (watermark), so later incremental
        // runs never look at it again.
        let provider1 = StubMarketProvider()
        await provider1.setDaily(["AAPL": [("2025-02-03", 200)]])
        let store = MarketStore(store: MemoryDataStore())
        _ = try await MarketUpdater(provider: provider1, store: store)
            .updateHistory(portfolio: makePortfolio(), displayCurrency: .cad,
                           today: utc("2025-06-30"))

        // Later the provider "learns" eight more closes inside the
        // covered window (a vendor file arrived, a fixture was fixed).
        let provider2 = StubMarketProvider()
        var full: [(String, Decimal)] = [("2025-02-03", 200)]
        for day in ["2025-02-10", "2025-02-11", "2025-02-12", "2025-02-13",
                    "2025-02-14", "2025-03-03", "2025-03-04", "2025-03-05"] {
            full.append((day, 210))
        }
        await provider2.setDaily(["AAPL": full])

        // Incremental trusts the watermark: AAPL is not re-requested.
        _ = try await MarketUpdater(provider: provider2, store: store)
            .updateHistory(portfolio: makePortfolio(), displayCurrency: .cad,
                           today: utc("2025-06-30"))
        let quietRequests = await provider2.seriesRequests
        XCTAssertFalse(quietRequests.contains { $0.symbol == "AAPL" },
                       "incremental must not re-fetch a covered window")

        // --re-fill re-verifies the full window and MERGES: the fetch
        // starts at the first holding day, nothing is erased, and the
        // stored real close survives alongside the new days.
        let refill = try await MarketUpdater(provider: provider2, store: store)
            .updateHistory(portfolio: makePortfolio(), displayCurrency: .cad,
                           mode: .refill, today: utc("2025-06-30"))
        let refillRequests = await provider2.seriesRequests
        guard let aapl = refillRequests.first(where: { $0.symbol == "AAPL" }) else {
            return XCTFail("refill must re-fetch covered windows")
        }
        XCTAssertEqual(aapl.from, utc("2025-01-02"), "refill starts at the window's first holding day")
        XCTAssertEqual(refill.pointsStored, 8, "only the missing days are added")
        let loaded = try await store.load()
        let series = try XCTUnwrap(loaded.series["AAPL"])
        XCTAssertEqual(series.points.count, 9)
        XCTAssertTrue(series.points.contains { $0.price == 200 && $0.via == nil },
                      "the stored real close was not erased")
    }

    func testHistoryReportsFailedFetches() async throws {
        let provider = StubMarketProvider()
        await provider.setFailing(["AAPL", "TSLA"])
        let store = MarketStore(store: MemoryDataStore())
        let report = try await MarketUpdater(provider: provider, store: store)
            .updateHistory(portfolio: makePortfolio(), displayCurrency: .cad,
                           today: utc("2025-06-30"))
        // Failures are loud, not silent …
        XCTAssertTrue(report.failures.contains { $0.contains("AAPL") })
        XCTAssertTrue(report.failures.contains { $0.contains("TSLA") })
        // … and nothing was marked covered by a failed fetch.
        let data = try await store.load()
        XCTAssertNil(data.series["AAPL"]?.coveredThrough)
    }

    // MARK: FX history

    func testFXHistoryFillsUsedCurrencyRange() async throws {
        let account = Account(reportingCurrency: .usd, name: "All-USD")
        let portfolio = Portfolio(
            accounts: [account],
            transactions: [
                // CAD is not the hub (USD is): display needs USD→CAD.
                Transaction(date: utc("2025-04-10"), accountID: account.id, currency: .usd,
                            kind: .deposit(amount: 100)),
            ])
        let provider = StubMarketProvider()
        var script: [(String, Decimal)] = []
        var day = utc("2025-04-10")
        while day <= utc("2025-05-05") {
            script.append((StubMarketProvider.stamp(day), 1.4))
            day = day.addingTimeInterval(86_400)
        }
        await provider.setDaily(["USDCAD=X": script])
        let store = MarketStore(store: MemoryDataStore())
        let report = try await MarketUpdater(provider: provider, store: store)
            .updateHistory(portfolio: portfolio, displayCurrency: .cad,
                           today: utc("2025-05-05"))
        let series = try await store.load().series["USD/CAD"]
        XCTAssertNotNil(series)
        XCTAssertEqual(series?.points.count, 26)
        XCTAssertEqual(report.failures, [])
    }

    // MARK: Series slicing (quote --from/--to)

    func testSeriesSliceIsInclusiveSortedAndOpenEnded() throws {
        var data = MarketData()
        data.series["AAPL"] = PriceSeries(symbol: "AAPL", currency: .usd, points: [
            DailyPrice(day: StubMarketProvider.day("2026-09-25")!, price: 1),
            DailyPrice(day: StubMarketProvider.day("2026-09-23")!, price: 2),
            DailyPrice(day: StubMarketProvider.day("2026-09-24")!, price: 3),
        ])
        // Bounds inclusive, output sorted by day (even if the fixture
        // arrived unsorted).
        let slice = data.points(from: StubMarketProvider.day("2026-09-23"),
                                to: StubMarketProvider.day("2026-09-24"),
                                for: "AAPL")
        XCTAssertEqual(slice.map(\.price), [2, 3])
        // Open ends: nil … nil is the whole series; a window past the
        // last point is EMPTY — never "the last point again".
        XCTAssertEqual(data.points(from: nil, to: nil, for: "AAPL").count, 3)
        XCTAssertTrue(data.points(from: StubMarketProvider.day("2026-09-26"), to: nil, for: "AAPL").isEmpty)
        XCTAssertTrue(data.points(from: nil, to: nil, for: "GHOST").isEmpty)
    }
}

// MARK: - Stub actor sugar (test-only convenience)

extension StubMarketProvider {
    func setLastPrices(_ values: [String: (Decimal, Currency)]) { lastPrices = values }
    func setDaily(_ values: [String: [(String, Decimal)]]) { daily = values }
    func setFailing(_ symbols: [String]) { failing = Set(symbols) }
    fileprivate var seriesRequestCount: Int { seriesRequests.count }
    fileprivate var seriesRequestSymbols: [String] { seriesRequests.map(\.symbol) }
    fileprivate var lastSeriesRequest: StubMarketProvider.Request? { seriesRequests.last }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
