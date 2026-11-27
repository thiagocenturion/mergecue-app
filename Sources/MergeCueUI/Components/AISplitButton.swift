import MergeCueCore
import SwiftUI

/// The large gradient "✦ <title> | ⌄" capsule: the main part runs the default action, the chevron opens `menu`
/// (other variants and the agent to use).
struct AISplitButton<MenuContent: View>: View {
    var title: String
    var help: String
    var accessibilityHint: String
    var menuLabel: String
    var action: () -> Void
    @ViewBuilder var menu: MenuContent

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    SparkleIcon(size: 16)
                        .symbolEffect(.bounce, options: .repeat(.periodic(delay: 4)))
                    Text(title)
                }
                .scaledFont(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .help(help)
            .accessibilityHint(accessibilityHint)
            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 26).accessibilityHidden(true)
            Menu {
                menu
            } label: {
                // A plain menu draws the label exactly as laid out, so the chevron sits in the middle of its segment.
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 50)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(menuLabel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Capsule().fill(Theme.actionGradient))
        .glassShape(Capsule(), tint: Theme.blue, fallback: .clear)
        .contentShape(Capsule())
    }
}

/// The agent picker section shared by the AI split buttons.
struct AgentMenuSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Agent") {
            ForEach(AgentKind.allCases, id: \.self) { kind in
                Toggle(isOn: Binding(get: { model.effectiveAgentKind == kind }, set: { if $0 { model.selectedAgentKind = kind } })) {
                    Text(model.state.agents.contains { $0.kind == kind } ? kind.shortName : "\(kind.shortName) (not detected)")
                }
            }
        }
    }
}

/// "✦ Fix now | ⌄": the main part creates the default task; the menu picks another task type or the agent.
struct AITaskSplitButton: View {
    @Bindable var model: AppModel
    let attentionID: String
    let defaultType: TaskType

    var body: some View {
        AISplitButton(title: defaultType.actionTitle, help: "\(defaultType.actionTitle): creates a task for your agent (⌘↩)",
                      accessibilityHint: "Creates a task for your agent. Command-Return", menuLabel: "More AI actions") {
            start(defaultType)
        } menu: {
            Section("Task") {
                ForEach(TaskType.allCases, id: \.self) { type in
                    Button(type.menuTitle) { start(type) }
                }
            }
            AgentMenuSection(model: model)
        }
    }

    private func start(_ type: TaskType) {
        Task { await model.createTaskAndShow(attentionID: attentionID, type: type) }
    }
}

/// "✦ Review with AI | ⌄" on someone else's pull/merge request (D60): opens the review handoff; the menu picks
/// what to focus on and the agent.
struct AIReviewSplitButton: View {
    @Bindable var model: AppModel
    let changeRequest: ChangeRequestKey

    var body: some View {
        AISplitButton(title: ReviewFocus.full.title, help: "Hand this \(changeRequest.kind.changeRequestNoun) to your coding agent for a review (⌘↩)",
                      accessibilityHint: "Opens the review handoff for your agent. Command-Return", menuLabel: "More review options") {
            model.startReview(changeRequest)
        } menu: {
            Section("Review") {
                ForEach(ReviewFocus.allCases, id: \.self) { focus in
                    Button(focus == .full ? "Full review" : focus.title) { model.startReview(changeRequest, focus: focus) }
                }
            }
            AgentMenuSection(model: model)
        }
    }
}

extension TaskType {
    /// Menu wording (Fix now / Address with AI / Draft reply / Investigate CI).
    var menuTitle: String {
        switch self {
        case .fixReview: "Fix now"
        case .addressSuggestion: "Address with AI"
        case .draftReply: "Draft reply"
        case .investigateCI: "Investigate CI"
        }
    }
}
