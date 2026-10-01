import Foundation

// MARK: - Portfolio import (single-account, scoped)

extension Portfolio {
    /// How to apply an imported (single-account) export to the portfolio.
    ///
    /// Imports land on *one account*: the account record plus its
    /// ledger. Everything else in the portfolio is untouched — a
    /// multi-account dump is a different operation and is refused
    /// (`MutationError.importMultiAccount`).
    public enum ImportMode: Sendable {
        /// The imported account's ledger is *replaced* by the file's:
        /// previously recorded transactions for that account are removed
        /// and the file's transactions become the record. The account
        /// record itself is also taken from the file.
        case replace

        /// The file is *merged in*: transactions already present (same
        /// ID) are skipped, a new account ID is added (an existing one
        /// is kept as-is), and only brand-new tickers (by symbol) are
        /// registered.
        case merge
    }

    /// Validate `incoming` and apply it in `mode`.
    ///
    /// - Returns: updated portfolio plus human-readable notes (what
    ///   replaced what, what was skipped, what was added).
    /// - Throws: ``MutationError/importNoAccount``,
    ///   ``MutationError/importMultiAccount(_:)``, or
    ///   ``MutationError/importDanglingAccount(id:)`` when the file is
    ///   not a self-consistent single-account export.
    ///
    /// Ticker handling is uniform: an import never touches ticker
    /// records the portfolio already has (existing metadata wins), and
    /// brand-new symbols from the file are registered so an imported
    /// ledger can be read back with names.
    public func importing(_ incoming: Portfolio, mode: ImportMode) throws -> (portfolio: Portfolio, notes: [String]) {
        guard let account = singleAccount(in: incoming) else {
            if incoming.accounts.isEmpty {
                throw MutationError.importNoAccount
            }
            throw MutationError.importMultiAccount(count: incoming.accounts.count)
        }
        // Self-consistency: every transaction in the file belongs to
        // that one account — otherwise the export does not describe a
        // single coherent ledger and importing it would orphan data.
        if let orphan = incoming.transactions.first(where: { $0.accountID != account.id }) {
            throw MutationError.importDanglingAccount(id: orphan.accountID)
        }

        var copy = self
        var addedTickers = 0
        let knownSymbols = Set(copy.tickers.map(\.symbol))
        for ticker in incoming.tickers where !knownSymbols.contains(ticker.symbol) {
            copy.tickers.append(ticker)
            addedTickers += 1
        }

        switch mode {
        case .replace:
            let removed = copy.transactions(in: account.id).count
            copy.upsert(account)
            copy.transactions.removeAll { $0.accountID == account.id }
            copy.transactions.append(contentsOf: incoming.transactions)
            var note = "imported (replace) '\(account.displayName)': \(incoming.transactions.count) "
                + "transaction(s) from the file replaced \(removed) previously recorded for that account"
            if addedTickers > 0 { note += "; \(addedTickers) new ticker(s) registered" }
            return (copy, [note])

        case .merge:
            let isNewAccount = copy[account: account.id] == nil
            if isNewAccount {
                copy.accounts.append(account)
            }
            let existingIDs = Set(copy.transactions.map(\.id))
            let newTransactions = incoming.transactions.filter { !existingIDs.contains($0.id) }
            let skipped = incoming.transactions.count - newTransactions.count
            copy.transactions.append(contentsOf: newTransactions)
            var note = "imported (merge) '\(account.displayName)': \(newTransactions.count) new transaction(s)"
            if skipped > 0 { note += ", \(skipped) already present (skipped)" }
            if isNewAccount {
                note += "; account created (new ID)"
            } else {
                note += "; existing account kept"
            }
            if addedTickers > 0 { note += "; \(addedTickers) new ticker(s) registered" }
            return (copy, [note])
        }
    }

    private func singleAccount(in portfolio: Portfolio) -> Account? {
        guard let first = portfolio.accounts.first else { return nil }
        return portfolio.accounts.count == 1 ? first : nil
    }
}
