import Foundation
import Testing
@testable import DitCore

/// `dit tx list`'s statement columns must reproduce EXACTLY the cash
/// rules of AccountBalances.compute (fees on the trade leg, fx paying
/// out of the source currency), keep running balances per account AND
/// per currency, and never sum money across accounts.
@Suite("ledger statement")
struct LedgerStatementTests {

    private func day(_ y: Int, _ month: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: month, day: d))!
    }
    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    @Test func runningCashLegsAndZeroDropoff() {
        let acct = Account(reportingCurrency: .usd, name: "T")
        let txs: [Transaction] = [
            Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                        kind: .deposit(amount: 10_000)),
            Transaction(date: day(2026, 1, 10), accountID: acct.id, currency: .usd,
                        kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 100, price: 90)),
                        fee: 10),
            Transaction(date: day(2026, 1, 20), accountID: acct.id, currency: .cad,
                        kind: .fxConversion(FXDetails(fromCurrency: .usd, fromAmount: 990, toAmount: 1_400))),
        ]
        let rows = LedgerStatement.rows(account: acct, transactions: txs)
        #expect(rows.count == 3)

        // Deposit: pure credit.
        #expect(rows[0].debits.isEmpty)
        #expect(rows[0].credits.first?.amount == 10_000)
        #expect(rows[0].cashAfter.first?.amount == 10_000)

        // Buy: cash OUT equals trade value PLUS the fee (same rule the
        // balances use), leaving 10,000 − 9,010 = 990.
        let purchase = rows[1]
        #expect(purchase.credits.isEmpty)
        #expect(purchase.debits.first?.amount == dec("9010"))
        #expect(purchase.cashAfter.first?.amount == dec("990"))

        // fx: the SOURCE currency is debited, the target credited; USD
        // cash reaches exactly zero and disappears from the snapshot
        // (0 ≠ 990). The fee stays with the incoming leg.
        let fx = rows[2]
        #expect(fx.debits.map(\.currency) == [.usd])
        #expect(fx.debits.first?.amount == dec("990"))
        #expect(fx.credits.first?.currency == .cad)
        #expect(fx.credits.first?.amount == dec("1400"))
        let after = Dictionary(uniqueKeysWithValues: fx.cashAfter.map { ($0.currency, $0.amount) })
        #expect(after[.usd] == nil, "a zero balance must not print as a number")
        #expect(after[.cad] == dec("1400"))
    }

    @Test func balancesNeverMergeAcrossAccounts() {
        let a = Account(reportingCurrency: .usd, name: "A")
        let b = Account(reportingCurrency: .usd, name: "B")
        var portfolio = Portfolio(accounts: [a, b])
        portfolio.transactions = [
            Transaction(date: day(2026, 1, 5), accountID: a.id, currency: .usd, kind: .deposit(amount: 100)),
            Transaction(date: day(2026, 1, 6), accountID: b.id, currency: .usd, kind: .deposit(amount: 100)),
            Transaction(date: day(2026, 1, 7), accountID: b.id, currency: .usd, kind: .withdrawal(amount: 40)),
        ]
        let rows = LedgerStatement.rows(portfolio: portfolio)
        #expect(rows.count == 3)
        // Rows interleave by date (A's day-5 deposit first), but the
        // last row shows account B's OWN cash (60), never a combined
        // 160 across accounts.
        #expect(rows.map(\.transaction.accountID) == [a.id, b.id, b.id])
        let last = rows[2]
        #expect(last.cashAfter.count == 1)
        #expect(last.cashAfter.first?.amount == dec("60"))
    }

    @Test func sameDayRowsKeepReplayOrderAcrossAccounts() {
        // Merging accounts must not reorder same-day rows by name or
        // uuid: a running balance only reads correctly in the order
        // it was computed (money must never appear to evaporate).
        let a = Account(reportingCurrency: .usd, name: "A")
        let b = Account(reportingCurrency: .usd, name: "B")
        var portfolio = Portfolio(accounts: [a, b])
        portfolio.transactions = [
            Transaction(date: day(2026, 1, 5), accountID: a.id, currency: .usd, kind: .deposit(amount: 100)),
            Transaction(date: day(2026, 1, 5), accountID: b.id, currency: .usd, kind: .deposit(amount: 100)),
            Transaction(date: day(2026, 1, 5), accountID: b.id, currency: .usd, kind: .withdrawal(amount: 40)),
        ]
        let rows = LedgerStatement.rows(portfolio: portfolio)
        #expect(rows.map(\.transaction.accountID) == [a.id, b.id, b.id])
        // B's own chain is visible and continuous: 100 → 60.
        #expect(rows[1].cashAfter.first?.amount == dec("100"))
        #expect(rows[2].cashAfter.first?.amount == dec("60"))
    }

    @Test func sameDayRowsKeepStorageOrderAndRunningState() {
        // A withdrawal and a sale recorded the same day: replay order
        // is storage order (matching AccountBalances.compute), and the
        // balance chain stays continuous.
        let acct = Account(reportingCurrency: .usd, name: "T")
        let gic = Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                              kind: .gicPurchase(GICDetails(product: "G", principal: 1_000, rate: 0.05,
                                                             compounding: .annual, maturityDate: day(2028, 1, 5),
                                                             redeemable: false)))
        let redeem = Transaction(date: day(2026, 1, 5), accountID: acct.id, currency: .usd,
                                 kind: .gicRedemption(GICRedemptionDetails(purchaseID: gic.id, proceeds: 1_100)))
        let rows = LedgerStatement.rows(account: acct, transactions: [gic, redeem])
        #expect(rows[0].debits.first?.amount == dec("1000"))   // principal left the cash
        #expect(rows[1].credits.first?.amount == dec("1100"))  // proceeds returned
        #expect(rows[1].cashAfter.first?.amount == dec("100")) // net cash after both legs
    }
}