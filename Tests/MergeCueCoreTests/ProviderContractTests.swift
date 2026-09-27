import Foundation
import MergeCueCore
import Testing

/// Minimal conformance proving the protocol surface is implementable and `requireCapability` works.
private struct StubProvider: ReviewProvider {
    static let protocolVersion = ReviewProviderContract.currentVersion
    let instance = ProviderInstance.gitlabCom
    let capabilities: CapabilityManifest

    func currentUser() async throws -> ProviderUser { ProviderUser(remoteID: "1", username: "mona-dev") }
    func listNamespaces() async throws -> [Namespace] { [] }
    func listRepositories(namespace: Namespace?) async throws -> [Repository] { [] }
    func listChangeRequests(_ query: ChangeRequestQuery) async throws -> ChangeRequestPage { .unchanged }
    func hydrate(_ summary: ChangeRequestSummary) async throws -> ChangeRequestSnapshot {
        ChangeRequestSnapshot(summary: summary, fetchedAt: Fixture.date)
    }
    func headInfo(for changeRequest: ChangeRequestKey) async throws -> HeadInfo {
        HeadInfo(headSHA: "abc", state: .open, isDraft: false, updatedAt: Fixture.date)
    }
    func thread(_ key: ThreadKey) async throws -> ReviewThread { throw ProviderError.notFound(key.shortID) }
    func failureLog(for check: CheckRun, maxBytes: Int) async throws -> LogExcerpt {
        try requireCapability(.readFailureLog)
        return LogExcerpt(text: "", truncated: false)
    }
    func diff(for changeRequest: ChangeRequestKey, maxBytes: Int) async throws -> DiffPayload {
        DiffPayload(unifiedDiff: "", files: [], truncated: false)
    }
    func createReply(to thread: ThreadKey, body: String) async throws -> ReviewComment {
        try requireCapability(.createReply)
        return ReviewComment(id: "1", author: Fixture.person(), body: body, createdAt: Fixture.date)
    }
    func resolveThread(_ thread: ThreadKey, resolved: Bool) async throws { try requireCapability(.resolveThread) }
    func requestChanges(on changeRequest: ChangeRequestKey, body: String) async throws { try requireCapability(.requestChanges) }
    func merge(_ changeRequest: ChangeRequestKey, expectedHeadSHA: String) async throws { try requireCapability(.merge) }
    func fetchHeadSpec(for snapshot: ChangeRequestSnapshot) -> FetchHeadSpec? {
        FetchHeadSpec(remoteURLs: [], refspec: "refs/merge-requests/\(snapshot.key.number)/head")
    }
    func deepLink(to target: DeepLinkTarget) -> URL? { nil }
}

@Suite("Capabilities and provider errors")
struct ProviderContractTests {
    private let manifest = CapabilityManifest(
        provider: .gitlab,
        manifestVersion: 1,
        entries: [
            .listAuthored: .supported,
            .readFailureLog: .partial(note: "Trace only"),
            .createReply: .requiresWriteAccess(scope: "api"),
            .merge: .unsupported(reason: "Disabled in v1"),
        ]
    )

    @Test func missingCapabilityIsUnsupported() {
        guard case .unsupported(let reason) = manifest.support(for: .deepLink) else {
            Issue.record("expected unsupported")
            return
        }
        #expect(reason.contains("GitLab"))
        #expect(manifest.isUsable(.listAuthored))
        #expect(manifest.isUsable(.readFailureLog))
        #expect(!manifest.isUsable(.createReply))
        #expect(!manifest.isUsable(.merge))
        #expect(manifest.undeclared.count == Capability.allCases.count - 4)
    }

    @Test func supportDescriptions() {
        #expect(CapabilitySupport.supported.userFacingDescription == "Supported")
        #expect(CapabilitySupport.requiresWriteAccess(scope: "api").userFacingDescription == "Requires write access (api)")
        #expect(CapabilitySupport.partial(note: "x").userFacingDescription == "Partially supported: x")
        #expect(CapabilitySupport.unsupported(reason: "y").userFacingDescription == "Unsupported: y")
    }

