import Foundation
import MergeCueCore

/// Client side of the private channel (used by `mergecue-mcp`, the agent simulator and verification clients).
///
/// Each call reads the current token, opens its own connection, sends one request and waits for its response
/// (bounded by `timeout`), so concurrent calls never block each other and an app restart (new token) is picked up
/// automatically. Every failure is a structured `IPCError`; the client never fabricates a result:
/// - app not running (no socket, `ECONNREFUSED`, no token), timeouts, or a connection closed before the answer →
///   `app_unavailable` (retryable), message `IPCError.appUnavailableMessage` when it simply is not running;
/// - server errors are passed through unchanged; an unexpected result shape is `internal_error`.
public actor IPCClient {
    public nonisolated let paths: MergeCuePaths
    public nonisolated let clientInfo: IPCClientInfo
    /// Seconds to wait for a response.
    public nonisolated let timeout: TimeInterval

    public init(paths: MergeCuePaths, clientInfo: IPCClientInfo, timeout: TimeInterval = 15) {
        self.paths = paths
        self.clientInfo = clientInfo
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 15
    }

    /// Calls `method` with `params` and decodes the result as `R`.
    public func call<P: Encodable & Sendable, R: Decodable & Sendable>(_ method: IPCMethod, _ params: P, as type: R.Type) async throws(IPCError) -> R {
        let encoded: JSONValue
        do {
            encoded = try JSONValue(encoding: params, encoder: IPCCoding.encoder())
        } catch {
            throw IPCError.invalidParams("The parameters for \(method.rawValue) could not be encoded: \(IPCCoding.bounded(String(describing: error)))")
        }
        let result = try await callRaw(method, params: encoded)
        return try IPCCoding.decodeResult(type, from: result, method: method)
    }

    /// Typed call: `try await client.call(ClaimTaskParams(…))` → `ClaimTaskResult`.
    public func call<P: IPCMethodParams>(_ params: P) async throws(IPCError) -> P.Output {
        try await call(P.method, params, as: P.Output.self)
    }

    /// Untyped call (the MCP bridge forwards tool arguments as-is and returns the result JSON).
    public func callRaw(_ method: IPCMethod, params: JSONValue = .object([:])) async throws(IPCError) -> JSONValue {
        let request = IPCClientExchange.Request(id: Self.makeRequestID(), client: clientInfo, method: method, params: params)
        let outcome = await IPCClientExchange.perform(
            request,
            socketPath: paths.socketPath,
            tokenPath: MergeCuePaths.fileSystemPath(paths.ipcToken),
            timeout: timeout
        )
        return try outcome.get()
    }

    /// `ping` convenience (connection check used by `mergecue-mcp --self-test`).
    public func ping() async throws(IPCError) -> PingResult {
        try await call(PingParams())
    }

    private static func makeRequestID() -> String {
        "req_" + UUID().uuidString.lowercased()
    }
}
