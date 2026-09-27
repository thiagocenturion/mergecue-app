import Foundation
import MergeCueCore

/// Machine-readable error codes shared by IPC and the MCP tools (`isError` results carry the same code).
public enum IPCErrorCode: String, Codable, Sendable, CaseIterable, Hashable {
    case appUnavailable = "app_unavailable"
    case unauthorized
    case invalidParams = "invalid_params"
    case notFound = "not_found"
    case versionConflict = "version_conflict"
    case leaseInvalid = "lease_invalid"
    case leaseExpired = "lease_expired"
    case invalidTransition = "invalid_transition"
    case terminalState = "terminal_state"
    case rateLimited = "rate_limited"
    case crossScopeReference = "cross_scope_reference"
    case pathOutsideCheckout = "path_outside_checkout"
    case validationFailed = "validation_failed"
    case unsupported
    case protocolVersion = "protocol_version"
    case internalError = "internal_error"

    /// Unknown codes (a newer app talking to an older client) decode as `internalError` instead of failing the
    /// whole response, so the message still reaches the agent.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = IPCErrorCode(rawValue: raw) ?? .internalError
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A structured IPC failure: `{code, message, retryable, data?}` on the wire.
///
/// Messages are user/agent facing and must never contain credentials; the server redacts them again with
/// `SecretRedactor` before they leave the process.
public struct IPCError: Error, Codable, Sendable, Equatable, Hashable, LocalizedError, CustomStringConvertible {
    public var code: IPCErrorCode
    public var message: String
    /// Whether retrying the same call later can succeed (app restarted, lease renewed, rate limit elapsed…).
    public var retryable: Bool
    /// Optional machine-readable details (e.g. `{"current_version": 7}` for `version_conflict`).
    public var data: JSONValue?

    public init(code: IPCErrorCode, message: String, retryable: Bool = false, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.data = data
    }

    /// Positional convenience: `IPCError(.notFound, "No task mc_abc123")`.
    public init(_ code: IPCErrorCode, _ message: String, retryable: Bool = false, data: JSONValue? = nil) {
        self.init(code: code, message: message, retryable: retryable, data: data)
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, retryable, data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(IPCErrorCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        let decodedData = try container.decodeIfPresent(JSONValue.self, forKey: .data)
        data = decodedData?.isNull == true ? nil : decodedData
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(retryable, forKey: .retryable)
        try container.encodeIfPresent(data, forKey: .data)
    }

    public var errorDescription: String? { message }

    public var description: String { "IPCError(\(code.rawValue): \(message))" }

    /// Copy with the message passed through `SecretRedactor` (applied by the server to every outgoing error).
    public var redacted: IPCError {
        var copy = self
        copy.message = SecretRedactor.redact(message)
        return copy
    }
}

// MARK: - Well-known errors

extension IPCError {
    /// The exact message agents see when the app is not reachable.
    public static let appUnavailableMessage = "MergeCue app is not running. Open MergeCue and retry."

    /// The app is not running / not reachable. Always retryable; the client never fabricates a result instead.
    public static func appUnavailable(_ message: String = appUnavailableMessage, reason: String? = nil) -> IPCError {
        IPCError(
            code: .appUnavailable,
            message: message,
            retryable: true,
            data: reason.map { ["reason": .string($0)] }
        )
    }

    /// Missing or wrong token, or a peer that failed the code-signature check.
    public static func unauthorized(_ message: String = "The request was not authorized by MergeCue.") -> IPCError {
        IPCError(code: .unauthorized, message: message, retryable: false)
    }

    /// Parameters could not be decoded or are out of range.
    public static func invalidParams(_ message: String, data: JSONValue? = nil) -> IPCError {
        IPCError(code: .invalidParams, message: message, retryable: false, data: data)
    }

    /// Semantically invalid input (e.g. "passed" tests with a non-zero exit code).
    public static func validationFailed(_ message: String, data: JSONValue? = nil) -> IPCError {
        IPCError(code: .validationFailed, message: message, retryable: false, data: data)
    }

    /// Request `v` other than `IPCProtocol.version`.
    public static func protocolVersion(received: Int?) -> IPCError {
        let got = received.map(String.init) ?? "missing"
        return IPCError(
            code: .protocolVersion,
            message: "Unsupported IPC protocol version \(got); MergeCue speaks version \(IPCProtocol.version). Update mergecue-mcp to match the app.",
            retryable: false,
            data: ["supported_versions": [.number(Double(IPCProtocol.version))]]
        )
    }

    /// Unexpected failure inside MergeCue.
    public static func internalError(_ message: String, retryable: Bool = false, reason: String? = nil) -> IPCError {
        IPCError(code: .internalError, message: message, retryable: retryable, data: reason.map { ["reason": .string($0)] })
    }
}
