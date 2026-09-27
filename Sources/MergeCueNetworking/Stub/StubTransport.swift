import Foundation
import MergeCueCore
import Synchronization

/// A deterministic in-process `HTTPTransport` for tests and demo mode.
///
/// Routes match on method (`*` = any), a path pattern relative to `baseURL`'s path and optional query constraints.
/// Pattern segments:
/// - literal (compared after percent-decoding, so `acme%2Fpayments-api` matches the encoded request segment);
/// - `{name}` captures one segment (decoded), optionally with a literal prefix/suffix (`{number}.diff`);
/// - `*` matches exactly one segment; a trailing `**` matches any remainder (including nothing).
///
/// A pattern may also carry a query (`/search/issues?q=is:pr`), merged into `query`. Query constraints must all be
/// present in the request (extra request parameters are fine); the value `*` only requires presence.
///
/// When several routes match, the most specific wins (more literal segments, then exact length over `**`, then
/// more query constraints); ties go to the route added last, so `add(_:)` can override fixtures.
/// Unmatched requests get `404` with `{"message":"stub: no route for METHOD path"}`. Every request is recorded.
/// All state is behind a lock: safe to use from concurrent tasks.
public final class StubTransport: HTTPTransport {
    /// Route handler. May throw (e.g. `URLError`) to simulate transport failures.
    public typealias Handler = @Sendable (HTTPRequest, Match) throws -> HTTPResponse

    /// Captured values of a matched route.
    public struct Match: Sendable, Hashable {
        /// `{name}` captures, percent-decoded.
        public var params: [String: String]
        /// Decoded request query (`+` treated as space); repeated names keep every value in order.
        public var query: [String: [String]]

        public init(params: [String: String] = [:], query: [String: [String]] = [:]) {
            self.params = params
            self.query = query
        }

        public subscript(_ name: String) -> String? { params[name] }
    }

    /// A stubbed endpoint.
    public struct Route: Sendable {
        public var method: String
        public var pathPattern: String
        public var query: [String: String]
        public var handler: Handler

        /// Handler form that ignores captures (the contract signature).
        public var respond: @Sendable (HTTPRequest) -> HTTPResponse {
            get {
                let handler = handler
                let pattern = RoutePattern(pathPattern)
                return { request in
                    let params = pattern.capturesInAnySuffix(of: request.url) ?? [:]
                    let match = Match(params: params, query: RoutePattern.decodedQuery(of: request.url))
                    return (try? handler(request, match)) ?? StubTransport.json(Data(#"{"message":"stub: handler failed"}"#.utf8), status: 500)
                }
            }
            set {
                handler = { request, _ in newValue(request) }
            }
        }

        public init(
            method: String = "GET",
            pathPattern: String,
            query: [String: String] = [:],
            respond: @escaping @Sendable (HTTPRequest) -> HTTPResponse
        ) {
            self.method = method
            self.pathPattern = pathPattern
            self.query = query
            self.handler = { request, _ in respond(request) }
        }

        public init(method: String = "GET", pathPattern: String, query: [String: String] = [:], handler: @escaping Handler) {
            self.method = method
            self.pathPattern = pathPattern
            self.query = query
            self.handler = handler
        }

        /// Always answers with `response`.
        public static func fixed(
            _ method: String = "GET",
            _ pathPattern: String,
            query: [String: String] = [:],
            response: HTTPResponse
        ) -> Route {
            Route(method: method, pathPattern: pathPattern, query: query) { _, _ in response }
        }

        /// `GET` answering with a JSON body.
        public static func getJSON(_ pathPattern: String, query: [String: String] = [:], _ json: String, status: Int = 200, headers: [String: String] = [:]) -> Route {
            fixed("GET", pathPattern, query: query, response: StubTransport.json(json, status: status, headers: headers))
        }

        /// Answers with `responses` in order, repeating the last one once exhausted.
        public static func sequence(
            _ method: String = "GET",
            _ pathPattern: String,
            query: [String: String] = [:],
            responses: [HTTPResponse]
        ) -> Route {
            let counter = CallCounter()
            return Route(method: method, pathPattern: pathPattern, query: query) { _, _ in
                let index = counter.next()
                guard let last = responses.last else { return StubTransport.empty(status: 204) }
                return index < responses.count ? responses[index] : last
            }
        }

        /// Throws `error` (e.g. `URLError(.timedOut)`) for every matching request.
        public static func failing(_ method: String = "GET", _ pathPattern: String, query: [String: String] = [:], error: URLError) -> Route {
            Route(method: method, pathPattern: pathPattern, query: query) { _, _ in throw error }
        }
    }

    private struct State {
        var routes: [Route]
        var requests: [HTTPRequest] = []
        var unmatched: [HTTPRequest] = []
    }

    /// Base URL routes are relative to (typically the provider's `apiURL`).
    public let baseURL: URL
    private let state: Mutex<State>

    public init(routes: [Route] = [], baseURL: URL) {
        self.baseURL = baseURL
        self.state = Mutex(State(routes: routes))
    }

    /// Adds a route; it wins over earlier routes of equal specificity.
    public func add(_ route: Route) {
        state.withLock { $0.routes.append(route) }
    }

    /// Adds several routes in order.
    public func add(_ routes: [Route]) {
        state.withLock { $0.routes.append(contentsOf: routes) }
    }

    /// Replaces every route (e.g. to move a fixture scenario to its next step).
    public func replaceRoutes(_ routes: [Route]) {
        state.withLock { $0.routes = routes }
    }

    /// Every request received, in order (matched or not).
    public var requests: [HTTPRequest] {
        state.withLock { $0.requests }
    }

    /// Requests that matched no route.
    public var unmatchedRequests: [HTTPRequest] {
        state.withLock { $0.unmatched }
    }

    /// Recorded requests whose path relative to `baseURL` equals `path` (percent-decoded), optionally filtered by
    /// method.
    public func requests(_ method: String? = nil, path: String) -> [HTTPRequest] {
        let wanted = RoutePattern.segments(of: path)
        return requests.filter { request in
            if let method, method.uppercased() != request.method.uppercased() { return false }
            return RoutePattern.relativeSegments(of: request.url, base: baseURL) == wanted
        }
    }

    /// Forgets recorded requests (routes stay).
    public func clearRequests() {
        state.withLock {
            $0.requests.removeAll()
            $0.unmatched.removeAll()
        }
    }

    // MARK: HTTPTransport

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if Task.isCancelled { throw URLError(.cancelled) }
        let found = state.withLock { state -> (Route, Match)? in
            state.requests.append(request)
            guard let found = Self.bestMatch(for: request, in: state.routes, baseURL: baseURL) else {
                state.unmatched.append(request)
                return nil
            }
            return found
        }
        guard let (route, match) = found else {
            return Self.noRoute(for: request, baseURL: baseURL)
        }
        // Run the handler outside the lock so it may call back into the transport.
        var response = try route.handler(request, match)
        if response.url == Self.placeholderURL {
            response.url = request.url
        }
        return response
    }

