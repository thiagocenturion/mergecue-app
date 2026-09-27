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

    @Test func encodesAsSingleString() throws {
        let ref = try #require(ChangeRequestRef(string: "gitlab:gitlab.com/acme/api!42"))
        #expect(try Fixture.json(ref) == #""gitlab:gitlab.com/acme/api!42""#)
        #expect(try Fixture.roundTrip(ref) == ref)
        #expect(throws: DecodingError.self) {
            try Fixture.decode(ChangeRequestRef.self, from: #""gitlab:gitlab.com/acme/api#42""#)
        }
    }
}
