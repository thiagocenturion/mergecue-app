import Foundation
import MCP
import MergeCueCore
import MergeCueIPC

/// One MergeCue MCP tool: the IPC method it forwards to, its MCP definition and its structural argument check.
public struct MergeCueToolDefinition: Sendable {
    /// IPC method (the tool name is the method's wire name).
    public let method: IPCMethod
    /// The MCP tool (name, title, description, input schema, annotations).
    public let tool: Tool
    /// Decodes the arguments with the method's params DTO (`invalid_params` on a structural problem). Read-only
    /// methods also run the DTO bounds (`validate()`); writes leave bounds to the app so rejected writes are
    /// audited as `rejected_call` activity.
    let check: @Sendable (JSONValue) throws(IPCError) -> Void

    public var name: String { method.rawValue }

    /// Argument names the input schema declares (anything else is rejected as `invalid_params`).
    public var allowedArguments: Set<String> { JSONSchema.propertyNames(of: tool.inputSchema) }

    /// Required argument names from the input schema.
    public var requiredArguments: [String] { JSONSchema.requiredNames(of: tool.inputSchema) }

    init<P: IPCMethodParams>(
        _ params: P.Type,
        title: String,
        description: String,
        inputSchema: Value,
        openWorld: Bool = false,
        idempotent: Bool? = nil
    ) {
        let method = P.method
        self.method = method
        let readOnly = !method.isMutating
        self.tool = Tool(
            name: method.rawValue,
            title: title,
            description: description + "\n\n" + MergeCueMCPServerInfo.safetyNotice,
            inputSchema: inputSchema,
            annotations: Tool.Annotations(
                title: title,
                readOnlyHint: readOnly,
                destructiveHint: false,
                idempotentHint: idempotent ?? readOnly,
                openWorldHint: openWorld
            )
        )
        self.check = { arguments throws(IPCError) in
            let decoded = try IPCCoding.decodeParams(P.self, from: arguments)
            if !method.isMutating {
                try decoded.validate()
            }
        }
    }

    /// Full local validation: unknown arguments, then the structural check.
    public func validate(arguments: JSONValue) throws(IPCError) {
        guard let members = arguments.objectValue else {
            throw IPCError.invalidParams("Tool arguments must be a JSON object.")
        }
        let allowed = allowedArguments
        let unknown = members.keys.filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty {
            let list = unknown.prefix(5).map { "'\($0)'" }.joined(separator: ", ")
            let expected = allowed.isEmpty ? "none" : allowed.sorted().joined(separator: ", ")
            throw IPCError.invalidParams(
                "Unknown argument\(unknown.count == 1 ? "" : "s") \(list) for \(name). Allowed: \(expected).",
                data: ["unknown_arguments": .array(unknown.map(JSONValue.string))]
            )
        }
        try check(arguments)
    }
}

/// Every MergeCue MCP tool: the IPC methods except `ping`, in a stable order.
public enum MergeCueToolCatalog {
    public static let all: [MergeCueToolDefinition] = reads + writes

    /// Lookup by tool name.
    public static func definition(named name: String) -> MergeCueToolDefinition? {
        byName[name]
    }

    /// `tools/list` payload.
    public static var tools: [Tool] { all.map(\.tool) }

    private static let byName: [String: MergeCueToolDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )

    /// Enum value lists straight from the Core/IPC types, so schemas cannot drift from the DTOs.
    enum Enums {
        static let providers = ProviderKind.allCases.map(\.rawValue)
        static let taskStates = TaskState.allCases.map(\.rawValue)
        static let taskTypes = TaskType.allCases.map(\.rawValue)
        static let phases = TaskPhase.allCases.map(\.rawValue)
        static let testStatuses = TestRunStatus.allCases.map(\.rawValue)
        static let ruleActions = RuleActionKind.allCases.map(\.rawValue)
        static let eventTypes = ChangeEventType.allCases.map(\.rawValue)
    }
}
