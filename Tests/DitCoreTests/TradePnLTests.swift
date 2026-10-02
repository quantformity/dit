import Testing
import Foundation
@testable import DitCore

/// Transaction-level P&L (`dit tx pnl`). Every expectation is
/// hand-computed from the ledger, and one test pins the CONTRACT that
/// makes the whole view trustworthy: summed, it equals the window
/// engine's full-history report for the same scope — two views, one
/// truth.
struct TradePnLTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func day(_ n: Double) -> Date { base.addingTimeInterval(n * 86_400) }
    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private let a1 = Account(reportingCurrency: .usd, name: "Alfred One", institution: "AO")
    private let a2 = Account(reportingCurrency: .cad, name: "Alfred Two", institution: "AO")

    private func tx(_ account: Account, _ d: Double, _ currency: Currency,
                    _ kind: Transaction.Kind, fee: Decimal? = nil) -> Transaction {
        Transaction(date: day(d), accountID: account.id, currency: currency, kind: kind, fee: fee)
    }

    private func series(_ symbol: String, _ currency: Currency, _ points: [(Double, Decimal)]) -> PriceSeries {
        PriceSeries(symbol: symbol, currency: currency,
                    points: points.map { DailyPrice(day: day($0.0), price: $0.1) })
    }

    // MARK: The WIDE fixture — buy 10 @ 5, sell 5 @ 8, dividend 7,
    // closes 6.00 and 8.00. Hand-checked: sale books 40 − 25 = +15,
    // dividend +7, open 5 sh × 8 − 25 = +15 → USD total +37.

    private var widePortfolio: Portfolio {
        Portfolio(accounts: [a1], transactions: [
            tx(a1, 10, .usd, .stockPurchase(StockDetails(ticker: "WIDE", shares: 10, price: 5))),
            tx(a1, 30, .usd, .stockSale(StockDetails(ticker: "WIDE", shares: 5, price: 8))),
            tx(a1, 32, .usd, .dividend(DividendDetails(ticker: "WIDE", amount: 7))),
        ])
    }

    private var wideMarket: MarketData {
        MarketData(series: ["WIDE": series("WIDE", .usd, [(22, dec("6.00")), (33, dec("8.00"))])])
    }

    @Test("booked rows carry the time-of-sale cost, not today's price")
    func handCheckedLedger() {
        let report = TradePnL.compute(portfolio: widePortfolio, accounts: [a1], asOf: day(35),
                                      market: wideMarket, symbols: nil, currencies: nil)
        #expect(report.booked.count == 2)
        let sell = report.booked.first { $0.kind == "sell" }
        #expect(sell?.pnl == Decimal(15))
        #expect(sell?.detail.contains("cost 25.00") == true)
        let open = report.open.first
        #expect(open?.unrealized == Decimal(15))       // 5 × 8 − 25
        #expect(report.perCurrency.first?.total == Decimal(37))
    }

    @Test("fees join the cost pool on the buy and net out on the event")
    func feesInAndOut() {
        // buy 100 @ 10 (+1 fee) → pool 1,001; sell 40 @ 12 (−1 fee):
        // proceeds 479 − removed cost 400.40 = +78.60.
        let portfolio = Portfolio(accounts: [a1], transactions: [
            tx(a1, 10, .usd, .stockPurchase(StockDetails(ticker: "FAST", shares: 100, price: 10)),
               fee: 1),
            tx(a1, 30, .usd, .stockSale(StockDetails(ticker: "FAST", shares: 40, price: 12)),
               fee: 1),
        ])
        let market = MarketData(series: ["FAST": series("FAST", .usd, [(31, dec("11"))])])
        let report = TradePnL.compute(portfolio: portfolio, accounts: [a1], asOf: day(35),
                                      market: market, symbols: nil, currencies: nil)
        #expect(report.booked.first?.pnl == dec("78.60"))
        // 60 sh × 11 − 600.60 remaining cost = +59.40 → total 138.00.
        #expect(report.open.first?.unrealized == dec("59.40"))
        #expect(report.perCurrency.first?.total == dec("138.00"))
    }

    @Test("no stored close → dashed unrealized, withheld totals, never zero")
    func unmarkedPositionIsNotZero() {
        let report = TradePnL.compute(portfolio: widePortfolio, accounts: [a1], asOf: day(35),
                                      market: nil, symbols: nil, currencies: nil)
        let open = report.open.first
        #expect(open?.unrealized == nil)
        #expect(open?.mark == nil)
        let usd = report.perCurrency.first
        #expect(usd?.open == nil)
        #expect(usd?.total == nil)
        #expect(usd?.booked == Decimal(22)) // ledger facts survive the missing prices
        #expect(report.notes.contains { $0.contains("DASHED") && $0.contains("WIDE") })
    }

    @Test("a series in a foreign currency is never used as a mark")
    func foreignSeriesIgnored() {
        let portfolio = Portfolio(accounts: [a2], transactions: [
            tx(a2, 10, .cad, .stockPurchase(StockDetails(ticker: "SHOP.TO", shares: 10, price: 100))),
        ])
        let wrongCcy = MarketData(series: ["SHOP.TO": series("SHOP.TO", .usd, [(30, dec("999"))])])
        let report = TradePnL.compute(portfolio: portfolio, accounts: [a2], asOf: day(35),
                                      market: wrongCcy, symbols: nil, currencies: nil)
        #expect(report.open.first?.unrealized == nil)
        // An UNLABELLED series (currency unknown) is taken at face
        // value as quoted in the position's currency, per the engine.
        let unlabelled = MarketData(series: ["SHOP.TO": series("SHOP.TO", .unknown, [(30, dec("120"))])])
        let trusted = TradePnL.compute(portfolio: portfolio, accounts: [a2], asOf: day(35),
                                       market: unlabelled, symbols: nil, currencies: nil)
        #expect(trusted.open.first?.unrealized == Decimal(200)) // 10 × 120 − 1,000
    }

    @Test("GIC redemption books proceeds minus recorded principal; an orphan redemption is skipped, loudly")
    func gicPaths() {
        let purchase = tx(a2, 10, .cad, .gicPurchase(GICDetails(
            product: "3-Year GIC", principal: 1500, rate: dec("0.04"),
            compounding: .annual, maturityDate: day(400), redeemable: false)))
        let redemption = tx(a2, 100, .cad,
                            .gicRedemption(GICRedemptionDetails(purchaseID: purchase.id, proceeds: 1560)))
        let orphan = tx(a2, 120, .cad,
                        .gicRedemption(GICRedemptionDetails(purchaseID: UUID(), proceeds: 999)))
        let portfolio = Portfolio(accounts: [a2], transactions: [purchase, redemption, orphan])
        let report = TradePnL.compute(portfolio: portfolio, accounts: [a2], asOf: day(121),
                                      market: nil, symbols: nil, currencies: nil)
        #expect(report.booked.count == 1) // the orphan booked nothing…
        #expect(report.booked.first?.pnl == Decimal(60))
        #expect(report.booked.first?.symbol == "GIC: 3-Year GIC")
        // …and the skip is named, not silent.
        #expect(report.notes.contains { $0.contains("without a recorded purchase") })
    }

    @Test("a sale beyond the holding books with a short flag and withholds totals")
    func oversoldFlagsTotals() {
        let portfolio = Portfolio(accounts: [a1], transactions: [
            tx(a1, 10, .usd, .stockPurchase(StockDetails(ticker: "FAST", shares: 10, price: 5))),
            tx(a1, 30, .usd, .stockSale(StockDetails(ticker: "FAST", shares: 14, price: 6))),
        ])
        let report = TradePnL.compute(portfolio: portfolio, accounts: [a1], asOf: day(31),
                                      market: nil, symbols: nil, currencies: nil)
        let sell = report.booked.first
        #expect(sell?.pnl == Decimal(34)) // 84 − 50 (full liquidation of the tracked pool)
        #expect(sell?.incomplete == true)
        #expect(report.perCurrency.first?.total == nil) // knowingly incomplete
        #expect(report.notes.contains { $0.contains("short") })
    }

    @Test("dividends book without any position; the ticker filter keeps GIC cash rows")
    func incomeAndFilters() {
        let gicPurchase = tx(a1, 5, .usd, .gicPurchase(GICDetails(
            product: "Bill GIC", principal: 500, rate: dec("0.05"),
            compounding: .annual, maturityDate: day(200), redeemable: true)))
        let gicRedeem = tx(a1, 90, .usd,
                           .gicRedemption(GICRedemptionDetails(purchaseID: gicPurchase.id, proceeds: 520)))
        let portfolio = Portfolio(accounts: [a1], transactions: [
            tx(a1, 10, .usd, .dividend(DividendDetails(ticker: "FLATCO", amount: 12))),
            gicPurchase, gicRedeem,
        ])
        // Dividend while never holding FLATCO: still an exact ledger fact.
        let all = TradePnL.compute(portfolio: portfolio, accounts: [a1], asOf: day(91),
                                   market: nil, symbols: nil, currencies: nil)
        #expect(all.booked.count == 2)
        #expect(all.booked.contains { $0.kind == "dividend" && $0.pnl == Decimal(12) })
        // Ticker whitelist: FLATCO drops, the GIC redemption stays
        // (cash P&L has no ticker to match — same rule as the window
        // engine).
        let filtered = TradePnL.compute(portfolio: portfolio, accounts: [a1], asOf: day(91),
                                        market: nil, symbols: ["WIDE"], currencies: nil)
        #expect(filtered.booked.count == 1)
        #expect(filtered.booked.first?.kind == "gic-redemption")
    }

    @Test("summed, the transaction view equals the window engine's full-history report")
    func reconcilesWithWindowEngine() throws {
        // WIDE (marked) + GHOST (bought, never sold, no prices): the
        // window engine DROPS the unmarked ghost drift; the
        // transaction view shows it dashed. Both must therefore agree
        // on what is KNOWN and both must refuse a USD total.
        let portfolio = Portfolio(accounts: [a1], transactions: [
            tx(a1, 10, .usd, .stockPurchase(StockDetails(ticker: "WIDE", shares: 10, price: 5))),
            tx(a1, 12, .usd, .stockPurchase(StockDetails(ticker: "GHOST", shares: 10, price: 2))),
            tx(a1, 30, .usd, .stockSale(StockDetails(ticker: "WIDE", shares: 5, price: 8))),
            tx(a1, 32, .usd, .dividend(DividendDetails(ticker: "WIDE", amount: 7))),
        ])
        let market = MarketData(series: ["WIDE": series("WIDE", .usd, [(22, dec("6.00")), (33, dec("8.00"))])])
        // Windows come from the PRODUCTION resolver — a hand-built
        // window with a mid-day timestamp silently moves the replay
        // boundary (a day-10 buy would count as "before the window"),
        // which is exactly how this test first failed: the engines
        // were right, the window was wrong.
        let end = day(35)
        func window() throws -> PnLReport.Window {
            try PnLWindow.resolveWindow(horizon: nil, from: nil, to: end, now: end,
                                        ledgerStart: day(10))
        }
        let w = try window()
        let tradeReport = TradePnL.compute(portfolio: portfolio, accounts: [a1], asOf: end,
                                           market: market, symbols: nil, currencies: nil)
        let windowReport = PnLWindow.compute(portfolio: portfolio, window: w,
                                             accounts: [a1], perAccount: true,
                                             symbols: nil, currencies: nil,
                                             reportingCurrency: .usd, market: market, fx: nil)
        // GHOST (unmeasurable, nothing booked) is NOT a pin-point
        // disagreement: the window engine drops quiet-unmeasurable
        // rows, so its total quietly omits the ghost (footnoted);
        // this view SHOWS the dashed position and REFUSES the total
        // (a total that silently omits a holding is the harsher lie).
        // Stricter here, never looser — that asymmetry is deliberate.
        #expect(windowReport.perCurrency.first?.total == Decimal(37))
        #expect(tradeReport.perCurrency.first?.total == nil)

        // Scoped to WIDE, both views are complete and must AGREE.
        // Half-cent tolerance = max regrouping dust between the
        // event sum and the boundary difference; more is a real
        // disagreement and must fail.
        let scopedWindow = PnLWindow.compute(portfolio: portfolio, window: w,
                                             accounts: [a1], perAccount: true,
                                             symbols: ["WIDE"], currencies: nil,
                                             reportingCurrency: .usd, market: market, fx: nil)
        let scopedTrade = TradePnL.compute(portfolio: portfolio, accounts: [a1], asOf: end,
                                           market: market, symbols: ["WIDE"], currencies: nil)
        let windowTotal = scopedWindow.perCurrency.first?.total
        let tradeTotal = scopedTrade.perCurrency.first?.total
        if let windowTotal, let tradeTotal {
            #expect(abs(windowTotal - tradeTotal) < dec("0.01"),
                    "window \(windowTotal) vs transactions \(tradeTotal)")
            #expect(tradeTotal == Decimal(37)) // the hand-checked ledger
        } else {
            Issue.record("both views must be complete for a WIDE-only scope: \(String(describing: windowTotal)) vs \(String(describing: tradeTotal))")
        }
    }
}