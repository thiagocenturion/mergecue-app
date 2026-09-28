import Foundation
import MergeCueCore
import MergeCueNetworking

/// GraphQL request body (`{"operationName", "query", "variables"}`).
struct GitHubGraphQLRequest: Encodable, Sendable {
    var operationName: String
    var query: String
    var variables: [String: JSONValue]
}

/// One entry of a GraphQL `errors` array.
struct GitHubGraphQLError: Decodable, Sendable, Hashable {
    var type: String?
    var message: String
}

private struct GraphQLErrorsProbe: Decodable {
    var errors: [GitHubGraphQLError]?
}

private struct GraphQLEnvelope<D: Decodable>: Decodable {
    var data: D?
}

/// Sends GraphQL documents through the account's `APIClient` and maps `errors` to `ProviderError`.
struct GitHubGraphQLClient: Sendable {
    let client: APIClient
    let endpoint: URL

    /// `https://api.github.com/graphql` for GitHub.com; `https://<host>/api/graphql` for GitHub Enterprise Server
    /// (whose REST root is `/api/v3`).
    static func endpoint(forAPIURL apiURL: URL) -> URL {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/api/v3") {
            path = String(path.dropLast("/v3".count)) + "/graphql"
        } else {
            path += "/graphql"
        }
        components.path = path
        components.query = nil
        return components.url ?? apiURL.appending(path: "graphql")
    }

    func execute<D: Decodable>(_ query: GitHubQuery, variables: [String: JSONValue], as type: D.Type) async throws -> D {
        let request = GitHubGraphQLRequest(operationName: query.operationName, query: query.document, variables: variables)
        let response = try await client.sendAbsolute("POST", endpoint, json: request)
        let probe = try APIClient.decode(GraphQLErrorsProbe.self, from: response)
        if let errors = probe.errors, !errors.isEmpty {
            throw Self.map(errors, response: response)
        }
        let envelope = try APIClient.decode(GraphQLEnvelope<D>.self, from: response)
        guard let data = envelope.data else {
            throw ProviderError.decoding("GraphQL \(query.operationName) returned no data.")
        }
        return data
    }

    // MARK: Error mapping

    /// Maps a GraphQL `errors` array to the most significant `ProviderError`:
    /// `RATE_LIMITED` → `.rateLimited`; `INSUFFICIENT_SCOPES` → `.forbidden(missingScope:)` (scope parsed from the
    /// message); `FORBIDDEN` → `.forbidden`; `NOT_FOUND` → `.notFound`; internal failures ("Something went wrong",
    /// timeouts) → `.server(502)`; anything else → `.invalidRequest`.
    static func map(_ errors: [GitHubGraphQLError], response: HTTPResponse) -> ProviderError {
        let message = sanitize(errors.prefix(3).map(\.message).joined(separator: "; "))
        let types = Set(errors.compactMap { $0.type?.uppercased() })
        if types.contains("RATE_LIMITED") || errors.contains(where: { $0.message.lowercased().contains("rate limit") }) {
            let info = RateLimitHeaderParsing.combined(response, preferred: GitHubRateLimitParser())
            return .rateLimited(resetAt: info?.resetAt, retryAfter: info?.retryAfter)
        }
        if types.contains("INSUFFICIENT_SCOPES") {
            let scope = errors.lazy.compactMap { missingScope(in: $0.message) }.first
            return .forbidden(missingScope: scope, message: message)
        }
        if types.contains("FORBIDDEN") {
            return .forbidden(missingScope: nil, message: message)
        }
        if types.contains("NOT_FOUND") {
            return .notFound(message)
        }
        let lower = message.lowercased()
        if lower.contains("something went wrong") || lower.contains("timeout") || lower.contains("timed out") {
            return .server(status: 502, message: message)
        }
        return .invalidRequest(message)
    }

    /// First scope of "… requires one of the following scopes: ['read:org', 'repo'], but …".
    static func missingScope(in message: String) -> String? {
        guard let marker = message.range(of: "following scopes:", options: .caseInsensitive) else { return nil }
        let tail = message[marker.upperBound...]
        guard let open = tail.firstIndex(of: "["), let close = tail[open...].firstIndex(of: "]") else { return nil }
        let list = tail[tail.index(after: open)..<close]
        let scopes = list.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        }.filter { !$0.isEmpty }
        return scopes.first
    }

    private static func sanitize(_ text: String) -> String {
        let bounded = BoundedText.truncate(text, maxBytes: 500).text
        let redacted = SecretRedactor.redact(bounded)
        return redacted.isEmpty ? "GraphQL error" : redacted
    }
}
