import DitCore
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

/// Derive the missing daily history of one ticker from another
/// (the .NE tracker case). Seeded from the registry + ledger, but
/// it WRITES the MARKET store — hence it lives under `market`
/// alongside history/import. Derived values carry provenance and
/// never replace real observations.
func marketBackfill(_ args: [String], global: Global) async throws {
    let options = try Options(args, valueOptions: ["from", "ratio"], flagOptions: ["dry-run"])
    guard options.positionals.count == 1 else {
        throw ParseError("usage: dit market backfill <target> --from <source> [--ratio R] [--dry-run]")
    }
    guard options["from"] != nil else {
        throw ParseError("backfill needs --from SOURCE — e.g. 'dit market backfill TSLA.NE --from TSLA'")
    }
    let from = options["from"]!
    var ratioOverride: Decimal?
    if let raw = options["ratio"] {
        guard let value = Decimal(string: raw), value > 0 else {
            throw ParseError("--ratio needs a positive number (got '\(raw)')")
        }
        ratioOverride = value
    }
    let (store, configuration) = try openStore(global: global)
    guard let portfolio = try await store.load() else {
        throw NoPortfolio(path: configuration.url.path)
    }
    let (marketStore, marketConfig) = try openMarketStore(global: global)
    let updater = MarketUpdater(provider: YahooQuoteProvider(), store: marketStore)
    let report: MarketUpdateReport
    do {
        report = try await updater.backfillHistory(
            portfolio: portfolio,
            targetSymbol: try requireSymbol(options.positionals[0]),
            sourceSymbol: try requireSymbol(from),
            ratioOverride: ratioOverride,
            allowNetwork: !global.offline,
            dryRun: options.has("dry-run"))
    } catch let error as DerivationError {
        throw LookupError(error.message)
    }
    print("Derived history — \(marketConfig.backend.rawValue) at \(marketConfig.url.path)")
    for line in report.lines { print("  \(line)") }
    for failure in report.failures { printErr("warning: \(failure)") }
}

/// Comma-separated tag list ("dividend, core") → normalized tags.
func parseTags(_ raw: String?) -> Set<Tag> {
    guard let raw else { return [] }
    return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { Tag($0) })
}

// MARK: - quote

/// `dit quote <SYMBOL|PAIR|CHAIN> …`: live quotes; `--as-of` reroutes
/// to stored single-day mode, `--from/--to` to range mode, a 3+ code
/// chain token to the matrix printer.
func quoteLookup(_ first: String, _ rest: [String], global: Global) async throws {
    let options = try Options(rest, valueOptions: ["as-of", "from", "to"])
    if options["as-of"] != nil, options["from"] != nil || options["to"] != nil {
        throw ParseError("--as-of (one point) and --from/--to (a range) cannot be combined — pick one view")
    }
    // A 3+ currency chain (USD/CAD/HKD/EUR) is the FX matrix view:
    // single-day only, no mixed requests, no range flags.
    if FXMatrix.looksLikeChain(first) {
        guard options.positionals.isEmpty else {
            throw ParseError("an FX matrix must be the only request — quote other symbols separately")
        }
        if options["from"] != nil || options["to"] != nil {
            throw ParseError("the FX matrix is single-day — use --as-of for one day, or 'dit quote USD/CAD --from … --to …' for a series")
        }
        guard let chain = FXMatrix.parseChain(first) else {
            throw ParseError("unknown currency in '\(first)' — the matrix needs known ISO codes (see 'dit help quote')")
        }
        try await quoteMatrix(chain, token: first, asOfRaw: options["as-of"], global: global)
        return
    }
    // --as-of (and --from/--to) read the MARKET STORE instead of
    // the network: they are the offline history paths, so the
    // offline guard below must not apply to them.
    if let asOfRaw = options["as-of"] {
        let asOf = try parseDate(asOfRaw)
        try await quoteAsOf([first] + options.positionals, asOf: asOf, global: global)
        return
    }
    if options["from"] != nil || options["to"] != nil {
        let fromRaw = options["from"]
        let toRaw = options["to"]
        let from = try fromRaw.map { try parseDate($0) }
        let to = try toRaw.map { try parseDate($0) }
        if let from, let to, to < from {
            throw ParseError("--to '\(toRaw!)' is before --from '\(fromRaw!)'")
        }
        try await quoteRange([first] + options.positionals, from: from, to: to, global: global)
        return
    }
    guard !global.offline else {
        throw ParseError("'dit quote' needs the network for live prices — drop --offline (offline mode exists to *avoid* fetching)")
    }
    let positionals = [first] + options.positionals
    let symbols = try positionals.map { try requireSymbol($0) }
    guard !symbols.isEmpty else {
        throw ParseError("usage: dit quote <SYMBOL> [SYMBOL ...]")
    }

    let provider = YahooQuoteProvider()
    // FX pairs (USD/CAD) are not chart symbols: they go through the
    // rate endpoint, prices read as quote-currency per 1 base.
    // Everything else goes to the quotes endpoint.
    var bySymbol: [String: MarketQuote] = [:]
    let equity = symbols.filter { ExchangeRate.pairRequest(for: $0) == nil }
    let pairs = symbols.filter { ExchangeRate.pairRequest(for: $0) != nil }
    do {
        if !equity.isEmpty {
            for quote in try await provider.quotes(for: equity) {
                bySymbol[quote.symbol] = quote
            }
        }
        for pair in pairs {
            guard let request = ExchangeRate.pairRequest(for: pair) else { continue }
            if let rate = try? await provider.rate(from: request.from, to: request.to) {
                bySymbol[pair] = MarketQuote(symbol: pair, currency: request.to,
                                             price: rate.rate, asOf: rate.asOf,
                                             source: rate.source)
            }
            // A failed rate lookup reads as a MISS in the table;
            // the all-missing guard still catches the loud case.
        }
    } catch {
        throw LookupError("live quote fetch failed: \(error)")
    }
    if global.json {
        guard !bySymbol.isEmpty else {
            throw LookupError("no live quotes available for: \(symbols.joined(separator: ", "))")
        }
        let jsonRows = symbols.map { symbol -> (String, String?, String?, String?, String?) in
            guard let quote = bySymbol[symbol] else { return (symbol, nil, nil, nil, nil) }
            // FX at 6 places, prices at 2 — rounding a rate to cents
            // would silently change what the pair is worth.
            let price = ExchangeRate.pairRequest(for: symbol) == nil
                ? JSONOutput.money(quote.price) : JSONOutput.rate(quote.price)
            return (quote.symbol, price,
                    quote.currency == .unknown ? nil : quote.currency.rawValue,
                    quote.asOf.map { JSONOutput.isoStamp($0) }, quote.source)
        }
        print(JSONOutput.liveQuotesJSON(rows: jsonRows))
        return
    }
    let rows = symbols.map { symbol -> [String] in
        guard let quote = bySymbol[symbol] else {
            return [symbol, "(none)", "", "", ""]
        }
        return [
            quote.symbol,
            trim(quote.price),
            quote.currency == .unknown ? "??" : quote.currency.rawValue,
            quote.asOf.map(quoteStamp) ?? "unknown",
            quote.source ?? "?",
        ]
    }
    print("Live quotes:")
    for line in Table.render(headers: ["Symbol", "Price", "Ccy", "AsOf", "Source"], rows: rows) {
        print("  \(line)")
    }
    let missing = symbols.filter { bySymbol[$0] == nil }
    if !missing.isEmpty {
        print("no quote found: \(missing.joined(separator: ", "))")
    }
    guard !bySymbol.isEmpty else {
        throw LookupError("no live quotes available for: \(symbols.joined(separator: ", "))")
    }
}

