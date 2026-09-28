// mergecue-agent-sim — drives a real `mergecue-mcp` process as an MCP client (SDK `Client` over stdio pipes)
// through scripted agent scenarios, prints a JSON report on stdout and exits 0 (pass) / 1 (fail) / 64 (usage).

import Darwin
import Foundation
import MergeCueCore

let usage = """
    Usage: mergecue-agent-sim [--mcp PATH] [--scenario NAME] [--task TASK_ID] [--agent-name NAME] [--timeout SECONDS]

      --mcp PATH         mergecue-mcp binary to spawn (default: next to this executable).
      --scenario NAME    happy | crash-after-claim | double-claim | hostile | invalid (default: happy).
      --task TASK_ID     Task to work on (default: the first task waiting for an agent).
      --agent-name NAME  Agent name used for claims (default: mergecue-agent-sim).
      --timeout SECONDS  Abort the scenario after this long (default: 120).
      --hostile-marker TEXT
                         Extra phrase identifying the hostile comment in the hostile scenario (repeatable).
      --handoff-code CODE
                         The code from the handoff prompt ("(handoff code: CODE)"), passed to claim_task.

    MERGECUE_HOME / MERGECUE_SOCKET are passed through to mergecue-mcp.

    """

func fail(usage message: String) -> Never {
    FileHandle.standardError.write(Data("mergecue-agent-sim: \(message)\n\(usage)".utf8))
    exit(64)
}

func parseOptions(_ arguments: [String]) -> SimOptions {
    var mcpPath: String?
    var taskID: String?
    var scenario = Scenario.happy
    var agentName = "mergecue-agent-sim"
    var timeout = 120
    var markers: [String] = []
    var handoffCode: String?
    var index = 0
    func value(_ flag: String) -> String {
        index += 1
        guard index < arguments.count else { fail(usage: "\(flag) needs a value.") }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--mcp": mcpPath = value(argument)
        case "--task":
            let raw = value(argument)
            guard TaskID.isValid(raw) else { fail(usage: "--task must look like mc_ + 6 characters.") }
            taskID = raw
        case "--scenario":
            let raw = value(argument)
            guard let parsed = Scenario(rawValue: raw) else { fail(usage: "unknown scenario \(raw).") }
            scenario = parsed
        case "--agent-name":
            agentName = value(argument)
            if agentName.isEmpty || agentName.count > 100 { fail(usage: "--agent-name must be 1…100 characters.") }
        case "--timeout":
            guard let seconds = Int(value(argument)), seconds > 0 else { fail(usage: "--timeout must be a positive integer.") }
            timeout = seconds
        case "--hostile-marker":
            let marker = value(argument)
            guard !marker.isEmpty, marker.count <= 200 else { fail(usage: "--hostile-marker must be 1…200 characters.") }
            markers.append(marker)
        case "--handoff-code":
            let code = value(argument)
            guard !code.isEmpty, code.count <= 32 else { fail(usage: "--handoff-code must be 1…32 characters.") }
            handoffCode = code
        case "--help", "-h":
            print(usage, terminator: "")
            exit(0)
        default:
            fail(usage: "unknown option \(argument).")
        }
        index += 1
    }
    let resolvedMCP = mcpPath ?? {
        let own = URL(filePath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        return own.deletingLastPathComponent().appending(path: "mergecue-mcp").path(percentEncoded: false)
    }()
    guard FileManager.default.isExecutableFile(atPath: resolvedMCP) else {
        fail(usage: "mergecue-mcp not found or not executable at \(resolvedMCP); pass --mcp PATH.")
    }
    return SimOptions(mcpPath: resolvedMCP, taskID: taskID, scenario: scenario, agentName: agentName, timeoutSeconds: timeout, hostileMarkers: markers,
                      handoffCode: handoffCode)
}

signal(SIGPIPE, SIG_IGN)
let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
let recorder = SimRecorder()
let startedAt = Date()

func finish(aborted: String? = nil) -> Never {
    if let aborted {
        recorder.record("scenario", ok: false, detail: aborted)
    }
    let snapshot = recorder.snapshot()
    let report = SimReport(
        scenario: options.scenario.rawValue,
        passed: !snapshot.steps.isEmpty && snapshot.steps.allSatisfy(\.ok),
        agentName: options.agentName,
        mcpPath: options.mcpPath,
        taskID: recorder.taskID,
        server: recorder.server,
        steps: snapshot.steps,
        skipped: snapshot.skipped,
        startedAt: startedAt,
        durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
    )
    print(report.jsonText())
    fflush(stdout)
    exit(report.passed ? 0 : 1)
}

let watchdog = Task.detached {
    try? await Task.sleep(for: .seconds(options.timeoutSeconds))
    if !Task.isCancelled {
        finish(aborted: "Timed out after \(options.timeoutSeconds) s.")
    }
}

do {
    try await ScenarioRunner(options: options, recorder: recorder).run()
    watchdog.cancel()
    finish()
} catch let abort as ScenarioAbort {
    watchdog.cancel()
    finish(aborted: "Aborted: \(abort.reason)")
} catch {
    watchdog.cancel()
    finish(aborted: "Unexpected error: \(error)")
}
