import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Terminal styling policy shared by stdout tables. Redirected output
/// stays plain; callers can disable styling with NO_COLOR or TERM=dumb.
enum TerminalStyle {
    static var stdoutSupportsBold: Bool {
        #if canImport(Darwin) || canImport(Glibc)
        let isTerminal = isatty(STDOUT_FILENO) == 1
        #else
        let isTerminal = false
        #endif
        return supportsBold(isTerminal: isTerminal, environment: ProcessInfo.processInfo.environment)
    }

    /// Keep the policy testable without changing process-wide environment
    /// variables or redirecting stdout in parallel tests.
    static func supportsBold(isTerminal: Bool, environment: [String: String]) -> Bool {
        isTerminal && environment["TERM"] != "dumb" && (environment["NO_COLOR"] ?? "").isEmpty
    }
}
