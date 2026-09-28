import MergeCueCore
import SwiftUI

/// One popover card: provider tile, "GitHub · acme/payments-api #42 · 6m", headline and ONE trailing action
/// (outlined gradient "✦ Fix with AI", neutral "Investigate", a spinner while an agent really works, mint
/// "Review patch"). Clicking the card opens its detail in the main window.
struct PopoverRowView: View {
    let model: AppModel
    let item: PopoverItem
    @State private var isHovering = false

    private var isSelected: Bool { model.popoverSelection == item.id }

    var body: some View {
        let content = PopoverRowContent.make(item, model: model)
        HStack(spacing: 12) {
            ProviderBadge(kind: item.providerKind, size: 42, style: .tile)
                .overlay(alignment: .topLeading) {
                    if item.isUnread {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Theme.popoverBackground, lineWidth: 1.5))
                            .offset(x: -3, y: -3)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.providerKind.shortName) · \(item.repoFullPath.split(separator: "/").last.map(String.init) ?? item.repoFullPath) \(item.providerKind.formattedNumber(item.number)) · \(UIFormat.compactAge(from: item.date, now: model.now))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 7) {
                    if let glyph = content.glyph {
                        StatusGlyph(symbol: glyph.symbol, color: glyph.color, size: 17)
                    }
                    Text(content.headline)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Theme.surfaceSelected : (isHovering ? Theme.surfaceHover : Theme.surface)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSelected ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: isSelected ? 1.3 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture {
            model.popoverSelection = item.id
            model.open(item)
        }
        .help("\(item.refText) — \(item.title)\n\(item.reason)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilityLabel(now: model.now))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: "Open details") { model.open(item) }
        .accessibilityAction(named: item.primaryAction.title) {
            Task { await model.perform(item.primaryAction) }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        let action = item.primaryAction
        if item.section == .aiWorking {
            WorkingSpinner(size: 28)
                .padding(.trailing, 8)
                .help("\(item.reason) — only shown while an agent holds the task")
        } else {
            let title = Presentation.compactTitle(action, section: item.section)
            let button = Button {
                model.popoverSelection = item.id
                Task { await model.perform(action) }
            } label: {
                HStack(spacing: 6) {
                    if case .createTask(_, let type) = action, type != .investigateCI { SparkleIcon(size: 12) }
                    Text(title).lineLimit(1)
                }
                .fixedSize()
            }
            .help(helpText(for: action))
            .accessibilityLabel("\(action.title), \(item.refText)")
            switch action {
            case .createTask(_, let type) where type != .investigateCI:
                button.buttonStyle(OutlinedGradientButtonStyle(size: .compact))
            case .openTask(_, let title) where item.section == .ready && title == "Review":
                button.buttonStyle(TintedOutlineButtonStyle(color: Theme.mint, size: .compact))
            default:
                button.buttonStyle(SecondaryButtonStyle(size: .compact))
            }
        }
    }

    private func helpText(for action: PrimaryAction) -> String {
        switch action {
        case .createTask(_, let type): "Create a “\(type.displayName)” task and hand it to your agent"
        case .copyCommand: "Copy the handoff command for your agent"
        case .openAttention, .openTask: "Open details in the MergeCue window"
        case .retryTask: "Put the task back in the queue for an agent"
        }
    }
}

/// What a popover card shows, derived from the row and the current state.
struct PopoverRowContent {
    struct Glyph {
        var symbol: String
        var color: Color
    }

    var headline: String
    var glyph: Glyph?

    @MainActor
    static func make(_ item: PopoverItem, model: AppModel) -> PopoverRowContent {
        switch item.source {
        case .attention(let id):
            guard let attention = model.attentionItem(id) else { return PopoverRowContent(headline: item.reason) }
            let text = Presentation.attentionText(attention, snapshot: model.snapshot(attention.changeRequest))
            let glyph: Glyph? = switch attention.reason {
            case .ciFailed, .mergeConflict: Glyph(symbol: "exclamationmark", color: Theme.needs)
            case .readyToMerge: Glyph(symbol: "checkmark", color: Theme.mint)
            default: nil
            }
            return PopoverRowContent(headline: text.headline, glyph: glyph)
        case .task(let id):
            guard let record = model.task(id) else { return PopoverRowContent(headline: item.reason) }
            let headline = Presentation.taskHeadline(record, snapshot: model.snapshot(record.task.origin.changeRequest), now: model.now)
            let glyph: Glyph? = switch record.task.state {
            case .readyForReview:
                Presentation.testSummary(record)?.outcome == .failed ? Glyph(symbol: "exclamationmark", color: Theme.critical)
                    : Glyph(symbol: "checkmark", color: Theme.mint)
            case .stale, .blocked: Glyph(symbol: "exclamationmark", color: Theme.waiting)
            case .failed: Glyph(symbol: "xmark", color: Theme.critical)
            default: nil
            }
            return PopoverRowContent(headline: headline, glyph: glyph)
        }
    }
}
