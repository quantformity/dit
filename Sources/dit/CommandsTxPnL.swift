import Foundation
import DitCore

// MARK: - `dit tx pnl` — transaction-level P&L (thin shell)
//
// All math lives in DitCore (`TradePnL.compute`) so the unit tests and
// the `dit pnl` reconciliation check the SAME code the CLI prints.
// This file only resolves scope, prints, and serializes.

/// Signed money for the P&L column: "+15.00", "-360.00", and —
/// crucially — "—" for withheld figures (a dash is not zero).
func signedPnL(_ amount: Decimal?, marker: String = "") -> String {
    guard let amount else { return "—" }
    let text = TextFormat.money(abs(amount))
    let sign = amount > 0 ? "+" : (amount < 0 ? "-" : " ")
    return "\(sign)\(text)\(marker)"
}

func txTradePnL(_ args: [String], global: Global) async throws {
    let options = try Options(args, valueOptions: ["account", "ticker"])
    guard options.positionals.isEmpty else {
        throw ParseError("unexpected argument '\(options.positionals[0])' — "
            + "accounts go in --account, symbols in --ticker (see 'dit help tx')")
    }
    let (store, configuration) = try openStore(global: global)

    // MARK: Market data — stored closes only, never the network.
    // An unreadable market store dashes every open mark; the booked
    // (realized) rows stay exact because ledger facts need no prices.
    var marketData: MarketData?
    var notes: [String] = []
    do {
        let (marketStore, _) = try openMarketStore(global: global)
        marketData = try await marketStore.load()
    } catch {
        notes.append("market store unreadable: \(error) — open positions cannot be marked")
    }

    guard let portfolio = try await store.load() else {
        if global.json {
            print(JSONOutput.envelope(schema: "tx-pnl/1", data: [
                "empty": true,
                "note": "no portfolio found — add accounts and transactions first",
                "store": configuration.url.path,
            ]))
            return
        }
        print("No portfolio found (store: \(configuration.backend.rawValue) at \(configuration.url.path)).")
        print("Nothing to report — add accounts and transactions first.")
        return
    }

    let (accounts, scope) = try tradePnLScope(portfolio: portfolio, options: options)
    var symbolFilter: Set<String>?
    if let raw = options["ticker"] {
        let list = splitCSV(raw).map { $0.uppercased() }
        guard !list.isEmpty else { throw ParseError("--ticker needs at least one symbol") }
        symbolFilter = Set(list)
    }
    let report = TradePnL.compute(portfolio: portfolio, accounts: accounts, asOf: Date.now,
                                  market: marketData, symbols: symbolFilter, currencies: nil)

    if global.json {
        print(JSONOutput.envelope(schema: "tx-pnl/1",
                                  data: tradePnLJSON(report: report, scope: scope,
                                                     extraNotes: notes)))
        return
    }

    let asOfText = TextFormat.day(report.asOf)
    print("Trade P&L — lifetime per-transaction view, FIFO lot attribution (open marks: last stored close on/before \(asOfText))")
    print("Scope: \(scope) — amounts are NATIVE currency, never mixed or summed across currencies")
    if report.isEmpty {
        print("No booked P&L and no open positions — nothing to report.")
        return
    }

    if !report.booked.isEmpty {
        print("")
        print("Booked at the transaction (realized at the time it booked):")
        print(Table.render(
            headers: ["Date", "Account", "Kind", "Symbol", "Ccy", "P&L", "Where it came from"],
            rows: report.booked.map { row in
                [TextFormat.day(row.date), row.accountName, row.kind, row.symbol,
                 row.currency.rawValue, signedPnL(row.pnl),
                 row.detail + "  [" + String(row.txID.uuidString.prefix(8)) + "]"]
            },
            leftColumns: [0, 1, 2, 3, 6]).joined(separator: "\n"))
    }
    if !report.open.isEmpty {
        print("")
        print("Open — per buy (unrealized at last stored close — dashes are withheld, never zero):")
        print(Table.render(
            headers: ["Bought", "Account", "Symbol", "Ccy", "Still held", "Cost left",
                      "Last close", "Unrealized", "Tx"],
            rows: report.open.map { row in
                let markText: String
                if let mark = row.mark, let day = row.markDay {
                    markText = "\(TextFormat.quantity(mark)) (\(TextFormat.day(day)))"
                } else {
                    markText = "NO MARK (no stored close)"
                }
                let marker = row.derived ? "*" : ""
                return [TextFormat.day(row.buyDate), row.accountName, row.symbol,
                        row.currency.rawValue,
                        "\(TextFormat.quantity(row.heldShares)) of \(TextFormat.quantity(row.boughtShares)) sh",
                        TextFormat.money(row.cost), markText,
                        signedPnL(row.unrealized, marker: marker),
                        String(row.txID.uuidString.prefix(8))]
            },
            leftColumns: [0, 1, 2, 4, 8]).joined(separator: "\n"))
    }

    print("")
    print("Totals per currency (native units; a DASH total is withheld by design, never a fake zero):")
    print(Table.render(
        headers: ["Ccy", "Booked", "Open", "Total"],
        rows: report.perCurrency.map { total in
            [total.currency.rawValue, signedPnL(total.booked), signedPnL(total.open),
             signedPnL(total.total) + (total.total == nil ? " [withheld — incomplete by design]" : "")]
        },
        leftColumns: [0]).joined(separator: "\n"))
    let allNotes = notes + report.notes
    if !allNotes.isEmpty {
        print("")
        for note in allNotes { print("  ! \(note)") }
    }
}

