import Foundation

/// A user-defined label for grouping holdings (e.g. `"dividend"`,
/// `"watchlist"`, `"long-term hold"`).
///
/// A free-form string, but wrapped in a dedicated type and **normalized**
/// (trimmed, lowercased) so that `"Dividend"` and `"dividend"` are the same
/// tag. The vocabulary is deliberately open — it emerges from the data
/// rather than being a closed enum that needs a code change per new label.
///
/// Encodes as a bare JSON string (not an object), so a tag set serializes
/// as `["dividend", "watchlist"]`.
public struct Tag: Codable, Hashable, Sendable, Comparable {
    /// The normalized tag value (trimmed, lowercased).
    public let rawValue: String

    /// Normalizes on creation (trim + lowercase) — normalization is
    /// the equality story, so never bypass it with a raw stored value.
    public init(_ value: String) {
        self.rawValue = value.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Capitalized form for display.
    public var displayValue: String { rawValue.capitalized }

    // MARK: Codable (bare string)

    /// Decodes a bare string through ``init(_:)`` so stored tags get
    /// re-normalized ("Dividend" in JSON still equals "dividend").
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    /// Writes the bare normalized string (no wrapper object).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: Comparable

    /// Sort by the lowercase value (display order is stable regardless
    /// of how tags were typed).
    public static func < (lhs: Tag, rhs: Tag) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}