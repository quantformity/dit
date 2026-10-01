import Foundation

// MARK: - Historical FX (the clock, not the snapshot)

/// One FX answer plus its provenance.
public struct FXQuote: Sendable {
    /// Units of quote currency per unit of base (e.g. CAD per 1 USD).
    public let rate: Decimal
    /// The date of the underlying close(s) actually used — may be
    /// earlier than the requested day (weekends, holidays, gaps).
    public let asOf: Date
    /// nil = direct single-pair observation; a label means the rate
    /// was composed (inverted twin / triangulated through USD) and
    /// the number is derived, not quoted.
    public let via: String?
    /// Days between `asOf` and the requested day (0 = exact day).
    public let stalenessDays: Int
    /// true when a triangulated cross was used.
    public var approx: Bool { via != nil }
}

/// Reads FX the way a historian must: "what did one unit of `base`
/// buy in `quote` ON that date?" — the last stored close on or
/// before it, from daily pair series only.
///
/// The latest-snapshot rates (`MarketData.latestRates`) are
/// deliberately NOT a source here: today's rate is not last June's
/// rate, and using it as a fallback would fabricate history. No
/// series at or before a needed date means NO ANSWER — callers dash.
///
/// Lookup order for base→quote (all from stored series):
/// 1. the direct pair ("USD/CAD" prices CAD per 1 USD);
/// 2. its inverted twin ("CAD/USD" → reciprocal; same observed pair);
/// 3. a triangulated cross through the USD hub (marked `approx`).
/// A leg older than `maxStalenessDays` (default 7) is refused —
/// beyond a week, a stale close is no longer "that date's FX".
public struct FXClock: Sendable {
    public let maxStalenessDays: Int
    /// pair key (e.g. "USD/CAD") → its daily closes, ascending
    private let pairs: [String: [DailyPrice]]

    public init(series: [String: PriceSeries], maxStalenessDays: Int = 7) {
        self.maxStalenessDays = maxStalenessDays
        self.pairs = series.filter { $0.key.contains("/") && !$0.value.points.isEmpty }
            .mapValues { $0.points.sorted { $0.day < $1.day } }
    }

    public var isEmpty: Bool { pairs.isEmpty }

    /// The last close on or before `day`, within the staleness limit.
    private func leg(_ key: String, notOlderThan day: Date) -> DailyPrice? {
        guard let points = pairs[key],
              let price = points.last(where: { $0.day <= day }),
              PnLWindow.utcDaydiff(price.day, day) <= maxStalenessDays else { return nil }
        return price
    }

    /// A USD-hub leg quoted as `quote` per 1 `base`, either stored
    /// direction ("HKD/USD" direct or "USD/HKD" inverted).
    private func hubLeg(base: Currency, quote quoteCurrency: Currency,
                        notOlderThan day: Date) -> (Decimal, Date)? {
        if let p = leg("\(base.rawValue)/\(quoteCurrency.rawValue)", notOlderThan: day) {
            return (p.price, p.day)
        }
        if let p = leg("\(quoteCurrency.rawValue)/\(base.rawValue)", notOlderThan: day),
           p.price != 0 {
            return (Decimal(1) / p.price, p.day)
        }
        return nil
    }

    /// base→quote on `day`. nil = honestly unanswerable (no stored
    /// FX pair data on or before that date, or only too-old data).
    public func quote(from base: Currency, to quote: Currency, on day: Date) -> FXQuote? {
        guard base != quote, base != .unknown, quote != .unknown else { return nil }
        let day = DailyPrice.utcDay(day)

        // 1. Direct: "USD/CAD" style — quote per 1 base.
        if let p = leg("\(base.rawValue)/\(quote.rawValue)", notOlderThan: day) {
            return FXQuote(rate: p.price, asOf: p.day, via: p.via,
                           stalenessDays: PnLWindow.utcDaydiff(p.day, day))
        }
        // 2. Inverted twin: "CAD/USD" holds the same observed pair;
        // a reciprocal is arithmetic, not a second observation.
        if let p = leg("\(quote.rawValue)/\(base.rawValue)", notOlderThan: day), p.price != 0 {
            let rate = Decimal(1) / p.price
            return FXQuote(rate: rate, asOf: p.day,
                           via: "inverted \(quote.rawValue)/\(base.rawValue)",
                           stalenessDays: PnLWindow.utcDaydiff(p.day, day))
        }
        // 3. Triangulated cross through the USD hub (same convention
        // as MarketDataCache.routedRate, but dated).
        if base != .usd, quote != .usd,
           let toUSD = hubLeg(base: base, quote: .usd, notOlderThan: day),   // USD per 1 base
           let fromUSD = hubLeg(base: .usd, quote: quote, notOlderThan: day) // quote per 1 USD
        {
            guard toUSD.0 != 0 else { return nil }
            // (USD per base) × (quote per USD) = quote per base.
            let composed = toUSD.0 * fromUSD.0
            return FXQuote(rate: composed,
                           asOf: max(toUSD.1, fromUSD.1),
                           via: "derived via USD (\(base.rawValue)→USD→\(quote.rawValue))",
                           stalenessDays: max(PnLWindow.utcDaydiff(toUSD.1, day),
                                              PnLWindow.utcDaydiff(fromUSD.1, day)))
        }
        // Base or quote IS USD and neither direction was stored.
        return nil
    }
}