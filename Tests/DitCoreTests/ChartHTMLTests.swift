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

    // MARK: summary → stat cards + column charts

    /// The embedded chart-data block (the id="data" JSON blob) —
    /// that is where honesty rules must hold, because the JS renderer
    /// trusts it blindly.
    private func dataBlock(_ page: String) -> String {
        page.components(separatedBy: "id=\"data\">").last?
            .components(separatedBy: "</script>").first ?? ""
    }

    /// Read the drawn height fraction of a column from the payload by
    /// its label (keys arrive sorted: "h" precedes "t").
    private func heightFor(_ page: String, _ label: String) -> Double? {
        guard let r = page.range(of: "\"t\":\"\(label)\"") else { return nil }
        let from = page.index(r.lowerBound, offsetBy: -160, limitedBy: page.startIndex) ?? page.startIndex
        let window = String(page[from..<r.lowerBound])
        guard let hRange = window.range(of: "\"h\":", options: .backwards) else { return nil }
        var rest = window[hRange.upperBound...]
        var num = ""
        while let c = rest.first, c.isNumber || c == "." || c == "-" {
            num.append(c)
            rest = rest.dropFirst()
        }
        return Double(num)
    }

    @Test func summaryPageKeepsDashedAndSignRules() throws {
        let page = try ChartHTML.document(fromJSON: Data(summaryDoc.utf8))
        #expect(page.contains("<!doctype html>"))
        let block = dataBlock(page)
        // GHOST (null total) stays a visible ghost column — a dashed
        // stub in the drawing — and its tooltip says "never shown as
        // zero"; the page legend names the dashed-stub rule. A null
        // never becomes a 0.00 amount anywhere on the page.
        #expect(block.contains("\"t\":\"GHOST\""), "unknown account stays visible, marked")
        #expect(block.contains("\"g\":\"g\""), "unknown draws a ghost stub, never a bar")
        #expect(block.contains("never shown as zero"))
        #expect(page.contains("dashed stub = no trustworthy combined value"))
        #expect(!page.contains("0.00"), "a null total never becomes a zero amount")
        // BAD (-456.70) is drawn BELOW the zero baseline ("d"), never
        // as a rightward/upward bar.
        #expect(block.contains("\"g\":\"d\",\"h\":-"),
                "negative amounts grow away from zero, downward")
    }

    @Test func signedColumnsShareOneScaleAndNeverCrossZero() throws {
        let page = try ChartHTML.document(fromJSON: Data(summaryDoc.utf8))
        // Shared scale: BAD/GOOD bar heights sit in the same ratio as
        // their values (456.70/1234.50 ≈ 0.37). The old bug drew
        // negatives at DOUBLE length across the line — that would
        // show up here as ≈ 0.74.
        let bad = try #require(heightFor(page, "BAD"))
        let good = try #require(heightFor(page, "GOOD"))
        #expect(bad < 0, "negative below the line")
        #expect(abs(abs(bad / good) - 456.70 / 1234.50) < 0.01,
                "one shared scale (ratio ≈ 0.37, got \(abs(bad / good)))")
        // No-crossing bound: with zero at fraction zf (from the top),
        // the space ABOVE the line is zf and BELOW is 1-zf; a column
        // may not exceed the space on its own side (domain padding to
        // nice steps makes this hold by construction).
        let zfRange = try #require(page.range(of: "\"zf\":"))
        let zfTail = page[zfRange.upperBound...]
        let zf = try #require(Double(String(zfTail.prefix { $0.isNumber || $0 == "." || $0 == "-" })))
        #expect(abs(bad) <= 1 - zf + 1e-9, "negative stays inside the negative half")
        #expect(good <= zf + 1e-9, "positive stays inside the positive half")
    }

    @Test func allNegativeSignedChartHangsBelowTheZeroLine() throws {
        let doc = """
        {"ok":true,"schema":"summary/1","data":{
          "displayCurrency":"CAD",
          "accounts":[{"name":"A","reportingCurrency":"CAD","total":"-10.00"},
                      {"name":"B","reportingCurrency":"CAD","total":"-40.00"}],
          "holdings":[],"totals":{}}}
        """
        let page = try ChartHTML.document(fromJSON: Data(doc.utf8))
        // The zero baseline is placed where the honest scale puts it:
        // an all-negative chart sits UNDER zero, so the line is at
        // the top (zf 0) and both columns hang down from it — zero
        // is never hidden to fake a fuller-looking chart.
        #expect(page.contains("\"mode\":\"pnl\""), "plus/minus chart mode")
        #expect(page.contains("\"zf\":0}]"), "all-negative: zero line caps the plot")
        #expect(page.contains("line marks zero; bars grow away from it on one shared scale"))
        let a = try #require(heightFor(page, "A"))
        let b = try #require(heightFor(page, "B"))
        #expect(a < 0 && b < 0 && abs(b) > abs(a),
                "debts measured downward, larger debt longer")
        #expect(abs(a / b - 10.0 / 40.0) < 0.01, "shared scale within the chart")
    }

    @Test func statCardsOnlyShowFiguresTheDocumentCarries() throws {
        let full = """
        {"ok":true,"schema":"summary/1","data":{
          "displayCurrency":"CAD",
          "accounts":[{"name":"A","reportingCurrency":"CAD","total":"10.00"}],
          "holdings":[],
          "totals":{"totalValue":"1060806.80","unrealizedPnl":"408862.82",
                    "dayChange":"-3038.63","cash":"70812.63","gic":"5000.00"},
          "warnings":[]}}
        """
        let page = try ChartHTML.document(fromJSON: Data(full.utf8))
        // Every card figure is the document's own number, grouped for
        // display: no re-computation, and sign colours follow it.
        #expect(page.contains("Total MTM (CAD)") && page.contains("$1,060,806.80"))
        #expect(page.contains("+$408,862.82") && page.contains("class=\"k pos\""))
        #expect(page.contains("−$3,038.63") && page.contains("class=\"k neg\""))
        #expect(page.contains("$70,812.63") && page.contains("class=\"k cash\""))
        #expect(page.contains("$5,000.00") && page.contains("class=\"k gic\""))
        // Offline/missing totals → NO cards at all (never "—" fillers).
        let empty = """
        {"ok":true,"schema":"summary/1","data":{"displayCurrency":"CAD",
          "offline":true,"accounts":[],"holdings":[],"totals":{},"warnings":[]}}
        """
        let page2 = try ChartHTML.document(fromJSON: Data(empty.utf8))
        #expect(!page2.contains("Total MTM"), "no data, no card")
        #expect(page2.contains("nothing to chart"), "the empty case says so")
    }

    @Test func moneyLabelsAreTheDocumentOwnStrings() throws {
        let page = ChartRenderer.moneyLabel(1234.50)
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
        // cannot close early; the payload arrives inside the blob only.
        #expect(!dataBlock(page).contains("</script"), "closing tags stay escaped inside the data block")
        #expect(page.contains("<\\/script"), "the blob carries the escaped form, not raw '</'")
    }
}
