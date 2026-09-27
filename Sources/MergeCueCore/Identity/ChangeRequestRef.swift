import Foundation

/// Human-readable, provider-qualified change request reference used in the UI and over MCP (`change_ref`).
///
/// Formats: `github:github.com/acme/api#42`, `gitlab:gitlab.com/group/sub/api!42`,
/// `bitbucket_cloud:bitbucket.org/acme/api#42`, `gitlab:[::1]:8443/acme/api!7`. Encoded in JSON as that single
/// string. Encoding and decoding accept exactly the same values (`isValid`): encoding a ref that could not be
/// parsed back throws instead of writing an unreadable row.
///
/// `==` is exact (the repository path is case-sensitive, as displayed). To resolve an agent-typed ref, use
/// `matches(_:)` / `normalizedKey`, which compare the repository path case-insensitively like the providers do.
/// A ref carries no account: the engine resolves it to a `ChangeRequestKey` among the task's account when a
/// task is in scope, and rejects it as ambiguous when several accounts match without one.
public struct ChangeRequestRef: Codable, Sendable, Hashable, CustomStringConvertible, LosslessStringConvertible {
    public let kind: ProviderKind
    /// Lowercased instance host (may include `:port`).
    public let host: String
    /// Repository path as shown by the provider (`acme/api`; GitLab may be nested).
    public let repoFullPath: String
    public let number: Int

    /// Memberwise initializer. The host is lowercased; other values are taken as-is (see `validated` / `isValid`).
    public init(kind: ProviderKind, host: String, repoFullPath: String, number: Int) {
        self.kind = kind
        self.host = host.lowercased()
        self.repoFullPath = repoFullPath
        self.number = number
    }

    /// A ref only if it round-trips through its string form (valid host, ≥ 2 path segments, positive number).
    public static func validated(kind: ProviderKind, host: String, repoFullPath: String, number: Int) -> ChangeRequestRef? {
        let ref = ChangeRequestRef(kind: kind, host: host, repoFullPath: repoFullPath, number: number)
        return ref.isValid ? ref : nil
    }

    /// Whether `ChangeRequestRef(string: string) == self`, i.e. the value can be encoded and decoded. Defined as
    /// that round trip, so encoding and decoding can never disagree.
    public var isValid: Bool {
        ChangeRequestRef(string: string) == self
    }

    /// Provider-style identity: kind, host and number exact, repository path compared case-insensitively
    /// (GitHub, GitLab and Bitbucket paths are case-insensitive; agents type refs by hand).
    public func matches(_ other: ChangeRequestRef) -> Bool {
        kind == other.kind && host == other.host && number == other.number
            && repoFullPath.lowercased() == other.repoFullPath.lowercased()
    }

    /// `string` with the repository path lowercased: equal for refs that `matches`. Use as a lookup key.
    public var normalizedKey: String {
        "\(kind.rawValue):\(host)/\(repoFullPath.lowercased())\(kind.numberPrefix)\(number)"
    }

    /// Parses the canonical string form. Returns `nil` for anything malformed: unknown provider, missing host
    /// or repository path, a number prefix that does not match the provider (`!` is GitLab only), a
    /// non-positive or zero-padded number, whitespace or unexpected characters.
    public init?(string: String) {
        guard let colon = string.firstIndex(of: ":"),
              let kind = ProviderKind(rawValue: String(string[..<colon]))
        else { return nil }

        let rest = string[string.index(after: colon)...]
        // The host ends at the first "/" (after a bracketed IPv6 literal, whose ":" are not path characters).
        let searchStart = rest.first == "[" ? (rest.firstIndex(of: "]") ?? rest.endIndex) : rest.startIndex
        guard let slash = rest[searchStart...].firstIndex(of: "/") else { return nil }
        let host = rest[..<slash]
        guard Self.isValidHost(host) else { return nil }

        let afterHost = rest[rest.index(after: slash)...]
        guard let prefixChar = kind.numberPrefix.first,
              let prefixIndex = afterHost.lastIndex(of: prefixChar)
        else { return nil }
        let path = afterHost[..<prefixIndex]
        let digits = afterHost[afterHost.index(after: prefixIndex)...]

        guard Self.isValidRepoPath(path),
              let number = Self.parseNumber(digits)
        else { return nil }

        self.init(kind: kind, host: String(host), repoFullPath: String(path), number: number)
    }

