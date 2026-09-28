import Foundation
@testable import GitLabAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

/// A clock whose sleeps return immediately (retries run instantly in tests).
struct ImmediateClock: MCClock {
    var now: Date { Date(timeIntervalSince1970: 1_790_000_000) }
    func sleep(for seconds: TimeInterval) async throws {}
}

struct GitLabHarness {
    let provider: GitLabProvider
    let transport: StubTransport

    init(step: Int = 0, instance: ProviderInstance = GitLabFixtures.instance, extraRoutes: [StubTransport.Route] = []) {
        transport = StubTransport(routes: GitLabFixtures.routes(step: step), baseURL: instance.apiURL)
        transport.add(extraRoutes)
        provider = GitLabProvider(instance: instance, credential: GitLabFixtures.credential, transport: transport, clock: ImmediateClock())
    }

    /// Summary of `key` as returned by the listing endpoints (authored + review requested).
    func summary(_ key: ChangeRequestKey) async throws -> ChangeRequestSummary {
        let authored = try await provider.listChangeRequests(ChangeRequestQuery(scope: .authored))
        let reviewing = try await provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested))
        guard let summary = (authored.items + reviewing.items).first(where: { $0.key == key }) else {
            throw ProviderError.notFound("fixture summary \(key)")
        }
        return summary
    }

    func snapshot(_ key: ChangeRequestKey) async throws -> ChangeRequestSnapshot {
        try await provider.hydrate(try await summary(key))
    }

    /// Paths (relative to the API root, percent-decoded) of every request, in order.
    var requestedPaths: [String] {
        transport.requests.map { request in
            let base = GitLabFixtures.instance.apiURL.path
            let path = request.url.path(percentEncoded: false)
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
        }
    }
}

extension ChangeRequestSnapshot {
    func thread(remoteID: String) -> ReviewThread? {
        threads.first { $0.key.remoteID == remoteID }
    }
}

/// Decodes a fixture merge request, applying `edit` to its JSON object first.
func fixtureMergeRequest(_ name: String = "mr_278964_42", step: Int = 0, edit: (inout [String: Any]) -> Void = { _ in }) throws -> GLMergeRequest {
    let data = try #require(GitLabFixtures.data(name, step: step))
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    edit(&object)
    let edited = try JSONSerialization.data(withJSONObject: object)
    return try GitLabJSON.decoder().decode(GLMergeRequest.self, from: edited)
}

