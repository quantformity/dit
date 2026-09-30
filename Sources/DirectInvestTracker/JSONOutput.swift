import Foundation

// MARK: - Machine-readable (AI-agent) output
//
// `--json` renders the SAME derived numbers the tables show, as data.
// The contract (documented in docs/json.md):
//
// - One JSON document on stdout, success AND failure — `{"ok":true,
//   "schema":"…","data":…}` or `{"ok":false,"kind":"usage|runtime",
//   "error":"…"}`. Exit codes stay as in table mode (0/1/2), so a
//   caller can branch on the code or just parse.
// - Money, quantities and ratios are decimal STRINGS ("279900.60"),
//   never JSON numbers: parsers that round-trip doubles would break
//   the Decimal discipline. No grouping separators.
// - `null` means "no data" (never zero); zero is "0.00".
// - Dates: ISO-8601 UTC ("2026-09-28" day-precision,
//   "2026-09-29T02:51:00Z" timestamps) — never the storage format's
//   reference-seconds doubles.
// - Provenance is data: `"via": null` means an OBSERVED close; a
//   non-nil `via` names the model that produced the number. A caller
//   must never have to string-match a label to learn how a figure was
//   made.
// - Native-currency figures and display-currency conversions are
//   separate fields; `%` figures are native-currency ratios.

public enum JSONOutput {

    // MARK: Envelope

    /// `{"ok":true,"schema":"name/version","data":{…}}`
    public static func envelope(schema: String, data: [String: Any]) -> String {
        encodeOrFallback(["ok": true, "schema": schema, "data": data])
    }

    /// Failure envelope — printed on stdout with the usual exit code
    /// (usage → 2, runtime → 1) so the parse path is always the same.
    public static func errorEnvelope(kind: String, message: String) -> String {
        encodeOrFallback(["error": message, "kind": kind, "ok": false])
    }

    private static func encodeOrFallback(_ document: [String: Any]) -> String {
        // .sortedKeys keeps output byte-stable run to run; without it
        // dictionary order varies and every consumer diff goes noisy.
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(withJSONObject: document, options: options),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{\"error\":\"internal: unserializable JSON document\",\"kind\":\"runtime\",\"ok\":false}"
        }
        return text
    }

    // MARK: Formatting primitives

    /// Money at fixed 2 decimals, no grouping ("279900.60", "-6179.00").
    public static func money(_ value: Decimal) -> String { TextFormat.fixed(value, scale: 2) }
    /// Ratios/percents as fractions at fixed 4 decimals ("0.0153").
    public static func fraction(_ value: Decimal) -> String { TextFormat.fixed(value, scale: 4) }
    /// FX rates at fixed 6 decimals ("1.418700").
    public static func rate(_ value: Decimal) -> String { TextFormat.fixed(value, scale: 6) }
    /// Share quantities, trimmed, up to 4 decimals ("840", "96.7").
    public static func quantity(_ value: Decimal) -> String {
        TextFormat.plainQuantity(value)
    }

    /// UTC calendar day, "2026-09-28".
    public static func isoDay(_ date: Date) -> String {
        TextFormat.day(date)
    }

    /// UTC second-precision timestamp, "2026-09-29T02:51:00Z".
    public static func isoStamp(_ date: Date) -> String {
        TextFormat.isoStamp(date)
    }
}

// MARK: - summary/1

extension JSONOutput {

