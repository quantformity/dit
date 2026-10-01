import Foundation

/// A currency exchange-rate snapshot: "1 unit of `base` buys `rate`
/// units of `quote`" (e.g. 1 USD = 1.25 CAD).
///
/// Like ``MarketQuote``, this is a fetched snapshot with an `asOf`
/// timestamp rather than permanent data. Providers report rates against
/// one hub currency (Yahoo Finance uses USD); ``MarketDataCache``
/// handles looking a pair up in either direction.
public struct ExchangeRate: Codable, Hashable, Sendable, Comparable {

    /// The unit being priced, e.g. `.usd`.
    public let base: Currency

    /// The currency bought per unit of `base`, e.g. `.cad`.
    public let quote: Currency

    /// Units of `quote` per one unit of `base`.
    public let rate: Decimal

    /// When the provider returned this rate. `nil` = freshness unknown.
    public let asOf: Date?

    /// Provider label, e.g. `"yahoo"`.
    public let source: String?

    /// Memberwise init; does NOT reciprocate — a CAD/USD rate is
    /// stored exactly as observed (reversal happens at lookup, see
    /// ``MarketDataCache``).
    public init(
        base: Currency,
        quote: Currency,
        rate: Decimal,
        asOf: Date? = nil,
        source: String? = nil
    ) {
        self.base = base
        self.quote = quote
        self.rate = rate
        self.asOf = asOf
        self.source = source
    }

    /// Lenient decoding: the pair and the rate are load-bearing (a
    /// missing one makes the record unusable), but missing `asOf`/
    /// `source` become `nil` and unrecognized currency codes degrade
    /// to ``Currency/unknown`` via ``Currency``'s own leniency.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            base: try container.decode(Currency.self, forKey: .base),
            quote: try container.decode(Currency.self, forKey: .quote),
            rate: try container.decode(Decimal.self, forKey: .rate),
            asOf: try? container.decodeIfPresent(Date.self, forKey: .asOf),
            source: try? container.decodeIfPresent(String.self, forKey: .source)
        )
    }

    /// Parse the display form `"BASE/QUOTE"` ("USD/CAD") into a rate
    /// request: base buys quote. Both sides must be known ISO codes
    /// and different; anything else returns nil and the symbol is
    /// treated as an equity. Direction matches the stored USD-hub
    /// series: "USD/CAD" prices CAD per 1 USD, "CAD/USD" prices
    /// USD per 1 CAD (fetched reciprocally by the cache layer).
    public static func pairRequest(for symbol: String) -> (from: Currency, to: Currency)? {
        let parts = symbol.uppercased().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let from = Currency(rawValue: String(parts[0])),
              let to = Currency(rawValue: String(parts[1])),
              from != .unknown, to != .unknown, from != to
        else { return nil }
        return (from, to)
    }

    /// The effective rate between two currencies this pair covers,
    /// reciprocating when asked for the reverse direction.
    ///
    /// `rate(from: .usd, to: .cad)` returns `rate` itself;
    /// `rate(from: .cad, to: .usd)` returns `1 / rate` (rounded to
    /// `Decimal`'s 38 significant digits). Any other pair — including
    /// either currency of an unrelated pair — returns `nil`, as does a
    /// zero rate in the reciprocating direction.
    public func rate(from: Currency, to: Currency) -> Decimal? {
        if from == base && to == quote {
            return rate
        }
        if from == quote && to == base {
            guard rate != 0 else { return nil }
            return 1 / rate
        }
        return nil
    }

    /// Convert `amount` between the currencies this pair covers, in
    /// either direction. Same-currency conversions are the identity;
    /// unrelated currencies or a zero rate return `nil`.
    public func convert(_ amount: Decimal, from: Currency, to currency: Currency) -> Decimal? {
        if from == currency {
            return amount
        }
        guard rate != 0, let factor = rate(from: from, to: currency) else { return nil }
        return amount * factor
    }

    /// Whether this observation is young enough to trust. FX rates move
    /// slowly, so the default tolerance is an hour.
    public func isFresh(maxAge: TimeInterval = 3600, now: Date = .now) -> Bool {
        guard let asOf else { return false }
        return now.timeIntervalSince(asOf) <= maxAge
    }

    /// Chronological order (oldest first); undated rates sort as oldest.
    public static func < (lhs: ExchangeRate, rhs: ExchangeRate) -> Bool {
        switch (lhs.asOf, rhs.asOf) {
        case let (l?, r?): return l < r
        case (nil, .some): return true
        case (.some, nil): return false
        case (nil, nil): return false
        }
    }
}