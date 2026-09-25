import XCTest
@testable import DirectInvestTracker

final class CurrencyTests: XCTestCase {
    // MARK: - Catalog

    func testKnownCatalogExcludesUnknownAndSortsByCode() {
        XCTAssertEqual(Currency.known.count, 10)
        XCTAssertEqual(
            Currency.known.map(\.isoCode),
            ["AUD", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD", "JPY", "NZD", "USD"]
        )
        XCTAssertFalse(Currency.known.contains(Currency.unknown))
    }

    func testConversionHubIsUSD() {
        XCTAssertEqual(Currency.conversionHub, Currency.usd)
    }

    // MARK: - Metadata

    func testMetadata() {
        let cad = Currency.cad
        let jpy = Currency.jpy
        let usd = Currency.usd
        let unknown = Currency.unknown

        XCTAssertEqual(cad.isoCode, "CAD")
        XCTAssertEqual(cad.displayName, "Canadian Dollar")
        XCTAssertEqual(cad.symbol, "C$")
        XCTAssertEqual(jpy.symbol, "¥")
        XCTAssertEqual(jpy.decimalPlaces, 0)
        XCTAssertEqual(cad.decimalPlaces, 2)
        XCTAssertEqual(usd.isoCode, "USD")
        XCTAssertEqual(unknown.displayName, "Unknown")
    }

    // MARK: - Decoding

    func testDecodesKnownCodes() throws {
        let decoded = try JSONDecoder().decode(Currency.self, from: Data("\"CAD\"".utf8))
        XCTAssertEqual(decoded, Currency.cad)
    }

    func testDecodingIsCaseAndWhitespaceInsensitive() throws {
        let decoded = try JSONDecoder().decode(Currency.self, from: Data("\"  cad \"".utf8))
        XCTAssertEqual(decoded, Currency.cad)
    }

    func testUnrecognizedCodeDecodesToUnknownInsteadOfThrowing() throws {
        let decoded = try JSONDecoder().decode(Currency.self, from: Data("\"XYZ\"".utf8))
        XCTAssertEqual(decoded, Currency.unknown)
    }

    func testRoundTripEncodesToISOCode() throws {
        for currency in Currency.allCases {
            let data = try JSONEncoder().encode(currency)
            let decoded = try JSONDecoder().decode(Currency.self, from: data)
            XCTAssertEqual(decoded, currency)
        }
        XCTAssertEqual(String(data: try JSONEncoder().encode(Currency.usd), encoding: .utf8), "\"USD\"")
        XCTAssertEqual(String(data: try JSONEncoder().encode(Currency.unknown), encoding: .utf8), "\"\"")
    }

    // MARK: - Yahoo Finance quotes

    func testQuoteTicker() {
        let usd = Currency.usd
        let eur = Currency.eur
        let cad = Currency.cad
        let jpy = Currency.jpy
        let unknown = Currency.unknown

        XCTAssertEqual(eur.quoteTicker(), "EURUSD=X")
        XCTAssertEqual(cad.quoteTicker(), "CADUSD=X")
        XCTAssertEqual(jpy.quoteTicker(against: cad), "JPYCAD=X")
        XCTAssertNil(unknown.quoteTicker())
        XCTAssertNil(usd.quoteTicker(against: unknown))
        XCTAssertNil(usd.quoteTicker()) // same currency: no such pair
    }

    // MARK: - Ordering

    func testOrdering() {
        let aud = Currency.aud
        let eur = Currency.eur
        let usd = Currency.usd
        let unknown = Currency.unknown

        XCTAssertEqual(Currency.known.min(), aud)
        XCTAssertEqual(Currency.known.max(), usd)
        XCTAssertLessThan(eur, usd)
        XCTAssertGreaterThan(unknown, usd)
        XCTAssertFalse(unknown < unknown)
    }
}