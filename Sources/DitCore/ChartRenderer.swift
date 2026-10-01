import Foundation

// MARK: - dit-chart support (ASCII bar charts from machine documents)
//
// `dit --json | dit-chart` — everything here is PRESENTATION of numbers
// the summary already computed. The renderer must never convert, sum,
// or invent a value: unknown amounts stay dashed (never zero-length,
// which reads as "flat"), and derived data keeps its marker so a chart
// cannot launder model output into something that looks observed.
//
// Glyph tiers (see docs): Unicode blocks are the default; `--ascii`
// forces the plain tier (#, ^, -) for cp936-style consoles, LANG=C
// and byte-stable output. Column widths come from the caller.

/// ASCII bar-chart renderer shared by `dit-chart` and the tests.
///
/// Pure presentation: rows carry already-formatted numbers; the
/// renderer never converts money or re-implements financial semantics
/// (see file header for the honesty rules it enforces).
public enum ChartRenderer {

    // MARK: Chart model

    /// One plottable line of a chart.
    public struct Row {
        /// Left column (account, symbol, currency…).
        public let label: String
        /// nil = not plottable (unknown / unconvertible). Rendered
        /// dashed, never as a zero-length bar.
        public let value: Decimal?
        /// Extra right-aligned text after the amount (e.g. "(-2.7%)").
        public let trailing: String
        /// Provenance marker column; nil when the row is a direct
        /// observation.
        public let marker: String?

        /// Builds a row; `marker` is only the provenance label ("*"),
        /// the renderer does not decide whether data is derived.
        public init(label: String, value: Decimal?, trailing: String = "", marker: String? = nil) {
            self.label = label
            self.value = value
            self.trailing = trailing
            self.marker = marker
        }
    }

    /// A complete chart: header, rows, and the legend explaining glyphs.
    public struct Chart {
        /// First line of output.
        public let title: String
        /// Sub-caption explaining what the numbers ARE (units, base of
        /// percentages, native-ratio warnings).
        public let note: String?
        /// true = plus/minus bars around a zero line (equal scale
        /// both sides, like the backfill formula charts).
        public let signed: Bool
        /// The lines to draw (order preserved — charts read top-down).
        public let rows: [Row]
        /// Explanatory footer lines (glyph meanings, unit warnings).
        public let legend: [String]
        /// Renderer hint for what the chart MEASURES ("account", "value",
        /// "pnl", "day"). The terminal renderer ignores it; the HTML
        /// renderer uses it to pick a colour language — quantity charts
        /// read one flat colour, performance charts green/red by sign.
        public let kind: String

        /// Memberwise init; `signed: true` selects the zero-line layout.
        public init(title: String, note: String? = nil, signed: Bool,
                    rows: [Row], legend: [String] = [], kind: String = "") {
            self.title = title
            self.note = note
            self.signed = signed
            self.rows = rows
            self.legend = legend
            self.kind = kind
        }
    }

    /// Everything a render run can refuse over (each message is
    /// written to be printed verbatim and exit 1).
    public enum ChartError: Error, CustomStringConvertible {
        case noInput
        case notJSON
        case rejected(String)          // ok:false document — carry its message
        case unsupported(String?)      // unknown or missing schema

        /// The exact text `dit-chart` prints for this failure (its own
        /// message, never a wrapper around the source document's).
        public var description: String {
            switch self {
            case .noInput: return "no JSON on stdin (usage: dit --json | dit-chart --ascii)"
            case .notJSON: return "input is not a JSON document"
            case .rejected(let message): return "source reported failure: \(message)"
            case .unsupported(let schema):
                return "no chart defined for \(schema.map { "schema '\($0)'" } ?? "a document without a schema")"
            }
        }
    }

    // MARK: Parsing a document into charts

    /// Known chartable schemas. Unknown schemas are REFUSED, never
    /// "plotted as generic bars" — guessing what a number means is
    /// how charts start lying.
    public static let chartableSchemas: Set<String> = ["summary/1"]

    /// Parse a `--json` document into charts. Throws ``ChartError/notJSON``
    /// on malformed input, ``ChartError/rejected(_:)`` on `"ok":false`
    /// (carrying the source's message), and ``ChartError/unsupported(_:)``
    /// on unknown/missing schemas.
    public static func charts(fromJSON data: Data) throws -> (header: [String], charts: [Chart]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChartError.notJSON
        }
        if (root["ok"] as? Bool) == false {
            throw ChartError.rejected((root["error"] as? String) ?? "(no message)")
        }
        let schema = root["schema"] as? String
        guard schema == "summary/1" else {
            throw ChartError.unsupported(schema)
        }
        guard let doc = root["data"] as? [String: Any] else { throw ChartError.notJSON }

