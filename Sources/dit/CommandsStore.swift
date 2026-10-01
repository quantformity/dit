import DitCore
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - store commands

/// Timestamp label for backup/export filenames (UTC, sort-friendly).
func fileStamp(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

/// `store path`: where the portfolio and market stores live (and
/// whether the portfolio is readable from there).
func storePath(global: Global) async throws {
    let (store, configuration) = try openStore(global: global)
    var body = [
        "Backend:  \(configuration.backend.rawValue) (flags > \(DataStoreFactory.backendKey) > default)",
        "Location: \(configuration.url.path)",
    ]
    let portfolio = try await store.load()
    if let portfolio {
        body.append("Document: present — \(portfolio.accounts.count) account(s), \(portfolio.transactions.count) transaction(s), \(portfolio.tickers.count) ticker(s) registered")
    } else {
        body.append("Document: empty (no portfolio recorded yet)")
    }
    if let keys = try? await store.keys(), !keys.isEmpty {
        body.append("Keys: \(keys.joined(separator: ", "))")
    }
    print("Store configuration:")
    for line in body {
        print("  \(line)")
    }
}

/// `store export [--to FILE] [--account NAME]`: portable JSON (atomic
/// write; default target sits beside the store). Multi-account exports
/// warn — import needs one account per file.
func storeExport(_ args: [String], global: Global) async throws {
    let options = try Options(args, valueOptions: ["to", "account"])
    guard options.positionals.isEmpty else {
        throw ParseError("unexpected argument '\(options.positionals[0])' — use: dit store export [--to FILE] [--account NAME]")
    }
    let (store, configuration) = try openStore(global: global)
    guard let portfolio = try await store.load() else {
        throw NoPortfolio(path: configuration.url.path)
    }
    var scoped = portfolio
    var scopeNote = "the full portfolio"
    if let ref = options["account"] {
        let account = try resolveAccount(ref, in: portfolio)
        let transactions = portfolio.transactions(in: account.id)
        let symbols = Set(transactions.compactMap(\.ticker).map { $0.uppercased() })
        scoped = Portfolio(
            accounts: [account],
            transactions: transactions,
            tickers: portfolio.tickers.filter { symbols.contains($0.symbol) }
        )
        scopeNote = "account '\(account.displayName)'"
    }
    let data: Data
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = try encoder.encode(scoped)
    } catch {
        throw StoreError("could not encode the export: \(error.localizedDescription)")
    }
    let baseDir: URL
    if configuration.backend == .file {
        baseDir = configuration.url
    } else {
        baseDir = configuration.url.deletingLastPathComponent()
    }
    let target: URL
    if let raw = options["to"] {
        target = URL(fileURLWithPath: raw, isDirectory: false)
    } else {
        target = baseDir.appendingPathComponent("dit-portfolio-\(fileStamp()).json")
    }
    do {
        try data.write(to: target, options: .atomic)
    } catch {
        throw StoreError("could not write '\(target.path)': \(error.localizedDescription)")
    }
    print("Exported \(scopeNote): \(scoped.accounts.count) account(s), \(scoped.transactions.count) transaction(s), \(scoped.tickers.count) ticker(s) registered")
    print("  → \(target.path)")
    if scoped.accounts.count != 1 {
        print("  note: this is a multi-account export — 'dit store import' needs one account per file; re-run with --account <name>")
    }
}