/// `dit quote --as-of DATE`: the stored answer, never a fetch.
/// Each row shows WHERE the price came from: `observed` (a close
/// fetched from the provider or imported from a measured source),
/// `backfilled — derived via …` (a model value: underlying × FX ÷
/// calibrated ratio), or nothing. A date with no quote on it
/// reports the nearest earlier one and how far back it had to go.
/// Single-day mode: prices/rates as of one historical day, read from
/// the market store (never the network unless refill needs it).
func quoteAsOf(_ rawSymbols: [String], asOf: Date, global: Global) async throws {
    let symbols = try rawSymbols.map { try requireSymbol($0) }
    let (marketStore, configuration) = try openMarketStore(global: global)
    let data = try await marketStore.load()
    if global.json {
        // Machine mode: the JSON document is the ONLY thing on
        // stdout — no prose header before it.
        let missing = symbols.filter { data.point(onOrBefore: asOf, for: $0) == nil }
        guard missing.count < symbols.count else {
            throw LookupError("no stored quotes for: \(symbols.joined(separator: ", ")) — the market store is empty for these; run 'dit market history'")
        }
        let jsonRows = symbols.map { symbol -> (String, String?, String?, String?, Int?, String, String?) in
            guard let point = data.point(onOrBefore: asOf, for: symbol) else {
                return (symbol, nil, nil, nil, nil, "none", nil)
            }
            let lag = Int(asOf.timeIntervalSince(point.day) / 86_400)
            let ccy = data.series[symbol]?.currency ?? .unknown
            return (symbol, JSONOutput.money(point.price),
                    ccy == .unknown ? nil : ccy.rawValue,
                    JSONOutput.isoDay(point.day), lag,
                    point.via == nil ? "observed" : "derived", point.via)
        }
        print(JSONOutput.storedQuotesJSON(asOf: JSONOutput.isoDay(asOf),
                                          storePath: configuration.url.path, rows: jsonRows))
        return
    }
    print("Historical quotes — \(configuration.backend.rawValue) at \(configuration.url.path)")
    print("  as of \(shortDate(asOf)) — read from the market store, nothing fetched")
    var rows: [[String]] = []
    var missing: [String] = []
    for symbol in symbols {
        guard let point = data.point(onOrBefore: asOf, for: symbol) else {
            rows.append([symbol, "(none)", "", "", "no stored quote"])
            missing.append(symbol)
            continue
        }
        let lag = Int(asOf.timeIntervalSince(point.day) / 86_400)
        let onText = lag == 0 ? shortDate(point.day) : "\(shortDate(point.day)) (\(lag)d earlier)"
        let ccy = data.series[symbol]?.currency ?? .unknown
        let provenance = point.via == nil ? "observed" : "backfilled — \(point.via!)"
        rows.append([symbol, trim(point.price), ccy == .unknown ? "?" : ccy.rawValue, onText, provenance])
    }
    for line in Table.render(headers: ["Symbol", "Price", "Ccy", "On", "Provenance"],
                             rows: rows, leftColumns: [0, 3, 4]) {
        print("  \(line)")
    }
    if !missing.isEmpty {
        print("no stored quote for: \(missing.joined(separator: ", ")) — 'dit market history' fills this store (derive proxy history with 'dit market backfill', fill with 'dit market import')")
    }
    guard missing.count < symbols.count else {
        throw LookupError("no stored quotes for: \(symbols.joined(separator: ", ")) — the market store is empty for these; run 'dit market history'")
    }
}

