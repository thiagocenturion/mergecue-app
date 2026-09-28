import Foundation
import MergeCueCore

extension GitWorkspaceInspector {
    /// Read-only: reports every reason `patch` cannot be imported into `checkoutPath` — missing folder, not a
    /// repository, GitButler workspace, uncommitted changes (with paths), unexpected HEAD, and conflicts from
    /// `git apply --check`.
    public func checkPatch(_ patch: String, into checkoutPath: String, expectedHeadSHA: String?) async throws -> PatchApplyCheck {
        try await evaluatePatch(patch, into: checkoutPath, expectedHeadSHA: expectedHeadSHA, apply: false)
    }

    /// Runs every `checkPatch` check and, only if there are no problems, `git apply` into the working tree —
    /// nothing is staged, committed or stashed, and `--whitespace=nowarn` makes sure the reviewed patch is applied
    /// verbatim (no `apply.whitespace=fix` rewriting). `canApply == true` in the result means it was applied.
    public func applyPatch(_ patch: String, into checkoutPath: String, expectedHeadSHA: String?) async throws -> PatchApplyCheck {
        try await evaluatePatch(patch, into: checkoutPath, expectedHeadSHA: expectedHeadSHA, apply: true)
    }

    private func evaluatePatch(
        _ patch: String, into checkoutPath: String, expectedHeadSHA: String?, apply: Bool
    ) async throws -> PatchApplyCheck {
        let context: RepoContext
        switch try await inspectContext(path: checkoutPath) {
        case .success(let value):
            context = value
        case .failure(let info):
            let problem = info.safety == .missing
                ? "\(info.path) does not exist."
                : "\(info.path) is not a git checkout."
            return PatchApplyCheck(canApply: false, problems: [problem], targetHeadSHA: nil, targetSafety: info.safety)
        }
        let info = context.info
        var problems: [String] = []

        if info.gitButler.isManaged {
            problems.append(
                "GitButler manages this checkout (\(info.gitButler.evidence.joined(separator: "; "))). MergeCue never "
                    + "writes into a GitButler workspace: import the reviewed patch through GitButler or apply it manually."
            )
        }
        if info.isDirty {
            let shown = info.dirtyPaths.prefix(10).joined(separator: ", ")
            let more = info.dirtyPaths.count > 10 ? " and \(info.dirtyPaths.count - 10) more" : ""
            problems.append(
                "The checkout has uncommitted changes (\(shown.isEmpty ? "unlisted paths" : shown)\(more)). "
                    + "Commit or stash them yourself, then retry."
            )
        }
        if let expected = expectedHeadSHA {
            if let head = info.headSHA {
                if !Self.sameCommit(expected, head) {
                    problems.append(
                        "HEAD is \(head.prefix(12)) but the patch was prepared for \(expected.prefix(12)). Check out "
                            + "the reviewed commit (or refresh the task) and retry."
                    )
                }
            } else {
                problems.append("The checkout has no commits; expected HEAD \(expected.prefix(12)).")
            }
        }
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problems.append("The patch is empty.")
            return PatchApplyCheck(canApply: false, problems: problems, targetHeadSHA: info.headSHA, targetSafety: info.safety)
        }

        let patchData = Data(patch.utf8)
        let check = try await git(
            ["apply", "--check", "--whitespace=nowarn", "-"], in: context.topLevel, stdin: patchData
        )
        if !check.succeeded {
            problems.append(contentsOf: Self.applyProblems(check.stderr))
        }
        guard problems.isEmpty, apply else {
            return PatchApplyCheck(
                canApply: problems.isEmpty, problems: problems, targetHeadSHA: info.headSHA, targetSafety: info.safety
            )
        }

        let applied = try await git(["apply", "--whitespace=nowarn", "-"], in: context.topLevel, stdin: patchData)
        if !applied.succeeded {
            problems.append(contentsOf: Self.applyProblems(applied.stderr))
        }
        return PatchApplyCheck(
            canApply: problems.isEmpty, problems: problems, targetHeadSHA: info.headSHA, targetSafety: info.safety
        )
    }

    /// `git apply` stderr → one problem per `error:` line (redacted, bounded).
    static func applyProblems(_ stderr: String) -> [String] {
        let lines = cleanMessage(stderr, maxBytes: 4_000)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let errors = lines.filter { $0.hasPrefix("error:") || $0.hasPrefix("fatal:") }
        let chosen = (errors.isEmpty ? lines : errors).prefix(20).map { line -> String in
            var text = line
            for prefix in ["error: ", "fatal: "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
            return "Patch conflict: \(text)"
        }
        return chosen.isEmpty ? ["The patch does not apply."] : Array(chosen)
    }
}
