import Foundation
import Testing
@testable import DirectInvestTracker

/// Pins the CONTRACTS of the shared formatting/replay layer (introduced
/// when the CLI stopped hand-rolling formatters): if a refactor changes
/// how money, dates, or replay order render, these fail — the same
/// promise the byte-diffed CLI outputs made by hand.
struct TextFormatTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    // MARK: display vs machine money

    @Test func displayMoneyGroupsAndPads() {
        #expect(TextFormat.money(dec("1234.5")) == "1,234.50")
        #expect(TextFormat.money(dec("-6768.5")) == "-6,768.50")
        #expect(TextFormat.money(dec("1234567.89")) == "1,234,567.89")
    }

    @Test func machineMoneyNeverGroups() {
        // The JSON contract (docs/json.md): parsers must never see a
        // comma or a binary double.
        #expect(TextFormat.fixed(dec("279900.6"), scale: 2) == "279900.60")
        #expect(TextFormat.fixed(dec("1.4187"), scale: 6) == "1.418700")
        #expect(!TextFormat.fixed(dec("1234567.891"), scale: 2).contains(","))
        #expect(TextFormat.plainQuantity(dec("840")) == "840")
        #expect(TextFormat.plainQuantity(dec("96.7")) == "96.7")
    }

    @Test func displayAndMachineAgreeOnceCommasAreRemoved() {
        // One formatting brain, two alphabets: the ONLY difference is
        // grouping (and both round the same way for exact inputs).
        for raw in ["1234.56", "-1234.56", "0.5", "1234567.89"] {
            let v = dec(raw)
            let display = TextFormat.money(v).replacingOccurrences(of: ",", with: "")
            #expect(display == TextFormat.fixed(v, scale: 2), "drift on \(raw)")
        }
    }

    @Test func quantityTrimsTrailingZeros() {
        #expect(TextFormat.quantity(dec("42.7674")) == "42.7674")
        #expect(TextFormat.quantity(dec("1260")) == "1,260")
        #expect(TextFormat.quantity(dec("96.70")) == "96.7")
    }

    // MARK: dates

    @Test func dayAndStampAreUTCByContract() {
        // Noon UTC — safe from any host-zone day boundary.
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 29
        components.hour = 12; components.minute = 51
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let instant = calendar.date(from: components)!
        #expect(TextFormat.day(instant) == "2026-09-29")
        #expect(TextFormat.isoStamp(instant) == "2026-09-29T12:51:00Z")
    }

    // MARK: replay order

    private func tx(_ day: Int, _ kind: Transaction.Kind, accountID: UUID = UUID()) -> Transaction {
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return Transaction(date: calendar.date(from: components)!, accountID: accountID,
                           currency: .cad, kind: kind)
    }

    @Test func replayOrderIsDateThenStorageOrder() {
        let later = tx(10, .deposit(amount: 5))
        let earlyA = tx(5, .deposit(amount: 1))
        let earlyB = tx(5, .withdrawal(amount: 2))
        let ordered = Replay.ordered([later, earlyA, earlyB])
        // Earlier date first; same-day ties keep STORAGE order —
        // earlyA was stored before earlyB.
        #expect(ordered.map(\.kind.kindName) == ["deposit", "withdrawal", "deposit"])
        // Deterministic: identical input replays identically.
        #expect(Replay.ordered([later, earlyA, earlyB]).map(\.id) == ordered.map(\.id))
    }

    @Test func statementMergeKeepsPerAccountChainsReadable() {
        // The all-accounts statement interleaves accounts; each
        // account's own running chain must stay monotonic in display
        // order (display order == replay order per account).
        let a = Account(reportingCurrency: .cad, name: "A")
        let b = Account(reportingCurrency: .cad, name: "B")
        var portfolio = Portfolio(accounts: [a, b])
        portfolio.transactions = [
            tx(5, .deposit(amount: 100), accountID: a.id),
            tx(5, .withdrawal(amount: 40), accountID: a.id),
            tx(5, .deposit(amount: 70), accountID: b.id),
        ]
        let rows = LedgerStatement.rows(portfolio: portfolio)
        let aChain = rows.filter { $0.transaction.accountID == a.id }.map { $0.cashAfter.first?.amount }
        #expect(aChain == [Decimal(100), Decimal(60)])
    }
}

struct PortfolioDisplayHelpersTests {

    @Test func accountNameFallsBackToDash() {
        let account = Account(reportingCurrency: .usd, name: "Mercury")
        let portfolio = Portfolio(accounts: [account])
        #expect(portfolio.accountName(for: account.id) == "Mercury")
        #expect(portfolio.accountName(for: UUID()) == "\u{2014}")
    }

    @Test func trackedSharesSumWholeLedgerIncludingShorts() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        func trade(_ accountID: UUID, _ kind: Transaction.Kind) -> Transaction {
            Transaction(date: day, accountID: accountID, currency: .usd, kind: kind)
        }
        let a = Account(reportingCurrency: .usd, name: "A")
        let b = Account(reportingCurrency: .usd, name: "B")
        var portfolio = Portfolio(accounts: [a, b])
        portfolio.transactions = [
            trade(a.id, .stockPurchase(StockDetails(ticker: "RBLX", shares: 100, price: 70))),
            trade(a.id, .stockSale(StockDetails(ticker: "RBLX", shares: 150, price: 50))),
        ]
        // -50, NOT clamped to 0: the SHORT warning must see the hole.
        #expect(portfolio.trackedSharesHeld(accountID: a.id, symbol: "RBLX") == Decimal(-50))
        // Other accounts and other tickers stay out of the count.
        portfolio.transactions.append(trade(b.id, .stockPurchase(StockDetails(ticker: "RBLX", shares: 10, price: 70))))
        #expect(portfolio.trackedSharesHeld(accountID: a.id, symbol: "RBLX") == Decimal(-50))
        #expect(portfolio.trackedSharesHeld(accountID: a.id, symbol: "AAPL") == 0)
    }
}
