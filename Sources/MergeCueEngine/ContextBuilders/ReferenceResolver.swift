import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore

// Resolution of agent-supplied references (`change_ref`, `thr_…`, `chk_…`) against stored snapshots only.
// A reference never resolves across providers or accounts by guesswork: refs use `ChangeRequestRef.matches`
// (kind, host, number exact; repo path case-insensitive), scoped to the task's account when a task is in scope,
// and several matching accounts without a task is an `invalid_params` ("ambiguous change_ref") error.

extension MergeCueEngine {
    func resolveChangeRef(_ ref: ChangeRequestRef, scope account: AccountKey?) async throws -> ChangeRequestSnapshot {
        let candidates = try await database.snapshots(account: account).filter { $0.summary.ref.matches(ref) }
        guard let first = candidates.first else {
            throw IPCError(code: .notFound, message: "No change request \(ref.string) in MergeCue.")
        }
        if Set(candidates.map(\.key.account)).count > 1 {
            throw IPCError.invalidParams("ambiguous change_ref \(ref.string): it matches several connected accounts.")
        }
        return first
    }

    func findThread(shortID: String) async throws -> (ReviewThread, ChangeRequestSnapshot)? {
        guard ShortID.isValid(shortID, prefix: ShortID.threadPrefix) else {
            throw IPCError.invalidParams("thread_id must be a MergeCue thread id (thr_…).")
        }
        for snapshot in try await database.snapshots(account: nil) {
            if let thread = snapshot.threads.first(where: { $0.key.shortID == shortID }) {
                return (thread, snapshot)
            }
        }
        return nil
    }

    func findCheck(shortID: String) async throws -> (CheckRun, ChangeRequestSnapshot)? {
        guard ShortID.isValid(shortID, prefix: ShortID.checkPrefix) else {
            throw IPCError.invalidParams("check_id must be a MergeCue check id (chk_…).")
        }
        for snapshot in try await database.snapshots(account: nil) {
            if let check = snapshot.checks.first(where: { $0.key.shortID == shortID }) {
                return (check, snapshot)
            }
        }
        return nil
    }
}
