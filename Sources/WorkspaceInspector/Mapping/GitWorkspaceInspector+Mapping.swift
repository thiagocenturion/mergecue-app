import Foundation
import MergeCueCore

extension GitWorkspaceInspector {
    /// Compares the checkout's remotes (fetch and push URLs, canonicalized host + path) with the repository's web
    /// and clone URLs.
    /// - `exact`: a remote canonicalizes to the repository.
    /// - `probable`: same host and repository name under another namespace (a fork remote), the same path on
    ///   another host (mirror / SSH alias), or — with no usable remote — a folder named like the repository.
    /// - `mismatch`: anything else, including missing paths and non-repositories.
    ///
    /// The suggestion's `checkoutPath` is the checkout's top level, so choosing a subfolder maps the whole checkout.
    public func match(repo: Repository, checkoutPath: String) async -> MappingSuggestion {
        let outcome: InspectOutcome
        do {
            outcome = try await inspectContext(path: checkoutPath)
        } catch {
            return MappingSuggestion(
                checkoutPath: Self.absolutePath(checkoutPath), confidence: .mismatch,
                reason: "Could not inspect the folder: \(Self.describeError(error))"
            )
        }
        switch outcome {
        case .failure(let info):
            let reason = info.safety == .missing ? "The folder does not exist." : "The folder is not a git checkout."
            return MappingSuggestion(checkoutPath: info.path, confidence: .mismatch, reason: reason)
        case .success(let context):
            return Self.classify(repo: repo, context: context)
        }
    }

    public func suggestMappings(for repo: Repository, searchRoots: [String]) async -> [MappingSuggestion] {
        var seen = Set<String>()
        var suggestions: [MappingSuggestion] = []
        for root in searchRoots {
            for candidate in Self.findRepositories(under: root, maxDepth: maxSearchDepth) {
                let key = Self.canonicalPath(candidate)
                guard seen.insert(key).inserted else { continue }
                if Task.isCancelled { return Self.sorted(suggestions) }
                let suggestion = await match(repo: repo, checkoutPath: candidate)
                if suggestion.confidence != .mismatch {
                    suggestions.append(suggestion)
                }
            }
        }
        return Self.sorted(suggestions)
    }

    // MARK: Classification

    static func classify(repo: Repository, context: RepoContext) -> MappingSuggestion {
        classify(repo: repo, topLevel: context.topLevel, rawRemotes: context.rawRemotes, note: safetyNote(context.info))
    }

    /// Classification from the remotes alone (shared by `match` and the single-pass `scanCheckouts`).
    static func classify(repo: Repository, topLevel: String, rawRemotes: [RawRemote], note: String = "") -> MappingSuggestion {
        let wanted = CanonicalRemote.candidates(for: repo)
        let path = topLevel

        for remote in rawRemotes {
            for (url, canonical) in [remote.fetchURL, remote.pushURL].compactMap({ $0 }).compactMap({ url in
                CanonicalRemote.parse(url).map { (url, $0) }
            }) where wanted.contains(canonical) {
                return MappingSuggestion(
                    checkoutPath: path, confidence: .exact, matchedRemote: url,
                    reason: "Remote '\(remote.name)' points to \(canonical).\(note)"
                )
            }
        }
        for remote in rawRemotes {
            for canonical in remote.canonicals {
                if let target = wanted.first(where: { $0.host == canonical.host && $0.name == canonical.name }) {
                    return MappingSuggestion(
                        checkoutPath: path, confidence: .probable, matchedRemote: remote.fetchURL,
                        reason: "Remote '\(remote.name)' points to \(canonical), a repository with the same name as "
                            + "\(target) (possibly a fork). Confirm before using this checkout.\(note)"
                    )
                }
                if let target = wanted.first(where: { $0.path == canonical.path }) {
                    return MappingSuggestion(
                        checkoutPath: path, confidence: .probable, matchedRemote: remote.fetchURL,
                        reason: "Remote '\(remote.name)' points to \(canonical): same path as \(target) on another "
                            + "host (mirror or SSH alias?). Confirm before using this checkout.\(note)"
                    )
                }
            }
        }
        let folder = (topLevel as NSString).lastPathComponent.lowercased()
        if rawRemotes.allSatisfy({ $0.canonicals.isEmpty }), folder == repo.name.lowercased() {
            return MappingSuggestion(
                checkoutPath: path, confidence: .probable,
                reason: "No remote identifies the repository, but the folder is named '\(repo.name)'. Confirm before "
                    + "using this checkout.\(note)"
            )
        }
        let remotes = rawRemotes.isEmpty
            ? "no remotes"
            : rawRemotes.prefix(3).map { remote in
                "\(remote.name) → \(remote.canonicals.first?.description ?? CanonicalRemote.sanitizedURL(remote.fetchURL))"
            }.joined(separator: ", ")
        return MappingSuggestion(
            checkoutPath: path, confidence: .mismatch,
            reason: "No remote matches \(repo.fullPath) (\(remotes))."
        )
    }

