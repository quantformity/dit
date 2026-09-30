import Foundation

/// An equity position in an account, tracked with the average-cost method.
struct PositionKey: Hashable {
    let currency: Currency
    let symbol: String
}

public struct StockPosition: Hashable, Sendable {
    /// Currency the shares trade and are valued in.
    public let currency: Currency
    /// Normalized ticker symbol.
    public let symbol: String
    /// Whole shares currently held (can be negative — see ``UntrackedShort``
    /// for sales beyond the tracked long, which are reported separately).
    public let shares: Decimal
    /// Average total cost per share, **fees included**.
    public let averageCostPerShare: Decimal

    /// Total cost of the position (`shares × averageCostPerShare`).
    public var costBasis: Decimal { shares * averageCostPerShare }

    /// Internal: built only by ``AccountBalances/compute(quotes:)`` and
    /// the cross-account rollup in ``Portfolio/summary(displayCurrency:quotes:fx:)``.
    init(currency: Currency, symbol: String, shares: Decimal, averageCostPerShare: Decimal) {
        self.currency = currency
        self.symbol = symbol
        self.shares = shares
        self.averageCostPerShare = averageCostPerShare
    }
}

/// A sale that sold more than the account held, aggregated per
/// `(currency, symbol)`. The cash it moved is booked in full (that is
/// a fact), but the short position it created is *not tracked* — a
/// `nil`-valued liability. Listing it keeps the totals honest about
/// being incomplete instead of quietly pretending the account is flat.
public struct UntrackedShort: Hashable, Sendable {
    /// Currency the short exposure sits in.
    public let currency: Currency
    /// Normalized ticker symbol that was oversold.
    public let symbol: String
    /// Shares sold beyond the tracked long.
    public let shares: Decimal

    /// Memberwise init (built by the replay and the summary rollup).
    public init(currency: Currency, symbol: String, shares: Decimal) {
        self.currency = currency
        self.symbol = symbol
        self.shares = shares
    }
}

/// A snapshot of what an account holds, computed from its transaction history.
///
/// Everything here is *derived* — nothing is stored with the account:
///
/// - `cashByCurrency` / `cash` — remaining cash per currency, and combined
///   in the account's reporting currency when convertible
/// - `positions` — shares held per ticker, average cost inclusive of fees
/// - `gicValueByCurrency` / `gicValue` — principal of live (unredeemed) GICs,
///   held at par (accrued interest is not modeled until redemption)
/// - `realizedPnLByCurrency` / `realizedPnL` — booked gains/losses: stock
///   sales, GIC redemptions, and dividends (fee-adjusted)
/// - `dividendsByCurrency` / `dividends` — dividends received (also inside
///   realized P&L)
/// - `unrealizedPnLByCurrency` / `unrealizedPnL` — `(lastPrice − averageCost) × shares`,
///   computed only for positions that received a quote
/// - `dayChangeByCurrency` / `dayChange` — `(quote − previousClose) × shares`,
///   computed only for positions whose quote pairs with an earlier stored
///   close (see ``DayPricePair``)
/// - `totalValue` — cash + position value (quote when given, else cost basis)
///   + live GIC principal, in the reporting currency
///
/// Components denominated outside the reporting currency combine only when a
/// `rate` closure can convert them; otherwise the combined value is `nil`
/// while the per-currency breakdowns stay exact.
///
/// Single-currency invariant (exact):
/// `cash + Σ costBasis + gicValue == deposits − withdrawals + realizedPnL`.
/// When `untrackedShorts` is non-empty the account sold shares it did
/// not hold; the cash moved, but the short liability is outside the
/// model, so aggregate totals are knowingly incomplete there.
public struct AccountBalances: Hashable, Sendable {
    /// The account this snapshot belongs to (identity + reporting
    /// currency; the balances themselves are all derived).
    public let account: Account

    /// Exact per-currency cash after replay (zeros omitted).
    public var cashByCurrency: [Currency: Decimal]
    /// Remaining cash in the reporting currency; `nil` if a foreign
    /// currency component could not be converted.
    public var cash: Decimal?

