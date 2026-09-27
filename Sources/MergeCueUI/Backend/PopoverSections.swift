import Foundation
import MergeCueCore

/// Semantic color role of a row, chip or icon (mapped to colors by the views).
public nonisolated enum Tone: String, Sendable, Hashable, CaseIterable {
    case neutral, attention, critical, progress, success
}

/// The four popover sections (PLAN §4).
public nonisolated enum PopoverSection: String, Sendable, Hashable, CaseIterable, Identifiable {
    case needsYou, waitingForAgent, aiWorking, ready

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .waitingForAgent: "Waiting for agent"
        case .aiWorking: "AI working"
        case .ready: "Ready"
        }
    }

    public var emptyTitle: String {
        switch self {
        case .needsYou: "You're all caught up"
        case .waitingForAgent: "Nothing waiting for an agent"
        case .aiWorking: "No agent work in progress"
        case .ready: "Nothing ready for review yet"
        }
    }

    public var symbol: String {
        switch self {
        case .needsYou: "bell.badge"
        case .waitingForAgent: "hourglass"
        case .aiWorking: "sparkles"
        case .ready: "checkmark.seal"
        }
    }

    public var tone: Tone {
        switch self {
        case .needsYou: .attention
        case .waitingForAgent: .neutral
        case .aiWorking: .progress
        case .ready: .success
        }
    }
}

nonisolated extension TaskType {
    /// Button title of the attention action that creates this task type.
    public var actionTitle: String {
        switch self {
        case .fixReview: "Fix with AI"
        case .addressSuggestion: "Address with AI"
        case .draftReply: "Draft reply"
        case .investigateCI: "Investigate with AI"
        }
    }

    /// The attention action matching this task type.
    public var attentionAction: AttentionAction {
        switch self {
        case .fixReview: .fixWithAI
        case .addressSuggestion: .addressWithAI
        case .draftReply: .draftReply
        case .investigateCI: .investigateWithAI
        }
    }

    public init?(attentionAction: AttentionAction) {
        switch attentionAction {
        case .fixWithAI: self = .fixReview
        case .addressWithAI: self = .addressSuggestion
        case .draftReply: self = .draftReply
        case .investigateWithAI: self = .investigateCI
        case .openInProvider, .acknowledge, .snooze, .markRead: return nil
        }
    }
}

/// The single primary action of a popover row.
public nonisolated enum PrimaryAction: Sendable, Hashable {
    /// "Fix with AI", "Investigate with AI", "Draft reply", "Address with AI".
    case createTask(attentionID: String, type: TaskType)
    /// Opens the item's detail ("Review", "Open").
    case openAttention(attentionID: String, title: String)
    case copyCommand(TaskID)
    /// Opens the task's detail ("View", "Review", "Map checkout…").
    case openTask(TaskID, title: String)
    case retryTask(TaskID)

    public var title: String {
        switch self {
        case .createTask(_, let type): type.actionTitle
        case .openAttention(_, let title): title
        case .copyCommand: "Copy command"
        case .openTask(_, let title): title
        case .retryTask: "Retry"
        }
    }

    /// Whether the action deserves the prominent (filled) button style.
    public var isProminent: Bool {
        switch self {
        case .createTask: true
        case .openTask(_, let title): title == "Review"
        case .openAttention, .copyCommand, .retryTask: false
        }
    }
}

/// One row of the popover: an attention item or a task.
public nonisolated struct PopoverItem: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        case attention(String)
        case task(TaskID)
    }

    public var id: String
    public var source: Source
    public var section: PopoverSection
    public var providerKind: ProviderKind
    public var changeRequest: ChangeRequestKey
    public var repoFullPath: String
    public var title: String
    public var reason: String
    public var reasonSymbol: String
    public var tone: Tone
    public var date: Date
    public var priority: AttentionPriority
    public var isUnread: Bool
    public var primaryAction: PrimaryAction

    public var number: Int { changeRequest.number }
    /// "acme/payments-api #42" (GitLab: "!42").
    public var refText: String { "\(repoFullPath) \(providerKind.formattedNumber(number))" }

    /// VoiceOver description of the whole row (the primary button has its own label).
    public func accessibilityLabel(now: Date) -> String {
        let noun = providerKind.changeRequestNoun
        let age = UIFormat.spokenAge(from: date, now: now)
        return "\(providerKind.displayName) \(noun) \(repoFullPath) number \(number). \(title). \(reason). \(age)."
    }
}

