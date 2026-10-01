import Foundation

// MARK: - Ledger statement view (the on-the-fly columns of `dit tx list`)
//
// A statement row shows, per event, the cash that moved OUT, the cash
// that moved IN, and the cash left per currency AFTER the event. Every
// number is derived on demand from the ledger with EXACTLY the cash
// rules of AccountBalances.compute (an fx conversion debits the source
// currency, fees ride along with the leg they were charged on), so the
// statement cannot drift from the balances. Display only — nothing is
// stored, and no position value is mixed into a cash column.

/// One printed line of a ledger statement (display projection of a
/// `Transaction` plus the cash state around it).
public struct StatementRow: Sendable {
    /// The event this row renders.
    public let transaction: Transaction
    /// Cash OUT of the account (positive amounts, tagged by currency).
    public let debits: [(currency: Currency, amount: Decimal)]
    /// Cash IN to the account (positive amounts).
    public let credits: [(currency: Currency, amount: Decimal)]
    /// Cash per currency AFTER this event. Zero balances are dropped;
    /// an empty list means the account holds no cash at this point.
    public let cashAfter: [(currency: Currency, amount: Decimal)]

    /// Memberwise init (the replay builds rows; renderers consume them).
    public init(transaction: Transaction,
                debits: [(currency: Currency, amount: Decimal)],
                credits: [(currency: Currency, amount: Decimal)],
                cashAfter: [(currency: Currency, amount: Decimal)]) {
        self.transaction = transaction
        self.debits = debits
        self.credits = credits
        self.cashAfter = cashAfter
    }
}

/// The statement replay engine: turns transaction order into the
/// `tx list` columns (file header defines the exactness contract).
public enum LedgerStatement {

    /// Replay ONE account's ledger into statement rows, carrying a
    /// per-currency running cash balance.
    public static func rows(account: Account, transactions: [Transaction]) -> [StatementRow] {
        var cash: [Currency: Decimal] = [:]
        return Replay.ordered(transactions).map { tx in
            var debits: [(Currency, Decimal)] = []
            var credits: [(Currency, Decimal)] = []
            switch tx.kind {
            case .fxConversion(let details):
                // Two legs: source currency out, target currency in
                // (net of the fee, charged on the incoming leg — same
                // bookkeeping as AccountBalances.compute).
                if details.fromAmount > 0 {
                    debits.append((details.fromCurrency, details.fromAmount))
                }
                let netIn = details.toAmount - (tx.fee ?? 0)
                if netIn > 0 {
                    credits.append((tx.currency, netIn))
                }
                cash[details.fromCurrency, default: 0] -= details.fromAmount
                cash[tx.currency, default: 0] += netIn
            default:
                let impact = tx.cashImpact
                if impact < 0 {
                    debits.append((tx.currency, -impact))
                } else if impact > 0 {
                    credits.append((tx.currency, impact))
                }
                cash[tx.currency, default: 0] += impact
            }
            let snapshot = cash
                .filter { $0.value != 0 }
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { (currency: $0.key, amount: $0.value) }
            return StatementRow(transaction: tx, debits: debits, credits: credits,
                                cashAfter: snapshot)
        }
    }

    /// Every account's ledger interleaved by date for display. Each
    /// row's Balance column stays that ACCOUNT's own cash (per
    /// currency) — the merge orders the rows, it never sums across
    /// accounts. Same-day rows keep their LEDGER replay order (stable
    /// merge): a running balance only reads correctly in the order it
    /// was computed, so a uuid or name tiebreak could show money
    /// evaporating between two printed lines.
    public static func rows(portfolio: Portfolio) -> [StatementRow] {
        let merged = portfolio.accounts
            .flatMap { account in
                rows(account: account, transactions: portfolio.transactions(in: account.id))
            }
        return Replay.ordered(merged, date: { $0.transaction.date })
    }
}