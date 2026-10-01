import Foundation

// MARK: - Stored market data

/// One end-of-day price observation, keyed by UTC calendar day.
public struct DailyPrice: Codable, Hashable, Sendable {
    /// The trading day, normalized to UTC midnight. Normalization is
    /// what lets "already have 2026-05-01" work across providers whose
    /// timestamps carry exchange-local times.
    public var day: Date
    /// Close (last) price for the day, in the series currency.
    public var price: Decimal
    /// Provenance: `nil` means this is a REAL observation (fetched or
    /// imported). A non-nil label (e.g. `"derived via TSLA ÷ 16.209"`)
    /// marks a model-generated value — derived data is never silently
    /// equal to observed data, and real observations always win on the
    /// same day.
    public var via: String?

    /// Normalizes `day` to its UTC calendar day (see ``day``) so any
    /// exchange-local timestamp collapses onto the same storage key.
    public init(day: Date, price: Decimal, via: String? = nil) {
        self.day = DailyPrice.utcDay(day)
        self.price = price
        self.via = via
    }

    /// The UTC-midnight calendar day containing `date`.
    public static func utcDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: date)
    }
}

/// The stored daily history for one asset (an equity symbol or an FX
/// pair). Points are kept sorted ascending by day with no duplicate
/// days, so a merge is cheap and the "keep only what is missing" rule
/// is a set membership test.
public struct PriceSeries: Codable, Hashable, Sendable {
    /// Equity symbol ("RBLX") or FX pair ("USD/CAD").
    public var symbol: String
    /// The currency the prices are denominated in (for FX pairs: the
    /// quote currency — USD/CAD prices CAD per 1 USD).
    public var currency: Currency
    /// Ascending, day-unique.
    public var points: [DailyPrice]
    /// The date through which a successful fetch has already verified
    /// this series ("everything up to here was asked for; what exists,
    /// exists"). This is what makes repeated updates cheap: holidays
    /// and no-data days sit behind the watermark instead of being
    /// re-requested forever, while genuinely new days do not.
    public var coveredThrough: Date?

    /// Sorts + de-duplicates `points` through ``normalized(_:)`` so a
    /// hand-built series cannot violate the day-unique invariant.
    public init(symbol: String, currency: Currency, points: [DailyPrice] = [],
                coveredThrough: Date? = nil) {
        self.symbol = symbol
        self.currency = currency
        self.points = PriceSeries.normalized(points)
        self.coveredThrough = coveredThrough
    }

    /// Lenient decoding with defaults, so a stored series from before
    /// the watermark existed (or with a missing field) still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.symbol = try container.decode(String.self, forKey: .symbol)
        self.currency = (try container.decodeIfPresent(Currency.self, forKey: .currency)) ?? .unknown
        self.points = (try container.decodeIfPresent([DailyPrice].self, forKey: .points)) ?? []
        self.coveredThrough = try? container.decodeIfPresent(Date.self, forKey: .coveredThrough)
    }

    /// Sort + de-duplicate by day; the *last* observation for a day wins
    /// (provider order, matching `MarketDataCache`'s "newer wins" rule).
    public static func normalized(_ points: [DailyPrice]) -> [DailyPrice] {
        var byDay: [Date: DailyPrice] = [:]
        for point in points { byDay[DailyPrice.utcDay(point.day)] = point }
        return byDay.sorted { $0.key < $1.key }.map { $0.value }
    }

    /// Adds only the days the series does not already hold; stored
    /// OBSERVED days keep their existing value (incremental update
    /// rule), but a newly arrived real observation replaces a
    /// previously *derived* value for the same day — models yield to
    /// measurement. Returns the merged series and how many days were
    /// added or had their derived value superseded.
    public func merging(_ new: [DailyPrice]) -> (series: PriceSeries, added: Int) {
        var current: [Date: DailyPrice] = [:]
        for point in points { current[point.day] = point }
        var additions: [DailyPrice] = []
        for point in new {
            let day = DailyPrice.utcDay(point.day)
            let incoming = DailyPrice(day: day, price: point.price, via: point.via)
            if let existing = current[day] {
                // Real replaces derived; real never replaces real, and
                // a derived value never replaces anything automatically.
                if point.via == nil && existing.via != nil { additions.append(incoming) }
            } else {
                additions.append(incoming)
            }
        }
        guard !additions.isEmpty else { return (self, 0) }
        var merged = PriceSeries(symbol: symbol, currency: currency, points: points + additions)
        merged.coveredThrough = coveredThrough
        return (merged, additions.count)
    }

    /// The newest stored day, if any.
    public var latestDay: Date? { points.last?.day }
}

