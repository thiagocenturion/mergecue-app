import Foundation
import MergeCueCore

/// Commit statuses and Pipelines steps → `CheckRun`s, and the honest merge-readiness evaluation.
struct BitbucketChecksMapper: Sendable {
    /// `logLocator` keys.
    enum Locator {
        static let repository = "repository"
        static let pipelineUUID = "pipeline_uuid"
        static let stepUUID = "step_uuid"
        static let buildNumber = "build_number"
        static let statusKey = "status_key"
        static let url = "url"
    }

    let instance: ProviderInstance
    let changeRequest: ChangeRequestKey
    let headSHA: String?

    // MARK: Commit statuses

    static func status(_ raw: String?) -> CheckStatus {
        switch raw?.uppercased() {
        case "SUCCESSFUL": .success
        case "FAILED": .failure
        case "INPROGRESS": .inProgress
        case "STOPPED": .cancelled
        default: .unknown
        }
    }

    /// Build number referenced by a Pipelines-generated commit status URL (`…/pipelines/results/101…`).
    static func pipelineBuildNumber(inStatusURL url: String?) -> Int? {
        guard let url, let range = url.range(of: "/results/") else { return nil }
        let digits = url[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// One check per status key (latest `updated_on` wins). Statuses mirrored by Bitbucket Pipelines for a pipeline
    /// that was fetched are dropped (its steps are reported instead). A status reported for another commit than the
    /// current head is marked `stale`.
    func checks(fromStatuses statuses: [BBCommitStatus], fetchedPipelineBuildNumbers: Set<Int>) -> [CheckRun] {
        var latest: [String: BBCommitStatus] = [:]
        var order: [String] = []
        for status in statuses {
            let key = status.key ?? status.name ?? status.url ?? ""
            guard !key.isEmpty else { continue }
            if let build = Self.pipelineBuildNumber(inStatusURL: status.url), fetchedPipelineBuildNumbers.contains(build),
               status.url?.contains("pipelines") == true
            {
                continue
            }
            if let existing = latest[key] {
                let existingDate = existing.updatedOn ?? existing.createdOn ?? .distantPast
                let date = status.updatedOn ?? status.createdOn ?? .distantPast
                if date >= existingDate { latest[key] = status }
            } else {
                latest[key] = status
                order.append(key)
            }
        }
        return order.compactMap { key -> CheckRun? in
            guard let status = latest[key] else { return nil }
            let commit = status.links?.commit?.href.flatMap { URL(string: $0)?.lastPathComponent }
            var state = Self.status(status.state)
            if let commit, let headSHA, !BitbucketIdentifiers.sameCommit(commit, headSHA) {
                state = .stale
            }
            var locator = [Locator.statusKey: key]
            if let url = status.url { locator[Locator.url] = url }
            return CheckRun(
                key: CheckKey(changeRequest: changeRequest, source: .bitbucketStatus, remoteID: key),
                name: status.name ?? key,
                status: state,
                isRequired: nil,
                startedAt: status.createdOn,
                completedAt: state.isTerminal ? status.updatedOn : nil,
                detailsURL: status.url.flatMap(URL.init(string:)),
                commitSHA: commit ?? headSHA,
                summary: status.description,
                logLocator: locator
            )
        }
    }

    // MARK: Pipelines

    static func status(_ state: BBPipelineState?) -> CheckStatus {
        switch state?.name?.uppercased() {
        case "PENDING", "READY", "PARSING", "HALTED":
            return .queued
        case "IN_PROGRESS", "RUNNING":
            if state?.stage?.name?.uppercased() == "PAUSED" { return .actionRequired }
            return .inProgress
        case "COMPLETED":
            switch state?.result?.name?.uppercased() {
            case "SUCCESSFUL": return .success
            case "FAILED", "ERROR": return .failure
            case "STOPPED": return .cancelled
            case "NOT_RUN", "SKIPPED": return .skipped
            case "EXPIRED": return .stale
            default: return .unknown
            }
        default:
            return .unknown
        }
    }

    /// The newest pipeline per selector (`pull-requests` vs `branches` vs `default`), so re-runs supersede older
    /// runs on the same commit.
    static func latestPipelines(_ pipelines: [BBPipeline]) -> [BBPipeline] {
        var result: [String: BBPipeline] = [:]
        var order: [String] = []
        for pipeline in pipelines {
            let selector = "\(pipeline.target?.selector?.type ?? "")|\(pipeline.target?.selector?.pattern ?? "")"
            if let existing = result[selector] {
                if (pipeline.buildNumber ?? 0, pipeline.createdOn ?? .distantPast)
                    > (existing.buildNumber ?? 0, existing.createdOn ?? .distantPast)
                {
                    result[selector] = pipeline
                }
            } else {
                result[selector] = pipeline
                order.append(selector)
            }
        }
        return order.compactMap { result[$0] }
    }

    /// Web page of a pipeline (and optionally one of its steps).
    func pipelineWebURL(repository: BitbucketRepoPath, buildNumber: Int?, pipelineUUID: String, stepUUID: String? = nil) -> URL {
        var url = instance.webURL.appending(path: repository.fullName).appending(path: "pipelines/results")
        url = url.appending(path: buildNumber.map(String.init) ?? pipelineUUID)
        if let stepUUID {
            url = url.appending(path: "steps").appending(path: stepUUID)
        }
        return url
    }

    /// `CheckKey.remoteID` of a pipeline step: `<build number>/<step uuid>` (a pipeline without steps uses
    /// `<build number>`), so deep links need no extra lookups.
    static func stepRemoteID(buildNumber: Int?, pipelineUUID: String, stepUUID: String?) -> String {
        let run = buildNumber.map(String.init) ?? pipelineUUID
        guard let stepUUID else { return run }
        return "\(run)/\(stepUUID)"
    }

    func checks(pipeline: BBPipeline, steps: [BBPipelineStep], repository: BitbucketRepoPath) -> [CheckRun] {
        let commit = pipeline.target?.commit?.hash ?? headSHA
        let runLabel = pipeline.buildNumber.map { "#\($0)" } ?? ""
        if steps.isEmpty {
            let status = Self.status(pipeline.state)
            return [
                CheckRun(
                    key: CheckKey(
                        changeRequest: changeRequest,
                        source: .bitbucketPipelineStep,
                        remoteID: Self.stepRemoteID(buildNumber: pipeline.buildNumber, pipelineUUID: pipeline.uuid, stepUUID: nil)
                    ),
                    name: "Pipeline",
                    status: status,
                    startedAt: pipeline.createdOn,
                    completedAt: pipeline.completedOn,
                    detailsURL: pipelineWebURL(repository: repository, buildNumber: pipeline.buildNumber, pipelineUUID: pipeline.uuid),
                    commitSHA: commit,
                    summary: "Bitbucket Pipelines \(runLabel)".trimmingCharacters(in: .whitespaces),
                    logLocator: [
                        Locator.repository: repository.fullName,
                        Locator.pipelineUUID: pipeline.uuid,
                        Locator.buildNumber: pipeline.buildNumber.map(String.init) ?? "",
                    ]
                ),
            ]
        }
        return steps.map { step in
            CheckRun(
                key: CheckKey(
                    changeRequest: changeRequest,
                    source: .bitbucketPipelineStep,
                    remoteID: Self.stepRemoteID(buildNumber: pipeline.buildNumber, pipelineUUID: pipeline.uuid, stepUUID: step.uuid)
                ),
                name: "Pipeline › \(step.name ?? "Step")",
                status: Self.status(step.state),
                startedAt: step.startedOn,
                completedAt: step.completedOn,
                detailsURL: pipelineWebURL(
                    repository: repository, buildNumber: pipeline.buildNumber, pipelineUUID: pipeline.uuid, stepUUID: step.uuid
                ),
                commitSHA: commit,
                summary: "Bitbucket Pipelines \(runLabel)".trimmingCharacters(in: .whitespaces),
                logLocator: [
                    Locator.repository: repository.fullName,
                    Locator.pipelineUUID: pipeline.uuid,
                    Locator.stepUUID: step.uuid,
                    Locator.buildNumber: pipeline.buildNumber.map(String.init) ?? "",
                ]
            )
        }
    }
}

/// Merge readiness from what the Bitbucket 2.0 API exposes to a non-admin user.
///
/// Bitbucket evaluates merge checks (minimum approvals, required builds, "no unresolved tasks", default reviewer
/// approvals) from branch restrictions that only workspace/repository admins can read, and the 2.0 API has no
/// documented mergeability endpoint. MergeCue therefore **never claims `readyToMerge`** for Bitbucket: when nothing
/// it can see blocks the merge and checks pass it reports `checksGreen`; visible blockers give `blocked(reasons)`;
/// no checks and no blockers give `unknown`.
enum BitbucketReadiness {
    static func evaluate(
        state: ChangeRequestState,
        isDraft: Bool,
        reviewers: [Reviewer],
        threads: [ReviewThread],
        unresolvedTaskCount: Int,
        checks: [CheckRun]
    ) -> MergeReadiness {
        var reasons: [String] = []
        switch state {
        case .merged: return .blocked(reasons: ["Pull request is already merged"])
        case .closed: return .blocked(reasons: ["Pull request is declined"])
        case .open: break
        }
        if isDraft { reasons.append("Draft pull request") }
        let requesters = reviewers.filter { $0.state == .changesRequested }.map(\.person.displayLabel)
        if !requesters.isEmpty {
            reasons.append("Changes requested by " + requesters.joined(separator: ", "))
        }
        let unresolved = threads.filter(\.isUnresolved).count
        if unresolved > 0 {
            reasons.append(unresolved == 1 ? "1 unresolved comment thread" : "\(unresolved) unresolved comment threads")
        }
        if unresolvedTaskCount > 0 {
            reasons.append(unresolvedTaskCount == 1 ? "1 open task" : "\(unresolvedTaskCount) open tasks")
        }
        let aggregate = AggregateCheckState.aggregate(checks)
        switch aggregate {
        case .failing:
            let failing = checks.filter(\.status.isFailing).map(\.name)
            reasons.append("Failing checks: " + failing.joined(separator: ", "))
        case .pending:
            reasons.append("Checks still running")
        case .passing, .none:
            break
        }
        if !reasons.isEmpty { return .blocked(reasons: reasons) }
        return aggregate == .passing ? .checksGreen : .unknown
    }
}
