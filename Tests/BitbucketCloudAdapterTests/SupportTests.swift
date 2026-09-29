import Foundation
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing
@testable import BitbucketCloudAdapter

@Suite("Bitbucket errors, deep links, identifiers and readiness rules")
struct SupportTests {
    // MARK: Errors

    private func userError(status: Int, body: String, headers: [String: String] = [:]) async -> ProviderError? {
        let harness = Harness(extraRoutes: [.getJSON("/user", body, status: status, headers: headers)])
        do {
            _ = try await harness.provider.currentUser()
            return nil
        } catch {
            return error as? ProviderError
        }
    }

    @Test func httpErrorsMapToProviderErrors() async throws {
        let body401 = #"{"type":"error","error":{"message":"Token is invalid, expired, or not supported for this endpoint."}}"#
        let error401 = await userError(status: 401, body: body401)
        #expect(error401 == .unauthorized("Token is invalid, expired, or not supported for this endpoint."))

        let body403 = #"{"type":"error","error":{"message":"Your credentials lack one or more required privilege scopes.","detail":{"granted":["read:user:bitbucket"],"required":["read:pullrequest:bitbucket"]}}}"#
        guard case .forbidden = await userError(status: 403, body: body403) else {
            Issue.record("403 must map to forbidden")
            return
        }
        guard case .notFound = await userError(status: 404, body: #"{"type":"error","error":{"message":"Not found"}}"#) else {
            Issue.record("404 must map to notFound")
            return
        }
        guard case .rateLimited = await userError(status: 429, body: #"{"type":"error","error":{"message":"Rate limit for this resource has been exceeded"}}"#) else {
            Issue.record("429 must map to rateLimited")
            return
        }
    }

    @Test func errorMessagesNeverEchoTheCredential() async throws {
        let token = "ATCTT3xFfGN0-very-secret-access-token"
        let harness = Harness(
            credential: .bearer(token),
            extraRoutes: [.getJSON("/user", #"{"type":"error","error":{"message":"bad token ATCTT3xFfGN0-very-secret-access-token"}}"#, status: 401)]
        )
        do {
            _ = try await harness.provider.currentUser()
            Issue.record("expected failure")
        } catch {
            #expect(!"\(error)".contains(token))
        }
    }

    // MARK: Deep links

    @Test func deepLinksPointAtTheExactBitbucketItem() async throws {
        let harness = Harness()
        let snapshot = try await harness.snapshot(42)
        let provider = harness.provider
        #expect(provider.deepLink(to: .changeRequest(snapshot.key))?.absoluteString
            == "https://bitbucket.org/acme/payments-api/pull-requests/42")
        #expect(provider.deepLink(to: .thread(Fx.thread("501")))?.absoluteString
            == "https://bitbucket.org/acme/payments-api/pull-requests/42#comment-501")
        #expect(provider.deepLink(to: .comment(Fx.thread("501"), commentID: "503"))?.absoluteString
            == "https://bitbucket.org/acme/payments-api/pull-requests/42#comment-503")

