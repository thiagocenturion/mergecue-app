import BitbucketCloudAdapter
import Foundation
import GitHubAdapter
import GitLabAdapter
import MergeCueCore
import MergeCueNetworking
import Synchronization

/// Demo mode's scripted world (**synthetic fixture data, always labeled, never live**): three demo accounts
/// (GitHub.com, GitLab.com, Bitbucket Cloud) served by the real adapters over `StubTransport` routes built from
/// `GitHubFixtures` / `GitLabFixtures` / `BitbucketFixtures`, plus the synthetic local repository
/// (`DemoRepository`) the fixtures' change request #42 points at.
///
/// Every manual refresh advances a provider's fixture step 0 → 1 → 2 (clamped):
/// - step 0 — baseline: open review threads, a failing check;
/// - step 1 — a new blocking review comment + a failing CI run arrive;
/// - step 2 — a reviewer reply + CI recovers.
/// Steps are persisted in `<directory>/demo-scenario.json`, so a relaunch continues where the owner left off.
public final class DemoScenario: Sendable {
    /// Where the scenario state and the synthetic repositories live (the demo data root).
    public let directory: URL
    public let repository: DemoRepository
    private let transports: [ProviderKind: DemoScenarioTransport]
    private let state: Mutex<PersistedState>

    struct PersistedState: Codable, Sendable, Hashable {
        var steps: [String: Int] = [:]
        /// Provider → head SHA after a simulated force-push.
        var movedHeads: [String: String] = [:]
    }

    public static let maxStep = 2
    static let stateFileName = "demo-scenario.json"

