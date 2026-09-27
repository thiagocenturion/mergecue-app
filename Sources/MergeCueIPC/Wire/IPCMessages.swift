import Foundation
import MergeCueCore

/// Protocol-level constants of the private channel.
public enum IPCProtocol {
    /// The only protocol version this build speaks (`v` of every request/response).
    public static let version = 1
    /// Maximum size of one newline-delimited JSON frame, excluding the `\n` (4 MiB).
    public static let maxFrameBytes = 4 * 1024 * 1024
    /// Length of the per-launch token in hex characters (32 random bytes).
    public static let tokenHexLength = 64
    /// Upper bound for request ids and client name/version strings.
    public static let maxIdentifierLength = 256
}

/// Who is calling (the MCP server, the agent simulator, a verification client…).
///
/// The server replaces `pid` with the kernel-reported peer pid (`LOCAL_PEERPID`) when it is available, so the
/// handler never trusts a self-declared process id.
public struct IPCClientInfo: Codable, Sendable, Hashable {
    public var name: String
    public var version: String
    public var pid: Int32

    public init(name: String, version: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.name = name
        self.version = version
        self.pid = pid
    }
}

/// One request frame: `{"v":1,"id":"…","token":"…","client":{…},"method":"…","params":{…}}`.
///
/// `description`, `debugDescription` and reflection never include the token.
public struct IPCRequest: Codable, Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var v: Int
    public var id: String
    public var token: String
    public var client: IPCClientInfo
    public var method: IPCMethod
    /// Method parameters (an object; `{}` when the method takes none).
    public var params: JSONValue

    public init(v: Int = IPCProtocol.version, id: String, token: String, client: IPCClientInfo, method: IPCMethod, params: JSONValue = .object([:])) {
        self.v = v
        self.id = id
        self.token = token
        self.client = client
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case v, id, token, client, method, params
    }

    /// A missing or `null` `params` member decodes as `{}`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        id = try container.decode(String.self, forKey: .id)
        token = try container.decode(String.self, forKey: .token)
        client = try container.decode(IPCClientInfo.self, forKey: .client)
        method = try container.decode(IPCMethod.self, forKey: .method)
        if let decodedParams = try container.decodeIfPresent(JSONValue.self, forKey: .params), !decodedParams.isNull {
            params = decodedParams
        } else {
            params = .object([:])
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(token, forKey: .token)
        try container.encode(client, forKey: .client)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
    }

    public var description: String {
        "IPCRequest(v: \(v), id: \(id), method: \(method.rawValue), client: \(client.name) \(client.version), token: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["v": v, "id": id, "client": client, "method": method, "params": params], displayStyle: .struct)
    }
}

/// One response frame: `{"v":1,"id":"…","result":{…}}` or `{"v":1,"id":"…","error":{…}}`.
///
/// `id` echoes the request id; connection-level rejections that precede any request (a peer that failed the
/// code-signature check, an oversize or malformed frame) use `""`.
public struct IPCResponse: Codable, Sendable, Hashable {
    public var v: Int
    public var id: String
    public var result: JSONValue?
    public var error: IPCError?

    public init(v: Int = IPCProtocol.version, id: String, result: JSONValue? = nil, error: IPCError? = nil) {
        self.v = v
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: String, result: JSONValue) -> IPCResponse {
        IPCResponse(id: id, result: result)
    }

    public static func failure(id: String, error: IPCError) -> IPCResponse {
        IPCResponse(id: id, error: error)
    }

    /// `.success(result)` / `.failure(error)`. A response carrying neither (or both) is a protocol violation and
    /// maps to `internal_error` — the client never invents a result.
    public var outcome: Result<JSONValue, IPCError> {
        switch (result, error) {
        case (_, .some(let error)):
            .failure(error)
        case (.some(let result), .none):
            .success(result)
        case (.none, .none):
            .failure(.internalError("MergeCue sent a response without a result or an error.", reason: "malformed_response"))
        }
    }
}
