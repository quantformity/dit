import XCTest
@testable import DitCore

/// Tests for `dit ticker backfill` (derived-history) and the CSV
/// seeding path. Data mirrors the real scenario: TSLA.NE (CAD, no real
/// daily source) derived from TSLA (USD) through daily USD/CAD, with
/// three genuine .NE observations used to calibrate the ratio.
final class BackfillTests: XCTestCase {

    private func day(_ iso: String) -> Date {
        guard let date = StubMarketProvider.day(iso) else { preconditionFailure("bad date \(iso)") }
        return date
    }

    private func dec(_ text: String) -> Decimal { Decimal(string: text)! }

    /// Same rounding the engine applies (mirror for exact comparison).
    private func rounded(_ value: Decimal, _ scale: Int) -> Decimal {
        let behavior = NSDecimalNumberHandler(roundingMode: .plain, scale: Int16(scale),
                                              raiseOnExactness: false, raiseOnOverflow: false,
                                              raiseOnUnderflow: false, raiseOnDivideByZero: false)
        return NSDecimalNumber(decimal: value).rounding(accordingToBehavior: behavior).decimalValue
    }

    /// One CAD account holding 100 TSLA.NE since 2026-09-16 (still open).
    private func makePortfolio() -> Portfolio {
        let account = Account(reportingCurrency: .cad, name: "Test")
        return Portfolio(
            accounts: [account],
            transactions: [
                Transaction(date: day("2026-09-16"), accountID: account.id, currency: .cad,
                            kind: .stockPurchase(StockDetails(ticker: "TSLA.NE", shares: 100, price: 32))),
            ],
            tickers: [
                EquityTicker(symbol: "TSLA.NE", currency: .cad),
                EquityTicker(symbol: "TSLA", currency: .usd),
            ])
    }

    private func seedMarketData(includeNEObservations: Bool = true) -> MarketData {
        var data = MarketData()
        data.series["TSLA"] = PriceSeries(symbol: "TSLA", currency: .usd, points: [
            DailyPrice(day: day("2026-09-16"), price: dec("358.08")),
            DailyPrice(day: day("2026-09-17"), price: dec("366.2")),
            DailyPrice(day: day("2026-09-18"), price: dec("364.27")),
            DailyPrice(day: day("2026-09-19"), price: dec("371")),   // Saturday — must stay unused
            DailyPrice(day: day("2026-09-20"), price: dec("372")),   // Sunday — must stay unused
            DailyPrice(day: day("2026-09-21"), price: dec("375.3")),
            DailyPrice(day: day("2026-09-22"), price: dec("378.9")),
            DailyPrice(day: day("2026-09-23"), price: dec("380.12")),
            DailyPrice(day: day("2026-09-24"), price: dec("376.5")),
            DailyPrice(day: day("2026-09-25"), price: dec("373.1")),
        ])
        data.series["USD/CAD"] = PriceSeries(symbol: "USD/CAD", currency: .cad, points: [
            DailyPrice(day: day("2026-09-16"), price: dec("1.3988")),
            DailyPrice(day: day("2026-09-17"), price: dec("1.399")),
            DailyPrice(day: day("2026-09-18"), price: dec("1.3987")),
            DailyPrice(day: day("2026-09-21"), price: dec("1.4033")),
            DailyPrice(day: day("2026-09-22"), price: dec("1.4066")),
            DailyPrice(day: day("2026-09-23"), price: dec("1.4066")),
            DailyPrice(day: day("2026-09-24"), price: dec("1.4106")),
            DailyPrice(day: day("2026-09-25"), price: dec("1.4171")),
        ])
        if includeNEObservations {
            // The three genuine .NE closes from the old app's cache.
            data.series["TSLA.NE"] = PriceSeries(symbol: "TSLA.NE", currency: .cad, points: [
                DailyPrice(day: day("2026-09-17"), price: dec("31.66")),
                DailyPrice(day: day("2026-09-18"), price: dec("31.54")),
                DailyPrice(day: day("2026-09-23"), price: dec("32.82")),
            ])
        }
        return data
    }

    // MARK: Happy path — calibrate and fill from stored data, no network

    func testBackfillCalibratesRatioFromRealObservationsAndFillsGaps() async throws {
        let store = MarketStore(store: MemoryDataStore())
        try await store.save(seedMarketData())
        let provider = StubMarketProvider()
        let updater = MarketUpdater(provider: provider, store: store)

        let report = try await updater.backfillHistory(
            portfolio: makePortfolio(), targetSymbol: "TSLA.NE", sourceSymbol: "TSLA",
            allowNetwork: false, dryRun: false, now: day("2026-09-25"))

        // Weekdays Sep 16…25: 8. Real closes: 3 → 5 derived fills.
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.pointsStored, 5)
        // Everything was already in the store: no fetch may happen.
        let requests = await provider.seriesRequests
        XCTAssertTrue(requests.isEmpty, "backfill must use stored data when present, got \(requests)")

