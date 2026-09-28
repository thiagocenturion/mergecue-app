import Foundation

/// Path checks for agent-reported locations: a reported worktree must be exactly the task's worktree (after
/// resolving symlinks, with no `..` components), and reported changed paths must stay inside it.
enum PathConfinement {
    /// Whether any component of `path` is `..`.
    static func containsTraversal(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    /// Absolute, standardized path with symlinks resolved (`/tmp/x` → `/private/tmp/x` when it exists).
    static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var result = url.path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Absolute, standardized path without symlink resolution.
    static func standardized(_ path: String) -> String {
        var result = URL(fileURLWithPath: path).standardizedFileURL.path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// True when `reported` (absolute, no `..`) resolves to the same directory as `expected`.
    static func isSameDirectory(_ reported: String, as expected: String) -> Bool {
        guard reported.hasPrefix("/"), !containsTraversal(reported), !reported.contains("\0") else { return false }
        return canonical(reported) == canonical(expected)
    }

    /// The worktree-relative form of a reported changed path, or nil if it escapes the worktree.
    /// Accepts relative paths (`Sources/A.swift`, `./Sources/A.swift`) and absolute paths inside the worktree.
    static func relativeChangedPath(_ path: String, worktree: String) -> String? {
        guard !path.isEmpty, !path.contains("\0"), !containsTraversal(path) else { return nil }
        var candidate = path
        if candidate.hasPrefix("/") {
            // Compare both the literal and the symlink-resolved forms (a changed file may not exist any more).
            let roots = [standardized(worktree), canonical(worktree)]
            let paths = [standardized(candidate), canonical(candidate)]
            var relative: String?
            for root in roots {
                for path in paths where path.hasPrefix(root + "/") {
                    relative = String(path.dropFirst(root.count + 1))
                }
            }
            guard let relative else { return nil }
            candidate = relative
        }
        while candidate.hasPrefix("./") { candidate.removeFirst(2) }
        let segments = candidate.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: "/")
    }
}
