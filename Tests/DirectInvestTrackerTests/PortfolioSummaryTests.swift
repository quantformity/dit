import Testing
import Foundation
@testable import DirectInvestTracker

/// NOTE on Decimal expectations: in `#expect`, an integer/float literal
/// *expression* (e.g. `a + b`) is inferred as Int/Double by the macro's
/// operand capture and then compared across types — which fails for
/// equal values. Always compare Decimals against an annotated variable
/// or a single literal.
struct PortfolioSummaryTests {

    // MARK: Fixtures

    private let td = Account(reportingCurrency: .cad, name: "TD Direct", institution: "TD")
    private let qt = Account(reportingCurrency: .usd, name: "Questrade", institution: "Questrade")

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func day(_ n: Double) -> Date { base.addingTimeInterval(n * 86_400) }

    private func deposit(_ account: Account, _ amount: Decimal, on d: Date) -> Transaction {
        Transaction(date: d, accountID: account.id, currency: account.reportingCurrency,
                    kind: .deposit(amount: amount))
    }

    private func buy(_ account: Account, _ ticker: String, shares: Decimal, at price: Decimal, on d: Date) -> Transaction {
        Transaction(date: d, accountID: account.id, currency: account.reportingCurrency,
                    kind: .stockPurchase(StockDetails(ticker: ticker, shares: shares, price: price)))
    }

    private func sell(_ account: Account, _ ticker: String, shares: Decimal, at price: Decimal, on d: Date) -> Transaction {
        Transaction(date: d, accountID: account.id, currency: account.reportingCurrency,
                    kind: .stockSale(StockDetails(ticker: ticker, shares: shares, price: price)))
    }

    /// The two-account, two-currency portfolio used by most tests.
    ///
    /// TD Direct (CAD): 10k deposit; 100 SHOP.TO @ 60; 50 ENB.TO @ 40;
    /// 1.5k GIC; 30 dividend. Cash ends at 530.
    /// Questrade (USD): 10k deposit; 100 SHOP.TO @ 70; 40 sold @ 80
    /// (realized +400, 60 left @ 70). Cash ends at 6200.
    private var portfolio: Portfolio {
        let gic = Transaction(
            date: day(4), accountID: td.id, currency: .cad,
            kind: .gicPurchase(GICDetails(
                product: "3-Year GIC", principal: 1500, rate: Decimal(string: "0.04")!,
                compounding: .annual, maturityDate: day(400), redeemable: false
            ))
        )
        let shopDividend = Transaction(
            date: day(5), accountID: td.id, currency: .cad,
            kind: .dividend(DividendDetails(ticker: "SHOP.TO", amount: 30))
        )
        return Portfolio(
            accounts: [td, qt],
            transactions: [
                deposit(td, 10_000, on: day(1)),
                buy(td, "SHOP.TO", shares: 100, at: 60, on: day(2)),
                buy(td, "ENB.TO", shares: 50, at: 40, on: day(3)),
                gic,
                shopDividend,
                deposit(qt, 10_000, on: day(1)),
                buy(qt, "SHOP.TO", shares: 100, at: 70, on: day(2)),
                sell(qt, "SHOP.TO", shares: 40, at: 80, on: day(3)),
            ],
            tickers: [
                EquityTicker(symbol: "SHOP.TO", name: "Shopify Inc."),
                EquityTicker(symbol: "ENB.TO", name: "Enbridge Inc."),
            ]
        )
    }

    /// Quotes: SHOP.TO 65 CAD / 75 USD; ENB.TO unquoted.
    private func quoteStub() -> LastPrice {
        { currency, symbol in
            if symbol == "SHOP.TO" {
                return currency == .cad ? Decimal(65) : (currency == .usd ? Decimal(75) : nil)
            }
            return nil
        }
    }

    /// Only USD→CAD 1.35 is known.
    private func rateStub() -> FXRate {
        { from, to in
            from == .usd && to == .cad ? Decimal(string: "1.35")! : nil
        }
    }

