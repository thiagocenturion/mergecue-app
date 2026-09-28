import Foundation
import MergeCueCore

extension GitWorkspaceInspector {
    /// Compares the checkout's remotes (fetch and push URLs, canonicalized host + path) with the repository's web
    /// and clone URLs.
    /// - `exact`: a remote canonicalizes to the repository.
    /// - `probable`: same host and repository name under another namespace (a fork remote), the same path on
    ///   another host (mirror / SSH alias), or — with no usable remote — a folder named like the repository.
    /// - `mismatch`: anything else, including missing paths and non-repositories.
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
        let wanted = CanonicalRemote.candidates(for: repo)
        let path = context.info.path
        let note = safetyNote(context.info)

        for remote in context.rawRemotes {
            for (url, canonical) in [remote.fetchURL, remote.pushURL].compactMap({ $0 }).compactMap({ url in
                CanonicalRemote.parse(url).map { (url, $0) }
            }) where wanted.contains(canonical) {
                return MappingSuggestion(
                    checkoutPath: path, confidence: .exact, matchedRemote: url,
                    reason: "Remote '\(remote.name)' points to \(canonical).\(note)"
                )
            }
        }
        for remote in context.rawRemotes {
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
        let folder = (context.topLevel as NSString).lastPathComponent.lowercased()
        if context.rawRemotes.allSatisfy({ $0.canonicals.isEmpty }), folder == repo.name.lowercased() {
            return MappingSuggestion(
                checkoutPath: path, confidence: .probable,
                reason: "No remote identifies the repository, but the folder is named '\(repo.name)'. Confirm before "
                    + "using this checkout.\(note)"
            )
        }
        let remotes = context.rawRemotes.isEmpty
            ? "no remotes"
            : context.rawRemotes.prefix(3).map { remote in
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

    private static func sorted(_ suggestions: [MappingSuggestion]) -> [MappingSuggestion] {
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
        let fileManager = FileManager.default
        let start = absolutePath(root)
        guard pathKind(start) == .directory else { return [] }
        var queue: [(path: String, depth: Int)] = [(start, 0)]
        var found: [String] = []
        var visited = 0
        var head = 0
        while head < queue.count, visited < maxScannedDirectories, found.count < maxRepositoriesPerRoot {
            let (directory, depth) = queue[head]
            head += 1
            visited += 1
            let gitMarker = (directory as NSString).appendingPathComponent(".git")
            if pathKind(gitMarker) != .missing {
                found.append(directory)
                continue
            }
            guard depth < maxDepth,
                  let entries = try? fileManager.contentsOfDirectory(atPath: directory)
            else { continue }
            for name in entries.sorted() where !name.hasPrefix(".") && !skippedDirectoryNames.contains(name) {
                let child = (directory as NSString).appendingPathComponent(name)
                guard let attributes = try? fileManager.attributesOfItem(atPath: child),
                      attributes[.type] as? FileAttributeType == .typeDirectory
                else { continue }  // symlinks report .typeSymbolicLink and are skipped
                queue.append((child, depth + 1))
            }
        }
        return found
    }
}
