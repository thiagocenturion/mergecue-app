import Foundation
import MergeCueCore
import MergeCueStore

// The local, append-only audit trail: agent-reported milestones, rejected agent calls, account changes, rule
// firings and every attempt/success/failure/refusal of a user-approved write. Outcomes: `attempted` (approved,
// about to write), `succeeded`, `failed` (the write or probe failed), `rejected` (refused before any write:
// policy, gate, stale fresh state, owner decline, invalid agent call).

extension MergeCueEngine {
    /// The newest audit entries (optionally of one task), newest first.
    public func auditLog(limit: Int = 200, taskID: TaskID? = nil) async throws(EngineError) -> [AuditEntry] {
        try await uiCall { try await database.auditEntries(limit: max(1, min(limit, 5000)), taskID: taskID) }
    }
}
