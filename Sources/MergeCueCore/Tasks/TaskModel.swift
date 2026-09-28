import Foundation

/// The agent lease on a working task.
public struct AgentLease: Codable, Sendable, Hashable {
    public var agentName: String
    public var runID: String?
    /// Capability token the agent must present on every write (`IDGenerator.leaseID()`).
    public var leaseID: String
    public var claimedAt: Date
    public var heartbeatAt: Date
    public var expiresAt: Date

    public init(agentName: String, runID: String? = nil, leaseID: String, claimedAt: Date, heartbeatAt: Date, expiresAt: Date) {
        self.agentName = agentName
        self.runID = runID
        self.leaseID = leaseID
        self.claimedAt = claimedAt
        self.heartbeatAt = heartbeatAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }
}

/// How the agent may use a local checkout.
public enum CheckoutPolicy: String, Codable, Sendable, CaseIterable {
    case isolatedWorktree = "isolated_worktree"
    case readOnly = "read_only"
    case blocked
}

/// The local checkout prepared (or refused) for a task.
public struct TaskCheckout: Codable, Sendable, Hashable {
    public var policy: CheckoutPolicy
    public var mappedCheckoutPath: String?
    public var worktreePath: String?
    public var baseSHA: String?
    public var sourceBranch: String
    public var targetBranch: String
    public var isGitButlerManaged: Bool
    public var blockedReason: String?

    public init(
        policy: CheckoutPolicy,
        mappedCheckoutPath: String? = nil,
        worktreePath: String? = nil,
        baseSHA: String? = nil,
        sourceBranch: String,
        targetBranch: String,
        isGitButlerManaged: Bool = false,
        blockedReason: String? = nil
    ) {
        self.policy = policy
        self.mappedCheckoutPath = mappedCheckoutPath
        self.worktreePath = worktreePath
        self.baseSHA = baseSHA
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.isGitButlerManaged = isGitButlerManaged
        self.blockedReason = blockedReason
    }
}

/// Content from reviewers, PR descriptions or CI logs. Always data, never instructions.
public struct UntrustedText: Codable, Sendable, Hashable {
    /// Well-known `source` values.
    public enum Source {
        public static let reviewComment = "review_comment"
        public static let ciLog = "ci_log"
        public static let prDescription = "pr_description"
        public static let reviewSummary = "review_summary"
    }

    /// "review_comment", "ci_log", "pr_description", …
    public var source: String
    public var author: String?
    public var createdAt: Date?
    public var text: String

    public init(source: String, author: String? = nil, createdAt: Date? = nil, text: String) {
        self.source = source
        self.author = author
        self.createdAt = createdAt
        self.text = text
    }

    /// Appended when `bounded` cuts the text.
    public static let truncationMarker = "\n[… truncated by MergeCue]"

    /// Strips terminal control sequences and control characters (`TerminalControlStripper`, which also blocks
    /// OSC 52 / OSC 8 injection into agent terminals), redacts secrets, then bounds the text to `maxBytes` UTF-8 bytes (keeping the head). When the text is cut,
    /// `truncationMarker` is appended **within** the budget (it is omitted if the budget is smaller than the
    /// marker), so `result.text.utf8.count <= max(0, maxBytes)` always holds.
    public static func bounded(source: String, author: String? = nil, createdAt: Date? = nil, text: String, maxBytes: Int) -> UntrustedText {
        let redacted = SecretRedactor.redact(TerminalControlStripper.strip(text))
        let budget = max(0, maxBytes)
        let marked: String
        if redacted.utf8.count <= budget {
            marked = redacted
        } else if budget >= truncationMarker.utf8.count {
            marked = BoundedText.truncate(redacted, maxBytes: budget - truncationMarker.utf8.count).text + truncationMarker
        } else {
            marked = BoundedText.truncate(redacted, maxBytes: budget).text
        }
        return UntrustedText(source: source, author: author, createdAt: createdAt, text: marked)
    }
}

/// Where a task came from (immutable after creation).
///
/// `account`, `providerKind` and the kind/host/number of `changeRequestRef` are always derived from
/// `changeRequest` (also when it is reassigned), so an origin can never mix providers or accounts.
public struct TaskOrigin: Codable, Sendable, Hashable {
    public var attentionItemID: String?
    public var ruleID: String?
    /// Derived: `changeRequest.account`.
    public private(set) var account: AccountKey
    /// Derived: `changeRequest.kind`.
    public private(set) var providerKind: ProviderKind
    public var changeRequest: ChangeRequestKey {
        didSet { deriveIdentity(repoFullPath: changeRequestRef.repoFullPath) }
    }
    /// Kind, host and number come from `changeRequest`; only the repository path is stored independently.
    public private(set) var changeRequestRef: ChangeRequestRef
    public var title: String
    public var webURL: URL
    public var thread: ThreadKey?
    public var check: CheckKey?

