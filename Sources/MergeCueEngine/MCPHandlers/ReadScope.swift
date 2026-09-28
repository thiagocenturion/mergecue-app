import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore

// Agent read scope (S3) and read hygiene (S12): the "Agent read access" setting, the set of change requests an
// agent may read in `tasks_only` mode, aggregated per-client read audit entries, a rate limit for reads that hit a
// provider (`get_ci_failure`, provider `get_diff`) and a short TTL cache for their results.

/// Change requests an agent may read; nil means the whole inbox (`all_inbox`).
struct AgentReadScope: Sendable {
    var changeRequests: Set<ChangeRequestKey>

    func contains(_ key: ChangeRequestKey) -> Bool {
        changeRequests.contains(key)
    }
}

/// One aggregation window of an MCP client's reads.
struct ReadAuditWindow: Sendable {
    var start: Date
    var counts: [String: Int] = [:]
    var denied = 0
}

/// A cached provider read.
struct CachedProviderRead: Sendable {
    var value: JSONValue
    var expiresAt: Date
}

extension MergeCueEngine {
    /// Aggregation window of read audit entries (one entry per client and window, plus the first denial).
    static let readAuditWindow: TimeInterval = 300
    /// Provider-hitting reads (`get_ci_failure`, provider `get_diff`) per MCP client per minute (cache hits free).
    static let maxProviderReadsPerMinute = 20
    /// Lifetime of cached provider reads.
    static let providerReadCacheTTL: TimeInterval = 60
    static let maxCachedProviderReads = 64

    // MARK: Setting

    /// Settings ▸ Agents ▸ "Agent read access" (default `tasks_only`).
    public func agentReadAccess() async -> AgentReadAccess {
        (try? await database.setting(SettingsKey.agentReadAccess, as: AgentReadAccess.self)) ?? .default
    }

    /// Changes what MCP reads may return. Audited.
    public func setAgentReadAccess(_ access: AgentReadAccess) async throws(EngineError) {
        try await uiCall {
            try await database.setSetting(SettingsKey.agentReadAccess, access)
            providerReadCache.removeAll()
            await appendAudit(actor: "user", action: "set_agent_read_access", target: access.rawValue, outcome: .succeeded, detail: access.explanation)
        }
    }

    // MARK: Scope

    /// nil when agents may read the whole inbox; otherwise the change requests of non-terminal tasks.
    func agentReadScope() async throws -> AgentReadScope? {
        guard await agentReadAccess() == .tasksOnly else { return nil }
        let tasks = try await database.tasks(states: TaskState.active)
        return AgentReadScope(changeRequests: Set(tasks.map(\.origin.changeRequest)))
    }

    static func outOfReadScope(_ what: String) -> IPCError {
        IPCError(
            code: .crossScopeReference,
            message: "\(what) does not belong to an open MergeCue task. Agent read access is set to “\(AgentReadAccess.tasksOnly.displayName)” "
                + "(MergeCue ▸ Settings ▸ Agents): agents may only read the pull/merge requests, threads and checks of tasks the owner "
                + "handed off. Work from get_task, or ask the owner to create a task or allow reading the whole inbox.",
            data: ["agent_read_access": .string(AgentReadAccess.tasksOnly.rawValue)]
        )
    }

    /// Throws `cross_scope_reference` when `key` is outside `scope`.
    func requireInReadScope(_ key: ChangeRequestKey, _ scope: AgentReadScope?, what: String) throws {
        guard let scope, !scope.contains(key) else { return }
        throw Self.outOfReadScope(what)
    }

    /// Hint returned with `list_attention` in `tasks_only` mode.
    static let tasksOnlyAttentionNote = "Agent read access is “\(AgentReadAccess.tasksOnly.displayName)”: only items of pull/merge "
        + "requests with an open MergeCue task are listed. The owner can allow the whole inbox in MergeCue ▸ Settings ▸ Agents."

    // MARK: Read audit (aggregated)

    /// Records one MCP read by `client` in the current window. A new window writes one audit entry summarizing the
    /// previous one; the first denied read of a window is audited immediately.
    func noteAgentRead(_ method: IPCMethod, client: IPCClientInfo, denied: Bool) async {
        let key = Self.clientKey(client)
        if var window = readAuditWindows[key], now.timeIntervalSince(window.start) < Self.readAuditWindow {
            window.counts[method.rawValue, default: 0] += 1
            let firstDenial = denied && window.denied == 0
            if denied { window.denied += 1 }
            readAuditWindows[key] = window
            if firstDenial {
                await appendAudit(actor: "agent:\(key)", action: "mcp_read_denied", target: method.rawValue, outcome: .rejected,
                                  detail: "Read outside the agent read scope was refused.")
            }
            return
        }
        let previous = readAuditWindows[key]
        var window = ReadAuditWindow(start: now)
        window.counts[method.rawValue] = 1
        window.denied = denied ? 1 : 0
        readAuditWindows[key] = window
        readAuditWindows = readAuditWindows.filter { now.timeIntervalSince($0.value.start) < Self.readAuditWindow * 12 }
        var detail = "MCP reads by \(client.name) (pid \(client.pid)) — started with \(method.rawValue)\(denied ? " (denied)" : "")."
        if let previous {
            let total = previous.counts.values.reduce(0, +)
            let breakdown = previous.counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
            detail += " Previous window: \(total) read(s) (\(breakdown)), \(previous.denied) denied."
        }
        await appendAudit(actor: "agent:\(key)", action: "mcp_reads", target: method.rawValue, outcome: denied ? .rejected : .succeeded, detail: detail)
    }

    static func clientKey(_ client: IPCClientInfo) -> String {
        "\(client.name.prefix(64))#\(client.pid)"
    }

    // MARK: Provider reads: rate limit + TTL cache

    /// Returns the cached value for `cacheKey`, or runs `body` after the per-client provider-read rate limit and
    /// caches its result for `providerReadCacheTTL`.
    func cachedProviderRead(_ cacheKey: String, client: IPCClientInfo?, _ body: () async throws -> JSONValue) async throws -> JSONValue {
        let current = now
        providerReadCache = providerReadCache.filter { $0.value.expiresAt > current }
        if let hit = providerReadCache[cacheKey] { return hit.value }
        if let client { try checkProviderReadRateLimit(client) }
        let value = try await body()
        if providerReadCache.count >= Self.maxCachedProviderReads,
           let oldest = providerReadCache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            providerReadCache[oldest] = nil
        }
        providerReadCache[cacheKey] = CachedProviderRead(value: value, expiresAt: current.addingTimeInterval(Self.providerReadCacheTTL))
        return value
    }

    private func checkProviderReadRateLimit(_ client: IPCClientInfo) throws(IPCError) {
        let key = Self.clientKey(client)
        let windowStart = now.addingTimeInterval(-60)
        var attempts = (providerReadAttempts[key] ?? []).filter { $0 > windowStart }
        guard attempts.count < Self.maxProviderReadsPerMinute else {
            providerReadAttempts[key] = attempts
            let retryAfter = attempts.first.map { max(1, Int($0.timeIntervalSince(windowStart).rounded(.up))) } ?? 60
            throw IPCError(
                code: .rateLimited,
                message: "Too many CI log / diff fetches (limit \(Self.maxProviderReadsPerMinute) per minute per agent). Reuse earlier results.",
                retryable: true,
                data: ["retry_after_seconds": .number(Double(retryAfter))]
            )
        }
        attempts.append(now)
        providerReadAttempts[key] = attempts
    }
}
