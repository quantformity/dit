import Foundation

/// One row of the portfolio's holdings table: an equity position
/// consolidated across all accounts, keyed by `(symbol, currency)` —
/// the same unit an account tracks positions in.
///
/// The same symbol held in two *different* currencies appears as two
/// rows (the values cannot be added); the same symbol held in several
/// accounts (same currency) appears once, with a weighted average cost
/// and the list of accounts that hold it.
public struct TickerHolding: Hashable, Sendable {
    public let symbol: String
    /// Common name from the ticker registry, when registered.
    public let name: String?
    /// The currency the shares are held and (when quoted) priced in.
    public let currency: Currency

    public let shares: Decimal
    /// Weighted average total cost per share, fees included.
    public let averageCostPerShare: Decimal

    /// Total cost of the holding (`shares × averageCostPerShare`).
    public var costBasis: Decimal { shares * averageCostPerShare }

    /// Market value in `currency` — quote-based when the underlying
    /// positions received quotes, cost basis otherwise.
    public let value: Decimal

    /// `(quote − averageCost) × shares`, summed over the quoted
    /// underlying positions; `nil` when none of them received a quote.
    public let unrealizedPnL: Decimal?

    /// Display names of the accounts that hold this position.
    public let accountNames: [String]

    /// Build a holding from its parts (`cost` = total cost, fees
    /// included; the weighted average cost is derived from it).
    public init(
        symbol: String,
        name: String?,
        currency: Currency,
        shares: Decimal,
        cost: Decimal,
        value: Decimal,
        unrealizedPnL: Decimal?,
        accountNames: [String]
    ) {
        self.symbol = symbol
        self.name = name
        self.currency = currency
        self.shares = shares
        self.averageCostPerShare = shares > 0 ? cost / shares : 0
        self.value = value
        self.unrealizedPnL = unrealizedPnL
        self.accountNames = accountNames
    }
}

/// A portfolio-wide snapshot: every account's ``AccountBalances`` summed
/// into per-currency totals, plus a consolidated holdings table.
///
/// Everything here is *derived* — from the transaction log, and from
/// live market data when `rate`/`lastPrice` were supplied. The numbers
/// come in two layers:
///
/// - **Per-currency sums** (`cashByCurrency`, `positionValueByCurrency`,
///   …) — exact, no conversion involved. These stay trustworthy even
///   when no FX rates are available at all.
/// - **Combined values** (`cash`, `positionValue`, …) — the per-currency
///   sums expressed in `displayCurrency`. Each is `nil` when the `rate`
///   closure could not convert some component; the per-currency
///   breakdown remains exact in that case.
///
/// `unrealizedPnL` is `nil` (not 0) when no position received a quote —
/// "no data" is a different answer than "no gain".
public struct PortfolioSummary: Hashable, Sendable {
    /// The currency combined values are expressed in.
    public let displayCurrency: Currency

    /// Per-account breakdowns, sorted by their value in
    /// `displayCurrency` (largest first; accounts whose value cannot be
    /// converted sort last).
    public let accounts: [AccountBalances]

    /// Open equity positions consolidated across all accounts, sorted by
    /// value (largest first, symbol to break ties).
    public let holdings: [TickerHolding]

    // MARK: Per-currency (exact — no conversion involved)

    public let cashByCurrency: [Currency: Decimal]
    public let positionValueByCurrency: [Currency: Decimal]
    public let gicValueByCurrency: [Currency: Decimal]
    public let realizedPnLByCurrency: [Currency: Decimal]
    public let dividendsByCurrency: [Currency: Decimal]
    public let unrealizedPnLByCurrency: [Currency: Decimal]

    /// Total account value per currency: cash + position value +
    /// live GIC principal.
    public var valueByCurrency: [Currency: Decimal] {
        var out: [Currency: Decimal] = [:]
        for dict in [cashByCurrency, positionValueByCurrency, gicValueByCurrency] {
            for (currency, value) in dict { out[currency, default: 0] += value }
        }
        return out
    }

    // MARK: Combined in `displayCurrency` (`nil` when not convertible)

    public let cash: Decimal?
    public let positionValue: Decimal?
    public let gicValue: Decimal?
    public let realizedPnL: Decimal?
    public let dividends: Decimal?
    /// `nil` when no position received a quote.
    public let unrealizedPnL: Decimal?
    /// Cash + position value + live GICs, in `displayCurrency`; `nil`
    /// when any component could not be converted.
    public let totalValue: Decimal?

