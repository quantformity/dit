import DirectInvestTracker
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

/// Seed the market store from a CSV of REAL observations
/// (`SYMBOL,YYYY-MM-DD,PRICE`). Imported observations always win
/// over derived values on the same day — the import path is how
/// measured data (an old app's cache, a vendor file) retires the
/// model's guesses.
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
