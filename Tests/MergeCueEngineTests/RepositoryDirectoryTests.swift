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
        let progress = Locked<[CheckoutScanProgress]>([])
        let report = try await h.engine.detectCheckouts(for: [docs, docs, Fixture.repo(Fixture.github)], searchRoots: ["/tmp/code"]) { value in
            progress.update { $0.append(value) }
        }
        #expect(report.scanned == 2)
        #expect(report.mapped.isEmpty)
        #expect(report.suggestions[docs]?.first?.checkoutPath == "/tmp/code/docs-site")
        #expect(progress.get().last?.isMatching == true)
        #expect(report.directoriesScanned == 7)

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

    @Test("many repositories are matched by ONE scan pass; exact unique matches are mapped")
    func singlePass() async throws {
        let h = try await Harness.make(.init(mapCheckout: false))
        let repos = (0..<50).map { Self.repository("r\($0)", "svc-\($0)") }
        h.world.state.update { $0.repositories = repos }
        _ = try await h.engine.accountRepositories(Fixture.github)
        h.workspace.state.update { $0.suggestionConfidence = .exact }
        let report = try await h.engine.detectCheckouts(for: repos.map(\.key), searchRoots: ["/tmp/code"])
        #expect(h.workspace.state.get().scanCalls.count == 1)
        #expect(h.workspace.state.get().scanCalls.first?.count == 50)
        #expect(report.mapped.count == 50)
        #expect(try await h.engine.mappings().count == 50)
    }

    @Test("search folders persist in the engine settings and feed the scan; nil restores the defaults")
    func searchFolders() async throws {
        let h = try await Harness.make(.init(mapCheckout: false))
        let defaults = await h.engine.checkoutSearchFolders()
        let saved = try await h.engine.setCheckoutSearchFolders(["/tmp/a", " /tmp/b/ ", "/tmp/a"])
        #expect(saved == ["/tmp/a", "/tmp/b"])
        #expect(try await h.db.setting("engine.checkout_search_folders", as: [String].self) == ["/tmp/a", "/tmp/b"])
        #expect(await h.engine.checkoutSearchFolders() == ["/tmp/a", "/tmp/b"])
        h.world.state.update { $0.repositories = [Self.repository("r9", "docs-site")] }
        _ = try await h.engine.accountRepositories(Fixture.github)
        let report = try await h.engine.detectCheckouts(for: [RepoKey(account: Fixture.github, remoteRepoID: "r9")])
        #expect(report.suggestions.values.first?.map(\.checkoutPath) == ["/tmp/a/docs-site", "/tmp/b/docs-site"])
        await #expect(throws: EngineError.self) { try await h.engine.setCheckoutSearchFolders(["relative/path"]) }
        try await h.engine.setCheckoutSearchFolders(nil)
        #expect(await h.engine.checkoutSearchFolders() == defaults)
    }

    @Test("Choose Folder maps an unstored repository too, resolving its remotes from the account instance")
    func chooseFolderWithoutStoredRepository() async throws {
        let h = try await Harness.make(.init(mapCheckout: false))
        let key = RepoKey(account: Fixture.github, remoteRepoID: "not-listed")
        let preview = try await h.engine.previewMapping(repo: key, repoFullPath: "acme/unlisted", checkoutPath: "/tmp/code/unlisted/")
        #expect(preview.remotesExpected.contains("github.com/acme/unlisted"))
        #expect(preview.suggestion.checkoutPath == "/tmp/code/unlisted")
        let mapping = try await h.engine.addMapping(repo: key, repoFullPath: "acme/unlisted", checkoutPath: "/tmp/code/unlisted")
        #expect(mapping.isConfirmed)
        let again = try await h.engine.addMapping(repo: key, repoFullPath: "acme/unlisted", checkoutPath: "/tmp/code/unlisted")
        #expect(again.id == mapping.id, "choosing the same folder again updates, never duplicates")
        #expect(try await h.engine.mappings(repo: key).count == 1)
    }

    @Test("a mismatched folder that is not a checkout is refused; Map anyway confirms a real one")
    func mismatchPolicy() async throws {
        let h = try await Harness.make(.init(mapCheckout: false))
        let key = RepoKey(account: Fixture.github, remoteRepoID: "x")
        h.workspace.state.update { $0.matchConfidence = .mismatch }
        await #expect(throws: EngineError.self) {
            try await h.engine.addMapping(repo: key, repoFullPath: "acme/x", checkoutPath: "/tmp/not-a-repo")
        }
        #expect(try await h.engine.mappings(repo: key).isEmpty)
        h.workspace.setCheckout("/tmp/other-clone", safety: .safe)
        let preview = try await h.engine.previewMapping(repo: key, repoFullPath: "acme/x", checkoutPath: "/tmp/other-clone")
        #expect(preview.canMapAnyway)
        let forced = try await h.engine.addMapping(repo: key, repoFullPath: "acme/x", checkoutPath: "/tmp/other-clone", confirm: true)
        #expect(forced.confidence == .mismatch && forced.isConfirmed)
    }
}
