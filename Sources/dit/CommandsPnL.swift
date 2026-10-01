import DirectInvestTracker
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - pnl (historical P&L between dates)

/// Split a comma-separated option value into trimmed, non-empty parts.
func splitCSV(_ raw: String) -> [String] {
    raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// `dit pnl`: historical P&L over a window (full ledger by default,
/// `--horizon`, or explicit `--from`/`--to`), scoped by accounts,
/// tickers and currencies. Text output speaks ONE currency — the
/// reporting currency (`--reporting-ccy`, default = display, CAD) —
/// converting each native amount at the FX close stored on/before
/// the relevant date. Unconvertible amounts dash; native figures
/// remain in `--json`. Reads the market STORE only — never fetches.
func pnlCommand(_ args: [String], global: Global) async throws {
    let options = try Options(args, valueOptions: ["horizon", "from", "to", "account", "tickers",
                                                    "ccy", "reporting-ccy"],
                              flagOptions: ["time-series", "daily"])
    if options["horizon"] != nil, options["from"] != nil || options["to"] != nil {
        throw ParseError("--horizon and --from/--to cannot be combined — pick one window form")
    }
    let wantSeries = options.flag("time-series") == true
    let forceDaily = options.flag("daily") == true
    if forceDaily, !wantSeries {
        throw ParseError("--daily is a modifier of --time-series — "
            + "use 'dit pnl --time-series --daily' (see 'dit help pnl')")
    }
    guard options.positionals.isEmpty else {
        throw ParseError("unexpected argument '\(options.positionals[0])' — "
            + "'dit pnl' filters with --account/--tickers/--ccy (see 'dit help pnl')")
    }
    let (store, configuration) = try openStore(global: global)
    guard let portfolio = try await store.load() else {
        if global.json {
            print(JSONOutput.envelope(schema: "pnl/1", data: [
                "empty": true,
                "note": "no portfolio found — add accounts and transactions first",
                "store": configuration.url.path,
            ]))
            return
        }
        print("No portfolio found (store: \(configuration.backend.rawValue) at \(configuration.url.path)).")
        print("Nothing to report — add accounts and transactions first.")
        return
    }

    // MARK: Scope — accounts (default: every account, aggregated)
    var accounts = portfolio.accounts
    var perAccount = false
    if let raw = options["account"] {
        let names = splitCSV(raw)
        guard !names.isEmpty else {
            throw ParseError("--account needs at least one account name (see 'dit accounts')")
        }
        var resolved: [Account] = []
        for name in names {
            resolved.append(try resolveAccount(name, in: portfolio))
        }
        var seen = Set<UUID>()
        accounts = resolved.filter { seen.insert($0.id).inserted }
        perAccount = true // naming accounts is asking to see THEM, not an aggregate
    }

    // MARK: Filters — tickers and currencies (empty match = nothing,
    // never a silent widening back to "all")
    var symbolFilter: Set<String>?
    if let raw = options["tickers"] {
        let list = splitCSV(raw).map { $0.uppercased() }
        guard !list.isEmpty else { throw ParseError("--tickers needs at least one symbol") }
        symbolFilter = Set(list)
    }
    var currencyFilter: Set<Currency>?
    if let raw = options["ccy"] {
        let codes = splitCSV(raw)
        guard !codes.isEmpty else { throw ParseError("--ccy needs at least one currency code") }
        currencyFilter = Set(try codes.map { try parseCurrency($0, option: "--ccy") })
    }
    let reporting = try options["reporting-ccy"].map { try parseCurrency($0, option: "--reporting-ccy") }
        ?? global.display

    // MARK: Window (no mixing: horizon vs explicit dates was rejected above)
    let fromRaw = options["from"]
    let toRaw = options["to"]
    let from = try fromRaw.map { try parseDate($0) }
    let to = try toRaw.map { try parseDate($0) }
    // The full/default window (and --to alone) starts at the earliest
    // transaction INSIDE the chosen scope — that is the honest ledger
    // start for what is being reported.
    let ledgerStart = accounts
        .flatMap { portfolio.transactions(in: $0.id).map(\.date) }
        .min()

    let window: PnLReport.Window
    do {
        window = try PnLWindow.resolveWindow(horizon: options["horizon"], from: from, to: to,
                                             now: Date.now, ledgerStart: ledgerStart)
    } catch let error as PnLWindow.WindowError {
        throw ParseError(error.description)
    }

    // MARK: Market data — stored closes + FX pair history, never the
    // network. Cross-currency reporting converts at DATED closes
    // only: the latest-snapshot rates are deliberately unused here
    // (today's rate is not last June's rate), and a window whose FX
    // history stops before its dates dashes instead of guessing.
    var marketData: MarketData?
    var notes: [String] = []
    do {
        let (marketStore, _) = try openMarketStore(global: global)
        marketData = try await marketStore.load()
    } catch {
        notes.append("market store unreadable: \(error) — no position-change data")
    }
    let fx = marketData.map { FXClock(series: $0.series) }

    let report = PnLWindow.compute(portfolio: portfolio,
                                   window: window,
                                   accounts: accounts,
                                   perAccount: perAccount,
                                   symbols: symbolFilter,
                                   currencies: currencyFilter,
                                   reportingCurrency: reporting,
                                   market: marketData,
                                   fx: fx)

    // `--time-series`: slice the SAME window into periods, each one
    // computed by the same engine (adjacent baselines telescope).
    // `--daily` overrides the auto-picked period size with one day.
    var series: PnLSeries?
    if wantSeries {
        let granularity: SeriesGranularity = forceDaily
            ? .daily
            : PnLWindow.autoGranularity(window: window)
        series = PnLWindow.computeSeries(portfolio: portfolio,
                                         window: window,
                                         granularity: granularity,
                                         accounts: accounts,
                                         perAccount: perAccount,
                                         symbols: symbolFilter,
                                         currencies: currencyFilter,
                                         reportingCurrency: reporting,
                                         market: marketData,
                                         fx: fx,
                                         fullReport: report)
    }

    // MARK: JSON — one document, nulls where a number would lie
    if global.json {
        let windowJSON: [String: Any] = [
            "label": report.window.label,
            "start": JSONOutput.isoDay(report.window.start),
            "end": JSONOutput.isoDay(report.window.end),
            "fromLedgerStart": report.window.fromLedgerStart,
        ]
        let scopeJSON: [String: Any] = [
            "accounts": perAccount ? accounts.map(\.displayName) : "all",
            "tickers": symbolFilter.map { $0.sorted() } ?? "all",
            "currencies": currencyFilter.map { $0.sorted(by: { $0.rawValue < $1.rawValue }).map(\.rawValue) } ?? "all",
            "reportingCurrency": reporting.rawValue,
            "perAccount": perAccount,
        ]
        let mixedView = report.perCurrency.contains { $0.currency != reporting }
        let positionJSON = report.rows.map { row -> [String: Any] in
            var json: [String: Any] = [
                "symbol": row.symbol,
                "kind": row.isCashPnL ? "cash" : "position",
                "accounts": row.accountNames,
                "currency": row.currency.rawValue,
                "realized": JSONOutput.money(row.realized),
                "positionChange": row.positionChange.map { JSONOutput.money($0) } ?? NSNull(),
                "total": row.total.map { JSONOutput.money($0) } ?? NSNull(),
                "basis": row.positionChange == nil ? NSNull() : (row.usedDerivedHistory ? "derived" : "observed"),
            ]
            // Converted figures ride along ONLY where a conversion is
            // involved (single-currency documents stay byte-identical).
            // The "reported" triple converts the SAME native numbers
            // at the dated FX used for this window — nulls mark what
            // could not be converted, never a hidden fallback.
            if row.currency != reporting {
                let factor = report.fxRates[row.currency]?.rate
                func reported(_ value: Decimal?) -> Any {
                    guard let value, let factor else { return NSNull() }
                    return JSONOutput.money(value * factor)
                }
                json["reported"] = [
                    "positionChange": reported(row.positionChange),
                    "realized": reported(row.realized),
                    "total": reported(row.total),
                ]
            }
            return json
        }
        let currencyJSON = report.perCurrency.map { total -> [String: Any] in
            var json: [String: Any] = [
                "currency": total.currency.rawValue,
                "realized": JSONOutput.money(total.realized),
                "positionChange": total.positionChange.map { JSONOutput.money($0) } ?? NSNull(),
                "total": total.total.map { JSONOutput.money($0) } ?? NSNull(),
                "incompletePositions": total.incompletePositions,
            ]
            if total.currency != reporting {
                let factor = report.fxRates[total.currency]?.rate
                json["reported"] = (factor == nil ? NSNull()
                    : total.total.map { JSONOutput.money($0 * factor!) } ?? NSNull())
            }
            return json
        }
        var data: [String: Any] = [
            "window": windowJSON,
            "scope": scopeJSON,
            "positions": positionJSON,
            "currencyTotals": currencyJSON,
            "activityCount": report.activityCount,
            "notes": report.notes,
        ]
        if let combined = report.combinedTotal {
            var json: [String: Any] = [
                "currency": reporting.rawValue,
                "value": JSONOutput.money(combined),
                // The FX actually applied, with the date behind each
                // rate (the as-of discipline, machine-readable).
                "at": JSONOutput.isoDay(report.window.end),
                "rates": report.fxRates.sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue)→\(reporting.rawValue) \(TextFormat.quantity($0.value.rate)) at \(JSONOutput.isoDay($0.value.asOf))" }
                    .joined(separator: "; "),
            ]
            if json["rates"] as? String == "" { json["rates"] = NSNull() }
            data["combined"] = json
        } else {
            data["combined"] = NSNull()
        }
        if let series {
            let pointsJSON = series.points.map { point -> [String: Any] in
                let totalsJSON = point.report.perCurrency.map { total -> [String: Any] in
                    [
                        "currency": total.currency.rawValue,
                        "realized": JSONOutput.money(total.realized),
                        "positionChange": total.positionChange.map { JSONOutput.money($0) } ?? NSNull(),
                        "total": total.total.map { JSONOutput.money($0) } ?? NSNull(),
                        "incompletePositions": total.incompletePositions,
                    ]
                }
                var json: [String: Any] = [
                    "label": point.label,
                    "start": JSONOutput.isoDay(point.start),
                    "end": JSONOutput.isoDay(point.end),
                    "currencyTotals": totalsJSON,
                ]
                // The period's converted total at ITS OWN end-date FX
                // (null when any part is unknown or unconvertible).
                if mixedView {
                    json["reportedTotal"] = point.report.combinedTotal.map { JSONOutput.money($0) }
                        ?? NSNull()
                }
                return json
            }
            data["series"] = [
                "granularity": series.granularity.label,
                "reconciles": series.reconciles,
                "collapsedEmpty": series.collapsedEmpty,
                "collapsedUnmeasurable": series.collapsedUnmeasurable,
                "points": pointsJSON,
            ]
        }
        print(JSONOutput.envelope(schema: "pnl/1", data: data))
        return
    }

    // MARK: Human rendering
    let scope = scopeNote(report, accounts: accounts, perAccount: perAccount,
                          symbolFilter: symbolFilter, currencyFilter: currencyFilter)
    let allNotes = notes + report.notes
    if let series {
        print(renderPnLSeries(report, series: series, forced: forceDaily,
                              scope: scope, notes: allNotes))
    } else {
        print(renderPnL(report, scopeNote: scope, notes: allNotes))
    }
}

