import Foundation

/// Backend-agnostic access to the persisted `Portfolio`.
///
/// This is the middle layer of the persistence cascade. Domain code calls
/// `load()` / `save(_:)` / `delete()` and knows nothing about the
/// underlying `DataStore` — file, SQLite, Redis, or a future backend.
/// The backend is injected once at construction and is invisible
/// everywhere else.
public struct PortfolioStore: Sendable {
    /// The storage key under which the whole portfolio document is kept.
    public static let documentKey = "portfolio"

    private let store: any DataStore

    /// - Parameter store: the backend to use (e.g. `FileDataStore`, or a
    ///   SQLite/Redis store added later). All I/O flows through it.
    public init(store: some DataStore) {
        self.store = store
    }

    /// The stored portfolio, or `nil` if nothing has been saved yet.
    public func load() async throws -> Portfolio? {
        guard let payload = try await store.load(key: Self.documentKey) else { return nil }
        do {
            return try JSONDecoder().decode(Portfolio.self, from: payload)
        } catch {
            throw DataStoreError.decodeFailed(key: Self.documentKey, message: error.localizedDescription)
        }
    }

    /// Replace the stored portfolio with `portfolio`.
    public func save(_ portfolio: Portfolio) async throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(portfolio)
        } catch {
            throw DataStoreError.encodeFailed(key: Self.documentKey, message: error.localizedDescription)
        }
        try await store.save(payload, key: Self.documentKey)
    }

    /// Remove the stored portfolio entirely.
    public func delete() async throws {
        try await store.delete(key: Self.documentKey)
    }
}