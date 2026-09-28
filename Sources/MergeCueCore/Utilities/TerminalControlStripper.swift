import Foundation

/// Removes terminal control sequences and control characters from untrusted text (CI logs, review comments, PR
/// descriptions) before it is redacted, displayed or handed to an agent.
///
/// Stripped: ANSI/VT escape sequences (CSI `ESC [ … final`, OSC `ESC ] … BEL|ST` — including OSC 52 clipboard
/// writes and OSC 8 hyperlinks — DCS/SOS/PM/APC strings, two- and three-byte `ESC` sequences), their 8-bit C1
/// forms (U+009B CSI, U+009D OSC, …), every other C0/C1 control character and DEL. Kept: `\n` and `\t`;
/// `\r\n` becomes `\n` and a lone `\r` (progress-bar overwrites) becomes `\n`, so nothing can be hidden by
/// returning the cursor.
///
/// Runs in time linear in the input: sequences are consumed in one forward pass, and the search for a string
/// terminator is cached so many unterminated `ESC ]` introducers cannot cause rescans. An unterminated string
/// sequence only loses its introducer (the rest stays visible as plain text).
public enum TerminalControlStripper {
    /// `text` without control sequences/characters (see type docs). Returns `text` unchanged when it contains
    /// nothing to strip.
    public static func strip(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: needsWork) else { return text }
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)
        var finder = TerminatorFinder(scalars: scalars)
        var index = 0
        let count = scalars.count

        while index < count {
            let scalar = scalars[index]
            let value = scalar.value
            switch value {
            case 0x0A, 0x09:
                output.append(scalar)
                index += 1
            case 0x0D:
                output.append("\n")
                index += (index + 1 < count && scalars[index + 1].value == 0x0A) ? 2 : 1
            case 0x1B:
                index = skipEscape(at: index, scalars: scalars, finder: &finder)
            case 0x9B:
                index = skipCSIBody(from: index + 1, scalars: scalars)
            case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
                index = skipString(bodyStart: index + 1, introducerEnd: index + 1, finder: &finder)
            case 0x00...0x1F, 0x7F, 0x80...0x9F:
                index += 1
            default:
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }

    /// Whether `text` holds anything `strip` would remove or rewrite.
    public static func containsControls(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: needsWork)
    }

    // MARK: Internals

    private static func needsWork(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x0A || value == 0x09 { return false }
        return value < 0x20 || (0x7F...0x9F).contains(value)
    }

    /// Index after the escape sequence that starts with `ESC` at `index`.
    private static func skipEscape(at index: Int, scalars: [Unicode.Scalar], finder: inout TerminatorFinder) -> Int {
        let next = index + 1
        guard next < scalars.count else { return next }
        switch scalars[next].value {
        case 0x5B: // [ → CSI
            return skipCSIBody(from: next + 1, scalars: scalars)
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // ] P X ^ _ → OSC, DCS, SOS, PM, APC strings
            return skipString(bodyStart: next + 1, introducerEnd: next + 1, finder: &finder)
        case 0x20...0x2F: // intermediates, then one final byte (ESC ( B, ESC # 8, …)
            var cursor = next
            while cursor < scalars.count, (0x20...0x2F).contains(scalars[cursor].value) { cursor += 1 }
            if cursor < scalars.count, (0x30...0x7E).contains(scalars[cursor].value) { cursor += 1 }
            return cursor
        case 0x30...0x7E: // two-byte sequences (ESC =, ESC 7, ESC c, ESC \ …)
            return next + 1
        default:
            // ESC followed by a control or non-ASCII scalar: drop the ESC only.
            return next
        }
    }

    /// Index after a CSI body: parameters (0x30–0x3F), intermediates (0x20–0x2F), one final byte (0x40–0x7E).
    /// A malformed body ends at the first byte outside those classes (which is kept).
    private static func skipCSIBody(from start: Int, scalars: [Unicode.Scalar]) -> Int {
        var cursor = start
        while cursor < scalars.count, (0x30...0x3F).contains(scalars[cursor].value) { cursor += 1 }
        while cursor < scalars.count, (0x20...0x2F).contains(scalars[cursor].value) { cursor += 1 }
        if cursor < scalars.count, (0x40...0x7E).contains(scalars[cursor].value) { cursor += 1 }
        return cursor
    }

    /// Index after a control string (OSC/DCS/…) whose body starts at `bodyStart`, or `introducerEnd` when the
    /// string is never terminated (only the introducer is dropped).
    private static func skipString(bodyStart: Int, introducerEnd: Int, finder: inout TerminatorFinder) -> Int {
        guard let terminator = finder.next(from: bodyStart) else { return introducerEnd }
        return terminator.end
    }

    /// Finds the next string terminator (BEL, `ESC \`, U+009C). Positions only move forward, and a failed search
    /// is remembered, so total work is linear.
    private struct TerminatorFinder {
        let scalars: [Unicode.Scalar]
        private var searchedFrom = Int.max
        private var found: (start: Int, end: Int)?

        init(scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        mutating func next(from position: Int) -> (start: Int, end: Int)? {
            if position >= searchedFrom {
                // A previous search from an earlier position covers this one unless its hit lies before us.
                guard let hit = found else { return nil }
                if hit.start >= position { return hit }
            }
            searchedFrom = position
            var cursor = position
            while cursor < scalars.count {
                switch scalars[cursor].value {
                case 0x07, 0x9C:
                    found = (cursor, cursor + 1)
                    return found
                case 0x1B where cursor + 1 < scalars.count && scalars[cursor + 1].value == 0x5C:
                    found = (cursor, cursor + 2)
                    return found
                default:
                    cursor += 1
                }
            }
            found = nil
            return nil
        }
    }
}