/// `dit quote --from/--to DATE`: stored time series, never a
/// fetch (works offline). One section per symbol, oldest point
/// first, with the same provenance words as --as-of. Missing
/// symbols are listed, not hidden; only a run where NOTHING is
/// stored in range exits non-zero.
/// Range mode: day-by-day closes between `--from`/`--to` printed as
/// bar charts (ChartRenderer does the drawing; no money math here).
func quoteRange(_ rawSymbols: [String], from: Date?, to: Date?, global: Global) async throws {
    let symbols = try rawSymbols.map { try requireSymbol($0) }
    let (marketStore, configuration) = try openMarketStore(global: global)
    let data = try await marketStore.load()
    let toDay = to ?? DailyPrice.utcDay(Date.now)  // open-ended = up to now
    let fromText = from.map { shortDate($0) } ?? "the beginning"
    let toText = (to == nil ? "today (" : "") + shortDate(toDay) + (to == nil ? ")" : "")
    let rangeText = "\(fromText) … \(toText)"
    if global.json {
        var rows: [(symbol: String, date: String?, price: String?, ccy: String?, basis: String, via: String?)] = []
        var pointCount = 0
        for symbol in symbols {
            let points = data.points(from: from, to: toDay, for: symbol)
            let ccy = data.series[symbol]?.currency ?? .unknown
            if points.isEmpty {
                rows.append((symbol, nil, nil, nil, "none", nil))
                continue
            }
            pointCount += points.count
            for point in points {
                rows.append((symbol, JSONOutput.isoDay(point.day), JSONOutput.money(point.price),
                             ccy == .unknown ? nil : ccy.rawValue,
                             point.via == nil ? "observed" : "derived", point.via))
            }
        }
        guard pointCount > 0 else {
            throw LookupError("no stored closes for: \(symbols.joined(separator: ", ")) in \(rangeText) — 'dit market history' fills this store")
        }
        print(JSONOutput.seriesQuotesJSON(from: from.map { JSONOutput.isoDay($0) },
                                          to: to.map { JSONOutput.isoDay($0) },
                                          storePath: configuration.url.path,
                                          rows: rows, pointCount: pointCount))
        return
    }
    print("Historical closes — \(configuration.backend.rawValue) at \(configuration.url.path)")
    print("  \(rangeText) — read from the market store, nothing fetched")
    var missing: [String] = []
    for symbol in symbols {
        let points = data.points(from: from, to: toDay, for: symbol)
        guard !points.isEmpty else {
            missing.append(symbol)
            continue
        }
        let ccy = data.series[symbol]?.currency ?? .unknown
        print("\n  \(symbol) (\(ccy == .unknown ? "?" : ccy.rawValue)) — \(points.count) close\(points.count == 1 ? "" : "s")")
        let rows = points.map { point in
            [shortDate(point.day), trim(point.price),
             point.via == nil ? "observed" : "backfilled — \(point.via!)"]
        }
        for line in Table.render(headers: ["Date", "Price", "Provenance"],
                                 rows: rows, leftColumns: [0, 2]) {
            print("    \(line)")
        }
    }
    if !missing.isEmpty {
        print("\nno stored closes for: \(missing.joined(separator: ", ")) — 'dit market history' fills this store (derive proxy history with 'dit market backfill', fill with 'dit market import')")
    }
    guard missing.count < symbols.count else {
        throw LookupError("no stored closes for: \(symbols.joined(separator: ", ")) in \(rangeText) — the market store is empty for these; run 'dit market history'")
    }
}

/// `dit quote USD/CAD/HKD/EUR` (3+ currencies): every pairwise
/// rate among them for ONE day — live (default) or from the
/// market store with --as-of/--offline. Ranges (--from/--to) are
/// refused by the caller: a matrix is single-day by design.
/// Anything not a direct observation is built from USD legs and
/// marked triangulated — never presented as a quote.
/// Currency-chain cross table ("USD/CAD/HKD"): pairwise rates, with
/// triangulated cells marked (never presented as observations).
func quoteMatrix(_ currencies: [Currency], token: String,
                                asOfRaw: String?, global: Global) async throws {
    let asOf: Date?
    if let asOfRaw { asOf = try parseDate(asOfRaw) } else { asOf = nil }
    let hub = Currency.conversionHub

    // Which rate sources the matrix may probe: every chain pair
    // (either orientation) plus each currency's USD legs —
    // triangulation needs them even when USD is not in the chain.
    var pairsToTry: [(Currency, Currency)] = []
    func addPair(_ a: Currency, _ b: Currency) {
        guard a != b,
              !pairsToTry.contains(where: { Set([$0.0, $0.1]) == Set([a, b]) })
        else { return }
        pairsToTry.append((a, b))
    }
    for a in currencies { for b in currencies { addPair(a, b) } }
    for currency in currencies { addPair(hub, currency) }

    // Gather rates BEFORE building, so FXMatrix stays a synchronous
    // pure function over "what was observed where".
    var direct: [String: (rate: Decimal, date: String?)] = [:]
    func key(_ a: Currency, _ b: Currency) -> String { "\(a.rawValue)/\(b.rawValue)" }
    let storeMode = global.offline || asOf != nil
    var storePath = "yahoo finance"

    if storeMode {
        // Single day from the market store, never a fetch.
        let (marketStore, configuration) = try openMarketStore(global: global)
        storePath = configuration.url.path
        let data = try await marketStore.load()
        let day = asOf ?? Date.now
        for (a, b) in pairsToTry {
            if let point = data.point(onOrBefore: day, for: key(a, b)) {
                direct[key(a, b)] = (point.price, shortDate(point.day))
            }
        }
    } else {
        let provider = YahooQuoteProvider()
        for (a, b) in pairsToTry {
            // Try the pair; if the provider has only the reverse
            // quote, take it — the builder inverts it explicitly.
            if let rate = try? await provider.rate(from: a, to: b) {
                direct[key(a, b)] = (rate.rate, nil)
            } else if let reverse = try? await provider.rate(from: b, to: a) {
                direct[key(b, a)] = (reverse.rate, nil)
            }
        }
    }

    let cells = FXMatrix.cells(currencies: currencies) { a, b in direct[key(a, b)] }
    guard cells.contains(where: { $0.rate != nil }) else {
        throw LookupError(storeMode
            ? "no stored FX rates for \(token) in the market store — 'dit market latest' fetches them live"
            : "no FX rates available for \(token) — check the network, or seed the store with 'dit market import'")
    }

    if global.json {
        print(JSONOutput.matrixJSON(token: token, currencies: currencies, cells: cells,
                                    storePath: storePath, storeMode: storeMode,
                                    asOf: asOf.map { shortDate($0) }, now: Date.now))
        return
    }

    print("FX matrix — \(token)")
    print("  every rate is QUOTE currency (column) per 1 unit of the row BASE")
    if storeMode {
        print("  \(asOf.map { shortDate($0) } ?? "latest stored rates") — read from the market store, nothing fetched")
    } else {
        print("  live from Yahoo Finance at \(quoteStamp(Date.now))")
    }
    let byPair = Dictionary(uniqueKeysWithValues: cells.map { ("\($0.base.rawValue)\u{0}\($0.quote.rawValue)", $0) })
    var rows: [[String]] = []
    for base in currencies {
        var row = [base.rawValue]
        for quote in currencies {
            if base == quote { row.append("·"); continue }
            guard let cell = byPair["\(base.rawValue)\u{0}\(quote.rawValue)"], let rate = cell.rate else {
                row.append("—")
                continue
            }
            row.append(JSONOutput.rate(rate) + (cell.basis == "derived" ? "*" : ""))
        }
        rows.append(row)
    }
    print()
    for line in Table.render(headers: ["Base \\ to"] + currencies.map(\.rawValue),
                             rows: rows, leftColumns: [0]) {
        print("  \(line)")
    }
    print()
    print("  · = same currency · — = no rate available · * = triangulated via USD")
    print("    (triangulated rates are approximations from two USD legs, not quotes)")
}