        func dec(_ any: Any?) -> Decimal? {
            guard let s = any as? String, !s.isEmpty else { return nil }
            return Decimal(string: s)
        }
        func str(_ any: Any?) -> String? { any as? String }

        let display = str(doc["displayCurrency"]) ?? "?"
        var header: [String] = [
            "Portfolio charts — amounts in \(display) (display currency)",
        ]
        let accounts = doc["accounts"] as? [[String: Any]] ?? []
        let holdings = doc["holdings"] as? [[String: Any]] ?? []
        header.append("source: summary/1 · \(accounts.count) accounts · \(holdings.count) holdings"
                          + (str(doc["generatedAt"]).map { " · generated \($0)" } ?? ""))
        if (doc["offline"] as? Bool) == true {
            header.append("note: OFFLINE — positions are valued at COST, not market; P&L is unknown, not zero")
        }
        for warning in (doc["warnings"] as? [String] ?? []).prefix(3) {
            header.append("note: \(warning)")
        }

        var charts: [Chart] = []

        // 1. Total value per account (display currency). Unknown
        // totals (unconvertible mix — the null-total rows) stay
        // dashed with their component hints.
        if !accounts.isEmpty {
            var legend = ["— = no trustworthy combined value (see the summary table)"]
            if (doc["offline"] as? Bool) == true { legend = ["(at cost — offline)", legend[0]] }
            charts.append(Chart(
                title: "Total value per account (\(display))",
                note: "bar = sum of cash + GIC + positions in display currency",
                // signed: accounts CAN be negative (overdrawn margin,
                // negative GIC) — that must read left-of-zero, never
                // as a rightward bar.
                signed: true,
                rows: accounts.map { account in
                    let name = (account["name"] as? String) ?? "?"
                    let reporting = (account["reportingCurrency"] as? String) ?? ""
                    let label = reporting != display && !reporting.isEmpty ? "\(name) (\(reporting))" : name
                    return Row(label: label, value: dec(account["total"]))
                },
                legend: legend, kind: "account"))
        }

        // 2. Position value per holding, % of the combined position
        // value. Percentages are display-currency shares.
        if !holdings.isEmpty {
            let totalPositions = dec((doc["totals"] as? [String: Any])?["positions"])
            let rows = holdings.compactMap { holding -> Row? in
                guard let value = dec(holding["valueDisplay"]) else { return nil }
                var trailing = ""
                if let total = totalPositions, total > 0, value > 0 {
                    // Display-only share of combined positions, 2 places,
                    // kept in Decimal end to end.
                    let share = roundToPlaces(value / total * 100, 2)
                    trailing = "(\(share.description)%)"
                }
                // Derived QUOTE (backfilled price) — the number below
                // is a model value; the marker keeps it visible.
                var marker: String?
                if (holding["quote"] as? [String: Any])?["via"] is String {
                    marker = "*"
                }
                let symbol = (holding["symbol"] as? String) ?? "?"
                let name = (holding["name"] as? String).flatMap { $0 as String? } ?? ""
                let label = name.isEmpty ? symbol : "\(symbol) \(name)"
                return Row(label: label, value: value, trailing: trailing, marker: marker)
            }
            if !rows.isEmpty {
                charts.append(Chart(
                    title: "Position value per holding (\(display))",
                    note: "bar = market value (or cost when offline), % of combined positions",
                    signed: false,
                    rows: rows,
                    legend: ["* = valued from a DERIVED (backfilled) quote — approximation, not a market price"],
                    kind: "value"))
            }
        }

        // 3. Unrealized P&L per position — a real plus/minus chart.
        let pnlRows = holdings.compactMap { holding -> Row? in
            guard holding["pnlDisplay"] != nil else { return nil }  // null = unknown, no bar
            let pct: String = {
                guard let raw = holding["pnlPct"] as? String, let ratio = Decimal(string: raw) else { return "" }
                let percent = roundToPlaces(ratio * 100, 1)
                return "(\(percent >= 0 ? "+" : "")\(percent.description)% cost)"
            }()
            return Row(label: (holding["symbol"] as? String) ?? "?",
                       value: dec(holding["pnlDisplay"]), trailing: pct)
        }
        if pnlRows.contains(where: { $0.value != nil }) {
            charts.append(Chart(
                title: "Unrealized P&L per position (\(display))",
                note: "bar = gain/loss vs cost basis in display currency; % is the native-currency ratio",
                signed: true,
                rows: pnlRows, kind: "pnl"))
        }