    private static func bestMatch(for request: HTTPRequest, in routes: [Route], baseURL: URL) -> (Route, Match)? {
        var best: (route: Route, match: Match, score: RoutePattern.Score)?
        let query = RoutePattern.decodedQuery(of: request.url)
        for (index, route) in routes.enumerated() {
            let method = route.method.uppercased()
            guard method == "*" || method == request.method.uppercased() else { continue }
            let pattern = RoutePattern(route.pathPattern, extraQuery: route.query)
            guard pattern.queryMatches(query),
                  let params = pattern.captures(in: request.url, base: baseURL)
            else { continue }
            let score = pattern.score(order: index)
            if let current = best, score <= current.score { continue }
            best = (route, Match(params: params, query: query), score)
        }
        return best.map { ($0.route, $0.match) }
    }

    // MARK: Response helpers

    /// Placeholder URL of helper-built responses; `send` replaces it with the request URL.
    public static let placeholderURL = URL(staticString: "stub://response")

    /// A JSON response (`content-type: application/json` unless given).
    public static func json(_ data: Data, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        var allHeaders = headers
        if !HTTPHeaders.contains("content-type", in: headers) {
            allHeaders["content-type"] = "application/json; charset=utf-8"
        }
        return HTTPResponse(status: status, headers: allHeaders, body: data, url: placeholderURL)
    }

    /// A JSON response from literal text.
    public static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        json(Data(text.utf8), status: status, headers: headers)
    }

    /// A JSON response from a `JSONValue` (sorted keys).
    public static func json(value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        json(value.jsonString(), status: status, headers: headers)
    }

    /// A JSON response encoding `value` with the wire encoder.
    public static func json<T: Encodable>(encoding value: T, status: Int = 200, headers: [String: String] = [:]) throws -> HTTPResponse {
        json(try MergeCueCoding.wireEncoder().encode(value), status: status, headers: headers)
    }

    /// A plain-text response (CI logs, diffs).
    public static func text(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        var allHeaders = headers
        if !HTTPHeaders.contains("content-type", in: headers) {
            allHeaders["content-type"] = "text/plain; charset=utf-8"
        }
        return HTTPResponse(status: status, headers: allHeaders, body: Data(text.utf8), url: placeholderURL)
    }

    /// A response without a body (`204`, `304`, …).
    public static func empty(status: Int, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(), url: placeholderURL)
    }

    /// The `404` returned for unmatched requests.
    public static func noRoute(for request: HTTPRequest, baseURL: URL) -> HTTPResponse {
        let path = request.url.path(percentEncoded: true)
        let message: JSONValue = ["message": .string("stub: no route for \(request.method) \(path)")]
        var response = json(value: message, status: 404)
        response.url = request.url
        return response
    }
}

extension HTTPRequest {
    /// The body parsed as JSON (nil when absent or invalid) — handy for asserting write payloads.
    public var jsonBody: JSONValue? {
        guard let body, !body.isEmpty else { return nil }
        return try? JSONValue.defaultDecoder().decode(JSONValue.self, from: body)
    }

    /// Decoded query items of the URL (`+` as space), in order.
    public var queryItems: [URLQueryItem] {
        RoutePattern.queryPairs(of: url).map { URLQueryItem(name: $0.0, value: $0.1) }
    }
}

/// A thread-safe call counter a `@Sendable` closure can capture.
private final class CallCounter: Sendable {
    private let value = Mutex(0)

    /// Returns the current count, then increments it.
    func next() -> Int {
        value.withLock { value in
            defer { value += 1 }
            return value
        }
    }
}
