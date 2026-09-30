import Foundation

// MARK: - Shared text formatting (display + machine)
//
// Why this file exists: the same money and date shapes were spelled
// by hand in the CLI shell, the renderers, and the JSON layer —
// identical output, ~10 places, each free to drift. One home makes
// "what a cent looks like" ONE decision.
//
// Two families, kept deliberately separate (the contract in
// docs/json.md):
// - DISPLAY text groups thousands, locale-pinned to en_US;
// - MACHINE text (JSON) never groups — parsers must see
//   "279900.60", never "279,900.60" or a binary double.
// No binary floats in either path: Decimal in, Decimal-scaled text out.
//
// Formatters are built per call rather than cached: the CLI formats a
// few hundred values per run (microseconds), and keeping them
// function-local avoids any cross-thread sharing of Foundation's
// formatter classes entirely.

/// Shared text formatting for display tables and the machine contract
/// (see file header: grouped display text vs. non-grouped JSON text).
public enum TextFormat {

    // MARK: Display money and quantities (grouped)

    /// Table money: fixed 2 places, thousands grouped ("1,234.57",
    /// "-6,768.50"). The currency tag is the caller's business.
    public static func money(_ value: Decimal) -> String {
        decimal(max: 2, min: 2, grouping: true)
            .string(from: NSDecimalNumber(decimal: value)) ?? value.description
    }

    /// Prices and share counts in tables: up to 4 places, trailing
    /// zeros trimmed, grouped ("42.7674", "1,260", "96.7").
    public static func quantity(_ value: Decimal) -> String {
        decimal(max: 4, min: 0, grouping: true)
            .string(from: NSDecimalNumber(decimal: value)) ?? value.description
    }

    // MARK: Machine (JSON) text — never grouped

    /// Fixed-decimal JSON string: exactly `scale` places, no grouping
    /// ("279900.60" at 2, "0.0153" at 4, "1.418700" at 6).
    public static func fixed(_ value: Decimal, scale: Int) -> String {
        decimal(max: scale, min: scale, grouping: false)
            .string(from: NSDecimalNumber(decimal: value)) ?? value.description
    }

    /// Quantity as JSON text: up to 4 places, no grouping, trailing
    /// zeros trimmed ("840", "96.7").
    public static func plainQuantity(_ value: Decimal) -> String {
        decimal(max: 4, min: 0, grouping: false)
            .string(from: NSDecimalNumber(decimal: value)) ?? value.description
    }

    private static func decimal(max: Int, min: Int, grouping: Bool) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.usesGroupingSeparator = grouping
        f.groupingSize = grouping ? 3 : 0
        f.minimumFractionDigits = min
        f.maximumFractionDigits = max
        return f
    }

    // MARK: Dates

    /// UTC calendar day, "2026-09-28" — storage and JSON day keys.
    public static func day(_ date: Date) -> String {
        utc(format: "yyyy-MM-dd").string(from: date)
    }

    /// UTC second-precision timestamp, "2026-09-29T02:51:00Z".
    public static func isoStamp(_ date: Date) -> String {
        utc(format: "yyyy-MM-dd'T'HH:mm:ss'Z'").string(from: date)
    }

    /// Human timestamp in the machine's local zone ("Sep 29, 2026,
    /// 10:51 AM") — display-only "as of" text.
    public static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Day in the machine's LOCAL zone ("2026-09-28"). Market report
    /// labels only — where a day is a human label, not a storage key.
    /// (Storage/JSON keys use `day`, which is UTC. The two disagree
    /// for moments near midnight; that is intentional, not a bug.)
    public static func localDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// "2026-09-28 21:51" (local zone) — the market store's compact
    /// quote stamp.
    public static func minuteClock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func utc(format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
}

// MARK: - Replay order

/// The canonical ledger replay order: date first, storage order for
/// same-day ties. `sorted` is NOT stable, so the tie-break must be
/// explicit — every view that shows a derived state (running balances,
/// history lists) has to replay in the same order the balance engine
/// computed, or money appears to evaporate between two printed lines.
public enum Replay {

    /// Stable chronological order over items carrying a date.
    public static func ordered<S: Sequence, T>(_ items: S, date: (T) -> Date) -> [T]
        where S.Element == T
    {
        items.enumerated().sorted { lhs, rhs in
            let left = date(lhs.element), right = date(rhs.element)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Stable chronological order of transactions (date, then storage
    /// position) — the replay order the balance engine and the
    /// statement view share.
    public static func ordered(_ transactions: [Transaction]) -> [Transaction] {
        ordered(transactions, date: \.date)
    }
}