    /// Prepares the synthetic repository under `directory` (reused when present) and loads the persisted steps.
    public init(directory: URL, git: URL = URL(filePath: "/usr/bin/git")) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.repository = try DemoRepository.prepare(in: directory, git: git)
        let loaded = Self.load(from: directory.appending(path: Self.stateFileName)) ?? PersistedState()
        self.state = Mutex(loaded)
        var transports: [ProviderKind: DemoScenarioTransport] = [:]
        for kind in ProviderKind.allCases {
            let step = min(max(loaded.steps[kind.rawValue] ?? 0, 0), Self.maxStep)
            // The demo runs for days: remember every write (providerWrites) but only recent reads (bounded memory).
            let stub = StubTransport(
                routes: Self.routes(kind, step: step), baseURL: Self.instance(kind).apiURL,
                recording: .bounded(keeping: { Self.isWrite($0, kind: kind) }, recent: Self.recentReadsKept)
            )
            transports[kind] = DemoScenarioTransport(
                stub: stub,
                substitutions: Self.substitutions(kind, repository: repository, movedHead: loaded.movedHeads[kind.rawValue])
            )
        }
        self.transports = transports
    }

    // MARK: Accounts

    /// The three demo accounts (`isDemo`, remote writes off until the owner enables them).
    public static let accounts: [Account] = [githubAccount, gitlabAccount, bitbucketAccount]

    public static let githubAccount = GitHubFixtures.account

    public static let gitlabAccount = Account(
        id: GitLabFixtures.accountKey, instance: GitLabFixtures.instance, username: GitLabFixtures.user.username,
        displayName: GitLabFixtures.user.displayName, avatarURL: GitLabFixtures.user.avatarURL,
        authMethod: .personalAccessToken, grantedScopes: GitLabFixtures.user.grantedScopes, label: "GitLab (demo)",
        connectedAt: Date(timeIntervalSince1970: 1_790_000_000), isDemo: true
    )

    public static let bitbucketAccount = Account(
        id: BitbucketFixtures.accountKey, instance: BitbucketFixtures.instance, username: BitbucketFixtures.user.username,
        displayName: BitbucketFixtures.user.displayName, avatarURL: BitbucketFixtures.user.avatarURL,
        authMethod: .bitbucketAccessToken, grantedScopes: BitbucketFixtures.user.grantedScopes, label: "Bitbucket (demo)",
        connectedAt: Date(timeIntervalSince1970: 1_790_000_000), isDemo: true
    )

    /// Placeholder tokens for the stub transports (not secrets; they never leave the process).
    public static let credentials: [AccountKey: Credential] = [
        GitHubFixtures.accountKey: GitHubFixtures.credential,
        GitLabFixtures.accountKey: GitLabFixtures.credential,
        BitbucketFixtures.accountKey: .bearer("fixture-bitbucket-token"),
    ]

    public static func instance(_ kind: ProviderKind) -> ProviderInstance {
        switch kind {
        case .github: GitHubFixtures.instance
        case .gitlab: GitLabFixtures.instance
        case .bitbucketCloud: BitbucketFixtures.instance
        }
    }

    // MARK: Transports and steps

    /// The transport serving `kind`'s fixtures (inject into the real adapter).
    public func transport(for kind: ProviderKind) -> DemoScenarioTransport {
        // Every ProviderKind case gets a transport in `init`.
        transports[kind] ?? DemoScenarioTransport(stub: StubTransport(baseURL: Self.instance(kind).apiURL))
    }

    /// Current fixture step of `kind` (0…2).
    public func step(for kind: ProviderKind) -> Int {
        state.withLock { min(max($0.steps[kind.rawValue] ?? 0, 0), Self.maxStep) }
    }

    public var steps: [ProviderKind: Int] {
        Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { ($0, step(for: $0)) })
    }

    /// Advances `kinds` (default: all) by one step (clamped at 2) and persists it. Returns the new steps.
    @discardableResult
    public func advance(_ kinds: [ProviderKind] = ProviderKind.allCases) -> [ProviderKind: Int] {
        for kind in kinds {
            let next = state.withLock { state -> Int in
                let next = min((state.steps[kind.rawValue] ?? 0) + 1, Self.maxStep)
                state.steps[kind.rawValue] = next
                return next
            }
            transport(for: kind).stub.replaceRoutes(Self.routes(kind, step: next))
        }
        persist()
        return steps
    }

    /// Simulates a force-push of #42 on `kind`: the hosted head moves to a new commit (published in the bare
    /// repository) and every later API answer reports it. Pending previews then become stale.
    @discardableResult
    public func simulateForcePush(_ kind: ProviderKind) throws -> String {
        let refs: [String] = switch kind {
        case .github: ["refs/pull/42/head", "refs/heads/\(DemoRepository.sourceBranches[0])"]
        case .gitlab: ["refs/merge-requests/42/head", "refs/heads/\(DemoRepository.sourceBranches[1])"]
        case .bitbucketCloud: ["refs/heads/\(DemoRepository.sourceBranches[2])"]
        }
        let newHead = try repository.pushNewHead(refs: refs, message: "Force-pushed \(kind.displayName) head (demo)")
        state.withLock { $0.movedHeads[kind.rawValue] = newHead }
        transport(for: kind).setSubstitutions(Self.substitutions(kind, repository: repository, movedHead: newHead))
        persist()
        return newHead
    }

    /// Reads remembered per provider transport (writes are always kept).
    public static let recentReadsKept = 200

    /// Every write request (POST/PUT/PATCH/DELETE) the adapters sent for `kind`, in fixture terms.
    public func providerWrites(_ kind: ProviderKind) -> [HTTPRequest] {
        transport(for: kind).stub.requests.filter { Self.isWrite($0, kind: kind) }
    }

    /// GraphQL reads are POSTs on GitHub; only mutations count as writes.
    public static func isWrite(_ request: HTTPRequest, kind: ProviderKind) -> Bool {
        let method = request.method.uppercased()
        guard ["POST", "PUT", "PATCH", "DELETE"].contains(method) else { return false }
        if kind == .github, request.url.path.hasSuffix("/graphql") {
            let body = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return body.contains("mutation") || body.contains("MergeCueResolveThread") || body.contains("MergeCueUnresolveThread")
        }
        return true
    }

    // MARK: Fixtures

    static func routes(_ kind: ProviderKind, step: Int) -> [StubTransport.Route] {
        switch kind {
        case .github: GitHubFixtures.routes(step: step)
        case .gitlab: GitLabFixtures.routes(step: step)
        case .bitbucketCloud: BitbucketFixtures.routes(step: step)
        }
    }

    /// Fixture SHAs of #42 → the synthetic repository's commits.
    static func substitutions(_ kind: ProviderKind, repository: DemoRepository, movedHead: String?) -> [DemoScenarioTransport.Substitution] {
        let head = movedHead ?? repository.headSHA
        let base = repository.baseSHA
        typealias S = DemoScenarioTransport.Substitution
        switch kind {
        case .github:
            return [S(fixture: GitHubFixtures.IDs.head42, real: head), S(fixture: GitHubFixtures.IDs.base42, real: base)]
        case .gitlab:
            return [S(fixture: GitLabFixtures.IDs.head42, real: head), S(fixture: GitLabFixtures.IDs.base42, real: base)]
        case .bitbucketCloud:
            let fixtureHead = BitbucketFixtures.IDs.head42
            return [
                S(fixture: fixtureHead, real: head),
                S(fixture: String(fixtureHead.prefix(12)), real: String(head.prefix(12))),
                S(fixture: bitbucketBase42Short, real: String(base.prefix(12))),
            ]
        }
    }

    /// Destination commit of Bitbucket PR #42 in the fixtures (12-character hash).
    static let bitbucketBase42Short = "9c1e4d2b7a60"

    // MARK: Persistence

    private static func load(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private func persist() {
        let snapshot = state.withLock { $0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: directory.appending(path: Self.stateFileName), options: .atomic)
    }
}
