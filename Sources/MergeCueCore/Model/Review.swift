import Foundation

/// State of a submitted review or of a reviewer's current verdict.
public enum ReviewState: String, Codable, Sendable, CaseIterable {
    case approved
    case changesRequested = "changes_requested"
    case commented
    case pending
    case dismissed
}

/// A submitted review.
public struct Review: Codable, Sendable, Hashable {
    public var remoteID: String
    public var author: Person
    public var state: ReviewState
    public var submittedAt: Date?
    /// Untrusted text.
    public var body: String?
    public var commitSHA: String?

    public init(remoteID: String, author: Person, state: ReviewState, submittedAt: Date? = nil, body: String? = nil, commitSHA: String? = nil) {
        self.remoteID = remoteID
        self.author = author
        self.state = state
        self.submittedAt = submittedAt
        self.body = body
        self.commitSHA = commitSHA
    }
}

/// A requested or participating reviewer and their latest verdict.
public struct Reviewer: Codable, Sendable, Hashable {
    public var person: Person
    public var state: ReviewState
    /// nil = provider does not expose required reviewers.
    public var isRequired: Bool?

    public init(person: Person, state: ReviewState, isRequired: Bool? = nil) {
        self.person = person
        self.state = state
        self.isRequired = isRequired
    }
}

/// Approval summary.
public struct ApprovalStatus: Codable, Sendable, Hashable {
    public var approvedBy: [Person]
    public var requiredCount: Int?
    /// nil = unknown (provider rules could not be evaluated).
    public var isSatisfied: Bool?

    public init(approvedBy: [Person] = [], requiredCount: Int? = nil, isSatisfied: Bool? = nil) {
        self.approvedBy = approvedBy
        self.requiredCount = requiredCount
        self.isSatisfied = isSatisfied
    }

    public static let unknown = ApprovalStatus()
}