// MARK: - market commands (the separate market-data store)

/// The market store + its path, resolved like every other store:
/// `--market-store` > `DIT_MARKET_URL` > beside the portfolio store.
func openMarketStore(global: Global) throws
    -> (MarketStore, DataStoreFactory.Configuration)
{
    var environment = ProcessInfo.processInfo.environment
    if let backend = global.backend { environment[DataStoreFactory.backendKey] = backend }
    if let store = global.store { environment[DataStoreFactory.storeURLKey] = store }
    if let market = global.marketStore { environment[DataStoreFactory.marketURLKey] = market }
    let factory = DataStoreFactory(environment: environment)
    let configuration = try factory.marketConfiguration()
    return (try factory.makeMarketStore(), configuration)
}

/// Shared guard for the two fetching commands: no portfolio loaded,
/// no work. A portfolio without positions is still a quiet success.
func marketPortfolio(global: Global) async throws -> Portfolio? {
    let (store, configuration) = try openStore(global: global)
    guard let portfolio = try await store.load() else {
        print("No portfolio found (store: \(configuration.backend.rawValue) at \(configuration.url.path)).")
        print("Nothing to update — add accounts and transactions first.")
        return nil
    }
    return portfolio
}

/// `market latest`: refresh the one latest snapshot per held symbol
/// and needed FX pair (refuses `--offline` — there is nothing to refresh).
func marketLatest(global: Global) async throws {
    guard !global.offline else {
        throw ParseError("'dit market latest' refreshes prices from the provider — "
            + "--offline refuses the network (offline summaries use cost basis)")
    }
    guard let portfolio = try await marketPortfolio(global: global) else { return }
    let (marketStore, configuration) = try openMarketStore(global: global)
    let updater = MarketUpdater(provider: YahooQuoteProvider(), store: marketStore)
    let report = try await updater.updateLatest(portfolio: portfolio,
                                                displayCurrency: global.display)
    print("Latest market data — \(configuration.backend.rawValue) at \(configuration.url.path)")
    if report.latestRows.isEmpty {
        for line in report.lines { print("  \(line)") }
    } else {
        // One aligned table: symbols and FX pairs share the ruler,
        // so prices line up decimal-point to decimal-point.
        let rows = report.latestRows
            .sorted { $0.name < $1.name }
            .map { [$0.name, $0.price, $0.ccy, $0.asOf] }
        for line in Table.render(headers: ["Symbol/Pair", "Price", "Ccy", "As of (local)"],
                                 rows: rows, leftColumns: [0, 3]) {
            print("  \(line)")
        }
    }
    for failure in report.failures { printErr("warning: \(failure)") }
    print("next: 'dit market history' fills daily closes for every held day")
}

