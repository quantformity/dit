import Foundation

extension Portfolio {
    // MARK: Tickers — the instrument registry

    /// Register an instrument's enrichment metadata.
    ///
    /// The symbol is the identity: registering one that is already
    /// present is a duplicate, throw ``MutationError/tickerExists`` —
    /// an update goes through ``updatingTicker(symbol:name:currency:tags:notes:)``.
    /// (Trades for an *unregistered* symbol are still legal; the
    /// registry is optional enrichment, not a precondition.)
    public func addingTicker(_ ticker: EquityTicker) throws -> (Portfolio, [String]) {
        guard !ticker.symbol.isEmpty else {
            throw MutationError.invalidValue("ticker symbol cannot be empty")
        }
        guard self[ticker: ticker.symbol] == nil else {
            throw MutationError.tickerExists(ticker.symbol)
        }
        var copy = self
        copy.upsert(ticker)
        var note = "registered \(ticker.symbol)"
        if let name = ticker.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            note += " ('\(name)')"
        }
        note += " — trades in \(ticker.currency == .unknown ? "unknown (set with 'dit ticker edit')" : ticker.currency.rawValue)"
        return (copy, [note])
    }

    /// Value-only update of a registry entry: `nil` arguments are left
    /// untouched. `tags` *replaces* the set wholesale (an empty set
    /// clears it). Throws ``MutationError/tickerUnchanged`` when every
    /// supplied value already matches — a no-op save is a confused save.
    public func updatingTicker(
        symbol: String,
        name: String? = nil,
        currency: Currency? = nil,
        tags: Set<Tag>? = nil,
        notes: String? = nil
    ) throws -> (Portfolio, [String]) {
        let normalized = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard let index = tickers.firstIndex(where: { $0.symbol == normalized }) else {
            throw MutationError.tickerNotFound(normalized)
        }
        var entry = tickers[index]
        var changes: [String] = []

        if let name, entry.name != name {
            changes.append("name → '\(name)'")
            entry.name = name
        }
        if let currency, entry.currency != currency {
            changes.append("currency → \(currency.rawValue)")
            entry.currency = currency
        }
        if let tags, entry.tags != tags {
            let rendered = tags.isEmpty
                ? "tags cleared"
                : "tags → " + tags.sorted().map(\.displayValue).joined(separator: ", ")
            changes.append(rendered)
            entry.tags = tags
        }
        if let notes, entry.notes != notes {
            changes.append("notes → '\(notes)'")
            entry.notes = notes
        }

        guard !changes.isEmpty else { throw MutationError.tickerUnchanged(normalized) }
        var copy = self
        copy.tickers[index] = entry
        return (copy, ["updated registry entry '\(normalized)': " + changes.joined(separator: ", ")])
    }

    /// Remove a registry entry.
    ///
    /// Transactions that reference the symbol are **unaffected** — the
    /// registry holds display metadata only, and the notes say so. The
    /// CLI gates a referenced removal with confirmation.
    public func removingTicker(symbol: String) throws -> (Portfolio, [String]) {
        let normalized = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard let index = tickers.firstIndex(where: { $0.symbol == normalized }) else {
            throw MutationError.tickerNotFound(normalized)
        }
        let entry = tickers[index]
        var copy = self
        copy.tickers.remove(at: index)

        var note = "unregistered "
        if let name = entry.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            note += "'\(name)' "
        }
        note += "(\(normalized))"
        let referencing = transactions(for: normalized).count
        if referencing > 0 {
            note += " — \(referencing) transaction\(referencing == 1 ? "" : "s") still reference \(normalized); they are unaffected"
        }
        return (copy, [note])
    }
}
