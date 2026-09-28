import MergeCueCore
import SwiftUI

/// The menu bar popover: header, the four sections (top 3 rows each) and the per-account status strip.
/// Keyboard: ↑/↓ select, Return runs the primary action, ⌘R refreshes, ⌘, opens Settings, Esc closes.
public struct PopoverView: View {
    let model: AppModel
    var onClose: () -> Void
    @FocusState private var isFocused: Bool
    @State private var contentHeight: CGFloat = 320
    @State private var topHeight: CGFloat = 46
    @State private var bottomHeight: CGFloat = 80

    public init(model: AppModel, onClose: @escaping () -> Void = {}) {
        self.model = model
        self.onClose = onClose
    }

    /// Room for the scrolling sections inside the ~600 pt popover (header, callouts and status strip are measured).
    private var maxScrollHeight: CGFloat {
        max(200, Theme.popoverMaxHeight - topHeight - bottomHeight - 2)
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                PopoverHeader(model: model)
                Divider()
                if !model.banners.isEmpty || model.handoffOffer != nil {
                    VStack(spacing: 8) {
                        ForEach(model.banners) { banner in
                            BannerView(banner: banner) { model.dismissBanner(banner.id) }
                        }
                        if let offer = model.handoffOffer {
                            HandoffCallout(model: model, offer: offer)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            if model.isLoaded && model.state.accounts.isEmpty {
                OnboardingPrompt(model: model)
            } else {
                sectionsScroll
            }
            Divider()
            AccountStatusStrip(model: model)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
        }
        .frame(width: Theme.popoverWidth)
        .background(.regularMaterial)
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
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(PopoverSection.allCases) { section in
                        PopoverSectionView(model: model, section: section)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
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

/// App mark, name, non-live badge and the Refresh / Pause / Settings controls.
struct PopoverHeader: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.showScreen(.inbox)
            } label: {
                HStack(spacing: 7) {
                    AppMark(size: 20)
                    Text("MergeCue")
                        .font(.headline)
                }
            }
            .buttonStyle(.plain)
            .help("Open MergeCue")
            .accessibilityLabel("Open MergeCue window")
            ModeBadge(mode: model.mode)
            Spacer(minLength: 4)
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh all accounts (⌘R)")
            .accessibilityLabel("Refresh")
            PauseNotificationsMenu(model: model)
            Button {
                model.showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 16, height: 16)
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                .foregroundStyle(model.notificationsPaused ? Theme.attention : Color.secondary)
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

/// Section header (symbol, title, count, View all) and its top rows or empty state.
struct PopoverSectionView: View {
    let model: AppModel
    let section: PopoverSection

    var body: some View {
        let items = model.sections.items(section)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: section.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.color(section.tone))
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                Text("\(items.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(items.isEmpty ? Color.secondary : Theme.color(section.tone))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(items.isEmpty ? Color.secondary.opacity(0.12) : Theme.tint(section.tone)))
                Spacer()
                if !items.isEmpty {
                    Button {
                        model.showAll(section)
                    } label: {
                        Text(items.count > AppModel.popoverRowLimit ? "View all \(items.count)" : "View all")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("View all \(section.title), \(items.count) items")
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isHeader)

            if items.isEmpty {
                EmptySectionRow(section: section)
            } else {
                VStack(spacing: 2) {
                    ForEach(items.prefix(AppModel.popoverRowLimit)) { item in
                        PopoverRowView(model: model, item: item)
                            .id(item.id)
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
            Image(systemName: section == .needsYou ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(section == .needsYou ? Theme.mint : Color.secondary)
                .accessibilityHidden(true)
            Text(section.emptyTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Transient message.
struct BannerView: View {
    let banner: Banner
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(banner.tone == .neutral ? Theme.accent : Theme.color(banner.tone))
                .accessibilityHidden(true)
            Text(banner.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .fill(banner.tone == .neutral ? Theme.accent.opacity(0.10) : Theme.tint(banner.tone)))
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

/// Shown right after "Fix with AI": hand the new task to an agent.
struct HandoffCallout: View {
    let model: AppModel
    let offer: HandoffOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Task \(offer.taskID.rawValue) is waiting for an agent")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    model.handoffOffer = nil
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            Text("Awaiting agent connection. Copy the command into your agent, or open the agent at the task checkout.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Copy command") {
                    Task { await model.send(.copyHandoffCommand(offer.taskID, agent: model.preferredAgent?.kind)) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                if let agent = model.preferredAgent, agent.canOpenTasks {
                    Button("Open in \(agent.name)") {
                        Task { await model.send(.openInAgent(offer.taskID, agent: agent.kind)) }
                    }
                }
                Spacer()
                Button("Details") { model.showTask(offer.taskID) }
                    .buttonStyle(.link)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.accent.opacity(0.25)))
    }
}

/// First launch: no accounts yet.
struct OnboardingPrompt: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            AppMark(size: 48)
            Text("Welcome to MergeCue")
                .font(.title3.weight(.semibold))
            Text("PRs move forward. You stay in flow.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Connect GitHub, GitLab or Bitbucket Cloud to see what needs you across all of them.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect an Account…") { model.showSettings(.accounts) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
