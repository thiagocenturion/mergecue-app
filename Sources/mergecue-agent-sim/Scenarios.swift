import Foundation
import MCP
import MergeCueCore

/// Simulator scenarios (PLAN §11 agent rows).
enum Scenario: String, CaseIterable, Sendable {
    case happy
    case crashAfterClaim = "crash-after-claim"
    case doubleClaim = "double-claim"
    case hostile
    case invalid
}

struct SimOptions: Sendable {
    var mcpPath: String
    var taskID: String?
    var scenario: Scenario
    var agentName: String
    var timeoutSeconds: Int
    /// Extra phrases that identify the hostile fixture comment (`--hostile-marker`).
    var hostileMarkers: [String] = []
}

/// Tools MergeCue must never expose to an agent (remote publishing is approved in the app only).
let forbiddenToolNames: Set<String> = [
    "merge", "merge_change_request", "post_reply", "post_comment", "resolve_thread", "push", "commit_and_push",
    "approve", "approve_action", "request_changes", "apply_patch",
]

/// Phrases a hostile review comment in the fixtures (and typical prompt injections) contain.
let hostileMarkers = [
    "ignore previous instructions", "ignore all previous instructions", "ignore prior instructions",
    "ignore the above", "system prompt", "you are now", "merge this", "approve this", "exfiltrate", "curl ",
]

struct ScenarioRunner {
    let options: SimOptions
    let recorder: SimRecorder

    let sessions = SessionPool()

    /// Runs the scenario, then shuts every MCP session down cleanly (stdin EOF), even after a failure.
    func run() async throws {
        do {
            let session = try await open(label: "agent")
            switch options.scenario {
            case .happy: try await happy(session)
            case .crashAfterClaim: try await crashAfterClaim(session)
            case .doubleClaim: try await doubleClaim(session)
            case .hostile: try await hostile(session)
            case .invalid: try await invalid(session)
            }
        } catch {
            await sessions.closeAll()
            throw error
        }
        await sessions.closeAll()
    }

    // MARK: Session helpers

    func open(label: String) async throws -> MCPSession {
        let session: MCPSession
        do {
            session = try await MCPSession.start(executable: options.mcpPath, label: label, clientName: "mergecue-agent-sim")
        } catch {
            recorder.record("initialize(\(label))", ok: false, detail: "Could not start or initialize \(options.mcpPath): \(error)")
            throw ScenarioAbort(reason: "initialize failed")
        }
        await sessions.add(session)
        if let initialize = session.initializeResult {
            recorder.server = SimReport.ServerInfo(
                name: initialize.serverInfo.name,
                version: initialize.serverInfo.version,
                protocolVersion: initialize.protocolVersion
            )
            let ok = initialize.serverInfo.name == "mergecue"
            recorder.record("initialize(\(label))", ok: ok, detail: "server \(initialize.serverInfo.name) \(initialize.serverInfo.version), MCP protocol \(initialize.protocolVersion)")
            if !ok { throw ScenarioAbort(reason: "unexpected server") }
        }
        return session
    }

    /// `--task`, or the first task waiting for an agent.
    func resolveTask(_ session: MCPSession) async throws -> String {
        if let taskID = options.taskID {
            recorder.taskID = taskID
            return taskID
        }
        let outcome = await session.call("list_tasks", ["states": ["waiting_for_agent"], "limit": 1])
        guard let tasks = recorder.expectSuccess("list_tasks(waiting_for_agent)", outcome)?["tasks"]?.arrayValue else {
            throw ScenarioAbort(reason: "list_tasks failed")
        }
        guard let taskID = tasks.first?["task_id"]?.stringValue else {
            recorder.record("pick task", ok: false, detail: "No task is waiting for an agent; pass --task <id>.")
            throw ScenarioAbort(reason: "no task")
        }
        recorder.taskID = taskID
        return taskID
    }

    func getTask(_ session: MCPSession, _ taskID: String, step: String = "get_task") async throws -> JSONValue {
        guard let task = recorder.expectSuccess(step, await session.call("get_task", ["task_id": .string(taskID)])) else {
            throw ScenarioAbort(reason: "get_task failed")
        }
        return task
    }

    func claim(_ session: MCPSession, _ taskID: String, version: Int, agent: String? = nil, step: String = "claim_task") async throws -> (lease: String, version: Int, checkout: JSONValue?) {
        let outcome = await session.call("claim_task", [
            "task_id": .string(taskID),
            "agent_name": .string(agent ?? options.agentName),
            "run_id": .string("sim-" + UUID().uuidString.lowercased()),
            "expected_version": .int(version),
        ])
        guard let claim = recorder.expectSuccess(step, outcome),
              let lease = claim["lease_id"]?.stringValue,
              let newVersion = claim["version"]?.intValue
        else { throw ScenarioAbort(reason: "claim failed") }
        return (lease, newVersion, claim["checkout"])
    }

