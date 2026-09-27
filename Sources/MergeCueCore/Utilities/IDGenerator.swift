import Foundation
import os

/// Random identifier factory. Use `IDGenerator.system` (or the static helpers) in production and
/// `IDGenerator(seed:)` for deterministic tests.
///
/// Formats: `art_` + 10 hex (same shape as other short ids), `act_` + 16 hex, `lease_` + 32 hex (128-bit
/// capability), `rule_` + 10 hex, `pv_` + 16 hex, `apr_` + 16 hex, `aud_` + 16 hex, `map_` + 10 hex,
/// `ntf_` + 16 hex.
public struct IDGenerator: Sendable {
    private let source: Source

    /// Uses `SystemRandomNumberGenerator`.
    public init() {
        source = .system
    }

    /// Deterministic sequence (SplitMix64) for tests.
    public init(seed: UInt64) {
        source = .seeded(SeededSource(seed: seed))
    }

    public static let system = IDGenerator()

    public func artifactID() -> String { ShortID.artifactPrefix + randomHex(ShortID.hashLength) }
    public func activityID() -> String { "act_" + randomHex(16) }
    public func leaseID() -> String { "lease_" + randomHex(32) }
    public func ruleID() -> String { "rule_" + randomHex(10) }
    public func previewID() -> String { "pv_" + randomHex(16) }
    public func approvalID() -> String { "apr_" + randomHex(16) }
    public func auditID() -> String { "aud_" + randomHex(16) }
    public func mappingID() -> String { "map_" + randomHex(10) }
    public func notificationID() -> String { "ntf_" + randomHex(16) }

    /// A task id drawn from this generator.
    public func taskID() -> TaskID {
        var generator = Generator(source: source)
        return TaskID.generate(using: &generator)
    }

    public static func artifactID() -> String { system.artifactID() }
    public static func activityID() -> String { system.activityID() }
    public static func leaseID() -> String { system.leaseID() }
    public static func ruleID() -> String { system.ruleID() }
    public static func previewID() -> String { system.previewID() }
    public static func approvalID() -> String { system.approvalID() }
    public static func auditID() -> String { system.auditID() }
    public static func mappingID() -> String { system.mappingID() }
    public static func notificationID() -> String { system.notificationID() }

    /// `count` lowercase hex characters.
    public func randomHex(_ count: Int) -> String {
        var generator = Generator(source: source)
        var bytes: [UInt8] = []
        bytes.reserveCapacity((count + 1) / 2)
        while bytes.count * 2 < count {
            withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0) }
        }
        return String(ContentDigest.hex(bytes).prefix(count))
    }

    // MARK: Randomness

    private enum Source: Sendable {
        case system
        case seeded(SeededSource)
    }

    private final class SeededSource: Sendable {
        private let state: OSAllocatedUnfairLock<UInt64>

        init(seed: UInt64) {
            state = OSAllocatedUnfairLock(initialState: seed)
        }

        func next() -> UInt64 {
            state.withLock { state in
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }
    }

    private struct Generator: RandomNumberGenerator {
        let source: Source
        var system = SystemRandomNumberGenerator()

        init(source: Source) {
            self.source = source
        }

        mutating func next() -> UInt64 {
            switch source {
            case .system: system.next()
            case .seeded(let seeded): seeded.next()
            }
        }
    }
}
