import BitbucketCloudAdapter
import Foundation
import GitHubAdapter
import GitLabAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueIPC
import MergeCueNetworking
import Testing
@testable import MergeCueRuntime

@Suite("LiveProviderFactory and write capability policy")
struct ProviderFactoryAndPolicyTests {
    static func account(_ kind: ProviderKind, scopes: [String], writes: Bool = true) -> Account {
        let instance = ProviderInstance.default(for: kind)
        return Account(
            id: AccountKey(instance: instance, remoteUserID: "u1"), instance: instance, username: "mona-dev",
            authMethod: .personalAccessToken, grantedScopes: scopes, writesEnabled: writes, connectedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func githubWritesFollowTheTokenScopesNotTheStaticManifest() throws {
        // The static manifest (scopes unknown) marks writes `requiresWriteAccess(repo)`…
        #expect(!WriteCapabilityPolicy.staticManifest(for: .github).isUsable(.createReply))
        // …but an account whose token has `repo` can write, and fine-grained tokens (no scopes reported) are partial.
        let repo = WriteCapabilityPolicy.manifest(for: Self.account(.github, scopes: ["repo", "read:org"]))
        #expect(repo.support(for: .createReply) == .supported)
        #expect(repo.support(for: .resolveThread) == .supported)
        let fineGrained = WriteCapabilityPolicy.manifest(for: Self.account(.github, scopes: []))
        #expect(fineGrained.isUsable(.createReply))
        let readOnly = WriteCapabilityPolicy.manifest(for: Self.account(.github, scopes: ["read:org", "gist"]))
        #expect(readOnly.support(for: .createReply) == .requiresWriteAccess(scope: "repo"))
        // Reads are never affected.
        #expect(readOnly.isUsable(.readThreads))
    }

    @Test func gitlabAndBitbucketWritesNeedTheirWriteScopesWhenScopesAreKnown() {
        #expect(WriteCapabilityPolicy.manifest(for: Self.account(.gitlab, scopes: ["api", "read_user"])).isUsable(.createReply))
        #expect(WriteCapabilityPolicy.manifest(for: Self.account(.gitlab, scopes: [])).isUsable(.createReply))
        let readAPI = WriteCapabilityPolicy.manifest(for: Self.account(.gitlab, scopes: ["read_api"]))
        #expect(readAPI.support(for: .createReply) == .requiresWriteAccess(scope: "api"))
        #expect(readAPI.isUsable(.readFailureLog))
        #expect(WriteCapabilityPolicy.manifest(for: Self.account(.bitbucketCloud, scopes: [])).isUsable(.resolveThread))
        let bbRead = WriteCapabilityPolicy.manifest(for: Self.account(.bitbucketCloud, scopes: ["read:pullrequest:bitbucket"]))
        #expect(bbRead.support(for: .createReply) == .requiresWriteAccess(scope: "write:pullrequest:bitbucket"))
        #expect(WriteCapabilityPolicy.manifest(for: Self.account(.bitbucketCloud, scopes: ["write:pullrequest:bitbucket"])).isUsable(.createReply))
    }

    @Test func factoryBuildsTheRealAdaptersWithAccountScopes() throws {
        let stub = StubTransport(baseURL: ProviderInstance.githubCom.apiURL)
        let factory = LiveProviderFactory(transport: { _ in stub })
        let github = factory.makeProvider(account: Self.account(.github, scopes: ["repo"]), credential: .bearer("x"))
        #expect(github is GitHubProvider)
        // `requireCapability` (Core) does not reject GitHub writes for a token with `repo`.
        try github.requireCapability(.createReply)
        try github.requireCapability(.resolveThread)
        // A probe (no account yet) uses the static manifest.
        let probe = factory.makeProbe(instance: .githubCom, credential: .bearer("x"))
        #expect(throws: ProviderError.self) { try probe.requireCapability(.createReply) }
        #expect(factory.makeProvider(account: Self.account(.gitlab, scopes: []), credential: .bearer("x")) is GitLabProvider)
        #expect(factory.makeProvider(account: Self.account(.bitbucketCloud, scopes: []), credential: .bearer("x")) is BitbucketCloudProvider)
        #expect(factory.capabilities(for: Self.account(.github, scopes: ["repo"])).isUsable(.createReply))
    }

    /// Request accounting (DECISIONS D35): account providers record every HTTP response except 304s; probes do not.
    @Test func accountProvidersCountTheirRequests() async throws {
        let stub = StubTransport(routes: [
            StubTransport.Route(method: "GET", pathPattern: "/user") { _, _ in
                StubTransport.json(#"{"id": 1, "login": "mona-dev"}"#, headers: ["X-OAuth-Scopes": "repo"])
            },
        ], baseURL: ProviderInstance.githubCom.apiURL)
        let clock = TestClock()
        let factory = LiveProviderFactory(clock: clock, transport: { _ in stub })
        let account = Self.account(.github, scopes: ["repo"])
        _ = try await factory.makeProvider(account: account, credential: .bearer("x")).currentUser()
        _ = try await factory.makeProvider(account: account, credential: .bearer("x")).currentUser()
        _ = try await factory.makeProbe(instance: .githubCom, credential: .bearer("x")).currentUser()
        #expect(factory.requestLedger.count(account.id, now: clock.now) == 2)
        #expect(stub.requests.count == 3)
    }
}

@Suite("IPC peer validation policy and helper lookup")
struct RuntimeIPCTests {
    @Test func unsignedBuildsFallBackToUidAndToken() throws {
        let (validator, description) = try RuntimeIPC.peerValidator(for: .automatic, currentTeamIdentifier: nil)
        #expect(validator == nil)
        #expect(description.contains("uid + token only"))
        #expect(try RuntimeIPC.peerValidator(for: .disabled, currentTeamIdentifier: "TTSKDZ455K").validator == nil)
    }

    @Test func signedBuildsRequireTheBundledHelper() throws {
        let requirement = RuntimeIPC.helperRequirement()
        #expect(requirement == #"anchor apple generic and certificate leaf[subject.OU] = "TTSKDZ455K" and identifier "com.thiagocenturion.MergeCue.mcp""#)
        let (validator, description) = try RuntimeIPC.peerValidator(for: .automatic, currentTeamIdentifier: "TTSKDZ455K")
        let compiled = try #require(validator as? CodeSignaturePeerValidator)
        #expect(compiled.requirementText == requirement)
        #expect(description.contains(requirement))
        #expect(throws: (any Error).self) { try RuntimeIPC.peerValidator(for: .requirement("this is not a requirement ((")) }
    }

    @Test func helperIsFoundInsideAnAppBundleFirst() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcrt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "MergeCue.app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.fake", "CFBundleExecutable": "MergeCue", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        for name in ["MergeCue", "mergecue-mcp"] {
            let file = macOS.appending(path: name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }
        let bundle = try #require(Bundle(url: app))
        let found = MCPHelperLocator.locate(bundle: bundle, environment: [:], packageRoot: nil)
        #expect(found?.lastPathComponent == "mergecue-mcp")
        #expect(found?.path(percentEncoded: false).contains("MergeCue.app/Contents/MacOS") == true)
        // Development fallback: the package's build directory.
        let candidates = MCPHelperLocator.candidates(bundle: .main, environment: [:], packageRoot: URL(filePath: "/pkg"))
        #expect(candidates.map { $0.path(percentEncoded: false) }.contains("/pkg/.build/debug/mergecue-mcp"))
        // Explicit override wins.
        let overridden = MCPHelperLocator.candidates(bundle: bundle, environment: ["MERGECUE_MCP_HELPER": "/x/mergecue-mcp"], packageRoot: nil)
        #expect(overridden.first?.path(percentEncoded: false) == "/x/mergecue-mcp")
    }
}
