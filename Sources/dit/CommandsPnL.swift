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
/// tickers and currencies, reported per currency (native, exact) plus
/// a combined total in the reporting currency when every currency
/// converts honestly. Reads the market STORE only — it never fetches.
func pnlCommand(_ args: [String], global: Global) async throws {
    let options = try Options(args, valueOptions: ["horizon", "from", "to", "account", "tickers",
                                                    "ccy", "reporting-ccy"],
                              flagOptions: ["time-series"])
    if options["horizon"] != nil, options["from"] != nil || options["to"] != nil {
        throw ParseError("--horizon and --from/--to cannot be combined — pick one window form")
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

    // MARK: Market data — stored closes + rates only, never the network
    var marketData: MarketData?
    var notes: [String] = []
    do {
        let (marketStore, _) = try openMarketStore(global: global)
        marketData = try await marketStore.load()
    } catch {
        notes.append("market store unreadable: \(error) — no position-change data")
    }
    let cache = MarketDataCache()
    for rate in marketData?.latestRates ?? [] { cache.upsert(rate) }
    // FX pair SERIES ("USD/CAD,DATE,PRICE" imports and history fills)
    // are rate observations too — the same source the FX matrix reads.
    // Seed them so window totals can combine at stored rates without
    // anyone having run 'market latest'.
    for (key, pairSeries) in marketData?.series ?? [:] where key.contains("/") {
        let parts = key.split(separator: "/")
        guard parts.count == 2,
              let base = Currency(rawValue: String(parts[0])), base != .unknown,
              let quote = Currency(rawValue: String(parts[1])), quote != .unknown,
              let last = pairSeries.points.last else { continue }
        cache.upsert(ExchangeRate(base: base, quote: quote, rate: last.price, asOf: last.day))
    }
    let rate: FXRate? = { c1, c2 in cache.routedRate(from: c1, to: c2) }

    let report = PnLWindow.compute(portfolio: portfolio,
                                   window: window,
                                   accounts: accounts,
                                   perAccount: perAccount,
                                   symbols: symbolFilter,
                                   currencies: currencyFilter,
                                   reportingCurrency: reporting,
                                   market: marketData,
                                   rate: rate)

    // `--time-series`: slice the SAME window into periods, each one
    // computed by the same engine (adjacent baselines telescope).
    var series: PnLSeries?
    if options.flag("time-series") == true {
        let granularity = PnLWindow.autoGranularity(window: window)
        series = PnLWindow.computeSeries(portfolio: portfolio,
                                         window: window,
                                         granularity: granularity,
                                         accounts: accounts,
                                         perAccount: perAccount,
                                         symbols: symbolFilter,
                                         currencies: currencyFilter,
                                         reportingCurrency: reporting,
                                         market: marketData,
                                         rate: rate,
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
        let positionJSON = report.rows.map { row -> [String: Any] in
            [
                "symbol": row.symbol,
                "kind": row.isCashPnL ? "cash" : "position",
                "accounts": row.accountNames,
                "currency": row.currency.rawValue,
                "realized": JSONOutput.money(row.realized),
                "positionChange": row.positionChange.map { JSONOutput.money($0) } ?? NSNull(),
                "total": row.total.map { JSONOutput.money($0) } ?? NSNull(),
                "basis": row.positionChange == nil ? NSNull() : (row.usedDerivedHistory ? "derived" : "observed"),
            ]
        }
        let currencyJSON = report.perCurrency.map { total -> [String: Any] in
            [
                "currency": total.currency.rawValue,
                "realized": JSONOutput.money(total.realized),
                "positionChange": total.positionChange.map { JSONOutput.money($0) } ?? NSNull(),
                "total": total.total.map { JSONOutput.money($0) } ?? NSNull(),
                "incompletePositions": total.incompletePositions,
            ]
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
            data["combined"] = ["currency": reporting.rawValue,
                                "value": JSONOutput.money(combined)]
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
                return [
                    "label": point.label,
                    "start": JSONOutput.isoDay(point.start),
                    "end": JSONOutput.isoDay(point.end),
                    "currencyTotals": totalsJSON,
                ]
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
        print(renderPnLSeries(report, series: series, scope: scope, notes: allNotes))
    } else {
        print(renderPnL(report, scopeNote: scope, notes: allNotes))
    }
}

/// The time-series view: one row per period × currency, native and
/// exact where measurable, dashed where not — plus the telescoping
/// check (Σ periods vs window total) so a sliced report can never
/// quietly disagree with the whole.
private func renderPnLSeries(_ report: PnLReport, series: PnLSeries, scope: [String], notes: [String]) -> String {
    var lines: [String] = []
    let window = report.window
    let rangeText: String
    if window.fromLedgerStart {
        rangeText = "since first transaction (\(shortDate(window.start))) … \(shortDate(window.end))"
    } else {
        rangeText = "\(shortDate(window.start)) … \(shortDate(window.end))"
    }
    lines.append("Historical P&L over time — \(rangeText) (\(window.label))")
    lines.append("  P&L currency: \(report.reportingCurrency.rawValue)")
    lines.append(contentsOf: scope)
    lines.append("  series: \(series.granularity.label) periods"
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

    let showConverted = report.perCurrency.contains { $0.currency != report.reportingCurrency }
    lines.append("")
    lines.append("P&L per period (native; — = not measurable, never zero):")
    var headers = ["Period", "Ccy", "Realized", "Position Δ", "Total"]
    if showConverted { headers.append("Total (\(report.reportingCurrency.rawValue))") }
    var rows: [[String]] = []
    for point in series.points {
        let derived = point.report.rows.contains(where: \.usedDerivedHistory)
        for total in point.report.perCurrency {
            var label = point.label + (derived ? "*" : "")
            if point.report.activityCount > 0 { label += " \u{00B7}" + " \(point.report.activityCount) tx" }
            var row = [label,
                       total.currency.rawValue,
                       amountOnly(total.realized),
                       total.positionChange.map { amountOnly($0) } ?? "—",
                       total.total.map { amountOnly($0) } ?? "—"]
            if showConverted {
                var converted: String?
                if total.currency == report.reportingCurrency {
                    converted = total.total.map { amountOnly($0) }
                } else if let amount = total.total,
                          let factor = report.conversionUsed.first(where: { $0.from == total.currency })?.rate {
                    converted = amountOnly(amount * factor)
                }
                row.append(converted ?? "—")
            }
            rows.append(row)
        }
    }
    lines.append(contentsOf: Table.render(headers: headers, rows: rows, leftColumns: [0, 1]).map { "  \($0)" })

    // Telescoping check — the series must sum to the window total or
    // say exactly why it cannot.
    if series.reconciles {
        lines.append("  Σ periods = window total (exact — every period measurable)")
    } else {
        lines.append("  Σ periods ≠ window total — dashed periods are GAPS, not zeros;"
            + " totals above must not be summed")
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

/// The text shape: window header, per-currency totals (with a
/// converted column + combined line when currencies mix), then the
/// position breakdown, then footnotes.
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
    lines.append("  P&L currency: \(report.reportingCurrency.rawValue)")
    lines.append(contentsOf: scope)

    let showConverted = report.perCurrency.contains { $0.currency != report.reportingCurrency }

    // MARK: By currency (native, exact where computable)
    if !report.perCurrency.isEmpty {
        lines.append("")
        lines.append("By currency (native):")
        var headers = ["Ccy", "Realized", "Position Δ", "Total"]
        if showConverted { headers.append("Total (\(report.reportingCurrency.rawValue))") }
        var rows: [[String]] = []
        for total in report.perCurrency {
            var row = [total.currency.rawValue,
                       amountOnly(total.realized),
                       total.positionChange.map { amountOnly($0) } ?? "—",
                       total.total.map { amountOnly($0) } ?? "—"]
            if showConverted {
                var converted: String?
                if total.currency == report.reportingCurrency {
                    converted = total.total.map { amountOnly($0) }
                } else if let amount = total.total,
                          let factor = report.conversionUsed.first(where: { $0.from == total.currency })?.rate {
                    converted = amountOnly(amount * factor)
                }
                row.append(converted ?? "—")
            }
            rows.append(row)
        }
        lines.append(contentsOf: Table.render(headers: headers, rows: rows, leftColumns: [0]).map { "  \($0)" })
        if let combined = report.combinedTotal {
            var totalLine = "  Total (P&L currency \(report.reportingCurrency.rawValue)): \(amountOnly(combined))"
            if !report.conversionUsed.isEmpty {
                let rates = report.conversionUsed.map { "\($0.from.rawValue)→\($0.to.rawValue) \(TextFormat.quantity($0.rate))" }
                totalLine += " (combined at stored rates: \(rates.joined(separator: ", ")))"
            }
            lines.append(totalLine)
        } else {
            lines.append("  Total (P&L currency \(report.reportingCurrency.rawValue)): — "
                + "(not combinable — see notes; per-currency totals stay exact)")
        }
    }

    // MARK: Positions
    if !report.rows.isEmpty {
        lines.append("")
        lines.append(report.perAccount ? "Positions (per account):" : "Positions (portfolio, merged across accounts):")
        var headers: [String]
        var rows: [[String]] = []
        if report.perAccount {
            headers = ["Account", "Symbol", "Ccy", "Realized", "Position Δ", "Total"]
            rows = report.rows.map { row in
                [row.accountNames.joined(separator: ", "), row.symbol, row.currency.rawValue,
                 amountOnly(row.realized),
                 dashOrMark(row.positionChange, derived: row.usedDerivedHistory),
                 dashOrMark(row.total, derived: false)]
            }
            lines.append(contentsOf: Table.render(headers: headers, rows: rows, leftColumns: [0, 1, 2]).map { "    \($0)" })
        } else {
            headers = ["Symbol", "Ccy", "Accounts", "Realized", "Position Δ", "Total"]
            rows = report.rows.map { row in
                [row.symbol, row.currency.rawValue, row.accountNames.joined(separator: ", "),
                 amountOnly(row.realized),
                 dashOrMark(row.positionChange, derived: row.usedDerivedHistory),
                 dashOrMark(row.total, derived: false)]
            }
            lines.append(contentsOf: Table.render(headers: headers, rows: rows, leftColumns: [0, 1, 2]).map { "    \($0)" })
        }
        if report.rows.contains(where: \.usedDerivedHistory) {
            lines.append("    * position change uses DERIVED proxy history — approximation, not a quote")
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

/// Money cell; dashes stay dashes, derived marks get their `*`.
private func dashOrMark(_ value: Decimal?, derived: Bool) -> String {
    guard let value else { return "—" }
    return amountOnly(value) + (derived ? "*" : "")
}