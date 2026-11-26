import MergeCueCore
import SwiftUI

/// The main window: the sidebar (logo, navigation, connected accounts, sync footer) and the current screen.
/// Laid out edge to edge under a transparent title bar; the sidebar reserves room for the traffic lights.
public struct MainWindowView: View {
    @Bindable var model: AppModel
    /// Icon-only sidebar below `MainWindowMetrics.compactSidebarThreshold`.
    /// The window is too narrow for the full sidebar.
    @State private var narrowWindow = false
    /// Icon-only sidebar: chosen with the title bar toggle (D48), or forced by a narrow window.
    private var compactSidebar: Bool { model.sidebarCollapsed || narrowWindow }

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
                // A floating glass sidebar (D43): inset from the window edges, the glow running underneath.
                Sidebar(model: model, compact: compactSidebar)
                    .frame(width: compactSidebar ? Theme.compactSidebarWidth : Theme.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .glassCard()
                    // The panel floats below the traffic lights and the sidebar toggle, never under them (D48).
                    .padding(.top, MainWindowMetrics.titlebarInset)
                    .padding([.leading, .bottom, .trailing], Sidebar.floatingInset)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ScreenContent(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Motion.smooth, value: isFocusedReview)
        .animation(Motion.smooth, value: compactSidebar)
        // One glow for the whole window, so navigating keeps the loop running instead of restarting it.
        .auroraBackdrop(height: 560)
        .background(Theme.windowBackground)
        .overlay(alignment: .top) { BannerStack(model: model) }
        .ignoresSafeArea()
        .frame(minWidth: MainWindowMetrics.minimumSize.width, minHeight: MainWindowMetrics.minimumSize.height)
        .onGeometryChange(for: Bool.self) { $0.size.width < MainWindowMetrics.compactSidebarThreshold } action: { narrowWindow = $0 }
        .sheet(item: $model.pendingPreview) { preview in
            ApprovalSheet(model: model, preview: preview)
                .dynamicTypeSize(model.textSize.dynamicTypeSize)
                .environment(\.avatarImages, model.avatarImages)
        }
        .sheet(item: $model.ruleEditor) { context in
            RuleEditorSheet(model: model, context: context)
                .dynamicTypeSize(model.textSize.dynamicTypeSize)
                .environment(\.avatarImages, model.avatarImages)
        }
        .sheet(item: connectSheetBinding) { item in
            ConnectAccountSheet(model: model, kind: item.kind)
                .dynamicTypeSize(model.textSize.dynamicTypeSize)
                .environment(\.avatarImages, model.avatarImages)
        }
        .sheet(isPresented: $model.showsOnboarding) {
            OnboardingView(model: model)
                .dynamicTypeSize(model.textSize.dynamicTypeSize)
                .environment(\.avatarImages, model.avatarImages)
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
        .dynamicTypeSize(model.textSize.dynamicTypeSize)
        .environment(\.avatarImages, model.avatarImages)
        .defaultGlassButtons()
        // Palette colours resolve the dark style when drawn; a new identity redraws everything after a change.
        .id(model.darkStyle)
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
        let key = "\(model.screen)|\(model.selectedTaskID?.rawValue ?? "")"
        ZStack {
            screen
                .id(key)
                .transition(Motion.screenTransition)
        }
        .animation(Motion.smooth, value: key)
    }

    @ViewBuilder
    private var screen: some View {
        switch model.screen {
        case .inbox:
            InboxScreen(model: model)
        case .reviews:
            TwoColumnScreen(model: model, key: "reviews", listWidth: 400, minListWidth: 380) {
                ReviewList(model: model)
            } detail: {
                ChangeRequestDetail(model: model)
            }
        case .changeRequests:
            TwoColumnScreen(model: model, key: "pullRequests", listWidth: 380, minListWidth: 380) {
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
            TwoColumnScreen(model: model, key: "rules", listWidth: 360, minListWidth: 300) {
                RuleList(model: model)
            } detail: {
                RuleDetail(model: model)
            }
        case .settings:
            TwoColumnScreen(model: model, key: "settings", listWidth: 250, minListWidth: 230) {
                SettingsList(model: model)
            } detail: {
                SettingsDetail(model: model)
            }
        }
    }
}

/// A list column and a detail column below the invisible title bar.
struct TwoColumnScreen<List: View, Detail: View>: View {
    let model: AppModel
    /// Saves the dragged list width per screen.
    var key: String
    /// Default list width.
    var listWidth: CGFloat
    /// The narrowest the list content fits in (its filters and rows); dragging stops there.
    var minListWidth: CGFloat
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail
    /// The width while the split line is being dragged (saved when the drag ends).
    @State private var dragWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            // The list keeps what its content needs; the detail keeps 440 pt (D49, D50).
            let range = minListWidth...max(minListWidth, min(720, proxy.size.width - 440))
            let width = min(max(dragWidth ?? model.splitWidth(key) ?? listWidth, range.lowerBound), range.upperBound)
            HStack(spacing: 0) {
                list
                    .padding(.top, MainWindowMetrics.contentTopInset - 8)
                    // Anchored left: content wider than the pane never spills over the sidebar.
                    .frame(width: width, alignment: .leading)
                    .frame(maxHeight: .infinity)
                SplitDivider(
                    width: Binding(get: { width }, set: { dragWidth = $0 }), range: range, controlsLeadingPane: true,
                    onReset: { model.setSplitWidth(key, nil) },
                    onCommit: {
                        if let dragWidth { model.setSplitWidth(key, dragWidth) }
                        dragWidth = nil
                    }
                )
                detail
                    .padding(.top, MainWindowMetrics.contentTopInset - 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
                    BannerView(banner: banner, onHold: { model.setBannerHeld(banner.id, $0) }) { model.dismissBanner(banner.id) }
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
                .scaledFont(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(title)
                .scaledFont(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .scaledFont(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
