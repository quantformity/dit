import XCTest
@testable import DitCore

final class TransactionTests: XCTestCase {
    /// Exact decimal from string — never use float literals for money.
    private func d(_ value: String) -> Decimal { Decimal(string: value)! }

    private let accountID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private let calendar = Calendar(identifier: .gregorian)
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Sample transactions (one per kind)

    private var deposit: Transaction {
        Transaction(date: date(2026, 1, 5), accountID: accountID, currency: .cad,
                    kind: .deposit(amount: d("1000")),
                    fee: nil, notes: "Annual contribution", externalID: "REF-1")
    }

    private var withdrawal: Transaction {
        Transaction(date: date(2026, 2, 1), accountID: accountID, currency: .cad,
                    kind: .withdrawal(amount: d("250.50")))
    }

    private var stockPurchase: Transaction {
        Transaction(date: date(2026, 1, 10), accountID: accountID, currency: .usd,
                    kind: .stockPurchase(.init(ticker: "aapl ", shares: d("10"), price: d("187.50"))),
                    fee: d("1.99"))
    }

    private var stockSale: Transaction {
        Transaction(date: date(2026, 3, 15), accountID: accountID, currency: .usd,
                    kind: .stockSale(.init(ticker: "AAPL", shares: d("5"), price: d("201.25"))),
                    fee: d("1.99"))
    }

    private var gicPurchase: Transaction {
        Transaction(date: date(2026, 1, 12), accountID: accountID, currency: .cad,
                    kind: .gicPurchase(.init(
                        product: "5-Year Prime+ GIC",
                        principal: d("10000"),
                        rate: d("0.047"),
                        compounding: .annual,
                        maturityDate: date(2031, 1, 12),
                        redeemable: false
                    )))
    }

    private var gicRedemption: Transaction {
        Transaction(date: date(2031, 1, 13), accountID: accountID, currency: .cad,
                    kind: .gicRedemption(.init(purchaseID: UUID(), proceeds: d("12444.48"))))
    }

    private var dividend: Transaction {
        Transaction(date: date(2026, 4, 15), accountID: accountID, currency: .usd,
                    kind: .dividend(.init(ticker: "AAPL", amount: d("1.23"))))
    }

    private var fxConversion: Transaction {
        Transaction(date: date(2026, 5, 1), accountID: accountID, currency: .cad,
                    kind: .fxConversion(.init(fromCurrency: .usd, fromAmount: d("1000"), toAmount: d("1380"))),
                    fee: d("9.99"))
    }

    private var allKinds: [Transaction] {
        [deposit, withdrawal, stockPurchase, stockSale, gicPurchase, gicRedemption, dividend, fxConversion]
    }

    // MARK: - Amount derivation

    func testAmountIsDerivedFromKind() {
        XCTAssertEqual(deposit.amount, d("1000"))
        XCTAssertEqual(withdrawal.amount, d("250.50"))
        XCTAssertEqual(stockPurchase.amount, d("1875"))            // 10 × 187.50
        XCTAssertEqual(stockSale.amount, d("1006.25"))            // 5 × 201.25
        XCTAssertEqual(gicPurchase.amount, d("10000"))
        XCTAssertEqual(gicRedemption.amount, d("12444.48"))
        XCTAssertEqual(dividend.amount, d("1.23"))
        XCTAssertEqual(fxConversion.amount, d("1380"))            // the "to" side
    }

    func testFractionalSharesAreExact() {
        let fractional = Transaction(
            date: date(2026, 6, 1), accountID: accountID, currency: .cad,
            kind: .stockPurchase(.init(ticker: "SHOP.TO", shares: d("0.7"), price: d("10.03")))
        )
        // 0.7 × 10.03 = 7.021 exactly in Decimal (would be 7.020999… in Double)
        XCTAssertEqual(fractional.amount, d("7.021"))
    }

    func testTickerIsNormalized() {
        let t = Transaction(
            date: date(2026, 6, 1), accountID: accountID, currency: .usd,
            kind: .stockPurchase(.init(ticker: "  tsla  ", shares: 1, price: 1))
        )
        XCTAssertEqual(t.ticker, "TSLA")
    }