/// The whole market-data document — the market store's unit of
/// persistence, mirroring how `Portfolio` is the portfolio store's.
///
/// Two independent sections:
/// - `latestQuotes`/`latestRates`: at most one snapshot per symbol/pair,
///   overwritten by `dit market latest` ("keep only the latest");
/// - `series`: the daily history filled by `dit market history`.
public struct MarketData: Codable, Hashable, Sendable {
    /// When the market store was last written (`nil` = never). Display
    /// metadata, not a data point.
    public var updatedAt: Date?
    /// The "latest snapshot" section: at most one entry per symbol.
    public var latestQuotes: [MarketQuote]
    /// The "latest snapshot" section for FX: at most one entry per pair.
    public var latestRates: [ExchangeRate]
    /// Keyed by symbol/pair (same key as inside `MarketQuote`/series).
    public var series: [String: PriceSeries]

    /// Empty-by-default memberwise init: an unseeded store decodes to
    /// this, and tests can build documents literally.
    public init(
        updatedAt: Date? = nil,
        latestQuotes: [MarketQuote] = [],
        latestRates: [ExchangeRate] = [],
        series: [String: PriceSeries] = [:]
    ) {
        self.updatedAt = updatedAt
        self.latestQuotes = latestQuotes
        self.latestRates = latestRates
        self.series = series
    }

