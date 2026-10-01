import Testing
import Foundation
@testable import DitCore

struct AccountBalancesTests {
    // MARK: Helpers

    private func account(_ name: String, currency: Currency) -> Account {
        Account(reportingCurrency: currency, name: name, institution: "Test Institution", accountNumber: "000")
    }

    private let fee2: Decimal = 2
    private let fee1: Decimal = 1

    /// Scenario: USD cash-heavy account with fees — the canonical test case.
    /// deposit 10,000 → buy 10 AAPL @ 190 (fee 2) → sell 5 AAPL @ 210 (fee 1) → dividend 50
    private func stockScenario() -> (Account, [Transaction]) {
        let a = account("Wealthsimple US", currency: .usd)
        let t1 = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            accountID: a.id,
            currency: .usd,
            kind: .deposit(amount: 10_000)
        )
        let t2 = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 2_000),
            accountID: a.id,
            currency: .usd,
            kind: .stockPurchase(StockDetails(ticker: "aapl", shares: 10, price: 190)),
            fee: fee2
        )
        let t3 = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 3_000),
            accountID: a.id,
            currency: .usd,
            kind: .stockSale(StockDetails(ticker: "AAPL", shares: 5, price: 210)),
            fee: fee1
        )
        let t4 = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 4_000),
            accountID: a.id,
            currency: .usd,
            kind: .dividend(DividendDetails(ticker: "AAPL", amount: 50))
        )
        return (a, [t4, t2, t1, t3]) // deliberately out of order
    }

    // MARK: Cash

    @Test func cashRemainingAfterTrades() {
        let (account, txs) = stockScenario()
        let b = AccountBalances.compute(account: account, transactions: txs)

        // 10,000 − (190×10 + 2) + (210×5 − 1) + 50
        #expect(b.cashByCurrency[.usd] == 9_197)
        #expect(b.cash == 9_197)
    }

    @Test func cashIsNilWithoutRatesWhenForeignCurrencyRemains() {
        let a = account("Brokerage MX", currency: .cad)
        let t1 = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            accountID: a.id,
            currency: .cad,
            kind: .deposit(amount: 5_000)
        )
        let t2 = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 2_000),
            accountID: a.id,
            currency: .usd,
            kind: .deposit(amount: 500)
        )
        let b = AccountBalances.compute(account: a, transactions: [t1, t2])

        #expect(b.cashByCurrency[.cad] == 5_000)
        #expect(b.cashByCurrency[.usd] == 500)
        #expect(b.cash == nil, "mixed currencies without a rate must not fabricate a total")

        let cadPerUsd = Decimal(string: "1.4")!
        let b2 = AccountBalances.compute(
            account: a,
            transactions: [t1, t2],
            rate: { from, to in from == .usd && to == .cad ? cadPerUsd : nil }
        )
        #expect(b2.cash == 5_700, "5,000 + 500 × 1.4")
    }

    @Test func cashUsesInverseRateWhenOnlyReverseDirectionProvided() {
        let a = account("Brokerage MX", currency: .cad)
        let depCAD = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            accountID: a.id,
            currency: .cad,
            kind: .deposit(amount: 1_000)
        )
        let depUSD = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 2_000),
            accountID: a.id,
            currency: .usd,
            kind: .deposit(amount: 500)
        )
        // Provider knows CAD→USD = 0.8 (exact inverse of 1.25); 500 / 0.8 = 625 CAD exactly.
        let b = AccountBalances.compute(
            account: a,
            transactions: [depCAD, depUSD],
            rate: { from, to in from == .cad && to == .usd ? Decimal(string: "0.8")! : nil }
        )
        #expect(b.cash == 1_625)
    }

    // MARK: Positions & P&L

    @Test func positionAverageCostIncludesFees() {
        let (account, txs) = stockScenario()
        let b = AccountBalances.compute(account: account, transactions: txs)

        #expect(b.positions.count == 1)
        let pos = b.positions[0]
        #expect(pos.symbol == "AAPL")
        #expect(pos.shares == 5)
        // (10 × 190 + 2) / 10 = 190.2
        #expect(pos.averageCostPerShare == Decimal(string: "190.2")!)
        #expect(pos.costBasis == 951)
    }

    @Test func realizedPnLFromSaleAndDividends() {
        let (account, txs) = stockScenario()
        let b = AccountBalances.compute(account: account, transactions: txs)

        // sale: (210 × 5 − 1) − (1902 × 5/10) = 1049 − 951 = 98 ; dividend: +50
        #expect(b.realizedPnL == 148)
        #expect(b.dividends == 50)
    }

    @Test func singleCurrencyInvariantHolds() {
        // cash + cost basis + live GIC == net deposits − withdrawals + realized P&L
        let (account, txs) = stockScenario()
        let b = AccountBalances.compute(account: account, transactions: txs)
        let cost = b.positions.reduce(Decimal.zero) { $0 + $1.costBasis }
        let expected: Decimal = 10_000 + 148 // annotated: 10,000 deposited + 148 realized

        #expect(b.cash! + cost + (b.gicValue ?? 0) == expected)
    }

    @Test func fullLiquidationRealizesExactCost() {
        let a = account("Liqa", currency: .usd)
        let t1 = Transaction(date: Date(timeIntervalSinceReferenceDate: 1_000), accountID: a.id,
                             currency: .usd, kind: .deposit(amount: 3_000))
        let t2 = Transaction(date: Date(timeIntervalSinceReferenceDate: 2_000), accountID: a.id,
                             currency: .usd, kind: .stockPurchase(StockDetails(ticker: "MSFT", shares: 3, price: Decimal(string: "100.07")!)))
        let t3 = Transaction(date: Date(timeIntervalSinceReferenceDate: 3_000), accountID: a.id,
                             currency: .usd, kind: .stockSale(StockDetails(ticker: "MSFT", shares: 3, price: 101)))
        let b = AccountBalances.compute(account: a, transactions: [t1, t2, t3])

        // avg cost 100.07; position fully sold out
        // realized: 303 − 300.21 = 2.79 ; cash: 3000 − 300.21 + 303 = 3002.79
        #expect(b.positions.isEmpty)
        #expect(b.realizedPnL == Decimal(string: "2.79")!)
        #expect(b.cash == Decimal(string: "3002.79")!)
    }

    @Test func unrealizedPnLAndMarketTotalUseQuotes() {
        let (account, txs) = stockScenario()
        let last250: LastPrice = { currency, symbol in
            (currency == .usd && symbol == "AAPL") ? 250 : nil
        }
        let b = AccountBalances.compute(
            account: account, transactions: txs, lastPrice: last250
        )

        // 5 × (250 − 190.2) = 299
        #expect(b.unrealizedPnL == 299)
        // cash 9197 + 5 × 250
        let expectedMarket: Decimal = 9_197 + 1_250
        #expect(b.totalValue == expectedMarket)

        // Without quotes: total falls back to cost basis; unrealized is nil.
        let bare = AccountBalances.compute(account: account, transactions: txs)
        #expect(bare.unrealizedPnL == nil)
        let expectedCost: Decimal = 9_197 + 951
        #expect(bare.totalValue == expectedCost)
    }

    // MARK: GICs

    @Test func gicLifeCycleRealizesGainAtRedemption() {
        let a = account("TF-SA", currency: .cad)
        let purchase = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            accountID: a.id,
            currency: .cad,
            kind: .gicPurchase(GICDetails(
                product: "5-Year Prime+ GIC",
                principal: 25_000,
                rate: 0.041,
                compounding: .annual,
                maturityDate: Date(timeIntervalSinceReferenceDate: 300_000),
                redeemable: false))
        )
        let t1 = Transaction(date: Date(timeIntervalSinceReferenceDate: 500), accountID: a.id,
                             currency: .cad, kind: .deposit(amount: 25_000))
        let t2 = Transaction(date: Date(timeIntervalSinceReferenceDate: 2_000), accountID: a.id,
                             currency: .cad, kind: .gicRedemption(GICRedemptionDetails(purchaseID: purchase.id, proceeds: 26_850)))

        // While live: cash 0, GIC at par.
        let live = AccountBalances.compute(account: a, transactions: [t1, purchase])
        #expect(live.cash == 0)
        #expect(live.gicValue == 25_000)
        #expect(live.realizedPnL == 0)
        #expect(live.totalValue == 25_000)

        // After redemption: gain of 1,850 booked.
        let done = AccountBalances.compute(account: a, transactions: [t1, purchase, t2])
        #expect(done.gicValue == 0)
        #expect(done.cash == 26_850)
        #expect(done.realizedPnL == 1_850)
        #expect(done.positions.isEmpty)
    }

    @Test func redemptionWithoutMatchingPurchaseFabricatesNothing() {
        let a = account("Orphan", currency: .cad)
        let orphan = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 1_000),
            accountID: a.id,
            currency: .cad,
            kind: .gicRedemption(GICRedemptionDetails(purchaseID: UUID(), proceeds: 99_999))
        )
        let b = AccountBalances.compute(account: a, transactions: [orphan])
        #expect(b.realizedPnL == 0, "no purchase → no principal → no invented gain")
    }

    // MARK: FX conversion

    @Test func fxConversionMovesCashBetweenCurrenciesWithNoPnL() {
        let a = account("FX", currency: .cad)
        let t1 = Transaction(date: Date(timeIntervalSinceReferenceDate: 1_000), accountID: a.id,
                             currency: .cad, kind: .deposit(amount: 5_000))
        let t2 = Transaction(date: Date(timeIntervalSinceReferenceDate: 2_000), accountID: a.id,
                             currency: .usd, kind: .deposit(amount: 1_500))
        let t3 = Transaction(   // currency is the *to* currency
            date: Date(timeIntervalSinceReferenceDate: 3_000),
            accountID: a.id,
            currency: .cad,
            kind: .fxConversion(FXDetails(fromCurrency: .usd, fromAmount: 1_000, toAmount: 1_380)),
            fee: fee1
        )
        let b = AccountBalances.compute(account: a, transactions: [t1, t2, t3])

        #expect(b.cashByCurrency[.cad] == 6_379, "5,000 + 1,380 − 1 fee")
        #expect(b.cashByCurrency[.usd] == 500, "1,500 − 1,000 converted")
        #expect(b.realizedPnL == 0, "a conversion is currency movement, not P&L")
    }

    @Test func fxFullyConvertedNeedsNoRate() {
        let a = account("FX2", currency: .cad)
        let t1 = Transaction(date: Date(timeIntervalSinceReferenceDate: 1_000), accountID: a.id,
                             currency: .cad, kind: .deposit(amount: 5_000))
        let t2 = Transaction(date: Date(timeIntervalSinceReferenceDate: 2_000), accountID: a.id,
                             currency: .usd, kind: .deposit(amount: 1_000))
        let t3 = Transaction(
            date: Date(timeIntervalSinceReferenceDate: 3_000),
            accountID: a.id,
            currency: .cad,
            kind: .fxConversion(FXDetails(fromCurrency: .usd, fromAmount: 1_000, toAmount: 1_380))
        )
        let b = AccountBalances.compute(account: a, transactions: [t1, t2, t3])

        #expect(b.cashByCurrency[.usd] == 0)
        #expect(b.cash == 6_380, "foreign bucket nets to zero → combinable without a rate")
    }

    // MARK: Portfolio lookups

    @Test func balanceLookupsByNameAndID() {
        let (usdAccount, txs) = stockScenario()
        let gicAccount = account("Questrade GIC", currency: .cad)
        let portfolio = Portfolio(accounts: [usdAccount, gicAccount], transactions: txs, tickers: [])

        #expect(portfolio.balance(forAccountName: " wealthsimple us ")?.cash == 9_197)
        #expect(portfolio.balance(forAccountID: usdAccount.id)?.cash == 9_197)
        #expect(portfolio.balance(forAccountID: UUID()) == nil)
        #expect(portfolio.balance(forAccountName: "nope") == nil)
        #expect(portfolio.account(named: "Wealthsimple US")?.id == usdAccount.id)
    }
}

