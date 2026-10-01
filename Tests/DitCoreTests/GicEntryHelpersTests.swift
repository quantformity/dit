import Foundation
import Testing

@testable import DitCore

private func day(_ offset: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(offset * 86_400)) }

private let wallet = Account(name: "Wallet")

private func gic(
    id: UUID = UUID(),
    account: Account = wallet,
    product: String,
    principal: String = "10000"
) -> Transaction {
    Transaction(
        id: id, date: day(100), accountID: account.id, currency: .cad,
        kind: .gicPurchase(GICDetails(
            product: product, principal: Decimal(string: principal)!, rate: 0.041,
            compounding: .annual, maturityDate: day(2000), redeemable: false)))
}

// MARK: - findGICPurchase

@Test("a redemption can name its GIC by product, case- and space-insensitively")
func findGICByProductName() throws {
    let first = gic(product: "5-Year Prime+ GIC")
    let noise = Transaction(
        date: day(50), accountID: wallet.id, currency: .usd,
        kind: .dividend(DividendDetails(ticker: "AAPL", amount: 12)))
    let portfolio = Portfolio(accounts: [wallet], transactions: [noise, first])
    #expect(try portfolio.findGICPurchase(accountID: wallet.id, reference: "5-YEAR PRIME+ gic").id
        == first.id)
    #expect(try portfolio.findGICPurchase(accountID: wallet.id, reference: "  5-Year Prime+ GIC  ").id
        == first.id)
}

@Test("ids resolve whole or by unique hex prefix; shared prefixes are refused, not guessed")
func findGICById() throws {
    let one = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!
    let two = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000002")!
    let unique = UUID(uuidString: "11112222-3333-4444-5555-666677778888")!
    let portfolio = Portfolio(accounts: [wallet],
                              transactions: [gic(id: one, product: "A GIC"),
                                             gic(id: two, product: "B GIC"),
                                             gic(id: unique, product: "C GIC")])
    // Full UUID (with dashes) and a unique prefix both resolve.
    #expect(try portfolio.findGICPurchase(accountID: wallet.id,
                                          reference: one.uuidString).productMatches("A GIC"))
    #expect(try portfolio.findGICPurchase(accountID: wallet.id,
                                          reference: "11112222").productMatches("C GIC"))
    // A prefix shared by two GICs lists the candidates instead of picking.
    do {
        _ = try portfolio.findGICPurchase(accountID: wallet.id, reference: "DEADBEEF")
        Issue.record("a shared prefix must not resolve")
    } catch MutationError.unresolvable(let problem) {
        #expect(problem.contains("matches 2 GICs"))
        #expect(problem.contains("A GIC") && problem.contains("B GIC"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test("a miss lists the account's live GICs; an empty account says record one first")
func findGICMissing() {
    let portfolio = Portfolio(accounts: [wallet, Account(name: "Empty")],
                              transactions: [gic(product: "Only GIC")])
    do {
        _ = try portfolio.findGICPurchase(accountID: wallet.id, reference: "NoSuchGIC")
        Issue.record("expected unresolvable")
    } catch MutationError.unresolvable(let problem) {
        #expect(problem.contains("no GIC matches 'NoSuchGIC'"))
        #expect(problem.contains("Only GIC"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
    let empty = Account(name: "Empty")
    let bare = Portfolio(accounts: [wallet, empty])
    do {
        _ = try portfolio.findGICPurchase(accountID: empty.id, reference: "5-Year GIC")
        Issue.record("expected unresolvable")
    } catch MutationError.unresolvable(let problem) {
        #expect(problem.contains("record the GIC first"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
    // Lookups are scoped to the account: 'Only GIC' is invisible from Empty.
    #expect(throws: (any Error).self) {
        _ = try bare.findGICPurchase(accountID: empty.id, reference: "Only GIC")
    }
}

@Test("a transaction reference may not smuggle in a non-GIC event")
func findGICRejectsNonGIC() {
    let dividend = Transaction(
        date: day(50), accountID: wallet.id, currency: .usd,
        kind: .dividend(DividendDetails(ticker: "AAPL", amount: 12)))
    let portfolio = Portfolio(accounts: [wallet], transactions: [dividend])
    // Even an exact id only resolves against GIC purchases.
    #expect(throws: MutationError.self) {
        _ = try portfolio.findGICPurchase(accountID: wallet.id, reference: dividend.id.uuidString)
    }
}

// MARK: - suggestedCurrency

@Test("entry currency defaults: ticker's trading currency, then the account's")
func suggestedCurrencyChain() {
    let registry = EquityTicker(symbol: "AAPL", currency: .usd)
    let unconfirmed = EquityTicker(symbol: "MYST", currency: .unknown)
    let portfolio = Portfolio(accounts: [wallet], tickers: [registry, unconfirmed])
    #expect(portfolio.suggestedCurrency(accountID: wallet.id, symbol: "AAPL") == .usd)
    // An unconfirmed registry entry is no evidence — fall back to the account.
    #expect(portfolio.suggestedCurrency(accountID: wallet.id, symbol: "MYST") == .cad)
    #expect(portfolio.suggestedCurrency(accountID: wallet.id, symbol: "BRAND-NEW") == .cad)
    #expect(portfolio.suggestedCurrency(accountID: wallet.id, symbol: nil) == .cad)
    let usdAccount = Account(reportingCurrency: .usd, name: "US Broker")
    let mixed = Portfolio(accounts: [usdAccount])
    #expect(mixed.suggestedCurrency(accountID: usdAccount.id, symbol: nil) == .usd)
}

private extension Transaction {
    func productMatches(_ name: String) -> Bool {
        if case .gicPurchase(let details) = kind { return details.product == name }
        return false
    }
}
