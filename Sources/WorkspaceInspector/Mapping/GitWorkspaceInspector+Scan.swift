import Foundation
import MergeCueCore

// Single-pass checkout scan: one bounded walk of every search folder, one `git config` read per checkout found,
// then every repository is matched against the in-memory index (canonical remote → checkouts). The amount of work
// depends on the folders, not on how many repositories are being matched.

extension GitWorkspaceInspector {
    /// Upper bound of directories visited by one `scanCheckouts` pass (all roots together).
    static let maxScanDirectories = 40_000
    /// Upper bound of checkouts indexed by one `scanCheckouts` pass.
    static let maxScanCheckouts = 2_000
    /// Concurrent `git config` reads while indexing.
    static let remoteReadWidth = 8

    /// A checkout found by the walk with its remotes (read once).
    struct IndexedCheckout: Sendable {
        var path: String
        var remotes: [RawRemote]
    }

    public func scanCheckouts(
        for repos: [Repository], searchRoots: [String], progress: @escaping @Sendable (CheckoutScanProgress) -> Void
    ) async -> CheckoutScanResult {
        var walk = CheckoutWalk(maxDepth: maxSearchDepth, maxDirectories: Self.maxScanDirectories, maxCheckouts: Self.maxScanCheckouts)
        for root in searchRoots {
            walk.walk(root: root) { visited, found in
                progress(CheckoutScanProgress(directoriesScanned: visited, checkoutsFound: found))
            }
            if walk.wasCancelled || walk.isTruncated { break }
        }
        var result = CheckoutScanResult(
            directoriesScanned: walk.visited, checkoutsFound: walk.found.count,
            isTruncated: walk.isTruncated, wasCancelled: walk.wasCancelled
        )
        progress(CheckoutScanProgress(directoriesScanned: walk.visited, checkoutsFound: walk.found.count, isMatching: true))
        guard !walk.wasCancelled else { return result }

        let checkouts = await readRemotes(of: walk.found)
        if Task.isCancelled {
            result.wasCancelled = true
            return result
        }
        result.suggestions = Self.matchIndex(repos: repos, checkouts: checkouts)
        return result
    }

    /// Reads the remotes of every checkout (bounded concurrency; unreadable checkouts are indexed without remotes).
    private func readRemotes(of paths: [String]) async -> [IndexedCheckout] {
        await withTaskGroup(of: (Int, IndexedCheckout).self) { group in
            var results = [IndexedCheckout?](repeating: nil, count: paths.count)
            var next = 0
            func addNext() {
                guard next < paths.count else { return }
                let index = next
                let path = paths[index]
                next += 1
                group.addTask {
                    let output = try? await git(["config", "-z", "--get-regexp", #"^remote\..*\.(url|pushurl)$"#], in: path)
                    let remotes = output.flatMap { $0.succeeded ? GitOutputParsing.remotes(fromConfigZ: $0.stdout) : nil } ?? []
                    return (index, IndexedCheckout(path: path, remotes: remotes))
                }
            }
            for _ in 0..<Self.remoteReadWidth { addNext() }
            while let (index, checkout) = await group.next() {
                results[index] = checkout
                if Task.isCancelled {
                    group.cancelAll()
                } else {
                    addNext()
                }
            }
            return results.compactMap { $0 }
        }
    }

    /// Matches every repository against the indexed checkouts in one pass (pure; unit-tested). Only exact and
    /// probable candidates are returned, exact first.
    static func matchIndex(repos: [Repository], checkouts: [IndexedCheckout]) -> [RepoKey: [MappingSuggestion]] {
        var byRemote: [CanonicalRemote: [Int]] = [:]
        var byHostName: [String: [Int]] = [:]
        var byPath: [String: [Int]] = [:]
        var remoteLessByFolder: [String: [Int]] = [:]
        for (index, checkout) in checkouts.enumerated() {
            let canonicals = checkout.remotes.flatMap(\.canonicals)
            if canonicals.isEmpty {
                remoteLessByFolder[(checkout.path as NSString).lastPathComponent.lowercased(), default: []].append(index)
            }
            for canonical in Set(canonicals) {
                byRemote[canonical, default: []].append(index)
                byHostName["\(canonical.host)\n\(canonical.name)", default: []].append(index)
                byPath[canonical.path, default: []].append(index)
            }
        }
        var suggestions: [RepoKey: [MappingSuggestion]] = [:]
        for repo in repos {
            var candidates = Set<Int>()
            for wanted in CanonicalRemote.candidates(for: repo) {
                candidates.formUnion(byRemote[wanted] ?? [])
                candidates.formUnion(byHostName["\(wanted.host)\n\(wanted.name)"] ?? [])
                candidates.formUnion(byPath[wanted.path] ?? [])
            }
            candidates.formUnion(remoteLessByFolder[repo.name.lowercased()] ?? [])
            let found = candidates.sorted().map { index in
                classify(repo: repo, topLevel: checkouts[index].path, rawRemotes: checkouts[index].remotes)
            }.filter { $0.confidence != .mismatch }
            if !found.isEmpty { suggestions[repo.key] = sorted(found) }
        }
        return suggestions
    }
}
