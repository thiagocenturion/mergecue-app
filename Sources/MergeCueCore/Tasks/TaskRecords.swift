import Foundation

/// Kind of artifact attached to a task.
public enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case diff
    case testRun = "test_run"
    case proposedReply = "proposed_reply"
    case summary
    case logExcerpt = "log_excerpt"
}

/// Evidence attached to a task (diff recomputed by the app, test run report, proposed reply, …).
public struct Artifact: Codable, Sendable, Hashable, Identifiable {
    /// `art_…` (`IDGenerator.artifactID()`).
    public var id: String
    public var taskID: TaskID
    public var kind: ArtifactKind
    public var createdAt: Date
    public var title: String
    /// Bounded and redacted.
    public var content: String
    public var metadata: [String: String]
    public var reportedBy: TransitionActor

    public init(
        id: String,
        taskID: TaskID,
        kind: ArtifactKind,
        createdAt: Date,
        title: String,
        content: String,
        metadata: [String: String] = [:],
        reportedBy: TransitionActor
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.createdAt = createdAt
        self.title = title
        self.content = content
        self.metadata = metadata
        self.reportedBy = reportedBy
    }
}

/// Remote/local write actions that require explicit user approval.
public enum RemoteActionKind: String, Codable, Sendable, CaseIterable {
    case applyPatch = "apply_patch"
    case postReply = "post_reply"
    case resolveThread = "resolve_thread"
    case requestChanges = "request_changes"
    case commitAndPush = "commit_and_push"
    case merge

    public var displayName: String {
        switch self {
        case .applyPatch: "Apply patch"
        case .postReply: "Post reply"
        case .resolveThread: "Resolve thread"
        case .requestChanges: "Request changes"
        case .commitAndPush: "Commit and push"
        case .merge: "Merge"
        }
    }

    /// Provider capability needed, if the action writes to the provider API.
    public var requiredCapability: Capability? {
        switch self {
        case .postReply: .createReply
        case .resolveThread: .resolveThread
        case .requestChanges: .requestChanges
        case .merge: .merge
        case .applyPatch, .commitAndPush: nil
        }
    }
}

public enum ApprovalDecision: String, Codable, Sendable, CaseIterable {
    case approved, rejected
}

/// A locally recorded user decision on an action preview.
public struct ApprovalRecord: Codable, Sendable, Hashable {
    public var id: String
    public var taskID: TaskID
    public var action: RemoteActionKind
    public var decision: ApprovalDecision
    public var decidedAt: Date
    /// Fingerprint of the exact preview the user saw (idempotency + tamper detection).
    public var previewFingerprint: String
    public var note: String?

    public init(
        id: String,
        taskID: TaskID,
        action: RemoteActionKind,
        decision: ApprovalDecision,
        decidedAt: Date,
        previewFingerprint: String,
        note: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.action = action
        self.decision = decision
        self.decidedAt = decidedAt
        self.previewFingerprint = previewFingerprint
        self.note = note
    }
}

/// Kind of an append-only task activity entry.
public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case created, claimed, progress, heartbeat
    case changesReported = "changes_reported"
    case testsReported = "tests_reported"
    case resultSubmitted = "result_submitted"
    case failed, blocked, stale, approved, rejected
    case actionAttempted = "action_attempted"
    case actionSucceeded = "action_succeeded"
    case actionFailed = "action_failed"
    case cancelled, dismissed, retried, reopened, note
    case rejectedCall = "rejected_call"
}

/// Append-only history entry for a task.
public struct TaskActivity: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var taskID: TaskID
    public var at: Date
    public var actor: TransitionActor
    public var actorName: String?
    public var kind: ActivityKind
    public var message: String
    public var fromState: TaskState?
    public var toState: TaskState?
    public var data: [String: String]

    public init(
        id: String,
        taskID: TaskID,
        at: Date,
        actor: TransitionActor,
        actorName: String? = nil,
        kind: ActivityKind,
        message: String,
        fromState: TaskState? = nil,
        toState: TaskState? = nil,
        data: [String: String] = [:]
    ) {
        self.id = id
        self.taskID = taskID
        self.at = at
        self.actor = actor
        self.actorName = actorName
        self.kind = kind
        self.message = message
        self.fromState = fromState
        self.toState = toState
        self.data = data
    }
}
