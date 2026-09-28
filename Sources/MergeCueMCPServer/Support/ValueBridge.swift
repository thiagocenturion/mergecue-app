import Foundation
import MCP
import MergeCueCore

/// Lossless conversions between the SDK's `Value` and MergeCue's `JSONValue`.
///
/// Integral numbers become `.int` on the MCP side (so `expected_version: 3` is not sent as `3.0`); the SDK's
/// `.data` case is carried as its data-URL string, which is how it is encoded on the wire anyway.
public enum ValueBridge {
    public static func jsonValue(_ value: Value) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let flag):
            return .bool(flag)
        case .int(let number):
            return .number(Double(number))
        case .double(let number):
            return .number(number)
        case .string(let text):
            return .string(text)
        case .data(let mimeType, let data):
            return .string(data.dataURLEncoded(mimeType: mimeType))
        case .array(let items):
            return .array(items.map(jsonValue))
        case .object(let members):
            return .object(members.mapValues(jsonValue))
        }
    }

    public static func value(_ json: JSONValue) -> Value {
        switch json {
        case .null:
            return .null
        case .bool(let flag):
            return .bool(flag)
        case .number(let number):
            if let integer = json.intValue, abs(number) <= Double(Int.max) {
                return .int(integer)
            }
            return .double(number)
        case .string(let text):
            return .string(text)
        case .array(let items):
            return .array(items.map(value))
        case .object(let members):
            return .object(members.mapValues(value))
        }
    }

    /// Tool arguments (`nil` = no arguments) as a JSON object.
    public static func arguments(_ arguments: [String: Value]?) -> JSONValue {
        .object((arguments ?? [:]).mapValues(jsonValue))
    }
}
