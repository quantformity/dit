import Foundation
import Testing
@testable import DitCore

/// The matrix math is financial logic: reciprocals and USD
/// triangulation must be exact, labelled, and never invented.
@Suite("FX matrix")
struct FXMatrixTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func cell(_ cells: [FXMatrix.Cell], _ from: Currency, _ to: Currency) -> FXMatrix.Cell {
        let found = cells.first { c in c.base == from && c.quote == to }
        guard let found else { fatalError("missing cell \(from)→\(to)") }
        return found
    }

    @Test func chainParsingRules() {
        #expect(FXMatrix.parseChain("USD/CAD/HKD") == [.usd, .cad, .hkd])
        #expect(FXMatrix.parseChain("usd/cad/hkd") == [.usd, .cad, .hkd])
        // Two codes are the PAIR path, not a matrix.
        #expect(FXMatrix.parseChain("USD/CAD") == nil)
        // Unknown or repeated codes never form a matrix.
        #expect(FXMatrix.parseChain("USD/CAD/XYZ") == nil)
        #expect(FXMatrix.parseChain("USD/CAD/USD") == nil)
        #expect(FXMatrix.looksLikeChain("USD/CAD/XYZ") == true)   // → "unknown currency" error
        #expect(FXMatrix.looksLikeChain("AAPL") == false)
    }

    @Test func reciprocalsAndTriangulationAreLabelled() throws {
        // USD hub quotes: CAD per USD = 1.4, HKD per USD = 7.84.
        let direct: (Currency, Currency) -> (rate: Decimal, date: String?)? = { a, b in
            if a == .usd, b == .cad { return (self.dec("1.4"), "2026-09-28") }
            if a == .usd, b == .hkd { return (self.dec("7.84"), "2026-09-28") }
            return nil
        }
        let cells = FXMatrix.cells(currencies: [.usd, .cad, .hkd], direct: direct)
        // Direct observations keep their basis.
        #expect(cell(cells, .usd, .cad).basis == "observed")
        #expect(cell(cells, .usd, .cad).rate == dec("1.4"))
        // Reversals are exact reciprocals of the stored quote …
        #expect(cell(cells, .cad, .usd).basis == "reciprocal")
        let halfCAD: Decimal = 1 / dec("1.4")
        #expect(cell(cells, .cad, .usd).rate == halfCAD)
        let inverseHKD: Decimal = 1 / dec("7.84")
        #expect(cell(cells, .hkd, .usd).rate == inverseHKD)
        // … and the cross multiplies the two USD legs (CAD→HKD =
        // (USD per CAD) × (HKD per USD)), marked derived, no date.
        #expect(cell(cells, .cad, .hkd).basis == "derived")
        let expected: Decimal = halfCAD * dec("7.84")
        #expect(cell(cells, .cad, .hkd).rate == expected)
        #expect(cell(cells, .cad, .hkd).date == nil)
    }

    @Test func directCrossBeatsTriangulation() {
        // If the feed has CAD/HKD directly, use it — as observed.
        let direct: (Currency, Currency) -> (rate: Decimal, date: String?)? = { a, b in
            if a == .usd, b == .cad { return (self.dec("1.4"), nil) }
            if a == .usd, b == .hkd { return (self.dec("7.84"), nil) }
            if a == .cad, b == .hkd { return (self.dec("5.6"), nil) }  // a real cross quote
            return nil
        }
        let cells = FXMatrix.cells(currencies: [.usd, .cad, .hkd], direct: direct)
        #expect(cell(cells, .cad, .hkd).basis == "observed")
        #expect(cell(cells, .cad, .hkd).rate == dec("5.6"))
    }

    @Test func missingLegsYieldNoneNeverInvention() {
        // Only USD/CAD known: nothing can be built between GBP, CHF
        // and CAD (no GBP legs anywhere) — every cell is "none".
        let direct: (Currency, Currency) -> (rate: Decimal, date: String?)? = { a, b in
            if a == .usd, b == .cad { return (self.dec("1.4"), nil) }
            return nil
        }
        let cells = FXMatrix.cells(currencies: [.gbp, .chf, .cad], direct: direct)
        let known = cells.filter { c in c.rate != nil }
        #expect(known.isEmpty)
    }
}
