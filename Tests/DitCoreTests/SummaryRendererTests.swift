import DitCore
import Foundation
import Testing

@Suite("SummaryRenderer")
struct SummaryRendererTests {

    // A single CAD account: deposit 10 000, buy 100 SHOP @ 60,
    // dividend 30 → cash 4 030. Quoted at 65 → total 10 530,
    // unrealized +500.
    private func cadPortfolio() -> Portfolio {
        let account = Account(reportingCurrency: .cad, name: "TD Direct")
        let deposit = Transaction(date: date(2026, 1, 2), accountID: account.id,
                                  currency: .cad, kind: .deposit(amount: 10_000))
        let buy = Transaction(date: date(2026, 1, 9), accountID: account.id,
                              currency: .cad,
                              kind: .stockPurchase(StockDetails(ticker: "shop.to", shares: 100,
                                                                price: Decimal(string: "60")!)))
        let dividend = Transaction(date: date(2026, 4, 3), accountID: account.id,
                                   currency: .cad,
                                   kind: .dividend(DividendDetails(ticker: "SHOP.TO",
                                                                   amount: Decimal(string: "30")!)))
        return Portfolio(accounts: [account], transactions: [deposit, buy, dividend],
                         tickers: [EquityTicker(symbol: "SHOP.TO", name: "Shopify Inc.")])
    }

    private func quote(portfolio: Portfolio, price: Decimal) -> MarketDataCache {
        let cache = MarketDataCache()
        cache.upsert(MarketQuote(symbol: "SHOP.TO", currency: .cad, price: price,
                                 asOf: Date(), source: "test"))
        return cache
    }

    @Test func rendersTotalsWithGrouping() {
        let portfolio = cadPortfolio()
        let summary = portfolio.summary(from: quote(portfolio: portfolio, price: Decimal(string: "65")!))
        let text = SummaryRenderer.render(summary, date: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(text.contains("Total value"))
        #expect(text.contains("10,530.00 CAD"))          // grouped, in display currency
        #expect(text.contains("4,030.00"))               // cash
        #expect(text.contains("6,500.00"))               // quoted position value
        #expect(text.contains("500.00"))                 // unrealized P&L
        #expect(text.contains("30.00"))                  // dividends
        #expect(text.contains("SHOP.TO"))
        #expect(text.contains("Shopify Inc."))           // registry name
        #expect(text.contains("By currency:"))
        #expect(text.contains("Accounts:"))
        #expect(text.contains("Holdings:"))
        // Percent return: 500 P&L on a 6 000 cost = +8.3%.
        #expect(text.contains("P&L%"))
        #expect(text.contains("+8.3%"))
        // Everything quoted → no cost-basis footnote.
        #expect(!text.contains("cost basis"))
    }

    @Test func percentColumnDashesWithoutAQuoteAndReadsNegativeForLosses() {
        let portfolio = cadPortfolio()
        // No quotes at all: the holdings row must carry a dash, never a
        // fake "+0.0%" manufactured from cost-basis values.
        let unquoted = SummaryRenderer.render(portfolio.summary())
        #expect(unquoted.contains("P&L%"))
        let dashLine = unquoted.split(separator: "\n").first { $0.contains("SHOP.TO") && $0.contains("6,000") }
        #expect(dashLine.map { !$0.contains("%") } ?? false,
                "unquoted holdings row must dash the percent column")

        // Losing position: quoted at 54 on a 60 cost → −10.0% exactly,
        // with the explicit minus sign.
        let losing = SummaryRenderer.render(
            portfolio.summary(from: quote(portfolio: portfolio, price: Decimal(string: "54")!)))
        #expect(losing.contains("-10.0%"))
    }

    @Test func unquotedPositionsFallBackToCostBasisWithFootnote() {
        let portfolio = cadPortfolio()
        let summary = portfolio.summary() // no quotes, no rates
        let text = SummaryRenderer.render(summary)

        // Single-currency account: its own value is still exact.
        #expect(text.contains("10,030.00 CAD"))         // 4 030 cash + 6 000 at cost
        #expect(text.contains("6,000.00"))              // position at cost basis
        #expect(text.contains("SHOP.TO (CAD) valued at cost basis — no fresh quote"))
        // No unrealized number is printed at all, and no percent either.
        #expect(!text.contains("Unrealized P&L   500"))
        let shopLine = text.split(separator: "\n").first { $0.contains("SHOP.TO") && $0.contains("6,000") }
        #expect(shopLine.map { !$0.contains("%") } ?? false)
    }

