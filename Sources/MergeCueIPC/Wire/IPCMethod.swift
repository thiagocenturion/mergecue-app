import Foundation

/// Every method of the private IPC channel (and, except `ping`, every MCP tool). Raw values are the wire names.
public enum IPCMethod: String, Codable, Sendable, CaseIterable, Hashable {
    case ping
    case listAttention = "list_attention"
    case getTask = "get_task"
    case getChangeContext = "get_change_context"
    case getThread = "get_thread"
    case getCIFailure = "get_ci_failure"
    case getDiff = "get_diff"
    case claimTask = "claim_task"
    case heartbeat
    case updateTask = "update_task"
    case reportChanges = "report_changes"
    case reportTests = "report_tests"
    case submitResult = "submit_result"
    case failTask = "fail_task"
    case proposeRule = "propose_rule"
    case listRules = "list_rules"
    case listTasks = "list_tasks"

    /// True for methods that change app state (task leases/state/artifacts, pending rules). Read-only methods
    /// never write; the engine rate-limits and audits mutating ones.
    public var isMutating: Bool {
        switch self {
        case .claimTask, .heartbeat, .updateTask, .reportChanges, .reportTests, .submitResult, .failTask, .proposeRule:
            true
        case .ping, .listAttention, .getTask, .getChangeContext, .getThread, .getCIFailure, .getDiff, .listRules, .listTasks:
            false
        }
    }

    /// Methods that act on a claimed task and therefore require a `lease_id`.
    public var requiresLease: Bool {
        switch self {
        case .heartbeat, .updateTask, .reportChanges, .reportTests, .submitResult, .failTask:
            true
        default:
            false
        }
    }

    /// Wire name (`list_attention`, …).
    public var wireName: String { rawValue }
}
