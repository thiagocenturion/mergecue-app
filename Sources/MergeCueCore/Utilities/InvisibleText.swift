import Foundation

/// Invisible or direction-changing characters that can hide or reorder text in a preview (S11): zero-width
/// characters, bidi embeddings/overrides/isolates and marks, Unicode tag characters, soft hyphen, other invisible
/// format characters, and C0/C1 controls (except `\n` and `\t`). An emoji zero-width joiner (between two emoji) is
/// kept so emoji sequences survive.
public enum InvisibleText {
    /// Result of `sanitized(_:)`.
    public struct Sanitized: Sendable, Hashable {
        /// The text without invisible characters: exactly what will be posted.
        public var text: String
        /// Removed characters as "U+200B" → count.
        public var removed: [String: Int]

        public var removedCount: Int { removed.values.reduce(0, +) }

        /// "U+200B ×2, U+202E" (sorted), or nil when nothing was removed.
        public var removedSummary: String? {
            guard !removed.isEmpty else { return nil }
            return removed.sorted { $0.key < $1.key }.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }.joined(separator: ", ")
        }
    }

    /// Whether `scalar` is an invisible/bidi/control character (see type docs), ignoring the emoji-ZWJ exception.
    public static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: return false
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E, 0x3164, 0xFFA0, 0xFEFF: return true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F: return true
        case 0xFFF9...0xFFFB: return true
        case 0xE0000...0xE007F: return true
        default: return false
        }
    }

    /// `text` without invisible characters, plus what was removed.
    public static func sanitized(_ text: String) -> Sanitized {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: isInvisible) else { return Sanitized(text: text, removed: [:]) }
        var output = String.UnicodeScalarView()
        var removed: [String: Int] = [:]
        for (index, scalar) in scalars.enumerated() {
            if scalar.value == 0x200D, index > 0, index + 1 < scalars.count,
               scalars[index - 1].properties.isEmoji, scalars[index + 1].properties.isEmoji, scalars[index - 1].value > 0x7F {
                output.append(scalar)
                continue
            }
            if isInvisible(scalar) {
                let code = String(scalar.value, radix: 16, uppercase: true)
                removed["U+" + String(repeating: "0", count: max(0, 4 - code.count)) + code, default: 0] += 1
            } else {
                output.append(scalar)
            }
        }
        return Sanitized(text: String(output), removed: removed)
    }
}
