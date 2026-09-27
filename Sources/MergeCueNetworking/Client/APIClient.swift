import Foundation
import MergeCueCore

/// A provider REST client bound to one account: base URL, credential, rate-limit parser, retry policy and ETag
/// cache.
///
/// - Paths are joined onto `baseURL` keeping its path prefix (see `RequestURLBuilder`); absolute URLs (pagination
///   `next` links) must share the base URL's origin, so the credential is never sent to another host.
/// - Every request carries `Authorization` from the credential (it wins over caller headers) and is never logged.
/// - Non-2xx responses throw `ProviderError` (`mapHTTPError`); transport failures throw `.offline`/`.timeout`/…
///   (`mapTransportError`); cancellation throws `CancellationError`. Thrown messages are scrubbed of the
///   credential's secret material in addition to `SecretRedactor` patterns.
/// - `GET`/`HEAD` are retried on 5xx/408, timeouts and offline errors with jittered exponential backoff, up to
///   `retry.maxAttempts`. `Retry-After` is honoured when it is ≤ `retry.maxRetryAfter` (60 s); a longer wait
///   surfaces `.rateLimited` immediately. Writes are never retried automatically.
/// - With `useETag`, a cached `ETag` is sent as `If-None-Match`; a `304` returns the cached body with status 200
///   and header `x-mergecue-cache: hit`.
public actor APIClient {
    public nonisolated let baseURL: URL
    public nonisolated let retry: RetryPolicy

    private let credential: Credential
    private let transport: any HTTPTransport
    private let rateLimitParser: any RateLimitParsing
    private let etagCache: ETagCache?
    private let clock: any MCClock
    private let extraHeaders: [String: String]
    private let jitter: @Sendable () -> Double
    private let scrubber: CredentialScrubber

    /// Rate-limit information from the most recent response that carried any.
    public private(set) var lastRateLimit: RateLimitInfo?

    /// - Parameters:
    ///   - baseURL: API root, e.g. `https://api.github.com` or `https://gitlab.com/api/v4`.
    ///   - extraHeaders: Sent with every request (e.g. `Accept`, `X-GitHub-Api-Version`); cannot override
    ///     `Authorization`.
    ///   - jitter: Source of backoff jitter in `0...1` (inject a constant in tests).
    public init(
        baseURL: URL,
        credential: Credential,
        transport: any HTTPTransport,
        rateLimitParser: any RateLimitParsing,
        retry: RetryPolicy = .default,
        etagCache: ETagCache? = ETagCache(),
        clock: any MCClock = SystemClock(),
        extraHeaders: [String: String] = [:],
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.transport = transport
        self.rateLimitParser = rateLimitParser
        self.retry = retry
        self.etagCache = etagCache
        self.clock = clock
        self.extraHeaders = extraHeaders
        self.jitter = jitter
        self.scrubber = CredentialScrubber(credential)
    }

    // MARK: Reads

    /// `GET baseURL + path` (`path` may also be a same-origin absolute URL).
    public func get(
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        useETag: Bool = false
    ) async throws -> HTTPResponse {
        let url = try url(for: path, query: query)
        return try await perform(HTTPRequest(method: "GET", url: url, headers: headers), useETag: useETag)
    }

    /// `GET` and decode the body as `T` (default decoder: `JSONDecoder.mergeCueProvider`). Decoding happens off
    /// the actor.
    public nonisolated func getJSON<T: Decodable>(
        _ type: T.Type,
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        useETag: Bool = false,
        decoder: JSONDecoder = .mergeCueProvider
    ) async throws -> T {
        let response = try await get(path, query: query, headers: headers, useETag: useETag)
        return try Self.decode(type, from: response, decoder: decoder)
    }

    /// `GET` an absolute URL (pagination `next` links). The URL must have the base URL's origin.
    public func getAbsolute(_ url: URL, headers: [String: String] = [:], useETag: Bool = false) async throws -> HTTPResponse {
        try checkSameOrigin(url)
        return try await perform(HTTPRequest(method: "GET", url: url, headers: headers), useETag: useETag)
    }

    // MARK: Writes

    /// Sends `method` to `baseURL + path` with an optional JSON body (encoded with `MergeCueCoding.wireEncoder()`).
    /// Non-`GET` requests are never retried.
    public func send(
        _ method: String,
        _ path: String,
        json: (any Encodable & Sendable)? = nil,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        let url = try url(for: path)
        return try await sendRequest(method, url: url, json: json, headers: headers)
    }

    /// Sends a raw body (e.g. form-encoded) to `baseURL + path`.
    public func send(
        _ method: String,
        _ path: String,
        body: Data?,
        contentType: String?,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        let url = try url(for: path)
        var allHeaders = headers
        if let contentType, !HTTPHeaders.contains("Content-Type", in: headers) {
            allHeaders["Content-Type"] = contentType
        }
        return try await perform(HTTPRequest(method: method, url: url, headers: allHeaders, body: body), useETag: false)
    }

    /// Sends a JSON body to a same-origin absolute URL (e.g. a GraphQL endpoint outside the REST prefix).
    public func sendAbsolute(
        _ method: String,
        _ url: URL,
        json: (any Encodable & Sendable)?,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        try checkSameOrigin(url)
        return try await sendRequest(method, url: url, json: json, headers: headers)
    }

    /// `send` + decode the response body.
    public nonisolated func sendJSON<T: Decodable>(
        _ type: T.Type,
        _ method: String,
        _ path: String,
        json: (any Encodable & Sendable)?,
        headers: [String: String] = [:],
        decoder: JSONDecoder = .mergeCueProvider
    ) async throws -> T {
        let response = try await send(method, path, json: json, headers: headers)
        return try Self.decode(type, from: response, decoder: decoder)
    }

    // MARK: URLs and decoding

    /// The URL `path` + `query` resolves to. Same-origin absolute URLs are accepted (query items are appended).
    ///
    /// - Throws: `ProviderError.invalidRequest` for dot segments or a different origin.
    public nonisolated func url(for path: String, query: [URLQueryItem] = []) throws -> URL {
        let lower = path.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            guard let absolute = URL(string: path) else {
                throw ProviderError.invalidRequest("Invalid request URL.")
            }
            try checkSameOrigin(absolute)
            guard !query.isEmpty else { return absolute }
            guard var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false) else {
                throw ProviderError.invalidRequest("Invalid request URL.")
            }
            let extra = RequestURLBuilder.encodeQuery(query)
            components.percentEncodedQuery = [components.percentEncodedQuery, extra]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: "&")
            guard let url = components.url else { throw ProviderError.invalidRequest("Invalid request URL.") }
            return url
        }
        return try RequestURLBuilder.url(baseURL: baseURL, path: path, query: query)
    }

    /// Decodes `response.body` as `T`; failures become `ProviderError.decoding` (no body content is included).
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from response: HTTPResponse,
        decoder: JSONDecoder = .mergeCueProvider
    ) throws -> T {
        do {
            return try decoder.decode(type, from: response.body)
        } catch let error as DecodingError {
            throw ProviderError.decoding("\(T.self) from \(response.url.path): \(Self.describe(error))")
        } catch {
            throw ProviderError.decoding("\(T.self) from \(response.url.path): invalid JSON.")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let components = context.codingPath.map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }
            return components.isEmpty ? "<root>" : components.joined(separator: ".")
        }
        let text: String = switch error {
        case .typeMismatch(let type, let context): "type mismatch (expected \(type)) at \(path(context))"
        case .valueNotFound(let type, let context): "missing \(type) value at \(path(context))"
        case .keyNotFound(let key, let context): "missing key \"\(key.stringValue)\" at \(path(context))"
        case .dataCorrupted(let context): "invalid data at \(path(context)): \(context.debugDescription)"
        @unknown default: "invalid data"
        }
        return SecretRedactor.redact(BoundedText.truncate(text, maxBytes: 300).text)
    }

    private nonisolated func checkSameOrigin(_ url: URL) throws {
        guard Origin(url) == Origin(baseURL) else {
            throw ProviderError.invalidRequest("Refusing to send credentials to a different host.")
        }
    }

    // MARK: Pipeline

    private func sendRequest(
        _ method: String,
        url: URL,
        json: (any Encodable & Sendable)?,
        headers: [String: String]
    ) async throws -> HTTPResponse {
        var allHeaders = headers
        var body: Data?
        if let json {
            do {
                body = try MergeCueCoding.wireEncoder().encode(json)
            } catch {
                throw ProviderError.invalidRequest("Could not encode the request body.")
            }
            if !HTTPHeaders.contains("Content-Type", in: headers) {
                allHeaders["Content-Type"] = "application/json"
            }
        }
        return try await perform(HTTPRequest(method: method, url: url, headers: allHeaders, body: body), useETag: false)
    }

    private enum FailureDecision {
        case retry(after: TimeInterval)
        case fail(ProviderError)
    }

    private func perform(_ original: HTTPRequest, useETag: Bool) async throws -> HTTPResponse {
        var request = original
        request.headers = HTTPHeaders.merged(
            ["Accept": "application/json"],
            extraHeaders,
            original.headers,
            ["Authorization": credential.authorizationHeaderValue()]
        )
        let canRetry = request.isIdempotentRead
        let cache = useETag && request.method.uppercased() == "GET" ? etagCache : nil
        var cached: ETagCache.Entry?
        if let cache, !HTTPHeaders.contains("If-None-Match", in: request.headers) {
            cached = await cache.entry(for: request.url)
            if let cached {
                request.headers["If-None-Match"] = cached.etag
            }
        }
        let maxAttempts = max(1, retry.maxAttempts)
        var attempt = 0

        while true {
            attempt += 1
            try Task.checkCancellation()

            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                if isCancellation(error) { throw CancellationError() }
                let mapped = mapTransportError(error)
                if canRetry, attempt < maxAttempts, mapped == .timeout || mapped == .offline {
                    let delay = retry.delay(forAttempt: attempt, jitter: jitter())
                    MCLog.providers.debug("\(request.method) attempt \(attempt) failed (\(mapped.code)); retrying in \(delay) s")
                    try await clock.sleep(for: delay)
                    continue
                }
                throw scrubber.scrub(mapped)
            }

            if let info = rateLimitParser.parse(response) {
                lastRateLimit = info
            }
            if response.status == 304, let cached {
                return Self.cacheHit(response, cached: cached)
            }
            if response.isSuccess || response.status == 304 {
                if let cache, response.status == 200 {
                    if let etag = response.header("etag"), !etag.isEmpty {
                        await cache.set(request.url, etag: etag, body: response.body, headers: response.headers)
                    } else {
                        await cache.remove(request.url)
                    }
                }
                return response
            }

            let error = mapHTTPError(response, parser: rateLimitParser)
                ?? .server(status: response.status, message: "Unexpected HTTP status \(response.status).")
            switch decide(after: response, error: error, attempt: attempt, maxAttempts: maxAttempts, canRetry: canRetry) {
            case .retry(let delay):
                MCLog.providers.debug("\(request.method) attempt \(attempt) got HTTP \(response.status); retrying in \(delay) s")
                try await clock.sleep(for: delay)
            case .fail(let failure):
                throw scrubber.scrub(failure)
            }
        }
    }

    private func decide(
        after response: HTTPResponse,
        error: ProviderError,
        attempt: Int,
        maxAttempts: Int,
        canRetry: Bool
    ) -> FailureDecision {
        guard canRetry else { return .fail(error) }
        let retryAfter = RateLimitHeaderParsing.combined(response, preferred: rateLimitParser)?.retryAfter
        switch error {
        case .rateLimited:
            guard let retryAfter, retryAfter <= retry.maxRetryAfter, attempt < maxAttempts else { return .fail(error) }
            return .retry(after: retryAfter)
        case .server(let status, _) where status >= 500 || status == 408:
            if let retryAfter {
                guard retryAfter <= retry.maxRetryAfter else {
                    return .fail(.rateLimited(resetAt: clock.now.addingTimeInterval(retryAfter), retryAfter: retryAfter))
                }
                return attempt < maxAttempts ? .retry(after: retryAfter) : .fail(error)
            }
            guard attempt < maxAttempts else { return .fail(error) }
            return .retry(after: retry.delay(forAttempt: attempt, jitter: jitter()))
        default:
            return .fail(error)
        }
    }

    /// Headers that describe the 304 itself rather than the cached representation.
    private static let notModifiedExcludedHeaders: Set<String> = ["content-length", "content-encoding", "transfer-encoding"]

    private static func cacheHit(_ notModified: HTTPResponse, cached: ETagCache.Entry) -> HTTPResponse {
        var headers = cached.headers
        for (name, value) in notModified.headers where !notModifiedExcludedHeaders.contains(name) {
            headers[name] = value
        }
        if headers["etag"] == nil {
            headers["etag"] = cached.etag
        }
        headers[HTTPHeaders.cacheStatus] = "hit"
        return HTTPResponse(status: 200, headers: headers, body: cached.body, url: notModified.url)
    }
}