/// `market history`: fill daily closes for the days each symbol was
/// actually held (incremental by default; `--all` re-verifies, `--rebuild`
/// erases first).
func marketHistory(_ args: [String], global: Global) async throws {
    guard !global.offline else {
        throw ParseError("'dit market history' fetches daily closes — "
            + "--offline refuses the network")
    }
    let options = try Options(args, valueOptions: ["from", "to"], flagOptions: ["all", "rebuild"])
    guard options.positionals.isEmpty else {
        throw ParseError("unexpected argument '\(options.positionals[0])' — "
            + "'dit market history' takes only --all / --rebuild / --from / --to (see 'dit help market')")
    }
    if options.has("all"), options.has("rebuild") {
        throw ParseError("--all and --rebuild conflict — --all fills gaps but KEEPS stored closes, "
            + "--rebuild erases the daily history first (pick one)")
    }
    if options["from"] != nil || options["to"] != nil {
        // Parsed for forward compatibility; refuse rather than
        // silently ignore a window nobody implemented.
        throw ParseError("--from/--to are not wired yet — history currently spans "
            + "each symbol's full holding window; use 'dit market history --all' to re-verify it "
            + "or --rebuild to erase and refetch")
    }
    guard let portfolio = try await marketPortfolio(global: global) else { return }
    let (marketStore, configuration) = try openMarketStore(global: global)
    let updater = MarketUpdater(provider: YahooQuoteProvider(), store: marketStore)
    let mode: HistoryFillMode = options.has("rebuild") ? .rebuild
        : options.has("all") ? .refill : .incremental
    let report = try await updater.updateHistory(portfolio: portfolio,
                                                 displayCurrency: global.display,
                                                 mode: mode)
    print("Daily history — \(configuration.backend.rawValue) at \(configuration.url.path)")
    for line in report.lines { print("  \(line)") }
    if report.pointsStored > 0 {
        // Changes first, one compact line — then the coverage view.
        let changed = report.historyRows.filter { $0.added > 0 }
            .map { "\($0.name) +\($0.added)" }
        print("  +\(report.pointsStored) new points stored (\(changed.joined(separator: ", ")))")
    }
    let historyRows = report.historyRows.map { [$0.name, $0.first, $0.last, "\($0.count)"] }
    if !historyRows.isEmpty {
        // Coverage per series, post-update: earliest day, latest
        // day, stored points. A quiet run repeats the same facts —
        // facts are allowed on screen, walls of "skipped" are not.
        for line in Table.render(headers: ["Ticker", "Earliest", "Latest", "Quotes"],
                                 rows: historyRows, leftColumns: [0, 1, 2]) {
            print("  \(line)")
        }
    } else if report.lines.isEmpty {
        print("  no series to maintain (nothing has ever been held)")
    }
    for failure in report.failures { printErr("warning: \(failure)") }
    // Every fetch failing with nothing stored means the network
    // answer taught us nothing — say so loudly (exit 1).
    if report.pointsStored == 0, report.seriesFetched > 0,
       report.failures.count >= report.seriesFetched {
        throw LookupError("every history fetch failed — check the network and retry")
    }
}

/// `market show`: print what the market store currently holds (latest
/// section + per-series coverage), with `--symbol`/`--days` filters.
func marketShow(_ args: [String], global: Global) async throws {
    let options = try Options(args, valueOptions: ["symbol", "days"])
    guard options.positionals.isEmpty else {
        throw ParseError("unexpected argument '\(options.positionals[0])' — "
            + "filter both tables with --symbol (see 'dit help market')")
    }
    let (marketStore, configuration) = try openMarketStore(global: global)
    let data = try await marketStore.load()
    let symbolFilter = options["symbol"]?.trimmingCharacters(in: .whitespaces).uppercased()
    let tailDays: Int?
    if let raw = options["days"] {
        guard let value = Int(raw), value > 0 else {
            throw ParseError("--days needs a positive number (got '\(raw)')")
        }
        tailDays = value
    } else {
        tailDays = nil
    }

    var shownSeries = data.series.sorted { $0.key < $1.key }
    if let symbolFilter, !symbolFilter.isEmpty {
        shownSeries = shownSeries.filter { $0.key == symbolFilter }
    }

    print("Market data — \(configuration.backend.rawValue) at \(configuration.url.path)")
    if data.latestQuotes.isEmpty, data.latestRates.isEmpty, data.series.isEmpty {
        print("  empty — run 'dit market latest' (current prices) and "
            + "'dit market history' (daily closes) to fill it")
        return
    }
    print("  updated: \(quoteStamp(data.updatedAt))")

    // --symbol filters BOTH sections — the whole point of asking
    // about one ticker is to see only that ticker.
    var latestQuotes = data.latestQuotes
    var latestRates = data.latestRates
    if let symbolFilter, !symbolFilter.isEmpty {
        latestQuotes = latestQuotes.filter { $0.symbol == symbolFilter }
        latestRates = latestRates.filter { "\($0.base.rawValue)/\($0.quote.rawValue)" == symbolFilter }
        if latestQuotes.isEmpty, latestRates.isEmpty, shownSeries.isEmpty {
            print("  nothing stored for '\(symbolFilter)' — 'dit market latest' / 'dit market history' fill this store")
            return
        }
    }

    if !latestQuotes.isEmpty || !latestRates.isEmpty {
        print("\nLatest (one per symbol, overwritten by 'dit market latest'):")
        var rows = latestQuotes
            .sorted { $0.symbol < $1.symbol }
            .map { quote in
                [quote.symbol, trim(quote.price),
                 quote.currency == .unknown ? "?" : quote.currency.rawValue,
                 quote.asOf.map { MarketUpdater.stampShort($0) } ?? "unknown"]
            }
        rows += latestRates
            .sorted { "\($0.base)" < "\($1.base)" }
            .map { rate in
                ["\(rate.base.rawValue)/\(rate.quote.rawValue)", trim(rate.rate),
                 rate.quote.rawValue,
                 rate.asOf.map { MarketUpdater.stampShort($0) } ?? "unknown"]
            }
        for line in Table.render(headers: ["Symbol", "Price", "Ccy", "As of (local)"], rows: rows) {
            print("  \(line)")
        }
    }

    if !shownSeries.isEmpty {
        print("\nHistory (\(shownSeries.count) series):")
        let rows = shownSeries.map { key, series -> [String] in
            var source = "observed"
            let derived = series.points.count { $0.via != nil }
            if derived > 0, let label = series.points.first(where: { $0.via != nil })?.via {
                source = "\(label) — \(derived)/\(series.points.count) pts"
            }
            return [
                key,
                series.currency == .unknown ? "?" : series.currency.rawValue,
                "\(series.points.count)",
                series.points.first.map { shortDate($0.day) } ?? "—",
                series.points.last.map { shortDate($0.day) } ?? "—",
                source,
            ]
        }
        for line in Table.render(headers: ["Symbol", "Ccy", "Points", "First", "Last", "Source"],
                                 rows: rows, leftColumns: [0, 1, 3, 4, 5]) {
            print("  \(line)")
        }
        if let symbolFilter, let tailDays, let series = data.series[symbolFilter] {
            print("\n  last \(min(tailDays, series.points.count)) close(s) for \(symbolFilter):")
            for point in series.points.suffix(tailDays) {
                print("    \(shortDate(point.day))  \(trim(point.price))\(point.via != nil ? "   (derived)" : "")")
            }
        }
    }
}

