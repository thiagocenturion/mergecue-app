import Foundation
import MergeCueCore

/// Shared coding for the private channel and the MCP tools: the `MergeCueCoding` wire coders (sorted keys,
/// RFC 3339 UTC dates with millisecond precision) plus `JSONValue` ⇄ DTO conversions that map failures to the
/// right `IPCError` codes.
///
/// Handlers decode `params` with `decodeParams` (→ `invalid_params`) and encode results with `encodeValue`
/// (→ `internal_error`); the client decodes results with `decodeResult` (→ `internal_error`, never a guess).
public enum IPCCoding {
    /// Maximum length of a generated error message about a decoding failure.
    static let maxDiagnosticLength = 400

    /// The wire encoder (`MergeCueCoding.wireEncoder()`).
    public static func encoder() -> JSONEncoder {
        MergeCueCoding.wireEncoder()
    }

    /// The wire decoder (`MergeCueCoding.wireDecoder()`).
    public static func decoder() -> JSONDecoder {
        MergeCueCoding.wireDecoder()
    }

    // MARK: JSONValue ⇄ DTO

    /// Encodes a DTO into a `JSONValue` with the wire encoder. Failures are `internal_error`.
    public static func encodeValue<T: Encodable>(_ value: T) throws(IPCError) -> JSONValue {
        do {
            return try JSONValue(encoding: value, encoder: encoder())
        } catch {
            throw IPCError.internalError("MergeCue could not encode \(String(describing: T.self)): \(bounded(String(describing: error)))")
        }
    }

    /// Handler convenience: `.success(<encoded value>)` or `.failure(internal_error)`.
    public static func result<T: Encodable>(_ value: T) -> Result<JSONValue, IPCError> {
        do throws(IPCError) {
            return .success(try encodeValue(value))
        } catch {
            return .failure(error)
        }
    }

    /// Decodes request parameters. Structural failures are `invalid_params` with a message naming the offending
    /// field (e.g. `Missing required parameter 'task_id'.`). Does not run `IPCMethodParams.validate()`.
    public static func decodeParams<T: Decodable>(_ type: T.Type, from params: JSONValue) throws(IPCError) -> T {
        let normalized: JSONValue = params.isNull ? .object([:]) : params
        guard normalized.objectValue != nil else {
            throw IPCError.invalidParams("Parameters must be a JSON object.")
        }
        do {
            return try normalized.decode(type, decoder: decoder())
        } catch let error as DecodingError {
            throw IPCError.invalidParams(describe(error))
        } catch {
            throw IPCError.invalidParams("Invalid parameters: \(bounded(String(describing: error)))")
        }
    }

    /// Decodes then validates (`IPCMethodParams.validate()`); both failures are returned as `IPCError`s.
    public static func decodeValidatedParams<P: IPCMethodParams>(_ type: P.Type, from params: JSONValue) throws(IPCError) -> P {
        let decoded = try decodeParams(type, from: params)
        try decoded.validate()
        return decoded
    }

    /// Decodes a method result on the client side. A shape mismatch is an `internal_error` (the client reports
    /// the problem instead of fabricating data).
    public static func decodeResult<T: Decodable>(_ type: T.Type, from result: JSONValue, method: IPCMethod) throws(IPCError) -> T {
        do {
            return try result.decode(type, decoder: decoder())
        } catch let error as DecodingError {
            throw IPCError.internalError("MergeCue returned an unexpected result for \(method.rawValue): \(describe(error))", reason: "unexpected_result")
        } catch {
            throw IPCError.internalError("MergeCue returned an unexpected result for \(method.rawValue).", reason: "unexpected_result")
        }
    }

    // MARK: Frames

    /// Encodes one frame body (no trailing newline) with the wire encoder.
    static func encodeFrame<T: Encodable>(_ message: T) throws -> Data {
        try encoder().encode(message)
    }

    // MARK: Diagnostics

    /// Human-readable, bounded description of a decoding failure using wire (snake_case) key paths.
    public static func describe(_ error: DecodingError) -> String {
        let message: String
        switch error {
        case .keyNotFound(let key, let context):
            message = "Missing required parameter '\(path(context.codingPath + [key]))'."
        case .valueNotFound(_, let context):
            message = "Parameter '\(path(context.codingPath))' must not be null."
        case .typeMismatch(let type, let context):
            let location = context.codingPath.isEmpty ? "Parameters" : "Parameter '\(path(context.codingPath))'"
            message = "\(location) must be \(jsonTypeName(type))."
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty {
                message = "Malformed JSON: \(context.debugDescription)"
            } else {
                message = "Invalid value for '\(path(context.codingPath))': \(context.debugDescription)"
            }
        @unknown default:
            message = "Invalid parameters."
        }
        return bounded(message)
    }

    static func path(_ codingPath: [any CodingKey]) -> String {
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result.isEmpty ? "(root)" : result
    }

    static func jsonTypeName(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return "a string"
        case is Bool.Type: return "a boolean"
        case is Int.Type, is Int32.Type, is Int64.Type, is UInt.Type: return "an integer"
        case is Double.Type, is Float.Type: return "a number"
        default: break
        }
        let name = String(describing: type)
        if name.hasPrefix("Array") { return "an array" }
        if name.hasPrefix("Dictionary") { return "an object" }
        return "a valid \(name)"
    }

    static func bounded(_ text: String) -> String {
        guard text.count > maxDiagnosticLength else { return text }
        return String(text.prefix(maxDiagnosticLength)) + "…"
    }
}

extension JSONValue {
    /// Wire-encodes a DTO into a `JSONValue` (`internal_error` on failure).
    public init<T: Encodable>(ipc value: T) throws(IPCError) {
        self = try IPCCoding.encodeValue(value)
    }

    /// Decodes this value as request parameters (`invalid_params` on failure).
    public func ipcParams<T: Decodable>(as type: T.Type) throws(IPCError) -> T {
        try IPCCoding.decodeParams(type, from: self)
    }
}