        // 4. Day change per position (same +/- pattern).
        let dayRows = holdings.compactMap { holding -> Row? in
            guard holding["dayChangeDisplay"] != nil else { return nil }
            let pct: String = {
                guard let raw = holding["dayPct"] as? String, let ratio = Decimal(string: raw) else { return "" }
                let percent = roundToPlaces(ratio * 100, 1)
                return "(\(percent >= 0 ? "+" : "")\(percent.description)%)"
            }()
            return Row(label: (holding["symbol"] as? String) ?? "?",
                       value: dec(holding["dayChangeDisplay"]), trailing: pct)
        }
        if dayRows.contains(where: { $0.value != nil }) {
            charts.append(Chart(
                title: "Day change per position (\(display))",
                note: "bar = last quote vs previous stored close, display currency; % is the native-currency ratio",
                signed: true,
                rows: dayRows, kind: "day"))
        }

        return (header, charts)
    }

    // MARK: Drawing

    /// Decimal-exact rounding for display strings (no binary float in
    /// the money path).
    static func roundToPlaces(_ value: Decimal, _ places: Int) -> Decimal {
        let handler = NSDecimalNumberHandler(roundingMode: .plain, scale: Int16(places),
                                              raiseOnExactness: false, raiseOnOverflow: false,
                                              raiseOnUnderflow: false, raiseOnDivideByZero: false)
        return (NSDecimalNumber(decimal: value).rounding(accordingToBehavior: handler)).decimalValue
    }

    /// Draw several charts one after another (each fully rendered).
    public static func render(charts: [Chart], width: Int, ascii: Bool) -> [String] {
        var lines: [String] = []
        for chart in charts {
            if chart.rows.allSatisfy({ $0.value == nil }) { continue }
            lines.append(contentsOf: render(chart: chart, width: max(width, 40), ascii: ascii))
            lines.append("")
        }
        return lines
    }

    /// One chart: title, optional note, aligned rows, and — for signed
    /// charts — a zero line at equal scale on both sides. Rows are
    /// ranked by size; anything past the cap folds into a counted
    /// remainder line instead of a wall of one-block bars.
    public static func render(chart: Chart, width: Int, ascii: Bool) -> [String] {
        var lines: [String] = [chart.title]
        if let note = chart.note { lines.append("  (\(note))") }

        let plottable = chart.rows.filter { $0.value != nil }
        let unknowns = chart.rows.filter { $0.value == nil }
        let ranked = plottable.sorted { abs($0.value!) > abs($1.value!) }
        let cap = 12
        var shown = Array(ranked.prefix(cap))
        let dashText = ascii ? "-" : "\u{2014}"
        let ellipsis = ascii ? "..." : "\u{2026}"
        var remainder: String?
        if ranked.count > cap {
            shown = Array(ranked.prefix(cap))
            let rest = ranked.dropFirst(cap)
            let sum = rest.reduce(Decimal.zero) { $0 + ($1.value ?? 0) }
            remainder = "\(ellipsis) +\(rest.count) smaller position" + (rest.count > 1 ? "s" : "")
                + " (combined \(moneyLabel(sum)) not drawn)"
        }
        // Unknown values stay VISIBLE as dashed rows (capped, so a
        // wall of dashes cannot bury the chart), never silently gone.
        var dashed = Array(unknowns.prefix(6))
        if unknowns.count > 6 {
            dashed = Array(unknowns.prefix(6))
            remainder = (remainder.map { $0 + "\n  " } ?? "")
                + "\(ellipsis) +\(unknowns.count - 6) more unknown rows not drawn"
        }

        let indent = "  "
        var labelWidth = (shown + dashed).map(\.label.count).max() ?? 6
        labelWidth = min(max(labelWidth, 6), 24)
        let moneyStrings = (shown + dashed).map { row -> String in
            guard let value = row.value else { return dashText }  // dashed, never 0
            return moneyLabel(value) + (row.trailing.isEmpty ? "" : " " + row.trailing)
        }
        let moneyWidth = max(moneyStrings.map(\.count).max() ?? 6, 10)
        let markerUsed = shown.contains { $0.marker != nil }
        let markerWidth = markerUsed ? 2 : 0
        let barWidth = width - indent.count - labelWidth - 1 - markerWidth - 1 - moneyWidth
        guard barWidth >= 6 else {
            // Too narrow to draw honest proportions: keep the facts, no bars.
            for row in shown {
                let money = row.value.map(moneyLabel) ?? dashText
                lines.append("\(indent)\(row.label)  \(money)")
            }
            return lines
        }

        let values = shown.compactMap { $0.value }
        let chartMax = max(abs(values.min() ?? 0), abs(values.max() ?? 0))

        // Bar GEOMETRY (cell counts) may use Double — it is layout,
        // not money; the values drawn stay Decimal end to end. One
        // cell means the SAME amount on both sides of zero.
        func cells(_ magnitude: Decimal, in span: Int) -> Int {
            guard span > 0, chartMax > 0 else { return 0 }
            let ratio = Double(truncating: magnitude as NSDecimalNumber)
                / Double(truncating: chartMax as NSDecimalNumber)
            return min(max(Int((ratio * Double(span)).rounded(.up)), 1), span)
        }

        // Zero placement for signed charts: mixed signs split the
        // field in half (one scale, nothing clipped); single-sign
        // charts run bars from the edge that keeps zero visible.
        var zeroColumn = 0
        if chart.signed, chartMax > 0 {
            if (values.min() ?? 0) < 0 && (values.max() ?? 0) > 0 {
                zeroColumn = barWidth / 2
            } else if (values.min() ?? 0) < 0 {
                zeroColumn = barWidth
            }
        }
        let barChar = ascii ? "#" : "\u{2588}"
        let zeroGlyph = ascii ? "^" : "\u{25B2}"

        for (row, money) in zip(shown + dashed, moneyStrings) {
            var field = Array(repeating: Character(" "), count: barWidth)
            if let value = row.value, value != 0, chartMax > 0 {
                if chart.signed && value < 0 {
                    let length = cells(abs(value), in: zeroColumn)
                    for index in (zeroColumn - length)..<zeroColumn {
                        if index >= 0 { field[index] = Character(barChar) }
                    }
                } else {
                    let length = cells(abs(value), in: barWidth - zeroColumn)
                    for index in zeroColumn..<min(zeroColumn + length, barWidth) {
                        field[index] = Character(barChar)
                    }
                }
            } else if row.value == nil {
                field[0] = Character(ascii ? "?" : "\u{2715}")
            }
            let markerCell = markerUsed ? " " + (row.marker ?? " ") : ""
            lines.append("\(indent)\(pad(row.label, labelWidth, ellipsis: ellipsis)) \(String(field))\(markerCell) \(padLeft(money, moneyWidth))")
        }

        if let remainder {
            lines.append("\(indent)\(remainder)")
        }

        if chart.signed {
            let axisIndent = indent.count + labelWidth + 1
            lines.append(String(repeating: " ", count: axisIndent + min(zeroColumn, barWidth - 1)) + zeroGlyph)
            lines.append("  (\(zeroGlyph) marks zero; both sides of it share one scale)")
        }
        for note in chart.legend
            where (!note.contains("= no") || !unknowns.isEmpty)
                && (!note.hasPrefix("*") || markerUsed) {
            // Dashed/marker legends only earn their place when that
            // marker is actually on screen.
            lines.append("\(indent)\(ascii ? note.replacingOccurrences(of: "\u{2014}", with: "-") : note)")
        }
        return lines
    }

    // MARK: Formatting helpers

    /// Money exactly as the summary tables speak it: grouped, 2 places,
    /// Decimal-exact rounding (display stays display — no binary
    /// float in the money path).
    static func moneyLabel(_ value: Decimal) -> String {
        let rounded = roundToPlaces(value, 2)
        let negative = rounded < 0
        let digits = (negative ? -rounded : rounded).description
        let parts = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = String(parts.first ?? "0")
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        while fraction.count < 2 { fraction.append("0") }
        if fraction.count > 2 { fraction = String(fraction.prefix(2)) }
        var grouped = ""
        for (index, character) in integer.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        grouped = String(grouped.reversed())
        return (negative ? "-" : "") + grouped + "." + fraction
    }

    private static func pad(_ text: String, _ width: Int, ellipsis: String) -> String {
        text.count >= width ? String(text.prefix(max(width - ellipsis.count, 1))) + ellipsis
            : text + String(repeating: " ", count: width - text.count)
    }

    private static func padLeft(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}