    /// Lenient decoding: every section may be missing (decode as empty),
    /// and one broken entry must not poison the whole document — entries
    /// that fail to decode are dropped, not fatal. Stored data is a
    /// refetchable cache; degrading beats refusing to start.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.latestQuotes = (try? container.decodeIfPresent([MarketQuote].self, forKey: .latestQuotes)) ?? []
        self.latestRates = (try? container.decodeIfPresent([ExchangeRate].self, forKey: .latestRates)) ?? []
        self.series = (try? container.decodeIfPresent([String: PriceSeries].self, forKey: .series)) ?? [:]
    }

    // MARK: Section helpers

    /// Replaces (or inserts) the one "latest" snapshot for the quote's
    /// symbol — the latest section holds at most one entry per symbol.
    public mutating func replaceLatest(_ quote: MarketQuote) {
        latestQuotes.removeAll { $0.symbol == quote.symbol }
        latestQuotes.append(quote)
    }

    /// Replaces (or inserts) the one "latest" snapshot for a currency pair.
    public mutating func replaceLatest(_ rate: ExchangeRate) {
        latestRates.removeAll { $0.base == rate.base && $0.quote == rate.quote }
        latestRates.append(rate)
    }

    /// Mends the per-day series for `symbol`, adding only days not
    /// already stored, and advances the coverage watermark to `through`
    /// when given (a successful fetch verifies everything up to there,
    /// even if the provider had no new data). Returns days added.
    @discardableResult
    public mutating func mergeSeries(symbol: String, currency: Currency,
                                     points: [DailyPrice], through: Date? = nil) -> Int {
        let existing = series[symbol] ?? PriceSeries(symbol: symbol, currency: currency)
        var (merged, added) = existing.merging(points)
        if let through, merged.coveredThrough == nil || through > merged.coveredThrough! {
            merged.coveredThrough = through
        }
        series[symbol] = merged
        return added
    }

    /// Removes every daily series, keeping the latest snapshots.
    /// This is what `dit market history --rebuild` does before refetching.
    public mutating func eraseSeries() {
        series.removeAll()
    }

    /// The lookup path `--as-of` valuation uses: the newest stored
    /// observation on or before `day`, with provenance — a caller can
    /// tell an observed close from a backfilled one.
    public func point(onOrBefore day: Date, for symbol: String) -> DailyPrice? {
        guard let series = series[symbol], !series.points.isEmpty else { return nil }
        let day = DailyPrice.utcDay(day)
        return series.points.last { $0.day <= day }
    }

    /// The newest stored observation strictly before `day`, with
    /// provenance — the "previous available close" behind the one-day
    /// P&L. The valued day is never its own baseline, even when today's
    /// close is already stored (and even when the quote is a weekend or
    /// holiday echo of an older close: its own day is used as the
    /// boundary).
    public func point(strictlyBefore day: Date, for symbol: String) -> DailyPrice? {
        guard let series = series[symbol], !series.points.isEmpty else { return nil }
        let day = DailyPrice.utcDay(day)
        return series.points.last { $0.day < day }
    }

    /// The newest stored price on or before `day` (provenance elided).
    public func price(onOrBefore day: Date, for symbol: String) -> Decimal? {
        point(onOrBefore: day, for: symbol)?.price
    }

    /// Every stored point with a date inside the INCLUSIVE range
    /// (nil bound = open-ended), sorted by day. Points may arrive
    /// unordered (fetch, import, backfill mix), so this sorts —
    /// unlike the single-point lookups above. Empty means "nothing
    /// stored in this range", which callers must report, not hide.
    public func points(from: Date?, to: Date?, for symbol: String) -> [DailyPrice] {
        guard let series = series[symbol], !series.points.isEmpty else { return [] }
        let lo = from.map(DailyPrice.utcDay)
        let hi = to.map(DailyPrice.utcDay)
        return series.points
            .filter { point in
                (lo.map { point.day >= $0 } ?? true) && (hi.map { point.day <= $0 } ?? true)
            }
            .sorted { $0.day < $1.day }
    }
}

// MARK: - Store

/// Backend-agnostic access to the persisted market data.
///
/// The middle layer above `DataStore`, exactly like `PortfolioStore`
/// above the portfolio document — one document key, load/save/erase,
/// backend invisible. The market document lives in its OWN backend
/// (its own directory or database file, separate from the portfolio
/// document) so price history can grow, be wiped, or be restored
/// without ever touching the ledger.
public struct MarketStore: Sendable {
    /// The storage key under which the market document is kept inside
    /// its backend.
    public static let documentKey = "market"

    private let store: any DataStore

    /// - Parameter store: the backend for the MARKET document — pass a
    ///   backend pointed at the market location, never the portfolio one.
    public init(store: some DataStore) {
        self.store = store
    }

    /// The stored market data. A missing or corrupt document decodes to
    /// an empty one: the market store is a cache, and an unreadable
    /// cache is refilled, not fatal.
    public func load() async throws -> MarketData {
        guard let payload = try await store.load(key: Self.documentKey) else { return MarketData() }
        if let decoded = try? JSONDecoder().decode(MarketData.self, from: payload) {
            return decoded
        }
        return MarketData()
    }

    /// Replace the whole market document atomically.
    public func save(_ data: MarketData) async throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(data)
        } catch {
            throw DataStoreError.encodeFailed(key: Self.documentKey, message: error.localizedDescription)
        }
        try await store.save(payload, key: Self.documentKey)
    }

    /// Remove the whole market document (diagnostics; `--rebuild` history
    /// refresh goes through `MarketData.eraseSeries` + `save` instead,
    /// so the latest snapshots survive).
    public func delete() async throws {
        try await store.delete(key: Self.documentKey)
    }

    /// All keys in the market backend (passthrough for `dit store path`).
    public func keys() async throws -> [String] {
        try await store.keys()
    }
}
