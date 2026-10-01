import Foundation

/// Builds the active `DataStore` from environment variables.
///
/// ## Configuration
///
/// | Variable         | Meaning                                                        | Default                                             |
/// |------------------|----------------------------------------------------------------|-----------------------------------------------------|
/// | `DIT_BACKEND`    | `file` or `sqlite` (case-insensitive)                          | `file`                                              |
/// | `DIT_STORE_URL`  | `file`: a directory · `sqlite`: a database file path           | `~/Library/Application Support/dit` (falls back to the legacy `…/DirectInvestTracker` when that older folder exists) |
///
/// For `sqlite`, if `DIT_STORE_URL` is an existing **directory**, the
/// database file `portfolio.sqlite` is created inside it. Any other
/// path is used as the exact database file path.
///
/// ```sh
/// # One .dat file per key — the default, no variables needed
/// dit
///
/// # SQLite database in the default location
/// DIT_BACKEND=sqlite dit
///
/// # SQLite database elsewhere
/// DIT_BACKEND=sqlite DIT_STORE_URL=~/data/portfolio.sqlite dit
/// ```
///
/// Unknown backend values fail loudly at startup — a misconfiguration
/// should never silently write data somewhere unexpected.
public struct DataStoreFactory: Sendable {
    /// Name of the variable selecting the backend (`file` or `sqlite`).
    public static let backendKey = "DIT_BACKEND"
    /// Name of the variable giving the store location (directory or file).
    public static let storeURLKey = "DIT_STORE_URL"
    /// Name of the variable giving the MARKET store location — the
    /// separate market-data store (see ``marketConfiguration()``).
    public static let marketURLKey = "DIT_MARKET_URL"

    /// Parsed environment configuration.
    public struct Configuration: Equatable, Sendable {
        public enum Backend: String, CaseIterable, Sendable {
            /// One `.dat` file per key inside a directory.
            case file
            /// One SQLite database file with a `key`/`payload` table.
            case sqlite
        }

        /// Which backend to build (from `DIT_BACKEND`, default `.file`).
        public var backend: Backend
        /// Directory (for `.file`) or database file path (for `.sqlite`).
        public var url: URL
    }

    private let environment: [String: String]

