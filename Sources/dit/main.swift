import DirectInvestTracker
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

/// dit — the command line for DirectInvestTracker.
///
/// A thin shell: parse arguments → load → mutate or derive → save →
/// render. Every rule with financial meaning (derivation, mutation
/// validation, rendering) lives in the library and is tested there.
///
/// Conventions:
/// - flags > env vars (`DIT_BACKEND`, `DIT_STORE_URL`) > defaults;
/// - dates are `YYYY-MM-DD`, amounts are plain decimals — invalid
///   input is a usage error (exit 2), never silently repaired;
/// - account references resolve by name (case-insensitive) or
///   UUID/unique prefix — ambiguity is reported, never guessed;
/// - destructive commands confirm (or require `--yes`);
/// - mutating commands make exactly one atomic save.
///
/// Exit codes: 0 success · 1 runtime error · 2 usage error.
@main
enum Main {

    // MARK: - Entry point

    /// Entry point: parse → dispatch → map failures to exit codes
    /// (0 success · 1 runtime error · 2 usage error).
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        var invocation = Invocation()
        var global = Global()
        do {
            let parsed = try parse(argv)
            invocation = parsed.invocation
            global = parsed.global
            if invocation.help {
                print(helpText(for: invocation))
                return
            }
            try await run(invocation, global: global)
        } catch let error as ParseError {
            // Machine mode keeps ONE parse path: failures arrive as the
            // same-shaped JSON document on stdout, exit codes unchanged.
            if global.json {
                print(JSONOutput.errorEnvelope(kind: "usage", message: error.message))
            } else {
                printErr("error: \(error.message)")
                printErr(helpText(for: invocation))
            }
            exit(2)
        } catch let error as LocalizedError {
            let message = error.errorDescription ?? "\(error)"
            if global.json { print(JSONOutput.errorEnvelope(kind: "runtime", message: message)) }
            else { printErr("error: \(message)") }
            exit(1)
        } catch {
            if global.json { print(JSONOutput.errorEnvelope(kind: "runtime", message: "\(error)")) }
            else { printErr("error: \(error)") }
            exit(1)
        }
    }

    /// Splits argv into command words, global options, and the rest.
    ///
    /// Command words are the leading bare tokens: one for plain
    /// commands, two for groups (`account add`). Global options may
    /// appear anywhere and are consumed here; everything else is passed
    /// to the command's own option scanner. A non-dash token is a
    /// command word only while the command still accepts words, so
    /// `dit accounts TD` keeps `TD` as a positional and
    /// `dit --store PATH summary` still selects summary.
    /// Split argv into global flags + the invocation (group, sub, rest).
    private static func parse(_ argv: [String]) throws -> (invocation: Invocation, global: Global) {
        var invocation = Invocation()
        var global = Global()
        var words: [String] = []
        var rest: [String] = []
        let groups: Set<String> = ["account", "tx", "transaction", "ticker", "store", "market", "quote", "help"]
        let globalValueOptions: Set<String> = ["display", "backend", "store", "market-store"]

        var i = 0
        // After an option only stage 2 understands (e.g. --kind), bare
        // tokens are option values or positionals — never a subcommand.
        // Stage 1-consumed options (--display/--store/--offline…) keep
        // the command-word stream open: 'dit account --display USD show TD'.
        var opaqueOptionSeen = false
        while i < argv.count {
            let token = argv[i]
            if token == "-h" || token == "--help" {
                invocation.help = true
                i += 1
                continue
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                var key = body
                var inline: String?
                if let eq = body.firstIndex(of: "=") {
                    key = String(body[..<eq])
                    inline = String(body[body.index(after: eq)...])
                }
                if globalValueOptions.contains(key) {
                    let value: String
                    if let inline {
                        value = inline
                        i += 1
                    } else {
                        guard i + 1 < argv.count else {
                            throw ParseError("missing value for --\(key)")
                        }
                        value = argv[i + 1]
                        i += 2
                    }
                    switch key {
                    case "display":
                        global.display = try parseCurrency(value, option: "--display")
                    case "backend":
                        guard value == "file" || value == "sqlite" else {
                            throw ParseError("unknown backend '\(value)' — use 'file' or 'sqlite'")
                        }
                        global.backend = value
                    case "store":
                        global.store = value
                    case "market-store":
                        global.marketStore = value
                    default:
                        break
                    }
                    continue
                }
                if key == "offline" {
                    if inline != nil { throw ParseError("--offline is a flag and takes no value") }
                    global.offline = true
                    i += 1
                    continue
                }
                if key == "json" {
                    if inline != nil { throw ParseError("--json is a flag and takes no value") }
                    global.json = true
                    i += 1
                    continue
                }
            }
            if !token.hasPrefix("-") {
                if words.isEmpty {
                    words.append(token)
                    i += 1
                    continue
                }
                if words.count == 1, groups.contains(words[0]), !opaqueOptionSeen {
                    words.append(token)
                    i += 1
                    continue
                }
            }
            if token.hasPrefix("--") && !token.hasPrefix("---") {
                opaqueOptionSeen = true
            }
            rest.append(token)
            i += 1
        }

        invocation.group = words.first ?? ""
        if words.first != nil && words.count > 1 { invocation.sub = words[1] }
        invocation.rest = rest
        return (invocation, global)
    }

    // MARK: - Dispatch

    /// Route the invocation to its command function (each command
    /// validates its own options and resolves its own references).
    private static func run(_ invocation: Invocation, global: Global) async throws {
        // --json is only honored where a schema exists; anywhere else it
        // is a usage error, never a silent fallback to table text (an
        // agent parsing JSON must never receive prose).
        if global.json {
            switch (invocation.group, invocation.sub) {
            case ("", _), ("summary", _), ("accounts", _), ("account", nil),
                 ("account", "list"), ("account", "show"), ("quote", _):
                break
            default:
                let command = ([invocation.group, invocation.sub].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " ").isEmpty)
                    ? "this command"
                    : ([invocation.group, invocation.sub].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: " "))
                throw ParseError("--json is not supported for '\(command)' — "
                    + "documented schemas: summary, accounts, account show, quote (see docs/json.md)")
            }
        }
        switch (invocation.group, invocation.sub) {
        case ("", _), ("summary", _):
            try await summary(global: global)
        case ("accounts", _):
            try await accountsList(global: global)
        case ("account", nil), ("account", "list"):
            try await accountsList(global: global)
        case ("account", "show"):
            try await accountShow(invocation.rest, global: global)
        case ("account", "add"):
            try await accountAdd(invocation.rest, global: global)
        case ("account", "edit"):
            try await accountEdit(invocation.rest, global: global)
        case ("account", "close"):
            try await accountClose(invocation.rest, global: global)
        case ("account", "delete"), ("account", "remove"):
            try await accountDelete(invocation.rest, global: global)
        case ("account", let sub?):
            throw ParseError("unknown account subcommand '\(sub)' — use list, show, add, edit, close, or delete")
        case ("tx", let sub?), ("transaction", let sub?):
            try await txCommand(sub, invocation.rest, global: global)
        case ("tx", nil), ("transaction", nil):
            try await txCommand("list", invocation.rest, global: global)
        case ("ticker", nil), ("ticker", "list"), ("ticker", "ls"):
            try await tickerList(global: global)
        case ("ticker", "show"):
            try await tickerShow(invocation.rest, global: global)
        case ("ticker", "add"):
            try await tickerAdd(invocation.rest, global: global)
        case ("ticker", "edit"):
            try await tickerEdit(invocation.rest, global: global)
        case ("ticker", "delete"), ("ticker", "remove"):
            try await tickerDelete(invocation.rest, global: global)
        case ("ticker", let sub?):
            throw ParseError("unknown ticker subcommand '\(sub)' — use list, show, add, edit, or delete")
        case ("store", nil), ("store", "path"):
            try await storePath(global: global)
        case ("store", "export"):
            try await storeExport(invocation.rest, global: global)
        case ("store", "backup"):
            try await storeBackup(invocation.rest, global: global)
        case ("store", "import"):
            try await storeImport(invocation.rest, global: global)
        case ("store", let sub?):
            throw ParseError("unknown store subcommand '\(sub)' — use path, export, backup, or import")
        case ("quote", let symbol?):
            try await quoteLookup(symbol, invocation.rest, global: global)
        case ("quote", _):
            throw ParseError("usage: dit quote <SYMBOL> [SYMBOL ...] — see 'dit help quote'")
        case ("market", nil), ("market", "latest"):
            try await marketLatest(global: global)
        case ("market", "history"):
            try await marketHistory(invocation.rest, global: global)
        case ("market", "backfill"):
            try await marketBackfill(invocation.rest, global: global)
        case ("market", "show"):
            try await marketShow(invocation.rest, global: global)
        case ("market", "import"):
            try await marketImport(invocation.rest, global: global)
        case ("market", let sub?):
            throw ParseError("unknown market subcommand '\(sub)' — use latest, history, backfill, import, or show (see 'dit help market')")
        case ("help", let topic):
            print(helpText(for: Invocation(group: topic ?? "usage", sub: nil, rest: [])))
        default:
            throw ParseError("unknown command '\(invocation.group)' — run 'dit help' for usage")
        }
    }

}
