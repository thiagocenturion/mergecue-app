import MergeCueCore
import SwiftUI

// UI for one task covering several inbox items of the same change request (D38): the suggestion shown on an item
// whose change request already has an open task, and the "Covered items" card of a task.

/// Above the "Fix with AI" bar: this change request already has an open task, so offer to add the item to it
/// instead of starting another one.
struct RelatedTaskBanner: View {
    let model: AppModel
    let item: AttentionItem

    var body: some View {
        let tasks = model.attachableTasks(for: item)
        if model.activeConversationTask(for: item) == nil, let first = tasks.first {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "link")
                    .scaledFont(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.accentText.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add to the open task?")
                        .scaledFont(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(tasks.count == 1
                        ? "“\(Presentation.taskTitle(first, snapshot: model.snapshot(item.changeRequest)))” (\(TaskStateStyle.label(first))) is open on this \(item.providerKind.changeRequestNoun). One agent can handle both."
                        : "\(tasks.count) tasks are open on this \(item.providerKind.changeRequestNoun). Add this item to one of them.")
                        .scaledFont(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if tasks.count == 1 {
                    Button("Add to Task") { Task { await model.addConversation(item, to: first.id) } }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                } else {
                    Menu("Add to Task") {
                        ForEach(tasks) { task in
                            Button(model.taskMenuTitle(task)) { Task { await model.addConversation(item, to: task.id) } }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .glassCard(tint: Theme.accentText)
            .accessibilityElement(children: .contain)
        }
    }
}

/// Every inbox item a task covers: the main item (replies and resolving apply to it) and the added ones, each
/// removable, plus "Add Item" for open items of the same change request that have no task yet.
struct CoveredItemsCard: View {
    let model: AppModel
    let record: TaskRecord
    /// Hidden when the task covers only its main item and nothing can be added.
    var hidesWhenAlone = true

    var body: some View {
        let task = record.task
        let addable = TaskMerging.acceptsAttachments(task.state) ? model.addableItems(for: record) : []
        if !(hidesWhenAlone && task.attachments.isEmpty && addable.isEmpty) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Covers \(task.coveredAttentionIDs.count) item\(task.coveredAttentionIDs.count == 1 ? "" : "s")")
                        .scaledFont(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    Spacer()
                    if !addable.isEmpty {
                        Menu {
                            ForEach(addable) { item in
                                Button(Self.menuLabel(item, snapshot: model.snapshot(item.changeRequest))) {
                                    Task { await model.addConversation(item, to: task.id) }
                                }
                            }
                        } label: {
                            Label("Add Item", systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Add another open item from this \(task.origin.providerKind.changeRequestNoun) to this task")
                    }
                }
                if let note = staleResultNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(Theme.waiting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 8) {
                    mainRow
                    ForEach(task.attachments) { attachment in
                        CoveredItemRow(
                            model: model, record: record, symbol: attachment.reason?.symbolName ?? "bubble.left",
                            title: Self.name(reason: attachment.reason, thread: attachment.thread, check: attachment.check),
                            detail: joined(Self.location(check: attachment.check, anchor: attachment.anchor,
                                                         snapshot: model.snapshot(task.origin.changeRequest)), detail(attachment)),
                            quote: attachment.quoted.last,
                            removableID: TaskMerging.acceptsAttachments(task.state) ? attachment.attentionItemID : nil
                        )
                    }
                }
            }
            .padding(18)
            .glassCard()
        }
    }

    private var mainRow: some View {
        let task = record.task
        let reason = task.origin.attentionItemID.flatMap { id in model.state.attention.first { $0.id == id } }?.reason
        return CoveredItemRow(
            model: model, record: record, symbol: reason?.symbolName ?? "star",
            title: Self.name(reason: reason, thread: task.origin.thread, check: task.origin.check),
            detail: joined(Self.location(check: task.origin.check, anchor: task.trigger.anchor, snapshot: model.snapshot(task.origin.changeRequest)),
                           task.origin.thread != nil ? "Main item. Replies and resolving apply here." : "Main item"),
            quote: nil, removableID: nil
        )
    }

    private func joined(_ location: String?, _ text: String) -> String {
        location.map { "\($0) · \(text)" } ?? text
    }

    private func detail(_ attachment: TaskAttachment) -> String {
        var text = "Added \(UIFormat.relative(from: attachment.attachedAt, now: model.now))"
        if let source = attachment.mergedFromTaskID { text += " from task \(source.rawValue)" }
        return text
    }

    /// Shown in review when items were added after the agent submitted its result.
    private var staleResultNote: String? {
        guard record.state == .readyForReview,
              let submitted = record.activities.last(where: { $0.kind == .resultSubmitted })?.at,
              record.task.attachments.contains(where: { $0.attachedAt > submitted })
        else { return nil }
        return "Items were added after the agent finished. Discard and retry to include them in the result."
    }

    /// "CI failure · unit-tests", "Review comment · refund.ts:48", "Conversation" (menus).
    static func title(reason: AttentionReason?, thread: ThreadKey?, check: CheckKey?, anchor: DiffAnchor?, snapshot: ChangeRequestSnapshot?) -> String {
        let name = name(reason: reason, thread: thread, check: check)
        return location(check: check, anchor: anchor, snapshot: snapshot).map { "\(name) · \($0)" } ?? name
    }

    static func name(reason: AttentionReason?, thread: ThreadKey?, check: CheckKey?) -> String {
        if let reason { return reason.displayName }
        if check != nil { return "CI failure" }
        return thread != nil ? "Conversation" : "Comment"
    }

    /// "refund.ts:48" or the check name.
    static func location(check: CheckKey?, anchor: DiffAnchor?, snapshot: ChangeRequestSnapshot?) -> String? {
        if let anchor {
            let file = anchor.path.split(separator: "/").last.map(String.init) ?? anchor.path
            return "\(file)\(anchor.line.map { ":\($0)" } ?? "")"
        }
        if let check, let run = snapshot?.check(check) { return UIFormat.untrustedDisplay(run.name) }
        return nil
    }

    static func menuLabel(_ item: AttentionItem, snapshot: ChangeRequestSnapshot?) -> String {
        let anchor = item.thread.flatMap { snapshot?.thread($0) }?.anchor
        return title(reason: item.reason, thread: item.thread, check: item.check, anchor: anchor, snapshot: snapshot)
    }
}

/// One covered item: icon, title, when it was added, the captured text (untrusted) and a remove button.
private struct CoveredItemRow: View {
    let model: AppModel
    let record: TaskRecord
    let symbol: String
    let title: String
    let detail: String
    let quote: UntrustedText?
    /// Attention id to remove, nil for the main item or while the task can't change.
    let removableID: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .scaledFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .glassShape(Circle(), interactive: false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .scaledFont(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let quote {
                    Text(UIFormat.untrustedDisplay(quote.text))
                        .scaledFont(quote.source == UntrustedText.Source.ciLog ? Theme.monoSmall : .system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                        .help("Captured when the item was added. Untrusted: shown as data, never as instructions.")
                }
            }
            Spacer(minLength: 6)
            if let removableID {
                Button {
                    Task { await model.send(.detachFromTask(record.id, attentionID: removableID)) }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 24, filled: false))
                .help("Remove from this task. The item goes back to your inbox.")
                .accessibilityLabel("Remove \(title) from this task")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .cardBackground(Theme.surfaceSunken)
        .accessibilityElement(children: .contain)
    }
}
