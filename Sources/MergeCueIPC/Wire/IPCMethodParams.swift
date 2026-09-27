import Foundation
import MergeCueCore

/// A params DTO bound to its method and result type, so `IPCClient.call(_:)` is fully typed.
///
/// `validate()` checks the bounds stated by the contract (lengths, limits, required combinations). It is not run
/// by `IPCCoding.decodeParams`: the engine calls it (or `IPCCoding.decodeValidatedParams`) so it can record a
/// `rejected_call` activity for writes that fail validation.
public protocol IPCMethodParams: Codable, Sendable {
    associatedtype Output: Codable & Sendable
    static var method: IPCMethod { get }
    func validate() throws(IPCError)
}

extension IPCMethodParams {
    public func validate() throws(IPCError) {}
}

/// Shared bound checks used by the params DTOs (`invalid_params` on violation).
enum IPCValidation {
    /// Non-blank string with at most `maxLength` characters.
    static func requireText(_ value: String, field: String, maxLength: Int) throws(IPCError) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IPCError.invalidParams("'\(field)' must not be empty.")
        }
        try requireMaxLength(value, field: field, maxLength: maxLength)
    }

    /// Optional string with at most `maxLength` characters.
    static func requireMaxLength(_ value: String?, field: String, maxLength: Int) throws(IPCError) {
        guard let value, value.count > maxLength else { return }
        throw IPCError.invalidParams("'\(field)' must be at most \(maxLength) characters (got \(value.count)).")
    }

    /// Optional string of at most `maxBytes` UTF-8 bytes.
    static func requireMaxBytes(_ value: String?, field: String, maxBytes: Int) throws(IPCError) {
        guard let value, value.utf8.count > maxBytes else { return }
        throw IPCError.invalidParams("'\(field)' must be at most \(maxBytes) bytes of UTF-8 (got \(value.utf8.count)).")
    }

    /// Optional integer inside `range`.
    static func requireRange(_ value: Int?, field: String, _ range: ClosedRange<Int>) throws(IPCError) {
        guard let value, !range.contains(value) else { return }
        throw IPCError.invalidParams("'\(field)' must be between \(range.lowerBound) and \(range.upperBound) (got \(value)).")
    }

    /// Optional integer that must be ≥ 0.
    static func requireNonNegative(_ value: Int?, field: String) throws(IPCError) {
        guard let value, value < 0 else { return }
        throw IPCError.invalidParams("'\(field)' must not be negative (got \(value)).")
    }

    /// Optional array with at most `maxCount` elements, each non-blank and at most `maxLength` characters.
    static func requireList(_ values: [String]?, field: String, maxCount: Int, maxLength: Int) throws(IPCError) {
        guard let values else { return }
        if values.count > maxCount {
            throw IPCError.invalidParams("'\(field)' must contain at most \(maxCount) entries (got \(values.count)).")
        }
        for (index, value) in values.enumerated() {
            try requireText(value, field: "\(field)[\(index)]", maxLength: maxLength)
        }
    }
}
