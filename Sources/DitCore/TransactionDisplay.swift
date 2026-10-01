import Foundation

/// Plain-text rendering of transactions, shared by the CLI listings,
/// mutation messages, and error hints. Values print as exact decimals
/// (no rounding, no grouping — these are facts, not report columns).
extension Transaction {

    /// The kind's display name — also the identity used by
    /// `--kind` filtering and the "same family" edit rule.
    public var kindName: String { kind.kindName }

    // MARK: Rendering

    /// One-line rendering: "buy 10 SHOP.TO @ 180.00", "deposit 1000", …
    public var summaryLine: String {
        var line: String
        switch kind {
        case .deposit(let amount):
            line = "deposit \(Self.exact(amount)) \(currency.rawValue)"
        case .withdrawal(let amount):
            line = "withdrawal \(Self.exact(amount)) \(currency.rawValue)"
        case .stockPurchase(let details):
            line = "buy \(Self.exact(details.shares)) \(details.ticker) @ \(Self.exact(details.price))"
        case .stockSale(let details):
            line = "sell \(Self.exact(details.shares)) \(details.ticker) @ \(Self.exact(details.price))"
        case .dividend(let details):
            line = "dividend \(details.ticker) \(Self.exact(details.amount)) \(currency.rawValue)"
        case .gicPurchase(let details):
            line = "GIC '\(details.product)' \(Self.exact(details.principal)) \(currency.rawValue)"
                + " @ \(Self.exact(details.rate * 100))% until \(Self.dayString(details.maturityDate))"
        case .gicRedemption(let details):
            line = "GIC redemption \(Self.exact(details.proceeds)) \(currency.rawValue)"
                + " (purchase \(Self.shortID(details.purchaseID)))"
        case .fxConversion(let details):
            line = "fx \(Self.exact(details.fromAmount)) \(details.fromCurrency.rawValue)"
                + " → \(Self.exact(details.toAmount)) \(currency.rawValue)"
        }
        if let fee, fee != 0 { line += " fee \(Self.exact(fee))" }
        return line
    }

    // MARK: Formatting helpers (deterministic, locale-free)

    /// Exact decimal text (Decimal.description, no rounding/scientific).
    static func exact(_ amount: Decimal) -> String {
        "\(amount)" // Decimal prints exactly; no scientific notation
    }

    /// First 8 UUID characters — the `tx list` ID spelling.
    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    /// `YYYY-MM-DD` (UTC) for embedding dates in summary lines.
    static func dayString(_ date: Date) -> String {
        TextFormat.day(date)
    }
}

extension Transaction.Kind {

    /// The kind's canonical name (also used for `--kind` matching).
    public var kindName: String {
        switch self {
        case .deposit: "deposit"
        case .withdrawal: "withdrawal"
        case .stockPurchase: "stockPurchase"
        case .stockSale: "stockSale"
        case .gicPurchase: "gicPurchase"
        case .gicRedemption: "gicRedemption"
        case .dividend: "dividend"
        case .fxConversion: "fxConversion"
        }
    }

    /// True when both sides describe the same kind of event (payloads
    /// may differ). Changing *family* is not an edit: it changes what
    /// the record is about, which must be delete + re-add.
    public func isSameFamily(as other: Transaction.Kind) -> Bool {
        kindName == other.kindName
    }
}