        let unit = try #require(snapshot.checks.first { $0.name == "Pipeline › Unit tests" })
        #expect(provider.deepLink(to: .check(unit.key))?.absoluteString
            == "https://bitbucket.org/acme/payments-api/pipelines/results/101/steps/%7Baa101000-0000-4000-8000-000000000002%7D")
        let sonar = try #require(snapshot.checks.first { $0.key.source == .bitbucketStatus })
        #expect(provider.deepLink(to: .check(sonar.key)) == sonar.detailsURL)
    }

    @Test func pipelineStepDeepLinkIsDerivedWithoutCachedURL() async throws {
        let directory = BitbucketRepositoryDirectory()
        directory.record(host: "bitbucket.org", uuid: BitbucketFixtures.IDs.paymentsRepoUUID, fullName: "acme/payments-api")
        let provider = BitbucketCloudProvider(
            instance: .bitbucketCloud, credential: .bearer("x"), transport: BitbucketFixtures.transport(), clock: TestClock(),
            directory: directory
        )
        let key = CheckKey(changeRequest: Fx.prKey(42), source: .bitbucketPipelineStep, remoteID: "102/{bb102000-0000-4000-8000-000000000002}")
        #expect(provider.deepLink(to: .check(key))?.absoluteString
            == "https://bitbucket.org/acme/payments-api/pipelines/results/102/steps/%7Bbb102000-0000-4000-8000-000000000002%7D")
    }

    @Test func deepLinksNeedAKnownRepository() {
        let provider = BitbucketFixtures.provider()
        #expect(provider.deepLink(to: .changeRequest(Fx.prKey(42))) == nil, "no guessed URLs for unknown repositories")
    }

    // MARK: Identifiers

    @Test func uuidNormalization() {
        #expect(BitbucketIdentifiers.normalizedUUID("8A6F0B4E-2C1D-4C8E-9F3A-5B7D1E2C3A40") == Fx.me)
        #expect(BitbucketIdentifiers.normalizedUUID("%7B8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40%7D") == Fx.me)
        #expect(BitbucketIdentifiers.normalizedUUID("  {8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40} ") == Fx.me)
        #expect(BitbucketIdentifiers.normalizedUUID("") == nil)
        #expect(BitbucketIdentifiers.sameUUID("8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40", Fx.me))
        #expect(!BitbucketIdentifiers.sameUUID(nil, Fx.me))
        #expect(BitbucketIdentifiers.segment(Fx.me) == Fx.meEncoded)
    }

    @Test func bbqlLiteralsAreEscaped() {
        #expect(BitbucketIdentifiers.bbqlString(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(BitbucketIdentifiers.reviewerQuery(userUUID: "8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40")
            == #"reviewers.uuid="{8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40}" AND state="OPEN""#)
    }

    @Test func codeLinkSpecCommitsAreParsed() {
        let link = "https://api.bitbucket.org/2.0/repositories/acme/payments-api/diff/acme/payments-api:3f9c2e1d8b47..9c1e4d2b7a60?path=src%2Fa.ts"
        #expect(BitbucketThreadBuilder.specCommits(fromCodeLink: link) == ["3f9c2e1d8b47", "9c1e4d2b7a60"])
        #expect(BitbucketThreadBuilder.specCommits(fromCodeLink: "https://example.com/nothing") == [])
    }

    // MARK: Reply chains (unit)

    @Test func repliesToExcludedCommentsAttachToTheNearestSurvivingAncestor() throws {
        let comments = try Fx.decodeComments("""
        [
          {"id": 1, "created_on": "2026-01-01T10:00:00.000000+00:00", "content": {"raw": "root"}, "inline": {"path": "a.swift", "to": 3}},
          {"id": 2, "created_on": "2026-01-01T10:01:00.000000+00:00", "content": {"raw": ""}, "deleted": true, "parent": {"id": 1}},
          {"id": 3, "created_on": "2026-01-01T10:02:00.000000+00:00", "content": {"raw": "reply to deleted"}, "parent": {"id": 2}},
          {"id": 4, "created_on": "2026-01-01T10:03:00.000000+00:00", "content": {"raw": "draft"}, "pending": true, "parent": {"id": 3}},
          {"id": 5, "created_on": "2026-01-01T10:04:00.000000+00:00", "content": {"raw": "reply to draft"}, "parent": {"id": 4}},
          {"id": 10, "created_on": "2026-01-01T11:00:00.000000+00:00", "content": {"raw": ""}, "deleted": true},
          {"id": 11, "created_on": "2026-01-01T11:01:00.000000+00:00", "content": {"raw": "orphaned reply"}, "parent": {"id": 10}},
          {"id": 20, "created_on": "2026-01-01T12:00:00.000000+00:00", "content": {"raw": "gone"}, "deleted": true}
        ]
        """)
        let mapper = BitbucketMapper(instance: .bitbucketCloud, account: Fx.account)
        let threads = BitbucketThreadBuilder(
            mapper: mapper, changeRequest: Fx.prKey(42),
            pullRequestURL: URL(string: "https://bitbucket.org/acme/payments-api/pull-requests/42")!, headSHA: nil
        ).build(comments)
        #expect(threads.map(\.key.remoteID) == ["1", "10"], "a fully deleted thread disappears")
        #expect(threads[0].comments.map(\.id) == ["1", "3", "5"])
        #expect(threads[0].comments.map(\.inReplyToID) == [nil, "1", "3"])
        #expect(threads[0].anchor?.isOutdated == false, "no anchor commit: not claimed outdated")
        #expect(threads[1].comments.map(\.id) == ["11"])
        #expect(threads[1].key.kind == .conversation)
    }

    // MARK: Readiness and manifest

    @Test func readinessNeverClaimsReadyToMerge() {
        let green = CheckRun(key: CheckKey(changeRequest: Fx.prKey(42), source: .bitbucketStatus, remoteID: "ci"), name: "CI", status: .success)
        #expect(BitbucketReadiness.evaluate(state: .open, isDraft: false, reviewers: [], threads: [], unresolvedTaskCount: 0, checks: [green])
            == .checksGreen)
        #expect(BitbucketReadiness.evaluate(state: .open, isDraft: false, reviewers: [], threads: [], unresolvedTaskCount: 0, checks: [])
            == .unknown)
        let running = CheckRun(key: green.key, name: "CI", status: .inProgress)
        #expect(BitbucketReadiness.evaluate(state: .open, isDraft: true, reviewers: [], threads: [], unresolvedTaskCount: 0, checks: [running])
            == .blocked(reasons: ["Draft pull request", "Checks still running"]))
        #expect(BitbucketReadiness.evaluate(state: .merged, isDraft: false, reviewers: [], threads: [], unresolvedTaskCount: 0, checks: [green])
            == .blocked(reasons: ["Pull request is already merged"]))
    }

    @Test func manifestDeclaresEveryCapability() {
        let manifest = BitbucketCloudProvider.capabilityManifest
        #expect(manifest.provider == .bitbucketCloud)
        #expect(manifest.undeclared.isEmpty)
        #expect(manifest.support(for: .createReply) == .supported)
        #expect(manifest.support(for: .resolveThread) == .supported)
        guard case .partial = manifest.support(for: .merge) else {
            Issue.record("merge must document the head race")
            return
        }
        #expect(BitbucketFixtures.provider().capabilities == manifest)
        #expect(BitbucketCloudProvider.protocolVersion == 1)
    }

    @Test func pipelineStateMapping() {
        func state(_ name: String, _ result: String? = nil, stage: String? = nil) -> CheckStatus {
            BitbucketChecksMapper.status(BBPipelineState(
                name: name, result: result.map { .init(name: $0) }, stage: stage.map { .init(name: $0) }
            ))
        }
        #expect(state("PENDING") == .queued)
        #expect(state("IN_PROGRESS") == .inProgress)
        #expect(state("IN_PROGRESS", stage: "PAUSED") == .actionRequired)
        #expect(state("COMPLETED", "SUCCESSFUL") == .success)
        #expect(state("COMPLETED", "FAILED") == .failure)
        #expect(state("COMPLETED", "ERROR") == .failure)
        #expect(state("COMPLETED", "STOPPED") == .cancelled)
        #expect(state("COMPLETED", "NOT_RUN") == .skipped)
        #expect(BitbucketChecksMapper.status("INPROGRESS") == .inProgress)
        #expect(BitbucketChecksMapper.status("STOPPED") == .cancelled)
    }
}

