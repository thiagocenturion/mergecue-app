import Foundation
import MergeCueCore

// Agent writes. Every call after `claim_task` carries the `lease_id` returned by the claim and (except
// `heartbeat`) the task `expected_version` for optimistic concurrency. Bounds below are enforced by `validate()`;
// the engine enforces leases, versions, transitions, rate limits and path confinement.

/// Shared length limits for agent-supplied text.
public enum IPCLimits {
    public static let maxAgentNameLength = 128
    public static let maxRunIDLength = 256
    public static let maxLeaseIDLength = 128
    public static let maxSHALength = 128
    public static let maxPathLength = 4096
    public static let maxChangedPaths = 10_000
    public static let maxNoteLength = 4000
    public static let maxProgressMessageLength = 280
    public static let maxCommandLength = 4096
    /// `report_tests.output` limit in UTF-8 bytes (16 KiB).
    public static let maxTestOutputBytes = 16 * 1024
    public static let maxSummaryLength = 4000
    public static let maxProposedReplyLength = 65_536
    public static let maxArtifactIDs = 100
    public static let maxKnownRisks = 50
    public static let maxKnownRiskLength = 1000
    public static let maxReasonLength = 4000
}

// MARK: - claim_task

/// `{task_id, agent_name, run_id?, expected_version}`.
public struct ClaimTaskParams: IPCMethodParams, Hashable {
    public typealias Output = ClaimTaskResult
    public static let method = IPCMethod.claimTask

    public var taskID: TaskID
    public var agentName: String
    /// Agent execution/session id, if the agent has one.
    public var runID: String?
    public var expectedVersion: Int

    public init(taskID: TaskID, agentName: String, runID: String? = nil, expectedVersion: Int) {
        self.taskID = taskID
        self.agentName = agentName
        self.runID = runID
        self.expectedVersion = expectedVersion
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireText(agentName, field: "agent_name", maxLength: IPCLimits.maxAgentNameLength)
        try IPCValidation.requireMaxLength(runID, field: "run_id", maxLength: IPCLimits.maxRunIDLength)
    }

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case agentName = "agent_name"
        case runID = "run_id"
        case expectedVersion = "expected_version"
    }
}

/// `{task_id, state, version, lease_id, lease_expires_at, heartbeat_interval_seconds, checkout?}`.
public struct ClaimTaskResult: Codable, Sendable, Hashable {
    public var taskID: TaskID
    public var state: TaskState
    public var version: Int
    /// Capability token for every later write on this task.
    public var leaseID: String
    public var leaseExpiresAt: Date
    public var heartbeatIntervalSeconds: Int
    public var checkout: TaskCheckoutDTO?

    public init(
        taskID: TaskID,
        state: TaskState,
        version: Int,
        leaseID: String,
        leaseExpiresAt: Date,
        heartbeatIntervalSeconds: Int,
        checkout: TaskCheckoutDTO? = nil
    ) {
        self.taskID = taskID
        self.state = state
        self.version = version
        self.leaseID = leaseID
        self.leaseExpiresAt = leaseExpiresAt
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.checkout = checkout
    }

    private enum CodingKeys: String, CodingKey {
        case state, version, checkout
        case taskID = "task_id"
        case leaseID = "lease_id"
        case leaseExpiresAt = "lease_expires_at"
        case heartbeatIntervalSeconds = "heartbeat_interval_seconds"
    }
}

// MARK: - heartbeat

/// `{task_id, lease_id}`.
public struct HeartbeatParams: IPCMethodParams, Hashable {
    public typealias Output = LeaseRenewalResult
    public static let method = IPCMethod.heartbeat

    public var taskID: TaskID
    public var leaseID: String

    public init(taskID: TaskID, leaseID: String) {
        self.taskID = taskID
        self.leaseID = leaseID
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireText(leaseID, field: "lease_id", maxLength: IPCLimits.maxLeaseIDLength)
    }

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case leaseID = "lease_id"
    }
}