    // MARK: Aggregation

    @Test func aggregatesAcrossAccountsInDisplayCurrency() {
        let s = portfolio.summary(rate: rateStub(), lastPrice: quoteStub())

        #expect(s.displayCurrency == Currency.cad)
        #expect(s.accounts.count == 2)

        // Combined in CAD (Questrade's USD components × 1.35).
        let cash: Decimal = 8_900          // 530 + 6200 × 1.35
        let positionValue: Decimal = 14_575 // (6500 + 2000) + 4500 × 1.35
        let gic: Decimal = 1_500
        let total: Decimal = 24_975
        let realized: Decimal = 570        // 30 + 400 × 1.35
        let dividends: Decimal = 30
        let unrealized: Decimal = 905      // 500 + 300 × 1.35

        #expect(s.cash == cash)
        #expect(s.positionValue == positionValue)
        #expect(s.gicValue == gic)
        #expect(s.totalValue == total)
        #expect(s.realizedPnL == realized)
        #expect(s.dividends == dividends)
        #expect(s.unrealizedPnL == unrealized)

        // The per-currency breakdowns stay exact, conversion-free.
        #expect(s.cashByCurrency == [Currency.cad: 530, .usd: 6200])
        #expect(s.positionValueByCurrency == [Currency.cad: 8500, .usd: 4500])
        #expect(s.gicValueByCurrency == [Currency.cad: 1500])
        #expect(s.realizedPnLByCurrency == [Currency.cad: 30, .usd: 400])
        #expect(s.dividendsByCurrency == [Currency.cad: 30])
        #expect(s.unrealizedPnLByCurrency == [Currency.cad: 500, .usd: 300])
        #expect(s.valueByCurrency == [Currency.cad: 10_530, .usd: 10_700])

        // Accounts sort by total value: Questrade (14 445) before TD (10 530).
        #expect(s.accounts[0].account.name == "Questrade")
        #expect(s.accounts[1].account.name == "TD Direct")
    }

    @Test func combinedValuesAreNilWithoutRates() {
        let s = portfolio.summary() // no rate, no quotes

        #expect(s.cash == nil)            // USD component unconvertible to CAD
        #expect(s.positionValue == nil)
        #expect(s.totalValue == nil)
        #expect(s.realizedPnL == nil)
        #expect(s.unrealizedPnL == nil)   // no quotes at all
        #expect(s.gicValue == 1_500)      // everything in the display currency
        #expect(s.dividends == 30)        // likewise
        #expect(s.cashByCurrency == [Currency.cad: 530, .usd: 6200]) // still exact

        // Without a rate, neither account can be converted into the
        // display currency for sorting, so the stable insertion order
        // stands. Each single-currency account still computes its own
        // value (no conversion needed internally).
        #expect(s.accounts[0].account.name == "TD Direct")
        #expect(s.accounts[0].totalValue == 10_030)
        #expect(s.accounts[1].account.name == "Questrade")
        #expect(s.accounts[1].totalValue == 10_400)
    }

    // MARK: Holdings table