    @Test func manifestEncodesAsKeyedObject() throws {
        let json = try Fixture.json(CapabilityManifest(provider: .github, entries: [.merge: .unsupported(reason: "n/a"), .listAuthored: .supported]))
        #expect(json == #"{"entries":{"listAuthored":{"type":"supported"},"merge":{"reason":"n/a","type":"unsupported"}},"manifestVersion":1,"provider":"github"}"#)
        #expect(try Fixture.roundTrip(manifest) == manifest)
    }

    @Test func writeCapabilities() {
        #expect(Set(Capability.allCases.filter(\.isWrite)) == [.resolveThread, .requestChanges, .createReply, .merge])
        #expect(RemoteActionKind.postReply.requiredCapability == .createReply)
        #expect(RemoteActionKind.applyPatch.requiredCapability == nil)
    }

    @Test func requireCapabilityMapsManifestEntries() async throws {
        let provider = StubProvider(capabilities: manifest)
        #expect(StubProvider.protocolVersion == 1)
        let log = try await provider.failureLog(
            for: CheckRun(key: CheckKey(changeRequest: Fixture.changeRequestKey(), source: .gitlabJob, remoteID: "1"), name: "test", status: .failure),
            maxBytes: 100
        )
        #expect(log.text.isEmpty)
        await #expect(throws: ProviderError.forbidden(missingScope: "api", message: "Reply to threads needs write access.")) {
            _ = try await provider.createReply(to: ThreadKey(changeRequest: Fixture.changeRequestKey(), remoteID: "d", kind: .diffThread), body: "hi")
        }
        await #expect(throws: ProviderError.unsupported(.merge, reason: "Disabled in v1")) {
            try await provider.merge(Fixture.changeRequestKey(), expectedHeadSHA: "abc")
        }
        await #expect(throws: ProviderError.self) {
            try await provider.resolveThread(ThreadKey(changeRequest: Fixture.changeRequestKey(), remoteID: "d", kind: .diffThread), resolved: true)
        }
    }

    @Test func retryability() {
        #expect(ProviderError.rateLimited(resetAt: nil, retryAfter: 30).isRetryable)
        #expect(ProviderError.offline.isRetryable)
        #expect(ProviderError.timeout.isRetryable)
        #expect(ProviderError.server(status: 502, message: "").isRetryable)
        #expect(ProviderError.server(status: 408, message: "").isRetryable)
        #expect(!ProviderError.server(status: 418, message: "").isRetryable)
        #expect(!ProviderError.unauthorized("expired").isRetryable)
        #expect(!ProviderError.forbidden(missingScope: "repo", message: "").isRetryable)
        #expect(!ProviderError.notFound("").isRetryable)
        #expect(!ProviderError.decoding("").isRetryable)
        #expect(!ProviderError.unsupported(.merge, reason: "").isRetryable)
        #expect(!ProviderError.conflict("head moved").isRetryable)
        #expect(!ProviderError.invalidRequest("").isRetryable)
    }

    @Test func codesAndRetryDates() {
        #expect(ProviderError.rateLimited(resetAt: nil, retryAfter: nil).code == "rate_limited")
        #expect(ProviderError.server(status: 500, message: "").code == "server_error")
        let reset = Fixture.date.addingTimeInterval(600)
        #expect(ProviderError.rateLimited(resetAt: reset, retryAfter: nil).retryDate(now: Fixture.date) == reset)
        #expect(ProviderError.rateLimited(resetAt: reset, retryAfter: 60).retryDate(now: Fixture.date) == Fixture.date.addingTimeInterval(60))
        #expect(ProviderError.offline.retryDate(now: Fixture.date) == nil)
        #expect(ProviderError.forbidden(missingScope: "read_api", message: "x").errorDescription?.contains("read_api") == true)
    }
}
