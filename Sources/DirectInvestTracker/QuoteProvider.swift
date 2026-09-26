import Foundation

/// A service that fetches live market data (price snapshots and exchange
/// rates) for valuation.
///
/// Providers fill a ``MarketDataCache``; the derivation layer never talks
/// to a provider directly — it reads the cache (or the closures built
/// from it, e.g. `rate: cache.rateValue` for ``AccountBalances``).
public protocol QuoteProvider: Sendable {

    /// The last price of each requested symbol, in whatever currency the
    /// exchange trades it.
    ///
    /// Individual symbols that have no quote (delisted, misspelled) are
    /// *omitted from the result* rather than failing the call; the error
    /// is thrown only when the provider itself fails (e.g. the network is
    /// down), since an empty result in that case is not a statement about
    /// the symbols.
    func quotes(for symbols: [String]) async throws -> [MarketQuote]

    /// The current exchange rate: units of `to` per one unit of `from`
    /// (e.g. `.usd` → `.cad` answers "how many CAD per 1 USD?").
    ///
    /// Same-currency requests are the identity (rate 1, no network call).
    func rate(from: Currency, to: Currency) async throws -> ExchangeRate
}