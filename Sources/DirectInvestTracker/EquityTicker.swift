import Foundation

/// Metadata for a listed equity instrument.
///
/// The **symbol is the identity**: in Yahoo Finance format (`"AAPL"`,
/// `"SHOP.TO"`), it is simultaneously
/// - the key that links `Transaction`s to this instrument (transactions
///   store the symbol in `StockDetails` / `DividendDetails`), and
/// - the Yahoo Finance quote key for the stock.
///
/// Entries are *optional enrichment*: a transaction for a symbol that has
/// no registry entry still works — the registry only adds display metadata.
///
/// What is deliberately **not** stored here: shares held, cost basis, and
/// price. Those are derived (positions from the transaction history,
/// price from live quotes) and would be a second source of truth.
public struct EquityTicker: Identifiable, Codable, Hashable, Sendable {
    /// Yahoo-format ticker symbol, normalized to uppercase.
    /// This is the identity of the instrument.
    public var symbol: String

    /// Common name, e.g. `"Shopify Inc."`.
    public var name: String?

    /// The currency the stock *trades in* (TSX → CAD, NYSE → USD).
    /// Distinct from any account's reporting currency.
    /// Defaults to `.unknown` until a quote or manual entry confirms it.
    public var currency: Currency

    /// Free-form notes.
    public var notes: String?

    public var id: String { symbol }

    public init(
        symbol: String,
        name: String? = nil,
        currency: Currency = .unknown,
        notes: String? = nil
    ) {
        self.symbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        self.name = name
        self.currency = currency
        self.notes = notes
    }
}