import Foundation
import MergeCueCore
import MergeCueStore
import Testing
@testable import MergeCueEngine

@Suite("Repository directory and checkout detection")
struct RepositoryDirectoryTests {
    static func repository(_ id: String, _ name: String, in namespace: String = "acme") -> Repository {
        Repository(
            key: RepoKey(account: Fixture.github, remoteRepoID: id), namespacePath: namespace, name: name,
            fullPath: "\(namespace)/\(name)", webURL: URL(string: "https://github.com/\(namespace)/\(name)")!,
            cloneURLs: ["https://github.com/\(namespace)/\(name).git"]
        )
    }

    @Test("lists every repository (no open PR needed), caches with a TTL, force refresh asks again")
    func listingAndCache() async throws {
        let h = try await Harness.make(.init(mapCheckout: false))
        h.world.state.update { $0.repositories = [Self.repository("r2", "zeta-tools"), Self.repository("r1", "alpha-lib")] }
        let first = try await h.engine.accountRepositories(Fixture.github)
        #expect(first.repositories.map(\.fullPath) == ["acme/alpha-lib", "acme/zeta-tools"])
        #expect(!first.fromCache)
        #expect(try await h.db.repositories(account: Fixture.github).count == 2)

        h.world.state.update { $0.repositories.append(Self.repository("r3", "new-repo")) }
        let cached = try await h.engine.accountRepositories(Fixture.github)
        #expect(cached.fromCache)
        #expect(cached.repositories.count == 2)
        #expect(h.world.state.get().repositoryCalls.count == 1)

        h.clock.advance(by: MergeCueEngine.repositoryListTTL + 1)
        let expired = try await h.engine.accountRepositories(Fixture.github)
        #expect(!expired.fromCache)
        #expect(expired.repositories.count == 3)
        _ = try await h.engine.accountRepositories(Fixture.github, forceRefresh: true)
        #expect(h.world.state.get().repositoryCalls.count == 3)
    }

    @Test("selected namespaces restrict the listing")
    func namespaces() async throws {
        let h = try await Harness.make(.init(mapCheckout: false))
        try await h.engine.setSelectedNamespaces(Fixture.github, ["ACME"])
        h.world.state.update { $0.repositories = [Self.repository("r1", "a"), Self.repository("r2", "b", in: "other")] }
        let listing = try await h.engine.accountRepositories(Fixture.github)
        #expect(listing.repositories.map(\.fullPath) == ["acme/a"])
        #expect(h.world.state.get().repositoryCalls == ["acme"])
    }

    @Test("provider errors surface and keep the cache")
    func errors() async throws {
        let h = try await Harness.make(.init(mapCheckout: false))
        h.world.state.update { $0.repositoryError = .rateLimited(resetAt: nil, retryAfter: nil) }
        await #expect(throws: EngineError.self) { try await h.engine.accountRepositories(Fixture.github) }
        #expect(try await h.db.setting("engine.repository_list_fetched_at.\(Fixture.github.id)", as: Date.self) == nil)
        h.world.state.update { $0.repositoryError = nil; $0.repositories = [Self.repository("r1", "a")] }
        #expect(try await h.engine.accountRepositories(Fixture.github).repositories.count == 1)
    }

    @Test("a listed repository without PRs can be mapped; exact unique matches are mapped by the scan")
    func detection() async throws {
        let h = try await Harness.make(.init(mapCheckout: false))
        h.world.state.update { $0.repositories = [Self.repository("r9", "docs-site")] }
        _ = try await h.engine.accountRepositories(Fixture.github)
        let docs = RepoKey(account: Fixture.github, remoteRepoID: "r9")
        // FakeWorkspace suggests one probable candidate per root.
        let progress = Locked<[Int]>([])
        let report = try await h.engine.detectCheckouts(for: [docs, docs, Fixture.repo(Fixture.github)], searchRoots: ["/tmp/code"]) { done, _ in
            progress.update { $0.append(done) }
        }
        #expect(report.scanned == 2)
        #expect(report.mapped.isEmpty)
        #expect(report.suggestions[docs]?.first?.checkoutPath == "/tmp/code/docs-site")
        #expect(progress.get() == [0, 1, 2])

        h.workspace.state.update { $0.suggestionConfidence = .exact }
        let exact = try await h.engine.detectCheckouts(for: [docs], searchRoots: ["/tmp/code"])
        #expect(exact.mapped.map(\.checkoutPath) == ["/tmp/code/docs-site"])
        #expect(exact.mapped.first?.isConfirmed == true)
        #expect(exact.mapped.first?.repoFullPath == "acme/docs-site")
        let after = try await h.engine.detectCheckouts(for: [docs], searchRoots: ["/tmp/code"], maxRepositories: 5)
        #expect(after.scanned == 0, "already mapped repositories are skipped")
        let bounded = try await h.engine.detectCheckouts(for: [Fixture.repo(Fixture.github)], searchRoots: ["/tmp/code"], maxRepositories: 0)
        #expect(bounded.skipped == 1 && bounded.scanned == 0)
    }
}
