import Foundation
import MergeCueCore

/// The code a line comment points at, as numbered diff rows.
///
/// GitHub sends a diff hunk with every review thread (`DiffAnchor.diffHunk`); Bitbucket and GitLab do not, so for
/// those the rows are cut from the change request's unified diff (loaded on demand). Either way the result is a
/// short window around the commented lines: up to `before` rows above the first commented line, the commented
/// range, and up to `after` rows below, never crossing a hunk boundary.
nonisolated enum CodeContext {
    static let before = 8
    static let after = 3

    /// Rows for `anchor`: from its own hunk when it has one, else from `diffFiles` (the change request's current
    /// diff, only used when the anchor is not outdated: an outdated anchor's lines belong to an older revision).
    static func lines(for anchor: DiffAnchor, diffFiles: [DiffFile]?) -> [DiffLine] {
        if let hunk = anchor.diffHunk, !hunk.isEmpty {
            let file = DiffParser.parse(hunk, defaultPath: anchor.path).first
            let rows = file?.lines ?? []
            // GitHub hunks end at the commented line; keep the tail when the line can't be found.
            return window(rows, anchor: anchor) ?? Array(rows.filter(\.isCode).suffix(before + 1))
        }
        guard !anchor.isOutdated, let files = diffFiles else { return [] }
        let file = files.first { $0.path == anchor.path } ?? anchor.oldPath.flatMap { old in files.first { $0.path == old } }
        guard let file else { return [] }
        return window(file.lines, anchor: anchor) ?? []
    }

    /// The window around the anchored rows of `rows` (nil when the anchored line isn't in them).
    static func window(_ rows: [DiffLine], anchor: DiffAnchor) -> [DiffLine]? {
        guard let line = anchor.line else { return nil }
        let start = min(anchor.startLine ?? line, line)
        guard let last = rows.lastIndex(where: { matches($0, line: line, side: anchor.side) }) else { return nil }
        let first = rows[...last].lastIndex(where: { matches($0, line: start, side: anchor.side) }) ?? last
        // Hunk boundaries around the anchored rows.
        let hunkStart = rows[..<first].lastIndex(where: { $0.kind == .hunk }).map { $0 + 1 } ?? rows.startIndex
        let hunkEnd = rows[(last + 1)...].firstIndex(where: { $0.kind == .hunk }) ?? rows.endIndex
        let lower = max(hunkStart, first - before)
        let upper = min(hunkEnd, last + after + 1)
        return rows[lower..<upper].filter(\.isCode)
    }

    /// Whether `row` is line `line` of `side`.
    static func matches(_ row: DiffLine, line: Int, side: DiffSide) -> Bool {
        switch side {
        case .new: row.kind != .removed && row.isCode && row.newNumber == line
        case .old: row.kind != .added && row.isCode && row.oldNumber == line
        }
    }

    /// Whether `row` falls inside the anchored range (the highlighted rows).
    static func isAnchored(_ row: DiffLine, anchor: DiffAnchor) -> Bool {
        guard let line = anchor.line else { return false }
        let range = min(anchor.startLine ?? line, line)...line
        switch anchor.side {
        case .new: return row.kind != .removed && row.newNumber.map(range.contains) == true
        case .old: return row.kind != .added && row.oldNumber.map(range.contains) == true
        }
    }
}

extension DiffLine {
    /// A code row (context, added or removed), not a hunk header or "\ No newline" marker.
    nonisolated var isCode: Bool {
        switch kind {
        case .context, .added, .removed: true
        case .hunk, .meta: false
        }
    }
}
