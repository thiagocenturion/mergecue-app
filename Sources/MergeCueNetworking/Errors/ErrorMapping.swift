import Foundation
import MergeCueCore

/// Maps an HTTP error response to a typed `ProviderError`; nil for statuses below 400.
///
/// | Status | Result |
/// | --- | --- |
/// | 401 | `unauthorized` |
/// | 403 + `retry-after`, `x-ratelimit-remaining: 0` / `ratelimit-remaining: 0`, or a "rate limit" message | `rateLimited` |
/// | 403 otherwise | `forbidden(missingScope:)` — scope hints from `X-Accepted-OAuth-Scopes` vs `X-OAuth-Scopes`, `X-Accepted-GitHub-Permissions`, `WWW-Authenticate: … error="insufficient_scope", scope="…"`, GitLab `scope` / Bitbucket `detail.required` bodies |
/// | 404, 410 | `notFound` |
/// | 408 | `server(status: 408)` (retryable) |
/// | 409, 412, 423 | `conflict` |
/// | 422 and other 4xx | `invalidRequest` |
/// | 429 | `rateLimited` |
/// | 5xx | `server` |
///
/// Messages come from the provider's JSON error body (GitHub `message` + `errors`, GitLab `message`/`error`,
/// Bitbucket `error.message`), are redacted with `SecretRedactor` and bounded to 500 bytes. Request headers are
/// never included.
public func mapHTTPError(_ response: HTTPResponse, parser: any RateLimitParsing) -> ProviderError? {
    let status = response.status
    guard status >= 400 else { return nil }
    let body = ErrorBody(response)
    let message = body.message
    switch status {
    case 401:
        return .unauthorized(message)
    case 403:
        if ErrorBody.looksRateLimited(response, message: message) {
            let info = RateLimitHeaderParsing.combined(response, preferred: parser)
            return .rateLimited(resetAt: info?.resetAt, retryAfter: info?.retryAfter)
        }
        return .forbidden(missingScope: ScopeHints.missingScope(in: response, body: body.json), message: message)
    case 404, 410:
        return .notFound(message)
    case 408:
        return .server(status: status, message: message)
    case 409, 412, 423:
        return .conflict(message)
    case 429:
        let info = RateLimitHeaderParsing.combined(response, preferred: parser)
        return .rateLimited(resetAt: info?.resetAt, retryAfter: info?.retryAfter)
    case 500...:
        return .server(status: status, message: message)
    default:
        return .invalidRequest(message)
    }
}

/// Maps a transport failure (`URLError`, …) with the shared `ProviderError.classify` rules: `timedOut` →
/// `.timeout`; no internet / lost connection / DNS / cannot connect → `.offline`; other errors → `.server(status: 0)`.
///
/// Cancellation is not a provider failure — check `isCancellation(_:)` first. If a cancellation is passed anyway it
/// maps to `.server(status: 0, message: "The request was cancelled.")`.
public func mapTransportError(_ error: any Error) -> ProviderError {
    ProviderError.classify(error) ?? .server(status: 0, message: "The request was cancelled.")
}

/// Whether `error` is a task or `URLSession` cancellation (never reported as a failure).
public func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

extension RateLimitHeaderParsing {
    /// `preferred`'s result with gaps filled from the GitHub, GitLab and `Retry-After` header families, so a
    /// response is understood even when the account's parser does not match the server.
    public static func combined(_ response: HTTPResponse, preferred: any RateLimitParsing) -> RateLimitInfo? {
        let candidates = [
            preferred.parse(response), GitHubRateLimitParser().parse(response), GitLabRateLimitParser().parse(response),
        ].compactMap { $0 }
        guard var result = candidates.first else { return nil }
        for other in candidates.dropFirst() {
            result.limit = result.limit ?? other.limit
            result.remaining = result.remaining ?? other.remaining
            result.resetAt = result.resetAt ?? other.resetAt
            result.retryAfter = result.retryAfter ?? other.retryAfter
        }
        return result
    }
}

// MARK: - Error bodies

/// A parsed provider error body.
struct ErrorBody {
    static let maxMessageBytes = 500

    let json: JSONValue?
    let message: String

