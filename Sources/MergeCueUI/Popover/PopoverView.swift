import MergeCueCore
import SwiftUI

/// The menu bar popover: header (app tile, "Your PRs at a glance", sync state), account problems, the sections
/// Needs you / Waiting for agent (only when non-empty) / AI working / Ready (top 3 each, collapsible) and the footer
/// (Open MergeCue, Refresh, Pause notifications, Settings).
/// Keyboard: ↑/↓ select, Return runs the primary action, ⌘R refreshes, ⌘, opens Settings, ⌘O opens the window, Esc closes.
public struct PopoverView: View {
    let model: AppModel
    var onClose: () -> Void
    @FocusState private var isFocused: Bool
    @State private var contentHeight: CGFloat = 320
    @State private var topHeight: CGFloat = 90
    @State private var bottomHeight: CGFloat = 64

    public init(model: AppModel, onClose: @escaping () -> Void = {}) {
        self.model = model
        self.onClose = onClose
    }

    private var maxScrollHeight: CGFloat {
        max(220, Theme.popoverMaxHeight - topHeight - bottomHeight - 2)
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                PopoverHeader(model: model)
                ThemeDivider().padding(.horizontal, 20)
                AccountProblemsStrip(model: model)
                if !model.banners.isEmpty || model.handoffOffer != nil {
                    VStack(spacing: 8) {
                        ForEach(model.banners) { banner in
                            BannerView(banner: banner) { model.dismissBanner(banner.id) }
                        }
                        if let offer = model.handoffOffer {
                            HandoffCallout(model: model, offer: offer)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            if model.isLoaded && model.state.accounts.isEmpty {
                OnboardingPrompt(model: model)
            } else {
                sectionsScroll
            }
            VStack(spacing: 0) {
                ThemeDivider().padding(.horizontal, 20)
                PopoverFooter(model: model)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
        }
        .frame(width: Theme.popoverWidth)
        .background(Theme.popoverBackground.ignoresSafeArea())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) {
            model.movePopoverSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.movePopoverSelection(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            guard model.popoverSelection != nil else { return .ignored }
            Task { await model.activatePopoverSelection() }
            return .handled
        }
        .onExitCommand(perform: onClose)
        .onAppear { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MergeCue")
    }

    private var sectionsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(PopoverSection.allCases) { section in
                        if section != .waitingForAgent || !model.sections.items(section).isEmpty {
                            PopoverSectionView(model: model, section: section)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 18)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maxScrollHeight))
            .onChange(of: model.popoverSelection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// App tile, "MergeCue", "Your PRs at a glance", the non-live badge and "● Synced now".
struct PopoverHeader: View {
    let model: AppModel

    var body: some View {
        let summary = Presentation.syncSummary(accounts: model.state.accounts, now: model.now, refreshing: model.isRefreshing)
        HStack(alignment: .center, spacing: 14) {
            Button {
                model.showScreen(.inbox)
            } label: {
                AppMark(size: 50)
            }
            .buttonStyle(PlainRowButtonStyle())
            .help("Open MergeCue")
            .accessibilityLabel("Open MergeCue window")
            VStack(alignment: .leading, spacing: 3) {
                Text("MergeCue")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize()
                Text("Your PRs at a glance")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(summary.tone == .success ? Theme.mint : (summary.tone == .neutral ? Theme.textTertiary : Theme.color(summary.tone)))
                    .frame(width: 8, height: 8)
                Text(summary.text.replacingOccurrences(of: "Synced just now", with: "Synced now"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .help(accountLines)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.text)
            .accessibilityHint(accountLines)
            ModeBadge(mode: model.mode)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    /// Per-account last successful sync, for the tooltip.
    private var accountLines: String {
        model.state.accounts.map { "\($0.kind.displayName) · \($0.account.displayLabel): \(UIFormat.syncText($0.status, now: model.now))" }
            .joined(separator: "\n")
    }
}

/// Accounts that are offline, rate limited or need new credentials — each independently.
struct AccountProblemsStrip: View {
    let model: AppModel

    var body: some View {
        let problems = model.accountsWithProblems
        if !problems.isEmpty || model.notificationsPaused {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(problems) { account in
                    AccountStatusLine(model: model, account: account)
                }
                if model.notificationsPaused, let until = model.state.notificationsPausedUntil {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.waiting)
                            .frame(width: 18)
                        Text("Notifications paused until \(UIFormat.time(until))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Resume") { Task { await model.send(.pauseNotifications(until: nil)) } }
                            .buttonStyle(PlainRowButtonStyle())
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }
}

struct AccountStatusLine: View {
    let model: AppModel
    let account: AccountState

    var body: some View {
        let tone = UIFormat.tone(of: account.status.state)
        HStack(spacing: 8) {
            ProviderGlyph(kind: account.kind, size: 14)
                .frame(width: 18)
            Text("\(account.kind.displayName) · \(account.account.displayLabel)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.color(tone))
                .accessibilityHidden(true)
            Text(UIFormat.syncText(account.status, now: model.now))
                .font(.system(size: 12))
                .foregroundStyle(Theme.color(tone))
                .lineLimit(1)
            if account.status.state == .authExpired {
                Button("Reconnect") {
                    model.connectSheetKind = account.kind
                    model.showSettings(.accounts)
                }
                .buttonStyle(PlainRowButtonStyle())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
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

/// "Open MergeCue" + Refresh, Pause notifications and Settings.
struct PopoverFooter: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.showScreen(.inbox)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 15))
                    Text("Open MergeCue")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.vertical, 6)
            }
            .buttonStyle(PlainRowButtonStyle())
            .keyboardShortcut("o", modifiers: .command)
            .help("Open the MergeCue window (⌘O)")
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: model.isRefreshing)
            }
            .buttonStyle(IconButtonStyle(size: 30, filled: false))
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh all accounts (⌘R)")
            .accessibilityLabel("Refresh")
            PauseNotificationsMenu(model: model)
            Rectangle().fill(Theme.divider).frame(width: 1, height: 22).padding(.horizontal, 4)
            Button {
                model.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle(size: 30, filled: false))
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// Pause notifications for 1 hour / until tomorrow, or resume.
struct PauseNotificationsMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button("Pause for 1 Hour") {
                Task { await model.send(.pauseNotifications(until: model.now.addingTimeInterval(3_600))) }
            }
            Button("Pause Until Tomorrow") {
                Task { await model.send(.pauseNotifications(until: PauseOptions.tomorrowMorning(after: model.now))) }
            }
            if model.notificationsPaused {
                Divider()
                Button("Resume Notifications") {
                    Task { await model.send(.pauseNotifications(until: nil)) }
                }
            }
        } label: {
            Image(systemName: model.notificationsPaused ? "bell.slash.fill" : "bell")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(model.notificationsPaused ? Theme.waiting : Theme.textSecondary)
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.notificationsPaused ? "Notifications paused" : "Pause notifications")
        .accessibilityLabel(model.notificationsPaused ? "Notifications paused" : "Pause notifications")
    }
}

enum PauseOptions {
    /// 9:00 tomorrow (local time).
    static func tomorrowMorning(after now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

/// Section header (dot, "Needs you · 2", collapse chevron), its top rows and "View all N".
struct PopoverSectionView: View {
    @Bindable var model: AppModel
    let section: PopoverSection

    private var isCollapsed: Bool { model.collapsedPopoverSections.contains(section) }

    var body: some View {
        let items = model.sections.items(section)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isCollapsed { model.collapsedPopoverSections.remove(section) } else { model.collapsedPopoverSections.insert(section) }
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Theme.color(section))
                        .frame(width: 10, height: 10)
                        .shadow(color: Theme.color(section).opacity(0.5), radius: 4)
                    Text("\(section.title)  ·  \(items.count)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(items.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainRowButtonStyle())
            .accessibilityLabel("\(section.title), \(items.count) item\(items.count == 1 ? "" : "s")")
            .accessibilityHint(isCollapsed ? "Expands the section" : "Collapses the section")
            .accessibilityAddTraits(.isHeader)

            if !isCollapsed {
                if items.isEmpty {
                    EmptySectionRow(section: section)
                } else {
                    VStack(spacing: 8) {
                        ForEach(items.prefix(AppModel.popoverRowLimit)) { item in
                            PopoverRowView(model: model, item: item)
                                .id(item.id)
                        }
                    }
                    if items.count > AppModel.popoverRowLimit {
                        Button {
                            model.showAll(section)
                        } label: {
                            HStack(spacing: 4) {
                                Text("View all \(items.count)")
                                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                            }
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.leading, 4)
                        }
                        .buttonStyle(PlainRowButtonStyle())
                        .accessibilityLabel("View all \(section.title), \(items.count) items")
                    }
                }
            }
        }
    }
}

struct EmptySectionRow: View {
    let section: PopoverSection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section == .needsYou ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(section == .needsYou ? Theme.mint : Theme.textTertiary)
                .accessibilityHidden(true)
            Text(section.emptyTitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(Theme.surface.opacity(0.6), radius: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Transient message.
struct BannerView: View {
    let banner: Banner
    var onDismiss: () -> Void

    var body: some View {
        let color = banner.tone == .neutral ? Theme.accent : Theme.color(banner.tone)
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(banner.message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(PlainRowButtonStyle())
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch banner.tone {
        case .critical: "exclamationmark.octagon.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .neutral, .progress: "info.circle.fill"
        }
    }
}

/// Shown right after "Fix with AI" in the popover: hand the new task to an agent.
struct HandoffCallout: View {
    let model: AppModel
    let offer: HandoffOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundStyle(Theme.waiting)
                    .accessibilityHidden(true)
                Text("Waiting for agent · \(offer.taskID.rawValue)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    model.handoffOffer = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(PlainRowButtonStyle())
                .accessibilityLabel("Dismiss")
            }
            Text("Paste the command into your agent, or open the agent at the task checkout. The status changes only after it connects.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let agent = model.preferredAgent, agent.canOpenTasks {
                    Button {
                        Task { await model.send(.openInAgent(offer.taskID, agent: agent.kind)) }
                    } label: {
                        HStack(spacing: 6) {
                            AgentMark(kind: agent.kind, size: 13, monochrome: .white)
                            Text("Open in \(agent.kind.shortName)")
                        }
                    }
                    .buttonStyle(GradientButtonStyle(size: .small))
                }
                Button("Copy command") {
                    Task { await model.send(.copyHandoffCommand(offer.taskID, agent: model.preferredAgent?.kind)) }
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                Spacer()
                Button("Details") { model.showTask(offer.taskID) }
                    .buttonStyle(PlainRowButtonStyle())
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(12)
        .cardBackground(Theme.waiting.opacity(0.07), radius: 12, border: Theme.waiting.opacity(0.35))
    }
}

/// First launch: no accounts yet.
struct OnboardingPrompt: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Text("Welcome to MergeCue")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("PRs move forward. You stay in flow.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Text("Connect GitHub, GitLab or Bitbucket Cloud to see what needs you across all of them.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                ForEach(ProviderKind.allCases, id: \.self) { ProviderBadge(kind: $0, size: 34, style: .tile) }
            }
            .padding(.vertical, 6)
            Button("Connect an Account…") { model.showSettings(.accounts) }
                .buttonStyle(GradientButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
