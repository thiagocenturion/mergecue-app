import Foundation
import MergeCueCore

/// Implements the IPC methods (the engine in the app). The server has already checked the protocol version, the
/// token and the method name; the handler decodes `params` itself (`IPCCoding.decodeParams` → `invalid_params`)
/// and returns an encoded result (`IPCCoding.result(_:)`) or a structured error.
///
/// Requests from one connection are delivered one at a time, in order; different connections run concurrently.
public protocol IPCRequestHandling: Sendable {
    func handle(method: IPCMethod, params: JSONValue, client: IPCClientInfo) async -> Result<JSONValue, IPCError>
}

/// Closure-backed handler (tests, simulators, thin adapters).
public struct IPCClosureHandler: IPCRequestHandling {
    public typealias Body = @Sendable (IPCMethod, JSONValue, IPCClientInfo) async -> Result<JSONValue, IPCError>

    private let body: Body

    public init(_ body: @escaping Body) {
        self.body = body
    }

    public func handle(method: IPCMethod, params: JSONValue, client: IPCClientInfo) async -> Result<JSONValue, IPCError> {
        await body(method, params, client)
    }
}
