import Foundation

// MARK: - dit-chart HTML support (interactive charts from machine documents)
//
// Same honesty contract as the ASCII renderer: this file is PRESENTATION
// only. Numbers travel as the exact strings the document carried and are
// shown verbatim in tooltips; nothing downstream adds, converts, or
// derives a value. Missing data stays missing: gaps break the line,
// unknown amounts render as a dashed stub — never as a zero-length bar.
// Charts never mix currencies on one axis: series are grouped by the
// currency the document states.
//
// The dark "insights dashboard" layout (stat cards + column charts with
// a shared zero baseline) follows the look of the earlier React app's
// MarketInsights page — styling only. All finance data arrives already
// computed; bar heights and axis ticks are GEOMETRY derived from the
// document's exact values, never a re-computation of money.

public enum ChartHTML {

    /// Gaps of this many missing days break the drawn line; shorter
    /// runs are weekend/holiday dust (weekday-sampled data) and stay
    /// unmarked — the same reasoning as the coverage audit.
    static let gapBreakDays = 10

    // MARK: Parsing

    /// Build a self-contained HTML page from one machine document.
    /// Throws the same ``ChartRenderer/ChartError`` refusals as the
    /// terminal renderer: failed source documents carry their message,
    /// unknown (or chart-less) schemas are refused, never "plotted as
    /// generic bars".
    public static func document(fromJSON data: Data, title: String? = nil) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChartRenderer.ChartError.notJSON
        }
        if (root["ok"] as? Bool) == false {
            throw ChartRenderer.ChartError.rejected((root["error"] as? String) ?? "(no message)")
        }
        switch root["schema"] as? String {
        case "summary/1":
            return try summaryPage(root, title: title)
        case "quote/1":
            guard let doc = root["data"] as? [String: Any],
                  (doc["mode"] as? String) == "series",
                  let quotes = doc["quotes"] as? [[String: Any]], !quotes.isEmpty
            else {
                // Live quotes and FX matrices are single-day snapshots —
                // there is no time series to chart; refusing is honest.
                throw ChartRenderer.ChartError.unsupported(root["schema"] as? String)
            }
            return try seriesPage(doc, quotes: quotes, title: title)
        default:
            throw ChartRenderer.ChartError.unsupported(root["schema"] as? String)
        }
    }

    // MARK: summary/1 → stat cards + column charts

    /// One plottable column: label, exact display string, geometry kind,
    /// signed height fraction, and the pre-built tooltip text.
    private struct Bar {
        var label: String
        var display: String
        /// "u" up column, "d" down column, "g" ghost (unknown),
        /// "z" true zero (draws nothing — a stub would read as a value).
        var glyph: String
        var height: Double
        var tip: String
    }

    private static func summaryPage(_ root: [String: Any], title: String?) throws -> String {
        let jsonData = (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
        let (header, charts) = try ChartRenderer.charts(fromJSON: jsonData)
        let data = (root["data"] as? [String: Any]) ?? [:]
        let unit = (data["displayCurrency"] as? String) ?? ""
        var body = kpiStrip(data, unit: unit)
        var payloadCharts: [[String: Any]] = []
        var drewAnything = false

        func dbl(_ d: Decimal) -> Double { Double(truncating: NSDecimalNumber(decimal: d)) }

        for chart in charts {
            let plottable = chart.rows.filter { $0.value != nil }
            if plottable.isEmpty { continue }
            drewAnything = true
            let values = plottable.compactMap { $0.value }
            let vMin = values.map(dbl).min() ?? 0
            let vMax = values.map(dbl).max() ?? 0
            // Column mode + colours follow the template's colour
            // language: quantity charts are one flat colour (account
            // totals purple, holding values blue — the NUMBER is the
            // point, not its sign); performance charts (P&L, day
            // change) are green/red by sign around a zero baseline.
            let signed = chart.signed
            let color = chart.kind == "account" ? "#8b5cf6"
                : chart.kind == "value" ? "#3b82f6" : "sign"
            // One shared scale for the whole chart. The domain always
            // CONTAINS zero (chart-wide zero line), is padded to a
            // "nice" step so gridlines land on readable values, and a
            // column can never grow past the zero line: |value| ≤ the
            // domain on its own side, by construction.
            var lo = signed ? min(vMin, 0) : min(0, vMin)
            var hi = max(vMax, 0)
            if hi <= lo { hi = lo + max(abs(lo), abs(hi), 1) }
            let step = niceStep((hi - lo) / 4.5)
            lo = (lo / step).rounded(.down) * step
            hi = (hi / step).rounded(.up) * step
            let span = hi - lo
            let zf = min(max(hi / span, 0), 1)   // zero line, fraction from the TOP

            var ticks: [[Any]] = []
            var t = lo
            while t <= hi + step * 0.001 && ticks.count <= 9 {
                ticks.append([tickLabel(t), (hi - t) / span])
                t += step
            }

            var bars: [Bar] = []
            for row in chart.rows {
                guard let value = row.value else {
                    bars.append(Bar(label: row.label, display: "—", glyph: "g", height: 0,
                                    tip: "\(row.label)\nno trustworthy value (never shown as zero)"))
                    continue
                }
                let amount = (ChartRenderer.moneyLabel(value)
                    + (row.trailing.isEmpty ? "" : " " + row.trailing))
                if value == 0 {
                    bars.append(Bar(label: row.label, display: amount, glyph: "z", height: 0,
                                    tip: "\(row.label)\n\(unit) : \(amount)"))
                    continue
                }
                let raw = dbl(value) / span
                // A column thinner than 0.6 % of the plot is drawn at
                // that floor so tiny-but-real values stay visible; the
                // tooltip still carries the exact figure.
                let h = abs(raw) < 0.006 ? (raw < 0 ? -0.006 : 0.006) : raw
                var tip = "\(row.label)\n\(unit) : \(amount)"
                if row.marker == "*" { tip += "\n(* derived — approximation)" }
                if row.marker == "~" { tip += "\n(~ triangulated FX)" }
                bars.append(Bar(label: row.label, display: amount,
                                glyph: value < 0 ? "d" : "u", height: h, tip: tip))
            }

            var legend: [String] = []
            if signed {
                legend.append("line marks zero; bars grow away from it on one shared scale")
            }
            let hasGhost = chart.rows.contains { $0.value == nil }
            for line in chart.legend {
                if hasGhost && line.hasPrefix("— = ") {
                    legend.append("dashed stub = " + line.dropFirst("— = ".count))
                } else {
                    legend.append(line)
                }
            }

            let cols: [[String: Any]] = bars.map { bar in
                ["t": bar.label, "v": bar.display, "g": bar.glyph,
                 "h": (bar.height * 1_000_000).rounded() / 1_000_000, "p": bar.tip]
            }
            payloadCharts.append(["t": chart.title, "mode": signed ? "pnl" : "qty",
                                  "col": color, "zf": (zf * 1e6).rounded() / 1e6,
                                  "tk": ticks, "cols": cols])

            var section = "<section class=\"card\">\n<h2>\(esc(chart.title))"
                + (unit.isEmpty ? "" : " <span class=\"cu\">(\(esc(unit)))</span>")
                + "</h2>\n<canvas class=\"bars\" data-b=\"\(payloadCharts.count - 1)\"></canvas>\n"
            if let note = chart.note { section += "<div class=\"legend\"><p>\(esc(note))</p>\n" }
            else { section += "<div class=\"legend\">\n" }
            for line in legend { section += "<p>\(esc(line))</p>\n" }
            section += "</div></section>\n"
            body += section
        }

        var sublines = header
        if !drewAnything {
            sublines.append("nothing to chart — the document carries no plottable values")
        }
        let payload: [String: Any] = ["mode": "summary", "unit": unit, "charts": payloadCharts]
        return page(heading: title ?? "Portfolio charts", sublines: sublines,
                    body: body, dataJSON: payload)
    }

    /// "Nice" gridline step (1/2/2.5/5 × 10^n) at or above `raw`.
    ///
    /// - Returns: the smallest ladder step at or above `raw`, or 1 for
    ///   non-positive input (a zero-range chart still draws).
    private static func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        for multiple in [1.0, 2.0, 2.5, 5.0, 10.0] {
            if raw <= multiple * magnitude + magnitude * 0.0001 { return multiple * magnitude }
        }
        return 10 * magnitude
    }

    /// Format one axis tick label.
    ///
    /// Tick labels are display abbreviations ($150K style), like the
    /// reference dashboard; the EXACT figures stay in the tooltips.
    ///
    /// - Returns: a `$`-prefixed abbreviation (`$1.2M`, `$-2K`, `$40`).
    private static func tickLabel(_ value: Double) -> String {
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        if magnitude < 0.000_001 { return "$0" }
        if magnitude >= 1_000_000 { return String(format: "\(sign)$%.1fM", magnitude / 1_000_000) }
        if magnitude >= 1_000 { return String(format: "\(sign)$%.0fK", magnitude / 1_000) }
        return String(format: "\(sign)$%.0f", magnitude)
    }

    /// The stat-card strip, built ONLY from figures the document
    /// already states (data.totals). Missing figure → no card, never
    /// a "—" filler card; a card's tint follows the figure's sign.
    private static func kpiStrip(_ data: [String: Any], unit: String) -> String {
        guard let totals = data["totals"] as? [String: Any], !totals.isEmpty else { return "" }
        func card(_ label: String, _ key: String, _ sub: String,
                  style: String, signed: Bool = false, skipZero: Bool = false) -> String {
            guard let raw = totals[key] as? String, !raw.isEmpty,
                  let value = Decimal(string: raw) else { return "" }
            if skipZero && value == 0 { return "" }
            let cls: String
            if style == "perf" { cls = value < 0 ? "k neg" : "k pos" }
            else { cls = "k \(style)" }
            return "<div class=\"\(cls)\"><p class=\"kl\">\(esc(label))</p>"
                + "<p class=\"kv\">\(esc(kpiValue(value, signed: signed)))</p>"
                + "<p class=\"ks\">\(esc(sub))</p></div>\n"
        }
        let cards = [
            card("Total MTM (\(unit))", "totalValue", "All positions incl. Cash & GIC", style: ""),
            card("Total P&L (\(unit))", "unrealizedPnl", "Unrealized, market positions", style: "perf", signed: true),
            card("Today's P&L (\(unit))", "dayChange", "Equity positions only", style: "perf", signed: true),
            card("Total Cash (\(unit))", "cash", "Cash positions", style: "cash", skipZero: true),
            card("Total GIC (\(unit))", "gic", "GIC positions", style: "gic", skipZero: true),
        ].joined()
        return cards.isEmpty ? "" : "<div class=\"kpis\">\n\(cards)</div>\n"
    }

    /// Display-only money dressing for the stat cards: grouping, the
    /// currency symbol, and a leading sign. The Decimal value itself is
    /// the document's; nothing here re-derives it (2-place display
    /// rounding only — the exact figure stays in the document).
    private static func kpiValue(_ value: Decimal, signed: Bool) -> String {
        let negative = value < 0
        let absValue = value < 0 ? -value : value
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.usesSignificantDigits = false
        // Money display: two fraction digits always, so "+$408,862.82"
        // and "$5,000.00" read at the same eye-line (truncation to a
        // short "5,000" or "806.8" would flicker widths per card).
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        let number = NSDecimalNumber(decimal: absValue)
        let amount = "$" + (formatter.string(from: number) ?? number.stringValue)
        if negative { return "−\(amount)" }
        if signed { return "+\(amount)" }
        return amount
    }

    // MARK: quote/1 series → line sections

    private static func seriesPage(_ doc: [String: Any], quotes: [[String: Any]],
                                   title: String?) throws -> String {
        var order: [String] = []
        var bySymbol: [String: [(date: String, price: String, derived: Bool, ccy: String)]] = [:]
        var missing: [String] = []
        for quote in quotes {
            guard let symbol = quote["symbol"] as? String else { continue }
            if quote["date"] is NSNull || quote["price"] is NSNull {
                if !missing.contains(symbol) { missing.append(symbol) }
                continue
            }
            guard let date = quote["date"] as? String, let price = quote["price"] as? String,
                  !price.isEmpty
            else { continue }
            if bySymbol[symbol] == nil { order.append(symbol) }
            bySymbol[symbol, default: []].append((date, price,
                                                   (quote["via"] as? String) != nil,
                                                   (quote["ccy"] as? String) ?? "?"))
        }

        // One chart per STATED currency; a series whose currency the
        // document does not state gets its own chart — two unknowns
        // sharing an axis would bet that they are the same unit.
        var chartKeys: [String] = []            // currency code or symbol
        var groups: [String: [String]] = [:]    // chart key → symbols
        var unitLabel: [String: String] = [:]   // chart key → axis unit
        for symbol in order {
            guard let points = bySymbol[symbol], !points.isEmpty else { continue }
            let currencies = Set(points.map(\.ccy)).sorted()
            let key: String
            let unit: String
            if currencies.count == 1, currencies[0] != "?" {
                key = currencies[0]
                unit = currencies[0]
            } else {
                key = symbol
                unit = "?"
            }
            if groups[key] == nil { chartKeys.append(key); unitLabel[key] = unit }
            groups[key, default: []].append(symbol)
        }

        var chartData: [[String: Any]] = []
        var blocks = ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for key in chartKeys {
            let unit = unitLabel[key] ?? "?"
            var linesData: [[String: Any]] = []
            var anyDashed = false
            for symbol in groups[key] ?? [] {
                guard let points = bySymbol[symbol] else { continue }
                // A point is [date, exact value, derived]; a gap is the
                // JSON null — JS breaks the stroke there, never bridges.
                var drawn: [Any] = []
                var previousDate: Date?
                var dashed = false
                for point in points {
                    if let previous = previousDate, let day = formatter.date(from: point.date),
                       Int(day.timeIntervalSince(previous) / 86_400) >= gapBreakDays {
                        drawn.append(NSNull())
                    }
                    if let day = formatter.date(from: point.date) { previousDate = day }
                    dashed = dashed || point.derived
                    drawn.append([point.date, point.price, point.derived ? 1 : 0] as [Any])
                }
                anyDashed = dashed || anyDashed
                linesData.append(["label": "\(symbol) (\(unit))", "dash": dashed, "points": drawn])
            }
            guard !linesData.isEmpty else { continue }
            var legend = ["line breaks mark ≥\(gapBreakDays)-day holes in stored data",
                          "axis starts at the smallest shown value, not zero — read against the printed scale"]
            if anyDashed {
                legend.insert("dashed = contains DERIVED (backfilled) closes — approximation, not observation", at: 0)
            }
            let titleText = unit == "?"
                ? "Closes for \(groups[key]?.joined(separator: ", ") ?? key) — currency not stated, kept off other charts"
                : "Closes in \(unit)"
            chartData.append(["t": titleText, "lines": linesData])
            blocks += "<section class=\"card\"><h2>\(esc(titleText))</h2>\n"
                + "<div class=\"legend\"><p>line = stored daily closes exactly as recorded; hover for values</p></div>\n"
                + "<canvas data-c=\"\(chartData.count - 1)\"></canvas>\n"
                + "<div class=\"legend\">" + legend.map { "<p>\(esc($0))</p>" }.joined() + "</div></section>\n"
        }

        let rangeText = [doc["from"] as? String, doc["to"] as? String]
            .compactMap { $0 }.joined(separator: " … ")
        var sublines = ["source: quote/1 · \(doc["count"] as? Int ?? quotes.count) closes"
                            + (rangeText.isEmpty ? "" : " · \(rangeText)")]
        if let store = doc["store"] as? String { sublines.append("store: \(store)") }
        if !missing.isEmpty {
            sublines.append("no stored closes for: \(missing.joined(separator: ", ")) — not plotted")
        }
        if chartData.isEmpty {
            sublines.append("nothing to chart — no plottable series in this document")
        }
        let payload: [String: Any] = ["mode": "series", "charts": chartData]
        return page(heading: title ?? "Historical closes", sublines: sublines,
                    body: blocks, dataJSON: payload)
    }

    // MARK: Page shell

    private static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(heading: String, sublines: [String], body: String,
                             dataJSON payload: [String: Any]) -> String {
        var head = "<header><h1>\(esc(heading))</h1>\n"
        for line in sublines { head += "<p class=\"sub\">\(esc(line))</p>\n" }
        head += "</header>\n"
        var data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // "</" would close the <script> tag early; "\/" is valid JSON
        // and keeps the page parseable everywhere.
        data = data.replacingOccurrences(of: "</", with: "<\\/")
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(heading)) — dit chart</title>
        <style>
        body{background:#030712;color:#d1d5db;font:14px/1.45 -apple-system,"Segoe UI",Roboto,sans-serif;margin:22px auto;max-width:1180px;padding:0 18px}
        h1{font-size:17px;margin:0 0 4px;color:#f3f4f6}
        h2{font-size:13.5px;font-weight:600;color:#e5e7eb;margin:0 0 10px}
        .cu{color:#6b7280;font-weight:400}
        .sub,.note{color:#6b7280;font-size:12px;margin:2px 0}
        header{margin-bottom:16px}
        .kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:14px 0 20px}
        .k,.card{background:#1f2937;border:1px solid #374151;border-radius:12px}
        .k{padding:12px 14px}
        .k.pos{background:rgba(34,197,94,.08);border-color:rgba(34,197,94,.35)}
        .k.neg{background:rgba(239,68,68,.08);border-color:rgba(239,68,68,.38)}
        .kl{font-size:11px;color:#9ca3af;margin:0 0 4px}
        .kv{font-size:21px;font-weight:700;margin:0;color:#f3f4f6;font-variant-numeric:tabular-nums}
        .k.pos .kv{color:#4ade80}.k.neg .kv{color:#f87171}
        .k.cash .kv{color:#22d3ee}.k.gic .kv{color:#c084fc}
        .ks{font-size:11px;color:#6b7280;margin:4px 0 0}
        .card{padding:14px 16px;margin:14px 0}
        canvas{width:100%;height:252px;display:block}
        .legend{margin:8px 2px 2px}
        .legend p{font-size:11px;color:#6b7280;margin:2px 0}
        #tip{position:fixed;display:none;background:#1f2937;border:1px solid #374151;color:#e5e7eb;font:12px/1.5 ui-monospace,Menlo,Consolas,monospace;padding:7px 10px;border-radius:8px;pointer-events:none;white-space:pre;z-index:9;box-shadow:0 6px 20px rgba(0,0,0,.45)}
        </style></head><body>
        \(head)\(body)<div id="tip"></div>
        <script type="application/json" id="data">\(data)</script>
        <script>
        // Renderer contract: draw + tooltip ONLY. Values arrive as exact
        // strings and display as-is; nothing below converts, sums, or
        // derives money. Float math is for geometry (layout) only.
        const DATA=JSON.parse(document.getElementById('data').textContent||'{}');
        const tip=document.getElementById('tip');
        const COLORS=['#60a5fa','#f87171','#4ade80','#c084fc','#fbbf24','#22d3ee','#fb7185','#94a3b8'];
        function showTip(e,text){
          tip.textContent=text; tip.style.display='block';
          tip.style.left=Math.min(e.clientX+14,window.innerWidth-290)+'px';
          tip.style.top=(e.clientY+12)+'px';
        }
        for(const canvas of document.querySelectorAll('canvas')){
          const dpr=window.devicePixelRatio||1;
          const W=canvas.clientWidth||1000,H=canvas.clientHeight||252;
          canvas.width=W*dpr; canvas.height=H*dpr;
          const g=canvas.getContext('2d'); g.scale(dpr,dpr);
          if(canvas.classList.contains('bars')) drawBars(g,canvas,W,H);
          else drawLine(g,canvas,W,H);
        }
        // Column charts. Geometry (height fractions, zero position, tick
        // placement) was computed by dit from the document's exact
        // values; this only paints rectangles and hover state.
        function drawBars(g,canvas,W,H){
          const ch=(DATA.charts||[])[+canvas.dataset.b]; if(!ch) return;
          const n=ch.cols.length; if(!n) return;
          const padL=58,padR=10,padT=10,padB=26;
          const pw=W-padL-padR,ph=H-padT-padB;
          const zy=padT+ch.zf*ph;                       // the zero baseline
          const slot=pw/n,bw=Math.max(Math.min(slot*0.7,42),2);
          function scene(){
            g.clearRect(0,0,W,H);
            g.font='10px ui-sans-serif,system-ui,sans-serif';
            for(const t of ch.tk){                        // dashed gridlines
              const y=padT+t[1]*ph;
              g.strokeStyle='#2b3442'; g.setLineDash([3,3]);
              g.beginPath(); g.moveTo(padL,y); g.lineTo(W-padR,y); g.stroke();
              g.setLineDash([]);
              g.fillStyle='#64748b'; g.fillText(t[0],4,y+3);
            }
            if(ch.mode==='pnl'){                           // solid zero line
              g.strokeStyle='#64748b';
              g.beginPath(); g.moveTo(padL,zy); g.lineTo(W-padR,zy); g.stroke();
            }
            ch.cols.forEach((c,i)=>{
              const x=padL+i*slot+(slot-bw)/2;
              if(c.g==='g'){          // ghost: dashed stub (never a zero bar)
                g.strokeStyle='#6b7280'; g.setLineDash([3,3]);
                g.beginPath(); g.moveTo(x,zy); g.lineTo(x+bw,zy); g.stroke();
                g.setLineDash([]);
                return;
              }
              if(c.g==='z'||c.h===0) return;               // true zero: nothing
              const h=Math.abs(c.h)*ph, up=c.h>0;
              const y=up?zy-h:zy;
              g.fillStyle=(ch.col==='sign')?(up?'#22c55e':'#ef4444'):ch.col;
              g.beginPath();
              const rr=Math.min(4,bw/2,h);                 // rounded OUTER end
              if(up){ g.moveTo(x,zy); g.lineTo(x,y+rr);
                g.arcTo(x,y,x+rr,y,rr); g.lineTo(x+bw-rr,y);
                g.arcTo(x+bw,y,x+bw,y+rr,rr); g.lineTo(x+bw,zy); }
              else { g.moveTo(x,zy); g.lineTo(x,zy+h-rr);
                g.arcTo(x,zy+h,x+rr,zy+h,rr); g.lineTo(x+bw-rr,zy+h);
                g.arcTo(x+bw,zy+h,x+bw,zy+h-rr,rr); g.lineTo(x+bw,zy); }
              g.closePath(); g.fill();
            });
            let maxLen=0; for(const c of ch.cols) maxLen=Math.max(maxLen,c.t.length);
            const stride=Math.max(1,Math.ceil(n*(maxLen*6.5+6)/pw));
            g.fillStyle='#94a3b8';
            ch.cols.forEach((c,i)=>{ if(i%stride===0) g.fillText(c.t,padL+i*slot+slot/2,H-10); });
          }
          scene();
          const base=g.getImageData(0,0,canvas.width,canvas.height);
          canvas.addEventListener('mousemove',e=>{
            const r=canvas.getBoundingClientRect();
            const mx=e.clientX-r.left, my=e.clientY-r.top;
            const i=Math.floor((mx-padL)/slot);
            g.putImageData(base,0,0);
            if(i>=0&&i<n&&my>=padT&&my<=padT+ph){
              g.fillStyle='rgba(255,255,255,0.05)';
              g.fillRect(padL+i*slot,padT,slot,ph);
              showTip(e,ch.cols[i].p);
            } else tip.style.display='none';
          });
          canvas.addEventListener('mouseleave',()=>{
            g.putImageData(base,0,0); tip.style.display='none';
          });
        }
        function drawLine(g,canvas,W,H){
          const chart=(DATA.charts||[])[+canvas.dataset.c]; if(!chart) return;
          const padL=66,padR=14,padT=12,padB=24;
          const real=chart.lines.flatMap(l=>l.points).filter(Array.isArray);
          if(!real.length) return;
          let lo=Infinity,hi=-Infinity;
          for(const p of real){const v=+p[1];if(v<lo)lo=v;if(v>hi)hi=v;}
          if(lo===hi){lo-=1;hi+=1;}
          const days=real.map(p=>Date.parse(p[0])).sort((a,b)=>a-b);
          const t0=days[0],t1=days[days.length-1]||t0+86400000;
          const X=t=>padL+(t-t0)/Math.max(t1-t0,1)*(W-padL-padR);
          const Y=v=>padT+(1-(v-lo)/(hi-lo))*(H-padT-padB);
          g.fillStyle='#64748b'; g.font='11px sans-serif';
          for(const f of [lo,(lo+hi)/2,hi]){
            g.strokeStyle='#2b3442';g.setLineDash([3,3]);
            g.beginPath();g.moveTo(padL,Y(f));g.lineTo(W-padR,Y(f));g.stroke();
            g.setLineDash([]);
            g.fillText(f.toFixed(2),6,Y(f)+3);
          }
          chart.lines.forEach((line,li)=>{
            g.strokeStyle=COLORS[li%COLORS.length];g.lineWidth=1.7;
            g.setLineDash(line.dash?[5,3]:[]);
            g.beginPath();let open=false;
            for(const p of line.points){
              if(!Array.isArray(p)){open=false;continue;}   // a gap BREAKS the line
              const x=X(Date.parse(p[0])),y=Y(+p[1]);
              if(!open){g.moveTo(x,y);open=true;}else g.lineTo(x,y);
            }
            g.stroke();
          });
          g.setLineDash([]);
          canvas.addEventListener('mousemove',e=>{
            const r=canvas.getBoundingClientRect();
            const mx=e.clientX-r.left;
            const rows=[];
            for(const line of chart.lines){
              let best=null,bd=1e9;
              for(const p of line.points){
                if(!Array.isArray(p))continue;
                const d=Math.abs(X(Date.parse(p[0]))-mx);
                if(d<bd){bd=d;best=p;}
              }
              if(best&&bd<44) rows.push(line.label+'  '+best[0]+': '+best[1]+(best[2]?'  (derived — approximation)':''));
            }
            if(rows.length) showTip(e,rows.join('\\n'));
            else tip.style.display='none';
          });
          canvas.addEventListener('mouseleave',()=>{tip.style.display='none';});
        }
        </script></body></html>
        """
    }
}
