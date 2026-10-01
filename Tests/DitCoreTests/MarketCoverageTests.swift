import Foundation
import Testing
@testable import DitCore

/// Coverage must state FACTS the reporting views would hit: a series
/// that exists but can never be READ is a gap, calendar dust is not,
/// darkness before anyone traded is not, and a chain made only of
/// refused-old legs converts nothing. Never a fabricated percentage,
/// never a hidden hole.
@Suite("market coverage")
struct MarketCoverageTests {

    private func day(_ y: Int, _ month: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: month, day: d))!
    }
    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    /// Daily closes from `start` for `count` consecutive days.
    private func closes(_ symbol: String, _ ccy: Currency, from: Date, _ count: Int,
                        price: String = "10", via: String? = nil) -> PriceSeries {
        PriceSeries(symbol: symbol, currency: ccy,
                    points: (0..<count).map {
                        DailyPrice(day: PnLWindow.addDays(from, $0), price: dec(price), via: via)
                    })
    }
    private func closes(_ symbol: String, _ ccy: Currency, _ pairs: [(Date, String)],
                        via: String? = nil) -> PriceSeries {
        PriceSeries(symbol: symbol, currency: ccy,
                    points: pairs.map { DailyPrice(day: $0.0, price: dec($0.1), via: via) })
    }

    private func market(_ series: PriceSeries...) -> MarketData {
        var data = MarketData()
        for s in series { data.series[s.symbol] = s }
        return data
    }

    private func portfolio(_ pairs: [(Account, [Transaction])]) -> ([Account], Portfolio) {
        let accounts = pairs.map(\.0)
        let txs = pairs.flatMap(\.1)
        return (accounts, Portfolio(accounts: accounts, transactions: txs))
    }

    // MARK: the clean case

    @Test func denseSeriesAndDenseFXReadAsComplete() {
        let acct = Account(reportingCurrency: .cad, name: "CA")
        let (accounts, book) = portfolio([(acct, [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 10, price: 60))),
        ])])
        let audit = day(2026, 10, 1)
        let store = market(
            closes("AAPL", .usd, from: day(2026, 1, 2), 274),          // through Oct 1
            closes("USD/CAD", .cad, from: day(2026, 1, 2), 274))       // dense too
        let report = MarketCoverage.report(portfolio: book, accounts: accounts,
                                           asOf: audit, windowStart: nil,
                                           reportingCurrency: .cad, market: store)
        #expect(report.symbols.count == 1)
        #expect(report.symbols[0].measurable)
        #expect(report.fx.count == 1)
        #expect(report.fx[0].usableNow)
        #expect(report.fx[0].boundariesMissing == 0)
        #expect(report.complete)
    }

    // MARK: price facts

    @Test func missingSeriesIsNamedPerPositionWithHolders() {
        let ca = Account(reportingCurrency: .cad, name: "CA")
        let cb = Account(reportingCurrency: .cad, name: "CB")
        let (accounts, book) = portfolio([
            (ca, [Transaction(date: day(2026, 2, 1), accountID: ca.id, currency: .usd,
                              kind: .stockPurchase(StockDetails(ticker: "NEWTKR", shares: 5, price: 20)))]),
            (cb, [Transaction(date: day(2026, 2, 1), accountID: cb.id, currency: .usd,
                              kind: .stockPurchase(StockDetails(ticker: "NEWTKR", shares: 5, price: 20)))]),
        ])
        let report = MarketCoverage.report(portfolio: book, accounts: accounts,
                                           asOf: day(2026, 10, 1), windowStart: nil,
                                           reportingCurrency: .cad, market: MarketData())
        #expect(report.symbols.count == 1)  // one row, both holders
        let row = try! #require(report.symbols.first)
        #expect(!row.seriesFound && !row.measurable)
        #expect(row.accounts == ["CA", "CB"])
        #expect(!report.complete)
    }

    @Test func wrongCurrencySeriesIsStatedAndNeverCountedAsCovered() {
        // A CAD-denominated position whose only series is stored in
        // USD: the reporting views refuse it — coverage must say so
        // instead of green-checking it.
        let acct = Account(reportingCurrency: .cad, name: "CA")
        let (accounts, book) = portfolio([(acct, [
            Transaction(date: day(2026, 6, 1), accountID: acct.id, currency: .cad,
                        kind: .stockPurchase(StockDetails(ticker: "TRK.TO", shares: 10, price: 7))),
        ])])
        let store = market(closes("TRK.TO", .usd, from: day(2026, 1, 2), 274))
        let report = MarketCoverage.report(portfolio: book, accounts: accounts,
                                           asOf: day(2026, 10, 1), windowStart: nil,
                                           reportingCurrency: .cad, market: store)
        #expect(report.symbols.count == 1)
        let row = try! #require(report.symbols.first)
        #expect(row.seriesFound && !row.usableSource && !row.measurable)
        #expect(row.seriesCurrency == .usd)
        #expect(row.longestGap == nil)  // a never-used series has no "gap" to scan
    }

    @Test func weekendDustIsSilentAndRealHolesAreReported() {
        let acct = Account(reportingCurrency: .cad, name: "CA")
        let (accounts, book) = portfolio([(acct, [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 10, price: 60))),
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "HOLEY", shares: 10, price: 60))),
        ])])
        // AAPL: every day (weekend dust cannot even occur). HOLEY:
        // daily Apr 1…Jun 30 then nothing until Sep 1 → a 63-day
        // inside hole inside the holding period.
        var holey: [(Date, String)] = []
        var cursor = day(2026, 1, 2)
        while cursor <= day(2026, 3, 31) { holey.append((cursor, "9")); cursor = PnLWindow.addDays(cursor, 1) }
        cursor = day(2026, 4, 1)
        while cursor <= day(2026, 6, 30) { holey.append((cursor, "9")); cursor = PnLWindow.addDays(cursor, 1) }
        cursor = day(2026, 9, 1)
        while cursor <= day(2026, 10, 1) { holey.append((cursor, "9")); cursor = PnLWindow.addDays(cursor, 1) }
        _ = cursor
        let store = market(
            closes("AAPL", .usd, from: day(2026, 1, 2), 274),
            closes("HOLEY", .usd, holey))
        let report = MarketCoverage.report(portfolio: book, accounts: accounts,
                                           asOf: day(2026, 10, 1), windowStart: nil,
                                           reportingCurrency: .cad, market: store)
        let dense = report.symbols.first { $0.symbol == "AAPL" }!
        #expect(dense.longestGap == nil)
        let gapped = report.symbols.first { $0.symbol == "HOLEY" }!
        #expect(gapped.longestGap?.days == 62)  // Jul 1 … Aug 31
    }

    @Test func darknessBeforeFirstTradeIsNotAGap() {
        // Bought Apr 27; the series starts exactly Apr 27 (the real
        // VRT case). Scanning from the LEDGER start would scream
        // "482-day hole" — a fabricated finding.
        let acct = Account(reportingCurrency: .cad, name: "CA")
        let (accounts, book) = portfolio([(acct, [
            Transaction(date: day(2026, 1, 4), accountID: acct.id, currency: .cad,
                        kind: .deposit(amount: dec("1000"))),  // unrelated early ledger noise
            Transaction(date: day(2026, 4, 27), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "VRT", shares: 5, price: 322))),
        ])])
        let store = market(closes("VRT", .usd, from: day(2026, 4, 27), 158),  // to Oct 1
                           closes("USD/CAD", .cad, from: day(2026, 1, 2), 274))
        let report = MarketCoverage.report(portfolio: book, accounts: accounts,
                                           asOf: day(2026, 10, 1), windowStart: nil,
                                           reportingCurrency: .cad, market: store)
        let row = report.symbols.first { $0.symbol == "VRT" }!
        #expect(row.longestGap == nil)
        #expect(row.staleDays == 0)
        #expect(report.complete)
    }

    @Test func seriesEndingLongAgoReportsStalenessNotFakeCoverage() {
        let acct = Account(reportingCurrency: .cad, name: "CA")
        let (accounts, book) = portfolio([(acct, [
            Transaction(date: day(2026, 6, 15), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "GONE", shares: 5, price: 20))),
        ])])
        // Series stops May 20 — nothing stored at or after the buy.
        let store = market(closes("GONE", .usd, from: day(2026, 1, 2), 139))
        let report = MarketCoverage.report(portfolio: book, accounts: accounts,
                                           asOf: day(2026, 10, 1), windowStart: nil,
                                           reportingCurrency: .cad, market: store)
        let row = report.symbols.first { $0.symbol == "GONE" }!
        #expect(row.pointsInWindow == 0)
        #expect((row.staleDays ?? 0) > 7)
        #expect(!report.complete)
    }

    @Test func closedPositionsAreNobodyGap() {
        // Sold before the audit date: no live price need, no row.
        let acct = Account(reportingCurrency: .cad, name: "CA")
        let (accounts, book) = portfolio([(acct, [
            Transaction(date: day(2026, 2, 1), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "RIDE", shares: 10, price: 20))),
            Transaction(date: day(2026, 5, 1), accountID: acct.id, currency: .usd,
                        kind: .stockSale(StockDetails(ticker: "RIDE", shares: 10, price: 22))),
        ])])
        let report = MarketCoverage.report(portfolio: book, accounts: accounts,
                                           asOf: day(2026, 10, 1), windowStart: nil,
                                           reportingCurrency: .cad, market: MarketData())
        #expect(report.symbols.isEmpty)
        // The sold shares need nothing anymore… but the +20 USD cash
        // that remains DOES need a conversion path: coverage says so.
        #expect(report.fx.map(\.from) == [.usd])
        #expect(!report.complete)
    }

    // MARK: FX facts

    @Test func fxChainsAreReportedByKind() {
        let acct = Account(reportingCurrency: .cad, name: "CA")
        let (accounts, book) = portfolio([(acct, [
            Transaction(date: day(2026, 6, 1), accountID: acct.id, currency: .hkd,
                        kind: .deposit(amount: dec("100"))),
            Transaction(date: day(2026, 6, 1), accountID: acct.id, currency: .jpy,
                        kind: .deposit(amount: dec("100"))),
        ])])
        let audit = day(2026, 10, 1)
        // HKD triangulates (both USD legs dense); JPY has no path.
        let store = market(
            closes("USD/HKD", .hkd, from: day(2026, 1, 2), 274),
            closes("USD/CAD", .cad, from: day(2026, 1, 2), 274))
        let report = MarketCoverage.report(portfolio: book, accounts: accounts,
                                           asOf: audit, windowStart: nil,
                                           reportingCurrency: .cad, market: store)
        let hkd = report.fx.first { $0.from == .hkd }!
        #expect(hkd.usableNow)
        #expect(hkd.chainLabel?.contains("derived via USD") == true)
        #expect(hkd.boundariesMissing == 0)
        let jpy = report.fx.first { $0.from == .jpy }!
        #expect(jpy.chainLabel == nil)
        #expect(!jpy.usableNow)
        #expect(!report.complete)
    }

    @Test func staleChainIsStatedNotHidden() {
        // USD/CAD exists but every close is 8+ months old: the FX
        // clock REFUSES it (staleness cap) — coverage must report
        // "chain exists, converts nothing", leading to the REFILL
        // remedy, not the IMPORT remedy.
        let acct = Account(reportingCurrency: .cad, name: "CA")
        let (accounts, book) = portfolio([(acct, [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                        kind: .deposit(amount: dec("100"))),
        ])])
        let store = market(closes("USD/CAD", .cad, from: day(2026, 1, 6), 90))  // stops Apr 5
        let report = MarketCoverage.report(portfolio: book, accounts: accounts,
                                           asOf: day(2026, 10, 1), windowStart: nil,
                                           reportingCurrency: .cad, market: store)
        let usd = report.fx.first { $0.from == .usd }!
        #expect(!usd.usableNow)
        #expect(usd.chainLabel != nil)          // the chain exists…
        #expect((usd.staleDays ?? 0) > 7)        // …and converts nothing
        #expect(usd.boundariesMissing > 0)
        #expect(!report.complete)
    }

    @Test func nativeCurrencyNeedsNoChain() {
        let acct = Account(reportingCurrency: .cad, name: "CA")
        let (accounts, book) = portfolio([(acct, [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .cad,
                        kind: .stockPurchase(StockDetails(ticker: "ENB.TO", shares: 10, price: 10))),
        ])])
        let report = MarketCoverage.report(portfolio: book, accounts: accounts,
                                           asOf: day(2026, 10, 1), windowStart: nil,
                                           reportingCurrency: .cad, market: MarketData())
        #expect(report.fx.isEmpty)  // CAD into CAD is arithmetic, not FX
    }

    @Test func scopeAndClosedForeignCashSkipFX() {
        // Foreign cash fully withdrawn before the audit date: no
        // conversion need; and positions in OTHER accounts are out
        // of scope when a narrower scope is passed.
        let ca = Account(reportingCurrency: .cad, name: "CA")
        let cb = Account(reportingCurrency: .cad, name: "CB")
        let (accounts, book) = portfolio([
            (ca, [Transaction(date: day(2026, 2, 1), accountID: ca.id, currency: .usd,
                              kind: .deposit(amount: dec("100"))),
                  Transaction(date: day(2026, 3, 1), accountID: ca.id, currency: .usd,
                              kind: .withdrawal(amount: dec("100")))]),
            (cb, [Transaction(date: day(2026, 2, 1), accountID: cb.id, currency: .usd,
                              kind: .stockPurchase(StockDetails(ticker: "OUT", shares: 5, price: 20)))]),
        ])
        let onlyCa = MarketCoverage.report(portfolio: book, accounts: [ca],
                                           asOf: day(2026, 10, 1), windowStart: nil,
                                           reportingCurrency: .cad, market: MarketData())
        #expect(onlyCa.isEmpty)  // nothing open in CA, no live foreign currency
        let all = MarketCoverage.report(portfolio: book, accounts: [ca, cb],
                                        asOf: day(2026, 10, 1), windowStart: nil,
                                        reportingCurrency: .cad, market: MarketData())
        #expect(all.symbols.map(\.symbol) == ["OUT"])
        #expect(all.fx.map(\.from) == [.usd])  // the OPEN OUT position needs it
    }
}