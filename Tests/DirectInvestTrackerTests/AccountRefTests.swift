import Foundation
import Testing

@testable import DirectInvestTracker

private func makePortfolio(_ accounts: [Account]) -> Portfolio {
    Portfolio(accounts: accounts)
}

private let tdDirect = Account(
    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    name: "TD Direct"
)
private let questrade = Account(
    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
    name: "Questrade"
)
private let cafe = Account(
    id: UUID(uuidString: "ABCD1234-ABCD-ABCD-ABCD-ABCDABCDABCD")!,
    name: "CAFE"
)
private let cafe2 = Account(
    id: UUID(uuidString: "ABCD9999-ABCD-ABCD-ABCD-ABCDABCDABCD")!,
    name: "Cafe Deux"
)

@Test("name lookup is exact, case-insensitive, and trims")
func nameLookup() throws {
    let portfolio = makePortfolio([tdDirect, questrade])
    for query in ["TD Direct", "td direct", "  TD DIRECT  "] {
        #expect(try AccountRef(query).resolve(in: portfolio) == tdDirect)
    }
}

@Test("full UUID (dashes optional, any case) resolves")
func fullUUIDLookup() throws {
    let portfolio = makePortfolio([tdDirect, questrade])
    #expect(try AccountRef(tdDirect.id.uuidString).resolve(in: portfolio) == tdDirect)
    #expect(try AccountRef(tdDirect.id.uuidString.lowercased()).resolve(in: portfolio) == tdDirect)
    let undashed = tdDirect.id.uuidString.replacingOccurrences(of: "-", with: "")
    #expect(try AccountRef(undashed).resolve(in: portfolio) == tdDirect)
}

@Test("unique UUID prefix resolves")
func uuidPrefixLookup() throws {
    let portfolio = makePortfolio([tdDirect, questrade])
    #expect(try AccountRef("11111111").resolve(in: portfolio) == tdDirect)
    #expect(try AccountRef("22222222").resolve(in: portfolio) == questrade)
    #expect(try AccountRef("11111111-1111").resolve(in: portfolio) == tdDirect)
}

@Test("ambiguous UUID prefix throws with both accounts named")
func ambiguousUUIDPrefix() throws {
    let portfolio = makePortfolio([cafe, cafe2])
    #expect(throws: AccountRef.ResolutionError.ambiguous(
        query: "ABCD",
        matches: ["CAFE", "Cafe Deux"])) {
        _ = try AccountRef("ABCD").resolve(in: portfolio)
    }
}

@Test("a query that looks hex but matches no UUID falls through to name lookup")
func hexLikeName() throws {
    let portfolio = makePortfolio([cafe, cafe2])
    // "CAFE" is hex; the UUIDs do not start with it; the account name does.
    #expect(try AccountRef("CAFE").resolve(in: portfolio) == cafe)
}

@Test("exact name matching several accounts is ambiguous")
func ambiguousName() throws {
    let one = Account(name: "Same Name")
    let two = Account(name: "same name ")
    let portfolio = makePortfolio([one, two])
    do {
        _ = try AccountRef("Same Name").resolve(in: portfolio)
        Issue.record("expected ambiguity error")
    } catch let AccountRef.ResolutionError.ambiguous(query, matches) {
        #expect(query == "Same Name")
        #expect(matches.count == 2)
    }
}

@Test("short hex-looking queries are names, not UUID prefixes")
func shortHexIsNotAPrefix() {
    let portfolio = makePortfolio([tdDirect, questrade])
    #expect(throws: AccountRef.ResolutionError.notFound(query: "AB")) {
        _ = try AccountRef("AB").resolve(in: portfolio)
    }
}

@Test("unknown and empty references")
func miss() {
    let portfolio = makePortfolio([tdDirect])
    #expect(throws: AccountRef.ResolutionError.notFound(query: "Nope")) {
        _ = try AccountRef("Nope").resolve(in: portfolio)
    }
    #expect(throws: AccountRef.ResolutionError.empty) {
        _ = try AccountRef("   ").resolve(in: portfolio)
    }
}

@Test("displayName falls back to a short account label")
func displayName() {
    #expect(tdDirect.displayName == "TD Direct")
    let unnamed = Account(name: "   ")
    #expect(unnamed.displayName == "Account \(unnamed.id.uuidString.prefix(4))")
}