    /// The summary document. `cache`/`market` are the SAME observations
    /// the summary was valued from; the per-holding `quote`/`prevClose`
    /// objects re-derive from them with identical rules, so provenance
    /// always describes the numbers actually displayed.
    public static func summaryJSON(
        _ summary: PortfolioSummary,
        cache: MarketDataCache?,
        market: MarketData?,
        maxAge: TimeInterval,
        now: Date,
        storePath: String,
        warnings: [String],
        offline: Bool,
        degraded: Bool
    ) -> String {
        let display = summary.displayCurrency

        func moneyOrNull(_ value: Decimal?) -> Any {
            value.map { money($0) as Any } ?? NSNull()
        }

        func textOrNull(_ value: String?) -> Any {
            value.map { $0 as Any } ?? NSNull()
        }

        var totals: [String: Any] = [
            "cash": moneyOrNull(summary.cash),
            "positions": moneyOrNull(summary.positionValue),
            "gic": moneyOrNull(summary.gicValue),
            "totalValue": moneyOrNull(summary.totalValue),
            "unrealizedPnl": moneyOrNull(summary.unrealizedPnL),
            "realizedPnl": moneyOrNull(summary.realizedPnL),
            "dividends": moneyOrNull(summary.dividends),
            "dayChange": moneyOrNull(summary.dayChange),
        ]
        // Reconciliation helper: the exact per-currency sums the
        // combined figures were converted from (and the conversion
        // rates), so a caller can verify totals against components.
        var components: [String: Any] = [:]
        for currency in summary.valueByCurrency.keys.sorted() {
            components[currency.rawValue] = [
                "cash": money(summary.cashByCurrency[currency] ?? 0),
                "positions": money(summary.positionValueByCurrency[currency] ?? 0),
                "gic": money(summary.gicValueByCurrency[currency] ?? 0),
                "total": money(summary.valueByCurrency[currency] ?? 0),
                "dayChange": (summary.dayChangeByCurrency[currency]).map { money($0) as Any } ?? NSNull(),
            ]
        }
        totals["byCurrency"] = components

        var accounts: [[String: Any]] = []
        for balance in summary.accounts {
            let reporting = balance.account.reportingCurrency
            // Recover the positions component the same way the table
            // does; missing parts make the whole row uncombined (null).
            var positions: Any = NSNull()
            if let total = balance.totalValue, let cash = balance.cash, let gic = balance.gicValue {
                positions = money(total - cash - gic)
            }
            accounts.append([
                "name": balance.account.displayName,
                "id": balance.account.id.uuidString,
                "reportingCurrency": reporting.rawValue,
                "cash": moneyOrNull(balance.cash),
                "positions": positions,
                "gic": moneyOrNull(balance.gicValue),
                "total": moneyOrNull(balance.totalValue),
                "unrealizedPnl": moneyOrNull(balance.unrealizedPnL),
                "dayChange": moneyOrNull(balance.dayChange),
            ])
        }

        var holdings: [[String: Any]] = []
        for holding in summary.holdings {
            // Same guard as the table: a percentage over a zero or
            // negative cost basis (untracked shorts) is meaningless —
            // dividing by it would emit garbage instead of null.
            var pnlPct: Any = NSNull()
            if let pnl = holding.unrealizedPnL, holding.shares > 0, holding.costBasis > 0 {
                pnlPct = fraction(pnl / holding.costBasis)
            }
            var row: [String: Any] = [
                "symbol": holding.symbol,
                "name": holding.name ?? NSNull(),
                "ccy": holding.currency.rawValue,
                "shares": quantity(holding.shares),
                "avgCost": money(holding.averageCostPerShare),
                "value": money(holding.value),
                "valueDisplay": moneyOrNull(holding.valueInDisplayCurrency),
                "pnl": moneyOrNull(holding.unrealizedPnL),
                "pnlDisplay": moneyOrNull(holding.unrealizedPnLInDisplayCurrency),
                "pnlPct": pnlPct,
                "dayChange": moneyOrNull(holding.dayChange),
                "dayChangeDisplay": moneyOrNull(holding.dayChangeInDisplayCurrency),
                "dayPct": (holding.dayChangeFraction).map { fraction($0) as Any } ?? NSNull(),
                "accounts": holding.accountNames,
            ]
            // Provenance: the quote actually used and the baseline the
            // day change compares against — the same lookups summary()
            // performed, replayed here so labels cannot drift.
            if let cache,
               let quote = cache.freshQuote(for: holding.symbol, maxAge: maxAge, now: now),
               quote.currency == holding.currency {
                // "quote" present == the holding was quoted; its
                // "previousClose" is null when no daily baseline
                // existed. Both keys are ALWAYS present so provenance
                // lookup needs no branching on key existence.
                var previous: Any = NSNull()
                if let market,
                   let point = market.point(strictlyBefore: quote.asOf ?? now, for: holding.symbol) {
                    previous = [
                        "date": isoDay(point.day),
                        "price": money(point.price),
                        "via": point.via ?? NSNull(),  // nil == observed
                    ] as [String: Any]
                }
                row["quote"] = [
                    "asOf": textOrNull(quote.asOf.map { isoStamp($0) }),
                    "price": money(quote.price),
                    "previousClose": previous,
                    "source": textOrNull(quote.source),
                ]
            }
            holdings.append(row)
        }

        var data: [String: Any] = [
            "degraded": degraded,
            "displayCurrency": display.rawValue,
            "generatedAt": isoStamp(now),
            "offline": offline,
            "store": storePath,
            "warnings": warnings,
        ]
        data["accounts"] = accounts
        data["holdings"] = holdings
        data["totals"] = totals
        let shorts = summary.untrackedShorts.map { flag in
            [
                "account": flag.accountName,
                "ccy": flag.currency.rawValue,
                "shares": quantity(flag.shares),
                "symbol": flag.symbol,
            ] as [String: Any]
        }
        data["untrackedShorts"] = shorts
        return envelope(schema: "summary/1", data: data)
    }
}

