import Foundation

// MARK: - FX matrix (single-day, multi-currency)
//
// `dit quote USD/CAD/HKD/EUR` asks for EVERY pairwise rate among the
// listed currencies. The source of truth for what exists is the rate
// feed (live) or the market store (single-day with --as-of); anything
// that is not a DIRECT observation is composed from two USD legs and
// labelled — a triangulated number is an approximation, and the
// contract (docs/json.md) requires it to say so.

/// Single-day FX cross-rate table (`dit quote CCY/CCY/…`).
///
/// Direct observations win over composed ones; everything composed is
/// labelled (see file header and docs/json.md for the honesty rules).
public enum FXMatrix {

    /// A chain is 3+ known ISO codes separated by `/` (fewer than 3
    /// is the two-currency pair path, or an equity symbol). Returns
    /// nil when the token is not a chain at all.
    public static func parseChain(_ token: String) -> [Currency]? {
        let parts = token.uppercased().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        var seen = Set<Currency>()
        var currencies: [Currency] = []
        for part in parts {
            guard let currency = Currency(rawValue: String(part)), currency != .unknown,
                  !seen.contains(currency)
            else { return nil }
            seen.insert(currency)
            currencies.append(currency)
        }
        return currencies
    }

    /// True when the token LOOKS like a chain (3+ slash-separated
    /// three-letter groups) even though some part is not a known
    /// currency — enough to give a pointed error instead of treating
    /// it as a stock symbol.
    public static func looksLikeChain(_ token: String) -> Bool {
        let parts = token.uppercased().split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isLetter) }
    }

    /// One directional rate: `base` buys `rate` units of `quote`.
    public struct Cell: Sendable {
        /// Left side of the pair (the unit being priced).
        public let base: Currency
        /// Right side (what one unit of `base` buys).
        public let quote: Currency
        /// nil = no observation and no triangulation path.
        public let rate: Decimal?
        /// "observed" (direct), "reciprocal" (1 / observed reverse
        /// pair), "derived" (triangulated via USD), or "none".
        public let basis: String
        /// Day the direct source was observed (stored mode); nil for
        /// derived/none and live.
        public let date: String?

        /// Memberwise init; `basis`/`date` carry the provenance so the
        /// table can label a derived rate (`*`, "via USD").
        public init(base: Currency, quote: Currency, rate: Decimal?, basis: String, date: String?) {
            self.base = base
            self.quote = quote
            self.rate = rate
            self.basis = basis
            self.date = date
        }
    }

    /// Build every directional cell (base × quote, base != quote).
    /// `direct` answers "the rate for A buying B (or B buying A), as
    /// stored/fetched, with the day it was observed" — the builder
    /// handles reciprocals and USD triangulation so the CLI stays a
    /// shell and the math stays testable. Rates are always
    /// "quote-ccy per 1 base-ccy".
    public static func cells(currencies: [Currency],
                             direct: (Currency, Currency) -> (rate: Decimal, date: String?)?) -> [Cell] {
        let hub = Currency.conversionHub   // USD
        func directRate(_ from: Currency, _ to: Currency) -> (rate: Decimal, date: String?)? {
            direct(from, to)
        }
        func rateOf(_ from: Currency, _ to: Currency) -> (rate: Decimal, basis: String, date: String?)? {
            if from == to { return (1, "identity", nil) }
            if let observed = directRate(from, to) {
                return (observed.rate, "observed", observed.date)
            }
            if let reverse = directRate(to, from), reverse.rate != 0 {
                return (1 / reverse.rate, "reciprocal", reverse.date)
            }
            // Triangulate through the hub: A→B = (A→hub) × (hub→B)
            // — both legs are already "quote per 1 base", so the
            // chain multiplies. Only when BOTH legs resolve (each
            // possibly itself a reciprocal). Derived — never silently
            // an "observed".
            guard from != hub, to != hub,
                  let up = rateOf(from, hub), up.rate != 0,
                  let across = rateOf(hub, to)
            else { return nil }
            return (up.rate * across.rate, "derived", nil)
        }

        var result: [Cell] = []
        for base in currencies {
            for quote in currencies where quote != base {
                if let rate = rateOf(base, quote) {
                    result.append(Cell(base: base, quote: quote, rate: rate.rate,
                                       basis: rate.basis, date: rate.date))
                } else {
                    result.append(Cell(base: base, quote: quote, rate: nil,
                                       basis: "none", date: nil))
                }
            }
        }
        return result
    }
}