import Foundation
import Testing
@testable import DirectInvestTracker

/// dit-chart reads the summary/1 document and draws bars. The rules
/// under test are HONESTY rules: nulls stay dashed (never drawn as
/// zero), signs keep their side of the zero line at one shared scale,
/// unknown schemas are refused, and a failed source document never
/// renders as a healthy chart.
@Suite("chart renderer")
struct ChartRendererTests {

    private let mixedDoc = """
    {"ok":true,"schema":"summary/1","data":{
      "displayCurrency":"CAD","offline":false,
      "accounts":[
        {"name":"GOOD","reportingCurrency":"CAD","total":"1234.50"},
        {"name":"BAD","reportingCurrency":"CAD","total":"-456.70"},
        {"name":"GHOST","reportingCurrency":"CAD","total":null}
      ],
      "holdings":[],
      "totals":{"positions":"1000.00"},
      "warnings":[]}}
    """

    private func render(_ json: String, width: Int = 80, ascii: Bool = false) throws -> [String] {
        let (_, charts) = try ChartRenderer.charts(fromJSON: Data(json.utf8))
        return ChartRenderer.render(charts: charts, width: width, ascii: ascii)
    }

    @Test func nullTotalStaysDashedAndNeverBecomesZero() throws {
        let lines = try render(mixedDoc, ascii: true)
        let ghost = try #require(lines.first { $0.hasPrefix("  GHOST") })
        #expect(ghost.contains("?"), "unknown value marks its bar spot")
        #expect(ghost.contains(" -"), "unknown value prints dashed, not 0.00")
        #expect(!ghost.contains("0.00"), "a null total must not render as a zero amount")
        #expect(!ghost.contains("#"), "unknown draws no bar")
    }

    @Test func signedBarsShareOneScaleAroundTheZeroLine() throws {
        let lines = try render(mixedDoc, ascii: true)
        let good = Array(try #require(lines.first { $0.hasPrefix("  GOOD") }))
        let bad = Array(try #require(lines.first { $0.hasPrefix("  BAD") }))
        let axis = try #require(lines.first { $0.hasSuffix("^") })
        let axisColumn = axis.count - 1   // one ^ at the zero column

        // Negative money grows LEFTWARD and ends just before zero;
        // positive starts AT zero and grows rightward.
        let badLast = try #require(bad.lastIndex(of: "#"))
        let goodFirst = try #require(good.firstIndex(of: "#"))
        #expect(badLast < axisColumn, "negative bar must stay left of the zero line")
        #expect(goodFirst >= axisColumn, "positive bar must start at/after the zero line")

        // One shared scale: the bigger magnitude draws the longer bar,
        // and each side's full-scale bar fills its half.
        let badLength = bad.filter { $0 == "#" }.count
        let goodLength = good.filter { $0 == "#" }.count
        #expect(goodLength > badLength, "1234.50 draws longer than 456.70")
        #expect(goodLength >= 20, "full-scale positive fills its half (width 80 → ~25 cells)")
    }

    @Test func asciiTierContainsOnlyPlainAscii() throws {
        let lines = try render(mixedDoc, width: 70, ascii: true)
        for line in lines {
            #expect(line.unicodeScalars.allSatisfy { $0.value < 128 },
                    "ASCII tier leaked a non-ASCII glyph: \(line)")
        }
        // The default tier really uses the blocks — the flag does
        // something, it is not a placebo.
        let pretty = try render(mixedDoc, width: 70, ascii: false)
        #expect(pretty.contains { $0.contains("\u{2588}") })
        #expect(pretty.contains { $0.contains("\u{25B2}") })
    }

    @Test func unknownSchemaIsRefusedAndFailedSourceCarriesItsMessage() {
        do {
            _ = try ChartRenderer.charts(fromJSON: Data(#"{"ok":true,"schema":"account/1","data":{}}"#.utf8))
            Issue.record("an unchartable schema must be refused, not guessed")
        } catch let ChartRenderer.ChartError.unsupported(schema) {
            #expect(schema == "account/1")
        } catch {
            Issue.record("wrong error kind: \(error)")
        }
        do {
            _ = try ChartRenderer.charts(fromJSON: Data(#"{"ok":false,"error":"no FX rates"}"#.utf8))
            Issue.record("a failed document must not chart")
        } catch let ChartRenderer.ChartError.rejected(message) {
            #expect(message == "no FX rates", "the source's message travels to stderr")
        } catch {
            Issue.record("wrong error kind: \(error)")
        }
        #expect(throws: (any Error).self) {
            _ = try ChartRenderer.charts(fromJSON: Data("tables not charts".utf8))
        }
    }

    @Test func narrowWidthKeepsNumbersInsteadOfFakeBars() throws {
        // At the smallest legal width the renderer must not smear
        // bars past the money column (it drops to plain lines).
        let lines = try render(mixedDoc, width: 40, ascii: true)
        for line in lines where line.contains("#") {
            #expect(line.count <= 42)
        }
    }

    @Test func moneyLabelsMatchTheTableFormat() {
        #expect(ChartRenderer.moneyLabel(Decimal(string: "1234.5")!) == "1,234.50")
        #expect(ChartRenderer.moneyLabel(Decimal(string: "-10728.39")!) == "-10,728.39")
        #expect(ChartRenderer.moneyLabel(Decimal(string: "0.004")!) == "0.00")
        #expect(ChartRenderer.moneyLabel(Decimal(string: "1234567.891")!) == "1,234,567.89")
    }
}