// MARK: - accounts/1

extension JSONOutput {

    /// The account-listing document (`accounts`, `account list`).
    public static func accountsListJSON(_ accounts: [Account]) -> String {
        let rows: [[String: Any]] = accounts.map { account in
            var row: [String: Any] = [
                "currency": account.reportingCurrency.rawValue,
                "id": account.id.uuidString,
                "name": account.displayName,
                "taxable": account.taxable,
            ]
            row["institution"] = account.institution ?? NSNull()
            row["number"] = account.accountNumber ?? NSNull()
            if let closed = account.closedDate {
                row["status"] = "closed \(isoDay(closed))"
            } else {
                row["status"] = "open"
            }
            if let opened = account.openedDate { row["opened"] = isoDay(opened) }
            return row
        }
        return envelope(schema: "accounts/1", data: ["accounts": rows])
    }

    /// The account-detail document (`account show`), with the ledger
    /// included only when `--history` was requested. Balances are
    /// offline by construction: positions at cost, no FX applied —
    /// `costBasis` is therefore explicitly cost-basis, never a
    /// valuation, and carries its own currency.
    public static func accountJSON(
        account: Account,
        balances: AccountBalances,
        history: [(id: String, date: Date, kind: String, detail: String, currency: String)]?
    ) -> String {
        var data: [String: Any] = [
            "account": [
                "currency": account.reportingCurrency.rawValue,
                "id": account.id.uuidString,
                "name": account.displayName,
                "status": account.closedDate == nil ? "open" : "closed \(isoDay(account.closedDate!))",
                "taxable": account.taxable,
            ] as [String: Any],
            "balances": [
                "cashByCurrency": balances.cashByCurrency
                    .reduce(into: [String: String]()) { $0[$1.key.rawValue] = money($1.value) },
                "dayChangeByCurrency": balances.dayChangeByCurrency
                    .reduce(into: [String: String]()) { $0[$1.key.rawValue] = money($1.value) },
                "dividendsByCurrency": balances.dividendsByCurrency
                    .reduce(into: [String: String]()) { $0[$1.key.rawValue] = money($1.value) },
                "gicByCurrency": balances.gicValueByCurrency
                    .reduce(into: [String: String]()) { $0[$1.key.rawValue] = money($1.value) },
                "realizedPnlByCurrency": balances.realizedPnLByCurrency
                    .reduce(into: [String: String]()) { $0[$1.key.rawValue] = money($1.value) },
                "unrealizedPnlByCurrency": balances.unrealizedPnLByCurrency
                    .reduce(into: [String: String]()) { $0[$1.key.rawValue] = money($1.value) },
            ],
            "positions": balances.positions.map { position in
                [
                    "avgCost": money(position.averageCostPerShare),
                    "ccy": position.currency.rawValue,
                    "costBasis": money(position.costBasis),  // COST, not a valuation
                    "shares": quantity(position.shares),
                    "symbol": position.symbol,
                ] as [String: Any]
            },
        ]
        if let history {
            data["history"] = history.map { entry in
                [
                    "currency": entry.currency,
                    "date": isoDay(entry.date),
                    "detail": entry.detail,
                    "id": entry.id,
                    "kind": entry.kind,
                ] as [String: Any]
            }
        }
        let shorts = balances.untrackedShorts.map { flag in
            [
                "ccy": flag.currency.rawValue,
                "shares": quantity(flag.shares),
                "symbol": flag.symbol,
            ] as [String: Any]
        }
        data["untrackedShorts"] = shorts
        return envelope(schema: "account/1", data: data)
    }
}

// MARK: - quote/1

extension JSONOutput {