/// Conditional GETs (DECISIONS D35): Bitbucket GETs send `If-None-Match` once a response carried an ETag.
@Suite("Bitbucket conditional requests")
struct BitbucketConditionalRequestTests {
    @Test func unchangedCollectionsAreRevalidatedWithIfNoneMatch() async throws {
        let etag = #""ws-v1""#
        let body = #"{"values":[{"workspace":{"slug":"acme","uuid":"{11111111-2222-3333-4444-555555555555}","name":"Acme"}}]}"#
        let stub = StubTransport(routes: [
            StubTransport.Route(method: "GET", pathPattern: "/user/workspaces") { request, _ in
                if request.header("If-None-Match") == etag { return StubTransport.empty(status: 304, headers: ["ETag": etag]) }
                return StubTransport.json(body, headers: ["ETag": etag])
            },
        ], baseURL: BitbucketFixtures.instance.apiURL)
        let provider = BitbucketCloudProvider(
            instance: BitbucketFixtures.instance, credential: .bearer("fixture-bitbucket-token"), transport: stub,
            clock: TestClock(), directory: BitbucketRepositoryDirectory()
        )
        let first = try await provider.listNamespaces()
        let second = try await provider.listNamespaces()
        #expect(first.map(\.path) == ["acme"])
        #expect(second == first, "a 304 serves the cached page")
        #expect(stub.requests.count == 2)
        #expect(stub.requests.first?.header("If-None-Match") == nil)
        #expect(stub.requests.last?.header("If-None-Match") == etag)
    }
}
