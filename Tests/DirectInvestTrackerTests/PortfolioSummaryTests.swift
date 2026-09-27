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

        // SHOP.TO appears twice: once per holding currency.
        let shopC = s.holdings[0]
        #expect(shopC.symbol == "SHOP.TO")
        #expect(shopC.name == "Shopify Inc.")
        #expect(shopC.currency == Currency.cad)
        #expect(shopC.shares == 100)
        #expect(shopC.averageCostPerShare == 60)
        #expect(shopC.costBasis == 6_000)
        #expect(shopC.value == 6500)
        #expect(shopC.unrealizedPnL == 500)
        #expect(shopC.accountNames == ["TD Direct"])

        let shopU = s.holdings[1]
        #expect(shopU.symbol == "SHOP.TO")
        #expect(shopU.currency == Currency.usd)
        #expect(shopU.shares == 60)
        #expect(shopU.averageCostPerShare == 70)
        #expect(shopU.value == 4500)
        #expect(shopU.unrealizedPnL == 300)
        #expect(shopU.accountNames == ["Questrade"])

        // ENB.TO: no quote → cost-basis value, no unrealized P&L.
        let enb = s.holdings[2]
        #expect(enb.symbol == "ENB.TO")
        #expect(enb.name == "Enbridge Inc.")
        #expect(enb.shares == 50)
        #expect(enb.value == 2000)
        #expect(enb.unrealizedPnL == nil)
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
}