/// Sum per-currency NATIVE amounts into the reporting currency at
/// the dated FX the engine actually used. nil when any part is
/// unknown or unconvertible — a half-sum is never displayed.
private func convertedSum(_ report: PnLReport, _ pick: (CurrencyPnL) -> Decimal?) -> Decimal? {
    var sum: Decimal = 0
    for total in report.perCurrency {
        guard let value = pick(total) else { return nil }
        if total.currency == report.reportingCurrency { sum += value; continue }
        guard let quote = report.fxRates[total.currency] else { return nil }
        sum += value * quote.rate
    }
    return sum
}

/// The time-series view: one row per period, every figure in the
/// REPORTING currency — each period converts at ITS OWN end-date FX
/// (a June slice never wears July's rate). The telescoping check runs
/// on the native slices, where summing is arithmetic; a converted-Σ
/// mismatch is FX timing, and the footer says exactly which it is.
private func renderPnLSeries(_ report: PnLReport, series: PnLSeries, forced: Bool,
                             scope: [String], notes: [String]) -> String {
    var lines: [String] = []
    let window = report.window
    let rangeText: String
    if window.fromLedgerStart {
        rangeText = "since first transaction (\(shortDate(window.start))) … \(shortDate(window.end))"
    } else {
        rangeText = "\(shortDate(window.start)) … \(shortDate(window.end))"
    }
    lines.append("Historical P&L over time — \(rangeText) (\(window.label))")
    let mixed = report.perCurrency.contains { $0.currency != report.reportingCurrency }
    lines.append("  Reporting: \(report.reportingCurrency.rawValue)"
        + (mixed ? " (each period converted at its own end-date FX)"
                 : " (as recorded — no conversion needed)"))
    lines.append(contentsOf: scope)
    lines.append("  series: \(series.granularity.label) periods\(forced ? " (forced)" : "")"
        + (series.collapsedEmpty > 0 ? " — \(series.collapsedEmpty) quiet period(s) collapsed" : ""))

    if series.isEmpty {
        lines.append("")
        if !report.hadActivity {
            lines.append("  No transactions in this window and no measurable price drift — nothing to report.")
        } else {
            lines.append("  \(report.activityCount) ledger line(s) in the window, none with P&L or measurable drift.")
        }
        if series.collapsedUnmeasurable > 0 {
            lines.append("  \(series.collapsedUnmeasurable) period(s) had NO usable price pair — unmeasurable,"
                + " not zero; nothing was invented for them")
        }
        if !notes.isEmpty {
            lines.append("")
            for note in notes { lines.append("  \(note)") }
        }
        return lines.joined(separator: "\n")
    }

    func aggCell(_ point: PnLSeriesPoint, _ pick: (CurrencyPnL) -> Decimal?) -> String {
        guard let value = convertedSum(point.report, pick) else { return "—" }
        return amountOnly(value)
    }

    lines.append("")
    lines.append("P&L per period (\(report.reportingCurrency.rawValue); — = not knowable, never zero):")
    let headers = ["Period", "Realized", "Position Δ", "Total"]
    var rows: [[String]] = []
    for point in series.points {
        let derived = point.report.rows.contains(where: \.usedDerivedHistory)
        let staleFX = point.report.fxRates.values.contains { $0.approx || $0.stalenessDays > 0 }
        var label = point.label + (derived ? "*" : "") + (staleFX ? "~" : "")
        if point.report.activityCount > 0 { label += " \u{00B7}" + " \(point.report.activityCount) tx" }
        rows.append([label,
                     aggCell(point) { $0.realized },
                     aggCell(point) { $0.positionChange },
                     aggCell(point) { $0.total }])
    }
    lines.append(contentsOf: Table.render(headers: headers, rows: rows, leftColumns: [0]).map { "  \($0)" })
    if rows.contains(where: { $0.joined().contains("*") || $0.joined().contains("~") }) {
        lines.append("  (* derived price history · ~ FX taken from an earlier or derived rate — see notes)")
    }

    // Telescoping check — the series must sum to the window total or
    // say exactly why it cannot. The identity is NATIVE arithmetic;
    // conversion is display, checked separately and labelled.
    if !series.reconciles {
        lines.append("  Σ periods ≠ window total — dashed periods are GAPS, not zeros;"
            + " totals above must not be summed")
    } else if !mixed {
        lines.append("  Σ periods = window total (exact — every period measurable, single currency)")
    } else {
        var seriesSum: Decimal? = 0
        for point in series.points {
            guard let part = convertedSum(point.report, { $0.total }) else { seriesSum = nil; break }
            seriesSum = (seriesSum ?? 0) + part
        }
        if seriesSum == nil {
            lines.append("  Σ \(report.reportingCurrency.rawValue) withheld — FX history does not cover every"
                + " period; nothing is summed at a guessed rate")
        } else if let seriesSum, let windowTotal = report.combinedTotal {
            var diff = seriesSum - windowTotal
            if diff < 0 { diff = -diff }
            if diff < Decimal(string: "0.005") ?? Decimal(0) {
                lines.append("  Σ periods = window total (exact — same FX throughout)")
            } else {
                lines.append("  Σ periods ≠ window total in \(report.reportingCurrency.rawValue) — the"
                    + " difference is FX TIMING (each period converts at its own close); the native"
                    + " slices still add exactly")
            }
        } else {
            lines.append("  Σ \(report.reportingCurrency.rawValue) withheld — the window total itself is"
                + " not combinable (see notes)")
        }
    }
    if series.collapsedUnmeasurable > 0 {
        lines.append("  (\(series.collapsedUnmeasurable) period(s) hidden with UNMEASURABLE drift"
            + " (no price pair) — unmeasurable is NOT zero)")
    }
    if !notes.isEmpty {
        lines.append("")
        for note in notes { lines.append("  \(note)") }
    }
    return lines.joined(separator: "\n")
}

