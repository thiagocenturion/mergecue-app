import Foundation

/// Human-readable, provider-qualified change request reference used in the UI and over MCP (`change_ref`).
///
/// Formats: `github:github.com/acme/api#42`, `gitlab:gitlab.com/group/sub/api!42`,
/// `bitbucket_cloud:bitbucket.org/acme/api#42`. Encoded in JSON as that single string.
public struct ChangeRequestRef: Codable, Sendable, Hashable, CustomStringConvertible, LosslessStringConvertible {
    public let kind: ProviderKind
    /// Lowercased instance host (may include `:port`).
    public let host: String
    /// Repository path as shown by the provider (`acme/api`; GitLab may be nested).
    public let repoFullPath: String
    public let number: Int

    /// Memberwise initializer. The host is lowercased; other values are taken as-is.
    public init(kind: ProviderKind, host: String, repoFullPath: String, number: Int) {
        self.kind = kind
        self.host = host.lowercased()
        self.repoFullPath = repoFullPath
        self.number = number
    }

    /// Parses the canonical string form. Returns `nil` for anything malformed: unknown provider, missing host
    /// or repository path, a number prefix that does not match the provider (`!` is GitLab only), a
    /// non-positive or zero-padded number, whitespace or unexpected characters.
    public init?(string: String) {
        guard let colon = string.firstIndex(of: ":"),
              let kind = ProviderKind(rawValue: String(string[..<colon]))
        else { return nil }

        let rest = string[string.index(after: colon)...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
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

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    // MARK: Validation

    private static func isValidHost(_ host: Substring) -> Bool {
        guard !host.isEmpty else { return false }
        var name = host
        if let colon = host.firstIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.count <= 5, port.allSatisfy(\.isASCIIDigit) else { return false }
            name = host[..<colon]
        }
        guard !name.isEmpty, name.first != ".", name.first != "-", name.last != "." else { return false }
        return name.allSatisfy { $0.isASCIIAlphanumeric || $0 == "." || $0 == "-" }
    }

    private static func isValidRepoPath(_ path: Substring) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".."
                && segment.allSatisfy { $0.isASCIIAlphanumeric || $0 == "." || $0 == "-" || $0 == "_" }
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