/// Resolve the account scope (default: every account).
private func tradePnLScope(portfolio: Portfolio, options: Options)
    throws -> (accounts: [Account], scope: String) {
    var scope = "all accounts"
    guard let raw = options["account"] else { return (portfolio.accounts, scope) }
    let names = splitCSV(raw)
    guard !names.isEmpty else {
        throw ParseError("--account needs at least one account name (see 'dit accounts')")
    }
    var resolved: [Account] = []
    for name in names { resolved.append(try resolveAccount(name, in: portfolio)) }
    var seen = Set<UUID>()
    scope = names.joined(separator: ", ")
    return (resolved.filter { seen.insert($0.id).inserted }, scope)
}

/// The `tx-pnl/1` document. Amounts are fixed-decimal STRINGS (never
/// grouped), native currency per row; withheld figures are JSON
/// `null` — a machine reader must tell "no data" from "zero" too.
private func tradePnLJSON(report: TradePnLReport, scope: String,
                          extraNotes: [String]) -> [String: Any] {
    var booked: [[String: Any]] = []
    for row in report.booked {
        booked.append([
            "id": row.txID.uuidString,
            "date": TextFormat.day(row.date),
            "account": row.accountName,
            "kind": row.kind,
            "symbol": row.symbol,
            "currency": row.currency.rawValue,
            "pnl": TextFormat.fixed(row.pnl, scale: 2),
            "detail": row.detail,
            "incomplete": row.incomplete,
        ])
    }
    var open: [[String: Any]] = []
    for row in report.open {
        open.append([
            "account": row.accountName,
            "id": row.txID.uuidString,
            "date": TextFormat.day(row.buyDate),
            "symbol": row.symbol,
            "currency": row.currency.rawValue,
            "bought": TextFormat.plainQuantity(row.boughtShares),
            "held": TextFormat.plainQuantity(row.heldShares),
            "cost": TextFormat.fixed(row.cost, scale: 2),
            "mark": row.mark.map { TextFormat.fixed($0, scale: 4) } ?? NSNull(),
            "markDay": row.markDay.map { TextFormat.day($0) } ?? NSNull(),
            "markKind": row.mark == nil ? NSNull() : (row.derived ? "derived" : "stored"),
            "unrealized": row.unrealized.map { TextFormat.fixed($0, scale: 2) } ?? NSNull(),
        ])
    }
    var totals: [[String: Any]] = []
    for total in report.perCurrency {
        totals.append([
            "currency": total.currency.rawValue,
            "booked": TextFormat.fixed(total.booked, scale: 2),
            "open": total.open.map { TextFormat.fixed($0, scale: 2) } ?? NSNull(),
            "total": total.total.map { TextFormat.fixed($0, scale: 2) } ?? NSNull(),
        ])
    }
    return [
        "asOf": TextFormat.day(report.asOf),
        "scope": scope,
        "policy": "fifo-lots",
        "booked": booked,
        "open": open,
        "currencyTotals": totals,
        "notes": extraNotes + report.notes,
    ]
}