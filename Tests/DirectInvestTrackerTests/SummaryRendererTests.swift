import DirectInvestTracker
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

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }
}