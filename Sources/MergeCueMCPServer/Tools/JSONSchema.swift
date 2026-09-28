import Foundation
import MCP

/// Minimal JSON Schema (draft 2020-12 subset) builder for tool input schemas.
///
/// Only keywords that every MCP client we target accepts are used: no top-level `anyOf`/`oneOf`/`allOf` (the
/// Anthropic API rejects them in tool input schemas), no `$ref`. Cross-field rules ("task_id or change_ref") are
/// stated in descriptions and enforced by MergeCue.
enum JSONSchema {
    /// A closed object schema (`additionalProperties: false`).
    static func object(_ properties: [String: Value], required: [String] = [], description: String? = nil) -> Value {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.sorted().map(Value.string))
        }
        if let description {
            schema["description"] = .string(description)
        }
        return .object(schema)
    }

    static func string(
        _ description: String,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        pattern: String? = nil,
        enumValues: [String]? = nil,
        examples: [String]? = nil
    ) -> Value {
        var schema: [String: Value] = ["type": "string", "description": .string(description)]
        if let minLength { schema["minLength"] = .int(minLength) }
        if let maxLength { schema["maxLength"] = .int(maxLength) }
        if let pattern { schema["pattern"] = .string(pattern) }
        if let enumValues { schema["enum"] = .array(enumValues.map(Value.string)) }
        if let examples { schema["examples"] = .array(examples.map(Value.string)) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil, defaultValue: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        if let defaultValue { schema["default"] = .int(defaultValue) }
        return .object(schema)
    }

    static func boolean(_ description: String, defaultValue: Bool? = nil) -> Value {
        var schema: [String: Value] = ["type": "boolean", "description": .string(description)]
        if let defaultValue { schema["default"] = .bool(defaultValue) }
        return .object(schema)
    }

    static func array(
        _ description: String,
        items: Value,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        uniqueItems: Bool = false
    ) -> Value {
        var schema: [String: Value] = ["type": "array", "description": .string(description), "items": items]
        if let minItems { schema["minItems"] = .int(minItems) }
        if let maxItems { schema["maxItems"] = .int(maxItems) }
        if uniqueItems { schema["uniqueItems"] = true }
        return .object(schema)
    }

    /// A bare enum item schema for arrays.
    static func enumItem(_ values: [String]) -> Value {
        .object(["type": "string", "enum": .array(values.map(Value.string))])
    }

    /// Property names of an object schema built by `object(_:required:)`.
    static func propertyNames(of schema: Value) -> Set<String> {
        Set(schema.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? [])
    }

    /// `required` names of an object schema.
    static func requiredNames(of schema: Value) -> [String] {
        schema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

/// Shared property schemas (patterns mirror the Core validators).
enum SchemaFields {
    /// `mc_` + 6 × [a-z0-9] (`TaskID.isValid`).
    static let taskIDPattern = "^mc_[a-z0-9]{6}$"
    /// `thr_` + 10 lowercase hex (`ShortID`).
    static let threadIDPattern = "^thr_[0-9a-f]{10}$"
    /// `chk_` + 10 lowercase hex (`ShortID`).
    static let checkIDPattern = "^chk_[0-9a-f]{10}$"
    /// `<provider>:<host>/<repo path><#|!><number>` (`ChangeRequestRef`).
    static let changeRefPattern = "^(github|gitlab|bitbucket_cloud):[^\\s/]+/[^\\s]+[#!][1-9][0-9]*$"
    /// `HH:MM`, 24-hour.
    static let clockTimePattern = "^([01][0-9]|2[0-3]):[0-5][0-9]$"

    static func taskID(_ description: String = "MergeCue task id (mc_ + 6 characters), e.g. mc_7f3k2a.") -> Value {
        JSONSchema.string(description, pattern: taskIDPattern, examples: ["mc_7f3k2a"])
    }

    static func changeRef(_ description: String) -> Value {
        JSONSchema.string(
            description,
            maxLength: 1024,
            pattern: changeRefPattern,
            examples: ["github:github.com/acme/payments-api#42", "gitlab:gitlab.com/acme/payments-api!42", "bitbucket_cloud:bitbucket.org/acme/payments-api#42"]
        )
    }

    static let leaseID = JSONSchema.string("The lease_id returned by claim_task (proves you hold the task).", minLength: 1, maxLength: 128)

    static let expectedVersion = JSONSchema.integer(
        "The task version you last saw (from get_task, claim_task or your previous write). A stale value fails with version_conflict.",
        minimum: 0
    )
}
