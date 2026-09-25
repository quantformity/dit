import XCTest
@testable import DirectInvestTracker

final class PortfolioTests: XCTestCase {
    private let account = Account(name: "Test brokerage", institution: "TestBank")
    private let ticker = EquityTicker(symbol: "AAPL", name: "Apple Inc.", currency: .usd)
    private var trade: Transaction {
        Transaction(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            accountID: account.id,
            currency: .usd,
            kind: .stockPurchase(.init(ticker: "aapl", shares: 10, price: 190))
        )
    }

    private var fullPortfolio: Portfolio {
        Portfolio(accounts: [account], transactions: [trade], tickers: [ticker])
    }

    // MARK: - Lenient decoding

    func testMissingSectionsDecodeToEmpty() throws {
        // Saved before the ticker registry existed, and the account record
        // predates the reporting-currency field: everything must still load.
        let payload = Data(
            """
            {"accounts":[{"id":"00000000-0000-0000-0000-000000000001","name":"Old account","taxable":true}],"transactions":[]}
            """
            .utf8
        )
        let decoded = try JSONDecoder().decode(Portfolio.self, from: payload)
        XCTAssertEqual(decoded.accounts.count, 1)
        XCTAssertEqual(decoded.accounts.first?.reportingCurrency, Currency.cad)
        XCTAssertTrue(decoded.tickers.isEmpty)
    }

    func testRoundTrip() throws {
        let portfolio = fullPortfolio // capture once: the computed trade mints fresh UUIDs
        let decoded = try JSONDecoder().decode(Portfolio.self, from: JSONEncoder().encode(portfolio))
        XCTAssertEqual(decoded, portfolio)
    }

    // MARK: - Lookups

    func testAccountLookup() {
        let portfolio = fullPortfolio
        XCTAssertEqual(portfolio[account: account.id]?.name, "Test brokerage")
        XCTAssertNil(portfolio[account: UUID()])
    }

    func testTickerLookupIsCaseInsensitive() {
        let portfolio = fullPortfolio
        XCTAssertEqual(portfolio[ticker: "aapl"]?.name, "Apple Inc.")
        XCTAssertEqual(portfolio[ticker: " AAPL "]?.name, "Apple Inc.")
        XCTAssertNil(portfolio[ticker: "MSFT"])
    }

    func testTransactionFiltering() {
        let portfolio = fullPortfolio
        XCTAssertEqual(portfolio.transactions(in: account.id).count, 1)
        XCTAssertTrue(portfolio.transactions(in: UUID()).isEmpty)
        XCTAssertEqual(portfolio.transactions(for: "AAPL").count, 1)
    }

    // MARK: - Mutations

    func testUpsertAccountReplacesBySameID() {
        var portfolio = fullPortfolio
        let renamed = Account(id: account.id, name: "Renamed")
        portfolio.upsert(renamed)

        XCTAssertEqual(portfolio.accounts.count, 1)
        XCTAssertEqual(portfolio.accounts.first?.name, "Renamed")
    }

    func testUpsertTickerReplacesBySameSymbol() {
        var portfolio = fullPortfolio
        portfolio.upsert(EquityTicker(symbol: "aapl ", name: "Apple Inc.", currency: .usd, notes: "updated"))

        XCTAssertEqual(portfolio.tickers.count, 1)
        XCTAssertEqual(portfolio.tickers.first?.symbol, "AAPL")
        XCTAssertEqual(portfolio.tickers.first?.notes, "updated")
    }

    func testAddTransactionAppends() {
        var portfolio = fullPortfolio
        portfolio.add(trade)
        XCTAssertEqual(portfolio.transactions.count, 2)
    }
}