import Foundation
import MergeCueCore

/// The production transport: an ephemeral `URLSession` with no cookies, no URL cache and no stored URL
/// credentials, a 30 s request timeout and `User-Agent: MergeCue/<version>`.
///
/// Redirects are followed, but credential-bearing headers are stripped when a redirect leaves the original origin
/// (e.g. GitHub Actions log downloads redirect to blob storage), and `https` → `http` downgrades are refused (the
/// 3xx response is returned as-is).
public final class URLSessionTransport: HTTPTransport {
    /// Default per-request timeout in seconds.
    public static let defaultTimeout: TimeInterval = 30

    public let timeout: TimeInterval
    public let userAgent: String
    private let session: URLSession

    /// - Parameters:
    ///   - timeout: Idle timeout per request (default 30 s). The whole transfer may take up to 10× longer so large
    ///     CI logs can finish downloading.
    ///   - userAgent: Defaults to `MergeCue/<CFBundleShortVersionString>` (or `MergeCue/dev`).
    public init(timeout: TimeInterval = URLSessionTransport.defaultTimeout, userAgent: String = URLSessionTransport.defaultUserAgent) {
        let timeout = timeout.isFinite && timeout > 0 ? timeout : Self.defaultTimeout
        self.timeout = timeout
        self.userAgent = userAgent
        self.session = URLSession(
            configuration: Self.makeConfiguration(timeout: timeout, userAgent: userAgent),
            delegate: RedirectGuard(),
            delegateQueue: nil
        )
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    // MARK: Configuration

    /// The session configuration used by the transport (exposed for tests).
    public static func makeConfiguration(timeout: TimeInterval, userAgent: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 10
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return configuration
    }

    /// `MergeCue/<version>` from the main bundle's `CFBundleShortVersionString`, or `MergeCue/dev`.
    public static var defaultUserAgent: String {
        userAgent(forVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    /// `MergeCue/<version>`; a missing, empty or malformed version becomes `dev`.
    public static func userAgent(forVersion version: String?) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_+")
        let trimmed = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isValid = !trimmed.isEmpty && trimmed.count <= 64
            && trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
        return "MergeCue/\(isValid ? trimmed : "dev")"
    }

    // MARK: HTTPTransport

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = makeURLRequest(request)
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name] = (value as? String) ?? String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data, url: http.url ?? request.url)
    }

    func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if urlRequest.value(forHTTPHeaderField: "User-Agent") == nil {
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }
}

// MARK: - Redirects

/// Decides how a redirect is followed without leaking credentials to another origin.
public enum RedirectPolicy {
    /// Headers removed when a redirect changes scheme, host or port.
    public static let credentialHeaders = ["Authorization", "Proxy-Authorization", "PRIVATE-TOKEN", "JOB-TOKEN", "Cookie"]

    /// The request to follow for a redirect from `original` to `proposed`, or nil to stop (the 3xx is returned).
    /// Cross-origin redirects lose credential-bearing headers; `https` → `http` downgrades are refused.
    public static func followRequest(original: URLRequest?, proposed: URLRequest) -> URLRequest? {
        guard let target = proposed.url, let scheme = target.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        guard let source = original?.url else {
            return stripCredentials(proposed)
        }
        if source.scheme?.lowercased() == "https", scheme == "http" {
            return nil
        }
        return Origin(source) == Origin(target) ? proposed : stripCredentials(proposed)
    }

    private static func stripCredentials(_ request: URLRequest) -> URLRequest {
        var copy = request
        for name in credentialHeaders {
            copy.setValue(nil, forHTTPHeaderField: name)
        }
        return copy
    }
}

/// Scheme + host + effective port.
struct Origin: Hashable {
    let scheme: String
    let host: String
    let port: Int?

    init(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        self.scheme = scheme
        self.host = url.host(percentEncoded: false)?.lowercased() ?? ""
        switch (url.port, scheme) {
        case (.some(let port), _): self.port = port
        case (nil, "https"): self.port = 443
        case (nil, "http"): self.port = 80
        default: self.port = nil
        }
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        RedirectPolicy.followRequest(original: task.originalRequest, proposed: request)
    }
}
