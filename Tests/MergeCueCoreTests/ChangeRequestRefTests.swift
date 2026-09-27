import Foundation
import MergeCueCore
import Testing

@Suite("ChangeRequestRef")
struct ChangeRequestRefTests {
    @Test(arguments: [
        "github:github.com/acme/api#42",
        "gitlab:gitlab.com/acme/api!42",
        "bitbucket_cloud:bitbucket.org/acme/api#42",
        "gitlab:gitlab.com/group/sub/deeper/project!7",
        "gitlab:gitlab.example.com:8443/acme/api!1",
        "github:github.com/acme-inc/payments.api_v2#123456",
        "gitlab:git_lab.corp/team/app!3",
        "gitlab:[::1]:8443/acme/api!7",
        "github:[fd00::2]/acme/api#1",
        "gitlab:gitlab.com/group/sub/proj%20x!9",
    ])
    func roundTrips(_ string: String) throws {
        let ref = try #require(ChangeRequestRef(string: string))
        #expect(ref.string == string)
        #expect(ref.description == string)
        #expect(ChangeRequestRef(ref.string) == ref)
    }

    @Test func parsesComponents() throws {
        let gitlab = try #require(ChangeRequestRef(string: "gitlab:gitlab.com/group/sub/api!42"))
        #expect(gitlab.kind == .gitlab)
        #expect(gitlab.host == "gitlab.com")
        #expect(gitlab.repoFullPath == "group/sub/api")
        #expect(gitlab.number == 42)
        #expect(gitlab.shortLabel == "group/sub/api!42")

        let bitbucket = try #require(ChangeRequestRef(string: "bitbucket_cloud:bitbucket.org/ws/repo#9"))
        #expect(bitbucket.kind == .bitbucketCloud)
        #expect(bitbucket.number == 9)
    }

    @Test func sameNumberDifferentProvidersAreDistinct() throws {
        let a = try #require(ChangeRequestRef(string: "github:github.com/acme/api#42"))
        let b = try #require(ChangeRequestRef(string: "bitbucket_cloud:bitbucket.org/acme/api#42"))
        let c = try #require(ChangeRequestRef(string: "gitlab:gitlab.com/acme/api!42"))
        #expect(Set([a, b, c]).count == 3)
    }

    @Test(arguments: [
        "",
        "github",
        "github:",
        "github:github.com",
        "github:github.com/acme/api",
        "github:github.com/acme/api#",
        "github:github.com/acme/api#0",
        "github:github.com/acme/api#-1",
        "github:github.com/acme/api#042",
        "github:github.com/acme/api#4x2",
        "github:github.com/acme/api#+42",
        "github:github.com/acme/api!42",
        "gitlab:gitlab.com/acme/api#42",
        "bitbucket_cloud:bitbucket.org/acme/api!42",
        "bitbucket:bitbucket.org/acme/api#42",
        "gitHub:github.com/acme/api#42",
        "github:/acme/api#42",
        "github:github.com/api#42",
        "github:github.com//api#42",
        "github:github.com/acme//api#42",
        "github:github.com/acme/api/#42",
        "github:github.com/acme/../api#42",
        "github:github.com/acme/a pi#42",
        "github: github.com/acme/api#42",
        "github:github.com/acme/api#42 ",
        "github:git hub.com/acme/api#42",
        "github:github.com:/acme/api#42",
        "github:github.com:99999x/acme/api#42",
        "github:.github.com/acme/api#42",
        "github:github.com/acme/api#99999999999999999999999",
        "https://github.com/acme/api/pull/42",
        "gitlab:[::1/acme/api!7",
        "gitlab:[::1]x/acme/api!7",
        "gitlab:[fe80::1%25en0]/acme/api!7",
        "gitlab:[]/acme/api!7",
        "gitlab:gitlab.com/acme/a#b!7",
        "github:github.com/acme/a!b#7",
        "github:github.com/acme/a\u{7}b#7",
    ])
    func rejectsMalformed(_ string: String) {
        #expect(ChangeRequestRef(string: string) == nil)
    }

    @Test func normalizesHostCase() throws {
        let ref = try #require(ChangeRequestRef(string: "github:GitHub.com/Acme/API#5"))
        #expect(ref.host == "github.com")
        #expect(ref.repoFullPath == "Acme/API")
        #expect(ref.string == "github:github.com/Acme/API#5")
    }

    @Test func summaryBuildsRef() {
        let github = Fixture.summary()
        #expect(github.ref.string == "github:github.com/acme/payments-api#42")
        #expect(github.displayNumber == "#42")

        let gitlabKey = Fixture.changeRequestKey(Fixture.gitlabAccount, number: 7)
        let gitlab = Fixture.summary(gitlabKey, fullPath: "acme/platform/payments-api")
        #expect(gitlab.ref.string == "gitlab:gitlab.com/acme/platform/payments-api!7")
        #expect(gitlab.displayNumber == "!7")
    }

