import Foundation

/// A currency identified by its ISO 4217 alphabetic code.
///
/// This is a *curated* list of currencies a personal portfolio is realistically
/// likely to hold, plus a lenient `.unknown` case so that data flowing in from
/// external sources (e.g. Yahoo Finance, whose catalog is 154 codes and changes
/// over time) can never fail to decode.
///
/// Deliberately **not** a closed enumeration of every code Yahoo Finance
/// supports — that catalog grows and mutates (e.g. `SLL` was renamed to `SLE`,
/// `CLF` was added) and would turn every API change into a breaking app change.
public enum Currency: String, Codable, CaseIterable, Sendable, Comparable {
    case cad = "CAD"
    case usd = "USD"
    case gbp = "GBP"
    case eur = "EUR"
    case jpy = "JPY"
    case chf = "CHF"
    case aud = "AUD"
    case nzd = "NZD"
    case cny = "CNY"
    case hkd = "HKD"

    /// Fallback for any code that is not enumerated here.
    /// Decoding never throws for unrecognized codes: they become `.unknown`.
    case unknown = ""

    // MARK: - Catalog

    /// The enumerated currencies (excluding `.unknown`), sorted by ISO code.
    public static let known: [Currency] = allCases
        .filter { $0 != .unknown }
        .sorted()

    /// USD is Yahoo Finance's FX conversion hub: most pairs are quoted against
    /// USD, so multi-hop conversions (e.g. EUR → CAD) route through USD.
    /// This is distinct from a *display* currency (e.g. CAD for a Canadian
    /// user), which is an app-level choice.
    public static let conversionHub: Currency = .usd

    // MARK: - Metadata

    /// ISO 4217 alphabetic code, e.g. `"CAD"`. Empty string for `.unknown`.
    public var isoCode: String { rawValue }

    /// Human-readable name, e.g. `"Canadian Dollar"`.
    public var displayName: String {
        switch self {
        case .cad: "Canadian Dollar"
        case .usd: "US Dollar"
        case .gbp: "British Pound Sterling"
        case .eur: "Euro"
        case .jpy: "Japanese Yen"
        case .chf: "Swiss Franc"
        case .aud: "Australian Dollar"
        case .nzd: "New Zealand Dollar"
        case .cny: "Chinese Yuan"
        case .hkd: "Hong Kong Dollar"
        case .unknown: "Unknown"
        }
    }

    /// A short symbol suitable for display next to an amount.
    public var symbol: String {
        switch self {
        case .cad: "C$"
        case .usd: "$"
        case .gbp: "£"
        case .eur: "€"
        case .jpy: "¥"
        case .chf: "CHF"
        case .aud: "A$"
        case .nzd: "NZ$"
        case .cny: "CN¥"
        case .hkd: "HK$"
        case .unknown: "?"
        }
    }

    /// The number of decimal places this currency is normally quoted with.
    public var decimalPlaces: Int {
        switch self {
        case .jpy: 0
        default: 2
        }
    }

    // MARK: - Yahoo Finance quotes

    /// The Yahoo Finance FX ticker for quoting this currency against `base`,
    /// e.g. `.eur.quoteTicker()` → `"EURUSD=X"`,
    /// `.jpy.quoteTicker(against: .cad)` → `"JPYCAD=X"`.
    ///
    /// Returns `nil` when either side is `.unknown`, or when both sides are the
    /// same currency (no quote exists for `CADCAD=X`).
    public func quoteTicker(against base: Currency = Self.conversionHub) -> String? {
        guard self != .unknown, base != .unknown, self != base else { return nil }
        return "\(rawValue)\(base.rawValue)=X"
    }

    // MARK: - Lenient Codable

    /// Decoding is case- and whitespace-insensitive, and any unrecognized code
    /// decodes to `.unknown` instead of throwing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container
            .decode(String.self)
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        self = Currency(rawValue: code) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoCode)
    }

    // MARK: - Comparable

    /// ISO codes sort lexicographically; `.unknown` always sorts last.
    public static func < (lhs: Currency, rhs: Currency) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, _): return false   // unknown is never "less than" anything
        case (_, .unknown): return true    // everything else is less than unknown
        case let (left, right): return left.isoCode < right.isoCode
        }
    }
}
