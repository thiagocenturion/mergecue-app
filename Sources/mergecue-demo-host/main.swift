// mergecue-demo-host — a headless MergeCue in **demo mode** (fixture data through the real adapters, always
// labeled demo). It hosts the runtime + private IPC socket so a real agent (Claude Code, Codex) can drive a task
// through the bundled `mergecue-mcp`, without the menu bar app. Used by scripts/e2e-real-agent.sh.
//
//   MERGECUE_HOME=/tmp/mce2e-x mergecue-demo-host --prepare-task [--state-file PATH]
//
// With --prepare-task it refreshes once (fixture step 1: a new blocking review comment arrives on GitHub #42),
// creates a task from that comment with an isolated worktree, prints one JSON line
// {"task_id","worktree","base_sha","socket","home","handoff"} to stdout (and <home>/host-ready.json), then keeps
// serving. Every second it writes the task state to <home>/host-state.json. On SIGTERM/SIGINT it writes
// <home>/host-final.json (task, activities, artifacts, provider writes) and exits after removing the socket.

import Darwin
import Dispatch
import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueFixtures
import MergeCueRuntime
import MergeCueSync

func log(_ message: String) {
    MCLog.writeToStandardError(message, category: "mergecue-demo-host")
}

func fail(_ message: String) -> Never {
    log(message)
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print("Usage: MERGECUE_HOME=<dir> mergecue-demo-host [--prepare-task] [--lease-seconds N] [--sync-interval N] [--refresh-every N]")
    exit(0)
}
let environment = ProcessInfo.processInfo.environment
guard environment[MergeCuePaths.homeEnvironmentKey]?.isEmpty == false else {
    fail("MERGECUE_HOME must point to a throwaway directory (the demo host never uses your real MergeCue data).")
}
let prepareTask = arguments.contains("--prepare-task")
var leaseSeconds: TimeInterval = 900
if let index = arguments.firstIndex(of: "--lease-seconds"), index + 1 < arguments.count, let value = TimeInterval(arguments[index + 1]) {
    leaseSeconds = value
}

// Profiling (scripts/profile-demo-host.sh): --sync-interval N lists every account and refreshes every change
// request's details every N seconds (the live cadence is lists every 15 min + progressive 30 s–30 min detail
// refreshes); --refresh-every N also runs a manual refresh
// (which advances the demo scenario) every N seconds.
func numberArgument(_ name: String) -> TimeInterval? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return TimeInterval(arguments[index + 1])
}
var syncConfiguration: SyncConfiguration?
if let interval = numberArgument("--sync-interval"), interval > 0 {
    syncConfiguration = .fixedInterval(interval)
}
let refreshEvery = numberArgument("--refresh-every")

let paths = MergeCuePaths(environment: environment)
let runtime: MergeCueRuntime
do {
    runtime = try await MergeCueRuntime.makeDemo(
        paths: paths, appVersion: "demo-host",
        options: RuntimeOptions(syncConfiguration: syncConfiguration, leaseDuration: leaseSeconds, mappingSearchRoots: [])
    )
    try await runtime.start()
} catch {
    fail("could not start the demo runtime: \(error.localizedDescription)")
}
let ipc = await runtime.ipcStatus()
log("demo runtime up (DEMO DATA) — socket \(ipc.socketPath); peers: \(ipc.peerValidation)")

struct Ready: Codable {
    var taskID: String
    var worktree: String?
    var baseSHA: String?
    var socket: String
    var home: String
    var handoff: String
    var isDemo = true

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id", worktree, baseSHA = "base_sha", socket, home, handoff, isDemo = "is_demo"
    }
}

func writeJSON<T: Encodable>(_ value: T, to name: String) {
    let encoder = MergeCueCoding.wireEncoder()
    encoder.outputFormatting.insert(.prettyPrinted)
    guard let data = try? encoder.encode(value) else { return }
    try? data.write(to: paths.root.appending(path: name), options: .atomic)
}

