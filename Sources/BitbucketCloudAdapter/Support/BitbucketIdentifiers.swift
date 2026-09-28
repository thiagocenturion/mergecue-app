import Foundation
import MergeCueCore
import MergeCueNetworking

/// Bitbucket UUID, BBQL and path helpers.
///
/// Bitbucket UUIDs are written with curly braces (`{8a6f…}`). They are kept verbatim as identifiers (Core keys,
/// `Person.remoteID`) and percent-encoded (`%7B…%7D`) whenever they appear in a path segment or query value.
public enum BitbucketIdentifiers {
    /// Canonical form of a Bitbucket UUID: trimmed, lower-cased, wrapped in `{…}` (added when missing).
    /// Returns nil for an empty value.
    public static func normalizedUUID(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("%7B") || value.hasPrefix("%7b") {
            value = value.removingPercentEncoding ?? value
        }
        value = value.lowercased()
        if !value.hasPrefix("{") { value = "{" + value }
        if !value.hasSuffix("}") { value += "}" }
        return value
    }

    /// Whether two Bitbucket UUIDs denote the same object (brace- and case-insensitive).
    public static func sameUUID(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalizedUUID(lhs), let rhs = normalizedUUID(rhs) else { return false }
        return lhs == rhs
    }

    /// A BBQL string literal: `"…"` with `\` and `"` escaped and control characters dropped.
    public static func bbqlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            default:
                if scalar.properties.generalCategory == .control { continue }
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"" + escaped + "\""
    }

    /// `reviewers.uuid="{uuid}" AND state="OPEN"` — the per-repository review-requested query.
    public static func reviewerQuery(userUUID: String) -> String {
        "reviewers.uuid=\(bbqlString(normalizedUUID(userUUID) ?? userUUID)) AND state=\"OPEN\""
    }

    /// One encoded path segment (`acme`, `%7B…%7D`).
    static func segment(_ value: String) -> String {
        RequestURLBuilder.encodePathSegment(value)
    }

    /// Hex commit hashes found in `text` (7…40 characters), in order.
    static func commitHashes(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            if (7...40).contains(current.count) { result.append(current.lowercased()) }
            current = ""
        }
        for character in text {
            if character.isHexDigit {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// Whether two (possibly abbreviated) commit hashes refer to the same commit.
    static func sameCommit(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.lowercased(), let rhs = rhs?.lowercased(), lhs.count >= 7, rhs.count >= 7 else {
            return false
        }
        return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }
}

/// `workspace/repo_slug` of a Bitbucket repository, derived from its `full_name`.
struct BitbucketRepoPath: Sendable, Hashable {
    var workspace: String
    var slug: String

    init(workspace: String, slug: String) {
        self.workspace = workspace
        self.slug = slug
    }

    /// Parses `acme/payments-api`; nil unless exactly two non-empty segments.
    init?(fullName: String) {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(workspace: String(parts[0]), slug: String(parts[1]))
    }

    var fullName: String { "\(workspace)/\(slug)" }

    /// `/repositories/{workspace}/{slug}` with both segments encoded.
    var apiPath: String {
        "/repositories/\(BitbucketIdentifiers.segment(workspace))/\(BitbucketIdentifiers.segment(slug))"
    }

    func pullRequestPath(_ id: Int) -> String {
        "\(apiPath)/pullrequests/\(id)"
    }
}
