import MergeCueCore
import SwiftUI

/// Creates or edits a rule. Saving never activates an agent proposal; activation is a separate user step.
struct RuleEditorSheet: View {
    let model: AppModel
    let context: RuleEditorContext
    @Environment(\.dismiss) private var dismiss
    @State private var rule: Rule
    @State private var includeText: String
    @State private var excludeText: String
    @State private var actionKind: ActionKind
    @State private var taskType: TaskType
    @State private var quietEnabled: Bool
    @State private var quietStart: Date
    @State private var quietEnd: Date

    enum ActionKind: String, CaseIterable, Identifiable {
        case notify, createTask, requestExecution
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notify: "Notify me"
            case .createTask: "Create an AI task"
            case .requestExecution: "Create a task and request execution"
            }
        }
    }

    init(model: AppModel, context: RuleEditorContext) {
        self.model = model
        self.context = context
        let rule = context.rule
        _rule = State(initialValue: rule)
        _includeText = State(initialValue: rule.repoInclude.joined(separator: ", "))
        _excludeText = State(initialValue: rule.repoExclude.joined(separator: ", "))
        switch rule.action {
        case .notify:
            _actionKind = State(initialValue: .notify)
            _taskType = State(initialValue: .fixReview)
        case .createTask(let type):
            _actionKind = State(initialValue: .createTask)
            _taskType = State(initialValue: type)
        case .requestExecution(let type):
            _actionKind = State(initialValue: .requestExecution)
            _taskType = State(initialValue: type)
        }
        let quiet = rule.quietHours ?? QuietHours(start: (22, 0), end: (7, 0), timeZone: .current)
        _quietEnabled = State(initialValue: rule.quietHours != nil)
        _quietStart = State(initialValue: Self.date(minute: quiet.startMinute))
        _quietEnd = State(initialValue: Self.date(minute: quiet.endMinute))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(context.isNew ? "New Rule" : "Edit Rule")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                }
                Section("When") {
                    MultiToggleGrid(title: "Events", options: ChangeEventType.allCases, label: \.displayName, selection: $rule.eventTypes)
                    MultiToggleGrid(title: "Providers", options: ProviderKind.allCases, label: \.displayName, selection: $rule.providerKinds)
                    TextField("Repositories", text: $includeText, prompt: Text("acme/**, group/sub/*  (empty = any)"))
                    TextField("Except", text: $excludeText, prompt: Text("acme/legacy-*"))
                    MultiToggleGrid(title: "Involvement", options: Involvement.allCases, label: \.rawValue, selection: $rule.involvement)
                    MultiToggleGrid(title: "Comment kinds", options: [CommentKind.comment, .question, .suggestion], label: \.rawValue,
                                    selection: $rule.commentKinds)
                    Toggle("Include my own comments and pushes", isOn: $rule.includeOwnEvents)
                }
                Section("Then") {
                    Picker("Action", selection: $actionKind) {
                        ForEach(ActionKind.allCases) { Text($0.title).tag($0) }
                    }
                    if actionKind != .notify {
                        Picker("Task type", selection: $taskType) {
                            ForEach(TaskType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                    if actionKind == .requestExecution {
                        Text("Runs unattended only with a verified agent runtime you opted into; otherwise the task waits for an agent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Stepper("At most \(rule.maxFiresPerHour) per hour", value: $rule.maxFiresPerHour, in: 1...120)
                    Toggle("Quiet hours", isOn: $quietEnabled)
                    if quietEnabled {
                        DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: $quietEnd, displayedComponents: .hourAndMinute)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Rules never bypass approval for repository writes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 680)
    }

    private func close() {
        model.ruleEditor = nil
        dismiss()
    }

    private func save() {
        var rule = rule
        rule.repoInclude = Self.split(includeText)
        rule.repoExclude = Self.split(excludeText)
        switch actionKind {
        case .notify: rule.action = .notify
        case .createTask: rule.action = .createTask(taskType)
        case .requestExecution: rule.action = .requestExecution(taskType)
        }
        rule.quietHours = quietEnabled
            ? QuietHours(startMinute: Self.minute(of: quietStart), endMinute: Self.minute(of: quietEnd), timeZoneID: TimeZone.current.identifier)
            : nil
        Task {
            if await model.send(.saveRule(rule)) != nil {
                model.selectedRuleID = rule.id
                close()
            }
        }
    }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func date(minute: Int) -> Date {
        Calendar.current.date(bySettingHour: (minute / 60) % 24, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    static func minute(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

/// A wrap-around grid of toggles for a `Set` filter ("empty = any").
struct MultiToggleGrid<Option: Hashable>: View {
    var title: String
    var options: [Option]
    var label: KeyPath<Option, String>
    @Binding var selection: Set<Option>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(selection.isEmpty ? "Any" : "\(selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(options, id: \.self) { option in
                    Toggle(option[keyPath: label], isOn: Binding(
                        get: { selection.contains(option) },
                        set: { isOn in
                            if isOn { selection.insert(option) } else { selection.remove(option) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                }
            }
        }
    }
}
