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

public struct StatementRow: Sendable {
    public let transaction: Transaction
    /// Cash OUT of the account (positive amounts, tagged by currency).
    public let debits: [(currency: Currency, amount: Decimal)]
    /// Cash IN to the account (positive amounts).
    public let credits: [(currency: Currency, amount: Decimal)]
    /// Cash per currency AFTER this event. Zero balances are dropped;
    /// an empty list means the account holds no cash at this point.
    public let cashAfter: [(currency: Currency, amount: Decimal)]

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

public enum LedgerStatement {

    /// Chronological order, storage order as tiebreaker — the same
    /// replay order the balance engine uses.
    private static func chronological(_ transactions: [Transaction]) -> [Transaction] {
        transactions.enumerated().sorted { lhs, rhs in
            if lhs.element.date != rhs.element.date { return lhs.element.date < rhs.element.date }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Replay ONE account's ledger into statement rows, carrying a
    /// per-currency running cash balance.
    public static func rows(account: Account, transactions: [Transaction]) -> [StatementRow] {
        var cash: [Currency: Decimal] = [:]
        return chronological(transactions).map { tx in
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
    /// accounts.
    public static func rows(portfolio: Portfolio) -> [StatementRow] {
        portfolio.accounts
            .flatMap { account in
                rows(account: account, transactions: portfolio.transactions(in: account.id))
            }
            .sorted { lhs, rhs in
                if lhs.transaction.date != rhs.transaction.date {
                    return lhs.transaction.date < rhs.transaction.date
                }
                let leftAccount = portfolio[account: lhs.transaction.accountID]?.displayName ?? ""
                let rightAccount = portfolio[account: rhs.transaction.accountID]?.displayName ?? ""
                if leftAccount != rightAccount { return leftAccount < rightAccount }
                return lhs.transaction.id.uuidString < rhs.transaction.id.uuidString
            }
    }
}