    public init?(_ description: String) {
        self.init(string: description)
    }

    /// Canonical string form.
    public var string: String {
        "\(kind.rawValue):\(host)/\(repoFullPath)\(kind.numberPrefix)\(number)"
    }

    public var description: String { string }

    /// Short human label without provider/host, e.g. `acme/api#42`.
    public var shortLabel: String {
        "\(repoFullPath)\(kind.numberPrefix)\(number)"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = ChangeRequestRef(string: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Malformed change_ref: \(raw)")
        }
        self = parsed
    }

    /// Throws `EncodingError.invalidValue` for a ref that could not be decoded again (see `isValid`).
    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                string,
                .init(codingPath: encoder.codingPath, debugDescription: "change_ref would not round-trip: \(string)")
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    // MARK: Validation

    /// `name[:port]` where the name is DNS-like (letters, digits, `.`, `-`, `_` — underscores occur in internal
    /// hosts) or a bracketed IPv6 literal (`[::1]`, `[fe80::1%25en0]` is rejected: no zones).
    private static func isValidHost(_ host: Substring) -> Bool {
        guard !host.isEmpty else { return false }
        var name = host
        var portPart: Substring?
        if host.first == "[" {
            guard let close = host.firstIndex(of: "]") else { return false }
            name = host[...close]
            let afterClose = host[host.index(after: close)...]
            if !afterClose.isEmpty {
                guard afterClose.first == ":" else { return false }
                portPart = afterClose.dropFirst()
            }
            let literal = name.dropFirst().dropLast()
            guard literal.contains(":"),
                  literal.allSatisfy({ $0.isHexDigit && $0.isASCII || $0 == ":" || $0 == "." })
            else { return false }
        } else {
            if let colon = host.firstIndex(of: ":") {
                portPart = host[host.index(after: colon)...]
                name = host[..<colon]
            }
            guard !name.isEmpty, name.first != ".", name.first != "-", name.last != "." else { return false }
            guard name.allSatisfy({ $0.isASCIIAlphanumeric || $0 == "." || $0 == "-" || $0 == "_" }) else { return false }
        }
        if let portPart {
            guard !portPart.isEmpty, portPart.count <= 5, portPart.allSatisfy(\.isASCIIDigit) else { return false }
        }
        return true
    }

    /// At least `owner/name`; segments are non-empty, not `.`/`..`, and contain no `/`, `#`, `!`, whitespace or
    /// control characters (so the number prefix is unambiguous for every provider).
    private static func isValidRepoPath(_ path: Substring) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".."
                && segment.unicodeScalars.allSatisfy { scalar in
                    scalar != "#" && scalar != "!" && !scalar.properties.isWhitespace
                        && scalar.properties.generalCategory != .control
                        && scalar.properties.generalCategory != .format
                }
        }
    }

    private static func parseNumber(_ digits: Substring) -> Int? {
        guard !digits.isEmpty, digits.count <= 18, digits.first != "0",
              digits.allSatisfy(\.isASCIIDigit),
              let value = Int(digits), value > 0
        else { return nil }
        return value
    }
}

extension Character {
    var isASCIIDigit: Bool {
        guard let ascii = asciiValue else { return false }
        return (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(ascii)
    }

    var isASCIIAlphanumeric: Bool {
        guard let ascii = asciiValue else { return false }
        return (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(ascii)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(ascii)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(ascii)
    }
}
