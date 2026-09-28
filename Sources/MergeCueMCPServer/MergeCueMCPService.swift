import Foundation
import MCP
import MergeCueCore
import MergeCueIPC

/// The MergeCue MCP server: tools, resources and the `work_on_task` prompt, bridged to the app over IPC.
///
/// The service holds no task state of its own; every answer comes from the running app (or is an
/// `app_unavailable` error when it is not running). Build the SDK `Server` with `makeServer()` and start it on
/// any transport (`StdioTransport` in `mergecue-mcp`, `InMemoryTransport` in tests).
public final class MergeCueMCPService: Sendable {
    public let version: String
    public let router: ToolCallRouter
    public let resources: ResourceProvider
    private let inFlight = InFlightTracker()

    public init(ipc: any MergeCueIPCCalling, version: String = MergeCueMCPServerInfo.version()) {
        self.version = version
        self.router = ToolCallRouter(ipc: ipc)
        self.resources = ResourceProvider(ipc: ipc)
    }

    /// Live service: an `IPCClient` for the paths in `environment` (`MERGECUE_HOME`, `MERGECUE_SOCKET`).
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> MergeCueMCPService {
        let version = MergeCueMCPServerInfo.version(environment: environment)
        return MergeCueMCPService(ipc: IPCClient.mergeCueMCP(environment: environment, version: version), version: version)
    }

    /// Advertised capabilities (static lists: no `listChanged`, no subscriptions).
    public static let capabilities = Server.Capabilities(
        prompts: .init(listChanged: false),
        resources: .init(subscribe: false, listChanged: false),
        tools: .init(listChanged: false)
    )

    /// A configured, not yet started SDK server.
    public func makeServer() async -> Server {
        let server = Server(
            name: MergeCueMCPServerInfo.name,
            version: version,
            title: MergeCueMCPServerInfo.title,
            instructions: MergeCueMCPServerInfo.instructions,
            capabilities: Self.capabilities
        )
        await register(on: server)
        return server
    }

    /// Requests currently being processed (used for a bounded drain at shutdown).
    public func requestsInFlight() async -> Int {
        await inFlight.current
    }

    /// Waits (at most `timeout`) for in-flight requests to finish. Returns true when none remain.
    @discardableResult
    public func drain(timeout: Duration) async -> Bool {
        await inFlight.drain(timeout: timeout)
    }

    private func register(on server: Server) async {
        // Tracked like every other request so a stdin EOF right after tools/list still drains its answer.
        await server.withMethodHandler(ListTools.self) { [self] _ in
            try await tracked { ListTools.Result(tools: MergeCueToolCatalog.tools) }
        }
        await server.withMethodHandler(CallTool.self) { [self] params in
            try await tracked { try await router.call(params) }
        }
        await server.withMethodHandler(ListResources.self) { [self] _ in
            try await tracked { try await resources.list() }
        }
        await server.withMethodHandler(ListResourceTemplates.self) { [self] _ in
            try await tracked { ListResourceTemplates.Result(templates: ResourceProvider.templates) }
        }
        await server.withMethodHandler(ReadResource.self) { [self] params in
            try await tracked { try await resources.read(uri: params.uri) }
        }
        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(prompts: [WorkOnTaskPrompt.prompt])
        }
        await server.withMethodHandler(GetPrompt.self) { params in
            guard params.name == WorkOnTaskPrompt.name else {
                throw MCPError.invalidParams("Unknown prompt: \(String(params.name.prefix(128))). MergeCue offers: \(WorkOnTaskPrompt.name).")
            }
            return try WorkOnTaskPrompt.get(arguments: params.arguments)
        }
    }

    private func tracked<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await inFlight.begin()
        do {
            let value = try await body()
            await inFlight.end()
            return value
        } catch {
            await inFlight.end()
            throw error
        }
    }
}
