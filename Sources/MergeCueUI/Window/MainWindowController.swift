import AppKit
import SwiftUI

/// Hosts `MainWindowView` in a full-size-content window with a transparent title bar: the sidebar draws under the
/// traffic lights and starts its content below them (`MainWindowMetrics.titlebarInset`). The app is a regular app
/// (Dock icon, menu bar) while this window is open, and an accessory (menu bar only) app otherwise.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private var hasShown = false
    static let autosaveName = "MergeCueMainWindow.v2"

    init(model: AppModel) {
        self.model = model
        let hosting = NSHostingController(rootView: MainWindowView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        MainWindowController.configure(window, badge: model.mode.badgeText)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Window chrome shared by the app and the snapshot tool.
    static func configure(_ window: NSWindow, badge: String?) {
        window.title = "MergeCue"
        if let badge { window.subtitle = badge }
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.backgroundColor = Theme.adaptiveNSColor(light: 0xF3F5FA, dark: 0x0B1020)
        window.setContentSize(MainWindowMetrics.defaultSize)
        window.contentMinSize = MainWindowMetrics.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
    }

    /// Shows the window and switches to a regular app with a Dock icon.
    func show() {
        NSApp.setActivationPolicy(.regular)
        if !hasShown, let window {
            hasShown = true
            // First appearance: the saved frame, else the default size centred on screen (the hosting controller must
            // not shrink the window to the SwiftUI view's fitting size).
            if !window.setFrameUsingName(MainWindowController.autosaveName) {
                window.setContentSize(MainWindowMetrics.defaultSize)
                window.center()
            }
            window.setFrameAutosaveName(MainWindowController.autosaveName)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

public enum MainWindowMetrics {
    public static let defaultSize = NSSize(width: 1_360, height: 860)
    public static let minimumSize = NSSize(width: 1_140, height: 700)
    /// Height reserved at the top of the sidebar for the traffic lights (transparent 28 pt title bar + margin).
    static let titlebarInset: CGFloat = 40
    /// Top padding of the content columns (below the invisible title bar).
    static let contentTopInset: CGFloat = 34

    /// Applies MergeCue's main-window chrome to `window` (used by the snapshot tool to render the real window).
    @MainActor
    public static func configure(_ window: NSWindow, badge: String?) {
        MainWindowController.configure(window, badge: badge)
    }
}