    @Test func holdingsTableConsolidatesAcrossAccounts() {
        let s = portfolio.summary(rate: rateStub(), lastPrice: quoteStub())

        #expect(s.holdings.count == 3)
        // Alphabetical by symbol; SHOP.TO appears twice, CAD before USD.
        #expect(s.holdings.map(\.symbol) == ["ENB.TO", "SHOP.TO", "SHOP.TO"])

        // ENB.TO: no quote → cost-basis value, no unrealized P&L.
        let enb = s.holdings[0]
        #expect(enb.symbol == "ENB.TO")
        #expect(enb.name == "Enbridge Inc.")
        #expect(enb.shares == 50)
        #expect(enb.value == 2000)
        #expect(enb.unrealizedPnL == nil)

        let shopC = s.holdings[1]
        #expect(shopC.symbol == "SHOP.TO")
        #expect(shopC.name == "Shopify Inc.")
        #expect(shopC.currency == Currency.cad)
        #expect(shopC.shares == 100)
        #expect(shopC.averageCostPerShare == 60)
        #expect(shopC.costBasis == 6_000)
        #expect(shopC.value == 6500)
        #expect(shopC.unrealizedPnL == 500)
        #expect(shopC.accountNames == ["TD Direct"])

        let shopU = s.holdings[2]
        #expect(shopU.symbol == "SHOP.TO")
        #expect(shopU.currency == Currency.usd)
        #expect(shopU.shares == 60)
        #expect(shopU.averageCostPerShare == 70)
        #expect(shopU.value == 4500)
        #expect(shopU.unrealizedPnL == 300)
        #expect(shopU.accountNames == ["Questrade"])
    }

    @Test func sameTickerInSameCurrencyMergesAcrossAccounts() {
        let a = Account(reportingCurrency: .cad, name: "Wealthsimple")
        let b = Account(reportingCurrency: .cad, name: "Questrade")
        let p = Portfolio(
            accounts: [a, b],
            transactions: [
                deposit(a, 3_000, on: day(1)),
                buy(a, "SHOP.TO", shares: 10, at: 60, on: day(2)),
                deposit(b, 2_000, on: day(1)),
                buy(b, "SHOP.TO", shares: 10, at: 62, on: day(2)),
            ],
            tickers: [EquityTicker(symbol: "SHOP.TO", name: "Shopify Inc.")]
        )
        let s = p.summary() // no quotes → cost basis

        #expect(s.holdings.count == 1)
        let h = s.holdings[0]
        #expect(h.shares == 20)
        #expect(h.averageCostPerShare == 61) // (600 + 620) / 20 — exact in decimal
        #expect(h.costBasis == 1_220)
        #expect(h.value == 1_220)
        #expect(h.unrealizedPnL == nil)
        #expect(h.accountNames == ["Questrade", "Wealthsimple"])
    }

    // MARK: Degenerate inputs

    @Test func emptyPortfolioIsAllZeros() {
        let s = Portfolio().summary()

        #expect(s.accounts.isEmpty)
        #expect(s.holdings.isEmpty)
        #expect(s.valueByCurrency.isEmpty)
        #expect(s.cash == 0)
        #expect(s.positionValue == 0)
        #expect(s.gicValue == 0)
        #expect(s.realizedPnL == 0)
        #expect(s.dividends == 0)
        #expect(s.unrealizedPnL == nil) // "no data", not "no gain"
        #expect(s.totalValue == 0)
    }

    // MARK: Cache convenience

    @Test func summaryFromCacheUsesFreshQuotesOnly() {
        let now = Date()
        let account = Account(reportingCurrency: .cad, name: "TD Direct")
        let p = Portfolio(
            accounts: [account],
            transactions: [
                deposit(account, 10_000, on: day(1)),
                buy(account, "SHOP.TO", shares: 100, at: 60, on: day(2)),
            ]
        )

        // Fresh quote → marked to market.
        let fresh = MarketDataCache()
        fresh.upsert(MarketQuote(symbol: "SHOP.TO", currency: .cad, price: 65, asOf: now))
        let s1 = p.summary(from: fresh, now: now)
        #expect(s1.totalValue == 10_500) // 4000 cash + 100 × 65
        #expect(s1.unrealizedPnL == 500)

        // Stale quote → falls back to cost basis.
        let stale = MarketDataCache()
        stale.upsert(MarketQuote(symbol: "SHOP.TO", currency: .cad, price: 65,
                                 asOf: now.addingTimeInterval(-3_600)))
        let s2 = p.summary(from: stale, now: now)
        #expect(s2.totalValue == 10_000) // 4000 + 100 × 60 (cost)
        #expect(s2.unrealizedPnL == nil)

        // Currency-mismatched quote → falls back to cost basis.
        let wrongCurrency = MarketDataCache()
        wrongCurrency.upsert(MarketQuote(symbol: "SHOP.TO", currency: .usd, price: 65, asOf: now))
        let s3 = p.summary(from: wrongCurrency, now: now)
        #expect(s3.totalValue == 10_000)
        #expect(s3.holdings[0].unrealizedPnL == nil)
    }

