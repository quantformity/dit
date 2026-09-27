import Foundation

/// An in-memory, thread-safe cache of fetched ``MarketQuote``s and
/// ``ExchangeRate``s.
///
/// The cache solves two problems for the derivation layer:
///
/// 1. **Freshness** — quotes and rates decay, so ``freshQuote(for:maxAge:now:)``
///    and ``freshRate(from:to:maxAge:now:)`` refuse to hand back
///    observations older than a maximum age.
/// 2. **Lookup ergonomics** — providers report rates against one hub
///    currency (Yahoo uses USD). ``rateValue(from:to:)`` finds a stored
///    pair in *either* direction and reciprocates when needed, so the
///    ``FXRate`` closure passed to ``AccountBalances`` becomes a one-liner:
///
///     ```swift
///     let b = portfolio.balance(forAccountName: "TD Trading",
///                               rate: cache.rateValue)
///     ```
///
/// The cache is a value: copies share the same underlying store, and the
/// struct is `Sendable` (locking, not isolation, guarantees safety) so it
/// can cross actor boundaries. It performs no I/O itself — a quote
/// provider fills it.
public struct MarketDataCache: @unchecked Sendable {

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var quotes: [String: MarketQuote] = [:]
        var rates: [RateKey: ExchangeRate] = [:]
    }

    private struct RateKey: Hashable {
        let base: Currency
        let quote: Currency
        init(base: Currency, quote: Currency) {
            self.base = base
            self.quote = quote
        }
        init(_ rate: ExchangeRate) {
            self.init(base: rate.base, quote: rate.quote)
        }
    }

    private let box: Box

    public init() {
        box = Box()
    }

    // MARK: Quotes

    /// Stores a quote. A newer observation wins over an older cached one
    /// (out-of-order provider responses cannot regress the cache).
    /// Returns `true` if the observation was stored.
    @discardableResult
    public func upsert(_ quote: MarketQuote) -> Bool {
        box.lock.lock(); defer { box.lock.unlock() }
        guard let existing = box.quotes[quote.symbol], existing >= quote else {
            box.quotes[quote.symbol] = quote
            return true
        }
        return false
    }

    /// The cached quote for a symbol, regardless of age (use
    /// ``freshQuote(for:maxAge:now:)`` when the value will drive a
    /// valuation).
    public func quote(for symbol: String) -> MarketQuote? {
        box.lock.lock(); defer { box.lock.unlock() }
        return box.quotes[symbol.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    /// The cached quote, only if it is younger than `maxAge`
    /// (default 60 s).
    public func freshQuote(for symbol: String, maxAge: TimeInterval = 60, now: Date = .now) -> MarketQuote? {
        guard let quote = quote(for: symbol), quote.isFresh(maxAge: maxAge, now: now) else { return nil }
        return quote
    }

    // MARK: Rates

    /// Stores a rate (keyed by the currency pair). As with quotes, a
    /// newer observation wins. Returns `true` if it was stored.
    @discardableResult
    public func upsert(_ rate: ExchangeRate) -> Bool {
        box.lock.lock(); defer { box.lock.unlock() }
        let key = RateKey(rate)
        guard let existing = box.rates[key], existing >= rate else {
            box.rates[key] = rate
            return true
        }
        return false
    }

    /// The stored observation for a currency pair, found in *either*
    /// direction (a stored USD→CAD pair answers CAD→USD lookups; the
    /// caller then gets the reciprocal via ``ExchangeRate/rate(from:to:)``
    /// or ``rateValue(from:to:)``).
    public func rate(from: Currency, to: Currency) -> ExchangeRate? {
        box.lock.lock(); defer { box.lock.unlock() }
        if let direct = box.rates[RateKey(base: from, quote: to)] { return direct }
        return box.rates[RateKey(base: to, quote: from)]
    }

    /// The effective conversion rate between two currencies,
    /// reciprocated when the stored pair runs the other way. `nil` when
    /// no stored observation covers the pair. Dropped straight into the
    /// ``FXRate`` closure position.
    public func rateValue(from: Currency, to: Currency) -> Decimal? {
        guard let rate = rate(from: from, to: to) else { return nil }
        return rate.rate(from: from, to: to)
    }

    /// Convert between two currencies using stored observations,
    /// **routing through `hub`** when no direct pair is stored:
    ///
    /// 1. a measured `from→to` pair (either direction) wins — it is a
    ///    direct observation, not a composition;
    /// 2. otherwise the product of the two hub legs, `from→hub ×
    ///    hub→to` (each reciprocated as needed).
    ///
    /// This is what makes the USD-hub fetch strategy (one rate fetch
    /// per currency, see ``MarketDataPlan``) serve arbitrary currency
    /// pairs. `nil` when either leg is missing.
    public func routedRate(from: Currency, to: Currency, hub: Currency = .usd) -> Decimal? {
        if from == to { return 1 }
        if from == hub || to == hub { return rateValue(from: from, to: to) }
        // A measured direct pair beats a composed one — it was actually
        // observed, not derived from two other observations.
        if let direct = rateValue(from: from, to: to) { return direct }
        guard let first = rateValue(from: from, to: hub), first != 0,
              let second = rateValue(from: hub, to: to) else { return nil }
        return first * second
    }

    /// Like ``rate(from:to:)``, but only when the observation is younger
    /// than `maxAge` (default 1 hour).
    public func freshRate(from: Currency, to: Currency, maxAge: TimeInterval = 3600, now: Date = .now) -> ExchangeRate? {
        guard let rate = rate(from: from, to: to), rate.isFresh(maxAge: maxAge, now: now) else { return nil }
        return rate
    }

    // MARK: Closure adapters

    /// The ``LastPrice`` closure: the cached price of `symbol` when the
    /// observation is fresh **and** quoted in exactly `currency`. A stale
    /// quote or a quote in a different currency yields `nil` — the caller
    /// then falls back to cost basis, which is the safe answer for a
    /// position that cannot be marked in its own denomination.
    public func lastPrice(for currency: Currency, symbol: String, maxAge: TimeInterval = 60, now: Date = .now) -> Decimal? {
        guard let quote = freshQuote(for: symbol, maxAge: maxAge, now: now) else { return nil }
        guard quote.currency == currency else { return nil }
        return quote.price
    }
}
