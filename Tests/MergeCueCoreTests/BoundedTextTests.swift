import Foundation
import MergeCueCore
import Testing

@Suite("BoundedText")
struct BoundedTextTests {
    @Test func shortTextIsUntouched() {
        let result = BoundedText.truncate("hello", maxBytes: 5)
        #expect(result.text == "hello")
        #expect(!result.isTruncated)
        #expect(result.originalByteCount == 5)
    }

    @Test func headTruncationCountsBytesNotCharacters() {
        let result = BoundedText.truncate("abcdef", maxBytes: 4)
        #expect(result.text == "abcd")
        #expect(result.isTruncated)
        #expect(BoundedText.truncate("abcdef", maxBytes: 0).text.isEmpty)
        #expect(BoundedText.truncate("abcdef", maxBytes: -3).isTruncated)
    }

    /// Every byte budget over multi-byte text yields valid UTF-8 that is a prefix/suffix of the input.
    @Test(arguments: ["héllo wörld", "日本語のテキスト", "emoji 🚀🎉👩‍💻 end", "e\u{301}\u{301} combining", "\u{10FFFF}x\u{80}"])
    func neverSplitsAScalar(_ text: String) {
        let total = text.utf8.count
        for budget in 0...total + 1 {
            let head = BoundedText.truncate(text, maxBytes: budget)
            #expect(head.text.utf8.count <= max(0, budget))
            #expect(text.hasPrefixBytes(head.text))
            #expect(head.text.unicodeScalars.allSatisfy { text.unicodeScalars.contains($0) })
            #expect(head.isTruncated == (total > budget))
            #expect(total - head.text.utf8.count < 4 || head.text.utf8.count > budget - 4, "backed off more than one scalar")

            let tail = BoundedText.truncate(text, maxBytes: budget, keepTail: true)
            #expect(tail.text.utf8.count <= max(0, budget))
            #expect(text.hasSuffixBytes(tail.text))
            #expect(total - tail.text.utf8.count < 4 || tail.text.utf8.count > budget - 4)
        }
    }

    @Test func cutsBeforeAMultiByteScalar() {
        // "a" + "é" (2 bytes) + "b": a 2-byte budget cannot include half of "é".
        #expect(BoundedText.truncate("aéb", maxBytes: 2).text == "a")
        #expect(BoundedText.truncate("aéb", maxBytes: 3).text == "aé")
        #expect(BoundedText.truncate("a🚀", maxBytes: 4).text == "a")
        #expect(BoundedText.truncate("🚀b", maxBytes: 2, keepTail: true).text == "b")
    }

    // MARK: Log excerpts

    private func makeLog(lines: Int, errorAt: [Int] = [], lineWidth: Int = 60) -> String {
        (0..<lines).map { index in
            if errorAt.contains(index) { return "line \(index): ERROR assertion failed in PaymentTests.testRetry" }
            return "line \(index): " + String(repeating: "x", count: lineWidth)
        }.joined(separator: "\n")
    }

    @Test func smallLogIsReturnedWhole() {
        let log = makeLog(lines: 5, errorAt: [2])
        let excerpt = BoundedText.logExcerpt(log, maxBytes: 10_000)
        #expect(excerpt.text == log)
        #expect(!excerpt.isTruncated)
    }

    @Test func keepsErrorContextAndTail() {
        let log = makeLog(lines: 2_000, errorAt: [500])
        let excerpt = BoundedText.logExcerpt(log, maxBytes: 4_096)
        #expect(excerpt.isTruncated)
        #expect(excerpt.originalByteCount == log.utf8.count)
        #expect(excerpt.text.utf8.count <= 4_096)
        #expect(excerpt.text.contains("line 500: ERROR assertion failed"))
        #expect(excerpt.text.contains("line 498: "), "2 lines of context before")
        #expect(excerpt.text.contains("line 503: "), "3 lines of context after")
        #expect(excerpt.text.contains("line 1999: "), "tail kept")
        #expect(!excerpt.text.contains("line 100: "))
        #expect(excerpt.text.contains("lines omitted]"))
        #expect(excerpt.text.hasPrefix("… [498 lines omitted] …"))
    }