/// The derived popover content.
public nonisolated struct PopoverSections: Sendable, Hashable {
    public var needsYou: [PopoverItem] = []
    public var waitingForAgent: [PopoverItem] = []
    public var aiWorking: [PopoverItem] = []
    public var ready: [PopoverItem] = []

    public init(needsYou: [PopoverItem] = [], waitingForAgent: [PopoverItem] = [], aiWorking: [PopoverItem] = [], ready: [PopoverItem] = []) {
        self.needsYou = needsYou
        self.waitingForAgent = waitingForAgent
        self.aiWorking = aiWorking
        self.ready = ready
    }

    public func items(_ section: PopoverSection) -> [PopoverItem] {
        switch section {
        case .needsYou: needsYou
        case .waitingForAgent: waitingForAgent
        case .aiWorking: aiWorking
        case .ready: ready
        }
    }

    public func count(_ section: PopoverSection) -> Int { items(section).count }

    /// Urgent = something that needs the user with high or urgent priority (menu bar alert glyph).
    public var hasUrgent: Bool { needsYou.contains { $0.priority >= .high } }

    public var isEmpty: Bool { PopoverSection.allCases.allSatisfy { items($0).isEmpty } }

    /// Every row, section by section (keyboard navigation order when all sections show everything).
    public var all: [PopoverItem] { PopoverSection.allCases.flatMap { items($0) } }
}

/// Pure derivation of the popover sections from an `AppState`.
///
/// - **Needs you**: actionable attention items (open, or snooze expired) without an active (non-terminal) task,
///   plus tasks that wait for a user decision (`blocked`, `failed`). Sorted by priority, then recency.
/// - **Waiting for agent**: `waiting_for_agent` and `stale` tasks (an agent may re-claim a stale task).
/// - **AI working**: only tasks with a real claim — state `working` with an agent lease.
/// - **Ready**: `ready_for_review` tasks.
public nonisolated enum PopoverDerivation {
    public static func derive(from state: AppState, now: Date) -> PopoverSections {
        let activeTasks = state.tasks.filter { !$0.task.isTerminal }
        let activeTaskIDs = Set(activeTasks.map(\.id))
        let attentionWithActiveTask = Set(activeTasks.compactMap(\.task.origin.attentionItemID))

        var sections = PopoverSections()
        for item in state.attention where item.isActionable(now: now) {
            if let linked = item.linkedTaskID, activeTaskIDs.contains(linked) { continue }
            if attentionWithActiveTask.contains(item.id) { continue }
            sections.needsYou.append(row(for: item, now: now))
        }
        for record in state.tasks {
            guard let section = section(for: record) else { continue }
            let row = row(for: record, section: section, state: state, now: now)
            switch section {
            case .needsYou: sections.needsYou.append(row)
            case .waitingForAgent: sections.waitingForAgent.append(row)
            case .aiWorking: sections.aiWorking.append(row)
            case .ready: sections.ready.append(row)
            }
        }
        sections.needsYou.sort { lhs, rhs in
            lhs.priority != rhs.priority ? lhs.priority > rhs.priority : lhs.date > rhs.date
        }
        sections.waitingForAgent.sort { $0.date > $1.date }
        sections.aiWorking.sort { $0.date > $1.date }
        sections.ready.sort { $0.date > $1.date }
        return sections
    }

    /// Which section a task belongs to, if any.
    public static func section(for record: TaskRecord) -> PopoverSection? {
        switch record.task.state {
        case .blocked, .failed: .needsYou
        case .waitingForAgent, .stale: .waitingForAgent
        case .working: record.hasRealClaim ? .aiWorking : .waitingForAgent
        case .readyForReview: .ready
        case .approvedAction, .done, .cancelled, .dismissed: nil
        }
    }

    // MARK: Rows

    static func row(for item: AttentionItem, now: Date) -> PopoverItem {
        PopoverItem(
            id: "att:" + item.id,
            source: .attention(item.id),
            section: .needsYou,
            providerKind: item.providerKind,
            changeRequest: item.changeRequest,
            repoFullPath: item.repoFullPath,
            title: item.title,
            reason: item.summary,
            reasonSymbol: item.reason.symbolName,
            tone: item.reason.tone,
            date: item.updatedAt,
            priority: item.priority,
            isUnread: item.isUnread,
            primaryAction: primaryAction(for: item)
        )
    }

    /// The attention item's primary action: the first AI action it suggests, otherwise "Review"/"Open".
    public static func primaryAction(for item: AttentionItem) -> PrimaryAction {
        let aiActions: [AttentionAction] = [.fixWithAI, .investigateWithAI, .addressWithAI, .draftReply]
        if let action = item.suggestedActions.first(where: aiActions.contains), let type = TaskType(attentionAction: action) {
            return .createTask(attentionID: item.id, type: type)
        }
        return .openAttention(attentionID: item.id, title: item.reason == .reviewRequested ? "Review" : "Open")
    }

    static func row(for record: TaskRecord, section: PopoverSection, state: AppState, now: Date) -> PopoverItem {
        let task = record.task
        let (reason, symbol, tone, action, priority) = describe(record, now: now)
        return PopoverItem(
            id: "task:" + task.id.rawValue,
            source: .task(task.id),
            section: section,
            providerKind: task.origin.providerKind,
            changeRequest: task.origin.changeRequest,
            repoFullPath: task.origin.changeRequestRef.repoFullPath,
            title: task.origin.title,
            reason: reason,
            reasonSymbol: symbol,
            tone: tone,
            date: task.state == .working ? (task.lease?.heartbeatAt ?? task.updatedAt) : task.updatedAt,
            priority: priority,
            isUnread: false,
            primaryAction: action
        )
    }

    // swiftlint:disable:next large_tuple
    static func describe(_ record: TaskRecord, now: Date) -> (String, String, Tone, PrimaryAction, AttentionPriority) {
        let task = record.task
        let agent = task.lease?.agentName ?? task.agentLabel ?? "The agent"
        switch task.state {
        case .waitingForAgent:
            return ("Awaiting agent connection", "hourglass", .neutral, .copyCommand(task.id), .normal)
        case .stale:
            let since = task.lease?.heartbeatAt ?? task.updatedAt
            return ("No heartbeat from \(agent) for \(UIFormat.duration(from: since, to: now))", "exclamationmark.triangle.fill",
                    .attention, .retryTask(task.id), .normal)
        case .working:
            guard record.hasRealClaim else {
                return ("Task ready to start", "hourglass", .neutral, .copyCommand(task.id), .normal)
            }
            let progress = record.latestProgress?.message ?? "Claimed the task"
            return ("\(agent): \(progress)", "sparkles", .progress, .openTask(task.id, title: "View"), .normal)
        case .readyForReview:
            return (readySummary(record, agent: agent), "checkmark.seal.fill", .success, .openTask(task.id, title: "Review"), .normal)
        case .blocked:
            let reason = task.checkout?.blockedReason ?? task.lastError?.message ?? "Blocked"
            let isCheckout = task.checkout?.policy == .blocked
            return (reason, "lock.fill", .attention, .openTask(task.id, title: isCheckout ? "Map checkout…" : "View"), .normal)
        case .failed:
            let message = task.lastError?.message ?? "The agent reported a failure"
            return ("Failed: \(message)", "xmark.octagon.fill", .critical, .retryTask(task.id), .normal)
        case .approvedAction:
            return ("Performing the approved action…", "arrow.triangle.2.circlepath", .progress, .openTask(task.id, title: "View"), .normal)
        case .done, .cancelled, .dismissed:
            return (task.state.displayName, "checkmark", .neutral, .openTask(task.id, title: "View"), .low)
        }
    }

    static func readySummary(_ record: TaskRecord, agent: String) -> String {
        var parts = ["\(agent) finished"]
        if let diff = record.artifact(.diff), let files = diff.metadata["files_changed"] {
            parts.append(files == "1" ? "1 file changed" : "\(files) files changed")
        }
        if let tests = record.artifact(.testRun), let status = tests.metadata["status"] {
            parts.append(status == "passed" ? "tests passed" : "tests \(status)")
        }
        if record.task.type == .draftReply, record.task.proposedReply != nil {
            parts.append("reply drafted")
        }
        return parts.joined(separator: " · ")
    }
}

