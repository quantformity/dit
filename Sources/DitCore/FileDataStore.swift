import Foundation

/// A `DataStore` backed by a directory of files.
///
/// Each key is stored as one file (`<sanitized-key>.dat`) inside the
/// directory, written atomically. Acts as an actor so overlapping
/// operations are serialized — a concurrent `save` can never observe a
/// half-written file.
///
/// This is the zero-dependency default backend. SQLite and Redis backends
/// conform to the same `DataStore` protocol; everything above this layer
/// is unaffected by the swap.
public actor FileDataStore: DataStore {
    private let directory: URL
    private let fileManager: FileManager

    /// Creates the directory (and parents) if it does not exist yet.
    public init(directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Writes the whole payload with `.atomic` (temp file + rename),
    /// so a crash mid-save can never leave half a file under the key.
    public func save(_ payload: Data, key: String) async throws {
        do {
            try payload.write(to: fileURL(for: key), options: .atomic)
        } catch {
            throw DataStoreError.ioFailed(key: key, message: error.localizedDescription)
        }
    }

    /// Reads the key's file; a missing file is `nil`, any other read
    /// failure is an error (an unreadable store must not read as empty).
    public func load(key: String) async throws -> Data? {
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw DataStoreError.ioFailed(key: key, message: error.localizedDescription)
        }
    }

    /// Deletes the key's file. "No such file" passes quietly — the
    /// protocol requires delete to be idempotent.
    public func delete(key: String) async throws {
        do {
            try fileManager.removeItem(at: fileURL(for: key))
        } catch let error as NSError {
            // Deleting something that does not exist is a no-op, not an error.
            guard error.domain == NSCocoaErrorDomain,
                  error.code == CocoaError.fileNoSuchFile.rawValue
            else {
                throw DataStoreError.ioFailed(key: key, message: error.localizedDescription)
            }
        }
    }

    /// The keys recoverable from `.dat` filenames, sorted. Non-`.dat`
    /// files in the directory are ignored (stray backups stay invisible).
    public func keys() async throws -> [String] {
        do {
            return try fileManager
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .compactMap { $0.pathExtension == "dat" ? $0.deletingPathExtension().lastPathComponent : nil }
                .sorted()
        } catch {
            throw DataStoreError.ioFailed(key: "<directory>", message: error.localizedDescription)
        }
    }

    // MARK: Key ↔ filename

    /// Maps a key to a filename, replacing any character that is not a
    /// letter, digit, `.`, `_`, or `-` with `_`.
    private func fileURL(for key: String) -> URL {
        var sanitized = ""
        for scalar in key.unicodeScalars {
            let character = Character(scalar)
            sanitized += character.isLetter || character.isNumber || "._-".contains(character)
                ? String(character)
                : "_"
        }
        if sanitized.isEmpty { sanitized = "_" }
        return directory
            .appendingPathComponent(sanitized)
            .appendingPathExtension("dat")
    }
}