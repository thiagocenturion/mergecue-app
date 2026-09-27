import Foundation

/// UTF-8 byte-bounded text helpers. Cuts never split a Unicode scalar.
public enum BoundedText {
    /// Result of bounding a text.
    public struct Truncation: Sendable, Hashable {
        public var text: String
        public var isTruncated: Bool
        /// UTF-8 size of the input.
        public var originalByteCount: Int

        public init(text: String, isTruncated: Bool, originalByteCount: Int) {
            self.text = text
            self.isTruncated = isTruncated
            self.originalByteCount = originalByteCount
        }
    }

    /// Keeps at most `maxBytes` UTF-8 bytes of `text` — the head, or the tail when `keepTail` is true — backing
    /// off to the nearest scalar boundary. No marker is added (callers decide how to present truncation).
    public static func truncate(_ text: String, maxBytes: Int, keepTail: Bool = false) -> Truncation {
        let utf8 = text.utf8
        let total = utf8.count
        guard total > maxBytes else {
            return Truncation(text: text, isTruncated: false, originalByteCount: total)
        }
        guard maxBytes > 0 else {
            return Truncation(text: "", isTruncated: true, originalByteCount: total)
        }
        if keepTail {
            var start = utf8.index(utf8.startIndex, offsetBy: total - maxBytes)
            while start < utf8.endIndex, isContinuation(utf8[start]) {
                start = utf8.index(after: start)
            }
            return Truncation(text: String(decoding: utf8[start...], as: UTF8.self), isTruncated: true, originalByteCount: total)
        }
        var end = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while end > utf8.startIndex, isContinuation(utf8[end]) {
            end = utf8.index(before: end)
        }
        return Truncation(text: String(decoding: utf8[..<end], as: UTF8.self), isTruncated: true, originalByteCount: total)
    }

    /// Bounds a CI log to `maxBytes`, preferring lines around `error|fail|panic|exception` (2 before, 3 after)
    /// plus the tail of the log. Omitted ranges are marked with `… [N lines omitted] …` lines. The result never
    /// exceeds `maxBytes`.
    public static func logExcerpt(_ log: String, maxBytes: Int) -> Truncation {
        let total = log.utf8.count
        guard total > maxBytes else {
            return Truncation(text: log, isTruncated: false, originalByteCount: total)
        }
        guard maxBytes >= 256 else {
            return truncate(log, maxBytes: maxBytes, keepTail: true)
        }

        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            line.hasSuffix("\r") ? line.dropLast() : line
        }
        let errorLines = lines.indices.filter { isErrorLine(lines[$0]) }

        var contextBudget = errorLines.isEmpty ? 0 : maxBytes * 45 / 100
        for _ in 0..<8 {
            let rendered = render(lines: lines, errorLines: errorLines, maxBytes: maxBytes, contextBudget: contextBudget)
            let size = rendered.utf8.count
            if size <= maxBytes {
                return Truncation(text: rendered, isTruncated: true, originalByteCount: total)
            }
            contextBudget = max(0, contextBudget - (size - maxBytes) - 64)
        }
        // Defensive fallback: plain tail.
        return truncate(log, maxBytes: maxBytes, keepTail: true)
    }

    // MARK: Internals

    private static let maxContextLineBytes = 512
    private static let errorPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: "error|fail|panic|exception", options: [.caseInsensitive]
    )

    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    private static func isErrorLine(_ line: Substring) -> Bool {
        guard let errorPattern else { return false }
        let text = String(line)
        return errorPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func render(lines: [Substring], errorLines: [Int], maxBytes: Int, contextBudget: Int) -> String {
        let markerReserve = 48
        var selected: [Int: String] = [:]

        // Tail first: everything not reserved for context and markers.
        var tailBudget = maxBytes - contextBudget - markerReserve * 2
        var index = lines.count - 1
        while index >= 0, tailBudget > 0 {
            let line = String(lines[index])
            let cost = line.utf8.count + 1
            if cost <= tailBudget {
                selected[index] = line
                tailBudget -= cost
            } else {
                if selected.values.allSatisfy(\.isEmpty) {
                    // An enormous last line: keep its tail, marked as clipped ("…" is 3 bytes).
                    selected[index] = "…" + truncate(line, maxBytes: tailBudget - 4, keepTail: true).text
                }
                break
            }
            index -= 1
        }
        let firstTailLine = index + 1

        // Error context windows, earliest first.
        var remaining = contextBudget
        outer: for errorLine in errorLines where errorLine < firstTailLine {
            let lower = max(0, errorLine - 2)
            let upper = min(firstTailLine - 1, errorLine + 3)
            guard lower <= upper else { continue }
            remaining -= markerReserve
            for candidate in lower...upper where selected[candidate] == nil {
                var line = String(lines[candidate])
                if line.utf8.count > maxContextLineBytes {
                    line = truncate(line, maxBytes: maxContextLineBytes).text + "…"
                }
                let cost = line.utf8.count + 1
                guard cost <= remaining else { break outer }
                selected[candidate] = line
                remaining -= cost
            }
        }

        var output: [String] = []
        var previous = -1
        for lineIndex in selected.keys.sorted() {
            let gap = lineIndex - previous - 1
            if gap > 0 {
                output.append("… [\(gap) line\(gap == 1 ? "" : "s") omitted] …")
            }
            if let line = selected[lineIndex] { output.append(line) }
            previous = lineIndex
        }
        let trailingGap = lines.count - 1 - previous
        if trailingGap > 0 {
            output.append("… [\(trailingGap) line\(trailingGap == 1 ? "" : "s") omitted] …")
        }
        if selected.isEmpty {
            output = ["… [log truncated] …"]
        }
        return output.joined(separator: "\n")
    }
}
