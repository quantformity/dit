import Foundation

/// Backend-agnostic key-value storage of opaque payloads.
///
/// This is the bottom of the persistence cascade:
///
/// ```
/// Portfolio  ←→  PortfolioStore (JSON codec)  ←→  DataStore (bytes)
///                                                      ├── FileDataStore
///                                                      ├── SQLiteDataStore  (to add)
///                                                      └── RedisDataStore   (to add)
/// ```
///
/// A store keeps `Data` under `String` keys. Concrete backends differ in
/// how they hold those bytes, but callers never see the backend or its
/// configuration — they depend only on this protocol.
///
/// Implementations must be `Sendable`; all methods are `async` so
/// backends with real I/O (network databases) can be used without
/// blocking.
public protocol DataStore: Sendable {
    /// Store `payload` under `key`, atomically replacing any existing value.
    func save(_ payload: Data, key: String) async throws

    /// The payload stored under `key`, or `nil` if nothing is stored there.
    func load(key: String) async throws -> Data?

    /// Remove the payload stored under `key`.
    /// Idempotent: no error if the key does not exist.
    func delete(key: String) async throws

    /// All keys currently stored (unordered).
    func keys() async throws -> [String]
}

/// Errors surfaced by the persistence layers.
///
/// `message` (rather than an `underlying: Error`) keeps the type
/// trivially `Sendable`.
public enum DataStoreError: Error, Sendable {
    /// The backend could not perform the I/O operation.
    case ioFailed(key: String, message: String)
    /// The domain object could not be encoded to bytes.
    case encodeFailed(key: String, message: String)
    /// Stored bytes could not be decoded into the expected domain type.
    case decodeFailed(key: String, message: String)
}