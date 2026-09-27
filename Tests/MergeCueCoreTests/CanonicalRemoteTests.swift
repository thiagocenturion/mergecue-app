import Foundation
import MergeCueCore
import Testing

@Suite("CanonicalRemote")
struct CanonicalRemoteTests {
    @Test(arguments: [
        "https://github.com/Acme/Repo.git",
        "https://github.com/acme/repo",
        "https://github.com/acme/repo/",
        "https://github.com/acme/repo.git/",
        "http://github.com/acme/repo",
        "HTTPS://GITHUB.COM/ACME/REPO.GIT",
        "https://x-access-token:ghp_abcdefghijklmnopqrstuvwxyz@github.com/acme/repo.git",
        "git@github.com:acme/repo.git",
        "git@github.com:acme/repo",
        "git@github.com:/acme/repo.git",
        "github.com:acme/repo.git",
        "ssh://git@github.com:22/acme/repo",
        "ssh://git@github.com/acme/repo.git",
        "ssh://git@ssh.github.com:443/acme/repo.git",
        "git+ssh://git@github.com/acme/repo.git",
        "git://github.com/acme/repo.git",
        "  https://github.com/acme/repo.git\n",
        "https://github.com/acme/repo?tab=readme#top",
        "https://github.com//acme//repo",
    ])
    func githubVariantsCanonicalizeToTheSameValue(_ url: String) throws {
        let remote = try #require(CanonicalRemote.parse(url), "failed to parse \(url)")
        #expect(remote == CanonicalRemote(host: "github.com", path: "acme/repo"))
        #expect(remote.description == "github.com/acme/repo")
    }

    @Test func gitlabNestedGroupsAndUserInfo() throws {
        let https = try #require(CanonicalRemote.parse("https://user:token@gitlab.com/group/sub/proj.git"))
        #expect(https.host == "gitlab.com")
        #expect(https.path == "group/sub/proj")
        #expect(!https.description.contains("token"))
        #expect(!https.description.contains("user"))
        #expect(https.namespace == "group/sub")
        #expect(https.name == "proj")

        let ssh = try #require(CanonicalRemote.parse("git@gitlab.com:Group/Sub/Proj.git"))
        #expect(ssh == https)
        let web = try #require(CanonicalRemote.parse("https://gitlab.com/group/sub/proj/-/merge_requests/7"))
        #expect(web == https)
        let selfManaged = try #require(CanonicalRemote.parse("ssh://git@gitlab.example.com:2222/team/app.git"))
        #expect(selfManaged == CanonicalRemote(host: "gitlab.example.com", path: "team/app"))
        #expect(CanonicalRemote.parse("https://gitlab.example.com:8443/team/app") == selfManaged)
    }

    @Test func bitbucketVariants() throws {
        let expected = CanonicalRemote(host: "bitbucket.org", path: "ws/repo")
        #expect(CanonicalRemote.parse("git@bitbucket.org:ws/repo.git") == expected)
        #expect(CanonicalRemote.parse("https://mona@bitbucket.org/ws/repo.git") == expected)
        #expect(CanonicalRemote.parse("https://x-token-auth:secret@bitbucket.org/WS/Repo") == expected)
        #expect(CanonicalRemote.parse("https://bitbucket.org/ws/repo/pull-requests/42") != expected, "web sub-paths are not repository paths")
    }

    @Test func differentHostsOrPathsDiffer() {
        #expect(CanonicalRemote.parse("git@github.com:acme/repo.git") != CanonicalRemote.parse("git@gitlab.com:acme/repo.git"))
        #expect(CanonicalRemote.parse("git@github.com:acme/repo.git") != CanonicalRemote.parse("git@github.com:fork/repo.git"))
    }

    @Test(arguments: [
        "",
        "   ",
        "/Users/mona/src/repo",
        "./repo",
        "../repo.git",
        "file:///Users/mona/src/repo.git",
        "ftp://github.com/acme/repo",
        "https://github.com",
        "https://github.com/",
        "https://github.com/acme",
        "git@github.com:repo.git",
        "git@github.com:",
        "https://github.com/acme/../repo",
        "https:///acme/repo",
        "C:\\Users\\mona\\repo",
        "https://github.com/acme/re po",
        "https://-bad.com/acme/repo",
    ])
    func rejectsNonRemotes(_ url: String) {
        #expect(CanonicalRemote.parse(url) == nil)
    }

    @Test func candidatesForRepository() {
        let repository = Fixture.repository()
        let candidates = CanonicalRemote.candidates(for: repository)
        #expect(candidates == [CanonicalRemote(host: "github.com", path: "acme/payments-api")])
    }

    @Test func gitRemoteDerivesCanonicalValue() throws {
        let remote = GitRemote(name: "origin", fetchURL: "git@github.com:Acme/Payments-API.git")
        #expect(remote.canonical == CanonicalRemote(host: "github.com", path: "acme/payments-api"))
        #expect(try Fixture.roundTrip(remote) == remote)
    }
}
