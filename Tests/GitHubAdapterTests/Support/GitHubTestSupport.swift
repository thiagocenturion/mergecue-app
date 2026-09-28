import Foundation
@testable import GitHubAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

/// Shared helpers: providers over the fixture stub, scenario lookups.
enum GH {
    typealias IDs = GitHubFixtures.IDs

    static func provider(step: Int = 0) -> (provider: GitHubProvider, transport: StubTransport) {
        GitHubFixtures.provider(step: step)
    }

    /// A provider over a bare stub with only `routes` (for error mapping).
    static func bareProvider(_ routes: [StubTransport.Route]) -> (provider: GitHubProvider, transport: StubTransport) {
        let stub = StubTransport(routes: routes, baseURL: GitHubFixtures.instance.apiURL)
        let provider = GitHubProvider(credential: .bearer("test-token-abcdef"), transport: stub, linkRegistry: GitHubLinkRegistry())
        return (provider, stub)
    }

    static func summary(_ provider: GitHubProvider, number: Int, scope: ChangeRequestScope = .authored) async throws -> ChangeRequestSummary {
        let page = try await provider.listChangeRequests(ChangeRequestQuery(scope: scope))
        return try #require(page.items.first { $0.key.number == number })
    }

    static func snapshot(_ provider: GitHubProvider, number: Int = 42, scope: ChangeRequestScope = .authored) async throws -> ChangeRequestSnapshot {
        try await provider.hydrate(try await summary(provider, number: number, scope: scope))
    }

    static func snapshot(step: Int, number: Int = 42) async throws -> ChangeRequestSnapshot {
        try await snapshot(provider(step: step).provider, number: number)
    }

    static func thread(_ snapshot: ChangeRequestSnapshot, _ remoteID: String) throws -> ReviewThread {
        try #require(snapshot.threads.first { $0.key.remoteID == remoteID })
    }

    /// GraphQL operation names sent through `transport`, in order.
    static func operations(_ transport: StubTransport) -> [String] {
        transport.requests(path: "/graphql").compactMap { $0.jsonBody?["operationName"]?.stringValue }
    }

    static func response(_ json: String, status: Int, headers: [String: String] = [:]) -> HTTPResponse {
        StubTransport.json(json, status: status, headers: headers)
    }
}
