import CryptoKit
import Foundation

/// SHA-256 helpers used for stable identifiers, dedupe keys and preview fingerprints.
public enum ContentDigest {
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// Lowercase hex SHA-256 of the UTF-8 bytes of `string`.
    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Lowercase hex encoding of arbitrary bytes.
    public static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

extension URL {
    /// Creates a URL from a compile-time constant. An invalid literal is a programmer error (covered by tests),
    /// never a runtime condition, so it traps instead of returning an optional.
    package init(staticString string: StaticString) {
        guard let url = URL(string: "\(string)") else {
            preconditionFailure("Invalid static URL literal: \(string)")
        }
        self = url
    }
}
