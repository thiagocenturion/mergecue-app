import Foundation
import MergeCueCore

/// A change request diff read on demand, parsed once.
struct LoadedDiff {
    /// Head the diff was read at; a new head makes it stale.
    var headSHA: String?
    var files: [DiffFile]
}

/// Code context of line comments (`CodeContext`): providers that send no diff hunk with a comment (Bitbucket,
/// GitLab) get it from the change request's diff, read once per head and kept in memory only.
extension AppModel {
    /// Whether some line comment of `snapshot` needs the change request diff for its code context.
    func needsDiff(_ snapshot: ChangeRequestSnapshot) -> Bool {
        snapshot.threads.contains { thread in
            guard let anchor = thread.anchor else { return false }
            return (anchor.diffHunk ?? "").isEmpty && !anchor.isOutdated && anchor.line != nil
        }
    }

    /// The parsed diff of `snapshot` at its current head (nil until loaded, or when stale).
    func diffFiles(for snapshot: ChangeRequestSnapshot) -> [DiffFile]? {
        guard let loaded = changeRequestDiffs[snapshot.key.id], loaded.headSHA == snapshot.summary.headSHA else { return nil }
        return loaded.files
    }

    /// Whether the diff of `snapshot` is being read.
    func isLoadingDiff(_ snapshot: ChangeRequestSnapshot) -> Bool {
        loadingDiffIDs.contains(snapshot.key.id)
    }

    /// Reads (once per head) the change request diff when a line comment needs it. Failures stay quiet: the code
    /// card then says the code is unavailable instead of raising a banner for a background read.
    func loadDiffIfNeeded(_ snapshot: ChangeRequestSnapshot) async {
        let id = snapshot.key.id
        guard needsDiff(snapshot), diffFiles(for: snapshot) == nil, !loadingDiffIDs.contains(id) else { return }
        loadingDiffIDs.insert(id)
        defer { loadingDiffIDs.remove(id) }
        let head = snapshot.summary.headSHA
        guard let payload = try? await backend.perform(.loadDiff(snapshot.key)).diff else {
            changeRequestDiffs[id] = LoadedDiff(headSHA: head, files: [])
            return
        }
        let text = payload.unifiedDiff
        let files = await Task.detached(priority: .userInitiated) { DiffParser.parse(text) }.value
        changeRequestDiffs[id] = LoadedDiff(headSHA: head, files: files)
    }

    /// Rows of code to show under the first comment of `thread` (empty when there is none to show).
    func codeLines(for thread: ReviewThread, snapshot: ChangeRequestSnapshot) -> [DiffLine] {
        guard let anchor = thread.anchor else { return [] }
        return CodeContext.lines(for: anchor, diffFiles: diffFiles(for: snapshot))
    }
}