    // MARK: - Cash impact

    func testCashImpactSignsAndFees() {
        XCTAssertEqual(deposit.cashImpact, d("1000"))
        XCTAssertEqual(withdrawal.cashImpact, d("-250.50"))
        XCTAssertEqual(stockPurchase.cashImpact, d("-1876.99"))   // -(1875 + 1.99)
        XCTAssertEqual(stockSale.cashImpact, d("1004.26"))       // 1006.25 - 1.99
        XCTAssertEqual(gicPurchase.cashImpact, d("-10000"))      // no fee
        XCTAssertEqual(gicRedemption.cashImpact, d("12444.48"))  // no fee
        XCTAssertEqual(dividend.cashImpact, d("1.23"))
        XCTAssertEqual(fxConversion.cashImpact, d("1370.01"))    // 1380 - 9.99
    }

    func testTickerExtraction() {
        XCTAssertEqual(stockPurchase.ticker, "AAPL")
        XCTAssertEqual(stockSale.ticker, "AAPL")
        XCTAssertEqual(dividend.ticker, "AAPL")
        XCTAssertNil(deposit.ticker)
        XCTAssertNil(gicPurchase.ticker)
        XCTAssertNil(withdrawal.ticker)
    }

    // MARK: - Coding

    func testEveryKindRoundTripsThroughJSON() throws {
        for transaction in allKinds {
            let data = try JSONEncoder().encode(transaction)
            let decoded = try JSONDecoder().decode(Transaction.self, from: data)
            XCTAssertEqual(decoded, transaction, "round-trip failed for \(transaction.kind)")
            XCTAssertEqual(decoded.id, transaction.id)
            XCTAssertEqual(decoded.accountID, accountID)
        }
    }

    func testDecodedKindPatternMatches() throws {
        let data = try JSONEncoder().encode(stockPurchase)
        let decoded = try JSONDecoder().decode(Transaction.self, from: data)

        guard case .stockPurchase(let details) = decoded.kind else {
            return XCTFail("expected stockPurchase, got \(decoded.kind)")
        }
        XCTAssertEqual(details.ticker, "AAPL")
        XCTAssertEqual(details.shares, d("10"))
        XCTAssertEqual(details.price, d("187.50"))
        XCTAssertEqual(decoded.fee, d("1.99"))
        XCTAssertEqual(decoded.externalID, nil)
    }

    func testUnknownCurrencyInTransactionDecodesToUnknown() throws {
        let payload = Data(
            """
            {"id":"44444444-4444-4444-4444-444444444444","date":784080000,"accountID":"33333333-3333-3333-3333-333333333333","currency":"XYZ","kind":{"deposit":{"amount":50}}}
            """
            .utf8
        )
        let decoded = try JSONDecoder().decode(Transaction.self, from: payload)
        XCTAssertEqual(decoded.currency, Currency.unknown)
        XCTAssertEqual(decoded.amount, d("50"))
    }

    // MARK: - FX details

    func testFXImpliedRate() {
        let details = FXDetails(fromCurrency: .usd, fromAmount: d("1000"), toAmount: d("1380"))
        XCTAssertEqual(details.rate, d("1.38"))
        let zero = FXDetails(fromCurrency: .usd, fromAmount: 0, toAmount: 0)
        XCTAssertNil(zero.rate)
    }

    // MARK: - GIC details

    func testGICDetails() {
        let details = GICDetails(
            product: "1-Year GIC",
            principal: d("5000"),
            rate: d("0.031"),
            compounding: .monthly,
            maturityDate: date(2027, 1, 10),
            redeemable: true
        )
        XCTAssertEqual(details.product, "1-Year GIC")
        XCTAssertEqual(details.principal, d("5000"))
        XCTAssertEqual(details.rate, d("0.031"))
        XCTAssertEqual(details.compounding, GICCompounding.monthly)
        XCTAssertEqual(details.maturityDate, date(2027, 1, 10))
        XCTAssertEqual(details.redeemable, true)
    }
}