    // MARK: marketDataPlan

    @Test func marketDataPlanCollectsPositionSymbolsAndNonHubCurrencies() {
        let plan = portfolio.marketDataPlan() // display CAD, hub USD

        // Open positions only — fully sold and redeemed things are
        // gone (SHOP.TO in USD is still held, via Questrade).
        #expect(plan.symbols == ["ENB.TO", "SHOP.TO"])
        // Currencies involved: CAD (TD) + USD (Questrade) + display
        // CAD. The hub (USD) needs no fetch; CAD does.
        #expect(plan.fxCurrencies == [.cad])
        #expect(plan.hub == .usd)
    }

    @Test func marketDataPlanAllHubCurrencyNeedsNoFx() {
        let allUsd = Portfolio(accounts: [qt], transactions: [deposit(qt, 1_000, on: day(1))])
        let plan = allUsd.marketDataPlan(displayCurrency: .usd)
        #expect(plan.symbols.isEmpty)
        #expect(plan.fxCurrencies.isEmpty)
    }

    // MARK: One-day P&L (quote vs previous available close)

    /// TD (CAD): 100 ENB.TO @ 40, quoted 40.8 against a prior close of
    /// 40.0 → +80 CAD. QT (USD): 60 NVDA @ 180, quoted 178 against a
    /// DERIVED prior close of 180 → −120 USD. At USD→CAD 1.40 the
    /// combined day change is 80 − 168 = −88 CAD.
    private var dayPnLPortfolio: Portfolio {
        let td = Account(reportingCurrency: .cad, name: "TD")
        let qt = Account(reportingCurrency: .usd, name: "QT")
        return Portfolio(
            accounts: [td, qt],
            transactions: [
                deposit(td, 10_000, on: day(1)),
                buy(td, "ENB.TO", shares: 100, at: 40, on: day(2)),
                deposit(qt, 12_000, on: day(1)),
                buy(qt, "NVDA", shares: 60, at: 180, on: day(2)),
            ],
            tickers: [
                EquityTicker(symbol: "ENB.TO", name: "Enbridge"),
                EquityTicker(symbol: "NVDA", name: "Nvidia"),
            ]
        )
    }

