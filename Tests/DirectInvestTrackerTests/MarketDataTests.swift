import Testing
import Foundation
@testable import DirectInvestTracker

/// NOTE on Decimal expectations: in `#expect`, an integer/float literal
/// *expression* (e.g. `a + b`) is inferred as Int/Double by the macro's
/// operand capture and then compared across types — which fails for
/// equal values. Always compare Decimals against an annotated variable
/// or `Decimal(string:)!`.
struct MarketDataTests {

    // MARK: MarketQuote

    @Test func quoteRoundTripsThroughCodable() throws {
        let q = MarketQuote(
            symbol: " shop.to ",
            currency: .cad,
            price: Decimal(string: "82.15")!,
            asOf: Date(timeIntervalSinceReferenceDate: 1_000),
            source: "yahoo"
        )
        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(MarketQuote.self, from: data)

        #expect(decoded == q)
        #expect(q.symbol == "SHOP.TO") // normalized on init
    }

    @Test func quoteDecodingIsLenient() throws {
        // Hand-written payload: symbol and price only — the rest degrades.
        let json = #"{"symbol":" aapl ","price":250}"#
        let q = try JSONDecoder().decode(MarketQuote.self, from: Data(json.utf8))

        #expect(q.symbol == "AAPL")
        #expect(q.currency == Currency.unknown)
        #expect(q.asOf == nil)
        #expect(q.source == nil)
        let expectedPrice: Decimal = 250 // annotated — not an untyped literal
        #expect(q.price == expectedPrice)
    }

