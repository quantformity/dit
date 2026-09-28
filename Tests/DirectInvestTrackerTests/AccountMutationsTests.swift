import Foundation
import Testing

@testable import DirectInvestTracker

private let accountA = Account(name: "Account A")
private let accountB = Account(name: "Account B")

private func tx(
    id: UUID = UUID(),
    account: Account,
    kind: Transaction.Kind,
    currency: Currency = .cad
) -> Transaction {
    Transaction(id: id, date: Date(timeIntervalSince1970: 0), accountID: account.id,
                currency: currency, kind: kind)
}

// MARK: - adding

@Test("adding an account appends it and reports")
func addAccount() throws {
    let new = Account(name: "Questrade", institution: "Questrade")
    let (updated, notes) = try Portfolio(accounts: [accountA]).addingAccount(new)
    #expect(updated.accounts.count == 2)
    #expect(notes.first?.contains("Questrade") == true)
    #expect(notes.first?.contains("CAD") == true)
}

@Test("duplicate account IDs are rejected, not merged")
func addDuplicateAccount() throws {
    let shared = accountA.id
    let clone = Account(id: shared, name: "Copycat")
    #expect(throws: MutationError.accountExists(shared)) {
        _ = try Portfolio(accounts: [accountA]).addingAccount(clone)
    }
}

// MARK: - updating

@Test("editing changes only the supplied fields")
func updateOnlySupplied() throws {
    let original = Account(name: "Keep", institution: "TD", taxable: true)
    let (updated, notes) = try Portfolio(accounts: [original])
        .updatingAccount(id: original.id, institution: "Desjardins", taxable: false)
    let account = try #require(updated.accounts.first)
    #expect(account.name == "Keep")                      // untouched
    #expect(account.institution == "Desjardins")
    #expect(account.taxable == false)
    #expect(notes.joined().contains("institution"))
    #expect(notes.joined().contains("non-taxable"))
}

@Test("editing an unknown account fails")
func updateUnknownAccount() throws {
    let missing = UUID()
    #expect(throws: MutationError.accountNotFound(missing)) {
        _ = try Portfolio().updatingAccount(id: missing, name: "x")
    }
}

@Test("a no-change edit is refused — a confused save is a corrupted save")
func updateNoOp() throws {
    let account = Account(name: "Same", institution: "TD")
    #expect(throws: MutationError.nothingToEdit(account.id)) {
        _ = try Portfolio(accounts: [account]).updatingAccount(id: account.id, name: "Same")
    }
}

@Test("closing before opening is refused")
func closeBeforeOpen() throws {
    let opened = Date(timeIntervalSince1970: 1_000_000)
    let early = Date(timeIntervalSince1970: 500_000)
    let account = Account(name: "Backwards", openedDate: opened)
    #expect(throws: MutationError.closedBeforeOpened(account.id, opened: opened, closed: early)) {
        _ = try Portfolio(accounts: [account]).closingAccount(id: account.id, on: early)
    }
}

@Test("closing sets the closed date")
func closeAccount() throws {
    let opened = Date(timeIntervalSince1970: 1_000_000)
    let closed = Date(timeIntervalSince1970: 2_000_000)
    let account = Account(name: "Retired", openedDate: opened)
    let (updated, _) = try Portfolio(accounts: [account]).closingAccount(id: account.id, on: closed)
    #expect(updated.accounts.first?.closedDate == closed)
}

// MARK: - removing

@Test("an empty account deletes cleanly")
func removeEmptyAccount() throws {
    let (updated, notes) = try Portfolio(accounts: [accountA, accountB])
        .removingAccount(id: accountA.id, force: false)
    #expect(updated.accounts == [accountB])
    #expect(updated.transactions.isEmpty)
    #expect(notes.first?.contains("Account A") == true)
}

@Test("deleting an account with history needs force")
func removeNeedsForce() throws {
    let txs = [
        tx(account: accountA, kind: .deposit(amount: 100)),
        tx(account: accountA, kind: .withdrawal(amount: 50)),
        tx(account: accountB, kind: .deposit(amount: 10)),
    ]
    let portfolio = Portfolio(accounts: [accountA, accountB], transactions: txs)
    #expect(throws: MutationError.accountHasTransactions(accountA.id, count: 2)) {
        _ = try portfolio.removingAccount(id: accountA.id, force: false)
    }
}

@Test("force deletes only the account's own transactions")
func removeWithForce() throws {
    let keepID = UUID()
    let txs = [
        tx(account: accountA, kind: .deposit(amount: 100)),
        tx(id: keepID, account: accountB, kind: .deposit(amount: 10)),
    ]
    let portfolio = Portfolio(accounts: [accountA, accountB], transactions: txs)
    let (updated, notes) = try portfolio.removingAccount(id: accountA.id, force: true)
    #expect(updated.accounts == [accountB])
    #expect(updated.transactions.map(\.id) == [keepID])
    #expect(notes.first?.contains("1 transaction") == true)
}

@Test("removing an unknown account fails")
func removeUnknownAccount() throws {
    let missing = UUID()
    #expect(throws: MutationError.accountNotFound(missing)) {
        _ = try Portfolio().removingAccount(id: missing, force: true)
    }
}

// MARK: - name uniqueness (the CLI resolves accounts by name)

@Test("adding an account with an existing name is refused")
func addDuplicateName() throws {
    let existing = Account(name: "TFSA")
    let duplicate = Account(name: "  tfsa ")
    #expect(throws: MutationError.accountAlreadyNamed("tfsa")) {
        _ = try Portfolio(accounts: [existing]).addingAccount(duplicate)
    }
    // Unnamed accounts stay allowed (they resolve by ID, not name).
    _ = try Portfolio(accounts: [existing]).addingAccount(Account(institution: "X"))
}

@Test("renaming onto another account's name is refused")
func renameCollision() throws {
    let a = Account(name: "Alpha")
    let b = Account(name: "Beta")
    #expect(throws: MutationError.accountAlreadyNamed("ALPHA")) {
        _ = try Portfolio(accounts: [a, b]).updatingAccount(id: b.id, name: "ALPHA")
    }
}