// MARK: - Untracked shorts (sales below zero)

private func walletTx(_ dayOffset: Int, _ kind: Transaction.Kind) -> Transaction {
    Transaction(date: Date(timeIntervalSince1970: TimeInterval(dayOffset * 86_400)),
                accountID: walletForShorts.id, currency: .cad, kind: kind)
}

private let walletForShorts = Account(reportingCurrency: .cad, name: "Wallet")

@Test("a sale below zero: cash is booked in full, the short is flagged, not shown as a position")
func saleBelowZeroIsFlagged() {
    let history = [
        walletTx(1, .stockPurchase(StockDetails(ticker: "SHOP.TO", shares: 10, price: 100))),
        walletTx(2, .stockSale(StockDetails(ticker: "SHOP.TO", shares: 14, price: 100))),
    ]
    let b = AccountBalances.compute(account: walletForShorts, transactions: history)
    #expect(b.positions.isEmpty)
    #expect(b.cash == 400) // −1000 + 1400: the ledger records what happened
    #expect(b.untrackedShorts == [UntrackedShort(currency: .cad, symbol: "SHOP.TO", shares: 4)])

    // A within-holding sale is not a short.
    let flat = AccountBalances.compute(
        account: walletForShorts,
        transactions: [walletTx(1, .stockPurchase(StockDetails(ticker: "SHOP.TO", shares: 10, price: 100))),
                       walletTx(2, .stockSale(StockDetails(ticker: "SHOP.TO", shares: 10, price: 100)))])
    #expect(flat.untrackedShorts.isEmpty)

    // Excess accumulates across separate below-zero sales.
    let twice = AccountBalances.compute(
        account: walletForShorts,
        transactions: [walletTx(1, .stockSale(StockDetails(ticker: "ENB.TO", shares: 3, price: 40))),
                       walletTx(2, .stockSale(StockDetails(ticker: "ENB.TO", shares: 2, price: 42)))])
    #expect(twice.untrackedShorts == [UntrackedShort(currency: .cad, symbol: "ENB.TO", shares: 5)])
}

