import MergeCueCore
import SwiftUI

/// What a handoff gives the agent (D60): a task (investigate or fix) or someone else's pull request to review.
enum HandoffTarget {
    case task(TaskRecord)
    case review(ChangeRequestSnapshot, ReviewFocus)
}

/// "1 Open in your coding agent": With MCP / Without MCP tabs, the agent picker, the exact command or prompt,
/// Open / Copy and a terminal-style preview. Used by a task's handoff and by "Review with AI".
struct HandoffStepView: View {
    @Bindable var model: AppModel
    let target: HandoffTarget
    var wide: Bool
    var number: String
    var title: String
    var message: String?

    init(model: AppModel, record: TaskRecord, wide: Bool, number: String, title: String, message: String?) {
        self.init(model: model, target: .task(record), wide: wide, number: number, title: title, message: message)
    }

    init(model: AppModel, target: HandoffTarget, wide: Bool, number: String, title: String, message: String?) {
        self.model = model
        self.target = target
        self.wide = wide
        self.number = number
        self.title = title
        self.message = message
    }

    private var agentKind: AgentKind { model.effectiveAgentKind }
    private var detected: AgentStatus? { model.state.agents.first { $0.kind == agentKind } }
    private var mode: AgentPromptMode { model.agentPromptMode }

    /// The repository's folder on this Mac, where Open starts the agent (D61); nil when it isn't mapped.
    private var directory: String? {
        switch target {
        case .task(let record): model.localCheckout(for: record.task.origin.changeRequest, task: record)
        case .review(let snapshot, _): model.localCheckout(for: snapshot.key)
        }
    }

    private var repoFullPath: String {
        switch target {
        case .task(let record): record.task.origin.changeRequestRef.repoFullPath
        case .review(let snapshot, _): snapshot.summary.repository.fullPath
        }
    }

    /// The exact text Copy puts on the clipboard and Open hands to the agent.
    private var promptText: String {
        switch target {
        case .task(let record): model.taskPrompt(record, mode: mode)
        case .review(let snapshot, let focus): model.reviewPrompt(snapshot, focus: focus, mode: mode)
        }
    }

    var body: some View {
        if model.handoffCollapsed {
            compact
        } else if wide {
            HStack(alignment: .top, spacing: 22) {
                controls
                TerminalPreview(model: model, target: target, agent: agentKind, prompt: promptText)
                    .frame(width: 250)
            }
        } else {
            // The terminal preview is illustration only; below the controls it just makes the panel taller.
            controls
        }
    }

    /// Collapsed: the title, the mode, Open and Copy, nothing else.
    private var compact: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(showsMessage: false)
            modeTabs
            VStack(spacing: 10) {
                openButton.buttonStyle(GradientButtonStyle(size: .tall, fullWidth: true))
                copyButton.buttonStyle(SecondaryButtonStyle(size: .tall, fullWidth: true))
            }
            agentNote
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(showsMessage: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            StepNumber(text: number)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .scaledFont(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsMessage, let message {
                    Text(message)
                        .scaledFont(.system(size: 13.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.snappy(duration: 0.25)) { model.handoffCollapsed.toggle() }
            } label: {
                Image(systemName: model.handoffCollapsed ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(IconButtonStyle(size: 30, filled: false))
            .help(model.handoffCollapsed ? "Show the command and agent options" : "Collapse to make room for the comment")
            .accessibilityLabel(model.handoffCollapsed ? "Expand agent handoff" : "Collapse agent handoff")
        }
    }

    /// "With MCP" (the agent fetches context through MergeCue) / "Without MCP" (everything in the prompt).
    private var modeTabs: some View {
        UnderlineTabs(options: AgentPromptMode.allCases.map { ($0, $0.title, nil) },
                      selection: Binding(get: { model.agentPromptMode }, set: { model.agentPromptMode = $0 }))
            .accessibilityLabel("How the agent gets the context")
    }

    private var openButton: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                AgentMark(kind: agentKind, size: 16, monochrome: .white)
                Text("Open in \(agentKind.shortName)")
                Image(systemName: "arrow.right").scaledFont(.system(size: 13, weight: .semibold))
            }
            .lineLimit(1)
        }
        .disabled(!(detected?.canOpenTasks ?? false) || directory == nil)
        .help(openHelp)
    }