/// `market coverage`: audit what the market store KNOWS for what the
/// ledger HOLDS (positions open at the audit date + the FX chains a
/// single-currency report would need). Purely offline and read-only:
/// it never fetches, never writes, and never mixes currencies — the
/// point is to find the holes BEFORE a P&L report dashes on them.
func marketCoverage(_ args: [String], global: Global) async throws {
    let options = try Options(args, valueOptions: ["from", "to", "account", "tickers", "reporting-ccy"],
                              flagOptions: ["strict"])
    guard options.positionals.isEmpty else {
        throw ParseError("unexpected argument '\(options.positionals[0])' — "
            + "'dit market coverage' filters with --account/--tickers/--from/--to (see 'dit help market')")
    }
    let fromRaw = options["from"]
    let toRaw = options["to"]
    let from = try fromRaw.map { try parseDate($0) }
    let to = try toRaw.map { try parseDate($0) }
    if let from, let to, to < from {
        throw ParseError("--to '\(toRaw!)' is before --from '\(fromRaw!)'")
    }

    let (store, storeConfig) = try openStore(global: global)
    guard let portfolio = try await store.load() else {
        if global.json {
            print(JSONOutput.envelope(schema: "coverage/1", data: [
                "empty": true,
                "note": "no portfolio found — add accounts and transactions first",
                "store": storeConfig.url.path,
            ]))
            return
        }
        print("No portfolio found (store: \(storeConfig.backend.rawValue) at \(storeConfig.url.path)).")
        print("Nothing to check — add accounts and transactions first.")
        return
    }

    // MARK: Scope — accounts (default: every account, aggregated) and
    // a ticker DISPLAY filter for the price table (FX stays scope-wide:
    // a conversion is not tied to one ticker).
    var accounts = portfolio.accounts
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
    }
    var symbolFilter: Set<String>?
    if let raw = options["tickers"] {
        let list = splitCSV(raw).map { $0.uppercased() }
        guard !list.isEmpty else { throw ParseError("--tickers needs at least one symbol") }
        symbolFilter = Set(list)
    }

    // MARK: Market store — read-only, never fetched. An unreadable
    // store is a NOTE, not a crash: every row then honestly reports
    // the absence (dashes are answers too).
    var marketData: MarketData?
    var marketPath = "no market store"
    var notes: [String] = []
    do {
        let (marketStore, configuration) = try openMarketStore(global: global)
        marketPath = "\(configuration.backend.rawValue) at \(configuration.url.path)"
        marketData = try await marketStore.load()
    } catch {
        notes.append("market store unreadable (\(error)) — every row below reports NO DATA")
    }

    // Default audit date: today; default gap window: the whole ledger
    // history up to it (a hole anywhere in the span someone reports
    // over matters — --from/--to narrow both).
    let reporting = try options["reporting-ccy"].map { try parseCurrency($0, option: "--reporting-ccy") }
        ?? global.display
    let report = MarketCoverage.report(portfolio: portfolio,
                                       accounts: accounts,
                                       asOf: to ?? Date.now,
                                       windowStart: from,
                                       reportingCurrency: reporting,
                                       market: marketData)
    var shownSymbols = report.symbols
    var filterNote: String?
    if let filter = symbolFilter {
        shownSymbols = report.symbols.filter { filter.contains($0.symbol) }
        let unmatched = filter.subtracting(shownSymbols.map(\.symbol))
        if !unmatched.isEmpty {
            filterNote = "nothing held at the audit date matches --tickers "
                + "\(unmatched.sorted().joined(separator: ", ")) (filters narrow, they never guess)"
        }
    }
    let visible = CoverageReport(asOf: report.asOf, windowStart: report.windowStart,
                                 seriesGranularity: report.seriesGranularity,
                                 symbols: shownSymbols, fx: report.fx)

    if global.json {
        var data: [String: Any] = [
            "auditDate": JSONOutput.isoDay(visible.asOf),
            "complete": visible.complete,
            "fx": visible.fx.map { chain -> [String: Any] in
                var row: [String: Any] = [
                    "chain": chain.chainLabel ?? "none",
                    "from": chain.from.rawValue,
                    "to": chain.to.rawValue,
                    "usableNow": chain.usableNow,
                ]
                row["boundariesMissing"] = chain.boundariesMissing
                row["boundariesTotal"] = chain.boundariesTotal
                if let last = chain.lastAsOf {
                    row["lastClose"] = JSONOutput.isoDay(last)
                    row["staleDays"] = chain.staleDays ?? 0
                }
                if chain.chainLabel?.hasPrefix("derived") == true { row["approx"] = true }
                return row
            },
            "notes": notes,
            "prices": shownSymbols.map { row -> [String: Any] in
                var entry: [String: Any] = [
                    "accounts": row.accounts,
                    "currency": row.currency.rawValue,
                    "status": coverageStatus(row),
                    "symbol": row.symbol,
                ]
                entry["derived"] = row.derived
                entry["points"] = row.pointsInWindow
                if let last = row.lastClose {
                    entry["lastClose"] = JSONOutput.isoDay(last)
                    entry["staleDays"] = row.staleDays ?? 0
                }
                if let gap = row.longestGap {
                    entry["longestGap"] = [
                        "days": gap.days,
                        "from": JSONOutput.isoDay(gap.from),
                        "to": JSONOutput.isoDay(gap.to),
                    ]
                }
                return entry
            },
            "reporting": reporting.rawValue,
            "scope": accounts.count == portfolio.accounts.count && accounts.count > 1
                ? "all accounts" : accounts.map(\.displayName),
            "seriesSlicing": visible.seriesGranularity.label,
            "window": [
                "from": JSONOutput.isoDay(visible.windowStart),
                "to": JSONOutput.isoDay(visible.asOf),
            ],
        ]
        if visible.isEmpty { data["empty"] = true }
        if let filterNote { data["filterNote"] = filterNote }
        print(JSONOutput.envelope(schema: "coverage/1", data: data))
        if options.has("strict"), !visible.complete {
            // ONE document on stdout — strict flips only the exit
            // code; "complete":false already carries the finding.
            fflush(stdout)
            exit(1)
        }
        return
    }

    print("Market coverage — \(marketPath)")
    print("  audit date \(shortDate(visible.asOf)) · window "
        + "\(shortDate(visible.windowStart)) … \(shortDate(visible.asOf)) · "
        + "reporting into \(reporting.rawValue)")
    if accounts.count == portfolio.accounts.count {
        print("  scope: all \(accounts.count) account(s)")
    } else {
        print("  scope: \(accounts.map(\.displayName).joined(separator: ", "))")
    }
    for note in notes { print("  note: \(note)") }
    if let filterNote { print("  \(filterNote)") }

    if visible.isEmpty {
        print("\n  Nothing held at the audit date (no open positions, no foreign cash) — "
            + "nothing to cover.")
        return
    }

    if !shownSymbols.isEmpty {
        print("\nPrices (per held symbol and its recorded currency):")
        let rows = shownSymbols.map { row -> [String] in
            [row.symbol, row.currency.rawValue, row.accounts.joined(separator: ", "),
             coverageCell(row)]
        }
        for line in Table.render(headers: ["Symbol", "Ccy", "Accounts", "Coverage"],
                                 rows: rows, leftColumns: [0, 1, 2, 3]) {
            print("  \(line)")
        }
    }

    if !visible.fx.isEmpty {
        print("\nFX into \(reporting.rawValue) (what combining foreign totals needs):")
        let rows = visible.fx.map { chain -> [String] in
            ["\(chain.from.rawValue)→\(chain.to.rawValue)", coverageCell(chain)]
        }
        for line in Table.render(headers: ["Chain", "Coverage"], rows: rows, leftColumns: [0, 1]) {
            print("  \(line)")
        }
    }

    // Legends only say what the current table actually shows.
    var legend: [String] = []
    if shownSymbols.contains(where: { $0.derived }) || visible.fx.contains(where: { $0.chainLabel?.hasPrefix("derived") == true }) {
        legend.append("* derived price proxy · ~ derived FX chain (inverted/cross) — labelled approximations, NOT missing data")
    }
    if shownSymbols.contains(where: { $0.longestGap != nil }) {
        legend.append("GAPS = holes of ≥ 10 missing days; shorter runs are weekend/holiday dust (weekday-sampled data) and stay unlisted")
    }
    if shownSymbols.contains(where: { ($0.staleDays ?? 0) > 7 }) || visible.fx.contains(where: { !$0.usableNow && $0.chainLabel != nil }) {
        legend.append("STALE = last data older than 7 days — FX conversion REFUSES it (dashes); stale prices are still used, labelled")
    }
    if shownSymbols.contains(where: { !$0.measurable }) || visible.fx.contains(where: { $0.chainLabel == nil }) {
        legend.append("NO DATA / WRONG CCY / NO CHAIN → 'dit market history' fetches what is missing, 'dit market import FILE' seeds measured data")
    }
    if !legend.isEmpty { print(); for line in legend { print("  \(line)") } }

    if options.has("strict"), !visible.complete {
        throw LookupError("coverage gaps listed above — 'dit market history' fetches, 'dit market import' seeds")
    }
}

