import Foundation

/// Lifecycle state of a change request.
public enum ChangeRequestState: String, Codable, Sendable, CaseIterable {
    case open
    case merged
    /// Closed without merge.
    case closed
}

/// Why a change request is relevant to the current user.
public enum Involvement: String, Codable, Sendable, CaseIterable {
    case authored
    case reviewRequested = "review_requested"
    case assigned
    case mentioned
    case participated
}

/// Lightweight list-level view of a change request.
public struct ChangeRequestSummary: Codable, Sendable, Hashable, Identifiable {
    public var key: ChangeRequestKey
    public var repository: Repository
    public var title: String
    public var author: Person
    public var state: ChangeRequestState
    public var isDraft: Bool
    public var sourceBranch: String
    public var targetBranch: String
    public var headSHA: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var webURL: URL
    public var involvement: Set<Involvement>
    /// Cheap change detector (provider `updated_at`, ETag, …).
    public var versionToken: String?

    public init(
        key: ChangeRequestKey,
        repository: Repository,
        title: String,
        author: Person,
        state: ChangeRequestState = .open,
        isDraft: Bool = false,
        sourceBranch: String,
        targetBranch: String,
        headSHA: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        webURL: URL,
        involvement: Set<Involvement> = [],
        versionToken: String? = nil
    ) {
        self.key = key
        self.repository = repository
        self.title = title
        self.author = author
        self.state = state
        self.isDraft = isDraft
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.headSHA = headSHA
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.webURL = webURL
        self.involvement = involvement
        self.versionToken = versionToken
    }

    public var id: String { key.id }
    public var providerKind: ProviderKind { key.kind }

    /// Provider-qualified human reference (`github:github.com/acme/api#42`).
    public var ref: ChangeRequestRef {
        ChangeRequestRef(
            kind: key.kind,
            host: key.repo.account.host,
            repoFullPath: repository.fullPath,
            number: key.number
        )
    }

    /// "#42" / "!42".
    public var displayNumber: String { key.kind.formattedNumber(key.number) }
}

/// Fresh head state fetched right before a remote write.
public struct HeadInfo: Codable, Sendable, Hashable {
    public var headSHA: String?
    public var state: ChangeRequestState
    public var isDraft: Bool
    public var updatedAt: Date

    public init(headSHA: String?, state: ChangeRequestState, isDraft: Bool, updatedAt: Date) {
        self.headSHA = headSHA
        self.state = state
        self.isDraft = isDraft
        self.updatedAt = updatedAt
    }
}

/// One page (the complete result) of a change request listing.
public struct ChangeRequestPage: Codable, Sendable, Hashable {
    public var items: [ChangeRequestSummary]
    /// True when a conditional request reported no change; `items` is then empty and the caller keeps its data.
    public var notModified: Bool

    public init(items: [ChangeRequestSummary], notModified: Bool = false) {
        self.items = items
        self.notModified = notModified
    }

    public static let unchanged = ChangeRequestPage(items: [], notModified: true)
}

/// Which listing to request from a provider.
public enum ChangeRequestScope: String, Codable, Sendable, CaseIterable {
    case authored
    case reviewRequested = "review_requested"

    public var involvement: Involvement {
        switch self {
        case .authored: .authored
        case .reviewRequested: .reviewRequested
        }
    }
}

/// Parameters for `ReviewProvider.listChangeRequests`.
public struct ChangeRequestQuery: Codable, Sendable, Hashable {
    public var scope: ChangeRequestScope
    /// Namespace paths to restrict to. Empty = all accessible.
    public var namespaces: [String]
    /// Repositories to query individually (required for Bitbucket reviewer listings).
    public var repositories: [Repository]
    public var updatedSince: Date?

    public init(scope: ChangeRequestScope, namespaces: [String] = [], repositories: [Repository] = [], updatedSince: Date? = nil) {
        self.scope = scope
        self.namespaces = namespaces
        self.repositories = repositories
        self.updatedSince = updatedSince
    }
}
