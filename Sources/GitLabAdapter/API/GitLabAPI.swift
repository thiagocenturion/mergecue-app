import Foundation
import MergeCueCore
import MergeCueNetworking

/// Thin typed layer over `APIClient` for GitLab REST v4: paths, decoding and offset pagination.
struct GitLabAPI: Sendable {
    /// Result of a paginated listing.
    struct Paged<Item: Sendable>: Sendable {
        var items: [Item]
        /// Every page came from the ETag cache (`304`), i.e. nothing changed since the last poll.
        var allCacheHits: Bool
        /// Stopped at `maxPages` while GitLab still reported a next page.
        var truncated: Bool
    }

    /// Items requested per page (GitLab's maximum).
    static let perPage = 100

    let client: APIClient

    // MARK: Paths (project id + MR iid everywhere; ids are percent-encoded path segments)

    static func project(_ projectID: String) -> String {
        "/projects/\(RequestURLBuilder.encodePathSegment(projectID))"
    }

    static func mergeRequest(project projectID: String, iid: Int) -> String {
        "\(project(projectID))/merge_requests/\(iid)"
    }

    static func mergeRequest(_ key: ChangeRequestKey) -> String {
        mergeRequest(project: key.repo.remoteRepoID, iid: key.number)
    }

    static func discussion(_ key: ThreadKey) -> String {
        "\(mergeRequest(key.changeRequest))/discussions/\(RequestURLBuilder.encodePathSegment(key.remoteID))"
    }

    // MARK: Requests

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [], useETag: Bool = false) async throws -> T {
        try await client.getJSON(type, path, query: query, useETag: useETag, decoder: GitLabJSON.decoder())
    }

    /// A plain-text resource (job trace, raw diff).
    func getText(_ path: String) async throws -> HTTPResponse {
        try await client.get(path, headers: ["Accept": "text/plain, */*"])
    }

    func send<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, json: (any Encodable & Sendable)?) async throws -> T {
        try await client.sendJSON(type, method, path, json: json, decoder: GitLabJSON.decoder())
    }

    func send(_ method: String, _ path: String, json: (any Encodable & Sendable)?) async throws -> HTTPResponse {
        try await client.send(method, path, json: json)
    }

    /// Follows GitLab offset pagination: `x-next-page` (preferred — it survives a misconfigured external URL),
    /// then the RFC 8288 `Link: rel="next"` header (keyset pagination). Stops after `maxPages`.
    func getAll<T: Decodable & Sendable>(
        _ type: T.Type,
        _ path: String,
        query: [URLQueryItem] = [],
        maxPages: Int = 20,
        useETag: Bool = false
    ) async throws -> Paged<T> {
        let baseQuery = query + [URLQueryItem(name: "per_page", value: String(Self.perPage))]
        var items: [T] = []
        var allCacheHits = true
        var response = try await client.get(path, query: baseQuery, useETag: useETag)
        var pages = 1
        while true {
            allCacheHits = allCacheHits && response.isCacheHit
            items.append(contentsOf: try APIClient.decode([T].self, from: response, decoder: GitLabJSON.decoder()))
            let nextPage = response.header("x-next-page").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let nextLink = nextPage == nil ? Pagination.nextLink(from: response) : nil
            guard nextPage != nil || nextLink != nil else { break }
            guard pages < maxPages else {
                return Paged(items: items, allCacheHits: false, truncated: true)
            }
            pages += 1
            if let nextPage {
                response = try await client.get(path, query: baseQuery + [URLQueryItem(name: "page", value: String(nextPage))], useETag: useETag)
            } else if let nextLink {
                response = try await client.getAbsolute(nextLink, useETag: useETag)
            }
        }
        return Paged(items: items, allCacheHits: allCacheHits && useETag, truncated: false)
    }
}
