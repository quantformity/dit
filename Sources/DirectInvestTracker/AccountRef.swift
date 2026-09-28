import Foundation

/// A user's reference to an account — its name, or its UUID (possibly
/// a unique prefix).
///
/// Resolution is deterministic and reports ambiguity instead of
/// guessing: a query that matches several accounts is an error that
/// lists them, so the user can disambiguate with a longer prefix or
/// the full UUID.
public struct AccountRef: Sendable {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public enum ResolutionError: LocalizedError, Equatable {
        case empty
        case notFound(query: String)
        case ambiguous(query: String, matches: [String])

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "empty account reference"
            case .notFound(let query):
                return "no account matches '\(query)' — use the exact account name "
                    + "(see 'dit accounts') or a UUID prefix"
            case .ambiguous(let query, let matches):
                return "'\(query)' is ambiguous — it matches: \(matches.joined(separator: ", ")). "
                    + "Use a longer name or the full UUID."
            }
        }
    }

    /// Resolution order:
    /// 1. exact UUID (dashes optional, case-insensitive),
    /// 2. unique UUID prefix (hex only, at least 4 characters),
    /// 3. exact name (case-insensitive, trimmed).
    ///
    /// A query that *looks* like a UUID but matches nothing falls
    /// through to name lookup — an account could legitimately be named
    /// "CAFE". A name query that matches several accounts (or a
    /// prefix that does) throws ``ResolutionError/ambiguous``.
    public func resolve(in portfolio: Portfolio) throws -> Account {
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { throw ResolutionError.empty }

        let accounts = portfolio.accounts
        let hexQuery = query.replacingOccurrences(of: "-", with: "").uppercased()
        let looksHex = hexQuery.count >= 4 && hexQuery.allSatisfy(\.isHexDigit)

        if looksHex {
            let matching = accounts.filter { hexPrefix($0.id).hasPrefix(hexQuery) }
            if let exact = matching.first(where: { hexPrefix($0.id) == hexQuery }) {
                return exact
            }
            switch matching.count {
            case 1: return matching[0]
            case 0: break // fall through to name lookup
            default:
                throw ResolutionError.ambiguous(query: query, matches: matching.map(\.displayName))
            }
        }

        let byName = accounts.filter {
            $0.name?
                .trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(query) == .orderedSame
        }
        switch byName.count {
        case 1: return byName[0]
        case 0: throw ResolutionError.notFound(query: query)
        default: throw ResolutionError.ambiguous(query: query, matches: byName.map(\.displayName))
        }
    }

    private func hexPrefix(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }
}

extension Account {
    /// The name used in listings and messages: the name when set and
    /// non-empty, otherwise "Account <first 4 hex of the UUID>".
    public var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return "Account \(id.uuidString.prefix(4))"
    }
}