    @Test func dayChangeIsExactPerCurrencyAndCombinedOnce() {
        let p408 = Decimal(string: "40.8")!
        let p178: Decimal = 178
        let p40: Decimal = 40
        let p180: Decimal = 180
        let s = dayPnLPortfolio.summary(
            rate: { from, to in from == .usd && to == .cad ? Decimal(string: "1.40")! : nil },
            lastPrice: { c, sym in
                if c == .cad && sym == "ENB.TO" { return p408 }
                if c == .usd && sym == "NVDA" { return p178 }
                return nil
            },
            dayPrices: { c, sym in
                if c == .cad && sym == "ENB.TO" { return DayPricePair(current: p408, previous: p40) }
                if c == .usd && sym == "NVDA" { return DayPricePair(current: p178, previous: p180, modelBaseline: true) }
                return nil
            }
        )

        // Native sums stay exact; conversion happens only in the combined
        // figure (no FX drift masquerading as trading P&L).
        #expect(s.dayChangeByCurrency == [Currency.cad: 80, Currency.usd: -120])
        let combinedDay: Decimal = -88
        #expect(s.dayChange == combinedDay)

        // Account rows in their reporting currency…
        let td = s.accounts.first { $0.account.name == "TD" }!
        let qt = s.accounts.first { $0.account.name == "QT" }!
        #expect(td.dayChangeByCurrency == [Currency.cad: 80])
        #expect(qt.dayChangeByCurrency == [Currency.usd: -120])
        let ownCurrency: Decimal = -120
        #expect(qt.dayChange == ownCurrency) // USD account: no conversion

        // Holdings carry the native day change and the price move.
        let enb = s.holdings.first { $0.symbol == "ENB.TO" }!
        let nvda = s.holdings.first { $0.symbol == "NVDA" }!
        let enbChange: Decimal = 80
        let nvdaChange: Decimal = -120
        #expect(enb.dayChange == enbChange)
        #expect(nvda.dayChange == nvdaChange)
        let enbFraction = Decimal(string: "0.8")! / Decimal(40)
        #expect(enb.dayChangeFraction == enbFraction)
        let nvdaFraction = Decimal(-2) / Decimal(180)
        #expect(nvda.dayChangeFraction == nvdaFraction)
        #expect(!enb.dayChangeModelBaseline)
        #expect(nvda.dayChangeModelBaseline)

        // Values in the display currency: CAD stays, USD converts.
        let enbValue: Decimal = 4_080
        let nvdaValue: Decimal = 14_952 // 60 × 178 × 1.40
        #expect(enb.valueInDisplayCurrency == enbValue)
        #expect(nvda.valueInDisplayCurrency == nvdaValue)
    }

    @Test func dayChangeRefusesUnpairedPrices() {
        let price: LastPrice = { _, _ in Decimal(100) }
        // A quote alone is not a day change — there must be an earlier
        // observation to compare against…
        let s1 = dayPnLPortfolio.summary(
            lastPrice: price,
            dayPrices: { _, _ in nil }
        )
        #expect(s1.dayChange == nil)
        #expect(s1.dayChangeByCurrency.isEmpty)
        #expect(s1.holdings.allSatisfy { $0.dayChange == nil && $0.dayChangeFraction == nil })

        // …and the pair must describe the price actually used. A pair
        // whose `current` (95) differs from the quote (100) compares two
        // observations that never entered the summary → ignored.
        let mismatched: DayPrices = { _, _ in DayPricePair(current: 95, previous: 94) }
        let s2 = dayPnLPortfolio.summary(
            lastPrice: price,
            dayPrices: mismatched
        )
        #expect(s2.dayChange == nil)
        #expect(s2.holdings.allSatisfy { $0.dayChange == nil })
    }

    @Test func dayChangeFromMarketSkipsTheQuoteDayItself() {
        let now = Date(timeIntervalSince1970: 1_758_000_000) // a Wednesday
        let yesterday = now.addingTimeInterval(-86_400)
        let cache = MarketDataCache()
        cache.upsert(MarketQuote(symbol: "NVDA", currency: .usd, price: 178, asOf: now, source: "test"))
        var market = MarketData()
        market.series["NVDA"] = PriceSeries(symbol: "NVDA", currency: .usd, points: [
            DailyPrice(day: yesterday, price: 180, via: "derived via TSLA ÷ 16.2645"),
            DailyPrice(day: now, price: 178), // today's close exists but is the quote's own day
        ])
        let s = dayPnLPortfolio.summary(from: cache, market: market, now: now)
        let nvda = s.holdings.first { $0.symbol == "NVDA" }!
        let change: Decimal = -120
        #expect(nvda.dayChange == change)            // against the DERIVED 180, not today's 178
        #expect(nvda.dayChangeModelBaseline)          // labelled as a model comparison

        // Only a same-day point exists → nothing to compare against.
        var single = MarketData()
        single.series["NVDA"] = PriceSeries(symbol: "NVDA", currency: .usd, points: [DailyPrice(day: now, price: 178)])
        let s2 = dayPnLPortfolio.summary(from: cache, market: single, now: now)
        #expect(s2.holdings.first { $0.symbol == "NVDA" }!.dayChange == nil)
    }
}
