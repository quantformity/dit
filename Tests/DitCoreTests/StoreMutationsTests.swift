import DitCore
import Foundation
import XCTest

/// `Portfolio.importing(_:mode:)` — the replace/merge semantics behind
/// `dit store import`, plus the single-account scope validation that
/// keeps a bad file from ever touching the store.
final class StoreMutationsTests: XCTestCase {
    private var tfsa: Account!
    private var other: Account!

    override func setUp() {
        super.setUp()
        tfsa = Account(reportingCurrency: .cad, name: "TFSA")
        other = Account(reportingCurrency: .usd, name: "Other")
    }

    private func transaction(_ day: Int, account: Account) -> Transaction {
        Transaction(
            date: Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 7, day: day))!,
            accountID: account.id,
            currency: account.reportingCurrency,
            kind: .deposit(amount: 1000)
        )
    }

    // MARK: - replace

    func testReplaceTakesTheFileLedgerForThatAccountID() throws {
        var portfolio = Portfolio(
            accounts: [tfsa, other],
            transactions: [
                transaction(1, account: tfsa),
                transaction(2, account: tfsa),
                transaction(5, account: other)
            ]
        )
        let fileAccount = Account(
            id: tfsa.id, reportingCurrency: .gbp, name: "TFSA (bank export)")

        let incoming = Portfolio(
            accounts: [fileAccount],
            transactions: [transaction(3, account: fileAccount)]
        )
        let imported = try portfolio.importing(incoming, mode: .replace)

        XCTAssertEqual(imported.portfolio.accounts.count, 2, "other account survives")
        let replaced = imported.portfolio[account: tfsa.id]
        XCTAssertEqual(replaced?.name, "TFSA (bank export)")
        XCTAssertEqual(replaced?.reportingCurrency, .gbp)
        XCTAssertEqual(imported.portfolio.transactions(in: tfsa.id).count, 1,
                       "the file's ledger replaces the old one")
        XCTAssertEqual(imported.portfolio.transactions(in: other.id).count, 1,
                       "the other account's ledger is untouched")
        XCTAssertEqual(imported.notes.count, 1)
        XCTAssertTrue(imported.notes[0].contains("replaced"))
    }

    func testReplaceOfAnUnseenAccountAddsIt() throws {
        let current = Portfolio(
            accounts: [tfsa],
            transactions: [transaction(1, account: tfsa)]
        )
        let newAccount = Account(reportingCurrency: .eur, name: "Brokerage")
        let incoming = Portfolio(
            accounts: [newAccount],
            transactions: [transaction(2, account: newAccount)]
        )
        let imported = try current.importing(incoming, mode: .replace)
        XCTAssertEqual(imported.portfolio.accounts.count, 2,
                       "replace keys on account ID: a new ID is added, existing untouched")
        XCTAssertEqual(imported.portfolio.transactions(in: tfsa.id).count, 1)
        XCTAssertEqual(imported.portfolio.transactions(in: newAccount.id).count, 1)
    }

    // MARK: - merge

    func testMergeSkipsDuplicateTransactionIDs() throws {
        let base = transaction(1, account: tfsa)
        let current = Portfolio(accounts: [tfsa], transactions: [base])
        let fresh = transaction(9, account: tfsa)
        let incoming = Portfolio(accounts: [tfsa], transactions: [base, fresh])
        let imported = try current.importing(incoming, mode: .merge)
        XCTAssertEqual(imported.portfolio.transactions(in: tfsa.id).count, 2,
                       "the duplicate (same UUID) is skipped exactly once")
        XCTAssertTrue(imported.notes[0].contains("skipped"),
                      "the note says what was skipped")
    }

    func testMergeAddsUnknownAccountAndKeepsExisting() throws {
        let current = Portfolio(accounts: [tfsa], transactions: [])
        let incoming = Portfolio(accounts: [other], transactions: [
            transaction(4, account: other)
        ])
        let imported = try current.importing(incoming, mode: .merge)
        XCTAssertEqual(imported.portfolio.accounts.count, 2)
        XCTAssertTrue(imported.notes[0].contains("new ID"))
        // Re-merging the same file must not duplicate anything.
        let again = try imported.portfolio.importing(incoming, mode: .merge)
        XCTAssertEqual(again.portfolio.accounts.count, 2)
        XCTAssertEqual(again.portfolio.transactions(in: other.id).count, 1)
    }

    // MARK: - ticker handling

    func testImportRegistersOnlyUnknownSymbols() throws {
        let known = EquityTicker(symbol: "AAPL", name: "Apple")
        var current = Portfolio(accounts: [tfsa], transactions: [transaction(1, account: tfsa)])
        current.tickers.append(known)
        let freshSymbol = EquityTicker(symbol: "BRK.B", name: "Berkshire")
        // File tries to overwrite the known entry — it must not.
        let incoming = Portfolio(
            accounts: [tfsa],
            transactions: [transaction(1, account: tfsa)],
            tickers: [
                EquityTicker(symbol: "AAPL", name: "Apple Inc. (file version)"),
                freshSymbol
            ]
        )
        let imported = try current.importing(incoming, mode: .replace)
        XCTAssertEqual(imported.portfolio[ticker: "AAPL"]?.name, "Apple",
                       "existing registry entries are never overwritten by an import")
        XCTAssertEqual(imported.portfolio[ticker: "BRK.B"]?.name, "Berkshire")
    }

    // MARK: - validation

    func testRefusesEmptyFile() {
        let incoming = Portfolio()
        XCTAssertThrowsError(try Portfolio().importing(incoming, mode: .replace)) {
            XCTAssertEqual($0 as? MutationError, .importNoAccount)
        }
    }

    func testRefusesMultiAccountFile() {
        let incoming = Portfolio(accounts: [tfsa, other], transactions: [])
        XCTAssertThrowsError(try Portfolio().importing(incoming, mode: .merge)) {
            XCTAssertEqual($0 as? MutationError, .importMultiAccount(count: 2))
        }
    }

    func testRefusesDanglingAccountReference() {
        let known = Account(reportingCurrency: .cad, name: "Known")
        let foreign = Account(reportingCurrency: .usd, name: "Foreign")
        let incoming = Portfolio(
            accounts: [known],
            transactions: [transaction(1, account: foreign)]
        )
        XCTAssertThrowsError(try Portfolio().importing(incoming, mode: .replace)) {
            guard case .importDanglingAccount(let id) = ($0 as? MutationError)! else {
                return XCTFail("expected importDanglingAccount, got \($0)")
            }
            XCTAssertEqual(id, foreign.id)
        }
    }
}
