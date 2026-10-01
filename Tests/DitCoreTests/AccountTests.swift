import XCTest
@testable import DitCore

final class AccountTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ components: [Calendar.Component: Int]) -> Date {
        var dc = DateComponents()
        dc.year = components[.year]
        dc.month = components[.month]
        dc.day = components[.day]
        return calendar.date(from: dc)!
    }

    private var fullAccount: Account {
        Account(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            reportingCurrency: .cad,
            name: "Desjardins TFSA",
            institution: "Desjardins",
            accountNumber: "1234",
            taxable: false,
            openedDate: date([.year: 2024, .month: 6, .day: 1]),
            closedDate: nil,
            notes: "Held for the house down payment"
        )
    }

    // MARK: - Defaults

    func testDefaults() {
        let account = Account()

        XCTAssertTrue(account.id != UUID())
        XCTAssertEqual(account.reportingCurrency, Currency.cad)
        XCTAssertNil(account.name)
        XCTAssertNil(account.institution)
        XCTAssertNil(account.accountNumber)
        XCTAssertEqual(account.taxable, true) // conservative default
        XCTAssertNil(account.openedDate)
        XCTAssertNil(account.closedDate)
        XCTAssertNil(account.notes)
        XCTAssertTrue(account.isActive)
    }

    // MARK: - Coding

    func testRoundTripPreservesAllFields() throws {
        let original = fullAccount
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.reportingCurrency, Currency.cad)
        XCTAssertEqual(decoded.name, "Desjardins TFSA")
        XCTAssertEqual(decoded.institution, "Desjardins")
        XCTAssertEqual(decoded.accountNumber, "1234")
        XCTAssertEqual(decoded.taxable, false)
        XCTAssertEqual(decoded.openedDate, original.openedDate)
        XCTAssertNil(decoded.closedDate)
        XCTAssertEqual(decoded.notes, "Held for the house down payment")
    }

    func testOptionalFieldsAreOmittedFromJSONWhenNil() throws {
        let data = try JSONEncoder().encode(Account())
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["name"])
        XCTAssertNil(json["institution"])
        XCTAssertNil(json["accountNumber"])
        XCTAssertNil(json["openedDate"])
        XCTAssertNil(json["closedDate"])
        XCTAssertNil(json["notes"])
        XCTAssertNotNil(json["id"])
        XCTAssertNotNil(json["reportingCurrency"])
        XCTAssertNotNil(json["taxable"])
    }

    func testReportingCurrencyDecodesLenientlyFromUnknownCode() throws {
        let payload = Data(
            """
            {"id": "22222222-2222-2222-2222-222222222222", "reportingCurrency": "XYZ", "taxable": true}
            """
            .utf8
        )
        let account = try JSONDecoder().decode(Account.self, from: payload)

        XCTAssertEqual(account.reportingCurrency, Currency.unknown)
        XCTAssertEqual(account.taxable, true)
    }

    func testRoundTripsWithClosedDate() throws {
        let account = Account(name: "Old brokerage", taxable: true,
                              openedDate: date([.year: 2019, .month: 3, .day: 15]),
                              closedDate: date([.year: 2023, .month: 12, .day: 31]))
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))

        XCTAssertFalse(decoded.isActive)
        XCTAssertEqual(decoded.closedDate, account.closedDate)
    }

    // MARK: - Value semantics

    func testIsHashableAndEquatable() {
        let a = Account(name: "A")
        let b = Account(name: "A")
        let c = Account(name: "B")

        XCTAssertTrue(Set([a.id, b.id, c.id]).count == 3)
        XCTAssertNotEqual(a, c)
        let dict: [UUID: Account] = [a.id: a, c.id: c]
        XCTAssertEqual(dict.count, 2)
    }
}