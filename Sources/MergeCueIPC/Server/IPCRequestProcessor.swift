import Foundation
import MergeCueCore

/// Turns one request frame into one response frame: token (constant time; closes the connection on failure, so
/// nothing — not even the protocol version — is answered before authentication) → protocol version → method →
/// client info → params shape → handler. Stateless and `Sendable`; each connection calls it sequentially.
struct IPCRequestProcessor: Sendable {
    struct Reply: Sendable {
        var data: Data
        /// Close the connection after writing `data` (bad token, malformed or oversize frame).
        var closeConnection: Bool
    }

    let token: String
    let handler: any IPCRequestHandling
    let maxFrameBytes: Int
    private let log = MCLog.ipc

    init(token: String, handler: any IPCRequestHandling, maxFrameBytes: Int) {
        self.token = token
        self.handler = handler
        self.maxFrameBytes = maxFrameBytes
    }

    func process(_ frame: Data, peer: IPCPeerCredentials) async -> Reply {
        guard let parsed = try? IPCCoding.decoder().decode(JSONValue.self, from: frame), let object = parsed.objectValue else {
            log.notice("IPC: malformed request frame from \(peer)")
            return reply(id: "", error: .invalidParams("Malformed request: each line must be one JSON object."), close: true)
        }
        let rawID = object["id"]?.stringValue
        let id = rawID.flatMap { $0.count <= IPCProtocol.maxIdentifierLength ? $0 : nil } ?? ""

        guard let presented = object["token"]?.stringValue, Self.tokensMatch(presented, token) else {
            log.notice("IPC: rejected a request with a missing or wrong token from \(peer)")
            return reply(
                id: id,
                error: .unauthorized("Missing or invalid MergeCue IPC token. Restart the MergeCue MCP server so it reads the current token."),
                close: true
            )
        }
        let version = object["v"]?.intValue
        guard version == IPCProtocol.version else {
            return reply(id: id, error: .protocolVersion(received: version), close: false)
        }
        guard rawID != nil, !id.isEmpty else {
            return reply(id: "", error: .invalidParams("Request 'id' must be a non-empty string of at most \(IPCProtocol.maxIdentifierLength) characters."), close: false)
        }
        guard let methodName = object["method"]?.stringValue else {
            return reply(id: id, error: .invalidParams("Missing 'method'."), close: false)
        }
        guard let method = IPCMethod(rawValue: methodName) else {
            return reply(id: id, error: IPCError(.unsupported, "Unknown method '\(methodName.prefix(64))'."), close: false)
        }
        guard var client = object["client"].flatMap({ try? $0.decode(IPCClientInfo.self, decoder: IPCCoding.decoder()) }),
              client.name.count <= IPCProtocol.maxIdentifierLength,
              client.version.count <= IPCProtocol.maxIdentifierLength
        else {
            return reply(id: id, error: .invalidParams("Missing or malformed 'client' (expected {name, version, pid})."), close: false)
        }
        if let pid = peer.pid {
            client.pid = pid
        }
        var params = object["params"] ?? .object([:])
        if params.isNull {
            params = .object([:])
        }
        guard params.objectValue != nil else {
            return reply(id: id, error: .invalidParams("'params' must be a JSON object."), close: false)
        }

        switch await handler.handle(method: method, params: params, client: client) {
        case .success(let result):
            return encode(IPCResponse.success(id: id, result: result), id: id, close: false)
        case .failure(let error):
            return reply(id: id, error: error, close: false)
        }
    }

    /// Reply for a frame that exceeded the size limit (the stream is out of sync: close).
    func frameTooLargeReply() -> Reply {
        reply(
            id: "",
            error: .invalidParams("Request frame exceeds the \(maxFrameBytes / (1024 * 1024)) MiB IPC limit; the connection is closed."),
            close: true
        )
    }

    /// Connection-level rejection sent before any request was read (peer failed validation).
    static func rejectionFrame(_ error: IPCError) -> Data {
        encodeOrFallback(IPCResponse.failure(id: "", error: error.redacted))
    }

    // MARK: Helpers

    private func reply(id: String, error: IPCError, close: Bool) -> Reply {
        encode(IPCResponse.failure(id: id, error: error.redacted), id: id, close: close)
    }

    private func encode(_ response: IPCResponse, id: String, close: Bool) -> Reply {
        guard let data = try? IPCCoding.encodeFrame(response) else {
            let fallback = IPCError.internalError("MergeCue could not encode the response.")
            return Reply(data: Self.encodeOrFallback(IPCResponse.failure(id: id, error: fallback)), closeConnection: close)
        }
        guard data.count <= maxFrameBytes else {
            let tooLarge = IPCError.internalError(
                "The response exceeds the \(maxFrameBytes / (1024 * 1024)) MiB IPC frame limit. Request less data (lower 'limit' or 'max_bytes')."
            )
            return Reply(data: Self.encodeOrFallback(IPCResponse.failure(id: id, error: tooLarge)), closeConnection: close)
        }
        return Reply(data: data, closeConnection: close)
    }

    private static func encodeOrFallback(_ response: IPCResponse) -> Data {
        if let data = try? IPCCoding.encodeFrame(response) {
            return data
        }
        return Data(#"{"error":{"code":"internal_error","message":"MergeCue could not encode the response.","retryable":false},"id":"","v":1}"#.utf8)
    }

    /// Constant-time comparison (time depends only on the expected token's length).
    static func tokensMatch(_ presented: String, _ expected: String) -> Bool {
        let presentedBytes = Array(presented.utf8)
        let expectedBytes = Array(expected.utf8)
        var difference: UInt8 = presentedBytes.count == expectedBytes.count ? 0 : 1
        for index in expectedBytes.indices {
            let byte = index < presentedBytes.count ? presentedBytes[index] : 0
            difference |= byte ^ expectedBytes[index]
        }
        return difference == 0 && !expectedBytes.isEmpty
    }
}
