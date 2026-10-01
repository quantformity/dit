import Testing
@testable import DitCore

/// `dit quote USD/CAD` depends on this parse: pairs are routed to the
/// FX rate endpoint, everything else to the equity quotes endpoint.
@Suite("FX pair parsing")
struct FXPairParsingTests {

    /// "FROM/TO" or nil — keeps the assertions readable.
    private func pair(_ symbol: String) -> String? {
        ExchangeRate.pairRequest(for: symbol).map { "\($0.from.rawValue)/\($0.to.rawValue)" }
    }

    @Test func pairsParseInBothDirections() {
        #expect(pair("USD/CAD") == "USD/CAD")
        #expect(pair("usd/cad") == "USD/CAD")   // upper-cased first
        #expect(pair("GBP/JPY") == "GBP/JPY")
    }

    @Test func nonPairsStayEquitySymbols() {
        #expect(pair("AAPL") == nil)
        #expect(pair("SHOP.TO") == nil)
        // Same-currency "pairs" have no quote; unknown codes are not FX.
        #expect(pair("CAD/CAD") == nil)
        #expect(pair("USD/XYZ") == nil)
        // Malformed shapes must not half-match.
        #expect(pair("USD/CAD/X") == nil)
        #expect(pair("/") == nil)
        #expect(pair("USD/") == nil)
    }
}