/// `{version, lease_expires_at}` — result of `heartbeat` and `update_task`.
public struct LeaseRenewalResult: Codable, Sendable, Hashable {
    public var version: Int
    public var leaseExpiresAt: Date

    public init(version: Int, leaseExpiresAt: Date) {
        self.version = version
        self.leaseExpiresAt = leaseExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case leaseExpiresAt = "lease_expires_at"
    }
}

public typealias HeartbeatResult = LeaseRenewalResult
public typealias UpdateTaskResult = LeaseRenewalResult

// MARK: - update_task

/// Coarse progress phase reported by the agent.
public enum TaskPhase: String, Codable, Sendable, CaseIterable, Hashable {
    case investigating, planning, editing, testing, finalizing
}

/// `{task_id, lease_id, expected_version, phase, message (1…280)}`.
public struct UpdateTaskParams: IPCMethodParams, Hashable {
    public typealias Output = UpdateTaskResult
    public static let method = IPCMethod.updateTask

    public var taskID: TaskID
    public var leaseID: String
    public var expectedVersion: Int
    public var phase: TaskPhase
    public var message: String

    public init(taskID: TaskID, leaseID: String, expectedVersion: Int, phase: TaskPhase, message: String) {
        self.taskID = taskID
        self.leaseID = leaseID
        self.expectedVersion = expectedVersion
        self.phase = phase
        self.message = message
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireText(leaseID, field: "lease_id", maxLength: IPCLimits.maxLeaseIDLength)
        try IPCValidation.requireText(message, field: "message", maxLength: IPCLimits.maxProgressMessageLength)
    }

    private enum CodingKeys: String, CodingKey {
        case phase, message
        case taskID = "task_id"
        case leaseID = "lease_id"
        case expectedVersion = "expected_version"
    }
}

// MARK: - report_changes

/// `{task_id, lease_id, expected_version, worktree_path, base_sha, head_sha?, changed_paths, note?}`.
/// The app recomputes the diff itself; the reported paths are only compared against it.
public struct ReportChangesParams: IPCMethodParams, Hashable {
    public typealias Output = ReportChangesResult
    public static let method = IPCMethod.reportChanges

    public var taskID: TaskID
    public var leaseID: String
    public var expectedVersion: Int
    public var worktreePath: String
    public var baseSHA: String
    public var headSHA: String?
    public var changedPaths: [String]
    public var note: String?

    public init(
        taskID: TaskID,
        leaseID: String,
        expectedVersion: Int,
        worktreePath: String,
        baseSHA: String,
        headSHA: String? = nil,
        changedPaths: [String],
        note: String? = nil
    ) {
        self.taskID = taskID
        self.leaseID = leaseID
        self.expectedVersion = expectedVersion
        self.worktreePath = worktreePath
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.changedPaths = changedPaths
        self.note = note
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireText(leaseID, field: "lease_id", maxLength: IPCLimits.maxLeaseIDLength)
        try IPCValidation.requireText(worktreePath, field: "worktree_path", maxLength: IPCLimits.maxPathLength)
        try IPCValidation.requireText(baseSHA, field: "base_sha", maxLength: IPCLimits.maxSHALength)
        try IPCValidation.requireMaxLength(headSHA, field: "head_sha", maxLength: IPCLimits.maxSHALength)
        try IPCValidation.requireList(changedPaths, field: "changed_paths", maxCount: IPCLimits.maxChangedPaths, maxLength: IPCLimits.maxPathLength)
        try IPCValidation.requireMaxLength(note, field: "note", maxLength: IPCLimits.maxNoteLength)
    }

    private enum CodingKeys: String, CodingKey {
        case note
        case taskID = "task_id"
        case leaseID = "lease_id"
        case expectedVersion = "expected_version"
        case worktreePath = "worktree_path"
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case changedPaths = "changed_paths"
    }
}

