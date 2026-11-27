import Foundation
import MergeCueCore
import MergeCueStore

// The owner approves someone else's change request from the app (D59). This is the owner's own action, confirmed
// in the UI, not an agent result: it skips the preview gate but keeps every write rule (writes switch, adapter
// capability, audit log) and only approves the head the owner saw.

extension MergeCueEngine {
    /// Whether `key` can be approved from the app: the account's writes switch is on and its adapter's `approve`
    /// capability is usable. When false the UI opens the provider page instead.
    public func canApproveInApp(_ key: ChangeRequestKey) async -> Bool {
        guard let account = try? await database.account(key.account), account.writesEnabled else { return false }
        return env.providers.capabilities(for: account).support(for: .approve).isUsable
    }

    /// Approves `key` at the head of its stored snapshot. Throws `writesDisabled` / `unsupported` when the app may
    /// not approve (nothing is sent), and the provider's `conflict` when the head moved since.
    public func approveChangeRequest(_ key: ChangeRequestKey) async throws(EngineError) {
        try await uiCall {
            let account = try await requireAccount(key.account)
            guard let snapshot = try await database.snapshot(key) else { throw EngineError.notFound("Change request") }
            let target = "\(snapshot.summary.repository.fullPath) \(key.kind.formattedNumber(key.number))"
            guard account.writesEnabled else {
                await appendAudit(actor: "user", action: "approve", target: target, outcome: .rejected, detail: "Writes are disabled for the account.")
                throw EngineError.writesDisabled(account: account.displayLabel)
            }
            let support = env.providers.capabilities(for: account).support(for: .approve)
            guard support.isUsable else {
                await appendAudit(actor: "user", action: "approve", target: target, outcome: .rejected, detail: support.userFacingDescription)
                throw EngineError.unsupported("\(Capability.approve.displayName): \(support.userFacingDescription)")
            }
            guard let head = snapshot.summary.headSHA, !head.isEmpty else {
                throw EngineError.invalidInput("MergeCue has not loaded this \(key.kind.changeRequestAbbreviation)'s commits yet. Refresh and try again.")
            }
            await appendAudit(actor: "user", action: "approve", target: target, outcome: .attempted, detail: "Head \(head.prefix(12)).")
            do {
                try await provider(for: account.id).approve(key, expectedHeadSHA: head)
            } catch {
                await appendAudit(actor: "user", action: "approve", target: target, outcome: .failed, detail: String(describing: error))
                throw error
            }
            await appendAudit(actor: "user", action: "approve", target: target, outcome: .succeeded)
            // Pick the new verdict up right away (lanes, re-approval item, notifications), without blocking the UI.
            let sync = env.sync
            Task { await sync.refresh(account: account.id) }
        }
    }
}
