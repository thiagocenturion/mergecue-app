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
        "C:/Users/mona/repo",
        "c:/Users/mona/repo.git",
        // Malformed userinfo (a password containing "/") must not yield a garbage remote that leaks it.
        "https://user:ab/cd@github.com/acme/repo",
        "https://user:a/b/c@github.com/acme/repo",
    ])
    func rejectsNonRemotes(_ url: String) {
        #expect(CanonicalRemote.parse(url) == nil)
    }

    @Test func sshAliasesWithUnderscoresAndResolvers() throws {
        let alias = try #require(CanonicalRemote.parse("git@github_work:acme/repo.git"))
        #expect(alias == CanonicalRemote(host: "github_work", path: "acme/repo"))
        #expect(CanonicalRemote.parse("git@github-work:acme/repo.git")?.host == "github-work")

        // ~/.ssh/config aliases resolve to the real host (WorkspaceInspector feeds `ssh -G` output here).
        let aliases = ["github-work": "github.com", "github_work": "ssh.github.com"]
        let resolved = CanonicalRemote.parse("git@github-work:Acme/Repo.git", resolvingHost: { aliases[$0] })
        #expect(resolved == CanonicalRemote(host: "github.com", path: "acme/repo"))
        #expect(CanonicalRemote.parse("git@github_work:acme/repo.git", resolvingHost: { aliases[$0] })?.host == "github.com")
        #expect(CanonicalRemote.parse("ssh://git@GitHub-Work:22/acme/repo", resolvingHost: { aliases[$0] })?.host == "github.com")
        #expect(CanonicalRemote.parse("https://github.com/acme/repo", resolvingHost: { _ in nil }) == resolved)
    }

    // MARK: Sanitizing

    @Test(arguments: [
        ("https://user:TOKEN123@github.com/acme/repo.git", "https://github.com/acme/repo.git"),
        ("https://x9f8Z2kLmQ7vR4tY1uW3@bitbucket.org/acme/api.git", "https://bitbucket.org/acme/api.git"),
        ("https://mona@bitbucket.org/ws/repo.git", "https://bitbucket.org/ws/repo.git"),
        ("HTTP://oauth2:glpat-abcdefghijklmnopqrst@gitlab.example.com:8443/g/p", "HTTP://gitlab.example.com:8443/g/p"),
        ("https://user:p@ss@github.com/acme/repo", "https://github.com/acme/repo"),
        ("https://user:ab/cd@github.com/acme/repo", "https://github.com/acme/repo"),
        ("ssh://git:hunter2@github.com:22/acme/repo.git", "ssh://git@github.com:22/acme/repo.git"),
        ("ssh://git@github.com/acme/repo.git", "ssh://git@github.com/acme/repo.git"),
        ("git+ssh://deploy@host/acme/repo", "git+ssh://deploy@host/acme/repo"),
        ("ssh://tok@en:pw@host/acme/repo", "ssh://host/acme/repo"),
        ("git@github.com:acme/repo.git", "git@github.com:acme/repo.git"),
        ("https://github.com/acme/repo.git", "https://github.com/acme/repo.git"),
        ("https://gitlab.com/g/p.git?private_token=abc123secret", "https://gitlab.com/g/p.git?private_token=[REDACTED]"),
        ("  https://token@github.com/a/b  ", "https://github.com/a/b"),
    ])
    func sanitizedURLDropsCredentials(_ raw: String, expected: String) {
        let sanitized = CanonicalRemote.sanitizedURL(raw)
        #expect(sanitized == expected)
        #expect(CanonicalRemote.sanitizedURL(sanitized) == sanitized, "idempotent")
    }

    @Test func gitRemoteNeverStoresCredentials() throws {
        let remote = GitRemote(
            name: "origin",
            fetchURL: "https://x-access-token:ghs_16C7e42F292c6912E7710c838347Ae178B4a@github.com/Acme/API.git",
            pushURL: "https://x9f8Z2kLmQ7vR4tY1uW3@github.com/acme/api.git"
        )
        #expect(remote.fetchURL == "https://github.com/Acme/API.git")
        #expect(remote.pushURL == "https://github.com/acme/api.git")
        #expect(remote.canonical == CanonicalRemote(host: "github.com", path: "acme/api"))
        #expect(try Fixture.roundTrip(remote) == remote)

        // Values persisted by an older build are sanitized when read.
        let legacy = #"{"name":"origin","fetchURL":"https://mona:hunter2@github.com/acme/api.git"}"#
        let decoded = try Fixture.decode(GitRemote.self, from: legacy)
        #expect(decoded.fetchURL == "https://github.com/acme/api.git")
        #expect(decoded.pushURL == nil)
    }

    @Test func mappingsStoreSanitizedRemotes() {
        var mapping = RepoMapping(
            id: "map_1", repo: Fixture.repoKey(), repoFullPath: "acme/payments-api", checkoutPath: "/src/api",
            confidence: .exact, matchedRemote: "https://mona:hunter2@github.com/acme/payments-api.git", createdAt: Fixture.date
        )
        #expect(mapping.matchedRemote == "https://github.com/acme/payments-api.git")
        mapping.matchedRemote = "https://abcDEF1234567890xyz@github.com/acme/payments-api.git"
        #expect(mapping.matchedRemote == "https://github.com/acme/payments-api.git")

        var suggestion = MappingSuggestion(checkoutPath: "/src/api", confidence: .probable, matchedRemote: "https://u:p4ss@h.io/a/b", reason: "name")
        #expect(suggestion.matchedRemote == "https://h.io/a/b")
        suggestion.matchedRemote = nil
        #expect(suggestion.matchedRemote == nil)
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
