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
        // The window keeps its own size (no fitting size from SwiftUI); its minimum comes from `pinMinimumSize`.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        MainWindowController.configure(window, badge: model.mode.badgeText)
        super.init(window: window)
        window.delegate = self
        Self.pinMinimumSize(hosting.view)
        installSidebarToggle(in: window)
        observeTitle()
    }

    /// The native "Hide / Show Sidebar" button right of the traffic lights (D48).
    private func installSidebarToggle(in window: NSWindow) {
        let button = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar") ?? NSImage(),
                              target: self, action: #selector(toggleSidebar(_:)))
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "Hide or show the sidebar (⌃⌘S)"
        button.keyEquivalent = "s"
        button.keyEquivalentModifierMask = [.control, .command]
        button.frame = NSRect(x: 0, y: 0, width: 30, height: 28)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: 28))
        button.frame.origin = NSPoint(x: 6, y: 0)
        container.addSubview(button)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        model.toggleSidebar()
    }

    /// Required constraints on the content view: AppKit never lets a window be smaller than what its content view's
    /// required constraints allow, on any resize path (dragging an edge, zoom, scripts, restored frames). The window's
    /// own `contentMinSize` was not enough: with Auto Layout content AppKit takes the minimum from constraints (D50).
    static func pinMinimumSize(_ view: NSView) {
        let minimum = MainWindowMetrics.minimumSize
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum.width),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: minimum.height),
        ])
    }

    /// Grows the window to the minimum content size, keeping its top-left corner.
    static func clampToMinimum(_ window: NSWindow) {
        let content = window.contentRect(forFrameRect: window.frame).size
        let minimum = MainWindowMetrics.minimumSize
        guard content.width < minimum.width || content.height < minimum.height else { return }
        let size = NSSize(width: max(content.width, minimum.width), height: max(content.height, minimum.height))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
    }

    /// Never smaller than the minimum (a restored frame from an older build could be).
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Clamp to the fixed minimum, not `sender.minSize`: Auto Layout can lower that one.
        let minimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: MainWindowMetrics.minimumSize)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    /// Keeps the window's title and subtitle on the current screen (VoiceOver, Mission Control, Window menu).
    private func observeTitle() {
        let title = withObservationTracking {
            model.windowTitle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeTitle() }
        }
        window?.title = title.title
        window?.subtitle = title.subtitle
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
        // No toolbar: the traffic lights stay in the plain title bar and the floating sidebar starts below them (D48).
        window.toolbar = nil
        // The palette colour, so the window behind the content follows the dark style (graphite or midnight).
        window.backgroundColor = Palette.windowBackground.nsColor
        window.setContentSize(MainWindowMetrics.defaultSize)
        window.contentMinSize = MainWindowMetrics.minimumSize
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: MainWindowMetrics.minimumSize)).size
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
            // Naming the autosave restores the saved frame too, so clamp after it: a frame saved by an older build
            // may be below today's minimum, and the content would then be cropped (D48).
            window.setFrameAutosaveName(MainWindowController.autosaveName)
            Self.clampToMinimum(window)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.userDidReturn()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

public enum MainWindowMetrics {
    public static let defaultSize = NSSize(width: 1_360, height: 860)
    /// The smallest window where nothing is cropped: icon sidebar + Inbox column + 440 pt detail, and the sidebar's
    /// navigation and accounts in height (D48). Fits a 13" display.
    public static let minimumSize = NSSize(width: 1_080, height: 700)
    /// Window widths below this use the icon-only sidebar.
    public static let compactSidebarThreshold: CGFloat = 1_140
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
