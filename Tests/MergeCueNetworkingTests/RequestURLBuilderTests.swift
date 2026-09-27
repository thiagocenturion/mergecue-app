import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

@Suite("Request URL building")
struct RequestURLBuilderTests {
    @Test(arguments: [
        ("https://gitlab.com/api/v4", "/projects/1", "https://gitlab.com/api/v4/projects/1"),
        ("https://gitlab.com/api/v4", "projects/1", "https://gitlab.com/api/v4/projects/1"),
        ("https://gitlab.com/api/v4/", "/projects/1", "https://gitlab.com/api/v4/projects/1"),
        ("https://gitlab.com/api/v4//", "//projects/1", "https://gitlab.com/api/v4/projects/1"),
        ("https://api.github.com", "/repos/acme/api/pulls", "https://api.github.com/repos/acme/api/pulls"),
        ("https://api.github.com/", "user", "https://api.github.com/user"),
        ("https://api.bitbucket.org/2.0", "/user", "https://api.bitbucket.org/2.0/user"),
        ("https://ghe.example.com:8443/api/v3", "/user", "https://ghe.example.com:8443/api/v3/user"),
        ("https://gitlab.com/api/v4", "/projects/", "https://gitlab.com/api/v4/projects/"),
        ("https://gitlab.com/api/v4", "", "https://gitlab.com/api/v4"),
    ])
    func pathJoiningKeepsTheBasePathPrefix(base: String, path: String, expected: String) throws {
        let url = try RequestURLBuilder.url(baseURL: try #require(URL(string: base)), path: path)
        #expect(url.absoluteString == expected)
    }

    @Test func percentEncodedSegmentsArePreservedAndUnsafeCharactersEncoded() throws {
        let gitlab = try RequestURLBuilder.url(baseURL: NetFixture.gitlabAPI, path: "/projects/acme%2Fpayments-api/merge_requests/42")
        #expect(gitlab.absoluteString == "https://gitlab.com/api/v4/projects/acme%2Fpayments-api/merge_requests/42")

        let bitbucket = try RequestURLBuilder.url(baseURL: NetFixture.bitbucketAPI, path: "/workspaces/acme/pullrequests/{b1c2-d3}")
        #expect(bitbucket.absoluteString == "https://api.bitbucket.org/2.0/workspaces/acme/pullrequests/%7Bb1c2-d3%7D")

        let spaces = try RequestURLBuilder.url(baseURL: NetFixture.githubAPI, path: "/repos/a b/ü%zz")
        #expect(spaces.absoluteString == "https://api.github.com/repos/a%20b/%C3%BC%25zz")
    }

    @Test func pathSegmentEncodingEscapesSlashesAndBraces() {
        #expect(RequestURLBuilder.encodePathSegment("acme/payments-api") == "acme%2Fpayments-api")
        #expect(RequestURLBuilder.encodePathSegment("{b1c2}") == "%7Bb1c2%7D")
        #expect(RequestURLBuilder.encodePathSegment("feature/x+y z") == "feature%2Fx%2By%20z")
        #expect(RequestURLBuilder.encodePathSegment("a.b_c~d-e") == "a.b_c~d-e")
    }

    @Test(arguments: ["/projects/../admin", "/projects/./1", "/a/%2E%2E/b", "..", "/x/%2e"])
    func dotSegmentsAreRejected(path: String) {
        #expect(throws: ProviderError.self) {
            try RequestURLBuilder.url(baseURL: NetFixture.gitlabAPI, path: path)
        }
    }

    @Test func queryItemsAreStrictlyPercentEncoded() throws {
        let url = try RequestURLBuilder.url(
            baseURL: NetFixture.githubAPI,
            path: "/search/issues",
            query: [
                URLQueryItem(name: "q", value: "is:pr is:open author:@me"),
                URLQueryItem(name: "plus", value: "a+b"),
                URLQueryItem(name: "slash", value: "feature/x"),
                URLQueryItem(name: "amp", value: "a&b=c"),
                URLQueryItem(name: "hash", value: "#1?"),
                URLQueryItem(name: "unicode", value: "ü"),
                URLQueryItem(name: "flag", value: nil),
                URLQueryItem(name: "per_page", value: "100"),
            ]
        )
        #expect(url.absoluteString == "https://api.github.com/search/issues"
            + "?q=is%3Apr%20is%3Aopen%20author%3A%40me&plus=a%2Bb&slash=feature%2Fx&amp=a%26b%3Dc"
            + "&hash=%231%3F&unicode=%C3%BC&flag&per_page=100")

        // Round trip through URLComponents recovers the original values.
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "plus" }?.value == "a+b")
        #expect(items.first { $0.name == "slash" }?.value == "feature/x")
        #expect(items.first { $0.name == "amp" }?.value == "a&b=c")
    }

    @Test func queryItemNamesAreEncodedAndOrderIsPreserved() {
        let encoded = RequestURLBuilder.encodeQuery([
            URLQueryItem(name: "b", value: "2"),
            URLQueryItem(name: "a b", value: "1"),
            URLQueryItem(name: "labels[]", value: "x"),
        ])
        #expect(encoded == "b=2&a%20b=1&labels%5B%5D=x")
    }

    @Test func inlineQueryInPathIsKeptAndItemsAreAppended() throws {
        let url = try RequestURLBuilder.url(
            baseURL: NetFixture.bitbucketAPI,
            path: "/repositories/acme/api/pullrequests?state=OPEN",
            query: [URLQueryItem(name: "q", value: "reviewers.uuid=\"{u}\"")]
        )
        #expect(url.absoluteString
            == "https://api.bitbucket.org/2.0/repositories/acme/api/pullrequests?state=OPEN&q=reviewers.uuid%3D%22%7Bu%7D%22")
    }

    @Test func fragmentsAreDropped() throws {
        let url = try RequestURLBuilder.url(baseURL: NetFixture.githubAPI, path: "/user#section")
        #expect(url.absoluteString == "https://api.github.com/user")
    }

    @Test func clientResolvesSameOriginAbsoluteURLsAndRejectsOtherHosts() async throws {
        let client = NetFixture.client(transport: StubTransport(baseURL: NetFixture.gitlabAPI))
        let absolute = try client.url(
            for: "https://gitlab.com/api/v4/projects?page=2",
            query: [URLQueryItem(name: "per_page", value: "100")]
        )
        #expect(absolute.absoluteString == "https://gitlab.com/api/v4/projects?page=2&per_page=100")

        #expect(throws: ProviderError.self) { try client.url(for: "https://evil.example.com/api/v4/projects") }
        #expect(throws: ProviderError.self) { try client.url(for: "http://gitlab.com/api/v4/projects") }
        #expect(throws: ProviderError.self) { try client.url(for: "https://gitlab.com:444/api/v4/projects") }
    }
}
