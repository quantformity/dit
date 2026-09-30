import Foundation

/// A financial account that holds positions (stocks, GICs, cash).
///
/// An account is *metadata*: it identifies where money is held and how it
/// should be reported. Positions live inside accounts once they are defined.
///
/// Every account designates a **reporting currency** — the currency in which
/// the account's total value and P&L are expressed. Positions denominated in
/// other currencies are converted into the reporting currency when the
/// account's totals are calculated.
public struct Account: Identifiable, Codable, Hashable, Sendable {
    // MARK: Identity

    /// Stable identity — the link key every transaction points back to.
    /// Decoding REQUIRES it (a record that cannot be attributed to an
    /// account is unusable), unlike the cosmetic fields below.
    public let id: UUID

    // MARK: Reporting

    /// The currency in which this account reports its value and P&L.
    public var reportingCurrency: Currency

    // MARK: Metadata (all optional)

    /// Display name, e.g. `"Desjardins TFSA"`.
    public var name: String?

    /// The institution holding the account, e.g. `"Wealthsimple"`, `"Desjardins"`.
    /// A natural grouping key when an account is held by one of several firms.
    public var institution: String?

    /// The account number.
    /// Consider storing only a masked suffix (e.g. last 4 digits) — this is PII.
    public var accountNumber: String?

    /// Whether holdings in this account are taxable.
    /// Defaults to `true` (conservative): an account is treated as
    /// non-registered / taxable until explicitly marked otherwise
    /// (e.g. TFSA, RRSP → `false`).
    public var taxable: Bool

    /// When the account was opened. Useful for holding-period calculations.
    public var openedDate: Date?

    /// When the account was closed. `nil` while the account is active;
    /// set for historical accounts so they don't count toward current totals.
    public var closedDate: Date?

    /// Free-form notes.
    public var notes: String?

    // MARK: Init

    /// Designated init. Every field has a default, so tests and
    /// imports can build an account compactly; CLI-created accounts get
    /// a fresh `UUID` and default to taxable + CAD reporting unless the
    /// flags say otherwise.
    public init(
        id: UUID = UUID(),
        reportingCurrency: Currency = .cad,
        name: String? = nil,
        institution: String? = nil,
        accountNumber: String? = nil,
        taxable: Bool = true,
        openedDate: Date? = nil,
        closedDate: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.reportingCurrency = reportingCurrency
        self.name = name
        self.institution = institution
        self.accountNumber = accountNumber
        self.taxable = taxable
        self.openedDate = openedDate
        self.closedDate = closedDate
        self.notes = notes
    }

    // MARK: Lenient decoding

    /// `id` is the relational link key, so a record missing it is
    /// unusable and decoding fails. Everything else degrades to its
    /// default, matching the init defaults — data saved before a field
    /// existed still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.reportingCurrency = try c.decodeIfPresent(Currency.self, forKey: .reportingCurrency) ?? .cad
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.institution = try c.decodeIfPresent(String.self, forKey: .institution)
        self.accountNumber = try c.decodeIfPresent(String.self, forKey: .accountNumber)
        self.taxable = try c.decodeIfPresent(Bool.self, forKey: .taxable) ?? true
        self.openedDate = try c.decodeIfPresent(Date.self, forKey: .openedDate)
        self.closedDate = try c.decodeIfPresent(Date.self, forKey: .closedDate)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    // MARK: Derived state

    /// Whether the account is still active.
    public var isActive: Bool { closedDate == nil }
}