    /// Positions with nonzero tracked shares, sorted for stable display.
    public var positions: [StockPosition]

    /// Live (unredeemed) GIC principal per currency.
    public var gicValueByCurrency: [Currency: Decimal]
    /// Live GIC principal in the reporting currency; `nil` if not convertible.
    public var gicValue: Decimal?

    /// Booked gains/losses per currency (sales, redemptions, dividends).
    public var realizedPnLByCurrency: [Currency: Decimal]
    /// Booked P&L in the reporting currency; `nil` if not convertible.
    public var realizedPnL: Decimal?

    /// Dividends received per currency (also counted inside realized P&L).
    public var dividendsByCurrency: [Currency: Decimal]
    /// Dividends in the reporting currency; `nil` if not convertible.
    public var dividends: Decimal?

    /// Mark-to-market P&L per currency, only for quoted positions.
    public var unrealizedPnLByCurrency: [Currency: Decimal]
    /// `nil` when no position received a quote.
    public var unrealizedPnL: Decimal?

    /// One-day P&L per currency (native amounts, exact): each quoted
    /// position's value change against that ticker's previous available
    /// close. `[:]` when no position has both a quote and a prior close.
    public var dayChangeByCurrency: [Currency: Decimal] = [:]
    /// The same changes in the reporting currency; `nil` when there is
    /// no daily data or a component could not be converted.
    public var dayChange: Decimal? = nil

    /// Whole-account value in the reporting currency; `nil` if any
    /// component could not be converted.
    public var totalValue: Decimal?

    /// Sales that went below zero — unmodeled short exposure, flagged
    /// so `totalValue` is never silently incomplete. The single-
    /// currency invariant holds only when this is empty.
    public var untrackedShorts: [UntrackedShort] = []
}

