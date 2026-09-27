import CryptoKit
import Foundation
import MergeCueCore
import Testing

@Suite("Identity keys and short IDs")
struct IdentityTests {
    @Test func stableIDsFollowTheVersionedFormat() {
        let key = Fixture.changeRequestKey()
        #expect(Fixture.githubAccount.id == "v1/github/github.com/u:123")
        #expect(key.repo.id == "v1/github/github.com/u:123/r:456")
        #expect(key.id == "v1/github/github.com/u:123/r:456/cr:789")

        let thread = ThreadKey(changeRequest: key, remoteID: "ic:991", kind: .conversation)
        #expect(thread.id == "v1/github/github.com/u:123/r:456/cr:789/th:conversation:ic%3A991")

        let check = CheckKey(changeRequest: key, source: .githubCheckRun, remoteID: "555")
        #expect(check.id == "v1/github/github.com/u:123/r:456/cr:789/ck:githubCheckRun:555")
    }

    @Test func componentsArePercentEncoded() {
        #expect(StableID.encode("acme/api") == "acme%2Fapi")
        #expect(StableID.encode("{abc-DEF}") == "%7Babc-DEF%7D")
        #expect(StableID.encode("a b:c") == "a%20b%3Ac")
        #expect(StableID.encode("ünï") == "%C3%BCn%C3%AF")
        #expect(StableID.encode("Az09-._~") == "Az09-._~")
        #expect(StableID.decode(StableID.encode("x/y:z é")) == "x/y:z é")

        let bitbucket = RepoKey(account: Fixture.bitbucketAccount, remoteRepoID: "{repo-uuid}")
        #expect(bitbucket.id == "v1/bitbucket_cloud/bitbucket.org/u:%7Bb1c2%7D/r:%7Brepo-uuid%7D")
    }

    @Test func separatorsInsideComponentsCannotCollide() {
        let a = RepoKey(account: AccountKey(kind: .github, host: "github.com", remoteUserID: "1/r:2"), remoteRepoID: "3")
        let b = RepoKey(account: AccountKey(kind: .github, host: "github.com", remoteUserID: "1"), remoteRepoID: "2/r:3")
        #expect(a.id != b.id)
        #expect(a.shortID != b.shortID)
    }

    @Test func sameNumberOnDifferentProvidersYieldsDistinctIdentities() {
        let github = Fixture.changeRequestKey(Fixture.githubAccount)
        let gitlab = Fixture.changeRequestKey(Fixture.gitlabAccount)
        let bitbucket = Fixture.changeRequestKey(Fixture.bitbucketAccount)
        let selfManaged = Fixture.changeRequestKey(AccountKey(kind: .gitlab, host: "gitlab.example.com", remoteUserID: "123"))
        let ids = Set([github.id, gitlab.id, bitbucket.id, selfManaged.id])
        let shortIDs = Set([github.shortID, gitlab.shortID, bitbucket.shortID, selfManaged.shortID])
        #expect(ids.count == 4)
        #expect(shortIDs.count == 4)
        #expect(github.number == gitlab.number)
    }

