import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@Suite("Code context of line comments")
struct CodeContextTests {
    /// A two-file diff: `src/a.ts` has one hunk of 20 lines with an addition at new line 15.
    let diff: String = {
        var lines = ["diff --git a/src/a.ts b/src/a.ts", "--- a/src/a.ts", "+++ b/src/a.ts", "@@ -1,19 +1,20 @@"]
        for number in 1...14 { lines.append(" line \(number)") }
        lines.append("+added 15")
        for number in 15...19 { lines.append(" line \(number)") }
        lines += ["diff --git a/README.md b/README.md", "@@ -1 +1 @@", "-old", "+new"]
        return lines.joined(separator: "\n")
    }()

    @Test func windowAroundTheCommentedLineFromTheChangeRequestDiff() {
        let files = DiffParser.parse(diff)
        let rows = CodeContext.lines(for: DiffAnchor(path: "src/a.ts", line: 15), diffFiles: files)
        // 8 rows above, the line itself, 3 below.
        #expect(rows.count == 12)
        #expect(rows.first?.newNumber == 7)
        #expect(rows.last?.newNumber == 18)
        let anchored = rows.filter { CodeContext.isAnchored($0, anchor: DiffAnchor(path: "src/a.ts", line: 15)) }
        #expect(anchored.map(\.text) == ["added 15"])
        #expect(rows.allSatisfy { $0.isCode })
    }

    @Test func multiLineCommentsKeepTheWholeRange() {
        let anchor = DiffAnchor(path: "src/a.ts", line: 15, startLine: 3)
        let rows = CodeContext.lines(for: anchor, diffFiles: DiffParser.parse(diff))
        #expect(rows.first?.newNumber == 1)
        #expect(rows.filter { CodeContext.isAnchored($0, anchor: anchor) }.count == 13)
    }

    @Test func oldSideCommentsMatchRemovedLines() {
        let rows = CodeContext.lines(for: DiffAnchor(path: "README.md", line: 1, side: .old), diffFiles: DiffParser.parse(diff))
        #expect(rows.map(\.text) == ["old", "new"])
    }

    @Test func providerHunkWinsAndOutdatedAnchorsNeverUseTheCurrentDiff() {
        var anchor = DiffAnchor(path: "src/a.ts", line: 2, diffHunk: "@@ -1,2 +1,2 @@\n context\n+mine")
        #expect(CodeContext.lines(for: anchor, diffFiles: DiffParser.parse(diff)).map(\.text) == ["context", "mine"])
        anchor.diffHunk = nil
        anchor.isOutdated = true
        #expect(CodeContext.lines(for: anchor, diffFiles: DiffParser.parse(diff)).isEmpty)
    }

    @Test func missingFileOrLineGivesNothing() {
        let files = DiffParser.parse(diff)
        #expect(CodeContext.lines(for: DiffAnchor(path: "nope.swift", line: 1), diffFiles: files).isEmpty)
        #expect(CodeContext.lines(for: DiffAnchor(path: "src/a.ts", line: 500), diffFiles: files).isEmpty)
        #expect(CodeContext.lines(for: DiffAnchor(path: "src/a.ts", line: 15), diffFiles: nil).isEmpty)
    }
}