/// `{artifact_id, version, verified_changed_paths, unexpected_paths, missing_paths}`.
public struct ReportChangesResult: Codable, Sendable, Hashable {
    /// The diff artifact MergeCue recorded (`art_…`).
    public var artifactID: String
    public var version: Int
    /// Reported and present in the recomputed diff.
    public var verifiedChangedPaths: [String]
    /// In the recomputed diff but not reported.
    public var unexpectedPaths: [String]
    /// Reported but not in the recomputed diff.
    public var missingPaths: [String]

    public init(artifactID: String, version: Int, verifiedChangedPaths: [String], unexpectedPaths: [String], missingPaths: [String]) {
        self.artifactID = artifactID
        self.version = version
        self.verifiedChangedPaths = verifiedChangedPaths
        self.unexpectedPaths = unexpectedPaths
        self.missingPaths = missingPaths
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case artifactID = "artifact_id"
        case verifiedChangedPaths = "verified_changed_paths"
        case unexpectedPaths = "unexpected_paths"
        case missingPaths = "missing_paths"
    }
}

// MARK: - report_tests

/// Outcome of a test command as reported by the agent.
public enum TestRunStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case passed, failed, error
    case notRun = "not_run"
}

/// `{task_id, lease_id, expected_version, command, exit_code, status, passed?, failed?, skipped?, duration_ms?,
/// output (≤ 16 KiB)}`. `passed` is rejected with a non-zero exit code or failures (`validation_failed`).
public struct ReportTestsParams: IPCMethodParams, Hashable {
    public typealias Output = ReportTestsResult
    public static let method = IPCMethod.reportTests

    public var taskID: TaskID
    public var leaseID: String
    public var expectedVersion: Int
    public var command: String
    public var exitCode: Int
    public var status: TestRunStatus
    public var passed: Int?
    public var failed: Int?
    public var skipped: Int?
    public var durationMs: Int?
    /// Bounded command output (untrusted when displayed).
    public var output: String

    public init(
        taskID: TaskID,
        leaseID: String,
        expectedVersion: Int,
        command: String,
        exitCode: Int,
        status: TestRunStatus,
        passed: Int? = nil,
        failed: Int? = nil,
        skipped: Int? = nil,
        durationMs: Int? = nil,
        output: String
    ) {
        self.taskID = taskID
        self.leaseID = leaseID
        self.expectedVersion = expectedVersion
        self.command = command
        self.exitCode = exitCode
        self.status = status
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.durationMs = durationMs
        self.output = output
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireText(leaseID, field: "lease_id", maxLength: IPCLimits.maxLeaseIDLength)
        try IPCValidation.requireText(command, field: "command", maxLength: IPCLimits.maxCommandLength)
        try IPCValidation.requireMaxBytes(output, field: "output", maxBytes: IPCLimits.maxTestOutputBytes)
        try IPCValidation.requireNonNegative(passed, field: "passed")
        try IPCValidation.requireNonNegative(failed, field: "failed")
        try IPCValidation.requireNonNegative(skipped, field: "skipped")
        try IPCValidation.requireNonNegative(durationMs, field: "duration_ms")
        if status == .passed, exitCode != 0 {
            throw IPCError.validationFailed("Tests cannot be reported as passed with a non-zero exit code (\(exitCode)).")
        }
        if status == .passed, let failed, failed > 0 {
            throw IPCError.validationFailed("Tests cannot be reported as passed with \(failed) failing test(s).")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case command, status, passed, failed, skipped, output
        case taskID = "task_id"
        case leaseID = "lease_id"
        case expectedVersion = "expected_version"
        case exitCode = "exit_code"
        case durationMs = "duration_ms"
    }
}

/// `{artifact_id, version}`.
public struct ReportTestsResult: Codable, Sendable, Hashable {
    public var artifactID: String
    public var version: Int

    public init(artifactID: String, version: Int) {
        self.artifactID = artifactID
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case artifactID = "artifact_id"
    }
}

// MARK: - submit_result

/// `{task_id, lease_id, expected_version, summary (1…4000), proposed_reply?, artifact_ids, known_risks?,
/// no_changes_reason?}`. Task-dependent rules (diff artifact or `no_changes_reason` for code tasks,
/// `proposed_reply` for `draft_reply`, artifact ownership) are enforced by the engine.
public struct SubmitResultParams: IPCMethodParams, Hashable {
    public typealias Output = TaskStateResult
    public static let method = IPCMethod.submitResult

