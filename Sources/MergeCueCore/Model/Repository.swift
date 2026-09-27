import Foundation

/// A provider user as it appears on remote objects (author, reviewer, actor).
public struct Person: Codable, Sendable, Hashable {
    /// Immutable provider id. Sync compares it with `Account.id.remoteUserID` to decide "is it me".
    public var remoteID: String
    public var username: String
    public var displayName: String?
    public var avatarURL: URL?
    public var isBot: Bool

    public init(remoteID: String, username: String, displayName: String? = nil, avatarURL: URL? = nil, isBot: Bool = false) {
        self.remoteID = remoteID
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.isBot = isBot
    }

    /// Display name if known, otherwise the username.
    public var displayLabel: String { displayName ?? username }
}

/// An organization, group, workspace or user namespace that owns repositories.
public struct Namespace: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case user, organization, group, workspace
    }

    public var id: String
    public var path: String
    public var displayName: String
    public var kind: Kind

    public init(id: String, path: String, displayName: String, kind: Kind) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.kind = kind
    }
}

/// A repository (GitHub repo, GitLab project, Bitbucket repository).
public struct Repository: Codable, Sendable, Hashable, Identifiable {
    public var key: RepoKey
    public var namespacePath: String
    public var name: String
    /// "acme/payments-api"; GitLab paths may be nested ("group/sub/project").
    public var fullPath: String
    public var webURL: URL
    /// HTTPS and SSH clone URLs.
    public var cloneURLs: [String]
    public var defaultBranch: String?
    public var isPrivate: Bool

    public init(
        key: RepoKey,
        namespacePath: String,
        name: String,
        fullPath: String,
        webURL: URL,
        cloneURLs: [String] = [],
        defaultBranch: String? = nil,
        isPrivate: Bool = true
    ) {
        self.key = key
        self.namespacePath = namespacePath
        self.name = name
        self.fullPath = fullPath
        self.webURL = webURL
        self.cloneURLs = cloneURLs
        self.defaultBranch = defaultBranch
        self.isPrivate = isPrivate
    }

    public var id: String { key.id }
    public var providerKind: ProviderKind { key.kind }
}
