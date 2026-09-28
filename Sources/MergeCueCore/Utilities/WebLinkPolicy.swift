import Foundation

/// The single policy for provider-supplied links (check `details_url`s, CI log URLs, PR/MR/thread web URLs) that
/// the app may open in the browser or hand to an agent.
///
/// Provider payloads are untrusted: a CI status `target_url` can be `file:///…`, `javascript:…`,
/// `x-apple.systempreferences:…` or a custom app scheme. Adapters drop non-web URLs at mapping time with
/// `webURL(_:)`; the UI opens links only through `decision(for:instances:)`.
public enum WebLinkPolicy {
    /// What the UI may do with a link.
    public enum Decision: Sendable, Hashable {
        /// A web link on the account's own instance or a well-known CI host: open directly.
        case open(URL)
        /// A web link elsewhere: open only after the user confirms `host`.
        case confirm(URL, host: String)
        /// Not a web link (or plain http to a host that is not a configured self-managed instance): never open.
        case reject(reason: String)
    }

    /// Well-known CI/CD and provider hosts (subdomains included) whose links open without confirmation.
    public static let knownCIHosts: [String] = [
        "github.com", "gitlab.com", "bitbucket.org",
        "circleci.com", "travis-ci.com", "travis-ci.org", "buildkite.com", "dev.azure.com", "codecov.io",
        "sonarcloud.io", "app.codacy.com", "cirrus-ci.com", "semaphoreci.com", "ci.appveyor.com", "bitrise.io",
    ]

    /// `url` when it is an absolute `https` (or `http`) URL with a host and no userinfo, otherwise nil. Use at
    /// adapter mapping time so non-web schemes never reach storage, the UI or MCP.
    public static func webURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        guard url.user(percentEncoded: false) == nil, url.password(percentEncoded: false) == nil else { return nil }
        return url
    }

    /// Parses `string` and applies `webURL(_:)`.
    public static func webURL(string: String?) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        return webURL(URL(string: string))
    }

    /// Decides whether `url` may be opened. `instances` are the connected accounts' instances: their hosts open
    /// without confirmation, and only a self-managed instance configured with `http://` allows plain http (to
    /// that host only). `https` links to other hosts open directly when the host is a known CI host, otherwise
    /// they need confirmation naming the host.
    public static func decision(for url: URL, instances: [ProviderInstance]) -> Decision {
        guard let scheme = url.scheme?.lowercased() else { return .reject(reason: "The link has no scheme.") }
        guard scheme == "https" || scheme == "http" else {
            return .reject(reason: "MergeCue only opens web links (https). This link uses “\(scheme):”.")
        }
        guard let web = webURL(url), let rawHost = web.host(percentEncoded: false) else {
            return .reject(reason: "The link has no host or embeds credentials.")
        }
        let host = normalizedHost(rawHost)
        let instanceHosts = instances.map { normalizedHost($0.webURL.host(percentEncoded: false) ?? "") }
        if scheme == "http" {
            let httpHosts = instances
                .filter { $0.webURL.scheme?.lowercased() == "http" }
                .map { normalizedHost($0.webURL.host(percentEncoded: false) ?? "") }
            guard httpHosts.contains(host) else {
                return .reject(reason: "MergeCue does not open plain-http links (\(host)); only a self-managed instance configured with http may use it.")
            }
            return .open(web)
        }
        if instanceHosts.contains(host) || isKnownCIHost(host) {
            return .open(web)
        }
        return .confirm(web, host: host)
    }

    /// Whether `host` is (a subdomain of) a `knownCIHosts` entry.
    public static func isKnownCIHost(_ host: String) -> Bool {
        let host = normalizedHost(host)
        return knownCIHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }
}
