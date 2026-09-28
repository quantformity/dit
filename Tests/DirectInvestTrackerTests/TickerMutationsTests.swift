import XCTest
@testable import DirectInvestTracker

final class TickerMutationsTests: XCTestCase {
    private func sample(symbol: String = "AAPL") -> EquityTicker {
        EquityTicker(symbol: symbol, name: "Apple Inc.", currency: .usd, tags: [Tag("watchlist")])
    }

    // MARK: - addingTicker

    func testAddRegistersNewEntry() {
        let result = try! Portfolio(tickers: []).addingTicker(sample())
        XCTAssertEqual(result.0.tickers.count, 1)
        XCTAssertEqual(result.0.tickers.first?.symbol, "AAPL")
        XCTAssertTrue(result.1.first!.contains("AAPL"))
    }

    func testAddNormalizesSymbolBeforeCollisionCheck() {
        let base = try! Portfolio(tickers: []).addingTicker(sample(symbol: "shop.to"))
        XCTAssertThrowsError(try base.0.addingTicker(sample(symbol: "SHOP.TO"))) { error in
            guard case MutationError.tickerExists(let symbol) = error else {
                return XCTFail("expected tickerExists, got \(error)")
            }
            XCTAssertEqual(symbol, "SHOP.TO")
        }
    }

    func testAddRejectsEmptySymbol() {
        XCTAssertThrowsError(try Portfolio(tickers: []).addingTicker(EquityTicker(symbol: "  "))) { error in
            guard case MutationError.invalidValue = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
    }

    // MARK: - updatingTicker

    func testUpdateChangesOnlySuppliedFields() {
        let base = try! Portfolio(tickers: []).addingTicker(sample())
        let (updated, notes) = try! base.0.updatingTicker(symbol: "aapl", name: "Apple", notes: "core holding")
        XCTAssertEqual(updated.tickers.first?.name, "Apple")
        XCTAssertEqual(updated.tickers.first?.notes, "core holding")
        XCTAssertEqual(updated.tickers.first?.currency, .usd)   // untouched
        XCTAssertEqual(updated.tickers.first?.tags, Set([Tag("watchlist")]))  // untouched
        XCTAssertTrue(notes[0].contains("name"))
        XCTAssertTrue(notes[0].contains("notes"))
        XCTAssertFalse(notes[0].contains("currency"))
    }

    func testUpdateReplacesTagsSetAndEmptyClears() {
        let base = try! Portfolio(tickers: []).addingTicker(sample())
        let withTwo = try! base.0.updatingTicker(symbol: "AAPL", tags: [Tag("dividend"), Tag("core")]).0
        XCTAssertEqual(withTwo.tickers.first?.tags, Set([Tag("dividend"), Tag("core")]))
        let (cleared, notes) = try! withTwo.updatingTicker(symbol: "AAPL", tags: [])
        XCTAssertTrue(cleared.tickers.first?.tags.isEmpty ?? true)
        XCTAssertTrue(notes[0].contains("tags cleared"))
    }

    func testUpdateUnknownSymbolThrowsNotFound() {
        XCTAssertThrowsError(try Portfolio(tickers: []).updatingTicker(symbol: "NOPE", name: "x")) { error in
            guard case MutationError.tickerNotFound(let symbol) = error else {
                return XCTFail("expected tickerNotFound, got \(error)")
            }
            XCTAssertEqual(symbol, "NOPE")
        }
    }

    func testUpdateWithNoChangesThrowsUnchanged() {
        let base = try! Portfolio(tickers: []).addingTicker(sample())
        XCTAssertThrowsError(try base.0.updatingTicker(symbol: "AAPL", name: "Apple Inc.", currency: .usd)) { error in
            guard case MutationError.tickerUnchanged = error else {
                return XCTFail("expected unchanged, got \(error)")
            }
        }
    }

    // MARK: - removingTicker

    func testRemoveUnregisteredEntry() {
        let base = try! Portfolio(tickers: []).addingTicker(sample())
        let (updated, notes) = try! base.0.removingTicker(symbol: "aapl")
        XCTAssertTrue(updated.tickers.isEmpty)
        XCTAssertTrue(notes[0].hasPrefix("unregistered"))
        XCTAssertTrue(notes[0].contains("Apple Inc."))
        XCTAssertTrue(notes[0].contains("AAPL"))
    }

    func testRemoveUnknownSymbolThrows() {
        XCTAssertThrowsError(try Portfolio(tickers: []).removingTicker(symbol: "NOPE")) { error in
            guard case MutationError.tickerNotFound = error else {
                return XCTFail("expected tickerNotFound, got \(error)")
            }
        }
    }

    func testRemoveKeepsReferencingTransactionsAndSaysSo() {
        let account = Account(reportingCurrency: .cad, name: "TD")
        let buy = Transaction(
            date: Date(),
            accountID: account.id,
            currency: .usd,
            kind: .stockPurchase(StockDetails(ticker: "AAPL", shares: 10, price: 200)))
        var p = Portfolio()
        p.accounts.append(account)
        p.transactions.append(buy)
        p.tickers.append(sample())

        let (updated, notes) = try! p.removingTicker(symbol: "AAPL")
        XCTAssertTrue(updated.tickers.isEmpty)
        XCTAssertEqual(updated.transactions.count, 1)      // ledger untouched
        XCTAssertEqual(updated.tickers, [])
        XCTAssertTrue(notes[0].contains("still reference"))
    }
}
