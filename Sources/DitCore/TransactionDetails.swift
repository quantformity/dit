import Foundation

// MARK: - Stocks

/// Details of a stock (equity) trade.
///
/// Stores the two facts measured at the trade — quantity and per-share
/// price — and derives the total (`shares × price`, exact in `Decimal`).
/// The total is deliberately *not* stored: three stored numbers that must
/// agree with each other are just a consistency problem waiting to happen.
public struct StockDetails: Codable, Hashable, Sendable {
    /// Ticker symbol, normalized to uppercase (e.g. `"AAPL"`, `"SHOP.TO"`).
    public var ticker: String
    /// Exact quantity — `Decimal` because fractional shares exist
    /// (Wealthsimple, Questrade, and many others allow them).
    public var shares: Decimal
    /// Execution price per share, in the transaction's currency.
    public var price: Decimal

    /// Total trade value: `shares × price`.
    public var amount: Decimal { shares * price }

    /// Normalizes `ticker` (trimmed, uppercased) so symbols compare
    /// equal everywhere — the registry, filters, and P&L pairing all
    /// rely on this one normalization point.
    public init(ticker: String, shares: Decimal, price: Decimal) {
        self.ticker = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        self.shares = shares
        self.price = price
    }
}

// MARK: - GICs

/// Compounding frequency of a GIC contract.
public enum GICCompounding: String, Codable, CaseIterable, Sendable {
    case simple
    case annual
    case semiAnnual
    case monthly
    case daily
}

/// The GIC contract terms, recorded at purchase.
///
/// A stock is a market instrument that exists independently of your trade
/// (its price is external, changing data). A GIC, by contrast, *is* a
/// private contract between you and the issuer: its rate and term are fixed
/// when the contract is created, so they live on the purchase transaction
/// and never go stale.
public struct GICDetails: Codable, Hashable, Sendable {
    /// The issuer's product name, e.g. `"5-Year Prime+ GIC"`.
    public var product: String
    /// The amount locked in, in the transaction's currency.
    public var principal: Decimal
    /// Annual interest rate **as a fraction**: `0.047` = 4.7% p.a.
    /// Stored compute-ready; format as a percentage for display.
    public var rate: Decimal
    /// How the stated annual rate compounds. Display + future
    /// interest math only — redemption facts stay measured, never
    /// recomputed from this assumption.
    public var compounding: GICCompounding
    /// The contractual maturity date.
    /// Store the date, not a "5-year" label — issuers apply business-day
    /// conventions, so the date is the fact and the term is display-only.
    public var maturityDate: Date
    /// Whether the GIC can be redeemed before maturity.
    public var redeemable: Bool

    /// Records the contract exactly as agreed at purchase (the CLI's
    /// `--rate` is a percentage and is divided by 100 before it gets here).
    public init(
        product: String,
        principal: Decimal,
        rate: Decimal,
        compounding: GICCompounding,
        maturityDate: Date,
        redeemable: Bool
    ) {
        self.product = product
        self.principal = principal
        self.rate = rate
        self.compounding = compounding
        self.maturityDate = maturityDate
        self.redeemable = redeemable
    }
}

/// Details of a GIC redemption (at maturity or early).
public struct GICRedemptionDetails: Codable, Hashable, Sendable {
    /// The id of the GIC's purchase transaction (the purchase *is* the GIC).
    public var purchaseID: UUID
    /// The actual amount received. May differ from the computed maturity
    /// value after an early-redemption penalty.
    public var proceeds: Decimal

    /// Links the redemption to its purchase transaction.
    public init(purchaseID: UUID, proceeds: Decimal) {
        self.purchaseID = purchaseID
        self.proceeds = proceeds
    }
}

// MARK: - Dividends

/// A cash dividend received from a holding.
public struct DividendDetails: Codable, Hashable, Sendable {
    /// Paying instrument, normalized on init.
    public var ticker: String
    /// Total cash received, in the transaction's currency.
    public var amount: Decimal

    /// Normalizes `ticker` the same way ``StockDetails/init(ticker:shares:price:)`` does.
    public init(ticker: String, amount: Decimal) {
        self.ticker = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        self.amount = amount
    }
}

// MARK: - Currency conversion

/// A currency exchange within a single account.
///
/// Stores both measured facts (amount given up, amount received); the
/// implied rate — spread included — is derived from them.
public struct FXDetails: Codable, Hashable, Sendable {
    /// The currency given up. Must differ from the transaction's currency.
    public var fromCurrency: Currency
    /// The amount given up, in `fromCurrency`.
    public var fromAmount: Decimal
    /// The amount received, in the transaction's currency.
    public var toAmount: Decimal

    /// Implied exchange rate: `toAmount / fromAmount`
    /// (units of the transaction's currency per unit of `fromCurrency`).
    /// `nil` when `fromAmount` is zero.
    public var rate: Decimal? {
        fromAmount == 0 ? nil : toAmount / fromAmount
    }

    /// Records both measured legs; the rate is never entered, only
    /// derived (see ``rate``).
    public init(fromCurrency: Currency, fromAmount: Decimal, toAmount: Decimal) {
        self.fromCurrency = fromCurrency
        self.fromAmount = fromAmount
        self.toAmount = toAmount
    }
}