extension AccountBalances {
    /// Compute an account's balances from its full transaction history.
    ///
    /// - Parameters:
    ///   - account: the account to analyze.
    ///   - transactions: its transactions, in any order (they are sorted by date).
    ///   - rate: optional converter `rate(from, to)` — units of `to` per
    ///     unit of `from`. A rate supplied in the reverse direction is
    ///     reciprocated. `nil` → foreign-currency components stay uncombined.
    ///   - lastPrice: optional provider `lastPrice(currency, symbol)`.
    ///     Unquoted positions fall back to cost basis in `totalValue` and
    ///     are excluded from `unrealizedPnL`.
    ///   - dayPrices: optional provider `dayPrices(currency, symbol)`
    ///     pairing the valuation price with the ticker's previous close.
    ///     A pair is used only when its `current` equals the quote the
    ///     position was actually valued at — a day change must describe
    ///     the number displayed, never a different observation.
    public static func compute(
        account: Account,
        transactions: [Transaction],
        rate: ((Currency, Currency) -> Decimal?)? = nil,
        lastPrice: ((Currency, String) -> Decimal?)? = nil,
        dayPrices: ((Currency, String) -> DayPricePair?)? = nil
    ) -> AccountBalances {
        let reporting = account.reportingCurrency
        let history = transactions.sorted { $0.date < $1.date }

        var cash: [Currency: Decimal] = [:]
        // (currency, symbol) → (shares, totalCost)
        var held: [PositionKey: (shares: Decimal, cost: Decimal)] = [:]
        // Live GIC purchase id → (currency, principal)
        var activeGICs: [UUID: (currency: Currency, principal: Decimal)] = [:]
        var realized: [Currency: Decimal] = [:]
        var dividends: [Currency: Decimal] = [:]
        // (currency, symbol) → shares sold beyond the tracked long.
        var soldBeyondZero: [PositionKey: Decimal] = [:]

        for tx in history {
            // Cash: fxConversion is the only kind whose impact spans two currencies.
            switch tx.kind {
            case .fxConversion(let details):
                cash[details.fromCurrency, default: 0] -= details.fromAmount
                cash[tx.currency, default: 0] += details.toAmount - (tx.fee ?? 0)
            default:
                cash[tx.currency, default: 0] += tx.cashImpact
            }

            switch tx.kind {
            case .stockPurchase(let details):
                let key = PositionKey(currency: tx.currency, symbol: details.ticker)
                let current = held[key] ?? (shares: 0, cost: 0)
                held[key] = (
                    shares: current.shares + details.shares,
                    cost: current.cost + details.amount + (tx.fee ?? 0)
                )

            case .stockSale(let details):
                let key = PositionKey(currency: tx.currency, symbol: details.ticker)
                let current = held[key] ?? (shares: 0, cost: 0)
                let costOfSharesSold: Decimal
                if current.shares > 0, details.shares >= current.shares {
                    costOfSharesSold = current.cost // full liquidation: exact
                } else if current.shares > 0 {
                    costOfSharesSold = current.cost * details.shares / current.shares
                } else {
                    costOfSharesSold = 0 // sale with no tracked position
                }
                realized[tx.currency, default: 0] += (details.amount - (tx.fee ?? 0)) - costOfSharesSold
                // Anything sold beyond the tracked long is untracked
                // short exposure: record that it happened.
                if details.shares > max(0, current.shares) {
                    soldBeyondZero[key, default: 0] += details.shares - max(0, current.shares)
                }
                held[key] = (
                    shares: max(0, current.shares - details.shares),
                    cost: max(0, current.cost - costOfSharesSold)
                )

            case .gicPurchase(let details):
                activeGICs[tx.id] = (currency: tx.currency, principal: details.principal)

            case .gicRedemption(let details):
                if let gic = activeGICs.removeValue(forKey: details.purchaseID) {
                    realized[tx.currency, default: 0] += (details.proceeds - (tx.fee ?? 0)) - gic.principal
                }
                // A redemption without its purchase in this history is
                // skipped: inventing a principal would fabricate P&L.

            case .dividend(let details):
                let net = details.amount - (tx.fee ?? 0)
                realized[tx.currency, default: 0] += net
                dividends[tx.currency, default: 0] += net

            default:
                break
            }
        }

        // Positions, sorted (currency, symbol) for stable output.
        let positions = held
            .filter { $0.value.shares > 0 } // fully liquidated tickers disappear
            .map { key, value in
                StockPosition(
                    currency: key.currency,
                    symbol: key.symbol,
                    shares: value.shares,
                    averageCostPerShare: value.shares > 0 ? value.cost / value.shares : 0
                )
            }
            .sorted { ($0.currency, $0.symbol) < ($1.currency, $1.symbol) }

        // Untracked shorts, sorted for stable output.
        let untrackedShorts = soldBeyondZero
            .map { key, shares in
                UntrackedShort(currency: key.currency, symbol: key.symbol, shares: shares)
            }
            .sorted { ($0.currency, $0.symbol) < ($1.currency, $1.symbol) }

        // Live GICs at par.
        var gicValue: [Currency: Decimal] = [:]
        for gic in activeGICs.values {
            gicValue[gic.currency, default: 0] += gic.principal
        }

        // Position value and unrealized P&L (quoted positions only).
        var positionValue: [Currency: Decimal] = [:]
        var unrealized: [Currency: Decimal] = [:]
        var anyQuoted = false
        // One-day P&L: the quote against the previous available close,
        // in each position's own currency.
        var dayChange: [Currency: Decimal] = [:]
        var anyDayChange = false
        for position in positions {
            let quote = lastPrice?(position.currency, position.symbol)
            positionValue[position.currency, default: 0] += position.shares * (quote ?? position.averageCostPerShare)
            if let quote {
                anyQuoted = true
                unrealized[position.currency, default: 0] += (quote - position.averageCostPerShare) * position.shares
                if let pair = dayPrices?(position.currency, position.symbol),
                   pair.current == quote, pair.previous > 0 {
                    anyDayChange = true
                    dayChange[position.currency, default: 0] += (quote - pair.previous) * position.shares
                }
            }
        }

        /// Combine per-currency amounts into the reporting currency.
        /// `nil` when `rate` is missing or cannot convert some component.
        func combined(_ values: [Currency: Decimal]) -> Decimal? {
            var total: Decimal = 0
            for (currency, amount) in values {
                if amount == 0 || currency == reporting {
                    total += amount
                    continue
                }
                guard let rate else { return nil }
                if let direct = rate(currency, reporting) {
                    total += amount * direct
                } else if let inverse = rate(reporting, currency), inverse != 0 {
                    total += amount / inverse
                } else {
                    return nil
                }
            }
            return total
        }

        let cashTotal = combined(cash)
        let positionTotal = combined(positionValue)
        let gicTotal = combined(gicValue)
        let totalValue: Decimal? = {
            guard let cashTotal, let positionTotal, let gicTotal else { return nil }
            return cashTotal + positionTotal + gicTotal
        }()

        return AccountBalances(
            account: account,
            cashByCurrency: cash,
            cash: cashTotal,
            positions: positions,
            gicValueByCurrency: gicValue,
            gicValue: gicTotal,
            realizedPnLByCurrency: realized,
            realizedPnL: combined(realized),
            dividendsByCurrency: dividends,
            dividends: combined(dividends),
            unrealizedPnLByCurrency: unrealized,
            unrealizedPnL: anyQuoted ? combined(unrealized) : nil,
            dayChangeByCurrency: dayChange,
            dayChange: anyDayChange ? combined(dayChange) : nil,
            totalValue: totalValue,
            untrackedShorts: untrackedShorts
        )
    }
}

