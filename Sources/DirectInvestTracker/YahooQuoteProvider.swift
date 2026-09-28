import Foundation

// MARK: - Errors

/// Failure modes of ``YahooQuoteProvider``.
///
/// All cases carry a `message`/`status` rather than an `underlying: Error`
/// so the enum stays trivially `Sendable` (same rule as `DataStoreError`).
public enum YahooQuoteError: Error, Sendable, Equatable {
    /// Yahoo answered with a non-200 status (429 when throttled, 999 when
    /// it rejects the request shape, 500 on its own outages).
    case http(status: Int)

    /// The endpoint answered 200 but carries no data for the symbol
    /// (Yahoo's `NOT_FOUND` for delisted or misspelled tickers).
    case noData(symbol: String, message: String)

    /// The response body was not in the expected chart shape, or the
    /// price could not be interpreted.
    case decoding(message: String)

    /// A transport-level failure (DNS, timeout, connection refused).
    case network(message: String)

    /// A batch returned zero quotes and at least one symbol failed at the
    /// transport level — the empty result is not trustworthy.
    case allSymbolsFailed(transportFailures: Int, apiFailures: Int)

    /// A symbol or currency that Yahoo cannot be asked about
    /// (e.g. `.unknown` in an FX request).
    case invalidSymbol(String)
}

// MARK: - Provider

/// A ``QuoteProvider`` backed by Yahoo Finance's public chart endpoint
/// (`query1.finance.yahoo.com/v8/finance/chart/{symbol}`) — the one that
/// still works without cookies/crumb, unlike `/v7/finance/quote`.
///
/// Yahoo rejects the default Swift user agent with 429, so every request
/// carries a browser-like `User-Agent`. No authentication, no API key.
public struct YahooQuoteProvider: QuoteProvider {

    /// Low-level HTTP fetch: `(body, HTTP response)` or a transport error.
    ///
    /// Injected for tests; the default performs the real network call.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let fetch: Fetch
    private let userAgent: String

    /// Uses the real `URLSession.shared` transport and the browser user
    /// agent Yahoo expects.
    public init() {
        self.fetch = YahooQuoteProvider.defaultFetch
        self.userAgent = YahooQuoteProvider.defaultUserAgent
    }

    /// - Parameters:
    ///   - fetch: transport stub for tests (or a custom session). The
    ///     default performs the real network call (a `dataTask`, so HTTP
    ///     error *statuses* are observable instead of being flattened
    ///     into a generic `URLError`).
    ///   - userAgent: `User-Agent` header. Defaults to a browser string;
    ///     Yahoo throttles non-browser agents.
    public init(fetch: @escaping Fetch, userAgent: String = YahooQuoteProvider.defaultUserAgent) {
        self.fetch = fetch
        self.userAgent = userAgent
    }

