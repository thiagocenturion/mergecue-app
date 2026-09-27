import Foundation

/// A commit on the change request.
public struct CommitInfo: Codable, Sendable, Hashable {
    public var sha: String
    public var title: String
    public var author: String?
    public var authoredAt: Date?

    public init(sha: String, title: String, author: String? = nil, authoredAt: Date? = nil) {
        self.sha = sha
        self.title = title
        self.author = author
        self.authoredAt = authoredAt
    }
}

/// How a file changed.
public enum FileChangeStatus: String, Codable, Sendable, CaseIterable {
    case added, modified, removed, renamed, copied, unknown
}

/// A changed file with optional line statistics.
public struct ChangedFile: Codable, Sendable, Hashable {
    public var path: String
    public var oldPath: String?
    public var status: FileChangeStatus
    public var additions: Int?
    public var deletions: Int?

    public init(path: String, oldPath: String? = nil, status: FileChangeStatus, additions: Int? = nil, deletions: Int? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

/// The repository holding the source branch (differs from the target for forks / cross-project MRs).
public struct SourceRepositoryInfo: Codable, Sendable, Hashable {
    public var fullPath: String
    public var cloneURLs: [String]
    public var remoteID: String?
    public var isFork: Bool

    public init(fullPath: String, cloneURLs: [String] = [], remoteID: String? = nil, isFork: Bool = false) {
        self.fullPath = fullPath
        self.cloneURLs = cloneURLs
        self.remoteID = remoteID
        self.isFork = isFork
    }
}

/// Fully hydrated change request state at `fetchedAt`.
public struct ChangeRequestSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var summary: ChangeRequestSummary
    /// Untrusted PR/MR description.
    public var description: String?
    public var source: SourceRepositoryInfo?
    public var baseSHA: String?
    public var reviewers: [Reviewer]
    public var reviews: [Review]
    public var approvals: ApprovalStatus
    public var threads: [ReviewThread]
    public var checks: [CheckRun]
    public var aggregateCheckState: AggregateCheckState
    public var commits: [CommitInfo]
    public var changedFiles: [ChangedFile]
    public var readiness: MergeReadiness
    public var fetchedAt: Date
    /// Provider API URLs / ids for traceability.
    public var nativeRefs: [String: String]

    public init(
        summary: ChangeRequestSummary,
        description: String? = nil,
        source: SourceRepositoryInfo? = nil,
        baseSHA: String? = nil,
        reviewers: [Reviewer] = [],
        reviews: [Review] = [],
        approvals: ApprovalStatus = .unknown,
        threads: [ReviewThread] = [],
        checks: [CheckRun] = [],
        aggregateCheckState: AggregateCheckState? = nil,
        commits: [CommitInfo] = [],
        changedFiles: [ChangedFile] = [],
        readiness: MergeReadiness = .unknown,
        fetchedAt: Date,
        nativeRefs: [String: String] = [:]
    ) {
        self.summary = summary
        self.description = description
        self.source = source
        self.baseSHA = baseSHA
        self.reviewers = reviewers
        self.reviews = reviews
        self.approvals = approvals
        self.threads = threads
        self.checks = checks
        self.aggregateCheckState = aggregateCheckState ?? AggregateCheckState.aggregate(checks)
        self.commits = commits
        self.changedFiles = changedFiles
        self.readiness = readiness
        self.fetchedAt = fetchedAt
        self.nativeRefs = nativeRefs
    }

    public var id: String { summary.key.id }
    public var key: ChangeRequestKey { summary.key }

    /// Threads the provider reports as unresolved (`isResolved == false`), including outdated ones.
    public var unresolvedThreadCount: Int {
        threads.lazy.filter(\.isUnresolved).count
    }

    public func thread(_ key: ThreadKey) -> ReviewThread? {
        threads.first { $0.key == key }
    }

    public func check(_ key: CheckKey) -> CheckRun? {
        checks.first { $0.key == key }
    }
}