    @Test func unconvertibleTotalsShowDashAndFootnote() {
        let cad = Account(reportingCurrency: .cad, name: "TD Direct")
        let usd = Account(reportingCurrency: .usd, name: "Questrade")
        let portfolio = Portfolio(
            accounts: [cad, usd],
            transactions: [
                Transaction(date: date(2026, 1, 2), accountID: cad.id,
                            currency: .cad, kind: .deposit(amount: 1_000)),
                Transaction(date: date(2026, 1, 2), accountID: usd.id,
                            currency: .usd, kind: .deposit(amount: 2_000))
            ],
            tickers: [])
        let summary = portfolio.summary() // no rate → combined values nil
        let text = SummaryRenderer.render(summary)

        #expect(text.contains("Total value      —"))
        // Per-currency breakdown stays exact and is the fallback story.
        #expect(text.contains("CAD"))
        #expect(text.contains("USD"))
        #expect(text.contains("some totals are unconverted — see the per-currency breakdown"))
    }

    @Test func emptyPortfolioRenders() {
        let summary = Portfolio(accounts: [], transactions: []).summary()
        let text = SummaryRenderer.render(summary)
        #expect(text.contains("Total value      0.00 CAD"))
        #expect(text.contains("—"))
    }

    @Test func callerNotesArePrinted() {
        let summary = Portfolio(accounts: [], transactions: []).summary()
        let text = SummaryRenderer.render(summary, notes: ["offline mode: positions at cost basis"])
        #expect(text.contains("Notes:"))
        #expect(text.contains("- offline mode: positions at cost basis"))
    }

    // MARK: Currency labels + one-day P&L columns

    /// TD (CAD) holds 100 ENB.TO @ 40; QT (USD) holds 60 NVDA @ 180.
    /// Quotes: ENB.TO 40.8, NVDA 178 (both today); USD→CAD 1.40.
    /// Market store holds yesterday's closes: ENB.TO 40.0 (real) and
    /// NVDA 180 (derived).
    private func mixedPortfolio() -> Portfolio {
        let td = Account(reportingCurrency: .cad, name: "TD Direct")
        let qt = Account(reportingCurrency: .usd, name: "Questrade")
        let buyEnb = Transaction(date: date(2025, 6, 2), accountID: td.id,
                                 currency: .cad,
                                 kind: .stockPurchase(StockDetails(ticker: "ENB.TO", shares: 100,
                                                                    price: Decimal(string: "40")!)))
        let buyNvda = Transaction(date: date(2025, 6, 2), accountID: qt.id,
                                  currency: .usd,
                                  kind: .stockPurchase(StockDetails(ticker: "NVDA", shares: 60,
                                                                     price: Decimal(string: "180")!)))
        return Portfolio(
            accounts: [td, qt],
            transactions: [
                Transaction(date: date(2025, 6, 1), accountID: td.id, currency: .cad,
                            kind: .deposit(amount: 10_000)),
                Transaction(date: date(2025, 6, 1), accountID: qt.id, currency: .usd,
                            kind: .deposit(amount: 12_000)),
                buyEnb, buyNvda,
            ],
            tickers: [EquityTicker(symbol: "ENB.TO", name: "Enbridge"),
                      EquityTicker(symbol: "NVDA", name: "Nvidia")]
        )
    }

