import Foundation
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

@Suite("GitHub fixtures")
struct GitHubFixturesTests {
    @Test func resourcesLoadFromTheBundle() throws {
        let paths = GitHubFixtures.allResourcePaths()
        #expect(paths.contains("graphql/pr42_step0.json"))
        #expect(paths.contains("rest/job_9001.log"))
        for path in paths {
            #expect(GitHubFixtures.resource(path) != nil, "\(path)")
        }
        #expect(GitHubFixtures.resource("graphql/does-not-exist.json") == nil)
    }

    @Test func personaIsLabeledDemo() {
        #expect(GitHubFixtures.account.isDemo)
        #expect(GitHubFixtures.user.username == "mona-dev")
        #expect(GitHubFixtures.user.remoteID == "583231")
        #expect(GitHubFixtures.user.displayName == "Mona Dev")
        #expect(GitHubFixtures.accountKey.id == "v1/github/github.com/u:583231")
    }

    @Test func everyStepServesTheScenarioWithoutUnmatchedRequests() async throws {
        for step in GitHubFixtures.steps {
            let (provider, transport) = GitHubFixtures.provider(step: step)
            _ = try await provider.currentUser()
            _ = try await provider.listNamespaces()
            _ = try await provider.listRepositories(namespace: nil)
            for scope in ChangeRequestScope.allCases {
                for summary in try await provider.listChangeRequests(ChangeRequestQuery(scope: scope)).items {
                    let snapshot = try await provider.hydrate(summary)
                    if summary.key.number == 42 {
                        #expect(try await !provider.diff(for: snapshot.key, maxBytes: 10_000).unifiedDiff.isEmpty)
                    }
                }
            }
            #expect(transport.unmatchedRequests.isEmpty, "step \(step)")
        }
    }

    @Test func stepsAreClamped() {
        #expect(GitHubFixtures.routes(step: -3).count == GitHubFixtures.routes(step: 0).count)
        #expect(GitHubFixtures.routes(step: 99).count == GitHubFixtures.routes(step: 2).count)
    }
}
