import Foundation

/// How an account authenticates with its provider.
public enum AuthMethod: String, Codable, Sendable, CaseIterable {
    case personalAccessToken
    case oauthDeviceFlow
    case githubCLIImport
    /// Atlassian API token used with the account email (HTTP Basic).
    case bitbucketAPIToken
    /// Bitbucket workspace/repository access token (Bearer).
    case bitbucketAccessToken

    public var displayName: String {
        switch self {
        case .personalAccessToken: "Personal access token"
        case .oauthDeviceFlow: "OAuth device flow"
        case .githubCLIImport: "Imported from GitHub CLI"
        case .bitbucketAPIToken: "Atlassian API token"
        case .bitbucketAccessToken: "Bitbucket access token"
        }
    }
}

/// A connected provider account. Contains no secrets (credentials live in the Keychain).
public struct Account: Codable, Sendable, Hashable, Identifiable {
    public var id: AccountKey
    public var instance: ProviderInstance
    public var username: String
    public var displayName: String?
    public var avatarURL: URL?
    public var authMethod: AuthMethod
    public var grantedScopes: [String]
    /// Remote writes (reply, resolve, request changes, merge) are disabled until the user enables them.
    public var writesEnabled: Bool
    public var label: String?
    /// Namespaces (org/group/workspace paths) to sync. Empty = all accessible.
    public var selectedNamespaces: [String]
    public var connectedAt: Date
    public var isDemo: Bool

    public init(
        id: AccountKey,
        instance: ProviderInstance,
        username: String,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        authMethod: AuthMethod,
        grantedScopes: [String] = [],
        writesEnabled: Bool = false,
        label: String? = nil,
        selectedNamespaces: [String] = [],
        connectedAt: Date,
        isDemo: Bool = false
    ) {
        self.id = id
        self.instance = instance
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.authMethod = authMethod
        self.grantedScopes = grantedScopes
        self.writesEnabled = writesEnabled
        self.label = label
        self.selectedNamespaces = selectedNamespaces
        self.connectedAt = connectedAt
        self.isDemo = isDemo
    }

    public var kind: ProviderKind { id.kind }

    /// User label if set, otherwise the username.
    public var displayLabel: String { label ?? username }
}

/// The authenticated user as reported by a provider probe.
public struct ProviderUser: Codable, Sendable, Hashable {
    public var remoteID: String
    public var username: String
    public var displayName: String?
    public var avatarURL: URL?
    public var grantedScopes: [String]
    public var email: String?

    public init(
        remoteID: String,
        username: String,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        grantedScopes: [String] = [],
        email: String? = nil
    ) {
        self.remoteID = remoteID
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.grantedScopes = grantedScopes
        self.email = email
    }
}