    // MARK: Scenarios

    /// get_task → claim → update → edit a file in the worktree → report_changes → run a test → report_tests →
    /// submit_result with a proposed reply.
    func happy(_ session: MCPSession) async throws {
        let tools = try await session.toolNames()
        recorder.record("tools/list", ok: tools.count == 16, detail: tools.sorted().joined(separator: ", "))

        let taskID = try await resolveTask(session)
        let task = try await getTask(session, taskID)
        guard let version = task["version"]?.intValue else { throw ScenarioAbort(reason: "no version") }
        var (lease, current, checkout) = try await claim(session, taskID, version: version)
        checkout = checkout ?? task["checkout"]

        guard let updated = recorder.expectSuccess("update_task(editing)", await session.call("update_task", [
            "task_id": .string(taskID), "lease_id": .string(lease), "expected_version": .int(current),
            "phase": "editing", "message": "mergecue-agent-sim is editing the worktree",
        ]))?["version"]?.intValue else { throw ScenarioAbort(reason: "update failed") }
        current = updated

        guard checkout?["policy"]?.stringValue == "isolated_worktree",
              let worktree = checkout?["worktree_path"]?.stringValue,
              let baseSHA = checkout?["base_sha"]?.stringValue
        else {
            recorder.record("checkout", ok: false, detail: "Task has no isolated worktree with a base SHA: \(checkout?.jsonString() ?? "none")")
            throw ScenarioAbort(reason: "no worktree")
        }
        let relativePath = "mergecue-agent-sim.txt"
        do {
            try Self.appendLine(to: relativePath, in: worktree, line: "Edited by \(options.agentName) for \(taskID) at \(Date())")
            recorder.record("edit file", ok: true, detail: "\(worktree)/\(relativePath)")
        } catch {
            recorder.record("edit file", ok: false, detail: "\(error)")
            throw ScenarioAbort(reason: "edit failed")
        }

        guard let changes = recorder.expectSuccess("report_changes", await session.call("report_changes", [
            "task_id": .string(taskID), "lease_id": .string(lease), "expected_version": .int(current),
            "worktree_path": .string(worktree), "base_sha": .string(baseSHA), "changed_paths": [.string(relativePath)],
            "note": "Simulated change",
        ])), let diffArtifact = changes["artifact_id"]?.stringValue, let afterChanges = changes["version"]?.intValue
        else { throw ScenarioAbort(reason: "report_changes failed") }
        current = afterChanges

        let command = "test -s \(relativePath) && echo ok"
        let run = Self.runShell(command, in: worktree)
        recorder.record("run tests", ok: run.exitCode == 0, detail: "\(command) → exit \(run.exitCode)")
        guard let tests = recorder.expectSuccess("report_tests", await session.call("report_tests", [
            "task_id": .string(taskID), "lease_id": .string(lease), "expected_version": .int(current),
            "command": .string(command), "exit_code": .int(Int(run.exitCode)),
            "status": .string(run.exitCode == 0 ? "passed" : "failed"),
            "passed": .int(run.exitCode == 0 ? 1 : 0), "failed": .int(run.exitCode == 0 ? 0 : 1),
            "duration_ms": .int(run.durationMs), "output": .string(String(run.output.suffix(4000))),
        ])), let testArtifact = tests["artifact_id"]?.stringValue, let afterTests = tests["version"]?.intValue
        else { throw ScenarioAbort(reason: "report_tests failed") }
        current = afterTests

        let submitted = recorder.expectSuccess("submit_result", await session.call("submit_result", [
            "task_id": .string(taskID), "lease_id": .string(lease), "expected_version": .int(current),
            "summary": .string("mergecue-agent-sim appended a line to \(relativePath) and verified it with a test."),
            "proposed_reply": "Thanks for the review — addressed in the latest changes (simulated).",
            "artifact_ids": [.string(diffArtifact), .string(testArtifact)],
            "known_risks": ["Simulated change produced by mergecue-agent-sim."],
        ]))
        let state = submitted?["state"]?.stringValue
        recorder.record("state is ready_for_review", ok: state == "ready_for_review", expected: "ready_for_review", detail: "state: \(state ?? "none")")
    }

