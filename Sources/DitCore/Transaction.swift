import Foundation

/// A single financial event that happened in an account.
///
/// Transactions are the **first-class source of truth** in this system:
/// holdings, account balances, and P&L are all *derived* from the
/// transaction history — never stored independently.
///
/// Every transaction shares:
/// - `date` — when it happened
/// - `accountID` — where it happened (a reference to `Account`, not a copy)
/// - `currency` — the currency the transaction's amounts are expressed in
/// - `kind` — what type of event it was
///
/// The money lives inside the `kind` payload rather than in a shared stored
/// `amount`, because what "amount" *means* depends on the event: a cash flow
/// stores its amount directly, while a stock trade derives it from
/// `shares × price`. The common access point is the computed `amount`.
public struct Transaction: Identifiable, Codable, Hashable, Sendable {
    /// Stable identity (the `tx list` ID column; prefixes resolve via
    /// ``TransactionRef``).
    public let id: UUID
    /// When the event happened (account-local calendar date).
    public var date: Date
    /// Where it happened — a reference to an `Account`, not a copy.
    public var accountID: UUID
    /// The currency the event's amounts are expressed in.
    public var currency: Currency
    /// What type of event it was (and its payload).
    public var kind: Kind
    /// Brokerage fee, in `currency`, if any.
    /// Not included in the kind's amounts — see `cashImpact`.
    public var fee: Decimal?
    /// Free-form user note about the event.
    public var notes: String?
    /// The institution's own reference for this event (e.g. a trade
    /// confirmation number). Enables de-duplication when importing
    /// statement CSVs.
    public var externalID: String?

    /// Memberwise init; `id` defaults to a fresh UUID so callers
    /// rarely pass one (tests pin ids for reproducibility).
    public init(
        id: UUID = UUID(),
        date: Date,
        accountID: UUID,
        currency: Currency,
        kind: Kind,
        fee: Decimal? = nil,
        notes: String? = nil,
        externalID: String? = nil
    ) {
        self.id = id
        self.date = date
        self.accountID = accountID
        self.currency = currency
        self.kind = kind
        self.fee = fee
        self.notes = notes
        self.externalID = externalID
    }

    // MARK: Derived values

    /// The notional value of this transaction in `currency`.
    /// Derived from the kind — see `Kind` for what each payload contributes.
    public var amount: Decimal {
        switch kind {
        case .deposit(let amount), .withdrawal(let amount):
            return amount
        case .stockPurchase(let details), .stockSale(let details):
            return details.amount
        case .gicPurchase(let details):
            return details.principal
        case .gicRedemption(let details):
            return details.proceeds
        case .dividend(let details):
            return details.amount
        case .fxConversion(let details):
            return details.toAmount
        }
    }

    /// The effect on the account's cash balance, in `currency`:
    /// positive adds cash, negative removes it.
    /// Fees are included (added to outflows, deducted from inflows).
    public var cashImpact: Decimal {
        switch kind {
        case .deposit(let amount):
            return amount
        case .withdrawal(let amount):
            return -amount
        case .stockPurchase(let details):
            return -(details.amount + (fee ?? 0))
        case .stockSale(let details):
            return details.amount - (fee ?? 0)
        case .gicPurchase(let details):
            return -(details.principal + (fee ?? 0))
        case .gicRedemption(let details):
            return details.proceeds - (fee ?? 0)
        case .dividend(let details):
            return details.amount - (fee ?? 0)
        case .fxConversion(let details):
            return details.toAmount - (fee ?? 0)
        }
    }

    /// The ticker involved in this event, if any.
    /// Useful for grouping a ticker's trade history.
    public var ticker: String? {
        switch kind {
        case .stockPurchase(let details), .stockSale(let details):
            return details.ticker
        case .dividend(let details):
            return details.ticker
        default:
            return nil
        }
    }

    // MARK: Kind

    /// The type of financial event.
    ///
    /// Each payload carries its own monetary facts. Amounts are the
    /// *measured* facts of the event and should be non-negative; direction
    /// (money in vs. out) is conveyed by the kind, not by sign.
    public enum Kind: Codable, Hashable, Sendable {
        /// Cash added to the account (contribution).
        case deposit(amount: Decimal)
        /// Cash removed from the account.
        case withdrawal(amount: Decimal)

        /// Bought shares of a marketable security.
        case stockPurchase(StockDetails)
        /// Sold shares of a marketable security.
        case stockSale(StockDetails)

        /// Bought a GIC. The purchase transaction *is* the GIC: contract
        /// terms (rate, term, compounding) are fixed at purchase and live
        /// here for the life of the instrument.
        case gicPurchase(GICDetails)
        /// Redeemed a GIC (at maturity or early).
        case gicRedemption(GICRedemptionDetails)

        /// Cash dividend received from a holding.
        case dividend(DividendDetails)

        /// Exchange of one currency for another within the same account.
        /// The transaction's `currency` is the *to* currency.
        case fxConversion(FXDetails)
    }
}