    /// Every ref built from a real summary can be written and read back (a TaskOrigin whose ref cannot be decoded
    /// would poison the task row).
    @Test(arguments: [
        (Fixture.githubAccount, "acme/payments-api", 42),
        (Fixture.gitlabAccount, "group/sub/deeper/payments-api", 7),
        (AccountKey(instance: ProviderInstance(kind: .gitlab, webURL: URL(string: "https://GitLab.Example.com:8443")!, apiURL: URL(string: "https://gitlab.example.com:8443/api/v4")!), remoteUserID: "5"), "team/app", 1),
        (AccountKey(kind: .gitlab, host: "git_lab.corp", remoteUserID: "5"), "team/app", 12),
        (AccountKey(instance: ProviderInstance(kind: .gitlab, webURL: URL(string: "https://[::1]:8443")!, apiURL: URL(string: "https://[::1]:8443/api/v4")!), remoteUserID: "5"), "team/app", 3),
        (Fixture.bitbucketAccount, "workspace/repo_slug.v2", 42),
    ])
    func summaryRefsRoundTrip(_ account: AccountKey, fullPath: String, number: Int) throws {
        let summary = Fixture.summary(Fixture.changeRequestKey(account, number: number), fullPath: fullPath)
        let ref = summary.ref
        #expect(ref.isValid)
        #expect(try Fixture.roundTrip(ref) == ref)
        #expect(ChangeRequestRef(string: ref.string) == ref)
        #expect(ChangeRequestRef.validated(kind: ref.kind, host: ref.host, repoFullPath: ref.repoFullPath, number: ref.number) == ref)
    }

    @Test func invalidRefsFailAtEncodeTimeNotDecodeTime() {
        let invalid = [
            ChangeRequestRef(kind: .github, host: "github.com", repoFullPath: "acme/api", number: 0),
            ChangeRequestRef(kind: .github, host: "github.com", repoFullPath: "api", number: 1),
            ChangeRequestRef(kind: .github, host: "github.com", repoFullPath: "acme/a pi", number: 1),
            ChangeRequestRef(kind: .gitlab, host: "gitlab.com", repoFullPath: "acme/a!pi", number: 1),
            ChangeRequestRef(kind: .github, host: "", repoFullPath: "acme/api", number: 1),
            ChangeRequestRef(kind: .github, host: "git hub.com", repoFullPath: "acme/api", number: 1),
            // A combining mark right after "/" would merge with it into one Character.
            ChangeRequestRef(kind: .github, host: "github.com", repoFullPath: "acme/\u{301}api", number: 1),
            ChangeRequestRef(kind: .github, host: "github.com", repoFullPath: "acme/api", number: -3),
        ]
        for ref in invalid {
            #expect(!ref.isValid, "\(ref.string)")
            #expect(ChangeRequestRef.validated(kind: ref.kind, host: ref.host, repoFullPath: ref.repoFullPath, number: ref.number) == nil)
            #expect(throws: EncodingError.self) { try Fixture.json(ref) }
        }
    }

    @Test func matchingIsCaseInsensitiveOnTheRepositoryPathOnly() throws {
        let typed = try #require(ChangeRequestRef(string: "github:GitHub.com/Acme/API#42"))
        let stored = try #require(ChangeRequestRef(string: "github:github.com/acme/api#42"))
        #expect(typed != stored, "== stays exact")
        #expect(typed.matches(stored) && stored.matches(typed))
        #expect(typed.normalizedKey == stored.normalizedKey)
        #expect(typed.normalizedKey == "github:github.com/acme/api#42")
        for other in ["github:github.com/acme/api#43", "bitbucket_cloud:bitbucket.org/acme/api#42", "github:ghe.corp/acme/api#42", "gitlab:gitlab.com/acme/api!42"] {
            let ref = try #require(ChangeRequestRef(string: other))
            #expect(!typed.matches(ref), "\(other)")
            #expect(typed.normalizedKey != ref.normalizedKey)
        }
    }

    @Test func encodesAsSingleString() throws {
        let ref = try #require(ChangeRequestRef(string: "gitlab:gitlab.com/acme/api!42"))
        #expect(try Fixture.json(ref) == #""gitlab:gitlab.com/acme/api!42""#)
        #expect(try Fixture.roundTrip(ref) == ref)
        #expect(throws: DecodingError.self) {
            try Fixture.decode(ChangeRequestRef.self, from: #""gitlab:gitlab.com/acme/api#42""#)
        }
    }
}