    public init(
        displayCurrency: Currency,
        accounts: [AccountBalances],
        holdings: [TickerHolding],
        cashByCurrency: [Currency: Decimal],
        positionValueByCurrency: [Currency: Decimal],
        gicValueByCurrency: [Currency: Decimal],
        realizedPnLByCurrency: [Currency: Decimal],
        dividendsByCurrency: [Currency: Decimal],
        unrealizedPnLByCurrency: [Currency: Decimal],
        cash: Decimal?,
        positionValue: Decimal?,
        gicValue: Decimal?,
        realizedPnL: Decimal?,
        dividends: Decimal?,
        unrealizedPnL: Decimal?,
        totalValue: Decimal?
    ) {
        self.displayCurrency = displayCurrency
        self.accounts = accounts
        self.holdings = holdings
        self.cashByCurrency = cashByCurrency
        self.positionValueByCurrency = positionValueByCurrency
        self.gicValueByCurrency = gicValueByCurrency
        self.realizedPnLByCurrency = realizedPnLByCurrency
        self.dividendsByCurrency = dividendsByCurrency
        self.unrealizedPnLByCurrency = unrealizedPnLByCurrency
        self.cash = cash
        self.positionValue = positionValue
        self.gicValue = gicValue
        self.realizedPnL = realizedPnL
        self.dividends = dividends
        self.unrealizedPnL = unrealizedPnL
        self.totalValue = totalValue
    }
}

// MARK: - Portfolio entry point