/// Machine-stable status word for one price row (keys sort, statuses
/// do not lie): the FIRST failing fact wins, the rest print as data.
func coverageStatus(_ row: SymbolCoverage) -> String {
    if !row.seriesFound { return "no-data" }
    if !row.usableSource { return "wrong-currency" }
    if row.lastClose == nil { return "no-data" }
    if (row.staleDays ?? 0) > 7 { return "stale" }
    if row.longestGap != nil { return "gaps" }
    return "ok"
}

/// One-line price coverage text: status word first (greppable), then
/// the raw facts — points, dates, staleness, the longest hole.
func coverageCell(_ row: SymbolCoverage) -> String {
    var parts: [String] = []
    switch coverageStatus(row) {
    case "no-data":
        if !row.seriesFound {
            parts.append("NO DATA — no daily series for \(row.symbol) — P&L dashes, summary values at cost")
        } else if let span = row.seriesRange {
            parts.append("NO USABLE CLOSES in window — series runs \(shortDate(span.first))…\(shortDate(span.last))")
        } else {
            parts.append("NO DATA before the audit date")
        }
    case "wrong-currency":
        parts.append("WRONG CCY — series is \(row.seriesCurrency?.rawValue ?? "?") and a "
            + "\(row.currency.rawValue) position needs \(row.currency.rawValue) — NEVER USED")
    case "stale":
        parts.append("STALE — last close \(shortDate(row.lastClose!)) (\(row.staleDays!)d before audit)")
        if let gap = row.longestGap {
            // STALE first, but the inside hole is a SEPARATE fact —
            // audit wants both, and the status word must not swallow
            // data.
            parts.append("+ GAPS \(gap.days)d (\(shortDate(gap.from))…\(shortDate(gap.to)))")
        }
        parts.append("\(row.pointsInWindow) closes in window")
    case "gaps":
        parts.append("GAPS — longest hole \(row.longestGap!.days)d (\(shortDate(row.longestGap!.from))…\(shortDate(row.longestGap!.to)))")
        parts.append("\(row.pointsInWindow) closes in window")
    default:
        parts.append("ok — \(row.pointsInWindow) closes")
    }
    if let range = row.windowRange, coverageStatus(row) == "ok" {
        parts.append("\(shortDate(range.first))…\(shortDate(range.last))")
    }
    if row.derived { parts.append("*derived") }
    return parts.joined(separator: ", ")
}

