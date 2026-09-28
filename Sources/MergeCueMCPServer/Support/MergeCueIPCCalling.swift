import Foundation
import MergeCueCore
import MergeCueIPC

/// The one IPC operation the MCP bridge needs. `IPCClient` conforms; tests may substitute an in-memory double.
public protocol MergeCueIPCCalling: Sendable {
    /// Forwards `params` unchanged and returns the raw result, or throws the structured IPC error (never a guess).
    func callRaw(_ method: IPCMethod, params: JSONValue) async throws(IPCError) -> JSONValue
}

extension IPCClient: MergeCueIPCCalling {}

extension IPCClient {
    /// The client `mergecue-mcp` uses: paths from `MERGECUE_HOME` / `MERGECUE_SOCKET`, name `mergecue-mcp`.
    public static func mergeCueMCP(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        version: String = MergeCueMCPServerInfo.version(),
        timeout: TimeInterval = 15
    ) -> IPCClient {
        IPCClient(
            paths: MergeCuePaths(environment: environment),
            clientInfo: IPCClientInfo(name: MergeCueMCPServerInfo.ipcClientName, version: version),
            timeout: timeout
        )
    }
}

/// Counts requests in flight so a shutting-down server can let them finish (bounded).
actor InFlightTracker {
    private var count = 0

    func begin() {
        count += 1
    }

    func end() {
        count = max(0, count - 1)
    }

    var current: Int { count }

    /// Waits until nothing is in flight or `timeout` elapses. Returns true when drained.
    func drain(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while count > 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return count == 0
    }
}
