import Foundation
import MergeCueCore
import Synchronization

/// Renders GitLab `/diffs` entries (per-file hunks without headers) into a git-style unified diff. Used when
/// `raw_diffs` is unavailable (instances older than the endpoint).
enum GitLabDiffRenderer {
    struct Rendered {
        var text: String
        /// Some files were collapsed/too large and their hunks are missing.
        var omittedFiles: Int
    }

    static func render(_ files: [GLDiffFile]) -> Rendered {
        var output = ""
        var omitted = 0
        for file in files {
            output += "diff --git a/\(file.oldPath) b/\(file.newPath)\n"
            if file.newFile {
                output += "new file mode \(file.bMode ?? "100644")\n"
            } else if file.deletedFile {
                output += "deleted file mode \(file.aMode ?? "100644")\n"
            } else if let aMode = file.aMode, let bMode = file.bMode, aMode != bMode, aMode != "0", bMode != "0" {
                output += "old mode \(aMode)\nnew mode \(bMode)\n"
            }
            if file.renamedFile {
                output += "rename from \(file.oldPath)\nrename to \(file.newPath)\n"
            }
            let hunks = file.diff ?? ""
            if hunks.isEmpty {
                if file.tooLarge == true || file.collapsed == true {
                    omitted += 1
                    output += "# diff omitted by GitLab (\(file.tooLarge == true ? "too large" : "collapsed"))\n"
                }
                continue
            }
            output += "--- \(file.newFile ? "/dev/null" : "a/\(file.oldPath)")\n"
            output += "+++ \(file.deletedFile ? "/dev/null" : "b/\(file.newPath)")\n"
            output += hunks
            if !hunks.hasSuffix("\n") { output += "\n" }
        }
        return Rendered(text: output, omittedFiles: omitted)
    }
}

/// Process-wide memory of provider web URLs seen while listing/hydrating, so `deepLink(to:)` (which only gets
/// keys) can link to the exact merge request, note or job. GitLab keys carry the project id + iid but not the
/// project path, and GitLab has no id-based merge request web route.
enum GitLabLinkCache {
    private struct Store: Sendable {
        var changeRequests: [String: URL] = [:]
        var threadRootNotes: [String: String] = [:]
        var jobs: [String: URL] = [:]
        var projects: [String: URL] = [:]
        var count: Int { changeRequests.count + threadRootNotes.count + jobs.count + projects.count }
    }

    private static let limit = 20_000
    private static let store = Mutex(Store())

    static func remember(changeRequest key: ChangeRequestKey, webURL: URL, projectWebURL: URL?) {
        store.withLock { store in
            trimIfNeeded(&store)
            store.changeRequests[key.id] = webURL
            if let projectWebURL { store.projects[key.repo.id] = projectWebURL }
        }
    }

    static func remember(thread key: ThreadKey, rootNoteID: String) {
        store.withLock { store in
            trimIfNeeded(&store)
            store.threadRootNotes[key.id] = rootNoteID
        }
    }

    static func remember(check key: CheckKey, webURL: URL) {
        store.withLock { store in
            trimIfNeeded(&store)
            store.jobs[key.id] = webURL
        }
    }

    static func changeRequestURL(_ key: ChangeRequestKey) -> URL? {
        store.withLock { $0.changeRequests[key.id] }
    }

    static func projectURL(_ key: RepoKey) -> URL? {
        store.withLock { $0.projects[key.id] }
    }

    static func rootNoteID(_ key: ThreadKey) -> String? {
        store.withLock { $0.threadRootNotes[key.id] }
    }

    static func checkURL(_ key: CheckKey) -> URL? {
        store.withLock { $0.jobs[key.id] }
    }

    private static func trimIfNeeded(_ store: inout Store) {
        if store.count >= limit { store = Store() }
    }
}