extension Portfolio {
    /// A portfolio-wide snapshot across all accounts.
    ///
    /// - Parameters:
    ///   - displayCurrency: currency for the combined values
    ///     (defaults to CAD — the display currency; conversion itself
    ///     routes through whatever the `rate` closure knows, USD hub or
    ///     not).
    ///   - rate: optional converter `rate(from, to)` — units of `to`
    ///     per unit of `from` (a reverse-direction rate is reciprocated).
    ///     `nil` → foreign-currency components stay uncombined
    ///     (`nil` combined values, exact per-currency sums).
    ///   - lastPrice: optional provider `lastPrice(currency, symbol)`.
    ///     Unquoted positions are valued at cost basis and excluded
    ///     from P&L.
    public func summary(
        displayCurrency: Currency = .cad,
        rate: FXRate? = nil,
        lastPrice: LastPrice? = nil
    ) -> PortfolioSummary {
        let balances = accounts.map { account in
            AccountBalances.compute(
                account: account,
                transactions: transactions(in: account.id),
                rate: rate,
                lastPrice: lastPrice
            )
        }

        // Accounts sorted by their value *in the display currency*,
        // largest first — a raw comparison of totals would pit CAD
        // values against USD values. Accounts whose value cannot be
        // converted sort last (stable within that).
        func displayValue(_ balance: AccountBalances) -> Decimal? {
            guard let value = balance.totalValue else { return nil }
            let reporting = balance.account.reportingCurrency
            if reporting == displayCurrency { return value }
            guard let rate else { return nil }
            if let direct = rate(reporting, displayCurrency) { return value * direct }
            if let inverse = rate(displayCurrency, reporting), inverse != 0 { return value / inverse }
            return nil
        }
        let sortedAccounts = balances
            .enumerated()
            .sorted { left, right in
                switch (displayValue(left.element), displayValue(right.element)) {
                case let (l?, r?):
                    // Ties (including exact equal values) keep
                    // portfolio order; `sort` is not stable.
                    return l != r ? l > r : left.offset < right.offset
                case (nil, .some): return false     // unconvertible sorts last
                case (.some, nil): return true
                case (nil, nil): return left.offset < right.offset
                }
            }
            .map(\.element)

        // --- Holdings pass -------------------------------------------------
        struct Accumulator {
            var shares: Decimal = 0
            var cost: Decimal = 0
            var value: Decimal = 0
            var unrealized: Decimal = 0
            var anyQuoted = false
            var accountNames: [String] = []
        }
        var holdingsByKey: [PositionKey: Accumulator] = [:]
        var positionValueByCurrency: [Currency: Decimal] = [:]

        for balance in balances {
            for position in balance.positions {
                let quote = lastPrice?(position.currency, position.symbol)
                let price = quote ?? position.averageCostPerShare
                positionValueByCurrency[position.currency, default: 0] += position.shares * price

                let key = PositionKey(currency: position.currency, symbol: position.symbol)
                var acc = holdingsByKey[key] ?? Accumulator()
                acc.shares += position.shares
                acc.cost += position.costBasis
                acc.value += position.shares * price
                if let quote {
                    acc.anyQuoted = true
                    acc.unrealized += (quote - position.averageCostPerShare) * position.shares
                }
                acc.accountNames.append(displayName(of: balance.account))
                holdingsByKey[key] = acc
            }
        }

        let holdings = holdingsByKey.map { key, acc in
            TickerHolding(
                symbol: key.symbol,
                name: self[ticker: key.symbol]?.name,
                currency: key.currency,
                shares: acc.shares,
                cost: acc.cost,
                value: acc.value,
                unrealizedPnL: acc.anyQuoted ? acc.unrealized : nil,
                accountNames: Array(Set(acc.accountNames)).sorted()
            )
        }
        .sorted { left, right in
            left.value != right.value ? left.value > right.value : left.symbol < right.symbol
        }

        // --- Per-currency sums (exact) --------------------------------------
        func sum(_ dicts: [[Currency: Decimal]]) -> [Currency: Decimal] {
            var out: [Currency: Decimal] = [:]
            for dict in dicts {
                for (currency, value) in dict { out[currency, default: 0] += value }
            }
            return out
        }
        let cashByCurrency = sum(balances.map(\.cashByCurrency))
        let gicValueByCurrency = sum(balances.map(\.gicValueByCurrency))
        let realizedPnLByCurrency = sum(balances.map(\.realizedPnLByCurrency))
        let dividendsByCurrency = sum(balances.map(\.dividendsByCurrency))
        let unrealizedPnLByCurrency = sum(balances.map(\.unrealizedPnLByCurrency))
        let anyQuoted = holdingsByKey.values.contains(where: { $0.anyQuoted })

        // --- Combined in the display currency --------------------------------
        /// Convert per-currency amounts into `displayCurrency`. Returns
        /// `nil` when a foreign component cannot be converted.
        func toDisplay(_ values: [Currency: Decimal]) -> Decimal? {
            var total: Decimal = 0
            for (currency, amount) in values {
                if amount == 0 || currency == displayCurrency {
                    total += amount
                    continue
                }
                guard let rate else { return nil }
                if let direct = rate(currency, displayCurrency) {
                    total += amount * direct
                } else if let inverse = rate(displayCurrency, currency), inverse != 0 {
                    total += amount / inverse
                } else {
                    return nil
                }
            }
            return total
        }

        let cashTotal = toDisplay(cashByCurrency)
        let positionTotal = toDisplay(positionValueByCurrency)
        let gicTotal = toDisplay(gicValueByCurrency)
        let totalValue: Decimal? = {
            guard let cashTotal, let positionTotal, let gicTotal else { return nil }
            return cashTotal + positionTotal + gicTotal
        }()

        return PortfolioSummary(
            displayCurrency: displayCurrency,
            accounts: sortedAccounts,
            holdings: holdings,
            cashByCurrency: cashByCurrency,
            positionValueByCurrency: positionValueByCurrency,
            gicValueByCurrency: gicValueByCurrency,
            realizedPnLByCurrency: realizedPnLByCurrency,
            dividendsByCurrency: dividendsByCurrency,
            unrealizedPnLByCurrency: unrealizedPnLByCurrency,
            cash: cashTotal,
            positionValue: positionTotal,
            gicValue: gicTotal,
            realizedPnL: toDisplay(realizedPnLByCurrency),
            dividends: toDisplay(dividendsByCurrency),
            unrealizedPnL: anyQuoted ? toDisplay(unrealizedPnLByCurrency) : nil,
            totalValue: totalValue
        )
    }

    /// A summary valued against the observations in `cache`: FX rates
    /// via ``MarketDataCache/rateValue(from:to:)`` (stored rates are
    /// used regardless of age — FX moves slowly), quotes via
    /// ``MarketDataCache/lastPrice(for:symbol:maxAge:now:)`` (fresh
    /// quotes only; positions without a fresh quote fall back to cost
    /// basis and are excluded from P&L).
    public func summary(
        from cache: MarketDataCache,
        displayCurrency: Currency = .cad,
        now: Date = .now
    ) -> PortfolioSummary {
        summary(
            displayCurrency: displayCurrency,
            rate: cache.rateValue,
            lastPrice: { currency, symbol in cache.lastPrice(for: currency, symbol: symbol, now: now) }
        )
    }
}

/// A stable display name for an account: its name when set, else a
/// short id prefix (accounts without names still show up distinctly).
private func displayName(of account: Account) -> String {
    if let name = account.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
        return name
    }
    return "Account \(account.id.uuidString.prefix(4))"
}