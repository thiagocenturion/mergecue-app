import Foundation
import MergeCueCore

/// One checked step of a scenario.
struct SimStep: Codable, Sendable {
    var name: String
    var ok: Bool
    /// What the step expected (e.g. `version_conflict`).
    var expected: String?
    /// Error code actually received, if any.
    var code: String?
    var detail: String
}

/// The JSON report printed on stdout.
struct SimReport: Codable, Sendable {
    struct ServerInfo: Codable, Sendable {
        var name: String
        var version: String
        var protocolVersion: String

        enum CodingKeys: String, CodingKey {
            case name, version
            case protocolVersion = "protocol_version"
        }
    }

    var scenario: String
    var passed: Bool
    var agentName: String
    var mcpPath: String
    var taskID: String?
    var server: ServerInfo?
    var steps: [SimStep]
    var skipped: [String]
    var startedAt: Date
    var durationMs: Int

    enum CodingKeys: String, CodingKey {
        case scenario, passed, server, steps, skipped
        case agentName = "agent_name"
        case mcpPath = "mcp_path"
        case taskID = "task_id"
        case startedAt = "started_at"
        case durationMs = "duration_ms"
    }

    func jsonText() -> String {
        let encoder = MergeCueCoding.wireEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{\"passed\": false, \"error\": \"report encoding failed\"}"
        }
        return text
    }
}

/// Collects steps while a scenario runs.
final class SimRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [SimStep] = []
    private var skipped: [String] = []
    var taskID: String?
    var server: SimReport.ServerInfo?

    func record(_ name: String, ok: Bool, expected: String? = nil, code: String? = nil, detail: String) {
        lock.withLock {
            steps.append(SimStep(name: name, ok: ok, expected: expected, code: code, detail: SecretRedactor.redact(detail)))
        }
    }

    func skip(_ reason: String) {
        lock.withLock { skipped.append(reason) }
    }

    /// Records a step that must succeed; returns the structured result when it did.
    @discardableResult
    func expectSuccess(_ name: String, _ outcome: ToolOutcome) -> JSONValue? {
        record(name, ok: outcome.value != nil, expected: "success", code: outcome.errorCode, detail: outcome.summary)
        return outcome.value
    }

    /// Records a step that must be rejected with one of `codes`.
    @discardableResult
    func expectRejection(_ name: String, _ outcome: ToolOutcome, codes: Set<String>) -> Bool {
        let ok = outcome.errorCode.map(codes.contains) ?? false
        record(name, ok: ok, expected: codes.sorted().joined(separator: "|"), code: outcome.errorCode, detail: outcome.summary)
        return ok
    }

    func snapshot() -> (steps: [SimStep], skipped: [String]) {
        lock.withLock { (steps, skipped) }
    }
}

/// Thrown to abort a scenario after a failed prerequisite (the failure is already recorded).
struct ScenarioAbort: Error {
    var reason: String
}
