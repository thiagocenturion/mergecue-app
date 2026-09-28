import AppKit
import SwiftUI

/// Hosts `MainWindowView` in an `NSWindow`. The app is a regular app (Dock icon, menu bar) while this window is
/// open, and an accessory (menu bar only) app otherwise.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let hosting = NSHostingController(rootView: MainWindowView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "MergeCue"
        if let badge = model.mode.badgeText { window.subtitle = badge }
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "MergeCueMainToolbar")
        window.setContentSize(NSSize(width: 1_180, height: 760))
        window.minSize = NSSize(width: 960, height: 580)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("MergeCueMainWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Shows the window and switches to a regular app with a Dock icon.
    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
