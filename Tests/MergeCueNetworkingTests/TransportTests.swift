import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

/// `URLSessionTransport` configuration and redirect policy (no network: nothing here sends a request).
@Suite("URLSession transport")
struct TransportTests {
    @Test func configurationIsEphemeralWithoutCookiesOrCache() {
        let configuration = URLSessionTransport.makeConfiguration(timeout: 30, userAgent: "MergeCue/1.0")
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(configuration.timeoutIntervalForResource >= 30)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.httpAdditionalHeaders?["User-Agent"] as? String == "MergeCue/1.0")
    }

    @Test func defaultsAndUserAgent() {
        let transport = URLSessionTransport()
        #expect(transport.timeout == 30)
        #expect(transport.userAgent.hasPrefix("MergeCue/"))
        #expect(URLSessionTransport(timeout: -1).timeout == 30)
        #expect(URLSessionTransport(timeout: .nan).timeout == 30)

        #expect(URLSessionTransport.userAgent(forVersion: "1.2.3") == "MergeCue/1.2.3")
        #expect(URLSessionTransport.userAgent(forVersion: nil) == "MergeCue/dev")
        #expect(URLSessionTransport.userAgent(forVersion: "") == "MergeCue/dev")
        #expect(URLSessionTransport.userAgent(forVersion: "1.0\r\nX-Evil: 1") == "MergeCue/dev")
        #expect(URLSessionTransport.userAgent(forVersion: "2.0-beta.1") == "MergeCue/2.0-beta.1")
    }

    @Test func urlRequestsCarryMethodHeadersBodyAndTimeout() {
        let transport = URLSessionTransport(timeout: 12, userAgent: "MergeCue/test")
        let request = HTTPRequest(
            method: "patch",
            url: URL(staticString: "https://api.github.com/x"),
            headers: ["Authorization": "Bearer t", "Content-Type": "application/json"],
            body: Data("{}".utf8)
        )
        let urlRequest = transport.makeURLRequest(request)
        #expect(urlRequest.httpMethod == "PATCH")
        #expect(urlRequest.value(forHTTPHeaderField: "authorization") == "Bearer t")
        #expect(urlRequest.value(forHTTPHeaderField: "User-Agent") == "MergeCue/test")
        #expect(urlRequest.httpBody == Data("{}".utf8))
        #expect(urlRequest.timeoutInterval == 12)
        #expect(urlRequest.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(urlRequest.httpShouldHandleCookies == false)

        let custom = transport.makeURLRequest(HTTPRequest(url: URL(staticString: "https://x.test"), headers: ["user-agent": "Other/1"]))
        #expect(custom.value(forHTTPHeaderField: "User-Agent") == "Other/1")
    }

    // MARK: Redirects

    private func request(_ url: String, auth: Bool = true) -> URLRequest {
        var request = URLRequest(url: URL(string: url) ?? URL(staticString: "https://invalid.test"))
        if auth {
            request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
            request.setValue("glpat-x", forHTTPHeaderField: "PRIVATE-TOKEN")
            request.setValue("a=b", forHTTPHeaderField: "Cookie")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    @Test func sameOriginRedirectsKeepCredentials() throws {
        let followed = try #require(RedirectPolicy.followRequest(
            original: request("https://api.github.com/repos/a/b"),
            proposed: request("https://API.github.com:443/repositories/1")
        ))
        #expect(followed.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func crossOriginRedirectsDropCredentials() throws {
        let followed = try #require(RedirectPolicy.followRequest(
            original: request("https://api.github.com/repos/a/b/actions/jobs/1/logs"),
            proposed: request("https://pipelines.actions.githubusercontent.com/logs/1?sig=abc")
        ))
        #expect(followed.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(followed.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil)
        #expect(followed.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(followed.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(followed.url?.query == "sig=abc")

        let otherPort = try #require(RedirectPolicy.followRequest(
            original: request("https://gitlab.example.com/api/v4/x"),
            proposed: request("https://gitlab.example.com:8443/api/v4/x")
        ))
        #expect(otherPort.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func downgradesAndOddSchemesAreRefused() {
        #expect(RedirectPolicy.followRequest(original: request("https://api.github.com/x"), proposed: request("http://api.github.com/x")) == nil)
        #expect(RedirectPolicy.followRequest(original: request("https://api.github.com/x"), proposed: request("file:///etc/passwd")) == nil)
        #expect(RedirectPolicy.followRequest(original: request("http://localhost:8080/x"), proposed: request("https://localhost:8080/x")) != nil)
    }
}

@Suite("HTTP messages")
struct HTTPMessageTests {
    @Test func responseHeaderNamesAreLowercased() {
        let response = HTTPResponse(status: 200, headers: ["ETag": "\"a\"", "X-RateLimit-Remaining": "5"], url: URL(staticString: "https://x.test"))
        #expect(response.headers == ["etag": "\"a\"", "x-ratelimit-remaining": "5"])
        #expect(response.header("ETAG") == "\"a\"")
        #expect(response.isSuccess)
    }

    @Test func collidingHeaderNamesAreJoinedDeterministically() {
        let response = HTTPResponse(status: 200, headers: ["Link": "<a>", "link": "<b>"], url: URL(staticString: "https://x.test"))
        #expect(response.headers["link"] == "<a>, <b>")
    }

    @Test func requestHeaderLookupIsCaseInsensitiveAndMethodUppercased() {
        let request = HTTPRequest(method: "get", url: URL(staticString: "https://x.test"), headers: ["If-None-Match": "\"x\""])
        #expect(request.method == "GET")
        #expect(request.header("if-none-match") == "\"x\"")
        #expect(request.isIdempotentRead)
        #expect(!HTTPRequest(method: "POST", url: URL(staticString: "https://x.test")).isIdempotentRead)
    }

    @Test func mergedHeadersReplaceCaseInsensitively() {
        let merged = HTTPHeaders.merged(["Accept": "a", "X-One": "1"], ["accept": "b"], ["ACCEPT": "c"])
        #expect(merged == ["ACCEPT": "c", "X-One": "1"])
    }

    @Test func sensitiveHeaderDetection() {
        for name in ["Authorization", "PRIVATE-TOKEN", "Job-Token", "Cookie", "X-Api-Key", "X-Gitlab-Token", "Proxy-Authorization"] {
            #expect(HTTPHeaders.isSensitive(name), "\(name)")
        }
        for name in ["Accept", "Content-Type", "X-RateLimit-Remaining", "ETag"] {
            #expect(!HTTPHeaders.isSensitive(name), "\(name)")
        }
    }
}