    @Test func quoteRequiresSymbolAndPrice() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MarketQuote.self, from: Data(#"{"price":250}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MarketQuote.self, from: Data(#"{"symbol":"AAPL"}"#.utf8))
        }
    }

    @Test func quotesSortChronologically() {
        let old = MarketQuote(symbol: "X", currency: .usd, price: 1, asOf: Date(timeIntervalSinceReferenceDate: 1))
        let newer = MarketQuote(symbol: "X", currency: .usd, price: 2, asOf: Date(timeIntervalSinceReferenceDate: 2))
        let undated = MarketQuote(symbol: "X", currency: .usd, price: 3)

        #expect([old, newer, undated].sorted() == [undated, old, newer])
    }

    @Test func isFreshChecksAgeAndTimestamp() {
        let now = Date()
        let fresh = MarketQuote(symbol: "X", currency: .usd, price: 1, asOf: now.addingTimeInterval(-30))
        let stale = MarketQuote(symbol: "X", currency: .usd, price: 1, asOf: now.addingTimeInterval(-120))
        let undated = MarketQuote(symbol: "X", currency: .usd, price: 1)

        #expect(fresh.isFresh(now: now))
        #expect(!stale.isFresh(now: now))
        #expect(!undated.isFresh(now: now))
    }

    // MARK: ExchangeRate

    @Test func rateRoundTripsThroughCodable() throws {
        let r = ExchangeRate(
            base: .usd, quote: .cad,
            rate: Decimal(string: "1.35")!,
            asOf: Date(timeIntervalSinceReferenceDate: 2_000),
            source: "yahoo"
        )
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(ExchangeRate.self, from: data) == r)
    }

    @Test func rateDecodingIsLenient() throws {
        let json = #"{"base":"USD","quote":"CAD","rate":1.25}"#
        let r = try JSONDecoder().decode(ExchangeRate.self, from: Data(json.utf8))

        #expect(r.base == Currency.usd)
        #expect(r.quote == Currency.cad)
        #expect(r.asOf == nil)
        #expect(r.source == nil)
        let expectedRate: Decimal = Decimal(string: "1.25")!
        #expect(r.rate == expectedRate)
    }

    @Test func rateRequiresPairAndRate() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ExchangeRate.self, from: Data(#"{"quote":"CAD","rate":1.25}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ExchangeRate.self, from: Data(#"{"base":"USD","quote":"CAD"}"#.utf8))
        }
    }

    @Test func convertHandlesBothDirections() {
        // 1.25 is chosen because its reciprocal (0.8) is exact in decimal.
        let r = ExchangeRate(base: .usd, quote: .cad, rate: Decimal(string: "1.25")!)
        let hundred: Decimal = 100
        let hundredTwentyFive: Decimal = 125

        #expect(r.convert(hundred, from: .usd, to: .cad) == hundredTwentyFive)
        #expect(r.convert(hundredTwentyFive, from: .cad, to: .usd) == hundred)
        #expect(r.convert(hundred, from: .usd, to: .usd) == hundred)
        #expect(r.convert(hundred, from: .usd, to: .eur) == nil)
        #expect(r.convert(hundred, from: .eur, to: .cad) == nil)
    }

    @Test func zeroRateIsUnusable() {
        let r = ExchangeRate(base: .usd, quote: .cad, rate: 0)
        let hundred: Decimal = 100

        // Forward rate is arithmetically defined (0 units per USD)…
        #expect(r.rate(from: .usd, to: .cad) == 0)
        // …but reciprocation is undefined, and conversions are not trusted.
        #expect(r.rate(from: .cad, to: .usd) == nil)
        #expect(r.convert(hundred, from: .usd, to: .cad) == nil)
        #expect(r.convert(hundred, from: .cad, to: .usd) == nil)
    }

    @Test func rateIsFreshWithinDefaultTolerance() {
        let now = Date()
        let hourOld = ExchangeRate(base: .usd, quote: .cad, rate: 1, asOf: now.addingTimeInterval(-3500))
        let twoHoursOld = ExchangeRate(base: .usd, quote: .cad, rate: 1, asOf: now.addingTimeInterval(-7200))

        #expect(hourOld.isFresh(now: now))
        #expect(!twoHoursOld.isFresh(now: now))
    }

    // MARK: MarketDataCache

    private func quote(_ symbol: String, price: Decimal, age: TimeInterval, now: Date) -> MarketQuote {
        MarketQuote(symbol: symbol, currency: .usd, price: price, asOf: now.addingTimeInterval(-age))
    }

    @Test func cacheServesQuotesFreshOrStale() {
        let now = Date()
        let freshCache = MarketDataCache()
        let freshPrice: Decimal = Decimal(string: "250")!
        #expect(freshCache.upsert(quote("aapl", price: freshPrice, age: 10, now: now)))

        #expect(freshCache.quote(for: "AAPL")?.symbol == "AAPL") // case-insensitive lookup
        #expect(freshCache.freshQuote(for: "aapl", now: now)?.price == freshPrice)
        #expect(freshCache.quote(for: "MSFT") == nil)

        let staleCache = MarketDataCache()
        staleCache.upsert(quote("NVDA", price: Decimal(string: "120")!, age: 600, now: now))
        #expect(staleCache.quote(for: "NVDA") != nil)             // still cached…
        #expect(staleCache.freshQuote(for: "NVDA", now: now) == nil) // …but too old to value
    }

    @Test func cacheKeepsNewestObservation() {
        let now = Date()
        let cache = MarketDataCache()
        cache.upsert(quote("AAPL", price: Decimal(string: "249")!, age: 300, now: now))

        #expect(cache.upsert(quote("AAPL", price: Decimal(string: "250")!, age: 5, now: now)))
        #expect(!cache.upsert(quote("AAPL", price: Decimal(string: "240")!, age: 600, now: now)))

        let stored: Decimal = 250
        #expect(cache.quote(for: "AAPL")?.price == stored)
    }

    @Test func cacheReciprocatesRateLookups() {
        let now = Date()
        let cache = MarketDataCache()
        let stored = ExchangeRate(base: .usd, quote: .cad, rate: Decimal(string: "1.25")!, asOf: now, source: "yahoo")
        cache.upsert(stored)

        #expect(cache.rate(from: .usd, to: .cad)?.source == "yahoo")
        #expect(cache.rate(from: .cad, to: .usd)?.base == Currency.usd) // same observation, reverse lookup
        let reciprocal: Decimal = Decimal(string: "0.8")! // 1 / 1.25, exact
        #expect(cache.rateValue(from: .usd, to: .cad) == Decimal(string: "1.25")!)
        #expect(cache.rateValue(from: .cad, to: .usd) == reciprocal)
        #expect(cache.rateValue(from: .eur, to: .cad) == nil)

        #expect(cache.freshRate(from: .cad, to: .usd, now: now)?.rate == stored.rate)

        let staleCache = MarketDataCache()
        staleCache.upsert(ExchangeRate(base: .usd, quote: .cad, rate: Decimal(string: "1.25")!, asOf: now.addingTimeInterval(-7200)))
        #expect(staleCache.rate(from: .usd, to: .cad) != nil)
        #expect(staleCache.freshRate(from: .usd, to: .cad, now: now) == nil)
    }

    @Test func cacheIsSafeForConcurrentAccess() async {
        let cache = MarketDataCache()
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<25 {
                        cache.upsert(MarketQuote(symbol: "S\(worker)-\(i)", currency: .usd, price: Decimal(i)))
                    }
                }
            }
        }

        var found = 0
        for worker in 0..<8 {
            for i in 0..<25 {
                if cache.quote(for: "S\(worker)-\(i)") != nil { found += 1 }
            }
        }
        #expect(found == 200) // no lost updates
    }
}
