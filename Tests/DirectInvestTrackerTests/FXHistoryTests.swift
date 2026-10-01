import Foundation
import Testing
@testable import DirectInvestTracker

/// The FX clock is the difference between a HISTORICAL report and a
/// report wearing today's clothes: rates must come from dated pair
/// series, never the latest snapshot; staleness is refused past a
/// week; and every answer carries the date it really came from.
@Suite("fx clock")
struct FXHistoryTests {

    private func day(_ y: Int, _ month: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: month, day: d))!
    }
    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func pair(_ key: String, _ quote: Currency, _ pairs: [(Date, String)],
                      via: String? = nil) -> PriceSeries {
        PriceSeries(symbol: key, currency: quote,
                    points: pairs.map { DailyPrice(day: $0.0, price: dec($0.1), via: via) })
    }

    @Test func directPairOnExactDay() {
        let clock = FXClock(series: ["USD/CAD":
            pair("USD/CAD", .cad, [(day(2026, 7, 31), "1.40")])])
        let q = clock.quote(from: .usd, to: .cad, on: day(2026, 7, 31))
        #expect(q?.rate == dec("1.40"))
        #expect(q?.stalenessDays == 0)
        #expect(q?.via == nil)   // a direct, same-day close is a fact
    }

    @Test func backdatesToLastStoredCloseAndLabelsStaleness() {
        // Only a Friday close exists; asking for Monday is legal — the
        // answer is Friday's rate, dated, staleness 3 days.
        let clock = FXClock(series: ["USD/CAD":
            pair("USD/CAD", .cad, [(day(2026, 7, 31), "1.40")])])
        let q = clock.quote(from: .usd, to: .cad, on: day(2026, 8, 3))
        #expect(q?.rate == dec("1.40"))
        #expect(q?.stalenessDays == 3)
        #expect(!q!.approx)
    }

    @Test func refusesStaleClosesInsteadOfStretchingThem() {
        // 21 days earlier is not "that date's FX"; no answer beats a
        // disguised one.
        let clock = FXClock(series: ["USD/CAD":
            pair("USD/CAD", .cad, [(day(2026, 7, 10), "1.40")])])
        #expect(clock.quote(from: .usd, to: .cad, on: day(2026, 7, 31)) == nil)
    }

    @Test func nothingStoredBeforeTheDayIsNoAnswer() {
        // The only close is AFTER the asked day — future data never
        // answers for the past.
        let clock = FXClock(series: ["USD/CAD":
            pair("USD/CAD", .cad, [(day(2026, 7, 31), "1.40")])])
        #expect(clock.quote(from: .usd, to: .cad, on: day(2026, 6, 30)) == nil)
        let empty = FXClock(series: [:])
        #expect(empty.isEmpty)
        #expect(empty.quote(from: .usd, to: .cad, on: day(2026, 6, 30)) == nil)
    }

    @Test func invertedTwinGivesTheReciprocalButIsLabelled() {
        // "CAD/USD" (USD per 1 CAD) is the same observed pair; the
        // reciprocal is arithmetic — still marked derived for honesty.
        let clock = FXClock(series: ["CAD/USD":
            pair("CAD/USD", .usd, [(day(2026, 7, 31), "0.714")])])
        let q = clock.quote(from: .usd, to: .cad, on: day(2026, 7, 31))
        #expect(q?.rate != nil)
        #expect(q?.via == "inverted CAD/USD")
        #expect(q!.approx)
    }

    @Test func triangulatesNonUSDPairsThroughTheHub() {
        // HKD→GBP = (GBP per USD) ÷ (HKD per USD), both legs dated.
        let clock = FXClock(series: [
            "USD/HKD": pair("USD/HKD", .hkd, [(day(2026, 7, 31), "7.80")]),
            "USD/GBP": pair("USD/GBP", .gbp, [(day(2026, 7, 31), "0.78")]),
        ])
        let q = clock.quote(from: .hkd, to: .gbp, on: day(2026, 7, 31))
        // (1 ÷ 7.80) × 0.78 — compare with dust tolerance, the clock
        // composes legs via division (no fabricated round numbers).
        var diff = (q?.rate ?? 0) - dec("0.1")
        if diff < 0 { diff = -diff }
        #expect(diff < dec("0.0000000001"))
        #expect(q?.via?.contains("derived via USD") == true)
        // One leg missing = no answer, not half a cross.
        let half = FXClock(series: ["USD/HKD":
            pair("USD/HKD", .hkd, [(day(2026, 7, 31), "7.80")])])
        #expect(half.quote(from: .hkd, to: .gbp, on: day(2026, 7, 31)) == nil)
    }

    @Test func sameCurrencyAndUnknownNeverNeedAClock() {
        let clock = FXClock(series: ["USD/CAD":
            pair("USD/CAD", .cad, [(day(2026, 7, 31), "1.40")])])
        #expect(clock.quote(from: .cad, to: .cad, on: day(2026, 7, 31)) == nil)
        #expect(clock.quote(from: .unknown, to: .cad, on: day(2026, 7, 31)) == nil)
        // Plain equity series are never FX sources.
        let noPairs = FXClock(series: ["AAPL": pair("AAPL", .usd,
            [(day(2026, 7, 31), "250.00")])])
        #expect(noPairs.isEmpty)
    }
}