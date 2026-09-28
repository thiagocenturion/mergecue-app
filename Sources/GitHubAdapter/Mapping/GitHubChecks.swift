import Foundation
import MergeCueCore

/// `statusCheckRollup` contexts → `CheckRun`s.
///
/// - `CheckRun` from the GitHub Actions app → `CheckSource.githubActionsJob` (the check run id **is** the Actions
///   job id); other check runs → `.githubCheckRun`. `remoteID` = check run `databaseId`.
/// - `StatusContext` (commit status) → `.githubStatus` with `remoteID` = the context name (unique per commit and
///   stable across pushes).
///
/// `logLocator` keys: `check_run_id`, `job_id` (Actions), `run_id`, `workflow`, `app`, `repo` (`owner/name`),
/// `context` (statuses).
enum GitHubChecks {
    static let actionsAppSlug = "github-actions"

    static func status(checkRunStatus: String?, conclusion: String?) -> CheckStatus {
        switch checkRunStatus?.uppercased() {
        case "COMPLETED":
            switch conclusion?.uppercased() {
            case "SUCCESS": .success
            case "FAILURE", "STARTUP_FAILURE": .failure
            case "CANCELLED": .cancelled
            case "SKIPPED": .skipped
            case "NEUTRAL": .neutral
            case "TIMED_OUT": .timedOut
            case "ACTION_REQUIRED": .actionRequired
            case "STALE": .stale
            default: .unknown
            }
        case "IN_PROGRESS": .inProgress
        case "QUEUED", "REQUESTED", "WAITING", "PENDING": .queued
        default: .unknown
        }
    }

    static func status(statusState: String?) -> CheckStatus {
        switch statusState?.uppercased() {
        case "SUCCESS": .success
        case "FAILURE", "ERROR": .failure
        case "PENDING": .inProgress
        case "EXPECTED": .queued
        default: .unknown
        }
    }

    /// The Actions job id from a check run details URL (`…/actions/runs/<run>/job/<job>`).
    static func jobID(fromDetailsURL url: URL?) -> String? {
        guard let url else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(of: "job"), index + 1 < parts.count,
              !parts[index + 1].isEmpty, parts[index + 1].allSatisfy(\.isNumber)
        else { return nil }
        return parts[index + 1]
    }

    static func checks(
        _ contexts: [GQLContext],
        changeRequest: ChangeRequestKey,
        headSHA: String?,
        repoFullPath: String
    ) -> [CheckRun] {
        var result: [CheckRun] = []
        var seen = Set<String>()
        for context in contexts {
            guard let check = check(context, changeRequest: changeRequest, headSHA: headSHA, repoFullPath: repoFullPath),
                  seen.insert(check.key.id).inserted
            else { continue }
            result.append(check)
        }
        return result.sorted { ($0.name.lowercased(), $0.key.id) < ($1.name.lowercased(), $1.key.id) }
    }

    static func check(
        _ context: GQLContext,
        changeRequest: ChangeRequestKey,
        headSHA: String?,
        repoFullPath: String
    ) -> CheckRun? {
        switch context.typename {
        case "CheckRun":
            guard let id = context.databaseId?.value else { return nil }
            let slug = context.checkSuite?.app?.slug
            let isActions = slug == actionsAppSlug
            let details = context.detailsUrl ?? context.url
            var locator: [String: String] = ["check_run_id": id, "repo": repoFullPath]
            if let slug { locator["app"] = slug }
            if isActions { locator["job_id"] = jobID(fromDetailsURL: context.detailsUrl) ?? id }
            if let run = context.checkSuite?.workflowRun?.databaseId?.value { locator["run_id"] = run }
            if let workflow = context.checkSuite?.workflowRun?.workflow?.name { locator["workflow"] = workflow }
            return CheckRun(
                key: CheckKey(changeRequest: changeRequest, source: isActions ? .githubActionsJob : .githubCheckRun, remoteID: id),
                name: context.name ?? "check",
                status: status(checkRunStatus: context.status, conclusion: context.conclusion),
                isRequired: context.isRequired,
                startedAt: context.startedAt,
                completedAt: context.completedAt,
                detailsURL: details,
                commitSHA: headSHA,
                summary: summary(title: context.title, text: context.summary),
                logLocator: locator
            )
        case "StatusContext":
            guard let name = context.context, !name.isEmpty else { return nil }
            let status = status(statusState: context.state)
            return CheckRun(
                key: CheckKey(changeRequest: changeRequest, source: .githubStatus, remoteID: name),
                name: name,
                status: status,
                isRequired: context.isRequired,
                startedAt: context.createdAt,
                completedAt: status.isTerminal ? context.createdAt : nil,
                detailsURL: context.targetUrl,
                commitSHA: headSHA,
                summary: summary(title: context.description, text: nil),
                logLocator: ["context": name, "repo": repoFullPath]
            )
        default:
            return nil
        }
    }

    private static func summary(title: String?, text: String?) -> String? {
        let parts = [title, text].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return BoundedText.truncate(parts.joined(separator: "\n"), maxBytes: GitHubMapping.maxCheckSummaryBytes).text
    }
}

/// Merge readiness from GitHub's own merge evaluation plus MergeCue's thread/check view.
///
/// - `readyToMerge` only when `mergeStateStatus` is `CLEAN` (or `HAS_HOOKS`, GHES), the PR is an open non-draft,
///   no review thread is unresolved and checks pass (or there are none). `mergeStateStatus` already folds in
///   branch protection: required reviews, required checks and conversation resolution.
/// - `checksGreen` when checks pass but anything else is missing.
/// - `blocked(reasons)` otherwise; `unknown` for merged/closed pull requests.
enum GitHubReadiness {
    static let cleanStates: Set<String> = ["CLEAN", "HAS_HOOKS"]

    static func evaluate(
        state: ChangeRequestState,
        isDraft: Bool,
        mergeStateStatus: String?,
        mergeable: String?,
        reviewDecision: String?,
        unresolvedThreads: Int,
        checks: AggregateCheckState
    ) -> MergeReadiness {
        guard state == .open else { return .unknown }
        let mergeState = mergeStateStatus?.uppercased() ?? "UNKNOWN"
        let checksOK = checks == .passing || checks == .none
        if cleanStates.contains(mergeState), unresolvedThreads == 0, checksOK, !isDraft {
            return .readyToMerge
        }
        if checks == .passing {
            return .checksGreen
        }
        var reasons: [String] = []
        if isDraft || mergeState == "DRAFT" { reasons.append("Draft") }
        if mergeable?.uppercased() == "CONFLICTING" || mergeState == "DIRTY" { reasons.append("Merge conflicts") }
        switch reviewDecision?.uppercased() {
        case "CHANGES_REQUESTED": reasons.append("Changes requested")
        case "REVIEW_REQUIRED": reasons.append("Review required")
        default: break
        }
        if unresolvedThreads > 0 {
            reasons.append(unresolvedThreads == 1 ? "1 unresolved thread" : "\(unresolvedThreads) unresolved threads")
        }
        switch checks {
        case .failing: reasons.append("Checks failing")
        case .pending: reasons.append("Checks pending")
        case .passing, .none: break
        }
        if mergeState == "BEHIND" { reasons.append("Branch is behind the base branch") }
        if reasons.isEmpty {
            switch mergeState {
            case "BLOCKED": reasons.append("Blocked by branch protection rules")
            case "UNKNOWN": reasons.append("GitHub is still computing mergeability")
            case "UNSTABLE": reasons.append("Non-required checks are not passing")
            default: reasons.append("Not mergeable yet")
            }
        }
        return .blocked(reasons: reasons)
    }
}
