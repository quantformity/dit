import Foundation
import Testing

@testable import DirectInvestTracker

private func day(_ offset: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(offset * 86_400)) }
private func d(_ raw: String) -> Decimal { Decimal(string: raw)! }

private let wallet = Account(name: "Wallet")

private func tx(
    id: UUID = UUID(),
    account: Account = wallet,
    day offset: Int = 0,
    currency: Currency = .cad,
    kind: Transaction.Kind,
    fee: Decimal? = nil
) -> Transaction {
    Transaction(id: id, date: day(offset), accountID: account.id,
                currency: currency, kind: kind, fee: fee)
}

// MARK: - adding

@Test("adding to an unknown account is refused")
func addUnknownAccount() {
    let stranger = Account(name: "Elsewhere")
    let newTx = tx(account: stranger, kind: .deposit(amount: 100))
    #expect(throws: MutationError.accountNotFound(stranger.id)) {
        _ = try Portfolio(accounts: [wallet]).addingTransaction(newTx)
    }
}

@Test("impossible payloads are refused: zero, negative, same-currency fx, empty ticker")
func addInvalidPayloads() {
    let portfolio = Portfolio(accounts: [wallet])
    let bad: [Transaction] = [
        tx(kind: .deposit(amount: 0)),
        tx(kind: .withdrawal(amount: -5)),
        tx(kind: .fxConversion(FXDetails(fromCurrency: .cad, fromAmount: 100, toAmount: 100))),
        tx(currency: .usd, kind: .fxConversion(FXDetails(fromCurrency: .usd, fromAmount: 100, toAmount: 130))),
        tx(kind: .fxConversion(FXDetails(fromCurrency: .usd, fromAmount: 0, toAmount: 130))),
        tx(currency: .usd, kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 0, price: 200))),
        tx(currency: .usd, kind: .stockSale(StockDetails(ticker: "", shares: 1, price: 200))),
        tx(kind: .gicPurchase(GICDetails(product: "X", principal: 100, rate: -0.01,
                                          compounding: .annual, maturityDate: day(1), redeemable: false))),
        tx(kind: .deposit(amount: 100), fee: -1),
    ]
    for badTx in bad {
        #expect(throws: (any Error).self) { _ = try portfolio.addingTransaction(badTx) }
    }
}

@Test("a first-seen ticker is auto-registered in the trade's currency")
func addAutoRegistersTicker() throws {
    let portfolio = Portfolio(accounts: [wallet])
    let buy = tx(currency: .usd, kind: .stockPurchase(StockDetails(ticker: "NVDA", shares: 5, price: 200)))
    let (updated, notes) = try portfolio.addingTransaction(buy)
    #expect(updated.tickers.contains { $0.symbol == "NVDA" && $0.currency == .usd })
    #expect(notes.contains { $0.contains("registered ticker 'NVDA'") })
    // Second trade with the same ticker does not duplicate the registry entry.
    let again = tx(currency: .usd, kind: .stockPurchase(StockDetails(ticker: "NVDA", shares: 1, price: 210)))
    let (second, secondNotes) = try updated.addingTransaction(again)
    #expect(second.tickers.filter { $0.symbol == "NVDA" }.count == 1)
    #expect(!secondNotes.contains { $0.contains("registered") })
}

@Test("a GIC redemption must reference a purchase in the same account")
func addRedemptionNeedsPurchase() throws {
    let purchase = tx(kind: .gicPurchase(GICDetails(product: "RBC 5yr", principal: 1000,
                                                     rate: 0.041, compounding: .annual,
                                                     maturityDate: day(365), redeemable: false)))
    let redeem = tx(id: UUID(), day: 1,
                    kind: .gicRedemption(GICRedemptionDetails(purchaseID: purchase.id, proceeds: 1041)))
    // Dangling: purchase absent.
    #expect(throws: MutationError.danglingRedemption(purchaseID: purchase.id)) {
        _ = try Portfolio(accounts: [wallet]).addingTransaction(redeem)
    }
    // Linked: purchase present → accepted.
    let withPurchase = Portfolio(accounts: [wallet], transactions: [purchase])
    let (updated, notes) = try withPurchase.addingTransaction(redeem)
    #expect(updated.transactions.count == 2)
    #expect(notes.first?.contains("GIC redemption") == true)
    // A purchase in a *different* account does not count.
    let elsewhere = Account(name: "Other")
    let split = Portfolio(accounts: [wallet, elsewhere],
                          transactions: [tx(account: elsewhere, kind: .gicPurchase(
                            GICDetails(product: "RBC 5yr", principal: 1000, rate: 0.041,
                                       compounding: .annual, maturityDate: day(365), redeemable: false)))])
    #expect(throws: MutationError.danglingRedemption(purchaseID: purchase.id)) {
        _ = try split.addingTransaction(redeem)
    }
}

