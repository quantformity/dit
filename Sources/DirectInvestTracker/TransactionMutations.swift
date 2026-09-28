import Foundation

// MARK: - Edits

/// One value-level change to an existing transaction.
///
/// Edits change *values only*. Changing a transaction's kind (or its
/// account) is never offered here: that changes what the record is
/// about, and corrections should be visible as a new fact — use
/// delete + re-add for that.
public enum TransactionEdit: Equatable, Sendable {
    case date(Date)
    /// `.fee(nil)` removes the fee.
    case fee(Decimal?)
    /// Replacement payload; must stay within the same kind family.
    case kind(Transaction.Kind)
}

extension Portfolio {

    // MARK: - Adding

    /// Record a new transaction.
    ///
    /// Refused (nothing is written) when: the account is unknown, the
    /// payload holds impossible values (zero shares, negative amounts
    /// or fees, an fx pair in one currency), or a GIC redemption
    /// references no purchase in the account. A ticker used for the
    /// first time is auto-registered in the registry (symbol-only;
    /// name/currency can be completed later with `dit ticker`).
    public func addingTransaction(_ tx: Transaction) throws -> (Portfolio, [String]) {
        guard accounts.contains(where: { $0.id == tx.accountID }) else {
            throw MutationError.accountNotFound(tx.accountID)
        }
        try Self.validateTransaction(tx)
        if case .gicRedemption(let details) = tx.kind {
            let linked = transactions.contains {
                $0.accountID == tx.accountID && $0.id == details.purchaseID
            }
            if !linked { throw MutationError.danglingRedemption(purchaseID: details.purchaseID) }
        }

        var copy = self
        var notes: [String] = ["added '\(tx.summaryLine)'"]

        // Auto-register an unseen ticker: ledger facts first, the
        // instrument registry follows the ledger (symbol is identity).
        if let symbol = tx.ticker, !copy.tickers.contains(where: { $0.symbol == symbol }) {
            copy.tickers.append(EquityTicker(symbol: symbol, currency: tx.currency))
            notes.append("registered ticker '\(symbol)' — add a name with 'dit ticker edit' if you like")
        }

        // Spending more cash than the account holds in some currency?
        // Record the fact, warn loudly (overdrafts happen; silent
        // negatives do not). Any pool the transaction drains counts —
        // withdrawals, buys, the outgoing side of an fx conversion.
        var pools = Self.cashPools(of: tx.accountID, in: self)
        for (currency, delta) in Self.cashDeltas(of: tx) where delta < 0 {
            pools[currency, default: 0] += delta
            if let shortfall = pools[currency], shortfall < 0 {
                notes.append("warning: \(currency.rawValue) cash goes negative (\(Transaction.exact(shortfall))) "
                    + "— check the account actually had this money")
            }
        }

        copy.transactions.append(tx)
        return (copy, notes)
    }

    // MARK: - Editing

    /// Apply value-level edits to one transaction.
    ///
    /// - Throws ``MutationError/transactionNotFound(_:)`` for an
    ///   unknown id, ``MutationError/kindChange(_:)`` when a kind
    ///   replacement crosses families, ``MutationError/invalidValue(_:)``
    ///   when the edited record would hold impossible values, and
    ///   ``MutationError/nothingToEdit(_:)`` for a no-op.
    public func editingTransaction(id: UUID, _ edits: [TransactionEdit]) throws -> (Portfolio, [String]) {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else {
            throw MutationError.transactionNotFound(id)
        }
        var tx = transactions[index]
        let before = tx.summaryLine

        for edit in edits {
            switch edit {
            case .date(let date):
                tx.date = date
            case .fee(let fee):
                tx.fee = fee
            case .kind(let newKind):
                guard newKind.isSameFamily(as: tx.kind) else {
                    throw MutationError.kindChange(id)
                }
                tx.kind = newKind
            }
        }
        guard tx != transactions[index] else { throw MutationError.nothingToEdit(id) }
        try Self.validateTransaction(tx)

        var copy = self
        copy.transactions[index] = tx
        var notes = ["corrected '\(Transaction.dayString(transactions[index].date)) \(before)' → "
            + "'\(Transaction.dayString(tx.date)) \(tx.summaryLine)'"]

        // A GIC whose principal changed silently re-attributes any
        // redemption linked to it — surface that.
        if case .gicPurchase(let newDetails) = tx.kind,
           case .gicPurchase(let oldDetails) = transactions[index].kind,
           newDetails.principal != oldDetails.principal {
            let linkedRedemptions = transactions.filter {
                $0.accountID == tx.accountID
                    && (($0.kind).isLinkedRedemption(of: id))
            }
            if !linkedRedemptions.isEmpty {
                notes.append("warning: \(linkedRedemptions.count) linked redemption"
                    + "\(linkedRedemptions.count == 1 ? "" : "s") recomputed against the new principal")
            }
        }
        return (copy, notes)
    }

