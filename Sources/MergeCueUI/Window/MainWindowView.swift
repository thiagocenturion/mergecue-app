import MergeCueCore
import SwiftUI

/// The main window: sidebar (Inbox, PRs & MRs, Tasks, Rules, Settings), a list column and a detail column.
public struct MainWindowView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } content: {
            ScreenList(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        } detail: {
            ScreenDetail(model: model)
                .navigationSplitViewColumnWidth(min: 440, ideal: 620)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 560)
        .sheet(item: $model.pendingPreview) { preview in
            ApprovalSheet(model: model, preview: preview)
        }
        .sheet(item: $model.ruleEditor) { context in
            RuleEditorSheet(model: model, context: context)
        }
        .sheet(item: connectSheetBinding) { item in
            ConnectAccountSheet(model: model, kind: item.kind)
        }
    }

    private var connectSheetBinding: Binding<ConnectSheetItem?> {
        Binding(
            get: { model.connectSheetKind.map(ConnectSheetItem.init) },
            set: { model.connectSheetKind = $0?.kind }
        )
    }
}

/// The columns of the main window.
public enum MainWindowColumn: String, Sendable, CaseIterable {
    case sidebar, content, detail
}

/// One column of the main window on its own. `MainWindowView` places the same views in a `NavigationSplitView`;
/// visual QA renders them side by side (the split view's glass sidebar and nested scroll content don't render into
/// offscreen bitmaps).
public struct MainWindowColumnView: View {
    let model: AppModel
    let column: MainWindowColumn

    public init(model: AppModel, column: MainWindowColumn) {
        self.model = model
        self.column = column
    }

    public var body: some View {
        switch column {
        case .sidebar: Sidebar(model: model)
        case .content: ScreenList(model: model)
        case .detail: ScreenDetail(model: model)
        }
    }
}

/// The list column of the current screen.
struct ScreenList: View {
    let model: AppModel

    var body: some View {
        switch model.screen {
        case .inbox: InboxList(model: model)
        case .changeRequests: ChangeRequestList(model: model)
        case .tasks: TaskList(model: model)
        case .rules: RuleList(model: model)
        case .settings: SettingsList(model: model)
        }
    }
}

/// The detail column of the current screen, with banners on top.
struct ScreenDetail: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.banners.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.banners) { banner in
                        BannerView(banner: banner) { model.dismissBanner(banner.id) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            Group {
                switch model.screen {
                case .inbox: InboxDetail(model: model)
                case .changeRequests: ChangeRequestDetail(model: model)
                case .tasks: TaskDetail(model: model)
                case .rules: RuleDetail(model: model)
                case .settings: SettingsDetail(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ConnectSheetItem: Identifiable {
    var kind: ProviderKind
    var id: String { kind.rawValue }
}

/// Screens, counts and the persistent non-live badge.
struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(MainScreen.allCases) { screen in
                    Label(screen.title, systemImage: screen.symbol)
                        .badge(badge(for: screen))
                        .tag(screen)
                        .help("\(screen.title) (⌘\(String(screen.shortcutDigit)))")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter(model: model)
        }
    }

    private var selection: Binding<MainScreen?> {
        Binding(get: { model.screen }, set: { if let screen = $0 { model.screen = screen } })
    }

    private func badge(for screen: MainScreen) -> Int {
        switch screen {
        case .inbox: model.sections.needsYou.filter { if case .attention = $0.source { true } else { false } }.count
        case .tasks: model.sections.count(.ready) + model.state.tasks.filter { [.blocked, .failed, .stale].contains($0.task.state) }.count
        case .rules: model.pendingRuleProposals.count
        case .changeRequests, .settings: 0
        }
    }
}

private struct SidebarFooter: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if model.mode != .live {
                ModeBadge(mode: model.mode)
                Text(model.mode.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.state.accounts) { account in
                HStack(spacing: 5) {
                    ProviderGlyph(kind: account.kind, size: 11)
                    Text(UIFormat.syncText(account.status, now: model.now))
                        .font(.caption2)
                        .foregroundStyle(account.status.state.isProblem ? Theme.color(UIFormat.tone(of: account.status.state)) : Color.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

/// Placeholder shown when nothing is selected.
struct NothingSelected: View {
    var title: String
    var symbol: String
    var message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
