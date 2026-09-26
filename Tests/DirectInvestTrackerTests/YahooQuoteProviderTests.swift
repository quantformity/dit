import Testing
import Foundation
@testable import DirectInvestTracker

// Stubbed transport: `YahooQuoteProvider(fetch:)` takes the HTTP call as
// a closure, so these tests exercise the real parsing/error logic with
// canned bodies — no network, no URLProtocol mocking.
struct YahooQuoteProviderTests {

    // MARK: Fixtures

    private func chartBody(symbol: String, currency: String, price: Double, time: Double = 1_700_000_000) -> Data {
        let dict: [String: Any] = [
            "chart": [
                "result": [[
                    "meta": [
                        "symbol": symbol,
                        "currency": currency,
                        "regularMarketPrice": price,
                        "regularMarketTime": time
                    ]
                ]],
                "error": NSNull()
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private let notFoundBody = Data(
        #"{"chart":{"result":null,"error":{"code":"NOT_FOUND","description":"No data found, symbol may be delisted"}}}"#.utf8
    )

    private func ok(_ status: Int = 200, _ url: URL, _ body: Data) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    private func canned(_ status: Int, _ body: Data) -> YahooQuoteProvider {
        YahooQuoteProvider { request in
            ok(status, request.url!, body)
        }
    }

    /// Shared-mutable box so a `@Sendable` stub closure can report what
    /// it was called with (each stub is hit by exactly one request here,
    /// so no synchronization is actually needed — the box only exists
    /// to satisfy Sendable capture rules).
    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    private let zero: Decimal = Decimal(string: "0")!

    // MARK: Single quote

    @Test func downloadsQuoteFromChartMeta() async throws {
        let provider = canned(200, chartBody(symbol: "SHOP.TO", currency: "CAD", price: 82.15))
        let quote = try await provider.quote(for: " shop.to ")

        #expect(quote.symbol == "SHOP.TO")          // normalized (case + trim)
        #expect(quote.currency == Currency.cad)     // from meta.currency
        #expect(quote.price == Decimal(string: "82.15")!)
        #expect(quote.asOf == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(quote.source == "yahoo")
    }

    @Test func requestCarriesBrowserUserAgentAndChartPath() async throws {
        let seen = Box<URLRequest>()
        let provider = YahooQuoteProvider { request in
            seen.value = request
            return ok(200, request.url!, self.chartBody(symbol: "AAPL", currency: "USD", price: 210))
        }
        _ = try await provider.quote(for: "AAPL")

        let request = try #require(seen.value)
        #expect(request.url!.absoluteString.hasPrefix("https://query1.finance.yahoo.com/v8/finance/chart/AAPL"))
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla") == true)
    }

    @Test func delistedSymbolThrowsNoData() async throws {
        let provider = canned(200, notFoundBody)
        do {
            _ = try await provider.quote(for: "DEAD")
            #expect(false, "expected noData")
        } catch let error as YahooQuoteError {
            #expect(error == .noData(symbol: "DEAD", message: "No data found, symbol may be delisted"))
        } catch {
            #expect(false, "unexpected error: \(error)")
        }
    }

    @Test func httpFailureCarriesStatus() async throws {
        let provider = canned(429, Data("throttled".utf8))
        do {
            _ = try await provider.quote(for: "AAPL")
            #expect(false, "expected http(429)")
        } catch let error as YahooQuoteError {
            #expect(error == .http(status: 429))
        } catch {
            #expect(false, "unexpected error: \(error)")
        }
    }

    @Test func emptySymbolIsRejected() async throws {
        // The stub would throw if a request ever got out the door.
        let provider = YahooQuoteProvider { _ in throw URLError(.badURL) }
        do {
            _ = try await provider.quote(for: "   ")
            #expect(false, "expected invalidSymbol")
        } catch let error as YahooQuoteError {
            #expect(error == .invalidSymbol("   "))
        } catch {
            #expect(false, "unexpected error: \(error)")
        }
    }

    // MARK: Batch

    @Test func batchSkipsUnquotedSymbols() async throws {
        let provider = YahooQuoteProvider { request in
            let url = request.url!.absoluteString
            if url.contains("AAPL") { return ok(200, request.url!, self.chartBody(symbol: "AAPL", currency: "USD", price: 210)) }
            if url.contains("DEAD") { return ok(200, request.url!, self.notFoundBody) }   // delisted
            if url.contains("GONE") { return ok(404, request.url!, Data()) }               // HTTP failure
            throw URLError(.notConnectedToInternet)                                        // transport failure
        }

        let quotes = try await provider.quotes(for: ["AAPL", "DEAD", "GONE", "NET"])
        // Only AAPL survives: delisted + 404 are API-level skips,
        // the transport failure is tolerated while successes exist.
        #expect(quotes.count == 1)
        #expect(quotes.first?.symbol == "AAPL")
    }

    @Test func batchThrowsWhenEverythingFailsAtTransport() async throws {
        let provider = YahooQuoteProvider { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await provider.quotes(for: ["AAPL", "MSFT"])
            #expect(false, "expected allSymbolsFailed")
        } catch let error as YahooQuoteError {
            #expect(error == .allSymbolsFailed(transportFailures: 2, apiFailures: 0))
        } catch {
            #expect(false, "unexpected error: \(error)")
        }
    }

    @Test func emptyBatchReturnsEmptyWithoutNetwork() async throws {
        let provider = YahooQuoteProvider { _ in throw URLError(.badURL) }
        let quotes = try await provider.quotes(for: [])
        #expect(quotes.isEmpty)
    }

    // MARK: Exchange rates

    @Test func sameCurrencyRateIsIdentityWithoutNetwork() async throws {
        let provider = YahooQuoteProvider { _ in throw URLError(.badURL) }
        let rate = try await provider.rate(from: .usd, to: .usd)

        #expect(rate.base == Currency.usd)
        #expect(rate.quote == Currency.usd)
        #expect(rate.rate == 1)
    }

    @Test func unknownCurrencyRateIsRejected() async throws {
        let provider = YahooQuoteProvider { _ in throw URLError(.badURL) }
        do {
            _ = try await provider.rate(from: .unknown, to: .usd)
            #expect(false, "expected invalidSymbol")
        } catch let error as YahooQuoteError {
            guard case .invalidSymbol = error else {
                #expect(false, "expected invalidSymbol, got \(error)")
                return
            }
        } catch {
            #expect(false, "unexpected error: \(error)")
        }
    }

    @Test func downloadsFxRateViaYahooTicker() async throws {
        let path = Box<String>()
        let provider = YahooQuoteProvider { request in
            path.value = request.url?.path
            return ok(200, request.url!, self.chartBody(symbol: "USDCAD=X", currency: "CAD", price: 1.3512, time: 1_700_000_123))
        }
        let rate = try await provider.rate(from: .usd, to: .cad)

        #expect(path.value?.hasSuffix("/USDCAD=X") == true)
        #expect(rate.base == Currency.usd)
        #expect(rate.quote == Currency.cad)
        #expect(rate.rate == Decimal(string: "1.3512")!)
        #expect(rate.asOf == Date(timeIntervalSince1970: 1_700_000_123))
        #expect(rate.source == "yahoo")
    }

    // MARK: Cache integration

    @Test func refreshPopulatesTheCache() async throws {
        let now = Date()
        let provider = YahooQuoteProvider { request in
            let url = request.url!.absoluteString
            // Recent timestamps so the quotes are *fresh* at `now`.
            let t = now.timeIntervalSince1970
            if url.contains("SHOP.TO") { return ok(200, request.url!, self.chartBody(symbol: "SHOP.TO", currency: "CAD", price: 82.15, time: t)) }
            if url.contains("USDCAD=X") { return ok(200, request.url!, self.chartBody(symbol: "USDCAD=X", currency: "CAD", price: 1.35, time: t)) }
            throw URLError(.badURL)
        }

        let cache = MarketDataCache()
        try await provider.refresh(cache, symbols: ["shop.to", "AAPL"]) // AAPL: transport failure, skipped
        try await provider.refresh(cache, from: .usd, to: .cad)

        #expect(cache.freshQuote(for: "SHOP.TO", now: now)?.price == Decimal(string: "82.15")!)
        #expect(cache.freshQuote(for: "AAPL", now: now) == nil)
        let reciprocal = cache.rateValue(from: .cad, to: .usd)!
        // 1 / 1.35 = 0.740740… — check the band instead of an exact tail
        #expect(reciprocal >= Decimal(string: "0.74")! && reciprocal <= Decimal(string: "0.741")!)
        #expect(cache.rateValue(from: .usd, to: .eur) == nil)
    }

    // MARK: Live (opt-in; the stubbed tests above cover the logic)

    @Test("liveYahooFetch", .enabled(if: ProcessInfo.processInfo.environment["DIT_LIVE"] != nil))
    func liveYahooFetch() async throws {
        let provider = YahooQuoteProvider()

        let quote = try await provider.quote(for: "SHOP.TO")
        print("LIVE quote: \(quote)")
        #expect(quote.price > zero)
        #expect(quote.currency != Currency.unknown)

        let rate = try await provider.rate(from: .usd, to: .cad)
        print("LIVE rate: \(rate)")
        #expect(rate.rate > zero)
    }
}