    /// - Parameter environment: environment to read; defaults to the
    ///   process environment. Injectable so tests can run without
    ///   mutating the real environment.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// Where stores live when `DIT_STORE_URL` is not set.
    ///
    /// Tries `urls(for: .userDirectory, in: .userDomainMask)` first —
    /// which some macOS releases return *empty* for — and falls back to
    /// `homeDirectoryForCurrentUser` (HOME-based, reliable). Never a
    /// system directory: a store that cannot be written is useless.
    ///
    /// Name history: the default folder is `dit`; a pre-rename
    /// `DirectInvestTracker` folder is still honored when `dit` does
    /// not exist, so existing stores keep working after the rename
    /// without moving any data. When BOTH exist, `dit` wins (the newer
    /// location is the configured one).
    public static var defaultStoreURL: URL {
        let home = FileManager.default
            .urls(for: .userDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return resolveDefaultStoreURL(home: home) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Pure path choice, injectable for tests: `dit` if it exists,
    /// else the legacy `DirectInvestTracker` folder if that exists,
    /// else `dit` (fresh installs get the new name).
    static func resolveDefaultStoreURL(home: URL,
                                       directoryExists: (URL) -> Bool) -> URL {
        let current = home.appendingPathComponent("Library/Application Support/dit", isDirectory: true)
        if directoryExists(current) { return current }
        let legacy = home.appendingPathComponent("Library/Application Support/DirectInvestTracker", isDirectory: true)
        if directoryExists(legacy) { return legacy }
        return current
    }

    /// Parse the environment. Throws `.configuration` on an unknown
    /// backend name.
    public func configuration() throws -> Configuration {
        let backendRaw = (environment[Self.backendKey] ?? "file")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let backend = Configuration.Backend(rawValue: backendRaw) else {
            throw DataStoreError.configuration(
                message: "Unknown \(Self.backendKey) value '\(backendRaw)' "
                    + "(expected: \(Configuration.Backend.allCases.map(\.rawValue).joined(separator: ", ")))"
            )
        }

        let urlRaw = (environment[Self.storeURLKey] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlRaw.isEmpty
            ? Self.defaultStoreURL
            : URL(fileURLWithPath: urlRaw, isDirectory: backend == .file)
        return Configuration(backend: backend, url: url)
    }

    /// Construct the `DataStore` selected by the environment.
    public func make() throws -> any DataStore {
        let config = try configuration()
        switch config.backend {
        case .file:
            return try FileDataStore(directory: config.url)

        case .sqlite:
            #if canImport(SQLite3)
            return try SQLiteDataStore(url: Self.sqliteFile(in: config.url, named: "portfolio.sqlite"))
            #else
            throw DataStoreError.configuration(
                message: "The sqlite backend requires the SQLite3 module, which is not available on this platform"
            )
            #endif
        }
    }

    // MARK: Market store

    /// Where the MARKET data lives — a store separate from the
    /// portfolio, holding prices instead of ledger facts.
    ///
    /// Same rules as the portfolio store: `DIT_MARKET_URL` (or the
    /// `--market-store` flag, injected into that variable by the CLI)
    /// overrides; otherwise the market store sits *beside* whichever
    /// portfolio location is configured —
    ///
    /// - `file`: a `market` directory next to `portfolio.dat`;
    /// - `sqlite`: `market.sqlite` beside `portfolio.sqlite`.
    ///
    /// Pointing the portfolio store somewhere new therefore isolates
    /// market data automatically: experiments never touch the real
    /// quote history, and one backup covers a predictable pair of
    /// locations.
    public func marketConfiguration() throws -> Configuration {
        let portfolio = try configuration()
        let raw = (environment[Self.marketURLKey] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            return Configuration(backend: portfolio.backend,
                                 url: URL(fileURLWithPath: raw, isDirectory: portfolio.backend == .file))
        }
        switch portfolio.backend {
        case .file:
            return Configuration(backend: .file,
                                 url: portfolio.url.appendingPathComponent("market", isDirectory: true))
        case .sqlite:
            return Configuration(backend: .sqlite,
                                 url: Self.sqliteDirectory(of: portfolio.url)
                                     .appendingPathComponent("market.sqlite", isDirectory: false))
        }
    }

    /// Construct the market `DataStore` (the backend for `MarketStore`).
    public func makeMarketDataStore() throws -> any DataStore {
        let config = try marketConfiguration()
        switch config.backend {
        case .file:
            return try FileDataStore(directory: config.url)
        case .sqlite:
            #if canImport(SQLite3)
            return try SQLiteDataStore(url: Self.sqliteFile(in: config.url, named: "market.sqlite"))
            #else
            throw DataStoreError.configuration(
                message: "The sqlite backend requires the SQLite3 module, which is not available on this platform"
            )
            #endif
        }
    }

    /// A ready `MarketStore` for the configured market location.
    public func makeMarketStore() throws -> MarketStore {
        MarketStore(store: try makeMarketDataStore())
    }

    /// Interpret `url` as the place holding a SQLite database: if it is
    /// an existing directory, the named file lives inside it; otherwise
    /// the URL is the file path itself.
    private static func sqliteFile(in url: URL, named fileName: String) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return url.appendingPathComponent(fileName, isDirectory: false)
        }
        return url
    }

    /// The directory that should hold sibling SQLite files.
    private static func sqliteDirectory(of url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        if url.pathExtension == "sqlite" { return url.deletingLastPathComponent() }
        return url
    }
}

extension PortfolioStore {
    /// A `PortfolioStore` configured from the process environment —
    /// the usual entry point for apps and CLI tools.
    public static func makeDefault() throws -> PortfolioStore {
        PortfolioStore(store: try DataStoreFactory().make())
    }
}