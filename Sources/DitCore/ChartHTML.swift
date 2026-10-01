import Foundation

// MARK: - dit-chart HTML support (interactive charts from machine documents)
//
// Same honesty contract as the ASCII renderer: this file is PRESENTATION
// only. Numbers travel as the exact strings the document carried and are
// shown verbatim in tooltips; nothing downstream adds, converts, or
// derives a value. Missing data stays missing: gaps break the line,
// unknown amounts render dashed — never as zero-length bars. Charts
// never mix currencies on one axis: series are grouped by the currency
// the document states.

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

    // MARK: summary/1 → interactive bar sections

    private static func summaryPage(_ root: [String: Any], title: String?) throws -> String {
        let jsonData = (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
        let (header, charts) = try ChartRenderer.charts(fromJSON: jsonData)
        var blocks = ""
        var drewAnything = false
        for chart in charts {
            let plottable = chart.rows.filter { $0.value != nil }
            if plottable.isEmpty { continue }
            drewAnything = true
            let values = plottable.compactMap { $0.value }
            let maxAbs = values.map { abs($0) }.max() ?? Decimal(1)
            let hasNegative = values.contains { $0 < 0 }
            let hasPositive = values.contains { $0 > 0 }
            // Signed charts with both signs share one scale around a
            // center zero line (mirrors the ASCII zero-line rule).
            let centerZero = chart.signed && hasNegative && hasPositive
            var inner = ""
            for row in chart.rows {
                let amount = (row.value.map { ChartRenderer.moneyLabel($0) } ?? "—")
                    + (row.trailing.isEmpty ? "" : " " + esc(row.trailing))
                let marker = row.marker ?? ""
                let tip = "\(row.label): "
                    + (row.value.map { ChartRenderer.moneyLabel($0) } ?? "no trustworthy value (never shown as zero)")
                    + (marker.isEmpty ? "" : " [\(marker)]")
                var bar = "<i class=\"dashed\"></i>"
                if let value = row.value {
                    let ratio = maxAbs == 0 ? 0
                        : Double(truncating: NSDecimalNumber(decimal: abs(value)))
                        / Double(truncating: NSDecimalNumber(decimal: maxAbs))
                    let width = min(max(ratio * 100, ratio == 0 ? 0 : 1.5), 100)
                    let w = String(format: "%.1f", width)
                    if value < 0 && width > 0 {
                        // Negative bars grow LEFTWARD, ending AT zero.
                        // On a shared-scale (center-zero) chart both
                        // halves span the same value range: a negative
                        // bar's half-track-per-value scale must equal
                        // the positive side's, or it reads twice as
                        // long AND crosses the zero line — the exact
                        // lie the ASCII renderer's half-span rule
                        // prevents.
                        if centerZero {
                            let half = String(format: "%.1f", width / 2)
                            bar = "<i class=\"neg\" style=\"left:calc(50% - \(half)%);width:\(half)%\"></i>"
                        } else {
                            bar = "<i class=\"neg\" style=\"left:calc(100% - \(w)%);width:\(w)%\"></i>"
                        }
                    } else if value > 0 && width > 0 {
                        if centerZero {
                            let half = String(format: "%.1f", width / 2)
                            bar = "<i style=\"left:50%;width:\(half)%\"></i>"
                        } else {
                            bar = "<i style=\"width:\(w)%\"></i>"
                        }
                    } else {
                        // A true zero stays a flat line, not a stub bar.
                        bar = "<i class=\"flat\"></i>"
                    }
                }
                inner += "<div class=\"row\(row.value == nil ? " unknown" : "")\(centerZero ? " cz" : "")\">"
                    + "<span class=\"lab\" title=\"\(esc(tip))\">\(esc(row.label))</span>"
                    + "<span class=\"track\">\(bar)</span>"
                    + "<span class=\"amt\">\(amount)</span></div>\n"
            }
            if let note = chart.note { inner += "<p class=\"note\">\(esc(note))</p>\n" }
            for legend in chart.legend { inner += "<p class=\"note\">\(esc(legend))</p>\n" }
            blocks += "<section><h2>\(esc(chart.title))</h2>\n<div class=\"bars\">\(inner)</div></section>\n"
        }
        var sublines = header
        if !drewAnything {
            sublines.append("nothing to chart — the document carries no plottable values")
        }
        return page(heading: title ?? "Portfolio charts", sublines: sublines,
                    body: blocks, lineData: "[]")
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
            chartData.append(["id": "c\(chartData.count)", "title": titleText, "lines": linesData])
            blocks += "<section><h2>\(esc(titleText))</h2>\n"
                + "<p class=\"note\">line = stored daily closes exactly as recorded; hover for values</p>\n"
                + "<canvas data-c=\"\(chartData.count - 1)\" width=\"1000\" height=\"260\"></canvas>\n"
                + "<ul class=\"legend\">" + legend.map { "<li>\(esc($0))</li>" }.joined() + "</ul></section>\n"
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
        let data = (try? JSONSerialization.data(withJSONObject: chartData, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // "</" would close the <script> tag early; "\/" is valid JSON
        // and keeps the page parseable everywhere.
        let safeData = data.replacingOccurrences(of: "</", with: "<\\/")
        return page(heading: title ?? "Historical closes", sublines: sublines,
                    body: blocks, lineData: safeData)
    }

    // MARK: Page shell

    private static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(heading: String, sublines: [String], body: String, lineData: String) -> String {
        var head = "<header><h1>\(esc(heading))</h1>\n"
        for line in sublines { head += "<p class=\"sub\">\(esc(line))</p>\n" }
        head += "</header>\n"
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(heading)) — dit chart</title>
        <style>
        body{background:#fbfbfd;color:#1c1c1e;font:14px/1.45 -apple-system,"Segoe UI",Roboto,sans-serif;margin:24px auto;max-width:1060px;padding:0 16px}
        h1{font-size:17px;margin:0 0 4px}h2{font-size:15px;margin:0 0 3px}
        .sub,.note{color:#6b6b70;font-size:12px;margin:2px 0}
        section{margin:24px 0 34px}
        .row{display:flex;align-items:center;gap:8px;padding:3px 6px;border-radius:4px}
        .row:hover{background:#eeeef2}
        .lab{width:230px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
        .amt{width:190px;text-align:right;font-variant-numeric:tabular-nums}
        .track{flex:1;height:13px;position:relative}
        .track i{position:absolute;top:1px;bottom:1px;left:0;background:#3478c6;border-radius:2px}
        .track i.neg{background:#c65b34}
        .row.cz .track::before{content:"";position:absolute;left:50%;top:0;bottom:0;border-left:1px solid #b7b7bd}
        .dashed{width:36px;height:0;top:7px;border-top:3px dashed #b7b7bd;background:none !important}
        .flat{width:100%;height:0;top:7px;border-top:1px solid #b7b7bd;background:none !important}
        canvas{width:100%;height:280px;background:#fff;border:1px solid #e3e3e8;border-radius:6px}
        .legend{font-size:12px;color:#6b6b70;margin:6px 0 0;padding-left:18px}
        #tip{position:fixed;display:none;background:#1c1c1e;color:#f2f2f5;font:12px/1.5 ui-monospace,Menlo,Consolas,monospace;padding:6px 9px;border-radius:6px;pointer-events:none;white-space:pre;z-index:9}
        </style></head><body>
        \(head)\(body)<div id="tip"></div>
        <script type="application/json" id="data">\(lineData)</script>
        <script>
        // Renderer contract: draw + tooltip ONLY. Values arrive as exact
        // strings and display as-is; nothing below converts, sums, or
        // derives money. Float math is for geometry (layout) only.
        const DATA=JSON.parse(document.getElementById('data').textContent||'[]');
        const tip=document.getElementById('tip');
        const COLORS=['#3478c6','#c65b34','#3a9a4f','#8a4fbf','#b7a13a','#2f9e9e','#b0455f','#6f6f78'];
        for(const canvas of document.querySelectorAll('canvas')){
          const chart=DATA[+canvas.dataset.c]; if(!chart) continue;
          const dpr=window.devicePixelRatio||1;
          const W=canvas.clientWidth||1000,H=280;
          canvas.width=W*dpr; canvas.height=H*dpr;
          const g=canvas.getContext('2d'); g.scale(dpr,dpr);
          const padL=66,padR=14,padT=12,padB=24;
          const real=chart.lines.flatMap(l=>l.points).filter(Array.isArray);
          if(!real.length) continue;
          let lo=Infinity,hi=-Infinity;
          for(const p of real){const v=+p[1];if(v<lo)lo=v;if(v>hi)hi=v;}
          if(lo===hi){lo-=1;hi+=1;}
          const days=real.map(p=>Date.parse(p[0])).sort((a,b)=>a-b);
          const t0=days[0],t1=days[days.length-1]||t0+86400000;
          const X=t=>padL+(t-t0)/Math.max(t1-t0,1)*(W-padL-padR);
          const Y=v=>padT+(1-(v-lo)/(hi-lo))*(H-padT-padB);
          g.fillStyle='#6b6b70'; g.font='11px sans-serif';
          for(const f of [lo,(lo+hi)/2,hi]){
            g.strokeStyle='#ececf1';g.beginPath();g.moveTo(padL,Y(f));g.lineTo(W-padR,Y(f));g.stroke();
            g.fillText(f.toFixed(2),6,Y(f)+3);
          }
          g.strokeStyle='#d0d0d6';g.beginPath();
          g.moveTo(padL,padT);g.lineTo(padL,H-padB);g.lineTo(W-padR,H-padB);g.stroke();
          chart.lines.forEach((line,li)=>{
            g.strokeStyle=COLORS[li%COLORS.length];g.lineWidth=1.7;
            g.setLineDash(line.dash?[5,3]:[]);
            g.beginPath();let open=false;
            for(const p of line.points){
              if(!Array.isArray(p)){open=false;continue;}
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
            if(rows.length){
              tip.textContent=rows.join('\\n');
              tip.style.display='block';
              tip.style.left=Math.min(e.clientX+14,window.innerWidth-280)+'px';
              tip.style.top=(e.clientY+12)+'px';
            } else tip.style.display='none';
          });
          canvas.addEventListener('mouseleave',()=>{tip.style.display='none';});
        }
        </script></body></html>
        """
    }
}
