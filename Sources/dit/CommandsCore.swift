import DirectInvestTracker
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - summary / accounts (read-only)

/// `dit` (no command): the portfolio snapshot — per-account balances,
/// holdings, and one-day change, valued from live quotes (or the
/// market store when `--offline`).
func summary(global: Global) async throws {
    let (store, configuration) = try openStore(global: global)
    guard let portfolio = try await store.load() else {
        if global.json {
            print(JSONOutput.envelope(schema: "summary/1", data: [
                "empty": true,
                "note": "no portfolio found — add accounts and transactions first",
                "store": configuration.url.path,
            ]))
            return
        }
        print("No portfolio found (store: \(configuration.backend.rawValue) at \(configuration.url.path)).")
        print("Add accounts and transactions first.")
        return
    }
    if portfolio.accounts.isEmpty {
        if global.json {
            print(JSONOutput.summaryJSON(portfolio.summary(displayCurrency: global.display),
                                         cache: nil, market: nil, maxAge: 0, now: Date.now,
                                         storePath: configuration.url.path,
                                         warnings: ["the portfolio has no accounts yet"],
                                         offline: global.offline, degraded: global.offline))
            return
        }
        print("The portfolio has no accounts yet.")
        return
    }

    let cache = MarketDataCache()
    var notes: [String] = []
    var summary: PortfolioSummary
    // The market store is consulted in ONLINE mode only (it powers
    // the day-change pairs); offline and --json-offline keep their
    // cost-basis contract with no daily data.
    var marketData: MarketData?

    if global.offline {
        notes.append("offline mode: positions at cost basis, no FX conversion")
        summary = portfolio.summary(displayCurrency: global.display)
    } else {
        let plan = portfolio.marketDataPlan(displayCurrency: global.display)
        let provider = YahooQuoteProvider()

        if plan.symbols.isEmpty {
            notes.append("no open positions — no quotes to fetch")
        } else {
            do {
                try await provider.refresh(cache, symbols: plan.symbols)
            } catch {
                notes.append("quote fetch failed: \(error) — positions at cost basis")
            }
        }
        for currency in plan.fxCurrencies {
            do {
                try await provider.refresh(cache, from: plan.hub, to: currency)
            } catch {
                notes.append("\(plan.hub.rawValue)-\(currency.rawValue) rate fetch failed: \(error)")
            }
        }
        notes.append(contentsOf: stalenessNotes(cache: cache, symbols: plan.symbols))
        // Read-only peek at the market store for the one-day P&L:
        // each quote is paired with that ticker's previous stored
        // close. The store is a cache — an absent or unreadable one
        // just means "no daily data", never a failed summary.
        do {
            let (marketStore, _) = try openMarketStore(global: global)
            marketData = try await marketStore.load()
        } catch {
            notes.append("market store unreadable: \(error) — no day-change data")
        }
        summary = portfolio.summary(from: cache, market: marketData, displayCurrency: global.display, maxAge: 3 * 86_400)
    }
    notes.append(contentsOf: untrackedShortNotes(summary))

    if global.json {
        let degraded = global.offline || notes.contains { $0.contains("fetch failed") }
        print(JSONOutput.summaryJSON(summary,
                                     cache: cache, market: marketData,
                                     maxAge: 3 * 86_400, now: Date.now,
                                     storePath: configuration.url.path,
                                     warnings: notes,
                                     offline: global.offline, degraded: degraded))
        return
    }

    print(SummaryRenderer.render(summary, notes: notes))
    print("")
    print("Store: \(configuration.url.path)")
}

/// `dit accounts`: the account roster with what each currently holds.
func accountsList(global: Global) async throws {
    let (store, configuration) = try openStore(global: global)
    guard let portfolio = try await store.load() else {
        if global.json {
            print(JSONOutput.envelope(schema: "accounts/1", data: [
                "accounts": [Any](), "note": "no portfolio found",
            ]))
            return
        }
        print("No portfolio found (store: \(configuration.backend.rawValue) at \(configuration.url.path)).")
        print("Add accounts and transactions first.")
        return
    }
    if portfolio.accounts.isEmpty || global.json {
        if global.json {
            print(JSONOutput.accountsListJSON(portfolio.accounts))
            return
        }
        print("The portfolio has no accounts yet.")
        return
    }
    print("Accounts:")
    let rows = portfolio.accounts.map { account in
        [
            account.displayName,
            account.institution ?? "",
            account.reportingCurrency.rawValue,
            account.taxable ? "yes" : "no",
            account.closedDate == nil ? "" : "closed \(shortDate(account.closedDate!))",
        ]
    }
    for line in Table.render(headers: ["Name", "Institution", "Ccy", "Taxable", "Status"], rows: rows) {
        print("  \(line)")
    }
}
