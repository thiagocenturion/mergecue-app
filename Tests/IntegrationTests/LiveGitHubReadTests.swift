import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueNetworking
import MergeCueRuntime
import Testing

/// Opt-in LIVE read check against GitHub.com using the owner's existing `gh` login (owner-approved, read-only).
/// Enabled only with `MERGECUE_LIVE_GITHUB=1`. Uses a temporary data directory and an in-memory credential store:
/// nothing touches the Keychain, the real MergeCue data, or GitHub state (no writes are ever issued).
/// Evidence (counts and repository names only — no comment bodies, titles or tokens) is written to
/// `docs/evidence/live-github-read.md`.
@Suite("Live GitHub read (opt-in)", .serialized)
struct LiveGitHubReadTests {
    static let enabled = ProcessInfo.processInfo.environment["MERGECUE_LIVE_GITHUB"] == "1"

    @Test(.enabled(if: LiveGitHubReadTests.enabled))
    func liveReadViaGitHubCLILogin() async throws {
        let home = URL(fileURLWithPath: "/tmp/mclive-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = MergeCuePaths(root: home)
        let options = RuntimeOptions(
            notifier: SilentNotifier(),
            credentials: InMemoryCredentialStore(),
            startsIPCServer: false,
            monitorsNetwork: false
        )
        let runtime = try await MergeCueRuntime.makeLive(paths: paths, appVersion: "live-check", options: options)
        try await runtime.start()

        let started = Date()
        let account = try await runtime.connectGitHubFromCLI(label: "live-check")
        #expect(account.writesEnabled == false)
        await runtime.refresh(account: account.id)
        // A second cycle must not duplicate anything (dedupe across polls).
        let first = try await runtime.engine.snapshot()
        await runtime.refresh(account: account.id)
        let second = try await runtime.engine.snapshot()
        let elapsed = Date().timeIntervalSince(started)

        let status = await runtime.sync.statuses().first { $0.account == account.id }
        let crs = second.changeRequests
        let threads = crs.reduce(0) { $0 + $1.threads.count }
        let unresolved = crs.reduce(0) { $0 + $1.unresolvedThreadCount }
        let comments = crs.reduce(0) { $0 + $1.threads.reduce(0) { $0 + $1.comments.count } }
        let checks = crs.reduce(0) { $0 + $1.checks.count }
        let failing = crs.reduce(0) { $0 + $1.checks.filter { $0.status.isFailing }.count }
        let authored = crs.filter { $0.summary.involvement.contains(.authored) }.count
        let reviewing = crs.filter { $0.summary.involvement.contains(.reviewRequested) }.count
        let repos = Set(crs.map { $0.summary.repository.fullPath }).sorted()
        let links = crs.allSatisfy { $0.summary.webURL.host() == "github.com" }

        let report = """
        # Live GitHub.com read check

        - Date: \(ISO8601DateFormatter().string(from: Date()))
        - Auth: owner's existing `gh` login imported via the app's explicit "Use my GitHub CLI login" path \
        (in-memory credential store for this check; token never printed or persisted)
        - Account: `\(account.username)` on `\(account.instance.host)`; granted scopes: \
        \(account.grantedScopes.isEmpty ? "(not reported)" : account.grantedScopes.joined(separator: ", ")); writes enabled: \(account.writesEnabled)
        - Sync status after 2 cycles: `\(status.map { "\($0.state)" } ?? "unknown")`, \
        last success: \(status?.lastSuccessAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")
        - Wall time (connect + 2 cycles): \(String(format: "%.1f", elapsed)) s
        - Open PRs synced: \(crs.count) (authored \(authored), review requested \(reviewing))
        - Review threads: \(threads) (\(unresolved) unresolved), comments: \(comments)
        - Checks: \(checks) (\(failing) failing)
        - Attention items: \(second.attention.count) (after first cycle: \(first.attention.count) — no duplicates on re-poll: \(first.attention.count == second.attention.count))
        - All PR links point at github.com: \(links)
        - Repositories: \(repos.isEmpty ? "(none — no open PRs authored by or requesting review from this account)" : repos.map { "`\($0)`" }.joined(separator: ", "))
        - Remote writes issued: none (read-only check)
        """
        let evidence = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/evidence/live-github-read.md")
        try report.write(to: evidence, atomically: true, encoding: .utf8)
        print(report)

        #expect(status?.lastSuccessAt != nil)
        #expect(first.attention.count == second.attention.count)
        await runtime.stop()
    }
}

private struct SilentNotifier: NotificationDelivering {
    func deliver(_ notification: GroupedNotification) async {}
}
