import XCTest
@testable import DirectInvestTracker

final class SQLiteDataStoreTests: XCTestCase {
    private func makeStore() throws -> SQLiteDataStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString).sqlite")
        return try SQLiteDataStore(url: url)
    }

    func testSaveLoadRoundTrip() async throws {
        let store = try makeStore()
        let payload = Data("hello, sqlite".utf8)

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

    func testBinaryPayloadSurvivesRoundTrip() async throws {
        // Blobs, not just text: NUL bytes and high-bit data included.
        let payload = Data([0x00, 0xFF, 0x80, 0x01, 0xFE, 0x00, 0x7F])
        let store = try makeStore()

        try await store.save(payload, key: "binary")
        let loaded = try await store.load(key: "binary")
        XCTAssertEqual(loaded, payload)
    }
}

final class DataStoreFactoryTests: XCTestCase {
    private var tempDirectory: URL!
    private let fileManager = FileManager.default

    override func setUp() {
        super.setUp()
        tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DataStoreFactoryTests-\(UUID().uuidString)")
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testDefaultsToFileBackend() throws {
        let config = try DataStoreFactory(environment: [:]).configuration()
        XCTAssertEqual(config.backend, DataStoreFactory.Configuration.Backend.file)
        XCTAssertEqual(config.url.lastPathComponent, "DirectInvestTracker")
    }

    /// Regression: `urls(for: .userDirectory, in: .userDomainMask)`
    /// returns *empty* on some macOS releases, which once made the
    /// default fall back to `/` and thus the system-wide
    /// `/Library/Application Support` — not writable. The default must
    /// always resolve inside the user's home directory.
    func testDefaultStoreURLIsInsideUserHome() throws {
        let storeURL = DataStoreFactory.defaultStoreURL
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        XCTAssertTrue(
            storeURL.standardizedFileURL.path.hasPrefix(home),
            "default store \(storeURL.path) must be inside home \(home)"
        )
        // And it must be writable — the whole point of a user store.
        try fileManager.createDirectory(at: storeURL, withIntermediateDirectories: true)
        let probe = storeURL.appendingPathComponent(".write-probe")
        try Data("ok".utf8).write(to: probe, options: .atomic)
        try fileManager.removeItem(at: probe)
    }

    func testEnvironmentSelectsSqlite() throws {
        let env = [
            DataStoreFactory.backendKey: "SQLITE", // case-insensitive
            DataStoreFactory.storeURLKey: tempDirectory.appendingPathComponent("data.sqlite").path
        ]
        let config = try DataStoreFactory(environment: env).configuration()
        XCTAssertEqual(config.backend, DataStoreFactory.Configuration.Backend.sqlite)
        XCTAssertEqual(config.url.lastPathComponent, "data.sqlite")
    }

    func testSqliteStoreInExistingDirectory() throws {
        let dir = tempDirectory.appendingPathComponent("somedir")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = [
            DataStoreFactory.backendKey: "sqlite",
            DataStoreFactory.storeURLKey: dir.path
        ]
        _ = try DataStoreFactory(environment: env).make()
        XCTAssertTrue(fileManager.fileExists(atPath: dir.appendingPathComponent("portfolio.sqlite").path))
    }

    func testSqliteStoreAtExactFilePath() throws {
        let file = tempDirectory.appendingPathComponent("mydata")
        let env = [
            DataStoreFactory.backendKey: "sqlite",
            DataStoreFactory.storeURLKey: file.path
        ]
        _ = try DataStoreFactory(environment: env).make()
        // Non-existent path without extension: used verbatim, not treated as a directory.
        XCTAssertTrue(fileManager.fileExists(atPath: file.path))
    }

    func testUnknownBackendThrows() {
        let env = [DataStoreFactory.backendKey: "redis"]
        do {
            _ = try DataStoreFactory(environment: env).configuration()
            XCTFail("expected a configuration error")
        } catch let error as DataStoreError {
            guard case .configuration = error else {
                return XCTFail("expected .configuration, got \(error)")
            }
        } catch {
            XCTFail("expected DataStoreError, got \(error)")
        }
    }

    /// Full stack, both backends: env picks the backend, `PortfolioStore`
    /// round-trips a portfolio, and the right artifacts land on disk.
    func testEndToEndOverEachConfiguredBackend() async throws {
        for backend in ["file", "sqlite"] {
            let root = tempDirectory.appendingPathComponent(backend)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let env = [
                DataStoreFactory.backendKey: backend,
                DataStoreFactory.storeURLKey: root.path
            ]
            let store = try DataStoreFactory(environment: env).make()
            let portfolioStore = PortfolioStore(store: store)

            let portfolio = Portfolio(
                accounts: [Account(name: "Desjardins TFSA", institution: "Desjardins", taxable: false)],
                transactions: [
                    Transaction(
                        date: Date(timeIntervalSince1970: 1_700_000_000),
                        accountID: UUID(),
                        currency: .cad,
                        kind: .stockPurchase(.init(ticker: "SHOP", shares: 42, price: 71.25))
                    )
                ],
                tickers: [EquityTicker(symbol: "SHOP.TO", name: "Shopify Inc.", currency: .cad)]
            )
            try await portfolioStore.save(portfolio)

            let loaded = try await portfolioStore.load()
            XCTAssertEqual(loaded, portfolio)

            // The configured backend really was used.
            if backend == "file" {
                XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("portfolio.dat").path))
            } else {
                XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("portfolio.sqlite").path))
            }
        }
    }
}