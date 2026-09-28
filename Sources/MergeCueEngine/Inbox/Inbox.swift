import Foundation
import MergeCueCore
import MergeCueStore

// Inbox: attention items (Sync owns their content, the user owns their state), change requests from stored
// snapshots, and on-demand CI logs / diffs fetched through the providers (bounded + redacted).

extension MergeCueEngine {
    // MARK: Attention

    /// Attention items matching `query`, actionable first, then by priority and recency. Dismissed items are only
    /// returned by no filter (they are hidden from the inbox).
    public func attentionItems(_ query: AttentionQuery = AttentionQuery()) async throws(EngineError) -> [AttentionItem] {
        try await uiCall {
            let at = now
            var items = try await database.attentionItems(includeInactive: true, now: at)
            if query.scope != .all {
                let involvement = try await involvementByChangeRequest()
                items = items.filter { item in
                    let set = involvement[item.changeRequest.id] ?? []
                    return query.scope == .mine ? set.contains(.authored) : set.contains(.reviewRequested)
                }
            }
            if let provider = query.provider { items = items.filter { $0.providerKind == provider } }
            if let account = query.account { items = items.filter { $0.account == account } }
            if let repo = query.repo { items = items.filter { $0.changeRequest.repo == repo } }
            items = items.filter { Self.matches($0, status: query.status, now: at) }
            return items.sorted { lhs, rhs in
                let (la, ra) = (lhs.isActionable(now: at), rhs.isActionable(now: at))
                if la != ra { return la }
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    static func matches(_ item: AttentionItem, status: AttentionStatusFilter, now: Date) -> Bool {
        let dismissed = item.disposition == .dismissed
        switch status {
        case .all: return !dismissed
        case .needsAction: return item.isActionable(now: now)
        case .unread: return item.isUnread && !dismissed
        case .withTask: return item.linkedTaskID != nil && !dismissed
        case .snoozed:
            if case .snoozed(let until) = item.disposition { return until > now }
            return false
        case .done: return item.disposition == .acknowledged || item.disposition == .resolved
        }
    }

    private func involvementByChangeRequest() async throws -> [String: Set<Involvement>] {
        var result: [String: Set<Involvement>] = [:]
        for snapshot in try await database.snapshots(account: nil) {
            result[snapshot.key.id] = snapshot.summary.involvement
        }
        return result
    }

    public func markAttentionRead(_ id: String, read: Bool = true) async throws(EngineError) {
        try await uiCall {
            try await requireAttention(id)
            try await database.setAttentionUnread(id: id, !read)
            emit(.attention)
        }
    }

    public func acknowledgeAttention(_ id: String) async throws(EngineError) {
        try await setDisposition(id, .acknowledged)
    }

    /// Snoozes an item until `until` (must be in the future).
    public func snoozeAttention(_ id: String, until: Date) async throws(EngineError) {
        guard until > now else { throw EngineError.invalidInput("Choose a snooze time in the future.") }
        try await setDisposition(id, .snoozed(until: until))
    }

    public func dismissAttention(_ id: String) async throws(EngineError) {
        try await setDisposition(id, .dismissed)
    }

    /// Reopens an acknowledged/dismissed/snoozed item.
    public func reopenAttention(_ id: String) async throws(EngineError) {
        try await setDisposition(id, .open)
    }

    private func setDisposition(_ id: String, _ disposition: AttentionDisposition) async throws(EngineError) {
        try await uiCall {
            try await requireAttention(id)
            try await database.setAttentionDisposition(id: id, disposition)
            if disposition != .open {
                try await database.setAttentionUnread(id: id, false)
            }
            emit(.attention)
        }
    }

    @discardableResult
    private func requireAttention(_ id: String) async throws -> AttentionItem {
        guard let item = try await database.attentionItem(id: id) else {
            throw EngineError.notFound("Attention item \(id)")
        }
        return item
    }

    // MARK: Change requests

    /// Stored change request snapshots (all accounts when nil), most recently updated first.
    public func changeRequests(account: AccountKey? = nil) async throws(EngineError) -> [ChangeRequestSnapshot] {
        try await uiCall {
            try await database.snapshots(account: account).sorted { $0.summary.updatedAt > $1.summary.updatedAt }
        }
    }

    public func changeRequest(_ key: ChangeRequestKey) async throws(EngineError) -> ChangeRequestSnapshot {
        try await uiCall {
            guard let snapshot = try await database.snapshot(key) else {
                throw EngineError.notFound("Change request")
            }
            return snapshot
        }
    }

    /// Event history of a change request.
    public func events(for key: ChangeRequestKey) async throws(EngineError) -> [ChangeEvent] {
        try await uiCall { try await database.events(changeRequest: key) }
    }

    /// On-demand CI log excerpt for a check (bounded, redacted — untrusted content).
    public func loadCheckLog(_ check: CheckKey, maxBytes: Int = 16 * 1024) async throws(EngineError) -> LogExcerpt {
        try await uiCall {
            guard let snapshot = try await database.snapshot(check.changeRequest), let run = snapshot.check(check) else {
                throw EngineError.notFound("CI check")
            }
            let bound = min(max(maxBytes, 256), 256 * 1024)
            let excerpt = try await provider(for: check.changeRequest.account).failureLog(for: run, maxBytes: bound)
            let bounded = BoundedText.logExcerpt(SecretRedactor.redact(excerpt.text), maxBytes: bound)
            return LogExcerpt(
                text: bounded.text, truncated: excerpt.truncated || bounded.isTruncated,
                fullLogURL: excerpt.fullLogURL, totalBytes: excerpt.totalBytes
            )
        }
    }

    /// On-demand provider diff of a change request (bounded, redacted).
    public func loadDiff(_ key: ChangeRequestKey, maxBytes: Int = 256 * 1024) async throws(EngineError) -> DiffPayload {
        try await uiCall {
            let bound = min(max(maxBytes, 1024), 1024 * 1024)
            var payload = try await provider(for: key.account).diff(for: key, maxBytes: bound)
            let bounded = BoundedText.truncate(SecretRedactor.redact(payload.unifiedDiff), maxBytes: bound)
            payload.unifiedDiff = bounded.text
            payload.truncated = payload.truncated || bounded.isTruncated
            return payload
        }
    }

    /// "Review changes": the diff recomputed by MergeCue from the task's isolated worktree against its base.
    public func reviewChanges(_ taskID: TaskID, maxBytes: Int = 1024 * 1024) async throws(EngineError) -> WorkspaceChanges {
        try await uiCall {
            let task = try await requireTask(taskID)
            guard let checkout = task.checkout, checkout.policy == .isolatedWorktree,
                  let worktree = checkout.worktreePath, let base = checkout.baseSHA
            else {
                throw EngineError.unsupported("This task has no isolated worktree to review.")
            }
            var changes = try await env.workspace.changes(inWorktree: worktree, since: base, maxBytes: maxBytes)
            changes.unifiedDiff = SecretRedactor.redact(changes.unifiedDiff)
            return changes
        }
    }
}
