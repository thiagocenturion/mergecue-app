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

/// Shape of an agent-supplied string.
enum IPCTextKind: Sendable {
    /// Identifiers, paths, names: no control characters at all.
    case singleLine
    /// Messages, summaries, replies: `\n` and `\t` allowed, every other control character rejected.
    case multiline
}

/// Shared bound checks used by the params DTOs (`invalid_params` on violation).
///
/// Lengths are counted in Unicode scalars (not grapheme clusters, which an agent could inflate without bound with
/// combining marks). Every checked string rejects C0/C1 control characters (except `\n`/`\t` in multiline text),
/// DEL and the bidirectional override/isolate controls U+202A–U+202E and U+2066–U+2069 ("Trojan Source").
enum IPCValidation {
    /// Non-blank string with at most `maxLength` Unicode scalars and no unsafe characters.
    static func requireText(_ value: String, field: String, maxLength: Int, kind: IPCTextKind = .singleLine) throws(IPCError) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IPCError.invalidParams("'\(field)' must not be empty.")
        }
        try requireMaxLength(value, field: field, maxLength: maxLength, kind: kind)
    }

    /// Optional string with at most `maxLength` Unicode scalars and no unsafe characters.
    static func requireMaxLength(_ value: String?, field: String, maxLength: Int, kind: IPCTextKind = .singleLine) throws(IPCError) {
        guard let value else { return }
        let length = value.unicodeScalars.count
        if length > maxLength {
            throw IPCError.invalidParams("'\(field)' must be at most \(maxLength) characters (got \(length)).")
        }
        try requireSafeCharacters(value, field: field, kind: kind)
    }

    /// Rejects control characters and bidi overrides (see type docs).
    static func requireSafeCharacters(_ value: String, field: String, kind: IPCTextKind) throws(IPCError) {
        for scalar in value.unicodeScalars where isUnsafe(scalar, kind: kind) {
            let code = String(scalar.value, radix: 16, uppercase: true)
            let padded = String(repeating: "0", count: max(0, 4 - code.count)) + code
            throw IPCError.invalidParams(
                "'\(field)' contains a disallowed control or bidirectional-override character (U+\(padded))\(kind == .singleLine ? "; it must be a single line" : "")."
            )
        }
    }

    /// Whether `scalar` is a control character or bidi override that agent text may not contain.
    static func isUnsafe(_ scalar: Unicode.Scalar, kind: IPCTextKind) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: kind == .singleLine
        case 0x00...0x1F, 0x7F...0x9F: true
        case 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    /// Strict identifier: 1…`maxLength` ASCII characters from `allowed`.
    static func requireIdentifier(_ value: String?, field: String, maxLength: Int, allowed: String, required: Bool) throws(IPCError) {
        guard let value else {
            if required { throw IPCError.invalidParams("'\(field)' must not be empty.") }
            return
        }
        try requireText(value, field: field, maxLength: maxLength)
        let allowedSet = Set(allowed.unicodeScalars)
        if let bad = value.unicodeScalars.first(where: { !($0.isASCII && (CharacterSet.alphanumerics.contains($0) || allowedSet.contains($0))) }) {
            throw IPCError.invalidParams("'\(field)' may only contain ASCII letters, digits and \"\(allowed)\" (found U+\(String(bad.value, radix: 16, uppercase: true))).")
        }
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

    /// Optional array with at most `maxCount` elements, each non-blank, at most `maxLength` scalars and safe.
    static func requireList(_ values: [String]?, field: String, maxCount: Int, maxLength: Int, kind: IPCTextKind = .singleLine) throws(IPCError) {
        guard let values else { return }
        if values.count > maxCount {
            throw IPCError.invalidParams("'\(field)' must contain at most \(maxCount) entries (got \(values.count)).")
        }
        for (index, value) in values.enumerated() {
            try requireText(value, field: "\(field)[\(index)]", maxLength: maxLength, kind: kind)
        }
    }
}
