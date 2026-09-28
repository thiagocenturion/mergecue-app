import Foundation

/// The per-task handoff code (S7): a short secret that MergeCue puts only into the handoff prompt the owner gives
/// to an agent (`(handoff code: K7Q2M9XD)`). `claim_task` must present it, so an arbitrary MCP client that merely
/// lists tasks cannot claim one. It is never returned by `get_task`, `list_tasks` or MCP resources.
public enum HandoffCode {
    /// Unambiguous upper-case alphabet (no 0/O, 1/I/L).
    public static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
    public static let length = 8

    /// A fresh code drawn from `ids` (deterministic with a seeded generator).
    public static func generate(using ids: IDGenerator) -> String {
        let hex = ids.randomHex(16)
        var value = UInt64(hex, radix: 16) ?? 0
        var result = ""
        for _ in 0..<length {
            result.append(alphabet[Int(value % UInt64(alphabet.count))])
            value /= UInt64(alphabet.count)
        }
        return result
    }

    /// Upper-cased, without spaces and dashes (agents may copy `k7q2-m9xd`).
    public static func normalized(_ code: String) -> String {
        String(code.uppercased().unicodeScalars.filter { $0 != " " && $0 != "-" }.map(Character.init))
    }

    /// Constant-time comparison of normalized codes.
    public static func matches(presented: String, expected: String) -> Bool {
        let lhs = Array(normalized(presented).utf8)
        let rhs = Array(normalized(expected).utf8)
        guard !rhs.isEmpty else { return false }
        var difference: UInt8 = lhs.count == rhs.count ? 0 : 1
        for index in rhs.indices {
            difference |= (index < lhs.count ? lhs[index] : 0) ^ rhs[index]
        }
        return difference == 0
    }

    /// The fragment appended to the task id in the handoff prompt.
    public static func promptFragment(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "" }
        return " (handoff code: \(code))"
    }
}