        let data = try await store.load()
        let series = try XCTUnwrap(data.series["TSLA.NE"])
        XCTAssertEqual(series.currency, .cad)
        XCTAssertEqual(series.points.count, 8, "3 real + 5 derived, weekends skipped")

        // Weekends are never filled, even though the source had points.
        XCTAssertNil(series.points.first { $0.day == day("2026-09-19") })
        XCTAssertNil(series.points.first { $0.day == day("2026-09-20") })

        // Real observations survive untouched, untagged.
        let real = try XCTUnwrap(series.points.first { $0.day == day("2026-09-17") })
        XCTAssertEqual(real.price, dec("31.66"))
        XCTAssertNil(real.via)

        // Fills carry provenance.
        let fill = try XCTUnwrap(series.points.first { $0.day == day("2026-09-21") })
        XCTAssertNotNil(fill.via)
        XCTAssertTrue(fill.via!.hasPrefix("derived via TSLA"))

        // Exact math: ratio = mean of (TSLA × USDCAD ÷ TSLA.NE) over the
        // three anchored days; fill = TSLA × USDCAD ÷ ratio (4dp).
        let r1 = dec("366.2") * dec("1.399") / dec("31.66")
        let r2 = dec("364.27") * dec("1.3987") / dec("31.54")
        let r3 = dec("380.12") * dec("1.4066") / dec("32.82")
        let ratio = rounded((r1 + r2 + r3) / 3, 6)
        let expectedFill = rounded(dec("375.3") * dec("1.4033") / ratio, 4)
        XCTAssertEqual(fill.price, expectedFill, "derived price must be source × FX ÷ mean ratio")

