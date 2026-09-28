import Foundation

/// What MCP read tools may return to agents (Settings ▸ Agents ▸ "Agent read access"; S3).
public enum AgentReadAccess: String, Codable, Sendable, CaseIterable, Hashable {
    /// Default. Reads are limited to change requests (and their threads/checks) of non-terminal tasks;
    /// `list_attention` only returns items of those change requests.
    case tasksOnly = "tasks_only"
    /// Agents may read every connected account's inbox (the pre-S3 behaviour).
    case allInbox = "all_inbox"

    public static let `default` = AgentReadAccess.tasksOnly

    /// "Only their tasks" / "Whole inbox".
    public var displayName: String {
        switch self {
        case .tasksOnly: "Only their tasks"
        case .allInbox: "Whole inbox"
        }
    }

    /// One-line explanation for Settings and error messages.
    public var explanation: String {
        switch self {
        case .tasksOnly:
            "Agents can read only the pull/merge requests, threads and checks of tasks you handed off and that are still open."
        case .allInbox:
            "Agents can list and read everything in your inbox across all connected accounts."
        }
    }
}
