import Foundation
import MergeCueCore
import MergeCueNetworking

extension GitHubProvider {
    // MARK: User, namespaces, repositories

    /// `GET /user`. Classic tokens report their scopes in `X-OAuth-Scopes`; fine-grained and app tokens send no such
    /// header, so `grantedScopes` is empty for them.
    public func currentUser() async throws -> ProviderUser {
        let response = try await client.get("/user")
        let user = try APIClient.decode(RESTUser.self, from: response)
        viewer.set(.init(remoteID: user.id.value, login: user.login))
        let scopes = response.header("x-oauth-scopes")?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        return ProviderUser(
            remoteID: user.id.value,
            username: user.login,
            displayName: user.name.flatMap { $0.isEmpty ? nil : $0 },
            avatarURL: user.avatarURL,
            grantedScopes: scopes,
            email: user.email
        )
    }

    /// The user's own namespace followed by `GET /user/orgs` (all pages).
    public func listNamespaces() async throws -> [Namespace] {
        let user = try await currentUser()
        var namespaces = [Namespace(id: user.remoteID, path: user.username, displayName: user.displayName ?? user.username, kind: .user)]
        let orgs = try await getAllPages(RESTOrganization.self, "/user/orgs")
        for org in orgs {
            namespaces.append(Namespace(id: org.id.value, path: org.login, displayName: org.login, kind: .organization))
        }
        return namespaces
    }

    /// `nil` → every repository the user can access (`/user/repos`, owner + collaborator + org member);
    /// the viewer's namespace → `/user/repos?affiliation=owner`; another user → `/users/{login}/repos`;
    /// an organization → `/orgs/{org}/repos`.
    public func listRepositories(namespace: Namespace?) async throws -> [Repository] {
        let account = try await accountKey()
        let path: String
        var query: [URLQueryItem] = []
        switch namespace {
        case nil:
            path = "/user/repos"
            query = [URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member")]
        case let namespace? where namespace.kind == .user:
            if namespace.id == account.remoteUserID || namespace.path.caseInsensitiveCompare(viewer.get()?.login ?? "") == .orderedSame {
                path = "/user/repos"
                query = [URLQueryItem(name: "affiliation", value: "owner")]
            } else {
                path = "/users/\(Self.segment(namespace.path))/repos"
            }
        case let namespace?:
            path = "/orgs/\(Self.segment(namespace.path))/repos"
        }
        query.append(URLQueryItem(name: "sort", value: "full_name"))
        let repos = try await getAllPages(RESTRepository.self, path, query: query)
        return repos.filter { $0.archived != true }.map { repo in
            let repository = GitHubMapping.repository(repo, account: account, instance: instance)
            register(repository)
            return repository
        }
    }

    // MARK: Change requests

    /// One GraphQL `search(type: ISSUE)` per scope (`author:@me` / `review-requested:@me` /
    /// `involves:@me -author:@me` — PRs of others you reviewed, commented on or were mentioned in, which GitHub
    /// keeps listing after it drops the review request; open, non-archived), cursor-paginated. The involved scope is
    /// bounded by `query.updatedSince` (Sync passes its involvement window) and `maxInvolvedPages`. Namespace restrictions are applied as `user:` qualifiers when the query stays within the
    /// search length limit, and always re-checked client-side.
    public func listChangeRequests(_ query: ChangeRequestQuery) async throws -> ChangeRequestPage {
        let searchQuery = Self.searchQuery(query)
        let wantedNamespaces = Set(query.namespaces.map { $0.lowercased() })
        var items: [ChangeRequestSummary] = []
        var seen = Set<String>()
        var cursor: String?
        var pages = 0
        repeat {
            var variables: [String: JSONValue] = [
                "q": .string(searchQuery),
                "first": .number(Double(GitHubQuery.searchPageSize)),
            ]
            variables["after"] = cursor.map(JSONValue.string) ?? .null
            let data = try await graphQL.execute(.search, variables: variables, as: GQLSearchData.self)
            guard let viewerID = data.viewer.databaseId?.value else {
                throw ProviderError.decoding("GraphQL viewer has no database id.")
            }
            viewer.set(.init(remoteID: viewerID, login: data.viewer.login))
            let account = AccountKey(instance: instance, remoteUserID: viewerID)
            for node in data.search.nodes ?? [] {
                guard let pr = node?.pullRequest else { continue }
                let summary = try GitHubMapping.summary(pr, account: account, instance: instance, involvement: [query.scope.involvement])
                register(summary.repository)
                if !wantedNamespaces.isEmpty, !wantedNamespaces.contains(summary.repository.namespacePath.lowercased()) {
                    continue
                }
                guard seen.insert(summary.key.id).inserted else { continue }
                items.append(summary)
            }
            pages += 1
            cursor = data.search.pageInfo?.hasNextPage == true ? data.search.pageInfo?.endCursor : nil
        } while cursor != nil && pages < (query.scope == .involved ? Self.maxInvolvedPages : Self.maxPages)
        return ChangeRequestPage(items: items)
    }

    /// GitHub search string for a listing query (max 256 characters).
    static func searchQuery(_ query: ChangeRequestQuery) -> String {
        var parts = ["is:pr", "is:open", "archived:false"]
        switch query.scope {
        case .authored: parts.append("author:@me")
        case .reviewRequested: parts.append("review-requested:@me")
        case .involved: parts += ["involves:@me", "-author:@me"]
        }
        if let since = query.updatedSince, let stamp = MergeCueCoding.formatWireDate(since) {
            // Search accepts ISO-8601 without fractional seconds.
            let whole = stamp.split(separator: ".").first.map(String.init) ?? stamp
            parts.append("updated:>=" + (whole.hasSuffix("Z") ? whole : whole + "Z"))
        }
        let base = parts.joined(separator: " ")
        let owners = query.namespaces
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." } }
            .map { "user:\($0)" }
        let restricted = ([base] + owners).joined(separator: " ")
        return owners.isEmpty || restricted.count > 256 ? base : restricted
    }

    // MARK: REST pagination

    /// Follows `Link: rel="next"` (same origin only) up to `maxPages` pages of `per_page=100`.
    func getAllPages<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> [T] {
        var results: [T] = []
        var response = try await client.get(path, query: query + [URLQueryItem(name: "per_page", value: "100")])
        results += try APIClient.decode([T].self, from: response)
        var pages = 1
        while pages < Self.maxPages, let next = Pagination.nextLink(from: response) {
            response = try await client.getAbsolute(next)
            results += try APIClient.decode([T].self, from: response)
            pages += 1
        }
        return results
    }
}
