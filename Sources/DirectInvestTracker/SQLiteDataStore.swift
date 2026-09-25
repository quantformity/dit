#if canImport(SQLite3)
import Foundation
import SQLite3

/// Owns an open SQLite handle and closes it exactly once, on dealloc.
///
/// `@unchecked Sendable` because `OpaquePointer` itself is not Sendable;
/// safety comes from the handle only ever being used behind the
/// `SQLiteDataStore` actor (serialized access) and closed once in `deinit`.
private final class DatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer?

    init(pointer: OpaquePointer?) {
        self.pointer = pointer
    }

    deinit {
        if let pointer { sqlite3_close(pointer) }
    }
}

/// A `DataStore` backed by a SQLite database file.
///
/// The whole store is one table —
/// `store(key TEXT PRIMARY KEY, payload BLOB)` — which is the key-value
/// common denominator in SQL form. The payload is opaque to SQLite;
/// the JSON encoding lives above, in `PortfolioStore`.
///
/// The store is an actor, so overlapping operations are serialized.
/// The database is opened (and created, along with its table) in `init`.
public actor SQLiteDataStore: DataStore {
    /// `SQLITE_TRANSIENT` (imported as the `sqlite3_destructor_type` constant
    /// via `unsafeBitCast`): tells SQLite to copy the bound bytes into the
    /// statement immediately. Required — the Swift buffers backing
    /// `withCString` / `withUnsafeBytes` die before `sqlite3_step` runs,
    /// so a static (uncopied) bind would read dangling memory.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: DatabaseHandle?

    /// Opens the database at `url`, creating the file (and table) if needed.
    public init(url: URL) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(rc))
            if let handle { sqlite3_close(handle) }
            throw DataStoreError.ioFailed(key: "<open>", message: "sqlite3_open_v2(\(rc)): \(message)")
        }
        self.db = DatabaseHandle(pointer: handle)
        try self.createSchema(on: handle)
    }

    // MARK: DataStore

    public func save(_ payload: Data, key: String) async throws {
        let stmt = try prepare(
            "INSERT INTO store (key, payload) VALUES (?, ?) "
            + "ON CONFLICT(key) DO UPDATE SET payload = excluded.payload"
        )
        defer { sqlite3_finalize(stmt) }

        let bindKey = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.transient) }
        guard bindKey == SQLITE_OK else {
            throw DataStoreError.ioFailed(key: key, message: "bind failed: \(errorMessage())")
        }

        var zero: Int8 = 0
        let bindBlob = payload.isEmpty
            ? sqlite3_bind_blob(stmt, 2, &zero, 0, Self.transient)
            : payload.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), Self.transient) }
        guard bindBlob == SQLITE_OK else {
            throw DataStoreError.ioFailed(key: key, message: "bind failed: \(errorMessage())")
        }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw DataStoreError.ioFailed(key: key, message: "step failed (\(rc)): \(errorMessage())")
        }
    }

    public func load(key: String) async throws -> Data? {
        let stmt = try prepare("SELECT payload FROM store WHERE key = ?")
        defer { sqlite3_finalize(stmt) }

        let bind = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.transient) }
        guard bind == SQLITE_OK else {
            throw DataStoreError.ioFailed(key: key, message: "bind failed: \(errorMessage())")
        }

        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            let pointer = sqlite3_column_blob(stmt, 0)
            let length = Int(sqlite3_column_bytes(stmt, 0))
            guard let pointer else { return nil }
            return Data(bytes: pointer, count: length)
        case SQLITE_DONE:
            return nil
        default:
            throw DataStoreError.ioFailed(key: key, message: "step failed: \(errorMessage())")
        }
    }

    public func delete(key: String) async throws {
        let stmt = try prepare("DELETE FROM store WHERE key = ?")
        defer { sqlite3_finalize(stmt) }

        let bind = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, Self.transient) }
        guard bind == SQLITE_OK else {
            throw DataStoreError.ioFailed(key: key, message: "bind failed: \(errorMessage())")
        }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw DataStoreError.ioFailed(key: key, message: "step failed (\(rc)): \(errorMessage())")
        }
    }

    public func keys() async throws -> [String] {
        let stmt = try prepare("SELECT key FROM store ORDER BY key")
        defer { sqlite3_finalize(stmt) }

        var result: [String] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                if let cString = sqlite3_column_text(stmt, 0) {
                    result.append(String(cString: cString))
                }
            case SQLITE_DONE:
                return result
            default:
                throw DataStoreError.ioFailed(key: "<keys>", message: "step failed: \(errorMessage())")
            }
        }
    }

    // MARK: SQLite helpers

    /// Creates the schema. Called from `init` with the raw handle, so it
    /// is `nonisolated` (actor inits run before isolation begins).
    private nonisolated func createSchema(on handle: OpaquePointer) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let schema = "CREATE TABLE IF NOT EXISTS store (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)"
        let rc = schema.withCString { sqlite3_exec(handle, $0, nil, nil, &errPtr) }
        guard rc == SQLITE_OK else {
            let message = errPtr.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errPtr)
            throw DataStoreError.ioFailed(key: "<init>", message: "schema creation failed: \(message)")
        }
    }

    /// Prepares `sql` against the open database, throwing a descriptive
    /// error on failure.
    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let pointer = db?.pointer else {
            throw DataStoreError.ioFailed(key: "<prepare>", message: "database is not open")
        }
        var stmt: OpaquePointer?
        let rc = sql.withCString { sqlite3_prepare_v2(pointer, $0, -1, &stmt, nil) }
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw DataStoreError.ioFailed(key: "<prepare>", message: "prepare failed (\(rc)): \(errorMessage())")
        }
        return prepared
    }

    private func errorMessage() -> String {
        guard let pointer = db?.pointer else { return "database is not open" }
        return String(cString: sqlite3_errmsg(pointer))
    }
}
#endif