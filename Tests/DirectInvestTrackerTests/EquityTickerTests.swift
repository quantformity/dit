import XCTest
@testable import DirectInvestTracker

final class EquityTickerTests: XCTestCase {
    // MARK: - Normalization & identity

    func testSymbolIsNormalizedToUppercaseYahooFormat() {
        let ticker = EquityTicker(symbol: "  shop.to ")
        XCTAssertEqual(ticker.symbol, "SHOP.TO")
        XCTAssertEqual(ticker.id, "SHOP.TO")
    }

    func testSymbolIsTheIdentifiableID() {
        let ticker = EquityTicker(symbol: "AAPL")
        XCTAssertEqual(ticker.id, ticker.symbol)
    }

    // MARK: - Defaults

    func testDefaults() {
        let ticker = EquityTicker(symbol: "AAPL")
        XCTAssertEqual(ticker.symbol, "AAPL")
        XCTAssertNil(ticker.name)
        XCTAssertEqual(ticker.currency, Currency.unknown)
        XCTAssertNil(ticker.notes)
    }

    // MARK: - Equality & dedup

    func testSameSymbolMeansSameInstrument() {
        let a = EquityTicker(symbol: "tsla", name: "Tesla")
        let b = EquityTicker(symbol: "TSLA", name: "Tesla, Inc.")
        XCTAssertEqual(a.symbol, b.symbol)
        XCTAssertEqual(Set([a.symbol, b.symbol]).count, 1)
    }

    // MARK: - Coding

    func testRoundTrip() throws {
        let original = EquityTicker(symbol: "SHOP.TO", name: "Shopify Inc.",
                                    currency: .cad, notes: "Long-term hold")
        let decoded = try JSONDecoder().decode(
            EquityTicker.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.symbol, "SHOP.TO")
        XCTAssertEqual(decoded.name, "Shopify Inc.")
        XCTAssertEqual(decoded.currency, Currency.cad)
        XCTAssertEqual(decoded.notes, "Long-term hold")
    }

    func testUnknownCurrencyCodeDecodesLeniently() throws {
        let payload = Data(#"{"symbol":"TEST","currency":"XYZ"}"#.utf8)
        let decoded = try JSONDecoder().decode(EquityTicker.self, from: payload)
        XCTAssertEqual(decoded.currency, Currency.unknown)
    }
}