nonisolated extension AttentionReason {
    /// SF Symbol for rows and chips.
    public var symbolName: String {
        switch self {
        case .reviewComment: "text.bubble.fill"
        case .changesRequested: "exclamationmark.bubble.fill"
        case .reviewerQuestion: "questionmark.bubble.fill"
        case .codeSuggestion: "chevron.left.forwardslash.chevron.right"
        case .reply: "arrowshape.turn.up.left.fill"
        case .ciFailed: "xmark.octagon.fill"
        case .reviewRequested: "eye.fill"
        case .readyToMerge: "checkmark.circle.fill"
        case .mergeConflict: "arrow.triangle.merge"
        }
    }

    public var tone: Tone {
        switch self {
        case .changesRequested, .reviewComment, .reviewerQuestion, .reply: .attention
        case .ciFailed, .mergeConflict: .critical
        case .codeSuggestion, .reviewRequested: .progress
        case .readyToMerge: .success
        }
    }
}

nonisolated extension TaskState {
    public var tone: Tone {
        switch self {
        case .waitingForAgent, .cancelled, .dismissed: .neutral
        case .working, .approvedAction: .progress
        case .readyForReview, .done: .success
        case .blocked, .stale: .attention
        case .failed: .critical
        }
    }

    public var symbolName: String {
        switch self {
        case .waitingForAgent: "hourglass"
        case .working: "sparkles"
        case .readyForReview: "checkmark.seal.fill"
        case .approvedAction: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .blocked: "lock.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "slash.circle"
        case .stale: "exclamationmark.triangle.fill"
        case .dismissed: "archivebox"
        }
    }
}
