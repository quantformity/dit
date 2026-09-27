import Foundation

/// Builds the active `DataStore` from environment variables.
///
/// ## Configuration
///
/// | Variable         | Meaning                                                        | Default                                             |
/// |------------------|----------------------------------------------------------------|-----------------------------------------------------|
/// | `DIT_BACKEND`    | `file` or `sqlite` (case-insensitive)                          | `file`                                              |
/// | `DIT_STORE_URL`  | `file`: a directory · `sqlite`: a database file path           | `~/Library/Application Support/DirectInvestTracker` |
///
/// For `sqlite`, if `DIT_STORE_URL` is an existing **directory**, the
/// database file `portfolio.sqlite` is created inside it. Any other
/// path is used as the exact database file path.
///
/// ```sh
/// # One .dat file per key — the default, no variables needed
/// ./direct-invest-tracker
///
/// # SQLite database in the default location
/// DIT_BACKEND=sqlite ./direct-invest-tracker
///
/// # SQLite database elsewhere
/// DIT_BACKEND=sqlite DIT_STORE_URL=~/data/portfolio.sqlite ./direct-invest-tracker
/// ```
///
/// Unknown backend values fail loudly at startup — a misconfiguration
/// should never silently write data somewhere unexpected.
public struct DataStoreFactory: Sendable {
    /// Name of the variable selecting the backend (`file` or `sqlite`).
    public static let backendKey = "DIT_BACKEND"
    /// Name of the variable giving the store location (directory or file).
    public static let storeURLKey = "DIT_STORE_URL"

    /// Parsed environment configuration.
    public struct Configuration: Equatable, Sendable {
        public enum Backend: String, CaseIterable, Sendable {
            /// One `.dat` file per key inside a directory.
            case file
            /// One SQLite database file with a `key`/`payload` table.
            case sqlite
        }

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
    public static var defaultStoreURL: URL {
        let home = FileManager.default
            .urls(for: .userDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/DirectInvestTracker", isDirectory: true)
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
            var dbURL = config.url
            var existingIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dbURL.path, isDirectory: &existingIsDirectory),
               existingIsDirectory.boolValue {
                dbURL.appendPathComponent("portfolio.sqlite", isDirectory: false)
            }
            return try SQLiteDataStore(url: dbURL)
            #else
            throw DataStoreError.configuration(
                message: "The sqlite backend requires the SQLite3 module, which is not available on this platform"
            )
            #endif
        }
    }
}

extension PortfolioStore {
    /// A `PortfolioStore` configured from the process environment —
    /// the usual entry point for apps and CLI tools.
    public static func makeDefault() throws -> PortfolioStore {
        PortfolioStore(store: try DataStoreFactory().make())
    }
}