// MARK: - Credential scrubbing

/// Removes the literal secret material of one credential from error text (covers opaque tokens that
/// `SecretRedactor` cannot recognize by shape).
struct CredentialScrubber: Sendable {
    private let secrets: [String]

    init(_ credential: Credential) {
        var values: [String] = [credential.authorizationHeaderValue()]
        switch credential.secret {
        case .bearer(let token):
            values.append(token)
        case .basic(let username, let password):
            let pair = "\(username):\(password)"
            values.append(contentsOf: [password, pair, Data(pair.utf8).base64EncodedString()])
        }
        if let refreshToken = credential.refreshToken {
            values.append(refreshToken)
        }
        for value in values {
            let encoded = RequestURLBuilder.encodeQueryComponent(value)
            if encoded != value { values.append(encoded) }
        }
        // Longest first so a token is not partially replaced by a shorter overlapping secret.
        secrets = Array(Set(values.filter { $0.count >= 4 })).sorted { ($0.count, $0) > ($1.count, $1) }
    }

    func scrub(_ text: String) -> String {
        var result = text
        for secret in secrets where result.contains(secret) {
            result = result.replacingOccurrences(of: secret, with: SecretRedactor.marker)
        }
        return SecretRedactor.redact(result)
    }

    func scrub(_ error: ProviderError) -> ProviderError {
        switch error {
        case .unauthorized(let message):
            .unauthorized(scrub(message))
        case .forbidden(let scope, let message):
            .forbidden(missingScope: scope.map(scrub), message: scrub(message))
        case .notFound(let message):
            .notFound(scrub(message))
        case .server(let status, let message):
            .server(status: status, message: scrub(message))
        case .decoding(let message):
            .decoding(scrub(message))
        case .unsupported(let capability, let reason):
            .unsupported(capability, reason: scrub(reason))
        case .conflict(let message):
            .conflict(scrub(message))
        case .invalidRequest(let message):
            .invalidRequest(scrub(message))
        case .rateLimited, .offline, .timeout:
            error
        }
    }
}