    public var taskID: TaskID
    public var leaseID: String
    public var expectedVersion: Int
    public var summary: String
    public var proposedReply: String?
    public var artifactIDs: [String]
    public var knownRisks: [String]?
    public var noChangesReason: String?

    public init(
        taskID: TaskID,
        leaseID: String,
        expectedVersion: Int,
        summary: String,
        proposedReply: String? = nil,
        artifactIDs: [String] = [],
        knownRisks: [String]? = nil,
        noChangesReason: String? = nil
    ) {
        self.taskID = taskID
        self.leaseID = leaseID
        self.expectedVersion = expectedVersion
        self.summary = summary
        self.proposedReply = proposedReply
        self.artifactIDs = artifactIDs
        self.knownRisks = knownRisks
        self.noChangesReason = noChangesReason
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireText(leaseID, field: "lease_id", maxLength: IPCLimits.maxLeaseIDLength)
        try IPCValidation.requireText(summary, field: "summary", maxLength: IPCLimits.maxSummaryLength)
        if let proposedReply {
            try IPCValidation.requireText(proposedReply, field: "proposed_reply", maxLength: IPCLimits.maxProposedReplyLength)
        }
        try IPCValidation.requireList(artifactIDs, field: "artifact_ids", maxCount: IPCLimits.maxArtifactIDs, maxLength: 64)
        try IPCValidation.requireList(knownRisks, field: "known_risks", maxCount: IPCLimits.maxKnownRisks, maxLength: IPCLimits.maxKnownRiskLength)
        if let noChangesReason {
            try IPCValidation.requireText(noChangesReason, field: "no_changes_reason", maxLength: IPCLimits.maxReasonLength)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case taskID = "task_id"
        case leaseID = "lease_id"
        case expectedVersion = "expected_version"
        case proposedReply = "proposed_reply"
        case artifactIDs = "artifact_ids"
        case knownRisks = "known_risks"
        case noChangesReason = "no_changes_reason"
    }
}

/// `{version, state}` — result of `submit_result` and `fail_task`.
public struct TaskStateResult: Codable, Sendable, Hashable {
    public var version: Int
    public var state: TaskState

    public init(version: Int, state: TaskState) {
        self.version = version
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case version, state
    }
}

public typealias SubmitResultResult = TaskStateResult
public typealias FailTaskResult = TaskStateResult

// MARK: - fail_task

/// `{task_id, lease_id, expected_version, reason, retryable, blocked?}` — `blocked: true` means the agent needs
/// the user (→ `blocked`), otherwise the task becomes `failed`.
public struct FailTaskParams: IPCMethodParams, Hashable {
    public typealias Output = FailTaskResult
    public static let method = IPCMethod.failTask

    public var taskID: TaskID
    public var leaseID: String
    public var expectedVersion: Int
    public var reason: String
    public var retryable: Bool
    public var blocked: Bool?

    public init(taskID: TaskID, leaseID: String, expectedVersion: Int, reason: String, retryable: Bool, blocked: Bool? = nil) {
        self.taskID = taskID
        self.leaseID = leaseID
        self.expectedVersion = expectedVersion
        self.reason = reason
        self.retryable = retryable
        self.blocked = blocked
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireText(leaseID, field: "lease_id", maxLength: IPCLimits.maxLeaseIDLength)
        try IPCValidation.requireText(reason, field: "reason", maxLength: IPCLimits.maxReasonLength)
    }

    /// The state-machine trigger this call maps to.
    public var trigger: TaskTrigger {
        blocked == true ? .agentBlocked : .fail(retryable: retryable)
    }

    private enum CodingKeys: String, CodingKey {
        case reason, retryable, blocked
        case taskID = "task_id"
        case leaseID = "lease_id"
        case expectedVersion = "expected_version"
    }
}
