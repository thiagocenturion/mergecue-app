import Foundation

/// Normalized, provider-neutral change event types.
public enum ChangeEventType: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case reviewComment = "review_comment"
    case changeRequested = "change_requested"
    case reply
    case ciFailed = "ci_failed"
    case ciRecovered = "ci_recovered"
    case approval
    case readyToMerge = "ready_to_merge"
    case merged
    case closedWithoutMerge = "closed_without_merge"
    case reviewRequested = "review_requested"
    case headChanged = "head_changed"
    case threadResolved = "thread_resolved"

    public var displayName: String {
        switch self {
        case .reviewComment: "Review comment"
        case .changeRequested: "Changes requested"
        case .reply: "Reply"
        case .ciFailed: "CI failed"
        case .ciRecovered: "CI recovered"
        case .approval: "Approval"
        case .readyToMerge: "Ready to merge"
        case .merged: "Merged"
        case .closedWithoutMerge: "Closed without merge"
        case .reviewRequested: "Review requested"
        case .headChanged: "New commits"
        case .threadResolved: "Thread resolved"
        }
    }
}

/// A detected change on a change request. Identity (`id`) is the dedupe key across polls and relaunches.
public struct ChangeEvent: Codable, Sendable, Hashable, Identifiable {
    /// `ChangeEvent.makeID(account:changeRequest:type:objectID:objectVersion:)`.
    public var id: String
    public var type: ChangeEventType
    public var account: AccountKey
    public var changeRequest: ChangeRequestKey
    public var providerKind: ProviderKind
    public var repoFullPath: String
    public var number: Int
    public var title: String
    /// Id of the object that changed (comment id, check id, review id, head SHA, …).
    public var objectID: String
    /// Version of that object (updated_at, status, attempt, …) so a genuinely new state yields a new event.
    public var objectVersion: String
    public var occurredAt: Date
    public var detectedAt: Date
    public var actor: Person?
    public var isFromCurrentUser: Bool
    /// True for events recorded during an account's first (baseline) sync — never notified.
    public var isBaseline: Bool
    public var thread: ThreadKey?
    public var commentID: String?
    public var check: CheckKey?
    /// Classification of the triggering comment, when the event carries one (question/suggestion/…).
    public var commentKind: CommentKind?
    /// Short text, may quote untrusted content — display only.
    public var summary: String
    public var nativeRefs: [String: String]

    public init(
        id: String? = nil,
        type: ChangeEventType,
        account: AccountKey,
        changeRequest: ChangeRequestKey,
        providerKind: ProviderKind? = nil,
        repoFullPath: String,
        number: Int? = nil,
        title: String,
        objectID: String,
        objectVersion: String,
        occurredAt: Date,
        detectedAt: Date,
        actor: Person? = nil,
        isFromCurrentUser: Bool = false,
        isBaseline: Bool = false,
        thread: ThreadKey? = nil,
        commentID: String? = nil,
        check: CheckKey? = nil,
        commentKind: CommentKind? = nil,
        summary: String,
        nativeRefs: [String: String] = [:]
    ) {
        self.id = id ?? Self.makeID(
            account: account, changeRequest: changeRequest, type: type, objectID: objectID, objectVersion: objectVersion
        )
        self.type = type
        self.account = account
        self.changeRequest = changeRequest
        self.providerKind = providerKind ?? changeRequest.kind
        self.repoFullPath = repoFullPath
        self.number = number ?? changeRequest.number
        self.title = title
        self.objectID = objectID
        self.objectVersion = objectVersion
        self.occurredAt = occurredAt
        self.detectedAt = detectedAt
        self.actor = actor
        self.isFromCurrentUser = isFromCurrentUser
        self.isBaseline = isBaseline
        self.thread = thread
        self.commentID = commentID
        self.check = check
        self.commentKind = commentKind
        self.summary = summary
        self.nativeRefs = nativeRefs
    }

    /// Stable event identity: `evt_` + 32 hex of SHA-256 over (account, change request, type, object, version).
    public static func makeID(
        account: AccountKey,
        changeRequest: ChangeRequestKey,
        type: ChangeEventType,
        objectID: String,
        objectVersion: String
    ) -> String {
        let material = [
            StableID.version,
            account.id,
            changeRequest.id,
            type.rawValue,
            StableID.encode(objectID),
            StableID.encode(objectVersion),
        ].joined(separator: "\n")
        return "evt_" + ContentDigest.sha256Hex(material).prefix(32)
    }

    /// Provider-qualified reference, e.g. `gitlab:gitlab.com/acme/api!42`.
    public var changeRequestRef: ChangeRequestRef {
        ChangeRequestRef(kind: providerKind, host: account.host, repoFullPath: repoFullPath, number: number)
    }
}
