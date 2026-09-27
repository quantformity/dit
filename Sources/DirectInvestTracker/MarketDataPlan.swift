import Foundation

/// The market data a portfolio needs in order to value itself:
///
/// - `symbols` — every ticker with an open position (quotes), and
/// - `fxCurrencies` — every currency involved that is *not* the hub
///   (FX rates against the hub: with the USD hub, one rate fetch per
///   currency covers every pair, composed at lookup time by
///   ``MarketDataCache/routedRate(from:to:hub:)``).
public struct MarketDataPlan: Hashable, Sendable {
    /// Symbols with open positions, normalized and de-duplicated.
    public let symbols: [String]
    /// Currencies that need a rate against `hub` (sorted; the hub and
    /// `.unknown` are excluded).
    public let fxCurrencies: [Currency]
    /// The currency `fxCurrencies` are rates against.
    public let hub: Currency

    public init(symbols: [String], fxCurrencies: [Currency], hub: Currency) {
        self.symbols = symbols
        self.fxCurrencies = fxCurrencies
        self.hub = hub
    }
}

extension Portfolio {
    /// What this portfolio needs to value itself, for the given
    /// display currency.
    ///
    /// Currencies are collected from the derived balances (cash,
    /// positions, live GICs) plus the display currency; only non-hub
    /// currencies need a fetch. A portfolio whose money all sits in
    /// the hub currency requests no FX at all.
    public func marketDataPlan(displayCurrency: Currency = .cad, hub: Currency = .usd) -> MarketDataPlan {
        var symbols = Set<String>()
        var currencies = Set<Currency>()
        for account in accounts {
            let balance = AccountBalances.compute(
                account: account,
                transactions: transactions(in: account.id)
            )
            for position in balance.positions {
                symbols.insert(position.symbol)
                currencies.insert(position.currency)
            }
            for currency in balance.cashByCurrency.keys { currencies.insert(currency) }
            for currency in balance.gicValueByCurrency.keys { currencies.insert(currency) }
        }
        currencies.insert(displayCurrency)

        let fx = currencies
            .filter { $0 != hub && $0 != .unknown }
            .sorted()
        return MarketDataPlan(symbols: symbols.sorted(), fxCurrencies: fx, hub: hub)
    }
}