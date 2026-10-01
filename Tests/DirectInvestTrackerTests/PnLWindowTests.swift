import Foundation
import Testing
@testable import DirectInvestTracker

/// Window P&L must reconcile with AccountBalances.compute (same rules,
/// no drift), decompose honestly into REALIZED + POSITION CHANGE (no
/// double counting, no phantom P&L from mid-window market prices), and
/// dash — never guess — when a price pair is missing.
@Suite("pnl window")
struct PnLWindowTests {

    private func day(_ y: Int, _ month: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: month, day: d))!
    }
    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func series(_ symbol: String, _ ccy: Currency, _ pairs: [(Date, String)], via: String? = nil) -> PriceSeries {
        PriceSeries(symbol: symbol, currency: ccy,
                    points: pairs.map { DailyPrice(day: $0.0, price: dec($0.1), via: via) })
    }

    // MARK: window resolution

    @Test func horizonsAreInclusiveSpansEndingAtTo() throws {
        let to = day(2026, 9, 30)
        // 5 calendar days: Sep 26 … 30.
        #expect(try PnLWindow.resolveWindow(horizon: "5d", from: nil, to: to, now: to,
                                            ledgerStart: nil).start == day(2026, 9, 26))
        // 1w = 7 days; 2w = 14 days.
        #expect(try PnLWindow.resolveWindow(horizon: "1w", from: nil, to: to, now: to,
                                            ledgerStart: nil).start == day(2026, 9, 24))
        #expect(try PnLWindow.resolveWindow(horizon: "2w", from: nil, to: to, now: to,
                                            ledgerStart: nil).start == day(2026, 9, 17))
        // Calendar months: three full calendar months ending Sep 30
        // start Jul 1; one month back from Sep 30 is Aug 31.
        #expect(try PnLWindow.resolveWindow(horizon: "1m", from: nil, to: to, now: to,
                                            ledgerStart: nil).start == day(2026, 8, 31))
        #expect(try PnLWindow.resolveWindow(horizon: "3m", from: nil, to: to, now: to,
                                            ledgerStart: nil).start == day(2026, 7, 1))
        // Years: 2025-09-30 (+1 day) for 1y.
        #expect(try PnLWindow.resolveWindow(horizon: "1y", from: nil, to: to, now: to,
                                            ledgerStart: nil).start == day(2025, 10, 1))
        #expect(try PnLWindow.resolveWindow(horizon: "ytd", from: nil, to: to, now: to,
                                            ledgerStart: nil).start == day(2026, 1, 1))
    }

    @Test func badHorizonsAndReversedRangesThrow() {
        let to = day(2026, 9, 30)
        #expect(throws: (any Error).self) {
            try PnLWindow.resolveWindow(horizon: "5x", from: nil, to: to, now: to, ledgerStart: nil)
        }
        #expect(throws: (any Error).self) {
            try PnLWindow.resolveWindow(horizon: "0d", from: nil, to: to, now: to, ledgerStart: nil)
        }
        #expect(throws: (any Error).self) {
            try PnLWindow.resolveWindow(horizon: nil, from: day(2026, 9, 10), to: day(2026, 9, 1),
                                        now: to, ledgerStart: nil)
        }
    }

    @Test func defaultWindowStartsAtLedgerStart() throws {
        // Full-history window: nothing was held before the first trade,
        // so P&L can be computed exactly without any baseline price.
        let start = day(2026, 1, 5)
        let window = try PnLWindow.resolveWindow(horizon: nil, from: nil, to: nil, now: day(2026, 9, 30),
                                                 ledgerStart: start)
        #expect(window.start == start)
        #expect(window.fromLedgerStart)
        #expect(window.end == day(2026, 9, 30))
    }

    // MARK: reconciliation with the balance engine

    @Test func windowRealizedSlicesReconcileWithTheWholeLedger() throws {
        let acct = Account(reportingCurrency: .usd, name: "T")
        let txs: [Transaction] = [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 100, price: 60))),
            Transaction(date: day(2026, 3, 1), accountID: acct.id, currency: .usd,
                        kind: .dividend(DividendDetails(ticker: "AAPL", amount: 100))),
            Transaction(date: day(2026, 7, 15), accountID: acct.id, currency: .usd,
                        kind: .stockSale(StockDetails(ticker: "AAPL", shares: 100, price: 80))),
        ]
        let portfolio = Portfolio(accounts: [acct], transactions: txs)
        let full = AccountBalances.compute(account: acct, transactions: txs)
        // Ledger truth: 100 + 2000 booked realized.
        #expect(full.realizedPnLByCurrency[.usd] == dec("2100"))

        let window = PnLReport.Window(start: day(2026, 1, 1), end: day(2026, 12, 31), label: "y")
        let report = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                       perAccount: false, symbols: nil, currencies: nil,
                                       reportingCurrency: .usd, market: nil, fx: nil)
        let rows = report.rows.filter { !$0.isCashPnL }
        // Bought and sold inside the window: the position's market
        // history is irrelevant — its whole P&L is the booked +2100.
        #expect(rows.count == 1)
        #expect(rows[0].symbol == "AAPL")
        #expect(rows[0].realized == dec("2100"))
        #expect(rows[0].total == dec("2100"))
        #expect(report.perCurrency.first?.currency == .usd)
        #expect(report.perCurrency.first?.realized == dec("2100"))
        // Combined total in the account's own currency stays exact.
        #expect(report.combinedTotal == dec("2100"))
    }

    @Test func windowSliceOfRealizedEqualsWholeMinusPrefix() throws {
        // The same ledger cut at 2026-06-30/07-01: what the second
        // half books must equal whole-minus-first-half — the shared
        // prefix cancels in both engines.
        let acct = Account(reportingCurrency: .usd, name: "T")
        let txs: [Transaction] = [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 100, price: 60))),
            Transaction(date: day(2026, 3, 1), accountID: acct.id, currency: .usd,
                        kind: .dividend(DividendDetails(ticker: "AAPL", amount: 100))),
            Transaction(date: day(2026, 7, 15), accountID: acct.id, currency: .usd,
                        kind: .stockSale(StockDetails(ticker: "AAPL", shares: 100, price: 80))),
        ]
        let portfolio = Portfolio(accounts: [acct], transactions: txs)
        func report(_ from: Date, _ to: Date) -> PnLReport {
            PnLWindow.compute(portfolio: portfolio,
                              window: PnLReport.Window(start: from, end: to, label: "t"),
                              accounts: [acct], perAccount: false, symbols: nil, currencies: nil,
                              reportingCurrency: .usd, market: nil, fx: nil)
        }
        let first = report(day(2026, 1, 1), day(2026, 6, 30))
        let second = report(day(2026, 7, 1), day(2026, 12, 31))
        let whole = report(day(2026, 1, 1), day(2026, 12, 31))
        let firstRealized = first.rows.reduce(Decimal(0)) { $0 + $1.realized }
        let secondRealized = second.rows.reduce(Decimal(0)) { $0 + $1.realized }
        let wholeRealized = whole.rows.reduce(Decimal(0)) { $0 + $1.realized }
        #expect(firstRealized == dec("100"))
        #expect(secondRealized == dec("2000"))
        #expect(firstRealized + secondRealized == wholeRealized)
    }

    // MARK: position change

    @Test func midWindowMarketSaleHasNoPhantomPnL() throws {
        // Bought at cost 100, marked 400 when the window opened, sold
        // inside at 350: realized +250, position change −300, TOTAL −50
        // (the economic loss since the window opened). Components must
        // add without double counting.
        let acct = Account(reportingCurrency: .usd, name: "T")
        let txs = [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 100, price: 1))),
            Transaction(date: day(2026, 7, 15), accountID: acct.id, currency: .usd,
                        kind: .stockSale(StockDetails(ticker: "AAPL", shares: 100, price: 3.5))),
        ]
        let portfolio = Portfolio(accounts: [acct], transactions: txs)
        let market = MarketData(series: ["AAPL": series("AAPL", .usd,
                                                        [(day(2026, 6, 30), "4.00"),
                                                         (day(2026, 7, 31), "3.50")])])
        let window = PnLReport.Window(start: day(2026, 7, 1), end: day(2026, 7, 31), label: "test")
        let report = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                       perAccount: false, symbols: nil, currencies: nil,
                                       reportingCurrency: .usd, market: market, fx: nil)
        #expect(report.rows.count == 1)
        let row = report.rows[0]
        #expect(row.realized == dec("250"))
        #expect(row.positionChange == dec("-300"))
        #expect(row.total == dec("-50"))
        #expect(report.perCurrency.first?.total == dec("-50"))
        #expect(report.combinedTotal == dec("-50"))
    }

    @Test func quietPositionDriftShowsWithPricesAndDashesWithout() throws {
        // A position nobody traded that merely drifted IS historical
        // P&L…
        let acct = Account(reportingCurrency: .usd, name: "T")
        let txs = [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 100, price: 50))),
        ]
        let portfolio = Portfolio(accounts: [acct], transactions: txs)
        let window = PnLReport.Window(start: day(2026, 7, 1), end: day(2026, 7, 31), label: "test")
        let withPrices = MarketData(series: ["AAPL": series("AAPL", .usd,
                                                            [(day(2026, 6, 30), "60.00"),
                                                             (day(2026, 7, 31), "65.00")])])
        let priced = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                       perAccount: false, symbols: nil, currencies: nil,
                                       reportingCurrency: .usd, market: withPrices, fx: nil)
        #expect(priced.rows.count == 1)
        #expect(priced.rows[0].positionChange == dec("500"))
        #expect(priced.rows[0].total == dec("500"))

        // …and without a price pair there is nothing measurable: no
        // row, but the symbol is declared in the notes.
        let bare = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                     perAccount: false, symbols: nil, currencies: nil,
                                     reportingCurrency: .usd, market: nil, fx: nil)
        #expect(bare.rows.isEmpty)
        #expect(bare.notes.contains { $0.contains("AAPL") && $0.contains("history") })
    }

    @Test func seriesInForeignCurrencyIsNeverUsed() throws {
        // A series stored in the WRONG currency is not a price for
        // this position (money never converts by accident).
        let acct = Account(reportingCurrency: .cad, name: "T")
        let txs = [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .cad,
                        kind: .stockPurchase(StockDetails(ticker: "SHOP", shares: 100, price: 50))),
        ]
        let portfolio = Portfolio(accounts: [acct], transactions: txs)
        let market = MarketData(series: ["SHOP": series("SHOP", .usd,
                                                        [(day(2026, 6, 30), "60.00"),
                                                         (day(2026, 7, 31), "65.00")])])
        let window = PnLReport.Window(start: day(2026, 7, 1), end: day(2026, 7, 31), label: "test")
        let report = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                       perAccount: false, symbols: nil, currencies: nil,
                                       reportingCurrency: .cad, market: market, fx: nil)
        // The held position cannot be valued → nothing reported, and
        // the report says SHOP was unmeasurable.
        #expect(report.rows.isEmpty)
        #expect(report.notes.contains { $0.contains("SHOP") })
    }

    // MARK: GIC redemption

    @Test func gicRedemptionPnLIsCashIncomeNotPositionChange() throws {
        let gicID = UUID()
        let acct = Account(reportingCurrency: .cad, name: "T")
        let txs = [
            Transaction(id: gicID, date: day(2026, 1, 10), accountID: acct.id, currency: .cad,
                        kind: .gicPurchase(GICDetails(product: "HISA Savings", principal: 1000,
                                                       rate: 0.047, compounding: .annual,
                                                       maturityDate: day(2027, 1, 10),
                                                       redeemable: true))),
            Transaction(date: day(2026, 8, 1), accountID: acct.id, currency: .cad,
                        kind: .gicRedemption(GICRedemptionDetails(purchaseID: gicID, proceeds: 1047))),
        ]
        let portfolio = Portfolio(accounts: [acct], transactions: txs)
        let window = PnLReport.Window(start: day(2026, 7, 1), end: day(2026, 9, 30), label: "test")
        let report = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                       perAccount: false, symbols: nil, currencies: nil,
                                       reportingCurrency: .cad, market: nil, fx: nil)
        #expect(report.rows.count == 1)
        let row = report.rows[0]
        #expect(row.isCashPnL)
        #expect(row.realized == dec("47"))
        // Redemption gain is fully booked in the window — its total is
        // EXACT even with no market data.
        #expect(row.total == dec("47"))
        #expect(report.combinedTotal == dec("47"))
    }

    // MARK: shorts

    @Test func oversoldSaleIsFlaggedAsUntrackedInsideTheWindow() throws {
        let acct = Account(reportingCurrency: .usd, name: "T")
        let txs = [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "XYZ", shares: 100, price: 10))),
            Transaction(date: day(2026, 7, 15), accountID: acct.id, currency: .usd,
                        kind: .stockSale(StockDetails(ticker: "XYZ", shares: 150, price: 12))),
        ]
        let portfolio = Portfolio(accounts: [acct], transactions: txs)
        let window = PnLReport.Window(start: day(2026, 7, 1), end: day(2026, 7, 31), label: "test")
        let report = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                       perAccount: true, symbols: nil, currencies: nil,
                                       reportingCurrency: .usd, market: nil, fx: nil)
        #expect(report.untrackedShorts.count == 1)
        #expect(report.untrackedShorts[0].shares == dec("50"))
        #expect(report.notes.contains { $0.contains("untracked short") })
    }

    // MARK: conversion

    @Test func combinedTotalCombinesOnlyWhenEveryCurrencyConverts() throws {
        let cadAcct = Account(reportingCurrency: .cad, name: "CAD")
        let usdAcct = Account(reportingCurrency: .usd, name: "USD")
        let txs = [
            Transaction(date: day(2026, 1, 5), accountID: cadAcct.id, currency: .cad,
                        kind: .stockPurchase(StockDetails(ticker: "PHYS.TO", shares: 100, price: 25))),
            Transaction(date: day(2026, 1, 6), accountID: usdAcct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 100, price: 60))),
        ]
        let portfolio = Portfolio(accounts: [cadAcct, usdAcct], transactions: txs)
        let window = PnLReport.Window(start: day(2026, 7, 1), end: day(2026, 7, 31), label: "test")
        let market = MarketData(series: [
            "PHYS.TO": series("PHYS.TO", .cad, [(day(2026, 6, 30), "26.00"), (day(2026, 7, 31), "28.00")]),
            "AAPL": series("AAPL", .usd, [(day(2026, 6, 30), "60.00"), (day(2026, 7, 31), "63.00")]),
        ])

        // Dated FX: a USD/CAD close ON the window's as-of date.
        let clock = FXClock(series: ["USD/CAD":
            series("USD/CAD", .cad, [(day(2026, 7, 31), "1.40")])])
        let withRates = PnLWindow.compute(portfolio: portfolio, window: window,
                                          accounts: [cadAcct, usdAcct], perAccount: false,
                                          symbols: nil, currencies: nil, reportingCurrency: .cad,
                                          market: market, fx: clock)
        // CAD drift +200; USD drift +300 × 1.40 = 420 → 620 combined.
        #expect(withRates.combinedTotal == dec("620"))
        #expect(withRates.fxRates[.usd]?.stalenessDays == 0)
        #expect(withRates.fxRates[.usd].map { !$0.approx } == true)

        // A 21-day-old FX close is not "July's FX" either — refused,
        // not stretched.
        let staleClock = FXClock(series: ["USD/CAD":
            series("USD/CAD", .cad, [(day(2026, 7, 10), "1.40")])])
        let stale = PnLWindow.compute(portfolio: portfolio, window: window,
                                      accounts: [cadAcct, usdAcct], perAccount: false,
                                      symbols: nil, currencies: nil, reportingCurrency: .cad,
                                      market: market, fx: staleClock)
        #expect(stale.combinedTotal == nil)
        #expect(stale.unconvertedCurrencies == [.usd])

        // The latest-snapshot rate is NOT history: with no pair series
        // the combined number is withheld, per-currency totals stay
        // native and exact.
        let noRates = PnLWindow.compute(portfolio: portfolio, window: window,
                                        accounts: [cadAcct, usdAcct], perAccount: false,
                                        symbols: nil, currencies: nil, reportingCurrency: .cad,
                                        market: MarketData(series: market.series), fx: nil)
        #expect(noRates.combinedTotal == nil)
        #expect(noRates.unconvertedCurrencies == [.usd])
    }

    // MARK: filters

    @Test func tickerAndCurrencyFiltersLimitScope() throws {
        let acct = Account(reportingCurrency: .usd, name: "T")
        let txs = [
            Transaction(date: day(2026, 7, 10), accountID: acct.id, currency: .usd,
                        kind: .dividend(DividendDetails(ticker: "AAPL", amount: 10))),
            Transaction(date: day(2026, 7, 11), accountID: acct.id, currency: .usd,
                        kind: .dividend(DividendDetails(ticker: "MSFT", amount: 20))),
            Transaction(date: day(2026, 7, 12), accountID: acct.id, currency: .cad,
                        kind: .dividend(DividendDetails(ticker: "SHOP.TO", amount: 30))),
        ]
        let portfolio = Portfolio(accounts: [acct], transactions: txs)
        let window = PnLReport.Window(start: day(2026, 7, 1), end: day(2026, 7, 31), label: "test")
        let tickers = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                        perAccount: false, symbols: ["AAPL"], currencies: nil,
                                        reportingCurrency: .usd, market: nil, fx: nil)
        #expect(tickers.rows.map(\.symbol) == ["AAPL"])
        let ccys = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                     perAccount: false, symbols: nil, currencies: [.cad],
                                     reportingCurrency: .usd, market: nil, fx: nil)
        #expect(ccys.rows.map(\.symbol) == ["SHOP.TO"])
        // A filter that matches nothing is nothing, never a widening.
        let none = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                     perAccount: false, symbols: ["NVDA"], currencies: nil,
                                     reportingCurrency: .usd, market: nil, fx: nil)
        #expect(none.rows.isEmpty)
    }

    // MARK: time series (--time-series)

    @Test func monthlyBucketsCoverEveryDayExactlyOnce() throws {
        // Contiguity is what makes the telescoping identity true: no
        // day may appear in two buckets or in none.
        let window = PnLReport.Window(start: day(2026, 6, 10), end: day(2026, 8, 31), label: "t")
        let buckets = PnLWindow.seriesBuckets(window: window, granularity: .monthly)
        #expect(buckets.map(\.label) == ["2026-06-10…2026-06-30", "2026-07", "2026-08"])
        var covered: [Date] = []
        for bucket in buckets {
            var d = bucket.start
            while d <= bucket.end { covered.append(d); d = PnLWindow.addDays(d, 1) }
        }
        var expected: [Date] = []
        var d = day(2026, 6, 10)
        while d <= day(2026, 8, 31) { expected.append(d); d = PnLWindow.addDays(d, 1) }
        #expect(covered == expected)
    }

    @Test func weeklyBucketsChainAndGranularityScales() throws {
        let window = PnLReport.Window(start: day(2026, 7, 1), end: day(2026, 7, 31), label: "t")
        let buckets = PnLWindow.seriesBuckets(window: window, granularity: .weekly)
        #expect(buckets.count == 5)
        #expect(buckets.map { $0.end.timeIntervalSince($0.start) / 86_400 + 1 } == [7, 7, 7, 7, 3])
        // Auto-pick keeps a window to a handful of readable periods.
        #expect(PnLWindow.autoGranularity(window: window) == .weekly)
        let twoMonths = PnLReport.Window(start: day(2026, 6, 1), end: day(2026, 7, 31), label: "t")
        #expect(PnLWindow.autoGranularity(window: twoMonths) == .monthly)
        let twelve = PnLReport.Window(start: day(2026, 7, 20), end: day(2026, 7, 31), label: "t")
        #expect(PnLWindow.autoGranularity(window: twelve) == .weekly)
        let short = PnLReport.Window(start: day(2026, 7, 22), end: day(2026, 7, 31), label: "t")
        #expect(PnLWindow.autoGranularity(window: short) == .daily)
    }

    /// The pinned fixture: 10 @ 5 bought Jun 10 (cost 50), half sold
    /// Jul 10 at 8 (+15), a 7 dividend Jul 20; closes 6.00 (Jun 30)
    /// and 8.00 (Jul 31). June drift = 60−50 = +10 (marked from cost,
    /// born inside June); July = realized 22 + drift 5 (10 shares at
    /// 6.00 → 5 shares at 8.00) = 27.
    private func pinnedFixture() -> (Portfolio, Account) {
        let acct = Account(reportingCurrency: .usd, name: "T")
        let txs: [Transaction] = [
            Transaction(date: day(2026, 6, 10), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "WIDE", shares: 10, price: 5))),
            Transaction(date: day(2026, 7, 10), accountID: acct.id, currency: .usd,
                        kind: .stockSale(StockDetails(ticker: "WIDE", shares: 5, price: 8))),
            Transaction(date: day(2026, 7, 20), accountID: acct.id, currency: .usd,
                        kind: .dividend(DividendDetails(ticker: "WIDE", amount: 7))),
        ]
        return (Portfolio(accounts: [acct], transactions: txs), acct)
    }

    @Test func seriesTelescopesToTheWindowTotalWhenEveryBucketIsPriced() throws {
        let (portfolio, acct) = pinnedFixture()
        let market = MarketData(series: ["WIDE":
            series("WIDE", .usd, [(day(2026, 6, 30), "6.00"), (day(2026, 7, 31), "8.00")])])
        let window = PnLReport.Window(start: day(2026, 6, 1), end: day(2026, 7, 31), label: "t")
        let full = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                     perAccount: false, symbols: nil, currencies: nil,
                                     reportingCurrency: .usd, market: market, fx: nil)
        let seriesResult = PnLWindow.computeSeries(portfolio: portfolio, window: window,
                                                   granularity: .monthly, accounts: [acct],
                                                   perAccount: false, symbols: nil, currencies: nil,
                                                   reportingCurrency: .usd, market: market,
                                                   fx: nil, fullReport: full)
        #expect(seriesResult.granularity == .monthly)
        #expect(seriesResult.points.count == 2)
        let june = seriesResult.points[0]
        let july = seriesResult.points[1]
        #expect(june.label == "2026-06")
        #expect(july.label == "2026-07")
        #expect(june.report.perCurrency.first?.total == dec("10.00"))
        #expect(july.report.perCurrency.first?.realized == dec("22.00"))
        #expect(july.report.perCurrency.first?.positionChange == dec("5.00"))
        #expect(july.report.perCurrency.first?.total == dec("27.00"))
        // The whole point of contiguous buckets: they ADD BACK.
        #expect(seriesResult.reconciles)
        #expect(full.perCurrency.first?.total == dec("37.00"))
    }

    @Test func quietPeriodsWithEqualPricesCollapseAndKeepTheSumExact() throws {
        let (portfolio, acct) = pinnedFixture()
        // August and September keep the last price (8.00): zero drift
        // is a MEASURED zero, not a gap — collapsed, and the series
        // still reconciles.
        let market = MarketData(series: ["WIDE":
            series("WIDE", .usd, [(day(2026, 6, 30), "6.00"), (day(2026, 7, 31), "8.00"),
                                  (day(2026, 9, 30), "8.00")])])
        let window = PnLReport.Window(start: day(2026, 6, 1), end: day(2026, 9, 30), label: "t")
        let full = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                     perAccount: false, symbols: nil, currencies: nil,
                                     reportingCurrency: .usd, market: market, fx: nil)
        let seriesResult = PnLWindow.computeSeries(portfolio: portfolio, window: window,
                                                   granularity: .monthly, accounts: [acct],
                                                   perAccount: false, symbols: nil, currencies: nil,
                                                   reportingCurrency: .usd, market: market,
                                                   fx: nil, fullReport: full)
        #expect(seriesResult.collapsedEmpty == 2) // Aug, Sep: measured zero drift
        #expect(seriesResult.collapsedUnmeasurable == 0)
        #expect(seriesResult.reconciles)
    }

    @Test func unmeasurableBucketsBreakTheSumAndAreCountedNotHidden() throws {
        let (portfolio, acct) = pinnedFixture()
        // NO market at all: June drift is unknowable (born mid-June,
        // no baseline/closing price), July books facts but dashes the
        // total, August silently holds an unmeasurable position. None
        // of it may collapse into a fake "0.00" or a reconciled sum.
        let window = PnLReport.Window(start: day(2026, 6, 1), end: day(2026, 8, 31), label: "t")
        let full = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                     perAccount: false, symbols: nil, currencies: nil,
                                     reportingCurrency: .usd, market: nil, fx: nil)
        let seriesResult = PnLWindow.computeSeries(portfolio: portfolio, window: window,
                                                   granularity: .monthly, accounts: [acct],
                                                   perAccount: false, symbols: nil, currencies: nil,
                                                   reportingCurrency: .usd, market: nil,
                                                   fx: nil, fullReport: full)
        #expect(seriesResult.points.count == 1)          // only July (booked facts)
        #expect(seriesResult.points[0].report.perCurrency.first?.total == nil) // dashed
        #expect(seriesResult.collapsedUnmeasurable == 2) // June and August
        #expect(!seriesResult.reconciles)
        #expect(full.combinedTotal == nil)               // window total withheld too
    }

    @Test func forcedDailySlicesStayHonestWithSparseAndDensePrices() throws {
        let (portfolio, acct) = pinnedFixture()
        func dailySeries(_ market: MarketData?) -> (PnLSeries, PnLReport) {
            let window = PnLReport.Window(start: day(2026, 6, 1), end: day(2026, 7, 31), label: "t")
            let full = PnLWindow.compute(portfolio: portfolio, window: window, accounts: [acct],
                                         perAccount: false, symbols: nil, currencies: nil,
                                         reportingCurrency: .usd, market: market, fx: nil)
            let seriesResult = PnLWindow.computeSeries(portfolio: portfolio, window: window,
                                                       granularity: .daily, accounts: [acct],
                                                       perAccount: false, symbols: nil,
                                                       currencies: nil, reportingCurrency: .usd,
                                                       market: market, fx: nil,
                                                       fullReport: full)
            return (seriesResult, full)
        }
        // SPARSE: two closes only. Days without a baseline are gaps —
        // the series must refuse to sum, never present its partial
        // totals as the answer.
        let sparse = dailySeries(MarketData(series: ["WIDE":
            series("WIDE", .usd, [(day(2026, 6, 30), "6.00"), (day(2026, 7, 31), "8.00")])]))
        #expect(!sparse.0.reconciles)
        #expect(sparse.0.collapsedUnmeasurable > 0)
        // DENSE: a close EVERY day (6.00 June 10 through Jul 31). Now
        // every day is measurable and the identity must hold exactly:
        // +10 (Jun 10, born at 6.00) + 10 (Jul 10: −5 drift + 15 sale)
        // + 7 (Jul 20 dividend) = 27 = the window total.
        var dense: [(Date, String)] = []
        var d = day(2026, 6, 10)
        while d <= day(2026, 7, 31) { dense.append((d, "6.00")); d = PnLWindow.addDays(d, 1) }
        let denseResult = dailySeries(MarketData(series: ["WIDE": series("WIDE", .usd, dense)]))
        #expect(denseResult.0.reconciles)
        #expect(denseResult.0.collapsedUnmeasurable == 0)
        let sum = denseResult.0.points.flatMap(\.report.perCurrency)
            .reduce(Decimal.zero) { $0 + ($1.total ?? 0) }
        #expect(sum == dec("27.00"))
        #expect(denseResult.1.perCurrency.first?.total == dec("27.00"))
    }
}
