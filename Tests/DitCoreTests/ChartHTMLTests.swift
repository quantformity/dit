import Foundation
import Testing
@testable import DitCore

/// The HTML renderer keeps the same honesty contract as the ASCII one:
/// it presents the document, never re-computes it. Unknown values stay
/// dashed (never zero), mixed or unstated currencies never share an
/// axis, ≥10-day holes break the line, and unchartable documents are
/// refused — a page that draws a guess is a lying page.
@Suite("chart html renderer")
struct ChartHTMLTests {

    private let summaryDoc = """
    {"ok":true,"schema":"summary/1","data":{
      "displayCurrency":"CAD","offline":false,
      "accounts":[
        {"name":"GOOD","reportingCurrency":"CAD","total":"1234.50"},
        {"name":"BAD","reportingCurrency":"CAD","total":"-456.70"},
        {"name":"GHOST","reportingCurrency":"CAD","total":null}
      ],
      "holdings":[],"totals":{},"warnings":[]}}
    """

    private func seriesDoc(_ lines: [String]) -> String {
        "{\"ok\":true,\"schema\":\"quote/1\",\"data\":{\"count\":9,\"from\":\"2026-06-01\","
            + "\"mode\":\"series\",\"quotes\":[\(lines.joined(separator: ","))],"
            + "\"store\":\"/tmp/x\",\"to\":\"2026-09-30\"}}"
    }

    private func point(_ symbol: String, _ date: String, _ price: String,
                       ccy: String? = "USD", via: String? = nil) -> String {
        let c = ccy.map { "\"\($0)\"" } ?? "null"
        let v = via.map { "\"\($0)\"" } ?? "null"
        return "{\"basis\":\"\(via == nil ? "observed" : "derived")\",\"ccy\":\(c),"
            + "\"date\":\"\(date)\",\"price\":\"\(price)\",\"symbol\":\"\(symbol)\",\"via\":\(v)}"
    }

    // MARK: summary → interactive bars

    /// The embedded chart-data block only (between its tag and the
    /// closing script tag) — that is where honesty rules must hold.
    private func dataBlock(_ page: String) -> String {
        page.components(separatedBy: "id=\"data\">").last?
            .components(separatedBy: "</script>").first ?? ""
    }

    @Test func summaryPageKeepsDashedAndSignRules() throws {
        let page = try ChartHTML.document(fromJSON: Data(summaryDoc.utf8))
        #expect(page.contains("<!doctype html>"))
        let ghost = try #require(page.components(separatedBy: "\n").first { $0.contains("GHOST") })
        #expect(ghost.contains("unknown"), "unknown account stays visible, marked")
        #expect(ghost.contains("dashed"), "unknown renders dashed, never a bar")
        #expect(!ghost.contains("0.00"), "a null total never becomes a zero amount")
        // Negative bar: leftward, ending at zero (grows from the left
        // edge toward the zero line of the shared center scale).
        let neg = try #require(page.components(separatedBy: "\n").first { $0.contains("class=\"neg\"") })
        #expect(neg.contains("calc(50%"), "negative bar anchors around the center zero")
    }

