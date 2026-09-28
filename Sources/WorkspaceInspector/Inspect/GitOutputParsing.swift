import Foundation
import MergeCueCore

/// A remote as configured, with **raw** URLs. Internal only: raw URLs may carry credentials and must never be
/// returned, logged or put into errors. Public results use `GitRemote` (sanitized).
struct RawRemote: Sendable, Hashable {
    var name: String
    var fetchURL: String
    var pushURL: String?

    var canonicals: [CanonicalRemote] {
        [fetchURL, pushURL].compactMap { $0 }.compactMap(CanonicalRemote.parse)
    }

    var publicRemote: GitRemote {
        GitRemote(name: name, fetchURL: fetchURL, pushURL: pushURL)
    }
}

/// Parsers for machine-readable git output (`-z` everywhere, so paths with spaces/newlines are safe).
enum GitOutputParsing {
    /// `git config -z --get-regexp '^remote\..*\.(url|pushurl)$'` → remotes in config order ("origin" first).
    static func remotes(fromConfigZ output: String) -> [RawRemote] {
        var order: [String] = []
        var fetch: [String: String] = [:]
        var push: [String: String] = [:]
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let newline = record.firstIndex(of: "\n") else { continue }
            let key = String(record[..<newline])
            let value = String(record[record.index(after: newline)...])
            let lowered = key.lowercased()
            guard lowered.hasPrefix("remote.") else { continue }
            let isPush = lowered.hasSuffix(".pushurl")
            let suffixLength = isPush ? ".pushurl".count : ".url".count
            guard isPush || lowered.hasSuffix(".url"), key.count > "remote.".count + suffixLength else { continue }
            let name = String(key.dropFirst("remote.".count).dropLast(suffixLength))
            if !order.contains(name) { order.append(name) }
            if isPush {
                if push[name] == nil { push[name] = value }
            } else if fetch[name] == nil {
                fetch[name] = value
            }
        }
        let remotes = order.compactMap { name -> RawRemote? in
            guard let url = fetch[name] else { return nil }
            return RawRemote(name: name, fetchURL: url, pushURL: push[name])
        }
        return remotes.sorted { lhs, rhs in
            rank(lhs.name) < rank(rhs.name)
        }
    }

    private static func rank(_ name: String) -> Int {
        switch name {
        case "origin": 0
        case "upstream": 1
        default: 2
        }
    }

    /// `git status --porcelain=v1 -z` → changed paths (renames report the new path).
    static func porcelainPaths(_ output: String) -> [String] {
        var paths: [String] = []
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.count > 3 else { continue }
            let status = token.prefix(2)
            paths.append(String(token.dropFirst(3)))
            if status.first == "R" || status.first == "C" {
                index += 1  // original path follows
            }
        }
        return paths
    }

    /// `git worktree list --porcelain -z` → worktree paths.
    static func worktreePaths(_ output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { field in
            field.hasPrefix("worktree ") ? String(field.dropFirst("worktree ".count)) : nil
        }
    }

    /// `git diff --name-status -z` → changed paths.
    static func nameStatus(_ output: String) -> [ChangedPath] {
        var result: [ChangedPath] = []
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < tokens.count {
            let code = tokens[index]
            index += 1
            guard let letter = code.first else { continue }
            switch letter {
            case "R", "C":
                guard index + 1 < tokens.count else { return result }
                result.append(ChangedPath(path: tokens[index + 1], status: letter == "R" ? .renamed : .copied))
                index += 2
            default:
                guard index < tokens.count else { return result }
                let status: FileChangeStatus = switch letter {
                case "A": .added
                case "M", "T": .modified
                case "D": .removed
                default: .unknown
                }
                result.append(ChangedPath(path: tokens[index], status: status))
                index += 1
            }
        }
        return result
    }
}