    init(_ response: HTTPResponse) {
        let json = response.body.isEmpty ? nil : try? JSONValue.defaultDecoder().decode(JSONValue.self, from: response.body)
        self.json = json
        let raw = json.flatMap(Self.message(fromJSON:)) ?? Self.plainTextMessage(response)
        let collapsed = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let bounded = BoundedText.truncate(collapsed, maxBytes: Self.maxMessageBytes).text
        self.message = SecretRedactor.redact(bounded.isEmpty ? "HTTP \(response.status)" : bounded)
    }

    /// GitHub `{message, errors}`, GitLab `{message}` / `{error, error_description}`, Bitbucket
    /// `{error: {message, detail}}`, GraphQL `{errors: [{message}]}`.
    static func message(fromJSON json: JSONValue) -> String? {
        guard let object = json.objectValue else {
            return json.stringValue
        }
        var parts: [String] = []
        if let message = object["message"].flatMap(flatten), !message.isEmpty {
            parts.append(message)
        } else if let description = object["error_description"]?.stringValue, !description.isEmpty {
            parts.append(description)
        } else if let error = object["error"] {
            if let text = error.stringValue {
                parts.append(text)
            } else if let nested = error.objectValue {
                if let text = nested["message"]?.stringValue { parts.append(text) }
                if let detail = nested["detail"]?.stringValue, !detail.isEmpty { parts.append(detail) }
            }
        }
        if let errors = object["errors"]?.arrayValue {
            let details = errors.prefix(3).compactMap { item -> String? in
                if let text = item.stringValue { return text }
                guard let entry = item.objectValue else { return nil }
                if let text = entry["message"]?.stringValue, !text.isEmpty { return text }
                let field = entry["field"]?.stringValue
                let code = entry["code"]?.stringValue
                return [field, code].compactMap { $0 }.joined(separator: " ").nilIfEmpty
            }
            if !details.isEmpty { parts.append(details.joined(separator: "; ")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }

    /// Strings, arrays of strings and `{field: [messages]}` objects (GitLab validation errors) as one line.
    private static func flatten(_ value: JSONValue) -> String? {
        if let text = value.stringValue { return text }
        if let array = value.arrayValue {
            return array.compactMap(flatten).joined(separator: ", ").nilIfEmpty
        }
        if let object = value.objectValue {
            return object.keys.sorted().compactMap { key in
                object[key].flatMap(flatten).map { "\(key) \($0)" }
            }
            .joined(separator: "; ").nilIfEmpty
        }
        return nil
    }

    private static func plainTextMessage(_ response: HTTPResponse) -> String {
        let text = response.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        // HTML error pages (load balancers, maintenance pages) are noise.
        if text.isEmpty || text.hasPrefix("<") {
            return "HTTP \(response.status)"
        }
        return BoundedText.truncate(text, maxBytes: 300).text
    }

    static func looksRateLimited(_ response: HTTPResponse, message: String) -> Bool {
        if response.header("retry-after") != nil { return true }
        for name in ["x-ratelimit-remaining", "ratelimit-remaining"] {
            if response.header(name)?.trimmingCharacters(in: .whitespaces) == "0" { return true }
        }
        let lower = message.lowercased()
        return lower.contains("rate limit") || lower.contains("abuse detection")
    }
}

// MARK: - Scope hints

enum ScopeHints {
    static func missingScope(in response: HTTPResponse, body: JSONValue?) -> String? {
        if let scope = gitHubOAuthScope(response) { return scope }
        if let permission = response.header("x-accepted-github-permissions")?
            .split(separator: ";").first?.trimmingCharacters(in: .whitespaces), !permission.isEmpty
        {
            return permission
        }
        if let scope = wwwAuthenticateScope(response) { return scope }
        if let scope = bodyScope(body) { return scope }
        return nil
    }

    /// GitHub classic tokens: `X-Accepted-OAuth-Scopes` lists scopes that would allow the call, `X-OAuth-Scopes`
    /// those the token has. Returns the least-privileged accepted scope when none of them is granted.
    static func gitHubOAuthScope(_ response: HTTPResponse) -> String? {
        guard let acceptedHeader = response.header("x-accepted-oauth-scopes"),
              let grantedHeader = response.header("x-oauth-scopes")
        else { return nil }
        let accepted = scopeList(acceptedHeader)
        let granted = scopeList(grantedHeader)
        guard !accepted.isEmpty else { return nil }
        let satisfied = accepted.contains { needed in granted.contains { covers($0, needed) } }
        guard !satisfied else { return nil }
        return accepted.min { privilegeRank($0) < privilegeRank($1) }
    }

    /// `WWW-Authenticate: Bearer error="insufficient_scope", scope="api read_api"`.
    static func wwwAuthenticateScope(_ response: HTTPResponse) -> String? {
        guard let header = response.header("www-authenticate"), header.lowercased().contains("insufficient_scope"),
              let scope = authParameter("scope", in: header)
        else { return nil }
        return leastPrivileged(scope.split(separator: " ").map(String.init))
    }

    /// GitLab `{"error": "insufficient_scope", "scope": "api read_api"}`; Bitbucket
    /// `{"error": {"detail": {"required": [...], "granted": [...]}}}`.
    static func bodyScope(_ body: JSONValue?) -> String? {
        guard let object = body?.objectValue else { return nil }
        if let scope = object["scope"]?.stringValue {
            return leastPrivileged(scope.split(separator: " ").map(String.init))
        }
        if let detail = object["error"]?["detail"]?.objectValue, let required = detail["required"]?.arrayValue {
            let granted = Set(detail["granted"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let missing = required.compactMap(\.stringValue).filter { !granted.contains($0) }
            return missing.isEmpty ? nil : missing.joined(separator: ", ")
        }
        return nil
    }

    static func scopeList(_ header: String) -> [String] {
        header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func leastPrivileged(_ scopes: [String]) -> String? {
        scopes.filter { !$0.isEmpty }.min { privilegeRank($0) < privilegeRank($1) }
    }

    /// read < plain < write < admin; stable for equal ranks (`min` keeps the first).
    static func privilegeRank(_ scope: String) -> Int {
        let lower = scope.lowercased()
        if lower.hasPrefix("read") || lower.hasSuffix("read") || lower.contains("read_") || lower.contains(":read") { return 0 }
        if lower.hasPrefix("admin") { return 3 }
        if lower.hasPrefix("write") || lower.hasSuffix("write") { return 2 }
        return 1
    }

    /// Whether GitHub scope `granted` implies `needed` (scope hierarchy).
    static func covers(_ granted: String, _ needed: String) -> Bool {
        if granted == needed { return true }
        switch granted {
        case "repo":
            return ["repo:status", "repo_deployment", "public_repo", "repo:invite", "security_events"].contains(needed)
        case "user":
            return needed.hasPrefix("user:") || needed == "read:user"
        case "project":
            return needed == "read:project"
        case "write:packages":
            return needed == "read:packages"
        case "admin:enterprise":
            return needed.hasSuffix(":enterprise")
        default:
            if granted.hasPrefix("admin:") {
                let family = granted.dropFirst("admin:".count)
                return needed == "write:\(family)" || needed == "read:\(family)"
            }
            if granted.hasPrefix("write:") {
                return needed == "read:\(granted.dropFirst("write:".count))"
            }
            return false
        }
    }

    /// Value of `name="value"` or `name=value` in an auth-param list.
    static func authParameter(_ name: String, in header: String) -> String? {
        let scalars = Array(header.unicodeScalars)
        var index = 0
        let target = name.lowercased()
        let separators: Set<Unicode.Scalar> = [" ", ",", "\t"]
        while index < scalars.count {
            while index < scalars.count, separators.contains(scalars[index]) { index += 1 }
            // A token (auth scheme or parameter name).
            var token = ""
            while index < scalars.count, scalars[index] != "=", !separators.contains(scalars[index]) {
                token.unicodeScalars.append(scalars[index])
                index += 1
            }
            var lookahead = index
            while lookahead < scalars.count, scalars[lookahead] == " " { lookahead += 1 }
            guard lookahead < scalars.count, scalars[lookahead] == "=" else { continue }
            index = lookahead + 1
            while index < scalars.count, scalars[index] == " " { index += 1 }
            var value = ""
            if index < scalars.count, scalars[index] == "\"" {
                index += 1
                while index < scalars.count, scalars[index] != "\"" {
                    if scalars[index] == "\\", index + 1 < scalars.count { index += 1 }
                    value.unicodeScalars.append(scalars[index])
                    index += 1
                }
                index += 1
            } else {
                while index < scalars.count, scalars[index] != ",", scalars[index] != " " {
                    value.unicodeScalars.append(scalars[index])
                    index += 1
                }
            }
            if token.lowercased() == target { return value }
        }
        return nil
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