/// Header/scope lines for the text view (what the flags selected).
private func scopeNote(_ report: PnLReport, accounts: [Account], perAccount: Bool,
                       symbolFilter: Set<String>?, currencyFilter: Set<Currency>?) -> [String] {
    var lines: [String] = []
    if perAccount {
        lines.append("  accounts: \(accounts.map(\.displayName).joined(separator: ", "))")
    } else if accounts.isEmpty {
        lines.append("  accounts: none in scope")
    }
    var filters: [String] = []
    if let symbols = symbolFilter, !symbols.isEmpty {
        filters.append("tickers \(symbols.sorted().joined(separator: ", "))")
    }
    if let currencies = currencyFilter, !currencies.isEmpty {
        filters.append("ccy \(currencies.map(\.rawValue).sorted().joined(separator: ", "))")
    }
    if !filters.isEmpty {
        lines.append("  filters: \(filters.joined(separator: " · "))")
    }
    return lines
}

/// The text shape: window header, then ONE table written in the
/// reporting currency (native amounts remain in `--json`), then the
/// combined total, then footnotes. Every displayed cell is either a
/// converted fact or a dash — the table never mixes currencies, and
/// a dash is a fact (no stored FX / no price pair), never zero.
private func renderPnL(_ report: PnLReport, scopeNote scope: [String], notes: [String]) -> String {
    var lines: [String] = []
    let window = report.window
    let rangeText: String
    if window.fromLedgerStart {
        rangeText = "since first transaction (\(shortDate(window.start))) … \(shortDate(window.end))"
    } else {
        rangeText = "\(shortDate(window.start)) … \(shortDate(window.end))"
    }
    lines.append("Historical P&L — \(rangeText) (\(window.label))")
    let mixed = report.perCurrency.contains { $0.currency != report.reportingCurrency }
    lines.append("  Reporting: \(report.reportingCurrency.rawValue)"
        + (mixed
           ? " (converted at the FX close on/before \(shortDate(window.end))"
               + (report.fxRates.isEmpty ? " — none found: cross-currency rows dash)" : ")")
           : " (as recorded — no conversion needed)"))
    lines.append(contentsOf: scope)

    let ccy = report.reportingCurrency.rawValue
    if !report.rows.isEmpty {
        // MARK: P&L in the reporting currency (single table)
        lines.append("")
        var rows: [[String]] = []
        if report.perAccount {
            lines.append("P&L (\(ccy), per account):")
            let headers = ["Account", "Symbol", "From", "Realized", "Position Δ", "Total"]
            rows = report.rows.map { row in
                [row.accountNames.joined(separator: ", "), row.symbol, row.currency.rawValue,
                 moneyCell(row.realized, native: row.currency, report: report, priceDerived: false),
                 moneyCell(row.positionChange, native: row.currency, report: report, priceDerived: row.usedDerivedHistory),
                 moneyCell(row.total, native: row.currency, report: report, priceDerived: row.usedDerivedHistory)]
            }
            lines.append(contentsOf: Table.render(headers: headers, rows: rows, leftColumns: [0, 1, 2]).map { "    \($0)" })
        } else if mixed {
            lines.append("P&L (\(ccy), portfolio — 'From' marks each row's recorded currency):")
            let headers = ["Symbol", "From", "Accounts", "Realized", "Position Δ", "Total"]
            rows = report.rows.map { row in
                [row.symbol, row.currency.rawValue, row.accountNames.joined(separator: ", "),
                 moneyCell(row.realized, native: row.currency, report: report, priceDerived: false),
                 moneyCell(row.positionChange, native: row.currency, report: report, priceDerived: row.usedDerivedHistory),
                 moneyCell(row.total, native: row.currency, report: report, priceDerived: row.usedDerivedHistory)]
            }
            lines.append(contentsOf: Table.render(headers: headers, rows: rows, leftColumns: [0, 1, 2]).map { "    \($0)" })
        } else {
            lines.append("P&L (\(ccy)):")
            let headers = ["Symbol", "Accounts", "Realized", "Position Δ", "Total"]
            rows = report.rows.map { row in
                [row.symbol, row.accountNames.joined(separator: ", "),
                 moneyCell(row.realized, native: row.currency, report: report, priceDerived: false),
                 moneyCell(row.positionChange, native: row.currency, report: report, priceDerived: row.usedDerivedHistory),
                 moneyCell(row.total, native: row.currency, report: report, priceDerived: row.usedDerivedHistory)]
            }
            lines.append(contentsOf: Table.render(headers: headers, rows: rows, leftColumns: [0, 1]).map { "    \($0)" })
        }
        if report.rows.contains(where: \.usedDerivedHistory) {
            lines.append("    * position change uses DERIVED proxy history — approximation, not a quote")
        }
        if report.fxRates.values.contains(where: { $0.approx || $0.stalenessDays > 0 }) {
            lines.append("    ~ FX taken from an EARLIER or DERIVED rate — dates and paths in the notes")
        }
    }

    // MARK: combined total in the reporting currency
    if !report.perCurrency.isEmpty {
        if !report.rows.isEmpty { lines.append("") }
        if let combined = report.combinedTotal {
            var totalLine = "  Total (\(ccy)): \(amountOnly(combined))"
            let rates = report.fxRates.sorted { $0.key.rawValue < $1.key.rawValue }.map { source, quote in
                "\(source.rawValue)→\(ccy) \(TextFormat.quantity(quote.rate)) (\(shortDate(quote.asOf)))"
            }
            if !rates.isEmpty { totalLine += "  [converted at \(rates.joined(separator: ", "))]" }
            lines.append(totalLine)
        } else {
            lines.append("  Total (\(ccy)): — (not combinable — see notes; native figures stay in --json)")
        }
    }

    if report.isEmpty {
        lines.append("")
        if !report.hadActivity {
            lines.append("  No transactions in this window and no measurable price drift — nothing to report.")
        } else {
            lines.append("  \(report.activityCount) ledger line(s) in the window, none with P&L or measurable drift.")
        }
    }

    if !notes.isEmpty {
        lines.append("")
        for note in notes {
            lines.append("  \(note)")
        }
    }
    return lines.joined(separator: "\n")
}

/// Reporting-currency money cell: converted at the dated FX the
/// engine actually used for `native`, or a dash when no such rate
/// exists (or the value itself is unknown). Markers: "*" derived
/// price history, "~" earlier/derived FX rate — labels, never
/// silent smoothing.
private func moneyCell(_ value: Decimal?, native: Currency, report: PnLReport,
                       priceDerived: Bool) -> String {
    guard let value else { return "—" }
    var mark = priceDerived ? "*" : ""
    if native == report.reportingCurrency {
        return amountOnly(value) + mark
    }
    guard let quote = report.fxRates[native] else { return "—" }
    if quote.approx || quote.stalenessDays > 0 { mark += "~" }
    return amountOnly(value * quote.rate) + mark
}