// MARK: - Portfolio entry points

/// Conversion rate: units of the second currency per one unit of the first.
public typealias FXRate = (Currency, Currency) -> Decimal?
/// Last price of a symbol quoted in the given currency.
public typealias LastPrice = (Currency, String) -> Decimal?

/// A price pair behind the one-day P&L: `current` is the price the
/// position is valued at, `previous` the latest observation strictly
/// older than that price's own date, and `modelBaseline` records
/// whether that baseline was derived (backfilled) rather than observed
/// — derived baselines track an underlying proxy, so consumers can
/// label the resulting change instead of presenting it as a real
/// two-market-day comparison.
/// Current close and its comparison baseline (both in one currency).
public struct DayPricePair: Hashable, Sendable {
    /// The as-of (or latest stored) close.
    public let current: Decimal
    /// The earlier close `current` is compared against.
    public let previous: Decimal
    /// true when `previous` is a derived/proxy baseline, not a real
    /// earlier close of this same instrument.
    public let modelBaseline: Bool

    /// Memberwise init; `modelBaseline` defaults to false (observed).
    public init(current: Decimal, previous: Decimal, modelBaseline: Bool = false) {
        self.current = current
        self.previous = previous
        self.modelBaseline = modelBaseline
    }

    /// The day's price move as a fraction (`0.012` = +1.2%).
    /// `nil` when the baseline price is not positive.
    public var fraction: Decimal? {
        previous > 0 ? (current - previous) / previous : nil
    }
}

extension Portfolio {
    /// Find an account by its display name — trimmed and case-insensitive.
    /// The first match wins if several accounts share a name.
    public func account(named name: String) -> Account? {
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return nil }
        return accounts.first {
            $0.name?.trimmingCharacters(in: .whitespaces).lowercased() == target
        }
    }

    /// Cash remaining, positions, and P&L for the account with `id`.
    /// `nil` when no such account exists in the portfolio.
    public func balance(
        forAccountID id: UUID,
        rate: FXRate? = nil,
        lastPrice: LastPrice? = nil
    ) -> AccountBalances? {
        guard let account = self[account: id] else { return nil }
        return .compute(
            account: account,
            transactions: transactions(in: id),
            rate: rate,
            lastPrice: lastPrice
        )
    }

    /// Cash remaining, positions, and P&L for the account called `name`
    /// (trimmed, case-insensitive), looked up in the portfolio.
    public func balance(
        forAccountName name: String,
        rate: FXRate? = nil,
        lastPrice: LastPrice? = nil
    ) -> AccountBalances? {
        guard let account = account(named: name) else { return nil }
        return .compute(
            account: account,
            transactions: transactions(in: account.id),
            rate: rate,
            lastPrice: lastPrice
        )
    }
}
/// Provider of one-day price pairs: `dayPrices(currency, symbol)`.
public typealias DayPrices = (Currency, String) -> DayPricePair?