    /// Live quotes (`dit quote SYM…`). Missing symbols get `price:
    /// null` + basis "none", so "no quote" is a parsed value, never a
    /// guessed one. Key names match quote/1 in both modes (asOf, ccy,
    /// price, source).
    public static func liveQuotesJSON(rows: [(symbol: String, price: String?, ccy: String?, asOf: String?, source: String?)] = []) -> String {
        let entries: [[String: Any]] = rows.map { row in
            [
                "asOf": row.asOf ?? NSNull(),
                "basis": row.price == nil ? "none" as Any : "live" as Any,
                "ccy": row.ccy ?? NSNull(),
                "price": row.price ?? NSNull(),
                "source": row.source ?? NSNull(),
                "symbol": row.symbol,
            ] as [String: Any]
        }
        return envelope(schema: "quote/1", data: ["mode": "live", "quotes": entries])
    }

    /// Stored quotes (`dit quote --as-of DATE`). `via` keeps the
    /// storage contract and is ALWAYS present: null means the point was
    /// OBSERVED (fetched or imported); non-null names the model that
    /// produced it — consumers should not have to distinguish
    /// "absent key" from "observed".
    public static func storedQuotesJSON(
        asOf: String,
        storePath: String,
        rows: [(symbol: String, price: String?, ccy: String?, date: String?, lagDays: Int?, basis: String, via: String?)]
    ) -> String {
        let entries: [[String: Any]] = rows.map { row in
            var entry: [String: Any] = [
                "basis": row.basis,             // "observed" | "derived" | "none"
                "ccy": row.ccy ?? NSNull(),
                "date": row.date ?? NSNull(),
                "price": row.price ?? NSNull(),
                "symbol": row.symbol,
                "via": row.via ?? NSNull(),
            ]
            if let lag = row.lagDays { entry["lagDays"] = lag }
            return entry
        }
        return envelope(schema: "quote/1", data: [
            "asOf": asOf,
            "mode": "store",
            "quotes": entries,
            "store": storePath,
        ])
    }

    /// Range quotes (`dit quote SYM… --from DATE --to DATE`). One flat
    /// list of dated points; a symbol with NO point in the range gets
    /// a single `basis: "none"` marker instead of vanishing. `from`/
    /// `to` echo the request (null when open-ended); `count` is the
    /// number of points, not rows (missing markers excluded).
    public static func seriesQuotesJSON(
        from: String?,
        to: String?,
        storePath: String,
        rows: [(symbol: String, date: String?, price: String?, ccy: String?, basis: String, via: String?)],
        pointCount: Int
    ) -> String {
        let entries: [[String: Any]] = rows.map { row in
            [
                "basis": row.basis,
                "ccy": row.ccy ?? NSNull(),
                "date": row.date ?? NSNull(),
                "price": row.price ?? NSNull(),
                "symbol": row.symbol,
                "via": row.via ?? NSNull(),
            ] as [String: Any]
        }
        return envelope(schema: "quote/1", data: [
            "count": pointCount,
            "from": from ?? NSNull(),
            "mode": "series",
            "quotes": entries,
            "store": storePath,
            "to": to ?? NSNull(),
        ])
    }

    /// FX matrix (`dit quote USD/CAD/HKD/EUR`, single day). `rates`
    /// carries every directional pair; `basis` tells observed from
    /// reciprocal and triangulated ("derived", with `via`) from
    /// unknown ("none", rate null). `count` counts only rates that
    /// exist — "none" rows are markers, never zeros.
    public static func matrixJSON(token: String, currencies: [Currency],
                                  cells: [FXMatrix.Cell], storePath: String,
                                  storeMode: Bool, asOf: String?, now: Date) -> String {
        let entries: [[String: Any]] = cells.map { cell in
            var entry: [String: Any] = [
                "base": cell.base.rawValue,
                "basis": cell.basis,
                "quote": cell.quote.rawValue,
                "rate": cell.rate.map { rate($0) as Any } ?? NSNull(),
            ]
            if let date = cell.date { entry["date"] = date }
            if cell.basis == "derived" { entry["via"] = "triangulated via USD" }
            return entry
        }
        var data: [String: Any] = [
            "count": cells.filter { $0.rate != nil }.count,
            "currencies": currencies.map(\.rawValue),
            "mode": "matrix",
            "pairCount": cells.count,
            "query": token,
            "rates": entries,
            "store": storePath,
        ]
        data["asOf"] = storeMode ? (asOf ?? NSNull()) : isoStamp(now)
        return envelope(schema: "quote/1", data: data)
    }
}
