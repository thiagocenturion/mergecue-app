import Foundation

/// What an agent task asks for.
public enum TaskType: String, Codable, Sendable, CaseIterable {
    case fixReview = "fix_review"
    case addressSuggestion = "address_suggestion"
    case draftReply = "draft_reply"
    case investigateCI = "investigate_ci"

    public var displayName: String {
        switch self {
        case .fixReview: "Fix review feedback"
        case .addressSuggestion: "Address code suggestion"
        case .draftReply: "Draft reply"
        case .investigateCI: "Investigate CI failure"
        }
    }

    /// Whether the task is expected to change code (needs a diff artifact or an explicit no-changes reason).
    public var isCodeTask: Bool {
        self != .draftReply
    }

    /// Default task type for an attention reason (the user may override). nil = no sensible agent task.
    public static func inferred(from reason: AttentionReason) -> TaskType? {
        switch reason {
        case .reviewComment, .changesRequested: .fixReview
        case .codeSuggestion: .addressSuggestion
        case .reviewerQuestion, .reply: .draftReply
        case .ciFailed: .investigateCI
        case .reviewRequested, .readyToMerge, .mergeConflict: nil
        }
    }
}

/// Task lifecycle state. See `TaskStateMachine` for the transition table.
public enum TaskState: String, Codable, Sendable, CaseIterable {
    case waitingForAgent = "waiting_for_agent"
    case working
    case readyForReview = "ready_for_review"
    case approvedAction = "approved_action"
    case done, blocked, failed, cancelled, stale, dismissed

    /// `done`, `cancelled` and `dismissed`: only a user `reopen` leaves them.
    public var isTerminal: Bool {
        switch self {
        case .done, .cancelled, .dismissed: true
        default: false
        }
    }

    public var displayName: String {
        switch self {
        case .waitingForAgent: "Waiting for agent"
        case .working: "Working"
        case .readyForReview: "Ready for review"
        case .approvedAction: "Approved action"
        case .done: "Done"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .stale: "Stale"
        case .dismissed: "Dismissed"
        }
    }

    /// Non-terminal states.
    public static let active: Set<TaskState> = Set(allCases.filter { !$0.isTerminal })
}

/// Who requests a transition.
public enum TransitionActor: String, Codable, Sendable, CaseIterable {
    case agent, user, system
}

/// Inputs to `TaskStateMachine`.
public enum TaskTrigger: Codable, Sendable, Hashable {
    // Agent (via MCP)
    case claim, heartbeat, progress, reportChanges, reportTests, submitResult
    case fail(retryable: Bool)
    case agentBlocked
    // System
    case leaseExpired
    // User review gate and system action outcomes
    case approveAction(RemoteActionKind)
    case rejectResult
    /// System: the approved remote action succeeded and more actions remain → back to `ready_for_review`.
    case actionSucceeded
    case actionBlocked, actionFailed
    /// User from `ready_for_review` (no remote action) or system from `approved_action` (final action succeeded).
    case markDone
    // Lifecycle
    case cancel, dismiss, retry, reopen, block, unblock

    /// Every concrete trigger value, including each associated-value variant (for exhaustive tables/tests).
    public static let allTriggers: [TaskTrigger] =
        [.claim, .heartbeat, .progress, .reportChanges, .reportTests, .submitResult,
         .fail(retryable: true), .fail(retryable: false), .agentBlocked, .leaseExpired]
        + RemoteActionKind.allCases.map { .approveAction($0) }
        + [.rejectResult, .actionSucceeded, .actionBlocked, .actionFailed, .markDone,
           .cancel, .dismiss, .retry, .reopen, .block, .unblock]

    /// Stable snake_case name (JSON `type`).
    public var name: String {
        switch self {
        case .claim: "claim"
        case .heartbeat: "heartbeat"
        case .progress: "progress"
        case .reportChanges: "report_changes"
        case .reportTests: "report_tests"
        case .submitResult: "submit_result"
        case .fail: "fail"
        case .agentBlocked: "agent_blocked"
        case .leaseExpired: "lease_expired"
        case .approveAction: "approve_action"
        case .rejectResult: "reject_result"
        case .actionSucceeded: "action_succeeded"
        case .actionBlocked: "action_blocked"
        case .actionFailed: "action_failed"
        case .markDone: "mark_done"
        case .cancel: "cancel"
        case .dismiss: "dismiss"
        case .retry: "retry"
        case .reopen: "reopen"
        case .block: "block"
        case .unblock: "unblock"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, retryable, action
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .type)
        switch name {
        case "fail":
            self = .fail(retryable: try container.decode(Bool.self, forKey: .retryable))
        case "approve_action":
            self = .approveAction(try container.decode(RemoteActionKind.self, forKey: .action))
        default:
            guard let simple = Self.allTriggers.first(where: { $0.name == name }) else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown trigger \(name)")
            }
            self = simple
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .type)
        switch self {
        case .fail(let retryable): try container.encode(retryable, forKey: .retryable)
        case .approveAction(let kind): try container.encode(kind, forKey: .action)
        default: break
        }
    }
}