    private var copyButton: some View {
        Button(action: copy) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                Text(copyTitle)
            }
            .lineLimit(1)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(showsMessage: true)
            modeTabs
                .padding(.top, 20)
            SegmentedTrack(options: AgentKind.allCases, selection: Binding(get: { agentKind }, set: { model.selectedAgentKind = $0 }), height: 44) { kind, selected in
                HStack(spacing: 10) {
                    AgentMark(kind: kind, size: 20)
                    Text(kind.shortName)
                        .scaledFont(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                }
            }
            .padding(.top, 18)
            .accessibilityLabel("Coding agent")
            Text(mode == .mcp ? "Command" : "Prompt")
                .scaledFont(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 18)
            CommandField(command: promptText, maxHeight: mode == .mcp ? nil : 240, onCopy: copy)
                .padding(.top, 8)
            HStack(spacing: 12) {
                openButton.fixedSize().buttonStyle(GradientButtonStyle(size: .tall))
                copyButton.fixedSize().buttonStyle(SecondaryButtonStyle(size: .tall))
            }
            .padding(.top, 16)
            agentNote
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func copy() {
        switch (target, mode) {
        case (.task(let record), .mcp):
            Task { await model.send(.copyHandoffCommand(record.id, agent: agentKind)) }
        case (.task, .standalone):
            model.copyToPasteboard(promptText, confirmation: "Prompt copied. Paste it into \(agentKind.displayName). "
                + "Without MCP the task doesn't track the agent: mark it done when it's finished.")
        case (.review, _):
            model.copyToPasteboard(promptText, confirmation: "Review prompt copied. Paste it into \(agentKind.displayName).")
        }
    }

    private func open() {
        guard let directory else { return }
        let prompt = promptText
        let kind = agentKind
        switch (target, mode) {
        case (.task(let record), .mcp): Task { await model.send(.openInAgent(record.id, agent: kind, directory: directory)) }
        case (.task(let record), .standalone): Task { await model.send(.openPromptInAgent(record.id, agent: kind, directory: directory, prompt: prompt)) }
        case (.review(let snapshot, _), _): Task { await model.send(.openReviewInAgent(snapshot.key, agent: kind, directory: directory, prompt: prompt)) }
        }
    }

    private var copyTitle: String { mode == .mcp ? "Copy command" : "Copy prompt" }

    private var openHelp: String {
        guard let detected else { return "\(agentKind.shortName) wasn't found on this Mac. Use \(copyTitle)." }
        guard detected.canOpenTasks else { return "Opening \(detected.name) isn't verified yet. Use \(copyTitle)." }
        guard let directory else { return "Map \(repoFullPath) to its folder in Settings › Repositories to open \(detected.name) there." }
        return "Opens \(detected.name) in \(UIFormat.abbreviatedPath(directory))"
    }

    // MARK: Notes

    @ViewBuilder
    private var agentNote: some View {
        if directory == nil {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                note(symbol: "folder.badge.questionmark", color: Theme.waitingText,
                     text: "MergeCue doesn't know where \(repoFullPath) is on this Mac, so it can't open your agent there. Map it, or use \(copyTitle).")
                Button("Map…") { model.showSettings(.repositories) }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                    .fixedSize()
            }
            .padding(.bottom, 4)
        }
        switch mode {
        case .standalone:
            note(symbol: "info.circle", color: Theme.textSecondary, text: standaloneNote)
        case .mcp:
            VStack(alignment: .leading, spacing: 8) {
                if case .review = target, !model.mcpCanReadAnyChangeRequest {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        note(symbol: "lock.shield", color: Theme.waitingText,
                             text: "MergeCue MCP only shares pull requests of your tasks. Allow reads of the whole inbox to review this one with MCP, or use Without MCP.")
                        Button("Allow") { Task { await model.send(.setAgentReadAccess(.allInbox)) } }
                            .buttonStyle(SecondaryButtonStyle(size: .small))
                            .fixedSize()
                            .help("Settings › Agents › Agent read access: Whole inbox")
                    }
                }
                registrationNote
            }
        }
    }

    private var standaloneNote: String {
        switch target {
        case .task: "Everything is in the prompt, no MCP setup needed. MergeCue won't see the agent's progress: mark the task done when it's finished."
        case .review: "Everything is in the prompt, no MCP setup needed."
        }
    }

    @ViewBuilder
    private var registrationNote: some View {
        if let detected {
            if !detected.mcpRegistration.isVerified {
                note(symbol: "exclamationmark.triangle.fill", color: Theme.waitingText,
                     text: "\(detected.name): \(detected.mcpRegistration.displayText). Set it up in Settings › Agents, or use Without MCP.")
            }
        } else {
            note(symbol: "exclamationmark.triangle.fill", color: Theme.waitingText,
                 text: "\(agentKind.shortName) wasn't detected on this Mac. Copy the command into any MCP-capable agent, or use Without MCP.")
        }
    }

    private func note(symbol: String, color: Color, text: String) -> some View {
        Label(text, systemImage: symbol)
            .scaledFont(.system(size: 12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The exact handoff command or prompt in a monospaced field with a copy button. Long prompts scroll inside
/// `maxHeight`.
struct CommandField: View {
    var command: String
    var maxHeight: CGFloat?
    var onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            text
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(IconButtonStyle(size: 28, filled: false))
            .help("Copy")
            .accessibilityLabel("Copy")
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 13)
        .cardBackground(Theme.surfaceSunken, radius: 11, border: Theme.borderStrong)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Handoff text: \(command)")
    }

    @ViewBuilder
    private var text: some View {
        let label = Text(command)
            .scaledFont(.system(size: 13, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let maxHeight {
            ScrollView { label }
                .frame(maxHeight: maxHeight)
                .scrollIndicators(.automatic)
        } else {
            label
        }
    }
}

/// A terminal-style illustration of what to run. Not live output: it lists only context MergeCue really has.
struct TerminalPreview: View {
    let model: AppModel
    let target: HandoffTarget
    var agent: AgentKind
    var prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 11, height: 11) }
                Spacer()
                Text(agent.shortName)
                    .scaledFont(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xC9D1E0))
                Spacer()
                Color.clear.frame(width: 47, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(minHeight: 34)
            .background(Color.black.opacity(0.25))
            VStack(alignment: .leading, spacing: 4) {
                line("> ", firstSentence, prompt: true)
                    .padding(.bottom, 8)
                ForEach(Array(comments.enumerated()), id: \.offset) { comment($0.element) }
                HStack(spacing: 6) {
                    Text(">").foregroundStyle(Theme.cyan)
                    Rectangle().fill(Color(hex: 0xE6EAF2)).frame(width: 8, height: 15)
                }
                .padding(.top, 10)
            }
            .scaledFont(.system(size: 11.5, design: .monospaced))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A dark terminal on glass: the tint keeps its light text readable in light mode too.
        .background(Theme.terminalBackground.opacity(0.82))
        .clipShape(SmoothRect())
        .glassCard()
        .help("Illustration of the handoff, not live output from your agent.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the handoff in \(agent.shortName). Illustration, not live output.")
    }

    /// The commented lines under the command.
    private var comments: [String] {
        switch target {
        case .task(let record):
            let ready = Presentation.handoffContext(record, state: model.state).filter { $0.status == .ready }.map { "- \($0.title)" }
            if model.agentPromptMode == .mcp {
                return ["MergeCue has prepared the context", "for this task, including:"] + ready
                    + ["", "The agent will start working", "after you run this command."]
            }
            return ["The prompt carries the context", "itself, including:"] + ready + ["", "No MCP needed. Mark the task", "done when the agent finishes."]
        case .review(_, let focus):
            let points = switch focus {
            case .full: ["- business logic gaps", "- edge cases and performance", "- codebase parity and nits"]
            case .conventions: ["- code and design patterns", "- architecture and naming", "- nits"]
            case .logic: ["- bugs and logic gaps", "- edge cases", "- performance"]
            }
            return ["The agent reviews the changes for:"] + points + ["", "Findings only. Nothing is", "changed or published."]
        }
    }

    private var firstSentence: String {
        let first = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        return first.split(separator: ".").first.map(String.init) ?? first
    }

    private func line(_ prefix: String, _ text: String, prompt: Bool) -> some View {
        (Text(prefix).foregroundStyle(Theme.cyan) + Text(text).foregroundStyle(Color(hex: 0xE6EAF2)))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func comment(_ text: String) -> some View {
        Text("# " + text)
            .foregroundStyle(Color(hex: 0x98A2B6))
            .fixedSize(horizontal: false, vertical: true)
    }
}
