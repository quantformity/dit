import XCTest
@testable import DitCore

final class TagTests: XCTestCase {
    // MARK: - Normalization

    func testNormalizationMakesSpellingAndCaseEquivalent() {
        XCTAssertEqual(Tag("Dividend"), Tag("dividend"))
        XCTAssertEqual(Tag("  Watchlist "), Tag("watchlist"))
        XCTAssertEqual(Tag("Dividend").rawValue, "dividend")
    }

    func testDisplayValueIsCapitalized() {
        XCTAssertEqual(Tag("dividend").displayValue, "Dividend")
        XCTAssertEqual(Tag("watchlist").displayValue, "Watchlist")
    }

    // MARK: - Set dedup

    func testSetDeduplicatesEquivalentSpellings() {
        let set: Set<Tag> = [Tag("Dividend"), Tag("dividend"), Tag("watchlist")]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - Coding (bare string)

    func testEncodesAsBareString() throws {
        let data = try JSONEncoder().encode(Tag("Dividend"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"dividend\"")
    }

    func testDecodesFromBareString() throws {
        let decoded = try JSONDecoder().decode(Tag.self, from: Data("\"  Long-term hold \"".utf8))
        XCTAssertEqual(decoded, Tag("long-term hold"))
    }

    func testSetRoundTripsAsStringArray() throws {
        let original: Set<Tag> = [Tag("Dividend"), Tag("Watchlist")]
        let decoded = try JSONDecoder().decode(Set<Tag>.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(String(data: try JSONEncoder().encode(original), encoding: .utf8)?
            .sorted(), "[\"dividend\",\"watchlist\"]".sorted())
    }

    // MARK: - Ordering

    func testComparable() {
        let tags = [Tag("watchlist"), Tag("dividend"), Tag("core")]
        XCTAssertEqual(tags.sorted(), [Tag("core"), Tag("dividend"), Tag("watchlist")])
    }
}