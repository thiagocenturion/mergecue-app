import Foundation

/// How confident a checkout ↔ repository match is.
public enum MappingConfidence: String, Codable, Sendable, CaseIterable {
    /// A remote canonicalizes to the repository.
    case exact
    /// Heuristic match (e.g. same name, fork remote) — needs user confirmation.
    case probable
    /// The checkout's remotes point elsewhere.
    case mismatch
}

/// A user-confirmed (or suggested) mapping from a provider repository to a local checkout.
public struct RepoMapping: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var repo: RepoKey
    public var repoFullPath: String
    public var checkoutPath: String
    public var confidence: MappingConfidence
    public var matchedRemote: String?
    /// Set when the user confirmed the mapping.
    public var confirmedAt: Date?
    public var createdAt: Date

    public init(
        id: String,
        repo: RepoKey,
        repoFullPath: String,
        checkoutPath: String,
        confidence: MappingConfidence,
        matchedRemote: String? = nil,
        confirmedAt: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.repo = repo
        self.repoFullPath = repoFullPath
        self.checkoutPath = checkoutPath
        self.confidence = confidence
        self.matchedRemote = matchedRemote
        self.confirmedAt = confirmedAt
        self.createdAt = createdAt
    }

    public var isConfirmed: Bool { confirmedAt != nil }
}

/// A candidate checkout for a repository.
public struct MappingSuggestion: Codable, Sendable, Hashable {
    public var checkoutPath: String
    public var confidence: MappingConfidence
    public var matchedRemote: String?
    public var reason: String

    public init(checkoutPath: String, confidence: MappingConfidence, matchedRemote: String? = nil, reason: String) {
        self.checkoutPath = checkoutPath
        self.confidence = confidence
        self.matchedRemote = matchedRemote
        self.reason = reason
    }
}
