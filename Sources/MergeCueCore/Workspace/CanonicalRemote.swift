import Foundation

/// A transport-independent repository location used to match local git remotes to provider repositories.
///
/// `https://github.com/Acme/Repo.git`, `git@github.com:acme/repo.git` and `ssh://git@github.com:22/acme/repo`
/// all canonicalize to host `github.com`, path `acme/repo`. Userinfo (including tokens), ports, `.git`,
/// query/fragment and trailing slashes are dropped; host and path are lowercased.
public struct CanonicalRemote: Codable, Sendable, Hashable, CustomStringConvertible {
    /// Lowercased host without port or userinfo.
    public var host: String
    /// Lowercased path, no ".git", no leading or trailing "/".
    public var path: String

    /// Normalizing initializer (lowercases, strips slashes and a trailing `.git`).
    public init(host: String, path: String) {
        self.host = Self.normalizeHost(host)
        self.path = Self.normalizePath(Substring(path))
    }

    public var description: String { "\(host)/\(path)" }

    /// Last path segment (repository name).
    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Everything before the last segment (owner / group / workspace path).
    public var namespace: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static let allowedSchemes: Set<String> = ["https", "http", "ssh", "git", "git+ssh", "ssh+git"]

    /// Parses https/http, `ssh://` (with optional user and port), `git://` and scp-like `[user@]host:path` remotes.
    /// Returns nil for local paths (including `C:/…` drive paths), `file://` URLs, malformed userinfo (an `@` in
    /// the path) and anything without at least `owner/name`.
    public static func parse(_ url: String) -> CanonicalRemote? {
        parse(url, resolvingHost: { _ in nil })
    }

    /// Like `parse(_:)`, but first maps the remote's host through `resolvingHost` — e.g. an `~/.ssh/config` alias
    /// (`github-work` → `github.com`, as reported by `ssh -G <alias>`). Return nil to keep the host as written.
    public static func parse(_ url: String, resolvingHost: (String) -> String?) -> CanonicalRemote? {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace || $0 == "\\" }) else { return nil }

        var hostPart: Substring
        var pathPart: Substring

        if let schemeRange = raw.range(of: "://") {
            let scheme = raw[..<schemeRange.lowerBound].lowercased()
            guard allowedSchemes.contains(scheme) else { return nil }
            let rest = raw[schemeRange.upperBound...]
            let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
            hostPart = stripPort(stripUserInfo(rest[..<authorityEnd]))
            pathPart = rest[authorityEnd...]
        } else {
            // scp-like syntax: [user@]host:path — no slash may precede the colon (that would be a local path).
            guard let colon = raw.firstIndex(of: ":") else { return nil }
            let authority = raw[..<colon]
            guard !authority.contains("/") else { return nil }
            hostPart = stripUserInfo(authority)
            // "C:/Users/…" is a Windows drive path, not host "c".
            guard !(hostPart.count == 1 && authority.count == 1) else { return nil }
            pathPart = raw[raw.index(after: colon)...]
        }

        if let cut = pathPart.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            pathPart = pathPart[..<cut]
        }
        // An "@" in the path means malformed userinfo (e.g. a password containing "/"); never guess.
        guard !pathPart.contains("@") else { return nil }
        // GitLab web URLs: "/group/project/-/tree/main" → "/group/project".
        if let dash = pathPart.range(of: "/-/") {
            pathPart = pathPart[..<dash.lowerBound]
        }
        let decodedPath = String(pathPart).removingPercentEncoding ?? String(pathPart)

        let writtenHost = String(hostPart)
        let host = normalizeHost(resolvingHost(writtenHost) ?? resolvingHost(writtenHost.lowercased()) ?? writtenHost)
        guard isValidHost(host) else { return nil }
        let path = normalizePath(Substring(decodedPath))
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return CanonicalRemote(uncheckedHost: host, path: path)
    }

    /// `url` with credentials removed, safe to display and persist (`GitRemote`, `RepoMapping.matchedRemote`).
    ///
    /// - `http(s)://` and other non-SSH URLs: the whole userinfo is dropped (`https://user:TOKEN@host/…` and
    ///   `https://TOKEN@host/…` → `https://host/…`).
    /// - `ssh://` / `git+ssh://`: only the password is dropped; a plain user name is kept (`ssh://git@host/…`).
    /// - scp-like `git@host:path` has no password field and is kept.
    ///
    /// The userinfo ends at the **last** `@` before any `?`/`#`, so passwords containing `@` or `/` cannot leak
    /// their tail. The result is finally passed through `SecretRedactor` (tokens in query strings etc.).
    public static func sanitizedURL(_ url: String) -> String {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = raw.range(of: "://") else {
            return SecretRedactor.redact(raw)
        }
        let scheme = raw[..<schemeRange.lowerBound]
        let rest = raw[schemeRange.upperBound...]
        let authorityRegionEnd = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
        guard let at = rest[..<authorityRegionEnd].lastIndex(of: "@") else {
            return SecretRedactor.redact(raw)
        }
        let userInfo = rest[..<at]
        let afterUserInfo = rest[rest.index(after: at)...]
        var kept = ""
        if ["ssh", "git+ssh", "ssh+git"].contains(scheme.lowercased()) {
            let user = userInfo.prefix { $0 != ":" }
            if !user.isEmpty, !user.contains("/"), !user.contains("@") {
                kept = String(user) + "@"
            }
        }
        return SecretRedactor.redact("\(scheme)://\(kept)\(afterUserInfo)")
    }

    /// All canonical locations of `repository` (web URL + clone URLs).
    public static func candidates(for repository: Repository) -> Set<CanonicalRemote> {
        var result = Set<CanonicalRemote>()
        if let web = parse(repository.webURL.absoluteString) { result.insert(web) }
        for clone in repository.cloneURLs {
            if let remote = parse(clone) { result.insert(remote) }
        }
        return result
    }

    // MARK: Internals

    private init(uncheckedHost host: String, path: String) {
        self.host = host
        self.path = path
    }

    /// Hosts that serve the same repositories under a different name (SSH over 443 etc.).
    private static let hostAliases: [String: String] = [
        "ssh.github.com": "github.com",
        "www.github.com": "github.com",
        "altssh.gitlab.com": "gitlab.com",
        "www.gitlab.com": "gitlab.com",
        "altssh.bitbucket.org": "bitbucket.org",
        "www.bitbucket.org": "bitbucket.org",
    ]

    private static func stripUserInfo(_ authority: Substring) -> Substring {
        guard let at = authority.lastIndex(of: "@") else { return authority }
        return authority[authority.index(after: at)...]
    }

    private static func stripPort(_ hostPort: Substring) -> Substring {
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            return hostPort[...close]
        }
        guard let colon = hostPort.firstIndex(of: ":") else { return hostPort }
        return hostPort[..<colon]
    }

    private static func normalizeHost(_ host: String) -> String {
        var value = host.lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return hostAliases[value] ?? value
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if host.hasPrefix("[") { return host.hasSuffix("]") && host.count > 2 }
        guard host.first != "-", host.first != "." else { return false }
        // "_" is common in ~/.ssh/config aliases (git@github_work:…) and internal hosts.
        return host.allSatisfy { $0.isASCIIAlphanumeric || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private static func normalizePath(_ raw: Substring) -> String {
        var path = raw.lowercased()
        path = path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        if path.hasSuffix(".git") {
            path.removeLast(4)
            while path.hasSuffix("/") { path.removeLast() }
        }
        return path
    }
}