    // MARK: - Deleting

    /// Delete one transaction, reporting the effect on positions and
    /// cash so the caller can show its impact before confirming.
    public func removingTransaction(id: UUID) throws -> (Portfolio, [String]) {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else {
            throw MutationError.transactionNotFound(id)
        }
        let tx = transactions[index]
        var copy = self
        copy.transactions.remove(at: index)

        var notes = ["removed '\(tx.summaryLine)'"]
        if let symbol = tx.ticker {
            switch tx.kind {
            case .stockPurchase(let details):
                if let impact = Self.positionImpact(portfolio: self, tx: tx,
                                                    symbol: symbol, delta: -details.shares) {
                    notes.append(impact)
                }
            case .stockSale(let details):
                if let impact = Self.positionImpact(portfolio: self, tx: tx,
                                                    symbol: symbol, delta: details.shares) {
                    notes.append(impact)
                }
            default:
                break
            }
        }
        if case .gicPurchase = tx.kind {
            let orphans = copy.transactions.filter { $0.kind.isLinkedRedemption(of: id) }
            if !orphans.isEmpty {
                notes.append("warning: \(orphans.count) redemption(s) will lose their GIC "
                    + "— their proceeds stay in cash but stop counting toward P&L")
            }
        }
        // Cash effect, per touched pool.
        for (currency, delta) in Self.cashDeltas(of: tx) where delta != 0 {
            let pools = Self.cashPools(of: tx.accountID, in: self)
            let after = (pools[currency] ?? 0) - delta
            notes.append("\(currency.rawValue) cash "
                + "\(Transaction.exact(pools[currency] ?? 0)) → \(Transaction.exact(after))")
        }
        return (copy, notes)
    }

    // MARK: - Validation

    /// Facts must be possible: the ledger records what happened, and
    /// impossible numbers are how corruption hides.
    static func validateTransaction(_ tx: Transaction) throws {
        if let fee = tx.fee, fee < 0 {
            throw MutationError.invalidValue("a fee cannot be negative (found \(fee))")
        }
        switch tx.kind {
        case .deposit(let amount), .withdrawal(let amount):
            guard amount > 0 else {
                throw MutationError.invalidValue("amount must be positive (found \(amount))")
            }
        case .stockPurchase(let details), .stockSale(let details):
            guard !details.ticker.isEmpty else { throw MutationError.invalidValue("empty ticker symbol") }
            guard details.shares > 0 else {
                throw MutationError.invalidValue("shares must be positive (found \(details.shares))")
            }
            guard details.price >= 0 else {
                throw MutationError.invalidValue("price cannot be negative (found \(details.price))")
            }
        case .dividend(let details):
            guard !details.ticker.isEmpty else { throw MutationError.invalidValue("empty ticker symbol") }
            guard details.amount > 0 else {
                throw MutationError.invalidValue("dividend amount must be positive (found \(details.amount))")
            }
        case .gicPurchase(let details):
            guard !details.product.isEmpty else { throw MutationError.invalidValue("empty GIC product name") }
            guard details.principal > 0 else {
                throw MutationError.invalidValue("principal must be positive (found \(details.principal))")
            }
            guard details.rate >= 0 else {
                throw MutationError.invalidValue("rate cannot be negative (found \(details.rate))")
            }
        case .gicRedemption(let details):
            guard details.proceeds >= 0 else {
                throw MutationError.invalidValue("proceeds cannot be negative (found \(details.proceeds))")
            }
        case .fxConversion(let details):
            guard details.fromCurrency != tx.currency else {
                throw MutationError.invalidValue("a currency conversion needs two different currencies")
            }
            guard details.fromAmount > 0, details.toAmount > 0 else {
                throw MutationError.invalidValue(
                    "both converted amounts must be positive "
                        + "(found \(details.fromAmount) → \(details.toAmount))")
            }
        }
    }

    // MARK: - Impact helpers

    /// Cash pools by currency, following the same accounting rule as
    /// `AccountBalances` (fxConversion spans two pools).
    static func cashPools(of accountID: UUID, in portfolio: Portfolio) -> [Currency: Decimal] {
        var pools: [Currency: Decimal] = [:]
        for tx in portfolio.transactions where tx.accountID == accountID {
            switch tx.kind {
            case .fxConversion(let details):
                pools[details.fromCurrency, default: 0] -= details.fromAmount
                pools[tx.currency, default: 0] += details.toAmount - (tx.fee ?? 0)
            default:
                pools[tx.currency, default: 0] += tx.cashImpact
            }
        }
        return pools
    }