    /// The `User-Agent` sent with every request — a browser string, since
    /// Yahoo throttles non-browser agents with 429.
    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private static let defaultFetch: Fetch = { request in
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: YahooQuoteError.network(message: error.localizedDescription))
                } else if let data, let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data, http))
                } else {
                    continuation.resume(throwing: YahooQuoteError.network(message: "Malformed HTTP response"))
                }
            }
            task.resume()
        }
    }

    // MARK: QuoteProvider

    /// Downloads the last price for one symbol.
    public func quote(for rawSymbol: String) async throws -> MarketQuote {
        guard let symbol = Self.normalizedSymbol(rawSymbol) else {
            throw YahooQuoteError.invalidSymbol(rawSymbol)
        }
        let meta = try await fetchMeta(symbol: symbol)
        return MarketQuote(
            symbol: symbol,
            currency: meta.currency,
            price: meta.price,
            asOf: meta.asOf,
            source: "yahoo"
        )
    }

    /// Downloads the last prices for several symbols concurrently.
    ///
    /// Returns one `MarketQuote` per symbol that *has* a quote; symbols
    /// that come back as Yahoo `NOT_FOUND` (delisted, misspelled) are
    /// skipped. Throws ``YahooQuoteError/allSymbolsFailed`` only when
    /// nothing came back and at least one failure was a transport error —
    /// i.e. the empty result reflects the connection, not the symbols.
    public func quotes(for symbols: [String]) async throws -> [MarketQuote] {
        let unique = Array(Set(symbols)).sorted()
        guard !unique.isEmpty else { return [] }

        let results = await withTaskGroup(of: (String, Result<MarketQuote, YahooQuoteError>).self) { group in
            for symbol in unique {
                group.addTask {
                    do { return (symbol, .success(try await self.quote(for: symbol))) }
                    catch let error as YahooQuoteError { return (symbol, .failure(error)) }
                    catch { return (symbol, .failure(.network(message: error.localizedDescription))) }
                }
            }
            var collected: [(String, Result<MarketQuote, YahooQuoteError>)] = []
            for await item in group { collected.append(item) }
            return collected
        }

        var quotes: [MarketQuote] = []
        var transportFailures = 0
        var apiFailures = 0
        for (_, result) in results {
            switch result {
            case let .success(quote):
                quotes.append(quote)
            case let .failure(error):
                switch error {
                case .network: transportFailures += 1
                default: apiFailures += 1
                }
            }
        }
        guard !quotes.isEmpty || transportFailures == 0 else {
            throw YahooQuoteError.allSymbolsFailed(transportFailures: transportFailures, apiFailures: apiFailures)
        }
        return quotes
    }

    /// Downloads the current rate between two currencies via Yahoo's FX
    /// chart (e.g. `"USDCAD=X"`, which prices CAD per 1 USD).
    public func rate(from: Currency, to: Currency) async throws -> ExchangeRate {
        guard from != .unknown, to != .unknown else {
            throw YahooQuoteError.invalidSymbol(from.isoCode + to.isoCode)
        }
        guard from != to else {
            return ExchangeRate(base: from, quote: to, rate: 1, asOf: nil, source: "yahoo")
        }
        guard let ticker = from.quoteTicker(against: to) else {
            throw YahooQuoteError.invalidSymbol(from.isoCode + to.isoCode)
        }
        let meta = try await fetchMeta(symbol: ticker)
        return ExchangeRate(base: from, quote: to, rate: meta.price, asOf: meta.asOf, source: "yahoo")
    }

    // MARK: Cache conveniences

    /// Downloads quotes for `symbols` and stores them in `cache`.
    public func refresh(_ cache: MarketDataCache, symbols: [String]) async throws {
        for quote in try await quotes(for: symbols) {
            cache.upsert(quote)
        }
    }

    /// Downloads the rate and stores it in `cache`.
    public func refresh(_ cache: MarketDataCache, from: Currency, to: Currency) async throws {
        cache.upsert(try await rate(from: from, to: to))
    }

    /// Downloads the daily closes between two UTC days (inclusive).
    ///
    /// One chart call for the whole range. Missing days (weekends,
    /// holidays, listing gaps) and non-positive closes are skipped —
    /// a shorter result is normal, a transport failure throws.
    public func dailySeries(_ rawSymbol: String, from: Date, to: Date) async throws -> DailySeries {
        guard let symbol = Self.normalizedSymbol(rawSymbol) else {
            throw YahooQuoteError.invalidSymbol(rawSymbol)
        }
        let p1 = Int(floor(from.timeIntervalSince1970))
        let p2 = Int(ceil(to.timeIntervalSince1970)) + 86_400 // period2 is end-exclusive; pad one day
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?period1=\(p1)&period2=\(p2)&interval=1d")
        else {
            throw YahooQuoteError.invalidSymbol(symbol)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let responsePair: (Data, HTTPURLResponse)
        do {
            responsePair = try await fetch(request)
        } catch let error as YahooQuoteError {
            throw error
        } catch {
            throw YahooQuoteError.network(message: error.localizedDescription)
        }
        let (body, response) = responsePair
        guard (200..<300).contains(response.statusCode) else {
            throw YahooQuoteError.http(status: response.statusCode)
        }
        let document: ChartDocument
        do {
            document = try JSONDecoder().decode(ChartDocument.self, from: body)
        } catch {
            throw YahooQuoteError.decoding(message: "Chart response is not in the expected shape: \(error.localizedDescription)")
        }
        guard let chart = document.chart else {
            throw YahooQuoteError.decoding(message: "Response has no 'chart' section")
        }
        if let apiError = chart.error {
            throw YahooQuoteError.noData(symbol: symbol, message: apiError.description ?? apiError.code ?? "unknown error")
        }
        guard let result = chart.result?.first else {
            throw YahooQuoteError.noData(symbol: symbol, message: "No chart result in response")
        }

        let stamps = result.timestamp ?? []
        let closes = (result.indicators?.quote ?? [])
            .lazy.compactMap { $0?.close }
            .first ?? []
        var byDay: [Date: Decimal] = [:]
        for (stamp, close) in zip(stamps, closes) {
            guard let stamp, let close, close.isFinite, close > 0 else { continue }
            guard let price = Decimal(string: "\(close)") else { continue }
            // Same-day duplicates (post-market revisions) resolve to the
            // later entry — same "newer wins" rule as the cache.
            byDay[DailyPrice.utcDay(Date(timeIntervalSince1970: stamp))] = price
        }
        let points = byDay.sorted { $0.key < $1.key }.map { DailyPrice(day: $0.key, price: $0.value) }
        let code = (result.meta?.currency ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return DailySeries(
            symbol: symbol,
            currency: code.isEmpty ? .unknown : Currency(rawValue: code) ?? .unknown,
            points: points
        )
    }

    // MARK: Transport

    fileprivate struct Meta {
        let price: Decimal
        let currency: Currency
        let asOf: Date?
    }

    private func fetchMeta(symbol: String) async throws -> Meta {
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=1d")
        else {
            throw YahooQuoteError.invalidSymbol(symbol)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let responsePair: (Data, HTTPURLResponse)
        do {
            responsePair = try await fetch(request)
        } catch let error as YahooQuoteError {
            throw error
        } catch {
            throw YahooQuoteError.network(message: error.localizedDescription)
        }
        let (body, response) = responsePair
        guard (200..<300).contains(response.statusCode) else {
            throw YahooQuoteError.http(status: response.statusCode)
        }

        let document: ChartDocument
        do {
            document = try JSONDecoder().decode(ChartDocument.self, from: body)
        } catch {
            throw YahooQuoteError.decoding(message: "Chart response is not in the expected shape: \(error.localizedDescription)")
        }
        guard let chart = document.chart else {
            throw YahooQuoteError.decoding(message: "Response has no 'chart' section")
        }
        if let apiError = chart.error {
            throw YahooQuoteError.noData(symbol: symbol, message: apiError.description ?? apiError.code ?? "unknown error")
        }
        guard let meta = chart.result?.first?.meta else {
            throw YahooQuoteError.noData(symbol: symbol, message: "No chart result in response")
        }
        return try meta.makeMeta()
    }

    private static func normalizedSymbol(_ raw: String) -> String? {
        let symbol = raw.trimmingCharacters(in: .whitespaces).uppercased()
        return symbol.isEmpty ? nil : symbol
    }
}

// The chart endpoint answers all three needs of the market store: latest
// price, latest FX rate, and daily closes.
extension YahooQuoteProvider: PriceDataProvider {}

// MARK: - Lenient response shape

/// The documented-but-undocumented chart API: almost everything is
/// optional, because Yahoo has shipped every permutation of this body.
private struct ChartDocument: Decodable {
    /// The actual API nests everything under `"chart"`.
    let chart: Chart?

    struct Chart: Decodable {
        struct ResultItem: Decodable {
            struct Meta: Decodable {
                let currency: String?
                /// Arrives as a JSON number; interpreted via shortest
                /// round-trip `Double` text so the `Decimal` carries exactly
                /// what Yahoo printed (never a 38-digit binary expansion).
                let price: Double?
                /// Unix seconds.
                let asOf: Double?

                enum CodingKeys: String, CodingKey {
                    case currency
                    case price = "regularMarketPrice"
                    case asOf = "regularMarketTime"
                }

                func makeMeta() throws -> YahooQuoteProvider.Meta {
                    guard let price else {
                        throw YahooQuoteError.decoding(message: "Chart meta has no regularMarketPrice")
                    }
                    guard price.isFinite, let decimal = Decimal(string: "\(price)") else {
                        throw YahooQuoteError.decoding(message: "Uninterpretable price: \(price)")
                    }
                    let code = (currency ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                    return YahooQuoteProvider.Meta(
                        price: decimal,
                        currency: code.isEmpty ? .unknown : Currency(rawValue: code) ?? .unknown,
                        asOf: asOf.map { Date(timeIntervalSince1970: $0) }
                    )
                }
            }
            struct Indicators: Decodable {
                /// Yahoo nests the series under "quote" → array of
                /// objects ({close, volume, …}); sometimes null entries
                /// appear, hence the optionals.
                let quote: [QuoteData?]?
            }
            struct QuoteData: Decodable {
                let close: [Double?]?
            }
            let meta: Meta?
            /// Unix seconds per interval point; nulls mark no-data slots.
            let timestamp: [Double?]?
            let indicators: Indicators?
        }

        struct APIError: Decodable {
            let code: String?
            let description: String?
        }

        let result: [ResultItem]?
        let error: APIError?
    }
}