    private static func safetyNote(_ info: CheckoutInfo) -> String {
        switch info.safety {
        case .gitButlerWorkspace: " GitButler manages this checkout: MergeCue works in an independent clone."
        default: ""
        }
    }

    static func sorted(_ suggestions: [MappingSuggestion]) -> [MappingSuggestion] {
        suggestions.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence == .exact }
            return lhs.checkoutPath < rhs.checkoutPath
        }
    }

    static func describeError(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    // MARK: Scanning

    /// Directories never descended into while scanning.
    static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".build", "build", "DerivedData", "Pods", "Carthage", "vendor", "target", "dist",
        "Library", "Applications", ".Trash", "__pycache__", ".venv", "venv",
    ]
    static let maxScannedDirectories = 20_000
    static let maxRepositoriesPerRoot = 500

    /// Breadth-first search for git checkouts (a `.git` directory or file) at most `maxDepth` levels below
    /// `root`. Does not follow symlinks, skips hidden and dependency/build folders, does not descend into
    /// repositories, and is bounded in visited directories.
    static func findRepositories(under root: String, maxDepth: Int) -> [String] {
        var walk = CheckoutWalk(maxDepth: maxDepth, maxDirectories: maxScannedDirectories, maxCheckouts: maxRepositoriesPerRoot)
        walk.walk(root: root)
        return walk.found
    }
}

/// The bounded directory walk behind `findRepositories` and `scanCheckouts`: breadth-first, no symlinks, no hidden
/// or dependency/build folders, never inside a checkout. Directories already visited from another root (e.g.
/// `~/Documents/GitHub` under `~/Documents`) are not walked twice.
struct CheckoutWalk {
    let maxDepth: Int
    let maxDirectories: Int
    let maxCheckouts: Int
    private(set) var found: [String] = []
    private(set) var visited = 0
    private(set) var isTruncated = false
    private(set) var wasCancelled = false
    private var seen = Set<String>()

    init(maxDepth: Int, maxDirectories: Int, maxCheckouts: Int) {
        self.maxDepth = maxDepth
        self.maxDirectories = maxDirectories
        self.maxCheckouts = maxCheckouts
    }

    /// Walks one root; `report` is called every `reportEvery` directories.
    mutating func walk(root: String, reportEvery: Int = 250, report: (Int, Int) -> Void = { _, _ in }) {
        let fileManager = FileManager.default
        let start = GitWorkspaceInspector.absolutePath(root)
        guard GitWorkspaceInspector.pathKind(start) == .directory else { return }
        var queue: [(path: String, depth: Int)] = [(start, 0)]
        var head = 0
        while head < queue.count {
            if Task.isCancelled {
                wasCancelled = true
                return
            }
            guard visited < maxDirectories, found.count < maxCheckouts else {
                isTruncated = true
                return
            }
            let (directory, depth) = queue[head]
            head += 1
            guard seen.insert(GitWorkspaceInspector.canonicalPath(directory)).inserted else { continue }
            visited += 1
            if visited % reportEvery == 0 { report(visited, found.count) }
            let gitMarker = (directory as NSString).appendingPathComponent(".git")
            if GitWorkspaceInspector.pathKind(gitMarker) != .missing {
                found.append(directory)
                continue
            }
            guard depth < maxDepth,
                  let entries = try? fileManager.contentsOfDirectory(atPath: directory)
            else { continue }
            for name in entries.sorted() where !name.hasPrefix(".") && !GitWorkspaceInspector.skippedDirectoryNames.contains(name) {
                let child = (directory as NSString).appendingPathComponent(name)
                guard let attributes = try? fileManager.attributesOfItem(atPath: child),
                      attributes[.type] as? FileAttributeType == .typeDirectory
                else { continue }  // symlinks report .typeSymbolicLink and are skipped
                queue.append((child, depth + 1))
            }
        }
    }
}