/// One-line FX coverage text: chain provenance + the boundary facts.
func coverageCell(_ chain: FXChainCoverage) -> String {
    guard let label = chain.chainLabel else {
        return "NO CHAIN — no stored path \(chain.from.rawValue)→\(chain.to.rawValue); "
            + "import a \(chain.from.rawValue)/\(chain.to.rawValue) series or both USD legs (separate totals)"
    }
    // Derived chains (inverted twin / triangulated cross) wear the
    // marker wherever they print — same `~` the P&L header uses.
    let derived = label.hasPrefix("derived") || label.hasPrefix("inverted")
    if !chain.usableNow {
        var text = (derived ? "~" : "") + label + " STALE — chain last answered "
            + "\(shortDate(chain.lastAsOf!)) (\(chain.staleDays!)d before audit); conversions dash"
        if chain.boundariesMissing > 0 {
            text += " — missing at \(chain.boundariesMissing)/\(chain.boundariesTotal) period ends"
        }
        return text
    }
    var text = "ok — \(derived ? "~" : "")\(label), last close \(shortDate(chain.lastAsOf!)) (\(chain.staleDays!)d)"
    if chain.boundariesMissing == 0, chain.boundariesTotal > 0 {
        text += "; usable at all \(chain.boundariesTotal) period ends"
    }
    if chain.boundariesMissing > 0 {
        text += " — but missing at \(chain.boundariesMissing)/\(chain.boundariesTotal) period ends "
            + "(e.g. \(chain.missingExample.map(shortDate) ?? "?"))"
    }
    return text
}

/// Seed the market store from a CSV of REAL observations
/// (`SYMBOL,YYYY-MM-DD,PRICE`). Imported observations always win
/// over derived values on the same day — the import path is how
/// measured data (an old app's cache, a vendor file) retires the
/// model's guesses.
/// `market import <file> [--dry-run]`: bulk-load daily closes from
/// text (`SYMBOL,DATE,PRICE[,BASIS]` lines); malformed lines are
/// reported, not repaired.
func marketImport(_ args: [String], global: Global) async throws {
    let options = try Options(args, flagOptions: ["dry-run"])
    guard options.positionals.count == 1 else {
        throw ParseError("usage: dit market import <FILE> [--dry-run] — CSV lines 'SYMBOL,YYYY-MM-DD,PRICE' (# comments and blank lines skipped)")
    }
    let path = options.positionals[0]
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw StoreError("cannot read '\(path)' as UTF-8 text")
    }
    let parsed = MarketData.parseSeriesCSV(text)
    guard !parsed.entries.isEmpty else {
        throw LookupError("no usable 'SYMBOL,YYYY-MM-DD,PRICE' lines in '\(path)'")
    }
    let (marketStore, configuration) = try openMarketStore(global: global)
    var data = try await marketStore.load()
    print("Market import — \(configuration.backend.rawValue) at \(configuration.url.path)")
    for problem in parsed.problems.prefix(8) { printErr("warning: \(problem)") }
    if parsed.problems.count > 8 {
        printErr("warning: ...and \(parsed.problems.count - 8) more unparsable line(s)")
    }
    var bySymbol: [String: [DailyPrice]] = [:]
    for entry in parsed.entries {
        bySymbol[entry.symbol, default: []].append(DailyPrice(day: entry.day, price: entry.price))
    }
    var totalStored = 0
    for (symbol, points) in bySymbol.sorted(by: { $0.key < $1.key }) {
        var currency = data.series[symbol]?.currency ?? .unknown
        if currency == .unknown,
           let slash = symbol.firstIndex(of: "/"),
           Currency(rawValue: String(symbol[..<slash])) != nil, // both sides
           let quote = Currency(rawValue: String(symbol[symbol.index(after: slash)...])) { // must be codes
            currency = quote // "USD/CAD" prices CAD per 1 USD
        }
        let stored = data.mergeSeries(symbol: symbol, currency: currency, points: points)
        totalStored += stored
        print("  \(symbol): \(stored) point(s) stored from \(points.count) line(s)")
    }
    if options.has("dry-run") {
        print("  dry run — nothing written")
        return
    }
    data.updatedAt = .now
    try await marketStore.save(data)
    print("  \(totalStored) point(s) added; imported observations replace derived values on the same day")
}