@Test("withdrawals beyond available cash are recorded, with a loud warning")
func addOversizedWithdrawal() throws {
    let deposit = tx(kind: .deposit(amount: 1000))
    let portfolio = Portfolio(accounts: [wallet], transactions: [deposit])
    let big = tx(day: 1, kind: .withdrawal(amount: 1500))
    let (updated, notes) = try portfolio.addingTransaction(big)
    #expect(updated.transactions.count == 2) // fact recorded, not refused
    #expect(notes.contains { $0.contains("warning") && $0.contains("negative") })
    // Within cash: no warning.
    let ok = tx(day: 1, kind: .withdrawal(amount: 400))
    let (_, okNotes) = try portfolio.addingTransaction(ok)
    #expect(!okNotes.contains { $0.hasPrefix("warning") })
}

// MARK: - editing

@Test("an unknown transaction id is an error")
func editUnknownId() {
    let missing = UUID()
    #expect(throws: MutationError.transactionNotFound(missing)) {
        _ = try Portfolio(accounts: [wallet]).editingTransaction(id: missing, [.date(day(1))])
    }
}

@Test("changing what a transaction IS is refused — including deposit→withdrawal")
func editKindFamilyRefused() throws {
    let deposit = tx(kind: .deposit(amount: 1000))
    let portfolio = Portfolio(accounts: [wallet], transactions: [deposit])
    #expect(throws: MutationError.kindChange(deposit.id)) {
        _ = try portfolio.editingTransaction(id: deposit.id, [.kind(.withdrawal(amount: 1000))])
    }
    let buy = tx(currency: .usd, kind: .stockPurchase(StockDetails(ticker: "SHOP.TO", shares: 10, price: 180)))
    let tradeBook = Portfolio(accounts: [wallet], transactions: [buy])
    #expect(throws: MutationError.kindChange(buy.id)) {
        _ = try tradeBook.editingTransaction(
            id: buy.id, [.kind(.stockSale(StockDetails(ticker: "SHOP.TO", shares: 10, price: 180)))])
    }
    // Same family, changed payload: an allowed edit.
    let (updated, notes) = try portfolio.editingTransaction(id: deposit.id, [.kind(.deposit(amount: 900))])
    #expect(updated.transactions[0].summaryLine.contains("900"))
    #expect(notes.contains { $0.contains("corrected") && $0.contains("→") })
}

@Test("value edits compose: date + fee removal in one go")
func editComposes() throws {
    let buy = tx(currency: .usd, kind: .stockPurchase(StockDetails(ticker: "SHOP.TO", shares: 10, price: 180)),
                 fee: 1)
    let portfolio = Portfolio(accounts: [wallet], transactions: [buy])
    let (updated, notes) = try portfolio.editingTransaction(
        id: buy.id,
        [.date(day(2)),
         .fee(nil),
         .kind(.stockPurchase(StockDetails(ticker: "SHOP.TO", shares: 10, price: d("179.95"))))])
    let edited = updated.transactions[0]
    #expect(edited.date == day(2))
    #expect(edited.fee == nil)
    #expect(edited.summaryLine.contains("179.95"))
    #expect(notes.count == 1)
    // No-ops are refused so a typo'd command never looks like success.
    #expect(throws: MutationError.nothingToEdit(buy.id)) {
        _ = try portfolio.editingTransaction(id: buy.id, [.date(day(0)), .fee(1)])
    }
    // An edited payload must still be possible.
    #expect(throws: (any Error).self) {
        _ = try portfolio.editingTransaction(
            id: buy.id,
            [.kind(.stockPurchase(StockDetails(ticker: "SHOP.TO", shares: -1, price: 180)))])
    }
}

