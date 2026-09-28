import Foundation
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing
@testable import BitbucketCloudAdapter

/// Shared helpers: a fixture provider + its transport, and quick lookups of fixture pull requests.
struct Harness {
    let transport: StubTransport
    let provider: BitbucketCloudProvider
    let directory: BitbucketRepositoryDirectory

    init(step: Int = 0, credential: Credential = .bearer("fixture-bitbucket-token"), extraRoutes: [StubTransport.Route] = []) {
        transport = BitbucketFixtures.transport(step: step)
        transport.add(extraRoutes)
        directory = BitbucketRepositoryDirectory()
        provider = BitbucketCloudProvider(
            instance: BitbucketFixtures.instance,
            credential: credential,
            transport: transport,
            clock: TestClock(),
            directory: directory
        )
    }

    func authored() async throws -> [ChangeRequestSummary] {
        try await provider.listChangeRequests(ChangeRequestQuery(scope: .authored)).items
    }

    func reviewing(repositories: [Repository] = []) async throws -> [ChangeRequestSummary] {
        try await provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested, repositories: repositories)).items
    }

    /// Summary of an authored fixture PR (#42 / #12) from the real listing.
    func authoredSummary(_ number: Int) async throws -> ChangeRequestSummary {
        try #require(try await authored().first { $0.key.number == number })
    }

    func snapshot(_ number: Int) async throws -> ChangeRequestSnapshot {
        if number == 7 {
            let summary = try #require(try await reviewing().first { $0.key.number == 7 })
            return try await provider.hydrate(summary)
        }
        return try await provider.hydrate(try await authoredSummary(number))
    }

    func requests(_ method: String? = nil, containing fragment: String) -> [HTTPRequest] {
        transport.requests.filter { request in
            (method == nil || request.method == method) && request.url.absoluteString.contains(fragment)
        }
    }
}

enum Fx {
    static let me = BitbucketFixtures.userUUID
    static let meEncoded = "%7B8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40%7D"
    static let account = BitbucketFixtures.accountKey

    static func repoKey(_ uuid: String) -> RepoKey {
        RepoKey(account: account, remoteRepoID: uuid)
    }

    static func prKey(_ number: Int, repo: String = BitbucketFixtures.IDs.paymentsRepoUUID) -> ChangeRequestKey {
        ChangeRequestKey(repo: repoKey(repo), remoteID: String(number), number: number)
    }

    static func thread(_ id: String, kind: ThreadKind = .diffThread, number: Int = 42) -> ThreadKey {
        ThreadKey(changeRequest: prKey(number), remoteID: id, kind: kind)
    }

    static func decodeComments(_ json: String) throws -> [BBComment] {
        try JSONDecoder.mergeCueProvider.decode([BBComment].self, from: Data(json.utf8))
    }
}
