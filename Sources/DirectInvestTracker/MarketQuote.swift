import Foundation

/// A single price observation for a listed security.
///
/// Market quotes are *snapshots* fetched from an external provider
/// (e.g. Yahoo Finance): unlike the transaction log, they decay over
/// time, so each one carries an `asOf` timestamp that consumers should
/// check before letting it drive a valuation. The fetched quote is the
/// only source of truth for "what is this stock worth right now" —
/// nothing in the portfolio document stores a price.
public struct MarketQuote: Codable, Hashable, Sendable, Comparable {

    /// Ticker symbol, normalized the same way as ``EquityTicker``
    /// (trimmed, upper-cased).
    public let symbol: String

    /// The currency `price` is denominated in (TSX listings trade in CAD,
    /// NYSE in USD). A quote whose currency does not match the
    /// position's trading currency cannot be used for valuation.
    public let currency: Currency

    /// Last traded price, in `currency`.
    public let price: Decimal

    /// When the provider returned this price. `nil` means freshness is
    /// unknown — ``isFresh(maxAge:now:)`` treats that as stale.
    public let asOf: Date?

    /// Provider label, e.g. `"yahoo"`. Free-form so adding a provider
    /// never requires migrating stored data.
    public let source: String?

    public init(
        symbol: String,
        currency: Currency,
        price: Decimal,
        asOf: Date? = nil,
        source: String? = nil
    ) {
        self.symbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        self.currency = currency
        self.price = price
        self.asOf = asOf
        self.source = source
    }

    /// Lenient decoding: only `symbol` and `price` are load-bearing.
    /// A missing `currency` degrades to ``Currency/unknown`` and missing
    /// `asOf`/`source` become `nil`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            symbol: try container.decode(String.self, forKey: .symbol),
            currency: (try container.decodeIfPresent(Currency.self, forKey: .currency)) ?? .unknown,
            price: try container.decode(Decimal.self, forKey: .price),
            asOf: try? container.decodeIfPresent(Date.self, forKey: .asOf),
            source: try? container.decodeIfPresent(String.self, forKey: .source)
        )
    }

    /// Whether this quote is young enough to trust.
    ///
    /// Quotes without a timestamp are treated as stale — a snapshot whose
    /// age cannot be established is not safe for valuations.
    public func isFresh(maxAge: TimeInterval = 60, now: Date = .now) -> Bool {
        guard let asOf else { return false }
        return now.timeIntervalSince(asOf) <= maxAge
    }

    /// Chronological order (oldest first); undated quotes sort as oldest.
    public static func < (lhs: MarketQuote, rhs: MarketQuote) -> Bool {
        switch (lhs.asOf, rhs.asOf) {
        case let (l?, r?): return l < r
        case (nil, .some): return true
        case (.some, nil): return false
        case (nil, nil): return false
        }
    }
}