    @Test func shortIDsArePrefixPlusTenHexOfSHA256() {
        let key = Fixture.changeRequestKey()
        let digest = SHA256.hash(data: Data(key.id.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(key.shortID == "cr_" + digest.prefix(10))
        #expect(ShortID.make(prefix: "cr_", from: key.id) == key.shortID)

        let thread = ThreadKey(changeRequest: key, remoteID: "PRRT_x", kind: .diffThread)
        let check = CheckKey(changeRequest: key, source: .gitlabJob, remoteID: "77")
        #expect(thread.shortID.hasPrefix("thr_"))
        #expect(check.shortID.hasPrefix("chk_"))
        #expect(key.repo.shortID.hasPrefix("repo_"))
        for (value, prefix) in [(key.shortID, "cr_"), (thread.shortID, "thr_"), (check.shortID, "chk_")] {
            #expect(ShortID.isValid(value, prefix: prefix))
            #expect(value.count == prefix.count + 10)
        }
    }

    @Test func shortIDsAreStableAcrossRuns() {
        // Pinned literals: changing the id scheme silently would orphan stored rows and MCP references.
        #expect(ShortID.make(prefix: "cr_", from: "v1/github/github.com/u:123/r:456/cr:789") == "cr_7d5304b264")
        #expect(Fixture.changeRequestKey().shortID == "cr_7d5304b264")
        #expect(ContentDigest.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: Equality agrees with the stable id

    @Test func changeRequestKeysCompareByPrimaryKeyNotNumber() {
        let key = Fixture.changeRequestKey(number: 42)
        let placeholder = Fixture.changeRequestKey(number: 0)
        #expect(key == placeholder)
        #expect(key.id == placeholder.id && key.shortID == placeholder.shortID)
        #expect(Set([key, placeholder]).count == 1)
        #expect([key: "row"][placeholder] == "row")
        #expect(key != Fixture.changeRequestKey(remoteID: "790", number: 42), "same number, different remote id")

        // Derived keys follow: a thread/check rebuilt from a placeholder key still finds the snapshot's objects.
        let thread = ThreadKey(changeRequest: key, remoteID: "PRRT_1", kind: .diffThread)
        #expect(thread == ThreadKey(changeRequest: placeholder, remoteID: "PRRT_1", kind: .diffThread))
        #expect(CheckKey(changeRequest: key, source: .githubCheckRun, remoteID: "5") == CheckKey(changeRequest: placeholder, source: .githubCheckRun, remoteID: "5"))
        let snapshot = ChangeRequestSnapshot(
            summary: Fixture.summary(key),
            threads: [ReviewThread(key: thread, isResolvable: true, comments: [], lastActivityAt: Fixture.date)],
            fetchedAt: Fixture.date
        )
        #expect(snapshot.thread(ThreadKey(changeRequest: placeholder, remoteID: "PRRT_1", kind: .diffThread)) != nil)
    }

    /// Canonically equivalent strings (NFC vs NFD) compare `==` in Swift, so their ids must match as well.
    @Test func canonicallyEquivalentComponentsShareTheirID() {
        let nfc = "caf\u{E9}"
        let nfd = "cafe\u{301}"
        #expect(nfc == nfd)
        #expect(StableID.encode(nfc) == StableID.encode(nfd))
        let a = AccountKey(kind: .gitlab, host: "gitlab.com", remoteUserID: nfc)
        let b = AccountKey(kind: .gitlab, host: "gitlab.com", remoteUserID: nfd)
        #expect(a == b)
        #expect(a.id == b.id)
        #expect(Set([a, b]).count == 1)
        #expect(RepoKey(account: a, remoteRepoID: nfd).id == RepoKey(account: b, remoteRepoID: nfc).id)
    }

    @Test(arguments: [
        (Fixture.changeRequestKey(), Fixture.changeRequestKey(number: 7)),
        (Fixture.changeRequestKey(), Fixture.changeRequestKey(Fixture.gitlabAccount)),
        (Fixture.changeRequestKey(), Fixture.changeRequestKey(repoID: "457")),
        (Fixture.changeRequestKey(remoteID: "caf\u{E9}"), Fixture.changeRequestKey(remoteID: "cafe\u{301}")),
    ])
    func equalityMatchesIDs(_ lhs: ChangeRequestKey, _ rhs: ChangeRequestKey) {
        #expect((lhs == rhs) == (lhs.id == rhs.id))
        #expect((lhs.hashValue == rhs.hashValue) || lhs != rhs)
    }

    // MARK: GitHub thread conventions and namespaced event objects

    @Test func githubThreadHelpers() {
        let key = Fixture.changeRequestKey()
        let issue = ThreadKey.githubIssueComment(changeRequest: key, commentID: "991")
        #expect(issue.remoteID == "ic:991")
        #expect(issue.kind == .conversation)
        #expect(issue.id == "v1/github/github.com/u:123/r:456/cr:789/th:conversation:ic%3A991")
        let review = ThreadKey.githubReviewSummary(changeRequest: key, reviewID: "991")
        #expect(review.remoteID == ThreadKey.githubReviewSummaryPrefix + "991")
        #expect(review.kind == .reviewSummary)
        #expect(issue != review)
    }

    /// An issue comment and a diff review comment with the same numeric id and version on one PR must yield two
    /// distinct events.
    @Test func namespacedObjectIDsKeepEventsApart() {
        let key = Fixture.changeRequestKey()
        let issueThread = ThreadKey.githubIssueComment(changeRequest: key, commentID: "1001")
        let diffThread = ThreadKey(changeRequest: key, remoteID: "PRRT_kw", kind: .diffThread)
        let objectIDs = [
            ChangeEvent.commentObjectID(thread: issueThread, commentID: "1001"),
            ChangeEvent.commentObjectID(thread: diffThread, commentID: "1001"),
            ChangeEvent.reviewObjectID("1001"),
            ChangeEvent.headObjectID(sha: "1001"),
            ChangeEvent.checkObjectID(CheckKey(changeRequest: key, source: .githubCheckRun, remoteID: "1001")),
            ChangeEvent.checkObjectID(CheckKey(changeRequest: key, source: .githubStatus, remoteID: "1001")),
        ]
        #expect(Set(objectIDs).count == objectIDs.count)
        let eventIDs = objectIDs.map {
            ChangeEvent.makeID(account: key.account, changeRequest: key, type: .reviewComment, objectID: $0, objectVersion: "2026-01-01T00:00:00Z")
        }
        #expect(Set(eventIDs).count == eventIDs.count)
        #expect(ChangeEvent.commentObjectID(thread: diffThread, commentID: "a/b") == diffThread.id + "/c:a%2Fb")
    }

    @Test func ipv6InstanceHostKeepsBrackets() {
        let instance = ProviderInstance(kind: .gitlab, webURL: URL(string: "https://[::1]:8443")!, apiURL: URL(string: "https://[::1]:8443/api/v4")!)
        #expect(instance.host == "[::1]:8443")
        let defaultPort = ProviderInstance(kind: .gitlab, webURL: URL(string: "https://[fd00::2]")!, apiURL: URL(string: "https://[fd00::2]/api/v4")!)
        #expect(defaultPort.host == "[fd00::2]")
        #expect(AccountKey(instance: instance, remoteUserID: "1").host == "[::1]:8443")
    }

    @Test(arguments: ["cr_0123456789", "cr_abcdefabcd"])
    func validShortIDs(_ value: String) {
        #expect(ShortID.isValid(value, prefix: "cr_"))
    }

    @Test(arguments: ["cr_012345678", "cr_0123456789a", "cr_ABCDEF0123", "thr_0123456789", "cr_01234567g9", ""])
    func invalidShortIDs(_ value: String) {
        #expect(!ShortID.isValid(value, prefix: "cr_"))
    }

    @Test func accountKeyNormalizesHostAndOrders() throws {
        let key = AccountKey(kind: .gitlab, host: "GitLab.Example.COM", remoteUserID: "7")
        #expect(key.host == "gitlab.example.com")
        let decoded = try Fixture.decode(AccountKey.self, from: #"{"kind":"gitlab","host":"GITLAB.com","remoteUserID":"7"}"#)
        #expect(decoded.host == "gitlab.com")
        #expect([Fixture.gitlabAccount, Fixture.githubAccount].sorted() == [Fixture.githubAccount, Fixture.gitlabAccount])
        #expect(AccountKey(instance: .githubCom, remoteUserID: "123") == Fixture.githubAccount)
    }

    @Test func keysRoundTripThroughJSON() throws {
        let key = Fixture.changeRequestKey(Fixture.bitbucketAccount)
        let thread = ThreadKey(changeRequest: key, remoteID: "55", kind: .reviewSummary)
        let check = CheckKey(changeRequest: key, source: .bitbucketPipelineStep, remoteID: "{step}")
        #expect(try Fixture.roundTrip(key) == key)
        #expect(try Fixture.roundTrip(thread) == thread)
        #expect(try Fixture.roundTrip(check) == check)
        #expect(try Fixture.roundTrip(thread).id == thread.id)
    }

    @Test func providerKindVocabulary() {
        #expect(ProviderKind.github.displayName == "GitHub")
        #expect(ProviderKind.gitlab.displayName == "GitLab")
        #expect(ProviderKind.bitbucketCloud.displayName == "Bitbucket Cloud")
        #expect(ProviderKind.bitbucketCloud.rawValue == "bitbucket_cloud")
        #expect(ProviderKind.github.changeRequestNoun == "pull request")
        #expect(ProviderKind.gitlab.changeRequestNoun == "merge request")
        #expect(ProviderKind.bitbucketCloud.changeRequestAbbreviation == "PR")
        #expect(ProviderKind.gitlab.changeRequestAbbreviation == "MR")
        #expect(ProviderKind.github.numberPrefix == "#")
        #expect(ProviderKind.bitbucketCloud.numberPrefix == "#")
        #expect(ProviderKind.gitlab.numberPrefix == "!")
        #expect(ProviderKind.gitlab.formattedNumber(7) == "!7")
    }

    @Test func hostedInstances() {
        #expect(ProviderInstance.githubCom.host == "github.com")
        #expect(ProviderInstance.githubCom.apiURL.absoluteString == "https://api.github.com")
        #expect(ProviderInstance.gitlabCom.apiURL.absoluteString == "https://gitlab.com/api/v4")
        #expect(ProviderInstance.bitbucketCloud.host == "bitbucket.org")
        #expect(ProviderInstance.bitbucketCloud.apiURL.absoluteString == "https://api.bitbucket.org/2.0")
        for kind in ProviderKind.allCases {
            #expect(kind.defaultInstance.kind == kind)
            #expect(kind.defaultInstance.isHostedService)
        }
    }

    @Test func selfManagedInstanceHostKeepsNonDefaultPort() {
        let custom = ProviderInstance(
            kind: .gitlab,
            webURL: URL(string: "https://GitLab.Example.com:8443")!,
            apiURL: URL(string: "https://gitlab.example.com:8443/api/v4")!
        )
        #expect(custom.host == "gitlab.example.com:8443")
        #expect(!custom.isHostedService)
        let defaultPort = ProviderInstance(kind: .github, webURL: URL(string: "https://ghe.corp:443")!, apiURL: URL(string: "https://ghe.corp/api/v3")!)
        #expect(defaultPort.host == "ghe.corp")
    }
}
