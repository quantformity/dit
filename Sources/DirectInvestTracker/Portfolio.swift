import Foundation

/// The root of the persisted data: everything the app knows.
///
/// `Portfolio` is the unit of storage — one Codable document in the
/// underlying `DataStore` — and contains the three foundations:
/// - `accounts` — where the money is held
/// - `transactions` — the first-class event log (source of truth)
/// - `tickers` — the instrument registry (display metadata)
public struct Portfolio: Codable, Hashable, Sendable {
    public var accounts: [Account]
    public var transactions: [Transaction]
    public var tickers: [EquityTicker]

    public init(
        accounts: [Account] = [],
        transactions: [Transaction] = [],
        tickers: [EquityTicker] = []
    ) {
        self.accounts = accounts
        self.transactions = transactions
        self.tickers = tickers
    }

    // MARK: Lookups

    public subscript(account id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    /// Case-insensitive symbol lookup, matching the normalization used
    /// everywhere else (`" shop.to "` finds `"SHOP.TO"`).
    public subscript(ticker symbol: String) -> EquityTicker? {
        let normalized = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        return tickers.first { $0.symbol == normalized }
    }

    public func transactions(in accountID: UUID) -> [Transaction] {
        transactions.filter { $0.accountID == accountID }
    }

    /// All transactions involving a ticker (buys, sells, dividends).
    public func transactions(for symbol: String) -> [Transaction] {
        let normalized = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        return transactions.filter { $0.ticker == normalized }
    }

    /// The display name of an account for listings, or "\u{2014}" when
    /// the id matches no account — history must still render even if
    /// its account vanished.
    public func accountName(for accountID: UUID) -> String {
        self[account: accountID]?.displayName ?? "\u{2014}"
    }

    /// Shares of `symbol` the account's ledger records, summed across
    /// the WHOLE ledger (no as-of cutoff): buys plus, sells minus.
    /// Goes negative when the account sold shares it did not have —
    /// that is the point. (``AccountBalances`` clamps positions at
    /// zero; this helper must not, or the "ends up SHORT" warning
    /// would miss an account already in the hole.)
    public func trackedSharesHeld(accountID: UUID, symbol: String) -> Decimal {
        transactions.reduce(Decimal.zero) { total, transaction in
            guard transaction.accountID == accountID else { return total }
            switch transaction.kind {
            case .stockPurchase(let details) where details.ticker == symbol:
                return total + details.shares
            case .stockSale(let details) where details.ticker == symbol:
                return total - details.shares
            default:
                return total
            }
        }
    }

    // MARK: Mutations

    public mutating func add(_ transaction: Transaction) {
        transactions.append(transaction)
    }

    /// Inserts `account`, or replaces the existing entry with the same id.
    public mutating func upsert(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    /// Inserts `ticker`, or replaces the existing entry with the same symbol.
    public mutating func upsert(_ ticker: EquityTicker) {
        if let index = tickers.firstIndex(where: { $0.symbol == ticker.symbol }) {
            tickers[index] = ticker
        } else {
            tickers.append(ticker)
        }
    }

    // MARK: Lenient decoding

    /// Missing collections decode to empty arrays, so data saved before a
    /// section existed (e.g. before the ticker registry) still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        self.transactions = try container.decodeIfPresent([Transaction].self, forKey: .transactions) ?? []
        self.tickers = try container.decodeIfPresent([EquityTicker].self, forKey: .tickers) ?? []
    }
}