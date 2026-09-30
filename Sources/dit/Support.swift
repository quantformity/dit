import DirectInvestTracker
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Shared CLI support types
//
// The shapes the whole shell shares: failure kinds, the parsed
// invocation, and the option scanner. Kept out of the command files
// so "what a usage error is" and "what a flag is" are defined once.

// MARK: - Errors

/// A usage error (exit 2): bad flags, missing values, bad formats.
/// Printed with a usage hint; never reaches financial logic.
struct ParseError: Error {
    /// The whole message (self-contained, printed verbatim).
    let message: String
    /// Wraps a ready-to-print message.
    init(_ message: String) { self.message = message }
}

/// The store exists but holds no portfolio — a runtime condition
/// for write commands (exit 1), printed plainly for read commands.
struct NoPortfolio: LocalizedError {
    let path: String
    var errorDescription: String? { "no portfolio found at \(path)" }
}

/// A failed live price lookup (exit 1). Recording `--price` by
/// hand is always the escape hatch — a fetched price is a
/// convenience, never the only path.
struct LookupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A filesystem-level failure (export/backup/import IO) — a runtime
/// error (exit 1), distinct from a usage error (exit 2).
struct StoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Parsed invocation

/// The global flags resolved for this run (`--display`, `--backend`,
/// `--store`, `--market-store`, `--offline`, `--json`).
struct Global {
    /// Currency combined totals are expressed in (default CAD).
    var display: Currency = .cad
    /// `--backend` override (raw string; the factory validates it).
    var backend: String?
    /// `--store` override: directory or `.sqlite` file path.
    var store: String?
    /// `--market-store` override (kept separate from the portfolio).
    var marketStore: String?
    /// `--offline`: never touch the network; value from stored data.
    var offline = false
    /// `--json`: machine contract on stdout instead of tables.
    var json = false
}

/// What the user asked for, before any store is opened.
struct Invocation {
    /// Command group: "summary", "accounts", "account", "tx", …
    var group = "summary"          // "summary", "accounts", "account", …
    /// Sub-command within the group ("account add" → sub "add").
    var sub: String?               // "account add" → group "account", sub "add"
    /// Remaining tokens (options/positionals) for the command.
    var rest: [String] = []        // options/positionals for the command
    /// `-h`/`--help` seen anywhere → help wins over the command.
    var help = false
}

// MARK: - Options scanner

/// Minimal `--key value` / `--key=value` / `--flag` scanner.
/// Unknown options are errors — a typo'd flag must never silently
/// change what gets written.
struct Options {
    /// Parsed `--key value` pairs.
    var values: [String: String] = [:]
    /// Bare flags (no `=value`).
    var flags: Set<String> = []
    /// Explicit `--flag=false` values; a flag set here overrides its
    /// presence (bare `--flag` means true).
    var flagValues: [String: Bool] = [:]
    /// Tokens that are not options (account names, symbols…).
    var positionals: [String] = []

    /// Scans `args`; `valueOptions`/`flagOptions` declare what this
    /// command accepts — anything else starting with `-` is a usage
    /// error (typos must not silently change what gets written).
    init(_ args: [String],
         valueOptions: Set<String> = [],
         flagOptions: Set<String> = []) throws {
        var i = 0
        while i < args.count {
            let token = args[i]
            if token == "-h" || token == "--help" { i += 1; continue }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                var key = body
                var inline: String?
                if let eq = body.firstIndex(of: "=") {
                    key = String(body[..<eq])
                    inline = String(body[body.index(after: eq)...])
                }
                if valueOptions.contains(key) {
                    if let inline {
                        values[key] = inline
                    } else {
                        guard i + 1 < args.count else {
                            throw ParseError("missing value for --\(key)")
                        }
                        values[key] = args[i + 1]
                        i += 1
                    }
                } else if flagOptions.contains(key) {
                    if let inline {
                        switch inline.lowercased() {
                        case "true", "yes": flagValues[key] = true
                        case "false", "no": flagValues[key] = false
                        default:
                            throw ParseError("--\(key) is a flag — pass it, omit it, "
                                + "or write --\(key)=true / --\(key)=false")
                        }
                    } else {
                        flags.insert(key)
                    }
                } else {
                    throw ParseError("unknown option '\(token)'")
                }
            } else if token.hasPrefix("-") && token.count > 1 {
                throw ParseError("unknown option '\(token)'")
            } else {
                positionals.append(token)
            }
            i += 1
        }
    }

    /// Raw value of `--key` (nil = not passed).
    subscript(_ key: String) -> String? { values[key] }
    /// Whether the bare flag was passed (ignores `=true/false`).
    func has(_ key: String) -> Bool { flags.contains(key) }
    /// nil = not passed; true/false = passed (bare or `=true/false`).
    func flag(_ key: String) -> Bool? {
        if let explicit = flagValues[key] { return explicit }
        return flags.contains(key) ? true : nil
    }
    /// Required option; missing or empty is a usage error.
    func require(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw ParseError("missing required option --\(key)")
        }
        return value
    }
}
