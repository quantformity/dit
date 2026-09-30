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

struct ParseError: Error {
    let message: String
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

struct Global {
    var display: Currency = .cad
    var backend: String?
    var store: String?
    var marketStore: String?
    var offline = false
    var json = false
}

struct Invocation {
    var group = "summary"          // "summary", "accounts", "account", …
    var sub: String?               // "account add" → group "account", sub "add"
    var rest: [String] = []        // options/positionals for the command
    var help = false
}

// MARK: - Options scanner

/// Minimal `--key value` / `--key=value` / `--flag` scanner.
/// Unknown options are errors — a typo'd flag must never silently
/// change what gets written.
struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    /// Explicit `--flag=false` values; a flag set here overrides its
    /// presence (bare `--flag` means true).
    var flagValues: [String: Bool] = [:]
    var positionals: [String] = []

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

    subscript(_ key: String) -> String? { values[key] }
    func has(_ key: String) -> Bool { flags.contains(key) }
    /// nil = not passed; true/false = passed (bare or `=true/false`).
    func flag(_ key: String) -> Bool? {
        if let explicit = flagValues[key] { return explicit }
        return flags.contains(key) ? true : nil
    }
    func require(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw ParseError("missing required option --\(key)")
        }
        return value
    }
}