    @Test func mixedTableLabelsCurrenciesAndAddsDisplayColumn() {
        let now = Date(timeIntervalSince1970: 1_758_000_000) // a Wednesday
        let yesterday = now.addingTimeInterval(-86_400)
        let cache = MarketDataCache()
        cache.upsert(MarketQuote(symbol: "ENB.TO", currency: .cad, price: Decimal(string: "40.8")!,
                                 asOf: now, source: "test"))
        cache.upsert(MarketQuote(symbol: "NVDA", currency: .usd, price: 178, asOf: now, source: "test"))
        cache.upsert(ExchangeRate(base: .usd, quote: .cad, rate: Decimal(string: "1.40")!,
                                  asOf: now, source: "test"))
        var market = MarketData()
        market.series["ENB.TO"] = PriceSeries(symbol: "ENB.TO", currency: .cad,
                                               points: [DailyPrice(day: yesterday, price: 40)])
        market.series["NVDA"] = PriceSeries(symbol: "NVDA", currency: .usd,
                                             points: [DailyPrice(day: yesterday, price: 180,
                                                                  via: "derived via TSLA ÷ 16.2645")])

        let summary = mixedPortfolio().summary(from: cache, market: market, now: now)
        let text = SummaryRenderer.render(summary, date: now)

        // Native values carry their currency code…
        #expect(text.contains("CAD 4,080.00"))
        #expect(text.contains("USD 10,680.00"))
        // …and mixed portfolios gain the converted column.
        #expect(text.contains("Value (CAD)"))
        #expect(text.contains("14,952.00")) // 10,680 USD × 1.40
        // Day columns: header line, tables, holdings.
        #expect(text.contains("Day change       -88.00 CAD"))
        #expect(text.contains("Day%"))
        #expect(text.contains("+2.0%"))   // ENB.TO: 40.0 → 40.8
        #expect(text.contains("-1.1%"))   // NVDA: 180 → 178
        #expect(text.contains("-120.00")) // USD account row day figure
        // Money columns speak the display currency: NVDA's −120 USD
        // renders as its −168 CAD equivalent in the Day and P&L cells…
        #expect(text.contains("Day (CAD)"))
        #expect(text.contains("P&L (CAD)"))
        #expect(text.contains("-168.00"))
        // …and the reconciliation contract is spelled out.
        #expect(text.contains("Day% and P&L% stay native-currency ratios"))
        // Derived baselines are labelled, not hidden.
        #expect(text.contains("derived proxy"))

        // Single-currency, quoted, but NO market history: the tables
        // keep their old shape — no dash-columns are manufactured.
        let singleText = SummaryRenderer.render(cadPortfolio().summary(), date: now)
        #expect(!singleText.contains("Value (CAD)"))
        #expect(!singleText.contains("Day change"))
        #expect(!singleText.contains("Day%"))
        #expect(singleText.contains("CAD 6,000.00")) // cost-basis value still labelled
    }

    @Test func unconvertibleDisplayValuesDashInsteadOfGuessing() {
        // Mixed currencies but no FX rate anywhere: the converted column
        // appears (currencies mix) with dashes — never a made-up rate.
        let now = Date(timeIntervalSince1970: 1_758_000_000)
        let summary = mixedPortfolio().summary(displayCurrency: .cad)
        let text = SummaryRenderer.render(summary, date: now)
        #expect(text.contains("Value (CAD)"))
        #expect(text.contains("USD 10,800.00")) // cost basis, unconverted
        // No quotes at all → no day columns, and totals unconverted.
        #expect(!text.contains("Day change"))
        #expect(text.contains("unconverted"))
    }

    @Test func dayColumnsAppearOnlyWithPairedData() {
        // Quote today, no stored history → nothing to compare against:
        // the summary must NOT grow empty Day columns.
        let cache = quote(portfolio: cadPortfolio(), price: Decimal(string: "65")!)
        let noHistory = SummaryRenderer.render(cadPortfolio().summary(from: cache))
        #expect(!noHistory.contains("Day change"))
        #expect(!noHistory.contains("Day%"))

        // With a previous close stored, the columns appear and carry
        // real numbers (65 vs 64 → +1.0% on the 6,000 cost = +100).
        var market = MarketData()
        let asOf = Date()
        market.series["SHOP.TO"] = PriceSeries(symbol: "SHOP.TO", currency: .cad,
                                                points: [DailyPrice(day: asOf.addingTimeInterval(-86_400),
                                                                     price: Decimal(string: "64")!)])
        let withHistory = SummaryRenderer.render(cadPortfolio().summary(from: cache, market: market))
        #expect(withHistory.contains("Day change       100.00 CAD"))
        #expect(withHistory.contains("+1.6%"))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }
}