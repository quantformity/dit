import Foundation
import Testing

@testable import DirectInvestTracker

private let wallet = Account(name: "Wallet")

private func tx(id: UUID, kind: Transaction.Kind = .deposit(amount: 100)) -> Transaction {
    Transaction(id: id, date: Date(timeIntervalSince1970: 0), accountID: wallet.id,
                currency: .cad, kind: kind)
}

@Test("a full UUID resolves — with or without dashes, any case")
func fullUUID() throws {
    let id = UUID(uuidString: "9F2C6D1A-0000-0000-0000-0000000000FF")!
    let portfolio = Portfolio(accounts: [wallet], transactions: [tx(id: id)])
    #expect(throws: Never.self) {
        _ = try TransactionRef(id.uuidString).resolve(in: portfolio)
        _ = try TransactionRef("9f2c6d1a0000000000000000000000ff").resolve(in: portfolio)
        _ = try TransactionRef("9F2C6D1A").resolve(in: portfolio) // unique prefix
    }
}

@Test("an unknown, too-short, or non-hex query reports not-found")
func misses() {
    let portfolio = Portfolio(accounts: [wallet], transactions: [tx(id: UUID())])
    for query in ["DEADBEEF", "9F", "TD", "td direct"] {
        #expect(throws: TransactionRef.ResolutionError.self) {
            _ = try TransactionRef(query).resolve(in: portfolio)
        }
    }
    #expect(throws: TransactionRef.ResolutionError.empty) {
        _ = try TransactionRef("   ").resolve(in: portfolio)
    }
}

@Test("ambiguity is reported with candidates, never guessed")
func ambiguity() throws {
    let a = tx(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let b = tx(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let portfolio = Portfolio(accounts: [wallet], transactions: [a, b])
    do {
        _ = try TransactionRef("00000000").resolve(in: portfolio)
        Issue.record("expected ambiguity")
    } catch let TransactionRef.ResolutionError.ambiguous(query, matches) {
        #expect(query == "00000000")
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.contains("deposit 100 CAD") })
    }
}
