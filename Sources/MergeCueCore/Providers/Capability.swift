import Foundation

/// A provider feature MergeCue may use. Every adapter declares each one explicitly in its manifest.
public enum Capability: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case listAuthored, listReviewRequested, readThreads, resolveThread, readChecks, readFailureLog
    case requestChanges, createReply, merge, fetchHead, deepLink
    /// Open change requests of others the user reviewed or commented on (`ChangeRequestScope.involved`). Additive:
    /// providers without it are simply not asked.
    case listInvolved

    /// Whether the capability writes to the provider (requires `Account.writesEnabled` + approval).
    public var isWrite: Bool {
        switch self {
        case .resolveThread, .requestChanges, .createReply, .merge: true
        default: false
        }
    }

    public var displayName: String {
        switch self {
        case .listAuthored: "List my change requests"
        case .listReviewRequested: "List review requests"
        case .readThreads: "Read review threads"
        case .resolveThread: "Resolve threads"
        case .readChecks: "Read CI checks"
        case .readFailureLog: "Read CI failure logs"
        case .requestChanges: "Request changes"
        case .createReply: "Reply to threads"
        case .merge: "Merge"
        case .fetchHead: "Fetch head for local checkout"
        case .deepLink: "Deep links"
        case .listInvolved: "List change requests you reviewed or commented on"
        }
    }
}

/// How well a provider supports a capability.
public enum CapabilitySupport: Codable, Sendable, Hashable {
    case supported
    case requiresWriteAccess(scope: String)
    case partial(note: String)
    case unsupported(reason: String)

    /// `supported` and `partial` can be used as-is; the others need user action or are unavailable.
    public var isUsable: Bool {
        switch self {
        case .supported, .partial: true
        case .requiresWriteAccess, .unsupported: false
        }
    }

    public var userFacingDescription: String {
        switch self {
        case .supported: "Supported"
        case .requiresWriteAccess(let scope): "Requires write access (\(scope))"
        case .partial(let note): "Partially supported: \(note)"
        case .unsupported(let reason): "Unsupported: \(reason)"
        }
    }

    /// Stable machine name used as the JSON `type`.
    public var name: String {
        switch self {
        case .supported: "supported"
        case .requiresWriteAccess: "requires_write_access"
        case .partial: "partial"
        case .unsupported: "unsupported"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, scope, note, reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "supported": self = .supported
        case "requires_write_access": self = .requiresWriteAccess(scope: try container.decode(String.self, forKey: .scope))
        case "partial": self = .partial(note: try container.decode(String.self, forKey: .note))
        case "unsupported": self = .unsupported(reason: try container.decode(String.self, forKey: .reason))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown support \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .type)
        switch self {
        case .supported: break
        case .requiresWriteAccess(let scope): try container.encode(scope, forKey: .scope)
        case .partial(let note): try container.encode(note, forKey: .note)
        case .unsupported(let reason): try container.encode(reason, forKey: .reason)
        }
    }
}

/// An adapter's explicit, versioned declaration of what it supports.
public struct CapabilityManifest: Codable, Sendable, Hashable {
    public var provider: ProviderKind
    public var manifestVersion: Int
    public var entries: [Capability: CapabilitySupport]

    public init(provider: ProviderKind, manifestVersion: Int = 1, entries: [Capability: CapabilitySupport]) {
        self.provider = provider
        self.manifestVersion = manifestVersion
        self.entries = entries
    }

    /// Declared support; a capability missing from the manifest is `.unsupported`.
    public func support(for capability: Capability) -> CapabilitySupport {
        entries[capability] ?? .unsupported(reason: "Not declared by the \(provider.displayName) adapter")
    }

    public func isUsable(_ capability: Capability) -> Bool {
        support(for: capability).isUsable
    }

    /// Capabilities with no manifest entry (adapters should declare every capability).
    public var undeclared: [Capability] {
        Capability.allCases.filter { entries[$0] == nil }
    }
}