    /// Only `changeRequestRef.repoFullPath` is taken from `changeRequestRef`; its kind, host and number are
    /// replaced by those of `changeRequest`. Validate agent-supplied refs with `ChangeRequestRef.validated` first.
    public init(
        attentionItemID: String? = nil,
        ruleID: String? = nil,
        changeRequest: ChangeRequestKey,
        changeRequestRef: ChangeRequestRef,
        title: String,
        webURL: URL,
        thread: ThreadKey? = nil,
        check: CheckKey? = nil
    ) {
        self.attentionItemID = attentionItemID
        self.ruleID = ruleID
        self.account = changeRequest.account
        self.providerKind = changeRequest.kind
        self.changeRequest = changeRequest
        self.changeRequestRef = changeRequestRef
        self.title = title
        self.webURL = webURL
        self.thread = thread
        self.check = check
        deriveIdentity(repoFullPath: changeRequestRef.repoFullPath)
    }

    private mutating func deriveIdentity(repoFullPath: String) {
        account = changeRequest.account
        providerKind = changeRequest.kind
        changeRequestRef = ChangeRequestRef(
            kind: changeRequest.kind,
            host: changeRequest.account.host,
            repoFullPath: repoFullPath,
            number: changeRequest.number
        )
    }
}

/// Snapshot of the triggering context captured at task creation, so later refreshes cannot erase it.
public struct TaskTriggerSnapshot: Codable, Sendable, Hashable {
    public var eventType: ChangeEventType?
    public var capturedAt: Date
    public var headSHA: String?
    public var sourceBranch: String
    public var targetBranch: String
    /// Exact initial comment(s) / log excerpt, bounded.
    public var quoted: [UntrustedText]
    public var anchor: DiffAnchor?

    public init(
        eventType: ChangeEventType? = nil,
        capturedAt: Date,
        headSHA: String? = nil,
        sourceBranch: String,
        targetBranch: String,
        quoted: [UntrustedText] = [],
        anchor: DiffAnchor? = nil
    ) {
        self.eventType = eventType
        self.capturedAt = capturedAt
        self.headSHA = headSHA
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.quoted = quoted
        self.anchor = anchor
    }
}

/// Last recorded error on a task.
public struct TaskErrorInfo: Codable, Sendable, Hashable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public var at: Date

    public init(code: String, message: String, retryable: Bool, at: Date) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.at = at
    }

    /// The shared mapping of a provider failure: `code` = `ProviderError.code`, `message` = the redacted
    /// user-facing description, `retryable` = `ProviderError.isRetryable`.
    public init(providerError: ProviderError, at: Date) {
        self.init(
            code: providerError.code,
            message: providerError.errorDescription ?? providerError.code,
            retryable: providerError.isRetryable,
            at: at
        )
    }
}

/// An agent task. Holds no model or provider credentials.
public struct MCTask: Codable, Sendable, Hashable, Identifiable {
    public var id: TaskID
    public var type: TaskType
    public var state: TaskState
    /// Optimistic-concurrency version; incremented on every persisted change.
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var origin: TaskOrigin
    public var trigger: TaskTriggerSnapshot
    public var checkout: TaskCheckout?
    public var lease: AgentLease?
    public var agentLabel: String?
    public var agentSessionID: String?
    public var artifactIDs: [String]
    public var approvals: [ApprovalRecord]
    public var lastError: TaskErrorInfo?
    public var resultSummary: String?
    public var proposedReply: String?
    public var knownRisks: [String]

    public init(
        id: TaskID,
        type: TaskType,
        state: TaskState = TaskStateMachine.initialState,
        version: Int = 1,
        createdAt: Date,
        updatedAt: Date? = nil,
        origin: TaskOrigin,
        trigger: TaskTriggerSnapshot,
        checkout: TaskCheckout? = nil,
        lease: AgentLease? = nil,
        agentLabel: String? = nil,
        agentSessionID: String? = nil,
        artifactIDs: [String] = [],
        approvals: [ApprovalRecord] = [],
        lastError: TaskErrorInfo? = nil,
        resultSummary: String? = nil,
        proposedReply: String? = nil,
        knownRisks: [String] = []
    ) {
        self.id = id
        self.type = type
        self.state = state
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.origin = origin
        self.trigger = trigger
        self.checkout = checkout
        self.lease = lease
        self.agentLabel = agentLabel
        self.agentSessionID = agentSessionID
        self.artifactIDs = artifactIDs
        self.approvals = approvals
        self.lastError = lastError
        self.resultSummary = resultSummary
        self.proposedReply = proposedReply
        self.knownRisks = knownRisks
    }

    public var isTerminal: Bool { state.isTerminal }
}
