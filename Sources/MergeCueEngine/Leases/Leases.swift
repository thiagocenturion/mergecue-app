import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore

// Agent leases: `claim_task` issues a capability token (`lease_…`) valid for `leaseDuration`; heartbeats,
// progress updates and reports renew it. A lease that is not renewed in time turns the task `stale` (never
// `done`) with an activity explaining which agent went silent and since when; the owner can retry, or an agent
// can re-claim the stale task with a new lease.

extension MergeCueEngine {
    /// Seconds between heartbeats an agent should send (a third of the lease, at least 10 s).
    var heartbeatInterval: Int {
        max(10, Int(env.leaseDuration / 3))
    }

    func newLease(agentName: String, runID: String?) -> AgentLease {
        let at = now
        return AgentLease(
            agentName: agentName, runID: runID, leaseID: ids.leaseID(), claimedAt: at, heartbeatAt: at,
            expiresAt: at.addingTimeInterval(env.leaseDuration)
        )
    }

    /// The lease with `heartbeatAt = now` and a fresh expiry.
    func renewed(_ lease: AgentLease) -> AgentLease {
        var lease = lease
        lease.heartbeatAt = now
        lease.expiresAt = now.addingTimeInterval(env.leaseDuration)
        return lease
    }

    /// Validates the caller's lease token against the task (`lease_invalid` / `lease_expired`).
    func requireValidLease(_ task: MCTask, leaseID: String) throws(IPCError) -> AgentLease {
        guard let lease = task.lease, !leaseID.isEmpty, constantTimeEquals(lease.leaseID, leaseID) else {
            throw IPCError(
                code: .leaseInvalid,
                message: "The lease_id does not match the task's current lease. Claim the task first (claim_task)."
            )
        }
        if task.state == .stale || lease.isExpired(at: now) {
            throw IPCError(
                code: .leaseExpired,
                message: "The lease expired at \(Self.wireDate(lease.expiresAt)); the task is \(task.state == .stale ? "stale" : "no longer held"). Re-claim it with claim_task.",
                retryable: false
            )
        }
        return lease
    }

    /// Scans `working` tasks and turns those with an expired lease into `stale` (system transition). Called by
    /// the monitor every `staleCheckInterval` seconds of the injected clock; safe to call at any time.
    @discardableResult
    public func sweepExpiredLeases() async -> [TaskID] {
        let working = (try? await database.tasks(states: [.working])) ?? []
        var expired: [TaskID] = []
        for task in working {
            guard let lease = task.lease, lease.isExpired(at: now) else { continue }
            if await expireLease(task, lease: lease) {
                expired.append(task.id)
            }
        }
        return expired
    }

    /// `working` → `stale` for one task. Returns false if another writer changed the task first.
    func expireLease(_ task: MCTask, lease: AgentLease) async -> Bool {
        let message = "No heartbeat from \(lease.agentName) since \(Self.wireDate(lease.heartbeatAt)); "
            + "the lease expired at \(Self.wireDate(lease.expiresAt)). The task is stale, not done — "
            + "retry it or let an agent re-claim it."
        do {
            try await transition(
                task, on: .leaseExpired, by: .system, message: message,
                data: ["agent_name": lease.agentName, "last_heartbeat_at": Self.wireDate(lease.heartbeatAt)]
            ) {
                $0.lastError = TaskErrorInfo(
                    code: "lease_expired", message: "No heartbeat from \(lease.agentName) since \(Self.wireDate(lease.heartbeatAt)).",
                    retryable: true, at: now
                )
            }
            await appendAudit(actor: "system", action: "lease_expired", target: task.id.rawValue, outcome: .succeeded, detail: message, taskID: task.id)
            return true
        } catch {
            return false
        }
    }

    static func wireDate(_ date: Date) -> String {
        MergeCueCoding.formatWireDate(date) ?? "\(date)"
    }
}

/// Compares two tokens without early exit on the first differing byte.
func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in a.indices {
        difference |= a[index] ^ b[index]
    }
    return difference == 0
}
