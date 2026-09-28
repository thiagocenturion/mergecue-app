import AgentHandoff
import Foundation
import MergeCueCore
import MergeCueEngine
import ServiceManagement

// UI conveniences that are not engine calls: GitHub CLI import, agent detection / registration / verification,
// "Open in agent", and the login item.

extension MergeCueRuntime {
    // MARK: Helper

    /// The `mergecue-mcp` helper agents are configured with (app bundle, else the SwiftPM build directory).
    public var mcpHelperURL: URL? {
        if let override = options.mcpHelperOverride { return override }
        return MCPHelperLocator.locate()
    }

    /// Environment for spawning the helper ourselves (verification): carries `MERGECUE_HOME` / `MERGECUE_SOCKET`
    /// when this runtime does not use the default location.
    public var helperEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if paths.usesCustomHome {
            environment[MergeCuePaths.homeEnvironmentKey] = MergeCuePaths.fileSystemPath(paths.root)
        }
        if paths.usesSocketOverride {
            environment[MergeCuePaths.socketEnvironmentKey] = paths.socketPath
        }
        return environment
    }

    // MARK: Accounts

    /// Explicit user action: reads the GitHub CLI's token for `hostname` (`gh auth token`). Never logged.
    public func importGitHubCLIToken(hostname: String = "github.com") async throws -> Credential {
        try await GitHubCLITokenImporter().importToken(hostname: hostname)
    }

    /// Imports the GitHub CLI token and connects (or reconnects) the github.com account with it.
    @discardableResult
    public func connectGitHubFromCLI(label: String? = nil) async throws -> Account {
        let credential = try await importGitHubCLIToken()
        return try await engine.connectAccount(AccountConnectionRequest(
            instance: .githubCom, method: .githubCLIImport, credential: credential, label: label
        ))
    }

    // MARK: Agents

    /// Installed agent CLIs (Claude Code, Codex).
    public func detectAgents() async -> [DetectedAgent] {
        await AgentDetector().detectAll()
    }

    /// The plan to (un)register the bundled helper with `agent` (shown to the owner before consent).
    public func registrationPlan(for agent: DetectedAgent, action: RegistrationAction = .register) throws -> MCPRegistrationPlan {
        guard let helper = mcpHelperURL else { throw RuntimeError.helperNotFound }
        switch action {
        case .register:
            return try MCPRegistrationPlan.register(agent, helper: helper, paths: dataPaths)
        case .unregister:
            return try MCPRegistrationPlan.unregister(
                agent: agent.kind, executable: agent.executableURL, helper: helper, paths: dataPaths
            )
        }
    }

    /// Whether `agent` has the `mergecue` server registered (read-only `mcp get`).
    public func registrationStatus(for agent: DetectedAgent) async -> AgentRegistrationStatus {
        await AgentRegistrar(paths: dataPaths).registrationStatus(agent)
    }

    /// Applies a plan the owner consented to (backup first; see `AgentRegistrar`).
    public func applyRegistration(_ plan: MCPRegistrationPlan, consent: RegistrationConsent) async throws -> RegistrationOutcome {
        let registrar = AgentRegistrar(paths: dataPaths)
        switch plan.action {
        case .register: return try await registrar.register(plan, consent: consent)
        case .unregister: return try await registrar.unregister(plan, consent: consent)
        }
    }

    /// Spawns the helper, lists its tools and runs a read-only round trip against this runtime.
    public func verifyMCPHelper(probe: ReadOnlyProbe = .listAttention) async throws -> MCPVerificationReport {
        guard let helper = mcpHelperURL else { throw RuntimeError.helperNotFound }
        return try await MCPServerVerifier().verify(helper: helper, environment: helperEnvironment, probe: probe)
    }

    /// The copyable handoff command for a task (`cd '<worktree>' && <agent> '<prompt>'`).
    public func handoffCommand(for taskID: TaskID, agent: DetectedAgent) async throws -> HandoffCommand {
        let handoff = try await engine.handoff(for: taskID)
        guard let directory = handoff.workingDirectory else {
            throw RuntimeError.failed(handoff.blockedReason ?? "The task has no checkout to open the agent in yet.")
        }
        return try HandoffCommandBuilder.command(for: agent, taskID: taskID, worktree: URL(filePath: directory, directoryHint: .isDirectory))
    }

    /// "Open in agent": opens a Terminal window running the agent in the task's checkout. The task stays
    /// "Task ready to start" until the agent really claims it.
    @discardableResult
    public func openInAgent(taskID: TaskID, agent: DetectedAgent) async throws -> URL {
        let command = try await handoffCommand(for: taskID, agent: agent)
        let script = try await AgentLauncher().openInTerminal(command: command, paths: dataPaths)
        try await engine.recordHandoffCopied(taskID, agentName: agent.kind.displayName)
        return script
    }

    // MARK: Login item

    /// Launch-at-login state (`SMAppService.mainApp`).
    public enum LoginItemStatus: Sendable, Hashable {
        case enabled
        case disabled
        /// Registered, but the owner must approve it in System Settings › General › Login Items.
        case requiresApproval
        /// Not running from an app bundle (development builds, tests).
        case unavailable
    }

    public func loginItemStatus() -> LoginItemStatus {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Opt-in launch at login (registers/unregisters `SMAppService.mainApp`).
    @discardableResult
    public func setLaunchAtLogin(_ enabled: Bool) throws -> LoginItemStatus {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
        return loginItemStatus()
    }
}
