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
        // Pinned value: changing the id scheme silently would orphan stored rows and MCP references.
        #expect(ShortID.make(prefix: "cr_", from: "v1/github/github.com/u:123/r:456/cr:789")
            == "cr_" + ContentDigest.sha256Hex("v1/github/github.com/u:123/r:456/cr:789").prefix(10))
        #expect(ContentDigest.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
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
