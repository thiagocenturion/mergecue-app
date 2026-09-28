import Foundation
import MergeCueCore
import Testing

@Suite("WebLinkPolicy (S1)")
struct WebLinkPolicyTests {
    static let selfManagedHTTP = ProviderInstance(
        kind: .gitlab,
        webURL: URL(staticString: "http://gitlab.intra.example"),
        apiURL: URL(staticString: "http://gitlab.intra.example/api/v4")
    )
    static let instances = [ProviderInstance.githubCom, .gitlabCom, selfManagedHTTP]

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple.preference.security",
        "vscode://file/tmp/x", "ssh://git@github.com/a/b", "data:text/html,hi", "https://user:pw@github.com/a",
        "https:///nohost",
    ])
    func dropsNonWebURLs(_ text: String) {
        #expect(WebLinkPolicy.webURL(string: text) == nil)
        if let url = URL(string: text) {
            if case .reject = WebLinkPolicy.decision(for: url, instances: Self.instances) {} else {
                Issue.record("\(text) must be rejected")
            }
        }
    }

    @Test func instanceAndKnownCIHostsOpenDirectly() throws {
        for text in ["https://github.com/acme/api/pull/42", "https://gitlab.com/acme/api/-/jobs/7",
                     "https://app.circleci.com/pipelines/1", "https://buildkite.com/acme/x", "http://gitlab.intra.example/g/p/-/jobs/1"] {
            let url = try #require(URL(string: text))
            #expect(WebLinkPolicy.decision(for: url, instances: Self.instances) == .open(url), "\(text)")
        }
    }

    @Test func unfamiliarHTTPSHostNeedsConfirmation() throws {
        let url = try #require(URL(string: "https://ci.evil.example/run/1"))
        #expect(WebLinkPolicy.decision(for: url, instances: Self.instances) == .confirm(url, host: "ci.evil.example"))
        // Look-alike suffixes are not subdomains.
        let lookalike = try #require(URL(string: "https://evilgithub.com/x"))
        #expect(WebLinkPolicy.decision(for: lookalike, instances: Self.instances) == .confirm(lookalike, host: "evilgithub.com"))
    }

    @Test func plainHTTPOnlyForAConfiguredSelfManagedHost() throws {
        let url = try #require(URL(string: "http://github.com/acme"))
        if case .reject = WebLinkPolicy.decision(for: url, instances: Self.instances) {} else { Issue.record("http must be rejected") }
    }

    @Test func checkRunDropsNonWebDetailsURL() throws {
        let key = CheckKey(
            changeRequest: ChangeRequestKey(repo: RepoKey(account: AccountKey(kind: .github, host: "github.com", remoteUserID: "1"),
                                                          remoteRepoID: "2"), remoteID: "3", number: 3),
            source: .githubStatus, remoteID: "ci")
        let bad = CheckRun(key: key, name: "ci", status: .failure, detailsURL: URL(string: "file:///Applications/Calculator.app"))
        #expect(bad.detailsURL == nil)
        let good = CheckRun(key: key, name: "ci", status: .failure, detailsURL: URL(string: "https://ci.example/1"))
        #expect(good.detailsURL?.absoluteString == "https://ci.example/1")
    }
}