        // Report mentions calibration and kept observations.
        XCTAssertTrue(report.lines.contains { $0.contains("ratio calibrated on 3 common day(s)") })
        XCTAssertTrue(report.lines.contains { $0.contains("3 real close(s) kept") })
    }

    func testBackfillSecondRunChangesNothing() async throws {
        let store = MarketStore(store: MemoryDataStore())
        try await store.save(seedMarketData())
        let updater = MarketUpdater(provider: StubMarketProvider(), store: store)
        let first = try await updater.backfillHistory(
            portfolio: makePortfolio(), targetSymbol: "TSLA.NE", sourceSymbol: "TSLA",
            allowNetwork: false, now: day("2026-09-25"))
        XCTAssertEqual(first.pointsStored, 5)

        let second = try await updater.backfillHistory(
            portfolio: makePortfolio(), targetSymbol: "TSLA.NE", sourceSymbol: "TSLA",
            allowNetwork: false, now: day("2026-09-25"))
        // Deterministic recompute: identical values → nothing "stored".
        XCTAssertEqual(second.pointsStored, 0)
        XCTAssertTrue(second.lines.contains { $0.contains("5 derived value(s) unchanged") })
    }

    // MARK: Refusals — the engine would rather stop than guess

    func testBackfillRefusesWithoutAnyCommonObservation() async throws {
        let store = MarketStore(store: MemoryDataStore())
        try await store.save(seedMarketData(includeNEObservations: false))
        let updater = MarketUpdater(provider: StubMarketProvider(), store: store)
        do {
            _ = try await updater.backfillHistory(
                portfolio: makePortfolio(), targetSymbol: "TSLA.NE", sourceSymbol: "TSLA",
                allowNetwork: false, now: day("2026-09-25"))
            XCTFail("no common observation must refuse, not invent a ratio")
        } catch let error as DerivationError {
            XCTAssertTrue(error.message.contains("no common days"), error.message)
        }
    }

    func testBackfillWithRatioOverrideSkipsCalibration() async throws {
        let store = MarketStore(store: MemoryDataStore())
        try await store.save(seedMarketData(includeNEObservations: false))
        let updater = MarketUpdater(provider: StubMarketProvider(), store: store)
        let report = try await updater.backfillHistory(
            portfolio: makePortfolio(), targetSymbol: "TSLA.NE", sourceSymbol: "TSLA",
            ratioOverride: dec("16"), allowNetwork: false, now: day("2026-09-25"))
        XCTAssertEqual(report.pointsStored, 8, "no real observations → all 8 weekdays derived")
        let data = try await store.load()
        let first = try XCTUnwrap(data.series["TSLA.NE"]?.points.first?.price)
        // Sep 16: 358.08 × 1.3988 ÷ 16 = 31.3051 (4dp)
        XCTAssertEqual(first, dec("31.3051"))
    }

    func testBackfillFetchesMissingSourceAndFXSeries() async throws {
        // The store starts EMPTY: backfill must fetch TSLA and USDCAD=X,
        // not silently produce nothing.
        var script: [(String, Decimal)] = []
        var cursor = day("2026-09-15")
        while cursor <= day("2026-09-25") {
            script.append((StubMarketProvider.stamp(cursor), 400))
            cursor = cursor.addingTimeInterval(86_400)
        }
        let fxScript: [(String, Decimal)] = (0 ... 10).map {
            (StubMarketProvider.stamp(day("2026-09-15").addingTimeInterval(Double($0) * 86_400)), dec("1.4"))
        }
        let provider = StubMarketProvider()
        await provider.setDaily(["TSLA": script, "USDCAD=X": fxScript])
        let store = MarketStore(store: MemoryDataStore())
        let updater = MarketUpdater(provider: provider, store: store)

        let report = try await updater.backfillHistory(
            portfolio: makePortfolio(), targetSymbol: "TSLA.NE", sourceSymbol: "TSLA",
            ratioOverride: dec("16"), now: day("2026-09-25"))

        let requests = await provider.seriesRequests
        XCTAssertEqual(Set(requests.map(\.symbol)), ["TSLA", "USDCAD=X"])
        XCTAssertGreaterThanOrEqual(report.pointsStored, 1)
        let data = try await store.load()
        XCTAssertNotNil(data.series["TSLA"], "fetched source series must persist")
        XCTAssertNotNil(data.series["USD/CAD"], "fetched FX series must persist")
    }

    func testBackfillReportsWeekdaysWithoutSourceData() async throws {
        var data = seedMarketData()
        // Remove Sep 21/22/24/25 sources → those weekdays stay honestly empty.
        data.series["TSLA"] = PriceSeries(symbol: "TSLA", currency: .usd, points: [
            DailyPrice(day: day("2026-09-16"), price: dec("358.08")),
            DailyPrice(day: day("2026-09-17"), price: dec("366.2")),
            DailyPrice(day: day("2026-09-18"), price: dec("364.27")),
            DailyPrice(day: day("2026-09-23"), price: dec("380.12")),
        ])
        let store = MarketStore(store: MemoryDataStore())
        try await store.save(data)
        let updater = MarketUpdater(provider: StubMarketProvider(), store: store)
        let report = try await updater.backfillHistory(
            portfolio: makePortfolio(), targetSymbol: "TSLA.NE", sourceSymbol: "TSLA",
            allowNetwork: false, now: day("2026-09-25"))
        XCTAssertEqual(report.pointsStored, 1, "only Sep 16 is derivable")
        XCTAssertTrue(report.lines.contains { $0.contains("4 weekday(s) had no same-day source data") })
    }

    // MARK: Provenance rules at the store layer

    func testRealObservationReplacesDerivedValueOnTheSameDay() throws {
        let series = PriceSeries(symbol: "TSLA.NE", currency: .cad, points: [
            DailyPrice(day: day("2026-09-17"), price: dec("30"), via: "derived via TSLA ÷ 16"),
            DailyPrice(day: day("2026-09-18"), price: dec("31"), via: nil),
        ])
        // Importing the REAL Sep 17 close supersedes the derived value…
        let (merged, added) = series.merging([DailyPrice(day: day("2026-09-17"), price: dec("31.66"))])
        XCTAssertEqual(added, 1)
        let sep17 = try XCTUnwrap(merged.points.first { $0.day == day("2026-09-17") })
        XCTAssertEqual(sep17.price, dec("31.66"))
        XCTAssertNil(sep17.via, "a superseded point becomes real")
        // …while a real day keeps its stored value and a second derived
        // point cannot appear beside it.
        let (again, added2) = series.merging([
            DailyPrice(day: day("2026-09-18"), price: dec("999")),
            DailyPrice(day: day("2026-09-18"), price: dec("1"), via: "derived via X"),
        ])
        XCTAssertEqual(added2, 0)
        XCTAssertEqual(again, series)
    }

    func testDecodeMarketDocumentWithoutProvenanceField() throws {
        // Documents written before `via` existed must still load. Dates
        // encode as reference seconds (default JSONDate strategy).
        let json = """
        {"series":{"AAPL":{"symbol":"AAPL","currency":"USD",
        "points":[{"day":786240000,"price":240}]}}}
        """
        let decoded = try JSONDecoder().decode(MarketData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.series["AAPL"]?.points.first?.price, 240)
        XCTAssertNil(decoded.series["AAPL"]?.points.first?.via)
    }

    // MARK: CSV seeding

    func testParseSeriesCSV() {
        let text = """
        # comment header
        SYMBOL,DATE,PRICE
        TSLA.NE,2026-09-17,31.66
        TSLA.NE,2026-09-18,31.54
        USD/CAD,2026-09-17,1.399
        broken line here
        TSLA.NE,2026-13-99,30
        TSLA.NE,2026-09-23,not-a-price
        """
        let parsed = MarketData.parseSeriesCSV(text)
        XCTAssertEqual(parsed.entries.count, 3)
        XCTAssertEqual(parsed.problems.count, 3)
        XCTAssertEqual(parsed.entries[2].symbol, "USD/CAD")
    }
}