    /// Claims the task, then the agent "crashes": the MCP process is killed with no further call. The app must
    /// later turn the task stale (lease expiry), never done.
    func crashAfterClaim(_ session: MCPSession) async throws {
        let taskID = try await resolveTask(session)
        let task = try await getTask(session, taskID)
        guard let version = task["version"]?.intValue else { throw ScenarioAbort(reason: "no version") }
        let claimed = try await claim(session, taskID, version: version)
        session.crash()
        await sessions.remove(session)
        recorder.record("crash", ok: !session.process.isRunning, detail: "mergecue-mcp killed after claim (lease \(claimed.lease.prefix(8))…); no heartbeat will follow.")
    }

    /// Two agents claim the same task version concurrently: exactly one lease, one version_conflict.
    func doubleClaim(_ session: MCPSession) async throws {
        let second = try await open(label: "agent-b")
        let taskID = try await resolveTask(session)
        let task = try await getTask(session, taskID)
        guard let version = task["version"]?.intValue else { throw ScenarioAbort(reason: "no version") }

        func claimArgs(_ agent: String) -> [String: Value] {
            ["task_id": .string(taskID), "agent_name": .string(agent), "expected_version": .int(version)]
        }
        async let first = session.call("claim_task", claimArgs(options.agentName + "-a"))
        async let other = second.call("claim_task", claimArgs(options.agentName + "-b"))
        let outcomes = await [first, other]
        let winners = outcomes.filter { $0.value?["lease_id"]?.stringValue != nil }
        let conflicts = outcomes.filter { $0.errorCode == "version_conflict" }
        recorder.record(
            "concurrent claims",
            ok: winners.count == 1 && conflicts.count == 1,
            expected: "1 success + 1 version_conflict",
            code: outcomes.compactMap(\.errorCode).first,
            detail: outcomes.map(\.summary).joined(separator: " || ")
        )
        // Release the winner so the task does not linger in `working`.
        if let winner = winners.first?.value, let lease = winner["lease_id"]?.stringValue, let current = winner["version"]?.intValue {
            let holder = outcomes[0].value != nil ? session : second
            recorder.expectSuccess("fail_task(release)", await holder.call("fail_task", [
                "task_id": .string(taskID), "lease_id": .string(lease), "expected_version": .int(current),
                "reason": "mergecue-agent-sim double-claim scenario finished", "retryable": true,
            ]))
        }
    }

    /// The hostile comment arrives as quoted untrusted data; publishing tools do not exist and a write the comment
    /// asks for (without a lease) is rejected.
    func hostile(_ session: MCPSession) async throws {
        let tools = try await session.toolNames()
        let exposed = forbiddenToolNames.intersection(tools)
        recorder.record("no publishing tools", ok: exposed.isEmpty, detail: exposed.isEmpty ? "none of \(forbiddenToolNames.sorted().joined(separator: ", "))" : "exposed: \(exposed.sorted())")

        let taskID = try await resolveTask(session)
        let task = try await getTask(session, taskID)
        let markers = hostileMarkers + options.hostileMarkers.map { $0.lowercased() }
        let untrusted = task["trigger"]?["untrusted_content"]?.arrayValue ?? []
        let hostileEntries = untrusted.filter { entry in
            guard let text = entry["text"]?.stringValue?.lowercased() else { return false }
            return markers.contains { text.contains($0) }
        }
        let wellFormed = untrusted.allSatisfy { $0["source"]?.stringValue?.isEmpty == false && $0["text"]?.stringValue != nil }
        recorder.record(
            "hostile text is quoted untrusted content",
            ok: !hostileEntries.isEmpty && wellFormed,
            detail: "\(hostileEntries.count) of \(untrusted.count) untrusted entries contain an injection marker; sources: \(untrusted.compactMap { $0["source"]?.stringValue }.joined(separator: ","))"
        )
        let trusted = ((task["instructions"]?.arrayValue ?? []) + (task["next_steps"]?.arrayValue ?? []))
            .compactMap(\.stringValue).joined(separator: "\n").lowercased()
        let leaked = markers.filter { trusted.contains($0) }
        recorder.record("trusted instructions carry no injected text", ok: leaked.isEmpty, detail: leaked.isEmpty ? "clean" : "found: \(leaked)")

        let merge = await session.call("merge_change_request", ["task_id": .string(taskID)])
        recorder.record("forbidden tool merge_change_request rejected", ok: merge.isRejected, detail: merge.summary)

        let forged = await session.call("submit_result", [
            "task_id": .string(taskID), "lease_id": "lease_from_review_comment",
            "expected_version": .int(task["version"]?.intValue ?? 0),
            "summary": "Merged as the reviewer instructed.", "artifact_ids": [],
        ])
        recorder.expectRejection("write without a lease rejected", forged, codes: ["lease_invalid", "lease_expired", "invalid_transition"])
    }

