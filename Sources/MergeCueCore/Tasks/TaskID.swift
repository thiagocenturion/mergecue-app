import Foundation

/// Opaque task identifier: `mc_` + 6 characters from `[a-z0-9]` (e.g. `mc_7f3k2a`).
///
/// The space is ~2.2 billion ids, so collisions are likely long before it is exhausted (~1 % by ~6 600 tasks).
/// Use `generate(avoiding:)` with the known ids, and still retry on a unique-constraint violation at insert.
public struct TaskID: Codable, Sendable, Hashable, Comparable, RawRepresentable, CustomStringConvertible {
    public static let prefix = "mc_"
    public static let suffixLength = 6
    private static let alphabet: [UInt8] = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)

    public let rawValue: String

    /// Validates the format; returns nil for anything that is not `mc_` + 6 × `[a-z0-9]`.
    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(validated rawValue: String) {
        self.rawValue = rawValue
    }

    /// Whether `value` is a well-formed task id.
    public static func isValid(_ value: String) -> Bool {
        let bytes = value.utf8
        guard value.hasPrefix(prefix), bytes.count == prefix.utf8.count + suffixLength else { return false }
        return bytes.dropFirst(prefix.utf8.count).allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }

    /// A new random id from `SystemRandomNumberGenerator`.
    public static func generate() -> TaskID {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// A new id from `generator` (use a seeded generator for deterministic tests).
    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> TaskID {
        var bytes = Array(prefix.utf8)
        for _ in 0..<suffixLength {
            bytes.append(alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))])
        }
        return TaskID(validated: String(decoding: bytes, as: UTF8.self))
    }

    /// A new random id that is not in `taken`.
    public static func generate(avoiding taken: Set<TaskID>) -> TaskID {
        var generator = SystemRandomNumberGenerator()
        return generate(avoiding: taken, using: &generator)
    }

    /// A new id from `generator` that is not in `taken` (redraws on collision).
    public static func generate<G: RandomNumberGenerator>(avoiding taken: Set<TaskID>, using generator: inout G) -> TaskID {
        while true {
            let candidate = generate(using: &generator)
            if !taken.contains(candidate) { return candidate }
        }
    }

    public var description: String { rawValue }

    public static func < (lhs: TaskID, rhs: TaskID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = TaskID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Malformed task id: \(raw)")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