@Test("editing a GIC's principal warns about linked redemptions")
func editGicBreaksRedemptionLink() throws {
    let purchase = tx(kind: .gicPurchase(GICDetails(product: "RBC 5yr", principal: 1000,
                                                     rate: 0.041, compounding: .annual,
                                                     maturityDate: day(365), redeemable: false)))
    let redeem = tx(day: 1, kind: .gicRedemption(
        GICRedemptionDetails(purchaseID: purchase.id, proceeds: 1041)))
    let portfolio = Portfolio(accounts: [wallet], transactions: [purchase, redeem])
    let (updated, notes) = try portfolio.editingTransaction(
        id: purchase.id,
        [.kind(.gicPurchase(GICDetails(product: "RBC 5yr", principal: 900, rate: 0.041,
                                       compounding: .annual, maturityDate: day(365), redeemable: false)))])
    #expect(updated.transactions.count == 2)
    #expect(notes.contains { $0.contains("linked redemption") && $0.contains("recomputed") })
    // Same principal (rate-only edit) keeps the link quiet.
    let (_, quietNotes) = try portfolio.editingTransaction(
        id: purchase.id,
        [.kind(.gicPurchase(GICDetails(product: "RBC 5yr", principal: 1000, rate: 0.042,
                                       compounding: .annual, maturityDate: day(365), redeemable: false)))])
    #expect(!quietNotes.contains { $0.contains("recomputed") })
}

// MARK: - deleting

@Test("deleting reports position and cash impact")
func removeImpact() throws {
    let deposit = tx(kind: .deposit(amount: 1000))
    let buy = tx(day: 1, currency: .usd, kind: .stockPurchase(StockDetails(ticker: "SHOP.TO", shares: 10, price: 180)),
                 fee: 1)
    let portfolio = Portfolio(accounts: [wallet], transactions: [deposit, buy])
    let (updated, notes) = try portfolio.removingTransaction(id: buy.id)
    #expect(updated.transactions.count == 1)
    #expect(notes.contains { $0.contains("SHOP.TO: 10 → 0 shares") || $0.contains("closes") })
    #expect(notes.contains { $0.contains("USD cash -1801 → 0") })

    #expect(throws: MutationError.transactionNotFound(deposit.id)) {
        _ = try Portfolio(accounts: [wallet]).removingTransaction(id: deposit.id)
    }
}

@Test("deleting an fx conversion shows both currency pools")
func removeFxImpact() throws {
    let fx = tx(currency: .cad, kind: .fxConversion(
        FXDetails(fromCurrency: .usd, fromAmount: 1000, toAmount: 1360)))
    let portfolio = Portfolio(accounts: [wallet], transactions: [fx])
    let (_, notes) = try portfolio.removingTransaction(id: fx.id)
    #expect(notes.contains { $0.contains("USD cash -1000 → 0") })
    #expect(notes.contains { $0.contains("CAD cash 1360 → 0") })
}

@Test("deleting a GIC purchase warns about orphaned redemptions")
func removeGicOrphansRedemption() throws {
    let purchase = tx(kind: .gicPurchase(GICDetails(product: "RBC 5yr", principal: 1000,
                                                     rate: 0.041, compounding: .annual,
                                                     maturityDate: day(365), redeemable: false)))
    let redeem = tx(day: 1, kind: .gicRedemption(
        GICRedemptionDetails(purchaseID: purchase.id, proceeds: 1041)))
    let portfolio = Portfolio(accounts: [wallet], transactions: [purchase, redeem])
    let (updated, notes) = try portfolio.removingTransaction(id: purchase.id)
    #expect(updated.transactions.count == 1)
    #expect(notes.contains { $0.contains("lose their GIC") })
}

// MARK: - rendering

@Test("summaryLine renders every kind exactly")
func summaryLines() {
    let purchase = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
    let lines: [(Transaction, String)] = [
        (tx(kind: .deposit(amount: d("1000"))), "deposit 1000 CAD"),
        (tx(kind: .withdrawal(amount: d("50")), fee: d("1")), "withdrawal 50 CAD fee 1"),
        (tx(currency: .cad, kind: .stockPurchase(StockDetails(ticker: "SHOP.TO", shares: 10, price: d("180.00")))),
         "buy 10 SHOP.TO @ 180"),
        (tx(currency: .cad, kind: .stockSale(StockDetails(ticker: "SHOP.TO", shares: 3, price: 200))),
         "sell 3 SHOP.TO @ 200"),
        (tx(currency: .usd, kind: .dividend(DividendDetails(ticker: "NVDA", amount: d("12.50")))),
         "dividend NVDA 12.5 USD"),
        (tx(kind: .gicRedemption(GICRedemptionDetails(purchaseID: purchase, proceeds: 1041))),
         "GIC redemption 1041 CAD (purchase 00000000)"),
        (tx(currency: .cad, kind: .fxConversion(FXDetails(fromCurrency: .usd, fromAmount: 1000, toAmount: 1360))),
         "fx 1000 USD → 1360 CAD"),
    ]
    for (transaction, expected) in lines {
        #expect(transaction.summaryLine == expected, "rendered '\(transaction.summaryLine)'")
    }
}