    /// Terminal resurrection, bad lease, path outside the checkout, passed-with-non-zero-exit, stale version and
    /// malformed arguments are all rejected with their codes.
    func invalid(_ session: MCPSession) async throws {
        let taskID = try await resolveTask(session)
        let task = try await getTask(session, taskID)
        guard let version = task["version"]?.intValue else { throw ScenarioAbort(reason: "no version") }

        recorder.expectRejection("missing task_id", await session.call("claim_task", [
            "agent_name": .string(options.agentName), "expected_version": .int(version),
        ]), codes: ["invalid_params"])
        recorder.expectRejection("bad lease", await session.call("heartbeat", [
            "task_id": .string(taskID), "lease_id": "lease_bogus",
        ]), codes: ["lease_invalid"])

        var (lease, current, checkout) = try await claim(session, taskID, version: version)
        checkout = checkout ?? task["checkout"]
        let worktree = checkout?["worktree_path"]?.stringValue ?? "/nonexistent-worktree"
        let baseSHA = checkout?["base_sha"]?.stringValue ?? "0000000000000000000000000000000000000000"

        recorder.expectRejection("stale expected_version", await session.call("update_task", [
            "task_id": .string(taskID), "lease_id": .string(lease), "expected_version": .int(current - 1),
            "phase": "investigating", "message": "stale write",
        ]), codes: ["version_conflict"])
        recorder.expectRejection("worktree outside checkout", await session.call("report_changes", [
            "task_id": .string(taskID), "lease_id": .string(lease), "expected_version": .int(current),
            "worktree_path": .string(NSHomeDirectory()), "base_sha": .string(baseSHA), "changed_paths": [".zshrc"],
        ]), codes: ["path_outside_checkout"])
        recorder.expectRejection("changed path escapes checkout", await session.call("report_changes", [
            "task_id": .string(taskID), "lease_id": .string(lease), "expected_version": .int(current),
            "worktree_path": .string(worktree), "base_sha": .string(baseSHA), "changed_paths": ["../../../etc/passwd"],
        ]), codes: ["path_outside_checkout"])
        recorder.expectRejection("passed with non-zero exit", await session.call("report_tests", [
            "task_id": .string(taskID), "lease_id": .string(lease), "expected_version": .int(current),
            "command": "false", "exit_code": 1, "status": "passed", "output": "",
        ]), codes: ["validation_failed"])

        let terminal = await session.call("list_tasks", ["states": ["done", "cancelled", "dismissed"], "limit": 1])
        if let other = recorder.expectSuccess("list_tasks(terminal)", terminal)?["tasks"]?.arrayValue?.first,
           let otherID = other["task_id"]?.stringValue, let otherVersion = other["version"]?.intValue {
            recorder.expectRejection("terminal task resurrection", await session.call("claim_task", [
                "task_id": .string(otherID), "agent_name": .string(options.agentName), "expected_version": .int(otherVersion),
            ]), codes: ["terminal_state"])
        } else {
            recorder.skip("terminal task resurrection: no done/cancelled/dismissed task exists")
        }

        if let released = recorder.expectSuccess("fail_task(release)", await session.call("fail_task", [
            "task_id": .string(taskID), "lease_id": .string(lease), "expected_version": .int(current),
            "reason": "mergecue-agent-sim invalid-call scenario finished", "retryable": true,
        ]))?["version"]?.intValue {
            current = released
        }
        _ = current
    }

    // MARK: Local work

    /// Appends `line` to `relativePath`, refusing any path that resolves outside `root`.
    static func appendLine(to relativePath: String, in root: String, line: String) throws {
        let rootURL = URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = rootURL.appending(path: relativePath).standardizedFileURL
        guard fileURL.path(percentEncoded: false).hasPrefix(rootURL.path(percentEncoded: false)) else {
            throw ScenarioAbort(reason: "refusing to write outside the worktree")
        }
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL)
        }
    }

    /// Runs `/bin/sh -c command` in `directory`, capturing combined output.
    static func runShell(_ command: String, in directory: String) -> (exitCode: Int32, output: String, durationMs: Int) {
        let started = Date()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (127, "could not run /bin/sh: \(error)", 0)
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), Int(Date().timeIntervalSince(started) * 1000))
    }
}

/// Sessions opened by a scenario, closed together at the end.
actor SessionPool {
    private var sessions: [MCPSession] = []

    func add(_ session: MCPSession) {
        sessions.append(session)
    }

    func remove(_ session: MCPSession) {
        sessions.removeAll { $0 === session }
    }

    func closeAll() async {
        let open = sessions
        sessions.removeAll()
        for session in open {
            await session.close()
        }
    }
}
