import XCTest
@testable import DirectInvestTracker

// A second, trivially different backend: proves `PortfolioStore` is
// agnostic to which `DataStore` implementation it sits on.
actor MemoryDataStore: DataStore {
    private var storage: [String: Data] = [:]

    init() {}

    func save(_ payload: Data, key: String) async throws {
        storage[key] = payload
    }

    func load(key: String) async throws -> Data? {
        storage[key]
    }

    func delete(key: String) async throws {
        storage[key] = nil
    }

    func keys() async throws -> [String] {
        Array(storage.keys)
    }
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DirectInvestTrackerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class FileDataStoreTests: XCTestCase {
    private func makeStore() throws -> FileDataStore {
        try FileDataStore(directory: try makeTempDirectory())
    }

    func testSaveLoadRoundTrip() async throws {
        let store = try makeStore()
        let payload = Data("hello, store".utf8)

        try await store.save(payload, key: "greeting")
        let loaded = try await store.load(key: "greeting")
        XCTAssertEqual(loaded, payload)
    }

    func testLoadMissingKeyReturnsNil() async throws {
        let store = try makeStore()
        let loaded = try await store.load(key: "absent")
        XCTAssertNil(loaded)
    }

    func testOverwriteReplacesPreviousValue() async throws {
        let store = try makeStore()
        try await store.save(Data("first".utf8), key: "k")
        try await store.save(Data("second".utf8), key: "k")

        let loaded = try await store.load(key: "k")
        XCTAssertEqual(String(data: loaded ?? Data(), encoding: .utf8), "second")
    }

    func testDeleteRemovesAndIsIdempotent() async throws {
        let store = try makeStore()
        try await store.save(Data("x".utf8), key: "k")
        try await store.delete(key: "k")
        try await store.delete(key: "k") // no error the second time

        let loaded = try await store.load(key: "k")
        XCTAssertNil(loaded)
    }

    func testKeysListsStoredKeys() async throws {
        let store = try makeStore()
        try await store.save(Data("1".utf8), key: "b")
        try await store.save(Data("2".utf8), key: "a")

        let keys = try await store.keys()
        XCTAssertEqual(keys, ["a", "b"])
    }
}

final class PortfolioStoreTests: XCTestCase {
    /// The same sequence of operations over a `PortfolioStore` — run
    /// against different backends to prove agnosticism.
    private func exerciseStore(store: PortfolioStore) async throws {
        // Fresh store: nothing persisted yet.
        let empty = try await store.load()
        XCTAssertNil(empty)

        // Save, then load back an identical portfolio.
        let portfolio = Portfolio(
            accounts: [Account(name: "Desjardins TFSA", institution: "Desjardins", taxable: false)],
            transactions: [
                Transaction(
                    date: Date(timeIntervalSince1970: 1_700_000_000),
                    accountID: UUID(),
                    currency: .cad,
                    kind: .gicPurchase(.init(
                        product: "3-Year GIC",
                        principal: 25000,
                        rate: 0.045,
                        compounding: .annual,
                        maturityDate: Date(timeIntervalSince1970: 1_790_000_000),
                        redeemable: false
                    ))
                )
            ],
            tickers: [EquityTicker(symbol: "SHOP.TO", name: "Shopify Inc.", currency: .cad, tags: [Tag("dividend")])]
        )
        try await store.save(portfolio)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, portfolio)
        XCTAssertEqual(loaded?.tickers.first?.tags, Set([Tag("dividend")]))

        // Delete, then loading yields nil again.
        try await store.delete()
        let gone = try await store.load()
        XCTAssertNil(gone)
    }

    func testPortfolioStoreOverFileBackend() async throws {
        try await exerciseStore(store: PortfolioStore(store: try FileDataStore(directory: try makeTempDirectory())))
    }

    func testPortfolioStoreOverMemoryBackend() async throws {
        // Identical code path, different backend — the store never knows.
        try await exerciseStore(store: PortfolioStore(store: MemoryDataStore()))
    }

    func testCorruptedPayloadSurfacesDecodeError() async throws {
        let fileStore = try FileDataStore(directory: try makeTempDirectory())
        // Bypass the codec and write garbage under the portfolio key.
        try await fileStore.save(Data("this is not JSON".utf8), key: PortfolioStore.documentKey)

        let store = PortfolioStore(store: fileStore)
        do {
            _ = try await store.load()
            XCTFail("expected a decode error")
        } catch let error as DataStoreError {
            guard case .decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }

    func testInitFailsWhenDirectoryCannotBeCreated() throws {
        // A directory whose parent is a regular file cannot exist.
        let blocker = try makeTempDirectory().appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        XCTAssertThrowsError(try FileDataStore(directory: blocker.appendingPathComponent("impossible")))
    }
}