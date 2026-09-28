import Foundation
import MCP
import MergeCueCore
import MergeCueIPC

/// Executes `tools/call`: validate arguments → forward them unchanged over IPC → wrap the result.
///
/// Success: the DTO JSON as one text content block **and** as `structuredContent`. Failure (local validation or
/// any IPC error, including `app_unavailable` when the app is not running): `isError: true` with
/// `{code, message, retryable, data?}` in both places. Nothing is ever synthesized locally.
public struct ToolCallRouter: Sendable {
    public let ipc: any MergeCueIPCCalling

    public init(ipc: any MergeCueIPCCalling) {
        self.ipc = ipc
    }

    /// Handles one call. Unknown tool names are a protocol error (`-32602`, as the MCP spec prescribes).
    public func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let definition = MergeCueToolCatalog.definition(named: params.name) else {
            throw MCPError.invalidParams("Unknown tool: \(String(params.name.prefix(128))). MergeCue offers: \(MergeCueToolCatalog.all.map(\.name).joined(separator: ", ")).")
        }
        let arguments = ValueBridge.arguments(params.arguments)
        return await call(definition, arguments: arguments)
    }

    /// Validates and forwards `arguments` for `definition`.
    public func call(_ definition: MergeCueToolDefinition, arguments: JSONValue) async -> CallTool.Result {
        do throws(IPCError) {
            try definition.validate(arguments: arguments)
            let result = try await ipc.callRaw(definition.method, params: arguments)
            return Self.success(result)
        } catch {
            return Self.failure(error)
        }
    }

    // MARK: Result encoding

    /// `{content: [text JSON], structuredContent: JSON, isError: false}`.
    public static func success(_ result: JSONValue) -> CallTool.Result {
        let structured: Value? = ValueBridge.value(result)
        return CallTool.Result(
            content: [.text(text: result.jsonString(), annotations: nil, _meta: nil)],
            structuredContent: structured,
            isError: false
        )
    }

    /// `{content: [text JSON], structuredContent: {code, message, retryable, data?}, isError: true}`.
    public static func failure(_ error: IPCError) -> CallTool.Result {
        let payload = errorPayload(error)
        let structured: Value? = ValueBridge.value(payload)
        return CallTool.Result(
            content: [.text(text: payload.jsonString(), annotations: nil, _meta: nil)],
            structuredContent: structured,
            isError: true
        )
    }

    /// The structured error agents see (message redacted once more).
    public static func errorPayload(_ error: IPCError) -> JSONValue {
        var members: [String: JSONValue] = [
            "code": .string(error.code.rawValue),
            "message": .string(SecretRedactor.redact(error.message)),
            "retryable": .bool(error.retryable),
        ]
        if let data = error.data, !data.isNull {
            members["data"] = data
        }
        return .object(members)
    }
}

/// Maps IPC errors to JSON-RPC errors for requests that have no `isError` result shape (resources, prompts).
enum ProtocolErrorMapping {
    /// MCP's "resource not found" code.
    static let resourceNotFoundCode = -32002
    /// Server-defined code for every other MergeCue failure (`-32000`/`-32001` are reserved by the SDK).
    static let mergeCueErrorCode = -32050

    static func mcpError(_ error: IPCError) -> MCPError {
        let message = "[\(error.code.rawValue)] \(SecretRedactor.redact(error.message))" + (error.retryable ? " (retryable)" : "")
        switch error.code {
        case .invalidParams:
            return .invalidParams(message)
        case .notFound:
            return .serverError(code: resourceNotFoundCode, message: message)
        default:
            return .serverError(code: mergeCueErrorCode, message: message)
        }
    }
}