    @Test func withoutErrorsKeepsTheTail() {
        let log = makeLog(lines: 1_000)
        let excerpt = BoundedText.logExcerpt(log, maxBytes: 2_048)
        #expect(excerpt.text.utf8.count <= 2_048)
        #expect(excerpt.text.contains("line 999: "))
        #expect(!excerpt.text.contains("line 0: "))
        #expect(excerpt.text.hasPrefix("… ["))
    }

    @Test func recognizesAllErrorKeywords() {
        for keyword in ["error", "FAIL", "panic", "Exception"] {
            var lines = (0..<600).map { "line \($0): " + String(repeating: "y", count: 50) }
            lines[100] = "line 100: something \(keyword) happened"
            let excerpt = BoundedText.logExcerpt(lines.joined(separator: "\n"), maxBytes: 2_048)
            #expect(excerpt.text.contains("line 100: something \(keyword) happened"), "\(keyword)")
        }
    }

    @Test func manyErrorsNeverExceedTheBudget() {
        let log = makeLog(lines: 5_000, errorAt: Array(stride(from: 0, to: 5_000, by: 7)))
        for budget in [256, 300, 1_000, 4_096, 16_384] {
            let excerpt = BoundedText.logExcerpt(log, maxBytes: budget)
            #expect(excerpt.text.utf8.count <= budget, "budget \(budget)")
            #expect(excerpt.isTruncated)
            let lastLine = String(excerpt.text.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
            #expect(log.hasSuffixBytes(lastLine.hasPrefix("…") ? String(lastLine.dropFirst()) : lastLine), "tail kept at budget \(budget)")
            if budget >= 1_000 {
                #expect(excerpt.text.contains("line 4999: "), "whole last line kept at budget \(budget)")
            }
        }
    }

    @Test func hugeSingleLineKeepsItsTail() {
        let log = String(repeating: "é", count: 50_000) + "END"
        let excerpt = BoundedText.logExcerpt(log, maxBytes: 1_000)
        #expect(excerpt.text.utf8.count <= 1_000)
        #expect(excerpt.text.hasSuffix("END"))
        #expect(excerpt.text.hasPrefix("…"), "clipped line is marked")
        #expect(excerpt.isTruncated)
    }

    @Test func hugeLastLineAfterNewlineStillShowsContent() {
        let log = "error: boom\n" + String(repeating: "z", count: 20_000) + "TAIL\n"
        let excerpt = BoundedText.logExcerpt(log, maxBytes: 1_024)
        #expect(excerpt.text.utf8.count <= 1_024)
        #expect(excerpt.text.contains("TAIL"))
    }

    @Test func tinyBudgetFallsBackToTail() {
        let log = makeLog(lines: 100, errorAt: [10])
        let excerpt = BoundedText.logExcerpt(log, maxBytes: 100)
        #expect(excerpt.text.utf8.count <= 100)
        #expect(log.hasSuffixBytes(excerpt.text))
    }

    @Test func overlongContextLinesAreClipped() {
        var lines = (0..<400).map { "line \($0): ok" + String(repeating: ".", count: 40) }
        lines[50] = "error: " + String(repeating: "w", count: 5_000)
        let excerpt = BoundedText.logExcerpt(lines.joined(separator: "\n"), maxBytes: 4_096)
        #expect(excerpt.text.utf8.count <= 4_096)
        #expect(excerpt.text.contains("error: www"))
        #expect(excerpt.text.contains("line 399: "))
    }
}

extension String {
    func hasPrefixBytes(_ other: String) -> Bool {
        Array(utf8).starts(with: other.utf8)
    }

    func hasSuffixBytes(_ other: String) -> Bool {
        Array(utf8).reversed().starts(with: other.utf8.reversed())
    }
}
