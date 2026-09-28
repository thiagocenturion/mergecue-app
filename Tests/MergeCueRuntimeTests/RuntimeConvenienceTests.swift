import AgentHandoff
import Foundation
import GitLabAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueIPC
import MergeCueNetworking
import Synchronization
import Testing
@testable import MergeCueRuntime

/// A scripted `ProcessRunning` (no real `gh` is ever executed in tests).
final class ScriptedRunner: ProcessRunning {
    let result: ProcessResult
    private let calls = Mutex<[[String]]>([])

    init(_ result: ProcessResult) { self.result = result }

    var invocations: [[String]] { calls.withLock { $0 } }

    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?, timeout: TimeInterval) async throws -> ProcessResult {
        calls.withLock { $0.append([executable.path(percentEncoded: false)] + arguments) }
        return result
    }
}

@Suite("GitHub CLI import")
struct GitHubCLITokenImporterTests {
    let gh = URL(filePath: "/opt/fake/gh")
    let token = "gho_" + String(repeating: "A1b2", count: 9)

    @Test func returnsTheTokenAsBearerWithoutExposingIt() async throws {
        let runner = ScriptedRunner(ProcessResult(exitCode: 0, stdout: token + "\n", stderr: ""))
        let importer = GitHubCLITokenImporter(environment: [:], executableOverride: gh, runner: runner)
        let credential = try await importer.importToken()
        #expect(credential == .bearer(token))
        #expect(!String(describing: credential).contains(token))
        #expect(runner.invocations == [["/opt/fake/gh", "auth", "token", "--hostname", "github.com"]])
    }

    @Test func notLoggedInIsReportedWithARedactedMessage() async {
        let leaked = "ghp_" + String(repeating: "Z9", count: 18)
        let runner = ScriptedRunner(ProcessResult(exitCode: 1, stdout: "", stderr: "no oauth token found for github.com (\(leaked))"))
        let importer = GitHubCLITokenImporter(environment: [:], executableOverride: gh, runner: runner)
        do {
            _ = try await importer.importToken()
            Issue.record("expected an error")
        } catch {
            guard case .notLoggedIn(let detail) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(!detail.contains(leaked))
            #expect(error.errorDescription?.contains("gh auth login") == true)
        }
    }

    @Test func timeoutsAndGarbageAreRejected() async {
        let timedOut = GitHubCLITokenImporter(environment: [:], executableOverride: gh, runner: ScriptedRunner(ProcessResult(exitCode: 0, stdout: "", stderr: "", timedOut: true)))
        await #expect(throws: GitHubCLITokenImporter.ImportError.timedOut) { _ = try await timedOut.importToken() }
        let garbage = GitHubCLITokenImporter(environment: [:], executableOverride: gh, runner: ScriptedRunner(ProcessResult(exitCode: 0, stdout: "line one\nline two with spaces", stderr: "")))
        await #expect(throws: GitHubCLITokenImporter.ImportError.invalidToken) { _ = try await garbage.importToken() }
        let badHost = GitHubCLITokenImporter(environment: [:], executableOverride: gh, runner: ScriptedRunner(ProcessResult(exitCode: 0, stdout: token, stderr: "")))
        await #expect(throws: GitHubCLITokenImporter.ImportError.self) { _ = try await badHost.importToken(hostname: "github.com; rm -rf /") }
    }
}

@Suite("Notifications")
struct NotificationTests {
    @Test func userInfoCarriesTheDeepLinkAndIsLabeledInDemo() throws {
        let key = ChangeRequestKey(repo: RepoKey(account: GitHubFixtures.accountKey, remoteRepoID: "1296269"), remoteID: "3100000042", number: 42)
        let notification = GroupedNotification(
            id: "n1", title: "acme/payments-api #42", subtitle: "New comment", body: "Blocking: …", changeRequest: key,
            attentionItemIDs: ["att_1", "att_2"], webURL: URL(string: "https://github.com/acme/payments-api/pull/42")
        )
        let info = UserNotificationDeliverer.userInfo(for: notification, isDemo: true)
        #expect(info[UserNotificationDeliverer.Keys.changeRequestID] as? String == key.id)
        #expect(info[UserNotificationDeliverer.Keys.attentionItemIDs] as? [String] == ["att_1", "att_2"])
        #expect(info[UserNotificationDeliverer.Keys.isDemo] as? Bool == true)
        let link = try #require(info[UserNotificationDeliverer.Keys.deepLink] as? String)
        #expect(link.hasPrefix("mergecue://change-request/"))
        #expect(URL(string: link) != nil)
        #expect(info[UserNotificationDeliverer.Keys.webURL] as? String == "https://github.com/acme/payments-api/pull/42")
    }

    @Test func outsideAnAppBundleNotificationsAreOnlyLogged() async {
        #expect(!UserNotificationDeliverer.isAvailable)
        let deliverer = UserNotificationDeliverer(isDemo: false)
        let key = ChangeRequestKey(repo: RepoKey(account: GitHubFixtures.accountKey, remoteRepoID: "1"), remoteID: "2", number: 3)
        await deliverer.deliver(GroupedNotification(id: "x", title: "t", subtitle: "s", body: "b", changeRequest: key))
        #expect(await deliverer.requestAuthorization() == false)
    }
}

@Suite("Link preloading")
struct LinkPreloadTests {
    @Test func gitlabDeepLinksAreExactAfterPreloadingAStoredSnapshot() throws {
        let account = GitLabFixtures.accountKey
        let repoKey = RepoKey(account: account, remoteRepoID: "7777\(Int.random(in: 100...999))")
        let key = ChangeRequestKey(repo: repoKey, remoteID: "9\(Int.random(in: 1000...9999))", number: 5)
        let provider = GitLabProvider(credential: .bearer("x"), transport: StubTransport(baseURL: ProviderInstance.gitlabCom.apiURL))
        // Never seen: only the id-based project route.
        #expect(provider.deepLink(to: .changeRequest(key))?.absoluteString.contains("/projects/") == true)
        let mrURL = try #require(URL(string: "https://gitlab.com/acme/preloaded/-/merge_requests/5"))
        let repository = Repository(
            key: repoKey, namespacePath: "acme", name: "preloaded", fullPath: "acme/preloaded",
            webURL: try #require(URL(string: "https://gitlab.com/acme/preloaded"))
        )
        let snapshot = ChangeRequestSnapshot(
            summary: ChangeRequestSummary(
                key: key, repository: repository, title: "t", author: Person(remoteID: "1", username: "a"),
                sourceBranch: "f", targetBranch: "main", createdAt: Date(), updatedAt: Date(), webURL: mrURL
            ),
            fetchedAt: Date()
        )
        LinkPreloader.remember(snapshot)
        #expect(provider.deepLink(to: .changeRequest(key)) == mrURL)
    }
}