    /// Cash deltas a transaction touches (currency → effect).
    static func cashDeltas(of tx: Transaction) -> [(Currency, Decimal)] {
        switch tx.kind {
        case .fxConversion(let details):
            return [(details.fromCurrency, -details.fromAmount),
                    (tx.currency, details.toAmount - (tx.fee ?? 0))]
        default:
            let delta = tx.cashImpact
            return delta == 0 ? [] : [(tx.currency, delta)]
        }
    }

    // MARK: - Entry helpers

    /// The currency a new record about `symbol` should default to:
    /// the ticker's confirmed trading currency, else the account's
    /// reporting currency. A live quote can override this (its own
    /// currency is the best evidence), but never a guess.
    public func suggestedCurrency(accountID: UUID, symbol: String?) -> Currency {
        if let symbol,
           let ticker = tickers.first(where: { $0.symbol == symbol }),
           ticker.currency != .unknown {
            return ticker.currency
        }
        return accounts.first { $0.id == accountID }?.reportingCurrency ?? .cad
    }

    /// Find a GIC purchase in `accountID` by product name (exact,
    /// case-insensitive), full UUID, or unique UUID prefix — the forms
    /// a redemption may use to say *which* GIC it redeemed. Ambiguity
    /// and misses list the account's live GICs instead of guessing.
    public func findGICPurchase(accountID: UUID, reference raw: String) throws -> Transaction {
        let query = raw.trimmingCharacters(in: .whitespaces)
        func gics(_ tx: Transaction) -> Bool {
            guard tx.accountID == accountID, case .gicPurchase = tx.kind else { return false }
            return true
        }
        let live = transactions.filter(gics)

        // Product name first: only an id-shaped reference that matches
        // no product may resolve by identifier.
        let byName = live.filter { tx in
            if case .gicPurchase(let details) = tx.kind {
                return details.product.lowercased() == query.lowercased()
            }
            return false
        }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 {
            throw MutationError.unresolvable(
                "'\(query)' matches \(byName.count) GICs in that account — refer to one by its "
                    + "transaction id: \(Self.describe(byName))")
        }

        let hex = query.replacingOccurrences(of: "-", with: "").uppercased()
        if hex.count >= 4, hex.allSatisfy(\.isHexDigit) {
            let byID = live.filter {
                $0.id.uuidString.replacingOccurrences(of: "-", with: "").uppercased().hasPrefix(hex)
            }
            if byID.count == 1 { return byID[0] }
            if byID.count > 1 {
                throw MutationError.unresolvable(
                    "'\(query)' matches \(byID.count) GICs — use a longer id: \(Self.describe(byID))")
            }
        }
        throw MutationError.unresolvable(live.isEmpty
            ? "no GIC purchase found in that account — record the GIC first ('dit tx gic'), "
                + "then redeem it"
            : "no GIC matches '\(query)' — in that account: \(Self.describe(live))")
    }

    static func describe(_ txs: [Transaction]) -> String {
        txs.prefix(4).map { "'\($0.summaryLine)' [\(String($0.id.uuidString.prefix(8)))]" }
            .joined(separator: " | ")
    }

    /// "SHOP.TO 100 → 90 shares" style impact for removing a trade.
    static func positionImpact(
        portfolio: Portfolio, tx: Transaction, symbol: String, delta: Decimal
    ) -> String? {
        var shares: Decimal = 0
        for other in portfolio.transactions where other.accountID == tx.accountID {
            switch other.kind {
            case .stockPurchase(let details) where details.ticker == symbol && other.currency == tx.currency:
                shares += details.shares
            case .stockSale(let details) where details.ticker == symbol && other.currency == tx.currency:
                shares -= details.shares
            default: break
            }
        }
        let after = shares + delta
        guard after != shares else { return nil }
        if after <= 0 {
            return after == 0
                ? "position \(symbol) closes (0 shares)"
                : "warning: position \(symbol) would be \(Transaction.exact(after)) shares — "
                    + "check the ledger around this trade"
        }
        return "\(symbol): \(Transaction.exact(shares)) → \(Transaction.exact(after)) shares"
    }
}

extension Transaction.Kind {
    /// True for a GIC redemption that references the given purchase id.
    public func isLinkedRedemption(of purchaseID: UUID) -> Bool {
        if case .gicRedemption(let details) = self { return details.purchaseID == purchaseID }
        return false
    }
}