/// Shared by `store backup` (explicit) and `store import` (automatic
/// pre-import). Returns the copies made.
func backupStore(global: Global, to directory: URL? = nil) throws -> [URL] {
    let (_, configuration) = try openStore(global: global)
    let fm = FileManager.default
    let stamp = fileStamp()
    var copies = [URL]()
    switch configuration.backend {
    case .file:
        let source = configuration.url
        let contents = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
        guard !contents.isEmpty else {
            throw StoreError("the file store at '\(source.path)' is missing or empty — nothing to back up")
        }
        let destDir = directory ?? source.deletingLastPathComponent()
        let destination = destDir.appendingPathComponent(source.lastPathComponent + ".bak-\(stamp)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination) // stale same-second target would merge
        }
        try fm.copyItem(at: source, to: destination)
        copies.append(destination)

    case .sqlite:
        var dbPath = configuration.url
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: dbPath.path, isDirectory: &isDirectory), isDirectory.boolValue {
            dbPath.appendPathComponent("portfolio.sqlite")
        }
        guard fm.fileExists(atPath: dbPath.path) else {
            throw StoreError("the sqlite database at '\(dbPath.path)' does not exist yet — nothing to back up")
        }
        let destDir = directory ?? dbPath.deletingLastPathComponent()
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for suffix in ["", ".wal", ".shm"] {
            let source = URL(fileURLWithPath: dbPath.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = destDir.appendingPathComponent(dbPath.lastPathComponent + ".bak-\(stamp)\(suffix)")
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            copies.append(destination)
        }
    }
    return copies
}

/// `store backup [--to DIR]`: timestamped copies of the store data.
func storeBackup(_ args: [String], global: Global) async throws {
    let options = try Options(args, valueOptions: ["to"])
    guard options.positionals.isEmpty else {
        throw ParseError("unexpected argument '\(options.positionals[0])' — use: dit store backup [--to DIR]")
    }
    let directory = options["to"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    let copies = try backupStore(global: global, to: directory)
    print("Backed up the store:")
    for url in copies {
        print("  → \(url.path)")
    }
}

/// `store import <file> [--merge|--force] [--yes]`: single-account
/// import, replace (default) or merge. Replace confirms (skippable
/// with `--yes`) and takes an automatic pre-import backup (skippable
/// with `--force`); a bad file is refused before either happens.
func storeImport(_ args: [String], global: Global) async throws {
    let options = try Options(args, flagOptions: ["merge", "force", "yes"])
    guard let raw = options.positionals.first else {
        throw ParseError("usage: dit store import FILE [--merge] [--force] [--yes]")
    }
    guard options.positionals.count == 1 else {
        throw ParseError("unexpected argument '\(options.positionals[1])' — use: dit store import FILE [--merge] [--force] [--yes]")
    }
    let file = URL(fileURLWithPath: raw, isDirectory: false)
    let data: Data
    do {
        data = try Data(contentsOf: file)
    } catch {
        throw ParseError("cannot read '\(raw)': \(error.localizedDescription)")
    }
    let incoming: Portfolio
    do {
        incoming = try JSONDecoder().decode(Portfolio.self, from: data)
    } catch {
        throw ParseError("'\(raw)' is not a dit portfolio export (decode failed: \(error.localizedDescription))")
    }

    // Validate first — a malformed file must neither take a backup
    // nor touch the store.
    let (store, configuration) = try openStore(global: global)
    let current = try await store.load() ?? Portfolio()
    let mode: Portfolio.ImportMode = options.has("merge") ? .merge : .replace
    let imported = try current.importing(incoming, mode: mode)
    let account = incoming.accounts[0]

    if mode == .replace {
        // Replace is destructive for that account's ledger — gate it
        // like every other destructive operation, then back up so a
        // bad import is one --store flag away.
        guard confirm(
            "Replace the record and ledger of '\(account.displayName)' with \(incoming.transactions.count) imported transaction(s)?",
            yes: options.has("yes"))
        else {
            throw LookupError("aborted — the store is unchanged")
        }
        if !options.has("force") {
            do {
                let copies = try backupStore(global: global)
                print("Store backed up before import:")
                for url in copies { print("  → \(url.path)") }
            } catch {
                printErr("warning: automatic pre-import backup failed: \(error) — continuing without a backup")
            }
        }
    }
    do {
        try await store.save(imported.portfolio)
    } catch {
        throw StoreError("could not save the portfolio: \(error.localizedDescription)")
    }
    for note in imported.notes { print(note) }
    print("Store: \(configuration.url.path)")
}
