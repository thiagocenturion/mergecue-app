import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

@Suite("Link header pagination")
struct PaginationTests {
    @Test func gitHubStyleHeader() {
        let header = #"<https://api.github.com/repositories/1/pulls?page=2&per_page=100>; rel="next", <https://api.github.com/repositories/1/pulls?page=5&per_page=100>; rel="last""#
        #expect(Pagination.nextLink(fromLinkHeader: header)?.absoluteString == "https://api.github.com/repositories/1/pulls?page=2&per_page=100")
        #expect(Pagination.link(relation: "last", fromLinkHeader: header)?.absoluteString.hasSuffix("page=5&per_page=100") == true)
    }

    @Test func gitLabStyleHeaderWithNextNotFirst() {
        let header = #"<https://gitlab.com/api/v4/projects?id_after=10&page=1>; rel="first", <https://gitlab.com/api/v4/projects?page=3>; rel="next",<https://gitlab.com/api/v4/projects?page=9>; rel="last""#
        #expect(Pagination.nextLink(fromLinkHeader: header)?.absoluteString == "https://gitlab.com/api/v4/projects?page=3")
    }

    @Test(arguments: [
        #"<https://x.test/a?page=2>; rel=next"#,
        #"<https://x.test/a?page=2>;rel="next""#,
        #"<https://x.test/a?page=2> ; REL = "NEXT""#,
        #"<https://x.test/a?page=2>; rel="prev next""#,
        #"<https://x.test/a?page=2>; title="a, b; c"; rel="next""#,
        #"  <https://x.test/a?page=2>;\#trel="next"  "#,
        #"<https://x.test/a?page=1>; rel="prev", <https://x.test/a?page=2>; rel="next""#,
        #", , <https://x.test/a?page=2>; rel="next","#,
    ])
    func robustToFormattingVariants(header: String) {
        #expect(Pagination.nextLink(fromLinkHeader: header)?.absoluteString == "https://x.test/a?page=2")
    }

    @Test func commasAndSemicolonsInsideTheTarget() {
        let header = #"<https://x.test/a?ids=1,2,3;x=y&page=2>; rel="next", <https://x.test/a?ids=1,2,3&page=9>; rel="last""#
        #expect(Pagination.nextLink(fromLinkHeader: header)?.absoluteString == "https://x.test/a?ids=1,2,3;x=y&page=2")
    }

    @Test func onlyTheFirstRelParameterCounts() {
        let header = #"<https://x.test/a?page=2>; rel="prev"; rel="next""#
        #expect(Pagination.nextLink(fromLinkHeader: header) == nil)
    }

    @Test(arguments: [
        nil,
        "",
        #"<https://x.test/a?page=2>; rel="last""#,
        #"<https://x.test/a?page=2; rel="next""#,
        #"https://x.test/a?page=2; rel="next""#,
        #"<javascript:alert(1)>; rel="next""#,
        #"<ftp://x.test/a>; rel="next""#,
        #"<>; rel="next""#,
        #"<https://x.test/a?page=2> garbage; rel="next""#,
    ] as [String?])
    func missingOrMalformedNextYieldsNil(header: String?) {
        #expect(Pagination.nextLink(fromLinkHeader: header) == nil)
    }

    @Test func malformedValuesDoNotHideLaterValidOnes() {
        let header = #"<https://x.test/a?page=2> garbage, <https://x.test/a?page=3>; rel="next""#
        #expect(Pagination.nextLink(fromLinkHeader: header)?.absoluteString == "https://x.test/a?page=3")
    }

    @Test func relativeTargetsResolveAgainstTheBase() throws {
        let header = #"</api/v4/projects?page=2>; rel="next""#
        #expect(Pagination.nextLink(fromLinkHeader: header) == nil, "relative targets need a base")
        let base = try #require(URL(string: "https://gitlab.com/api/v4/projects?page=1"))
        #expect(Pagination.nextLink(fromLinkHeader: header, relativeTo: base)?.absoluteString == "https://gitlab.com/api/v4/projects?page=2")

        let response = HTTPResponse(status: 200, headers: ["Link": header], url: base)
        #expect(Pagination.nextLink(from: response)?.absoluteString == "https://gitlab.com/api/v4/projects?page=2")
    }

    @Test func parseExposesRelationsAndParameters() {
        let links = Pagination.parse(#"<https://x.test/1>; rel="next last"; type="application/json", <https://x.test/0>; rel=prev"#)
        #expect(links.count == 2)
        #expect(links.first?.relations == ["next", "last"])
        #expect(links.first?.parameters["type"] == "application/json")
        #expect(links.last?.relations == ["prev"])
    }

    @Test func clientFollowsNextLinksAcrossPages() async throws {
        let stub = StubTransport(
            routes: [
                .fixed("GET", "/projects", query: ["page": "1"], response: StubTransport.json(
                    "[1]", headers: ["Link": #"<https://gitlab.com/api/v4/projects?page=2>; rel="next""#]
                )),
                .fixed("GET", "/projects", query: ["page": "2"], response: StubTransport.json("[2]")),
            ],
            baseURL: NetFixture.gitlabAPI
        )
        let client = NetFixture.client(transport: stub)
        var pages: [[Int]] = []
        var response = try await client.get("/projects", query: [URLQueryItem(name: "page", value: "1")])
        pages.append(try AppClientDecode.ints(response))
        while let next = Pagination.nextLink(from: response) {
            response = try await client.getAbsolute(next)
            pages.append(try AppClientDecode.ints(response))
        }
        #expect(pages == [[1], [2]])
    }

    @Test func getAbsoluteRefusesOtherOrigins() async throws {
        let stub = StubTransport(baseURL: NetFixture.gitlabAPI)
        let client = NetFixture.client(transport: stub)
        let evil = try #require(URL(string: "https://attacker.example/api/v4/projects?page=2"))
        await #expect(throws: ProviderError.invalidRequest("Refusing to send credentials to a different host.")) {
            try await client.getAbsolute(evil)
        }
        #expect(stub.requests.isEmpty, "the credential never left the client")
    }
}

enum AppClientDecode {
    static func ints(_ response: HTTPResponse) throws -> [Int] {
        try APIClient.decode([Int].self, from: response)
    }
}
