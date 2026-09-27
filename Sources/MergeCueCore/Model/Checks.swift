import Foundation

/// Normalized CI check status.
public enum CheckStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case inProgress = "in_progress"
    case success, failure, cancelled, skipped, neutral
    case timedOut = "timed_out"
    case actionRequired = "action_required"
    case stale, unknown

    /// Failure states that deserve attention: `failure`, `timed_out`, `action_required`.
    /// `cancelled` is deliberately not failing (usually a superseded run).
    public var isFailing: Bool {
        switch self {
        case .failure, .timedOut, .actionRequired: true
        default: false
        }
    }

    /// The check finished (successfully or not). `queued`, `in_progress` and `unknown` are not terminal.
    public var isTerminal: Bool {
        switch self {
        case .queued, .inProgress, .unknown: false
        default: true
        }
    }

    /// Finished without blocking: `success`, `skipped`, `neutral`.
    public var isPassing: Bool {
        switch self {
        case .success, .skipped, .neutral: true
        default: false
        }
    }

    /// Still running or waiting.
    public var isPending: Bool {
        self == .queued || self == .inProgress
    }

    public var displayName: String {
        switch self {
        case .queued: "Queued"
        case .inProgress: "In progress"
        case .success: "Passed"
        case .failure: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .neutral: "Neutral"
        case .timedOut: "Timed out"
        case .actionRequired: "Action required"
        case .stale: "Stale"
        case .unknown: "Unknown"
        }
    }
}

/// A CI check run, status context, job or pipeline step.
public struct CheckRun: Codable, Sendable, Hashable, Identifiable {
    public var key: CheckKey
    public var name: String
    public var status: CheckStatus
    /// nil = provider does not say whether the check is required.
    public var isRequired: Bool?
    public var startedAt: Date?
    public var completedAt: Date?
    public var detailsURL: URL?
    public var commitSHA: String?
    public var attempt: Int?
    /// Untrusted provider summary.
    public var summary: String?
    /// Opaque adapter-specific locator for the failure log (job id, pipeline + step uuid, …).
    public var logLocator: [String: String]

    public init(
        key: CheckKey,
        name: String,
        status: CheckStatus,
        isRequired: Bool? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        detailsURL: URL? = nil,
        commitSHA: String? = nil,
        attempt: Int? = nil,
        summary: String? = nil,
        logLocator: [String: String] = [:]
    ) {
        self.key = key
        self.name = name
        self.status = status
        self.isRequired = isRequired
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.detailsURL = detailsURL
        self.commitSHA = commitSHA
        self.attempt = attempt
        self.summary = summary
        self.logLocator = logLocator
    }

    public var id: String { key.id }
}

/// Aggregate CI state for a change request head.
public enum AggregateCheckState: String, Codable, Sendable, CaseIterable {
    case none, pending, passing, failing

    /// Shared aggregation rule: no checks → `none`; any failing → `failing`; any queued/in-progress/unknown →
    /// `pending`; otherwise `passing` (`cancelled` and `stale` checks are ignored unless nothing else exists).
    public static func aggregate(_ checks: [CheckRun]) -> AggregateCheckState {
        guard !checks.isEmpty else { return .none }
        if checks.contains(where: { $0.status.isFailing }) { return .failing }
        if checks.contains(where: { $0.status.isPending || $0.status == .unknown }) { return .pending }
        if checks.contains(where: { $0.status.isPassing }) { return .passing }
        // Only cancelled/stale checks: nothing proves the head is green.
        return .pending
    }
}

/// Whether a change request can be merged, claimed only when provider rules were actually checked.
public enum MergeReadiness: Codable, Sendable, Hashable {
    /// Provider approvals/rules satisfied, no unresolved threads, checks green on the current head.
    case readyToMerge
    /// Checks pass but readiness could not be fully confirmed.
    case checksGreen
    case blocked(reasons: [String])
    case unknown

    /// Stable machine name used as the JSON `type`.
    public var name: String {
        switch self {
        case .readyToMerge: "ready_to_merge"
        case .checksGreen: "checks_green"
        case .blocked: "blocked"
        case .unknown: "unknown"
        }
    }

    public var displayText: String {
        switch self {
        case .readyToMerge: "Ready to merge"
        case .checksGreen: "Checks green"
        case .blocked(let reasons): reasons.isEmpty ? "Blocked" : "Blocked: " + reasons.joined(separator: "; ")
        case .unknown: "Unknown"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, reasons
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "ready_to_merge": self = .readyToMerge
        case "checks_green": self = .checksGreen
        case "blocked": self = .blocked(reasons: try container.decodeIfPresent([String].self, forKey: .reasons) ?? [])
        case "unknown": self = .unknown
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown readiness \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .type)
        if case .blocked(let reasons) = self {
            try container.encode(reasons, forKey: .reasons)
        }
    }
}