@Test("portfolio summary carries untracked shorts with the account attached")
func summaryFlagsShorts() {
    let history = [walletTx(1, .stockPurchase(StockDetails(ticker: "SHOP.TO", shares: 10, price: 100))),
                   walletTx(2, .stockSale(StockDetails(ticker: "SHOP.TO", shares: 14, price: 100)))]
    let portfolio = Portfolio(accounts: [walletForShorts], transactions: history)
    let summary = portfolio.summary()
    #expect(summary.untrackedShorts == [
        ShortSaleFlag(accountName: "Wallet", symbol: "SHOP.TO", currency: .cad, shares: 4),
    ])
}

@Test("a redemption — even a partial one — ends its GIC; cash and realized say so")
func partialRedemptionEndsGIC() {
    let purchase = Transaction(
        date: Date(timeIntervalSince1970: 86_400), accountID: walletForShorts.id, currency: .cad,
        kind: .gicPurchase(GICDetails(product: "G", principal: 10_000, rate: 0.041,
                                      compounding: .annual,
                                      maturityDate: Date(timeIntervalSince1970: 86_400 * 999),
                                      redeemable: false)))
    let redeem = Transaction(
        date: Date(timeIntervalSince1970: 86_400 * 2), accountID: walletForShorts.id, currency: .cad,
        kind: .gicRedemption(GICRedemptionDetails(purchaseID: purchase.id, proceeds: 2_000)))
    let b = AccountBalances.compute(account: walletForShorts, transactions: [purchase, redeem])
    #expect(b.cash == -8_000)          // −10,000 principal + 2,000 back
    #expect(b.gicValue == 0)          // no live GIC left
    #expect(b.realizedPnL == -8_000)  // the un-redeemed remainder is booked as lost
}

@Test("any drained pool going negative warns loudly — and still records")
func drainedPoolWarns() throws {
    let deposit = walletTx(1, .deposit(amount: 1_000))
    let portfolio = Portfolio(accounts: [walletForShorts], transactions: [deposit])
    let fx = Transaction(
        date: Date(timeIntervalSince1970: 86_400 * 2), accountID: walletForShorts.id, currency: .usd,
        kind: .fxConversion(FXDetails(fromCurrency: .cad, fromAmount: 5_000, toAmount: 3_700)))
    let (updated, notes) = try portfolio.addingTransaction(fx)
    #expect(updated.transactions.count == 2) // fact recorded, not refused
    #expect(notes.contains { $0.contains("warning") && $0.contains("CAD cash goes negative") })
}
