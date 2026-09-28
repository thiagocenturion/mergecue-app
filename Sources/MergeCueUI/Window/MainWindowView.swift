import MergeCueCore
import SwiftUI

/// The main window: the sidebar (logo, navigation, connected accounts, sync footer) and the current screen.
/// Laid out edge to edge under a transparent title bar; the sidebar reserves room for the traffic lights.
public struct MainWindowView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    /// The result review is a focused screen with its own leading timeline column instead of the sidebar.
    private var isFocusedReview: Bool {
        model.screen == .tasks && model.task(model.selectedTaskID)?.state == .readyForReview
    }

    public var body: some View {
        HStack(spacing: 0) {
            if !isFocusedReview {
                Sidebar(model: model)
                    .frame(width: Theme.sidebarWidth)
                    .background(Theme.sidebarBackground)
                Rectangle().fill(Theme.divider).frame(width: 1)
            }
            ScreenContent(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.windowBackground)
        .overlay(alignment: .top) { BannerStack(model: model) }
        .ignoresSafeArea()
        .frame(minWidth: MainWindowMetrics.minimumSize.width, minHeight: MainWindowMetrics.minimumSize.height)
        .sheet(item: $model.pendingPreview) { preview in
            ApprovalSheet(model: model, preview: preview)
        }
        .sheet(item: $model.ruleEditor) { context in
            RuleEditorSheet(model: model, context: context)
        }
        .sheet(item: connectSheetBinding) { item in
            ConnectAccountSheet(model: model, kind: item.kind)
        }
        .sheet(isPresented: $model.showsOnboarding) {
            OnboardingView(model: model)
        }
        .alert(
            "Open a link to \(model.pendingLinkConfirmation?.host ?? "another site")?",
            isPresented: linkConfirmationBinding,
            presenting: model.pendingLinkConfirmation
        ) { _ in
            Button("Open in Browser") { model.confirmPendingLink() }
            Button("Cancel", role: .cancel) { model.cancelPendingLink() }
        } message: { pending in
            Text("This link comes from provider data and points outside your connected accounts and known CI services:\n\(pending.url.absoluteString)")
        }
    }

    private var linkConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingLinkConfirmation != nil },
            set: { if !$0 { model.cancelPendingLink() } }
        )
    }

    private var connectSheetBinding: Binding<ConnectSheetItem?> {
        Binding(
            get: { model.connectSheetKind.map(ConnectSheetItem.init) },
            set: { model.connectSheetKind = $0?.kind }
        )
    }
}

/// The current screen, right of the sidebar.
struct ScreenContent: View {
    let model: AppModel

    var body: some View {
        switch model.screen {
        case .inbox:
            InboxScreen(model: model)
        case .changeRequests:
            TwoColumnScreen(listWidth: 380) {
                ChangeRequestList(model: model)
            } detail: {
                ChangeRequestDetail(model: model)
            }
        case .tasks:
            if let record = model.task(model.selectedTaskID) {
                TaskDetailScreen(model: model, record: record)
                    .id(record.id)
            } else {
                TaskList(model: model)
            }
        case .rules:
            TwoColumnScreen(listWidth: 360) {
                RuleList(model: model)
            } detail: {
                RuleDetail(model: model)
            }
        case .settings:
            TwoColumnScreen(listWidth: 250) {
                SettingsList(model: model)
            } detail: {
                SettingsDetail(model: model)
            }
        }
    }
}

/// A list column and a detail column below the invisible title bar.
struct TwoColumnScreen<List: View, Detail: View>: View {
    var listWidth: CGFloat
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            list
                .padding(.top, MainWindowMetrics.contentTopInset - 8)
                .frame(width: listWidth)
                .frame(maxHeight: .infinity)
                .background(Theme.contentBackground)
            Rectangle().fill(Theme.divider).frame(width: 1)
            detail
                .padding(.top, MainWindowMetrics.contentTopInset - 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.windowBackground)
        }
    }
}

/// Transient messages, top centre of the window.
struct BannerStack: View {
    let model: AppModel

    var body: some View {
        if !model.banners.isEmpty {
            VStack(spacing: 6) {
                ForEach(model.banners) { banner in
                    BannerView(banner: banner) { model.dismissBanner(banner.id) }
                }
            }
            .frame(maxWidth: 560)
            .padding(.top, 14)
        }
    }
}

public enum MainWindowColumn: String, Sendable, CaseIterable {
    case sidebar, content, detail
}

struct ConnectSheetItem: Identifiable {
    var kind: ProviderKind
    var id: String { kind.rawValue }
}

/// Placeholder shown when nothing is selected.
struct NothingSelected: View {
    var title: String
    var symbol: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