var taskID: TaskID?
if prepareTask {
    await runtime.refresh()
    let items = (try? await runtime.engine.attentionItems()) ?? []
    guard let item = items.first(where: {
        $0.changeRequest.kind == .github && $0.thread?.remoteID == GitHubFixtures.IDs.blockingThread
    }) else {
        fail("the step-1 GitHub review comment did not arrive (items: \(items.count)).")
    }
    do {
        var task = try await runtime.engine.createTask(fromAttention: item.id)
        if task.checkout?.policy != .isolatedWorktree {
            _ = try await runtime.engine.prepareCheckout(task.id)
            task = try await runtime.engine.taskDetail(task.id).task
        }
        guard task.checkout?.policy == .isolatedWorktree else {
            fail("no isolated worktree: \(task.checkout?.blockedReason ?? "unknown")")
        }
        taskID = task.id
        let handoff = try await runtime.engine.handoff(for: task.id)
        let ready = Ready(
            taskID: task.id.rawValue, worktree: task.checkout?.worktreePath, baseSHA: task.checkout?.baseSHA,
            socket: ipc.socketPath, home: MergeCuePaths.fileSystemPath(paths.root), handoff: handoff.command
        )
        writeJSON(ready, to: "host-ready.json")
        let encoder = MergeCueCoding.wireEncoder()
        if let line = try? encoder.encode(ready) {
            FileHandle.standardOutput.write(line + Data("\n".utf8))
        }
    } catch {
        fail("could not create the demo task: \(error.localizedDescription)")
    }
}

struct Snapshot: Encodable {
    struct Activity: Encodable {
        var at: Date
        var actor: String
        var actorName: String?
        var kind: String
        var message: String
        var fromState: String?
        var toState: String?
    }
    struct ArtifactSummary: Encodable {
        var id: String
        var kind: String
        var title: String
        var reportedBy: String
        var metadata: [String: String]
        var content: String
    }
    var taskID: String?
    var state: String?
    var version: Int?
    var agent: String?
    var resultSummary: String?
    var proposedReply: String?
    var knownRisks: [String]
    var activities: [Activity]
    var artifacts: [ArtifactSummary]
    var providerWrites: [String]
    var isDemo = true
}

func snapshot(taskID: TaskID?, full: Bool) async -> Snapshot {
    var result = Snapshot(knownRisks: [], activities: [], artifacts: [], providerWrites: [])
    if let demo = runtime.demo {
        result.providerWrites = ProviderKind.allCases.flatMap { kind in
            demo.providerWrites(kind).map { "\(kind.rawValue) \($0.method) \($0.url.path)" }
        }
    }
    guard let taskID, let detail = try? await runtime.engine.taskDetail(taskID) else { return result }
    result.taskID = taskID.rawValue
    result.state = detail.task.state.rawValue
    result.version = detail.task.version
    result.agent = detail.task.lease?.agentName ?? detail.task.agentLabel
    result.resultSummary = detail.task.resultSummary
    result.proposedReply = detail.task.proposedReply
    result.knownRisks = detail.task.knownRisks
    result.activities = detail.activities.map {
        .init(at: $0.at, actor: $0.actor.rawValue, actorName: $0.actorName, kind: $0.kind.rawValue, message: $0.message,
              fromState: $0.fromState?.rawValue, toState: $0.toState?.rawValue)
    }
    result.artifacts = detail.artifacts.map {
        .init(id: $0.id, kind: $0.kind.rawValue, title: $0.title, reportedBy: $0.reportedBy.rawValue, metadata: $0.metadata,
              content: full ? String($0.content.prefix(12_000)) : String($0.content.prefix(200)))
    }
    return result
}

// Signals → final report + clean shutdown. (Built outside the main actor: the handlers run on a global queue.)
nonisolated func installSignalHandlers() -> (AsyncStream<Int32>, [DispatchSourceSignal]) {
    let (stream, continuation) = AsyncStream<Int32>.makeStream()
    var sources: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { continuation.yield(number) }
        source.resume()
        sources.append(source)
    }
    return (stream, sources)
}
let (signals, signalSources) = installSignalHandlers()

let hostedTaskID = taskID
let refresher = Task {
    guard let refreshEvery, refreshEvery > 0 else { return }
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(refreshEvery))
        await runtime.refresh()
    }
}
let ticker = Task {
    while !Task.isCancelled {
        writeJSON(await snapshot(taskID: hostedTaskID, full: false), to: "host-state.json")
        try? await Task.sleep(for: .seconds(1))
    }
}

for await received in signals {
    log("received signal \(received); writing the final report")
    break
}
ticker.cancel()
refresher.cancel()
writeJSON(await snapshot(taskID: hostedTaskID, full: true), to: "host-final.json")
await runtime.stop()
signalSources.forEach { $0.cancel() }
log("demo runtime stopped")
exit(0)
