import Foundation
import MergeCueCore
import Testing
@testable import WorkspaceInspector

@Suite("Inspect")
struct InspectTests {
    @Test func cleanCheckoutIsSafe() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)

        let info = try await sandbox.inspector().inspect(path: checkout.path)

        #expect(info.isRepository)
        #expect(info.topLevel == checkout.path)
        #expect(info.currentBranch == "main")
        #expect(info.headSHA == scenario.baseSHA)
        #expect(!info.isDirty)
        #expect(info.dirtyPaths.isEmpty)
        #expect(info.safety == .safe)
        #expect(!info.gitButler.isManaged)
        #expect(info.worktrees == [checkout.path])
        let origin = try #require(info.remotes.first)
        #expect(origin.name == "origin")
        #expect(origin.fetchURL == RemoteScenario.originHTTPS)
        #expect(origin.canonical == CanonicalRemote(host: "github.com", path: "acme/payments-api"))
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func subdirectoryResolvesTopLevel() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let info = try await sandbox.inspector().inspect(path: checkout.appending(path: "src").path)
        #expect(info.topLevel == checkout.path)
        #expect(info.safety == .safe)
    }

    @Test func remoteCredentialsAreSanitized() async throws {
        let sandbox = try GitSandbox()
        let repo = try sandbox.initRepo("creds", remote: "https://someone:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/acme/payments-api.git")
        try sandbox.git(["remote", "set-url", "--push", "origin", "https://oauth2:glpat-SECRETSECRETSECRET@gitlab.com/acme/x.git"], in: repo)
        let info = try await sandbox.inspector().inspect(path: repo.path)
        let remote = try #require(info.remotes.first)
        #expect(!remote.fetchURL.contains("ghp_"))
        #expect(!remote.fetchURL.contains("someone"))
        #expect(!(remote.pushURL ?? "").contains("glpat-"))
        #expect(remote.canonical?.path == "acme/payments-api")
        let encoded = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        #expect(!encoded.contains("ghp_abcdef"))
        #expect(!encoded.contains("SECRETSECRET"))
    }

    @Test func dirtyCheckoutListsModifiedAndUntrackedPaths() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        try sandbox.write("changed\n", to: checkout.appending(path: "README.md"))
        try sandbox.write("new\n", to: checkout.appending(path: "notes/todo.txt"))
        try sandbox.git(["mv", "src/app.txt", "src/main.txt"], in: checkout)
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)

        let info = try await sandbox.inspector().inspect(path: checkout.path)

        #expect(info.isDirty)
        #expect(info.safety == .dirty)
        #expect(Set(info.dirtyPaths) == ["README.md", "notes/", "src/main.txt"])
        // Inspection never refreshes or rewrites the index.
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func detachedHead() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        try sandbox.git(["checkout", "-q", "--detach", "HEAD"], in: checkout)
        let info = try await sandbox.inspector().inspect(path: checkout.path)
        #expect(info.currentBranch == nil)
        #expect(info.headSHA == scenario.baseSHA)
        #expect(info.safety == .detached)
    }

    @Test func notARepositoryAndMissing() async throws {
        let sandbox = try GitSandbox()
        let plain = sandbox.url("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let inspector = sandbox.inspector()

        let notRepo = try await inspector.inspect(path: plain.path)
        #expect(!notRepo.isRepository)
        #expect(notRepo.safety == .notARepository)

        let missing = try await inspector.inspect(path: sandbox.url("nope").path)
        #expect(!missing.isRepository)
        #expect(missing.safety == .missing)

        let bare = sandbox.url("bare.git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try sandbox.git(["init", "-q", "--bare"], in: bare)
        #expect(try await inspector.inspect(path: bare.path).safety == .notARepository)
    }

    @Test func leakedGitEnvironmentIsIgnored() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let other = try sandbox.initRepo("other")
        var inherited = ProcessInfo.processInfo.environment
        inherited["GIT_DIR"] = other.appending(path: ".git").path
        inherited["GIT_WORK_TREE"] = other.path
        inherited["GIT_INDEX_FILE"] = "/nonexistent/index"
        let inspector = GitWorkspaceInspector(
            worktreeRoot: sandbox.worktreeRoot, environmentOverrides: sandbox.environment, inheritedEnvironment: inherited
        )
        let info = try await inspector.inspect(path: checkout.path)
        #expect(info.topLevel == checkout.path)
        #expect(info.headSHA == scenario.baseSHA)
    }

    @Test func gitButlerWorkspaceIsDetectedWithEvidence() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        try scenario.makeGitButlerWorkspace(checkout)
        try sandbox.git(["config", "gitbutler.signCommits", "false"], in: checkout)

        let info = try await sandbox.inspector().inspect(path: checkout.path)

        #expect(info.gitButler.isManaged)
        #expect(info.gitButler.workspaceBranch == "gitbutler/workspace")
        #expect(info.safety == .gitButlerWorkspace)
        let evidence = info.gitButler.evidence.joined(separator: "\n")
        #expect(evidence.contains("HEAD is on the GitButler branch gitbutler/workspace"))
        #expect(evidence.contains(".git/gitbutler directory exists"))
        #expect(evidence.contains("GitButler branches present"))
        #expect(evidence.contains("gitbutler.* configuration"))
    }

    @Test func gitButlerDataDirectoryAloneMarksManaged() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        try FileManager.default.createDirectory(at: checkout.appending(path: ".git/gitbutler"), withIntermediateDirectories: true)
        let info = try await sandbox.inspector().inspect(path: checkout.path)
        #expect(info.gitButler.isManaged)
        #expect(info.gitButler.workspaceBranch == nil)
        #expect(info.safety == .gitButlerWorkspace)
    }

    @Test func linkedWorktreesAreListed() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let extra = sandbox.url("work/extra")
        try sandbox.git(["worktree", "add", "-q", "--detach", extra.path], in: checkout)
        let info = try await sandbox.inspector().inspect(path: checkout.path)
        #expect(info.worktrees == [checkout.path, extra.path])
    }
}
