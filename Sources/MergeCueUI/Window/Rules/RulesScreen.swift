import MergeCueCore
import SwiftUI

/// Rules: agent proposals pending activation, the user's rules and the built-in templates.
struct RuleList: View {
    @Bindable var model: AppModel

    var body: some View {
        let proposals = model.pendingRuleProposals
        let templateIDs = Set(RuleTemplates.all.map(\.id))
        let mine = model.state.rules.filter { !templateIDs.contains($0.id) && !($0.origin == .agentProposal && !$0.isActive) }
        let templates = model.state.rules.filter { templateIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Rules")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    model.newRule()
                } label: {
                    Label("New Rule", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            ThemeDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !proposals.isEmpty {
                        section("Pending activation", proposals)
                    }
                    section("Your rules", mine)
                    if mine.isEmpty {
                        Text("No rules yet — start from a template below.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                    }
                    section("Templates", templates)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .background(Theme.contentBackground)
    }

    @ViewBuilder
    private func section(_ title: String, _ rules: [Rule]) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 14)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
        ForEach(rules) { rule in
            let isSelected = model.selectedRuleID == rule.id
            RuleRow(model: model, rule: rule)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Theme.surfaceSelected : Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { model.selectedRuleID = rule.id }
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
        }
    }
}

struct RuleRow: View {
    let model: AppModel
    let rule: Rule

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: RuleText.symbol(rule.action))
                .foregroundStyle(rule.isActive ? Theme.accent : Color.secondary)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name).font(.callout.weight(.medium)).lineLimit(1)
                    if rule.origin == .agentProposal && !rule.isActive {
                        Chip(text: "Proposed by agent", symbol: "sparkles", tone: .attention)
                    }
                }
                Text(RuleText.summary(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Text(rule.isActive ? "On" : "Off")
                .font(.caption.weight(.semibold))
                .foregroundStyle(rule.isActive ? Theme.mint : Color.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Rule detail with Activate / Edit / Delete.
struct RuleDetail: View {
    let model: AppModel

    var body: some View {
        if let id = model.selectedRuleID, let rule = model.state.rules.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: RuleText.symbol(rule.action)).font(.title2).foregroundStyle(Theme.accent)
                            Text(rule.name).font(.title2.weight(.semibold))
                            Chip(text: rule.isActive ? "Active" : "Inactive", tone: rule.isActive ? .success : .neutral)
                        }
                        Text(RuleText.summary(rule)).font(.callout).foregroundStyle(.secondary)
                    }
                    if rule.origin == .agentProposal && !rule.isActive {
                        StatusCallout(tone: .attention, symbol: "sparkles", title: "Proposed by an agent",
                                      message: "An agent proposed this rule through MergeCue MCP. It stays inactive until you activate it here. Rules never bypass approval for repository writes.") {
                            Button("Activate Rule") { Task { await model.send(.activateRule(id: rule.id, active: true)) } }
                                .buttonStyle(GradientButtonStyle(size: .small))
                            Button("Edit…") { model.editRule(rule) }
                            Button("Reject", role: .destructive) { Task { await model.send(.deleteRule(id: rule.id)) } }
                        }
                    }
                    Card("When", systemImage: "bolt") {
                        VStack(alignment: .leading, spacing: 6) {
                            field("Events", rule.eventTypes.isEmpty ? "Any event" : rule.eventTypes.map(\.displayName).sorted().joined(separator: ", "))
                            field("Providers", rule.providerKinds.isEmpty ? "Any provider" : rule.providerKinds.map(\.displayName).sorted().joined(separator: ", "))
                            field("Repositories", rule.repoInclude.isEmpty ? "Any repository" : rule.repoInclude.joined(separator: ", "))
                            if !rule.repoExclude.isEmpty { field("Except", rule.repoExclude.joined(separator: ", ")) }
                            field("Involvement", rule.involvement.isEmpty ? "Any" : rule.involvement.map(\.rawValue).sorted().joined(separator: ", "))
                            if !rule.commentKinds.isEmpty { field("Comment kinds", rule.commentKinds.map(\.rawValue).sorted().joined(separator: ", ")) }
                            field("Own events", rule.includeOwnEvents ? "Included" : "Ignored")
                        }
                    }
                    Card("Then", systemImage: "arrow.turn.down.right") {
                        VStack(alignment: .leading, spacing: 6) {
                            field("Action", RuleText.action(rule.action))
                            field("Rate limit", rule.maxFiresPerHour <= 0 ? "Never fires" : "At most \(rule.maxFiresPerHour) per hour")
                            field("Quiet hours", rule.quietHours.map(RuleText.quietHours) ?? "None")
                            if case .requestExecution = rule.action {
                                Text("Unattended execution runs only with a verified agent runtime; otherwise MergeCue creates the task and it waits for an agent.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if rule.origin != .agentProposal || rule.isActive {
                    HStack {
                        if true {
                            Button(rule.isActive ? "Turn Off" : "Activate") {
                                Task { await model.send(.activateRule(id: rule.id, active: !rule.isActive)) }
                            }
                            .buttonStyle(GradientButtonStyle(size: .small))
                        }
                        if RuleTemplates.template(id: rule.id) != nil {
                            Button("Use as Template…") { model.newRule(from: rule) }
                        } else {
                            Button("Edit…") { model.editRule(rule) }
                            Button("Delete", role: .destructive) { Task { await model.send(.deleteRule(id: rule.id)) } }
                        }
                    }
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.windowBackground)
        } else {
            NothingSelected(title: "Rules", symbol: "wand.and.rays",
                            message: "Rules turn PR/MR events into notifications or tasks, with per-repo filters and quiet hours.")
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

enum RuleText {
    static func symbol(_ action: RuleAction) -> String {
        switch action {
        case .notify: "bell"
        case .createTask: "sparkles"
        case .requestExecution: "play.circle"
        }
    }

    static func action(_ action: RuleAction) -> String {
        switch action {
        case .notify: "Notify me"
        case .createTask(let type): "Create a “\(type.displayName)” task"
        case .requestExecution(let type): "Create a “\(type.displayName)” task and request execution"
        }
    }

    static func phrase(_ type: ChangeEventType) -> String {
        switch type {
        case .reviewComment: "a review comment"
        case .changeRequested: "requested changes"
        case .reply: "a reply"
        case .ciFailed: "a CI failure"
        case .ciRecovered: "CI recovery"
        case .approval: "an approval"
        case .readyToMerge: "ready to merge"
        case .merged: "a merge"
        case .closedWithoutMerge: "closed without merge"
        case .reviewRequested: "a review request"
        case .headChanged: "new commits"
        case .threadResolved: "a resolved thread"
        }
    }

    static func summary(_ rule: Rule) -> String {
        let events = rule.eventTypes.isEmpty ? "any event" : rule.eventTypes.map(phrase).sorted().joined(separator: " or ")
        let repos = rule.repoInclude.isEmpty ? "" : " in \(rule.repoInclude.joined(separator: ", "))"
        return "On \(events)\(repos) → \(action(rule.action).prefix(1).lowercased() + action(rule.action).dropFirst())"
    }

    static func quietHours(_ hours: QuietHours) -> String {
        func format(_ minute: Int) -> String { String(format: "%02d:%02d", (minute / 60) % 24, minute % 60) }
        return "\(format(hours.startMinute))–\(format(hours.endMinute)) (\(hours.timeZoneID))"
    }
}
