import Foundation

/// The review platform a remote object belongs to.
public enum ProviderKind: String, Codable, Sendable, CaseIterable, Hashable, CodingKeyRepresentable {
    case bitbucketCloud = "bitbucket_cloud"
    case github
    case gitlab

    /// "Bitbucket Cloud", "GitHub", "GitLab".
    public var displayName: String {
        switch self {
        case .bitbucketCloud: "Bitbucket Cloud"
        case .github: "GitHub"
        case .gitlab: "GitLab"
        }
    }

    /// "pull request" (GitHub, Bitbucket) or "merge request" (GitLab).
    public var changeRequestNoun: String {
        self == .gitlab ? "merge request" : "pull request"
    }

    /// "pull requests" / "merge requests".
    public var changeRequestNounPlural: String {
        changeRequestNoun + "s"
    }

    /// "PR" / "MR".
    public var changeRequestAbbreviation: String {
        self == .gitlab ? "MR" : "PR"
    }

    /// "#" (GitHub, Bitbucket) or "!" (GitLab).
    public var numberPrefix: String {
        self == .gitlab ? "!" : "#"
    }

    /// Human form of a change request number, e.g. "#42" or "!42".
    public func formattedNumber(_ number: Int) -> String {
        numberPrefix + String(number)
    }

    /// The hosted (SaaS) instance of this provider.
    public var defaultInstance: ProviderInstance {
        ProviderInstance.default(for: self)
    }
}

/// A concrete provider deployment (hosted service or self-managed). Its `host` is part of every identity key.
public struct ProviderInstance: Codable, Sendable, Hashable {
    public let kind: ProviderKind
    public let webURL: URL
    public let apiURL: URL

    public init(kind: ProviderKind, webURL: URL, apiURL: URL) {
        self.kind = kind
        self.webURL = webURL
        self.apiURL = apiURL
    }

    /// Lowercased web host, with a non-default port appended (`gitlab.example.com:8443`).
    public var host: String {
        let base = (webURL.host(percentEncoded: false) ?? "").lowercased()
        guard let port = webURL.port else { return base }
        switch (webURL.scheme?.lowercased(), port) {
        case ("https", 443), ("http", 80):
            return base
        default:
            return "\(base):\(port)"
        }
    }

    /// Whether this is the provider's hosted service (github.com, gitlab.com, bitbucket.org).
    public var isHostedService: Bool {
        host == Self.default(for: kind).host
    }

    /// GitHub.com — web `https://github.com`, API `https://api.github.com`.
    public static let githubCom = ProviderInstance(
        kind: .github,
        webURL: URL(staticString: "https://github.com"),
        apiURL: URL(staticString: "https://api.github.com")
    )

    /// GitLab.com — web `https://gitlab.com`, API `https://gitlab.com/api/v4`.
    public static let gitlabCom = ProviderInstance(
        kind: .gitlab,
        webURL: URL(staticString: "https://gitlab.com"),
        apiURL: URL(staticString: "https://gitlab.com/api/v4")
    )

    /// Bitbucket Cloud — web `https://bitbucket.org`, API `https://api.bitbucket.org/2.0`.
    public static let bitbucketCloud = ProviderInstance(
        kind: .bitbucketCloud,
        webURL: URL(staticString: "https://bitbucket.org"),
        apiURL: URL(staticString: "https://api.bitbucket.org/2.0")
    )

    /// The hosted instance for `kind`.
    public static func `default`(for kind: ProviderKind) -> ProviderInstance {
        switch kind {
        case .github: githubCom
        case .gitlab: gitlabCom
        case .bitbucketCloud: bitbucketCloud
        }
    }
}
