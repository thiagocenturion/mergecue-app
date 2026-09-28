import AgentHandoff
import MergeCueCore
import SwiftUI

// The agent setup wizard (Settings › Agents and the setup assistant): detect → review the exact registration
// (command, config snippet, files touched, backup) → explicit "Register" consent → verify through the helper
// (`tools/list` + a read-only round trip) → only then "Connected". "Copy command" is always available.

/// Settings › Agents.
struct AgentsSettings: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MergeCue hands tasks to the coding agent you already use. It never runs a model itself and never edits your agent's configuration without your consent and a backup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AgentSetupList(model: model)
            AgentReadAccessCard(model: model)
        }
    }
}

/// Settings › Agents › "Agent read access" (S3): what MCP read tools may return.
struct AgentReadAccessCard: View {
    let model: AppModel

    var body: some View {
        Card("Agent read access", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Agents can read", selection: Binding(
                    get: { model.state.agentReadAccess },
                    set: { access in Task { await model.send(.setAgentReadAccess(access)) } }
                )) {
                    ForEach(AgentReadAccess.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(model.state.agentReadAccess.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One card per supported agent (detected or not) + a re-detect button.
struct AgentSetupList: View {
    let model: AppModel
    @State private var isDetecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(AgentKind.allCases, id: \.self) { kind in
                AgentSetupCard(model: model, kind: kind, agent: model.state.agents.first { $0.kind == kind })
            }
            HStack(spacing: 8) {
                Button {
                    isDetecting = true
                    Task {
                        await model.send(.refreshAgents)
                        isDetecting = false
                    }
                } label: {
                    Label("Detect agents again", systemImage: "arrow.clockwise")
                }
                .disabled(isDetecting)
                if isDetecting { ProgressView().controlSize(.small) }
            }
            if let home = model.state.runtime?.helperHome {
                Label("This MergeCue uses MERGECUE_HOME=\(home). Agents must run the helper with the same variable to reach it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.waiting)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Detect / register / verify one agent.
struct AgentSetupCard: View {
    let model: AppModel
    let kind: AgentKind
    let agent: AgentStatus?
    @State private var plan: MCPRegistrationPlan?
    @State private var verification: AgentVerification?
    @State private var busy = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let agent {
                    registration(agent)
                    ThemeDivider()
                    verify(agent)
                } else {
                    Text("\(kind.displayName) wasn't found on this Mac (login shell PATH and the usual install locations). Install it, then detect again — or copy the command and run it yourself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CommandBlock(text: genericCommand)
                    Button("Copy command") { model.copyToPasteboard(genericCommand, confirmation: "Command copied") }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentMark(kind: kind, size: 26)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(kind.displayName)\(agent?.version.map { " \($0)" } ?? "")").font(.headline)
                Text(agent?.path ?? "Not detected").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if let agent {
                Chip(text: agent.mcpRegistration.displayText,
                     symbol: agent.mcpRegistration.isVerified ? "checkmark.seal.fill" : "exclamationmark.triangle",
                     tone: agent.mcpRegistration.isVerified ? .success : .attention)
            } else {
                Chip(text: "Not installed", symbol: "minus.circle", tone: .neutral)
            }
        }
    }

    // MARK: Step 1 — registration

    @ViewBuilder
    private func registration(_ agent: AgentStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StepTitle(number: "1", title: "Register MergeCue MCP", done: agent.mcpRegistration.isRegistered)
            if let plan {
                PlanReview(plan: plan)
                HStack(spacing: 8) {
                    Button(plan.action == .register ? "Register" : "Remove") {
                        // The owner reviewed the plan above: this click is the explicit consent.
                        let consent = RegistrationConsent.userConfirmed(plan)
                        busy = true
                        Task {
                            if await model.send(.applyAgentRegistration(plan, consent)) != nil { self.plan = nil }
                            busy = false
                        }
                    }
                    .buttonStyle(GradientButtonStyle(size: .small))
                    .disabled(busy || model.mode == .preview)
                    .help("Runs exactly the command above after backing up the files it touches")
                    Button("Copy command") { model.copyToPasteboard(plan.displayCommand, confirmation: "Command copied — run it yourself in Terminal") }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                    Button("Cancel") { self.plan = nil }
                        .buttonStyle(.link)
                }
            } else {
                Text(agent.mcpRegistration.isRegistered
                     ? "Registered with this Mac's MergeCue helper (user scope)."
                     : "MergeCue adds a user-scope MCP server named “mergecue” with \(kind.displayName)'s own CLI. You review the exact command, the config it writes and the backup location first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if agent.mcpRegistration.isRegistered {
                        Button("Remove registration…") { loadPlan(.unregister) }
                            .buttonStyle(SecondaryButtonStyle(size: .small))
                            .disabled(busy)
                    } else {
                        Button("Review setup…") { loadPlan(.register) }
                            .buttonStyle(GradientButtonStyle(size: .small))
                            .disabled(busy)
                        if isMismatch(agent) {
                            Button("Remove existing entry…") { loadPlan(.unregister) }
                                .buttonStyle(SecondaryButtonStyle(size: .small))
                                .disabled(busy)
                        }
                    }
                    Button("Copy command") {
                        Task {
                            let result = await model.send(.prepareAgentRegistration(kind, .register))
                            if let command = result?.registrationPlan?.displayCommand {
                                model.copyToPasteboard(command, confirmation: "Command copied — run it yourself in Terminal")
                            }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                    if busy { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private func isMismatch(_ agent: AgentStatus) -> Bool {
        if case .needsAttention = agent.mcpRegistration { return true }
        return false
    }

    private func loadPlan(_ action: RegistrationAction) {
        busy = true
        Task {
            plan = await model.send(.prepareAgentRegistration(kind, action))?.registrationPlan
            busy = false
        }
    }

    // MARK: Step 2 — verification

    @ViewBuilder
    private func verify(_ agent: AgentStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StepTitle(number: "2", title: "Verify the connection", done: agent.mcpRegistration.isVerified)
            Text("Starts the bundled mergecue-mcp like \(kind.displayName) does, lists its tools and makes one read-only call. Nothing is written.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let verification {
                VStack(alignment: .leading, spacing: 3) {
                    Label(verification.succeeded ? "Connected" : "Not connected",
                          systemImage: verification.succeeded ? "checkmark.seal.fill" : "xmark.octagon")
                        .foregroundStyle(verification.succeeded ? Theme.mint : Theme.critical)
                        .font(.callout.weight(.semibold))
                    Text("tools/list: \(verification.toolCount) tools\(verification.missingTools.isEmpty ? "" : " (missing \(verification.missingTools.joined(separator: ", ")))") · \(verification.roundTrip)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if case .registered(let verifiedAt?) = agent.mcpRegistration {
                Text("Verified \(UIFormat.relative(from: verifiedAt, now: model.now)).").font(.caption).foregroundStyle(.secondary)
            }
            Button("Verify") {
                busy = true
                Task {
                    verification = await model.send(.verifyAgent(kind))?.verification
                    busy = false
                }
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
            .disabled(busy || !agent.mcpRegistration.isRegistered || model.mode == .preview)
            .help(agent.mcpRegistration.isRegistered ? "Run tools/list and a read-only round trip" : "Register first")
        }
    }

    private var genericCommand: String {
        let helper = model.state.runtime?.helperPath ?? "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp"
        let quoted = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch kind {
        case .claudeCode: return "claude mcp add --scope user mergecue -- \(quoted)"
        case .codex: return "codex mcp add mergecue -- \(quoted)"
        }
    }
}

/// Everything the owner consents to: command, resulting config, touched files, backup folder.
struct PlanReview: View {
    let plan: MCPRegistrationPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled("Command MergeCue will run") { CommandBlock(text: plan.displayCommand) }
            labeled(plan.action == .register ? "Configuration it adds" : "Configuration it removes") { CommandBlock(text: plan.configSnippet) }
            labeled("Files it changes") {
                Text(plan.filesTouched.map { UIFormat.abbreviatedPath(MergeCuePaths.fileSystemPath($0)) }.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            labeled("Backed up first to") {
                Text(UIFormat.abbreviatedPath(MergeCuePaths.fileSystemPath(plan.backupDirectory)))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Monospaced, selectable command/config text.
struct CommandBlock: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceSunken))
    }
}

/// "① Register MergeCue MCP ✓".
struct StepTitle: View {
    var number: String
    var title: String
    var done: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(done ? Theme.mint : Theme.blue))
            Text(title).font(.callout.weight(.semibold))
            if done { Image(systemName: "checkmark").foregroundStyle(Theme.mint).font(.caption.weight(.bold)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title)\(done ? ", done" : "")")
    }
}