    @Test func signedBarsShareOneScaleAroundTheZeroLine() throws {
        let page = try ChartHTML.document(fromJSON: Data(summaryDoc.utf8))
        // BAD (-456.70) vs GOOD (1234.50): shared scale means each
        // side's FULL HALF equals maxAbs. BAD's bar must be
        // 456.70/1234.50 ≈ 37% of the track → 18.5% of the whole
        // track, ending exactly AT the 50% zero line — never longer
        // and never crossing it.
        let neg = try #require(page.components(separatedBy: "\n").first { $0.contains("class=\"neg\"") })
        #expect(neg.contains("left:calc(50% - 18.5%);width:18.5%"),
                "negative bar: half-scale, anchored left of zero, ends at zero (got: \(neg))")
        // The positive partner starts at 50% with the SAME scale
        // (1234.50 = maxAbs → full 50% half).
        let pos = try #require(page.components(separatedBy: "\n").first { $0.contains("GOOD") })
        #expect(pos.contains("left:50%;width:50.0%"),
                "full-scale positive fills its half (got: \(pos))")
        // And a negative's total footprint must never reach past the
        // zero line (the exact bug: full-width negatives crossed into
        // the positive half and read as gains).
        // And a negative's total footprint must never reach past the
        // zero line (the exact bug: "calc(50% - 37.0% / 2);width:
        // 37.0%" spanned 31.5%→68.5% — double scale AND across the
        // line). The fixed form keeps the whole bar in the negative
        // half at the shared scale; "/ 2)" would only ever appear in
        // the old broken calc (the JS midline helper writes "/2,").
        #expect(!page.contains(" / 2)"),
                "no stale calc form that lengthens negatives across zero")
    }

    @Test func allNegativeSignedChartKeepsZeroAtTheRightEdge() throws {
        let doc = """
        {"ok":true,"schema":"summary/1","data":{
          "displayCurrency":"CAD",
          "accounts":[{"name":"A","reportingCurrency":"CAD","total":"-10.00"},
                      {"name":"B","reportingCurrency":"CAD","total":"-40.00"}],
          "holdings":[],"totals":{}}}
        """
        let page = try ChartHTML.document(fromJSON: Data(doc.utf8))
        // No mixed signs → no center line; bars grow leftward from
        // the RIGHT edge (zero there), largest magnitude fills it.
        let big = try #require(page.components(separatedBy: "\n").first { $0.contains("B</span") })
        #expect(big.contains("left:calc(100% - 100.0%);width:100.0%"),
                "max negative fills from the zero edge (got: \(big))")
        #expect(!page.contains("class=\"row cz"), "no fake zero line without mixed signs")
    }

    @Test func moneyLabelsAreTheDocumentOwnStrings() throws {
        let page = try ChartRenderer.moneyLabel(1234.50)
        #expect(page == "1,234.50", "display formatting stays grouped and Decimal-exact")
    }

    // MARK: quote series → line charts

    @Test func sameCurrencySeriesShareOneChartOthersDoNot() throws {
        // TSLA + SHOP both USD → one chart; HKD series (unstated ccy)
        // would need its own — and an UNSTATED ccy never shares at all.
        let doc = seriesDoc([
            point("TSLA", "2026-06-01", "400.00"),
            point("TSLA", "2026-06-02", "401.00"),
            point("SHOP", "2026-06-01", "100.00", ccy: "USD"),
            point("SHOP", "2026-06-02", "101.00", ccy: "USD"),
            point("PIAP", "2026-06-01", "9.00", ccy: nil),
            point("PIAP", "2026-06-02", "9.10", ccy: nil),
        ])
        let page = try ChartHTML.document(fromJSON: Data(doc.utf8))
        #expect(page.contains("Closes in USD"), "stated currency earns a shared chart")
        #expect(page.contains("currency not stated"), "unstated currency keeps its own chart")
        #expect(page.contains("(USD)") && page.contains("(?)"), "series labels carry their unit")
        // and the unknown-ccy chart must NOT contain SHOP (the other line):
        let piapChart = try #require(page.components(separatedBy: "</section>")
            .first { $0.contains("PIAP") })
        #expect(!piapChart.contains("SHOP"), "unstated units never share an axis")
    }

    @Test func tenDayHoleBreaksTheLine() throws {
        // Dense June, then a 14-day hole, then early July: the hole
        // must appear as a stroke break (a JSON null), not a bridge.
        var points: [String] = []
        for day in 1...16 {
            let d = String(format: "2026-06-%02d", day)
            points.append(point("GAPPY", d, "11.00", ccy: nil))
        }
        for day in 31...40 {   // July 2 → 14-day gap after June 16…18 window
            let d = String(format: "2026-07-%02d", day - 30)
            points.append(point("GAPPY", d, "12.00", ccy: nil))
        }
        let page = try ChartHTML.document(fromJSON: Data(seriesDoc(points).utf8))
        #expect(dataBlock(page).contains("null"), "a ≥10-day hole draws as a break, never a bridge")
        #expect(page.contains("line breaks mark"), "the legend explains the breaks")
    }

    @Test func weekendGapsStayUnmarked() throws {
        // Fri → Mon (3 days) is calendar dust: no break, no legend.
        let doc = seriesDoc([
            point("FAST", "2026-06-05", "10.00", ccy: nil),   // Fri
            point("FAST", "2026-06-08", "10.10", ccy: nil),   // Mon
        ])
        let page = try ChartHTML.document(fromJSON: Data(doc.utf8))
        #expect(!dataBlock(page).contains("null"), "a weekend gap is not a data hole")
        #expect(page.contains("line breaks mark ≥\(ChartHTML.gapBreakDays)-day"), "legend states the rule")
    }

    @Test func derivedSeriesStaysMarked() throws {
        let doc = seriesDoc([
            point("FAST", "2026-06-01", "10.00", ccy: nil, via: "formula v1"),
            point("FAST", "2026-06-02", "10.10", ccy: nil),
        ])
        let page = try ChartHTML.document(fromJSON: Data(doc.utf8))
        #expect(page.contains("dashed"), "derived closes keep their provenance marker")
        #expect(page.contains("DERIVED (backfilled)"), "the legend says what dashed means")
        let dataLine = try #require(page.components(separatedBy: "\n").first { $0.contains("\"dash\":true") })
        #expect(dataLine.contains(",1]"), "per-point derived flags survive into the page")
    }

    // MARK: refusals (the page must never guess)

    @Test func unknownSchemaRefused() {
        let doc = #"{"ok":true,"schema":"account/1","data":{}}"#
        #expect(throws: ChartRenderer.ChartError.self) {
            _ = try ChartHTML.document(fromJSON: Data(doc.utf8))
        }
    }

    @Test func failedSourceDocumentCarriesItsMessage() {
        let doc = #"{"ok":false,"error":"no FX rates available"}"#
        do {
            _ = try ChartHTML.document(fromJSON: Data(doc.utf8))
            Issue.record("a failed document must not render")
        } catch let error as ChartRenderer.ChartError {
            #expect(error.description.contains("no FX rates available"),
                    "the source's own message travels to the refusal")
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test func liveAndMatrixQuoteDocumentsAreNotCharts() {
        // Single-day snapshots carry no time series — refusing is honest.
        let live = #"{"ok":true,"schema":"quote/1","data":{"mode":"live","quotes":[]}}"#
        let matrix = #"{"ok":true,"schema":"quote/1","data":{"mode":"matrix","rates":[]}}"#
        for doc in [live, matrix] {
            #expect(throws: ChartRenderer.ChartError.self) {
                _ = try ChartHTML.document(fromJSON: Data(doc.utf8))
            }
        }
    }

    @Test func scriptClosingTextInLabelsCannotBreakThePage() throws {
        let evil = """
        {"ok":true,"schema":"summary/1","data":{
          "displayCurrency":"CAD",
          "accounts":[{"name":"A</script><script>alert(1)</script>","reportingCurrency":"CAD","total":"10.00"}],
          "holdings":[],"totals":{}}}
        """
        let page = try ChartHTML.document(fromJSON: Data(evil.utf8))
        // "</" inside the data block is escaped to "<\/" so the tag
        // cannot close early; labels are HTML-escaped in the markup.
        #expect(!dataBlock(page).contains("</script"), "closing tags stay escaped inside the data block")
        #expect(page.contains("&lt;/script"), "labels stay escaped in the markup too")
    }
}
