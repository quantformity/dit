import Foundation

/// A user's reference to a transaction — its full UUID or a unique
/// prefix of the dashed or undashed UUID string (the `tx list` ID
/// column shows the first 8 characters for copy-paste).
///
/// Ambiguity is reported, never guessed: candidates are listed so the
/// user knows to type more characters.
public struct TransactionRef: Sendable {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public enum ResolutionError: LocalizedError, Equatable {
        case empty
        case notFound(query: String)
        case ambiguous(query: String, matches: [String])

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "empty transaction reference"
            case .notFound(let query):
                return "no transaction matches '\(query)' — use the ID shown by 'dit tx list' "
                    + "(full UUID or unique prefix)"
            case .ambiguous(let query, let matches):
                return "'\(query)' is ambiguous — it matches: \(matches.joined(separator: " | "))"
            }
        }
    }

    /// Resolution order mirrors ``AccountRef``: exact UUID (dashes
    /// optional) → unique hex prefix (at least 4 characters) → error.
    /// There is no name lookup: transactions are identified, not named.
    public func resolve(in portfolio: Portfolio) throws -> Transaction {
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { throw ResolutionError.empty }

        let hexQuery = query.replacingOccurrences(of: "-", with: "").uppercased()
        guard hexQuery.count >= 4, hexQuery.allSatisfy(\.isHexDigit) else {
            throw ResolutionError.notFound(query: query)
        }

        func hex(_ id: UUID) -> String {
            id.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        }
        let matching = portfolio.transactions.filter { hex($0.id).hasPrefix(hexQuery) }
        if let exact = matching.first(where: { hex($0.id) == hexQuery }) {
            return exact
        }
        switch matching.count {
        case 1:
            return matching[0]
        case 0:
            throw ResolutionError.notFound(query: query)
        default:
            throw ResolutionError.ambiguous(
                query: query,
                matches: matching.prefix(4).map { "\($0.summaryLine) [\($0.id.uuidString.prefix(8))]" })
        }
    }
}