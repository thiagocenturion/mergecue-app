import MergeCueCore
import SwiftUI

/// One popover row: provider glyph, "namespace/repo #42", 1-line title, reason, age and ONE primary action.
/// Clicking the row opens its detail in the main window.
struct PopoverRowView: View {
    let model: AppModel
    let item: PopoverItem
    @State private var isHovering = false

    private var isSelected: Bool { model.popoverSelection == item.id }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ProviderGlyph(kind: item.providerKind, size: 18)
                .overlay(alignment: .topLeading) {
                    if item.isUnread {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                            .offset(x: -3, y: -3)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(Text(item.repoFullPath).foregroundStyle(.secondary)) \(Text(item.providerKind.formattedNumber(item.number)).fontWeight(.semibold).foregroundStyle(.primary))")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(UIFormat.compactAge(from: item.date, now: model.now))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help(UIFormat.dateTime(item.date))
                }
                Text(item.title)
                    .font(.callout.weight(item.isUnread ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: item.reasonSymbol)
                        .font(.caption2)
                        .foregroundStyle(Theme.color(item.tone))
                        .accessibilityHidden(true)
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    primaryButton
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.16) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            model.popoverSelection = item.id
            model.open(item)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilityLabel(now: model.now))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: "Open details") { model.open(item) }
        .accessibilityAction(named: item.primaryAction.title) {
            Task { await model.perform(item.primaryAction) }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        let action = item.primaryAction
        let button = Button {
            model.popoverSelection = item.id
            Task { await model.perform(action) }
        } label: {
            Text(action.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .controlSize(.small)
        .help(helpText(for: action))
        .accessibilityLabel("\(action.title), \(item.refText)")
        if action.isProminent {
            button.buttonStyle(.borderedProminent).tint(Theme.accent)
        } else {
            button.buttonStyle(.bordered)
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

/// Per-account sync status: each account independently, never blocking the others.
struct AccountStatusStrip: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.state.accounts.isEmpty {
                Text("No accounts connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.state.accounts) { account in
                AccountStatusLine(model: model, account: account)
            }
            if model.notificationsPaused, let until = model.state.notificationsPausedUntil {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.attention)
                        .frame(width: 12)
                    Text("Notifications paused until \(UIFormat.time(until))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume") { Task { await model.send(.pauseNotifications(until: nil)) } }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
    }
}

struct AccountStatusLine: View {
    let model: AppModel
    let account: AccountState

    var body: some View {
        let tone = UIFormat.tone(of: account.status.state)
        HStack(spacing: 6) {
            ProviderGlyph(kind: account.kind, size: 12)
            Text(account.account.displayLabel)
                .font(.caption)
                .lineLimit(1)
            Text(account.kind.displayName)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if account.status.state.isProblem {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(Theme.color(tone))
                    .accessibilityHidden(true)
            }
            Text(UIFormat.syncText(account.status, now: model.now))
                .font(.caption)
                .foregroundStyle(account.status.state.isProblem ? Theme.color(tone) : Color.secondary)
                .lineLimit(1)
            if account.status.state == .authExpired {
                Button("Reconnect") {
                    model.connectSheetKind = account.kind
                    model.showSettings(.accounts)
                }
                .buttonStyle(.link)
                .font(.caption.weight(.medium))
            }
        }
        .help(account.status.message.map { SecretRedactorHelp.safe($0) } ?? account.status.state.displayText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.kind.displayName) account \(account.account.displayLabel): \(UIFormat.syncText(account.status, now: model.now))")
    }

    private var symbol: String {
        switch account.status.state {
        case .offline: "wifi.slash"
        case .authExpired: "key.slash"
        case .rateLimited: "gauge.with.dots.needle.100percent"
        default: "exclamationmark.triangle.fill"
        }
    }
}

enum SecretRedactorHelp {
    /// Account messages come from providers; redact before showing them.
    static func safe(_ message: String) -> String { SecretRedactor.redact(message) }
}
