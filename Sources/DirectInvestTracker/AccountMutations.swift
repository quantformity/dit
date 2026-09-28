import Foundation

/// Errors a portfolio mutation can raise.
///
/// Mutations return `(Portfolio, [String])` on success — the updated
/// document plus human-readable notes of what changed — and throw
/// these when the operation cannot be applied.
public enum MutationError: LocalizedError, Equatable {
    case accountExists(UUID)
    case accountNotFound(UUID)
    case accountHasTransactions(UUID, count: Int)
    case closedBeforeOpened(UUID, opened: Date, closed: Date)
    case nothingToEdit(UUID)
    case transactionNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .accountExists(let id):
            return "an account with ID \(id) already exists"
        case .accountNotFound(let id):
            return "no account with ID \(id)"
        case .accountHasTransactions(let id, let count):
            return "account \(id) has \(count) transaction\(count == 1 ? "" : "s"); "
                + "deleting it removes its whole history — pass --force to confirm"
        case .closedBeforeOpened(_, let opened, let closed):
            return "closed date (\(shortDateString(closed))) precedes opened date (\(shortDateString(opened)))"
        case .nothingToEdit(let id):
            return "no changes — every supplied value already matches account \(id)"
        case .transactionNotFound(let id):
            return "no transaction with ID \(id)"
        }
    }
}

/// Deterministic yyyy-MM-dd rendering for mutation messages — the
/// raw `Date` description is noise in a CLI note.
func shortDateString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

extension Portfolio {
    // MARK: Accounts

    /// Insert a new account. Throws ``MutationError/accountExists``
    /// for a duplicate ID (IDs are identity — a second account with
    /// the same ID would corrupt every lookup).
    public func addingAccount(_ account: Account) throws -> (Portfolio, [String]) {
        guard !accounts.contains(where: { $0.id == account.id }) else {
            throw MutationError.accountExists(account.id)
        }
        var copy = self
        copy.accounts.append(account)
        return (
            copy,
            ["added account '\(account.displayName)' (\(account.reportingCurrency.rawValue), "
                + "\(account.taxable ? "taxable" : "non-taxable"))"]
        )
    }

    /// Value-only update: `nil` arguments are left untouched, so the
    /// caller changes exactly what the user asked for.
    ///
    /// Throws ``MutationError/nothingToEdit`` when every supplied
    /// value already matches — a no-op save is a confused save.
    /// Closing before opening is rejected
    /// (``MutationError/closedBeforeOpened(_:opened:closed:)``).
    public func updatingAccount(
        id: UUID,
        name: String? = nil,
        institution: String? = nil,
        accountNumber: String? = nil,
        currency: Currency? = nil,
        taxable: Bool? = nil,
        opened: Date? = nil,
        closed: Date? = nil,
        notes: String? = nil
    ) throws -> (Portfolio, [String]) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw MutationError.accountNotFound(id)
        }

        var account = accounts[index]
        var changes: [String] = []

        if let name, account.name != name { changes.append("name → '\(name)'"); account.name = name }
        if let institution, account.institution != institution {
            changes.append("institution → '\(institution)'")
            account.institution = institution
        }
        if let accountNumber, account.accountNumber != accountNumber {
            changes.append("number → '\(accountNumber)'")
            account.accountNumber = accountNumber
        }
        if let currency, account.reportingCurrency != currency {
            changes.append("currency → \(currency.rawValue)")
            account.reportingCurrency = currency
        }
        if let taxable, account.taxable != taxable {
            changes.append(taxable ? "now taxable" : "now non-taxable")
            account.taxable = taxable
        }
        if let opened, account.openedDate != opened {
            changes.append("opened → \(shortDateString(opened))")
            account.openedDate = opened
        }
        if let closed, account.closedDate != closed {
            changes.append("closed → \(shortDateString(closed))")
            account.closedDate = closed
        }
        if let notes, account.notes != notes { changes.append("notes → '\(notes)'"); account.notes = notes }

        guard !changes.isEmpty else { throw MutationError.nothingToEdit(id) }
        if let openedDate = account.openedDate, let closedDate = account.closedDate,
           closedDate < openedDate {
            throw MutationError.closedBeforeOpened(id, opened: openedDate, closed: closedDate)
        }

        var copy = self
        copy.accounts[index] = account
        return (copy, ["updated '\(account.displayName)': " + changes.joined(separator: ", ")])
    }

    /// Close the account as of `date` — a convenience over
    /// ``updatingAccount(id:closed:)`` with the same validation.
    public func closingAccount(id: UUID, on date: Date) throws -> (Portfolio, [String]) {
        try updatingAccount(id: id, closed: date)
    }

    /// Remove an account. An account with transactions can only be
    /// removed with `force: true`, which removes them too — an
    /// account's history is never deleted silently.
    public func removingAccount(id: UUID, force: Bool) throws -> (Portfolio, [String]) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw MutationError.accountNotFound(id)
        }
        let account = accounts[index]
        let transactionCount = transactions(in: id).count
        guard transactionCount == 0 || force else {
            throw MutationError.accountHasTransactions(id, count: transactionCount)
        }

        var copy = self
        if transactionCount > 0 {
            copy.transactions.removeAll { $0.accountID == id }
        }
        copy.accounts.remove(at: index)
        return (
            copy,
            ["removed account '\(account.displayName)'"
                + (transactionCount > 0 ? " and \(transactionCount) transaction"
                    + (transactionCount == 1 ? "" : "s") : "")]
        )
    }
}