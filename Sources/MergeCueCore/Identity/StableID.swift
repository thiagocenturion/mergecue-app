import Foundation

/// Builds the stable, versioned string identifiers used as database primary keys.
///
/// Every identity component is percent-encoded (everything except RFC 3986 unreserved characters), so the
/// separators `/` and `:` never appear inside a component and the resulting ids are injective, e.g.
/// `v1/github/github.com/u:123/r:456/cr:789`.
public enum StableID {
    /// Version prefix of every stable id. Bump only together with a store migration.
    public static let version = "v1"

    private static let upperHex: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// Percent-encodes `component`, leaving only `A-Z a-z 0-9 - . _ ~` unescaped.
    public static func encode(_ component: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(component.utf8.count)
        for byte in component.utf8 {
            if isUnreserved(byte) {
                out.append(byte)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(upperHex[Int(byte >> 4)])
                out.append(upperHex[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Reverses `encode(_:)`. Returns `nil` for malformed escapes.
    public static func decode(_ component: String) -> String? {
        component.removingPercentEncoding
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }
}

/// Short, prefixed identifiers derived from stable ids, used in the UI and over MCP (`cr_…`, `thr_…`, …).
public enum ShortID {
    public static let changeRequestPrefix = "cr_"
    public static let threadPrefix = "thr_"
    public static let checkPrefix = "chk_"
    public static let attentionPrefix = "att_"
    public static let artifactPrefix = "art_"
    /// Repository short ids are not exposed over MCP; the prefix exists so `RepoKey.shortID` is self-describing.
    public static let repositoryPrefix = "repo_"

    /// Number of lowercase hex characters after the prefix.
    public static let hashLength = 10

    /// `prefix` + the first 10 lowercase hex characters of SHA-256(`id`).
    public static func make(prefix: String, from id: String) -> String {
        prefix + String(ContentDigest.sha256Hex(id).prefix(hashLength))
    }

    /// Whether `value` has the shape `prefix` + 10 lowercase hex characters.
    public static func isValid(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let hash = value.utf8.dropFirst(prefix.utf8.count)
        guard hash.count == hashLength else { return false }
        return hash.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}
