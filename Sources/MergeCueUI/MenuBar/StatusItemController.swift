import AppKit
import MergeCueCore
import Observation
import SwiftUI

/// Actions of the status item's context menu.
struct StatusMenuActions {
    var openMainWindow: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
}

/// Owns the `NSStatusItem` (appearance-aware MergeCue glyph + compact "Needs you" count) and the click-opened `NSPopover`.
/// Left click toggles the popover; right-click or control-click shows the menu. The global shortcut (Settings ›
/// General › Keyboard) toggles the popover from any app, and VoiceOver users reach the menu and Quit through the
/// status item's custom actions (the popover's gear menu has Quit too).
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let actions: StatusMenuActions
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var currentIconShowsDot = false
    private var appearanceObservation: NSKeyValueObservation?
    /// Light/dark of the last icon drawn for an appearance change, and whether a check is already queued.
    private var lastIconIsDark: Bool?
    private var appearanceCheckPending = false
    private var hotKey: GlobalHotKey?

    init(model: AppModel, actions: StatusMenuActions) {
        self.model = model
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let hosting = NSHostingController(rootView: PopoverView(model: model) { [weak self] in self?.closePopover() })
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        statusItem.autosaveName = "MergeCueStatusItem"
        if #available(macOS 14.0, *) { popover.hasFullSizeContent = true }
        // The icon is not a template: redraw it when the menu bar switches between light and dark. AppKit sets the
        // button's appearance again on every redraw of the status item, so redrawing on each notification never stops
        // (a full CPU core, D55): redraw only when light/dark really changed, once per burst.
        lastIconIsDark = statusItem.button.map { MenuBarIcon.isDark($0.effectiveAppearance) }
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheduleAppearanceCheck() }
        }
        statusItem.button?.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Show menu") { [weak self] in
                self?.showMenu()
                return true
            },
            NSAccessibilityCustomAction(name: "Quit MergeCue") { [actions] in
                actions.quit()
                return true
            },
        ])
        hotKey = GlobalHotKey { [weak self] in self?.toggleFromKeyboard() }
        observeModel()
        observeHotKey()
    }

    // MARK: Global shortcut

    private func observeHotKey() {
        let preset = withObservationTracking {
            model.globalHotKey
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeHotKey() }
        }
        if hotKey?.registered != preset, hotKey?.register(preset) == false {
            model.showBanner(.attention, "\(preset.displayName) is used by another app. Choose another shortcut in Settings › General.")
        }
    }

    private func toggleFromKeyboard() {
        popover.isShown ? closePopover() : showPopover(fromKeyboard: true)
    }

    // MARK: Appearance

    private func scheduleAppearanceCheck() {
        guard !appearanceCheckPending else { return }
        appearanceCheckPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.checkAppearance()
        }
    }

    private func checkAppearance() {
        appearanceCheckPending = false
        guard let button = statusItem.button else { return }
        let isDark = MenuBarIcon.isDark(button.effectiveAppearance)
        guard isDark != lastIconIsDark else { return }
        lastIconIsDark = isDark
        button.needsDisplay = true
    }

    // MARK: Button content

    private func observeModel() {
        withObservationTracking {
            updateButton()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let count = model.needsYouCount
        let showsDot = count > 0 || model.sections.count(.ready) > 0
        if showsDot != currentIconShowsDot || button.image == nil {
            button.image = MenuBarIcon.image(showsDot: showsDot)
            currentIconShowsDot = showsDot
        }
        // Every set redraws the status item, and this runs on each state change: set only what changed.
        let title = count > 0 && model.showCountInMenuBar ? "\(count)" : ""
        if button.title != title {
            if title.isEmpty {
                button.title = ""
            } else {
                button.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium),
                    .baselineOffset: 0.5,
                ])
            }
        }
        let toolTip = model.menuBarToolTip
        if button.toolTip != toolTip { button.toolTip = toolTip }
        let label = model.menuBarAccessibilityLabel
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        let shortcut = model.globalHotKey == .off ? "" : " Shortcut: \(model.globalHotKey.spokenName)."
        button.setAccessibilityHelp("Click to show what needs you. Control-click, or use the Show menu action, for more options.\(shortcut)")
    }

    // MARK: Clicks

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        popover.isShown ? closePopover() : showPopover()
    }

    func showPopover(fromKeyboard: Bool = false) {
        guard let button = statusItem.button else { return }
        model.popoverWillShow(fromKeyboard: fromKeyboard)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverSelection = nil
    }

    // MARK: Menu

    private func showMenu() {
        closePopover()
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if let badge = model.mode.badgeText {
            let item = NSMenuItem(title: "\(badge) (not live)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }
        menu.addItem(MenuItemFactory.item(title: "Open MergeCue", key: "o") { [actions] in actions.openMainWindow() })
        menu.addItem(MenuItemFactory.item(title: "Refresh", key: "r") { [model] in Task { await model.refresh() } })

        let pause = NSMenuItem(title: "Pause Notifications", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(MenuItemFactory.item(title: "For 1 Hour") { [model] in
            Task { await model.send(.pauseNotifications(until: model.now.addingTimeInterval(3_600))) }
        })
        submenu.addItem(MenuItemFactory.item(title: "Until Tomorrow") { [model] in
            Task { await model.send(.pauseNotifications(until: PauseOptions.tomorrowMorning(after: model.now))) }
        })
        submenu.addItem(.separator())
        let resume = MenuItemFactory.item(title: "Resume") { [model] in Task { await model.send(.pauseNotifications(until: nil)) } }
        resume.isEnabled = model.notificationsPaused
        submenu.addItem(resume)
        submenu.autoenablesItems = false
        pause.submenu = submenu
        menu.addItem(pause)
        menu.addItem(makeAutoSyncItem())

        menu.addItem(.separator())
        menu.addItem(MenuItemFactory.item(title: "Settings…", key: ",") { [actions] in actions.openSettings() })
        menu.addItem(.separator())
        menu.addItem(MenuItemFactory.item(title: "Quit MergeCue", key: "q") { [actions] in actions.quit() })
        menu.autoenablesItems = false
        return menu
    }

    /// "Pause Auto-Sync" (or "Auto-Sync Paused" while paused): timed pauses, resume, "sync anyway" during a
    /// scheduled pause, and the way to the schedule rules.
    private func makeAutoSyncItem() -> NSMenuItem {
        let now = model.now
        let pauseState = model.autoSyncPause
        let item = NSMenuItem(title: pauseState == nil ? "Pause Auto-Sync" : "Auto-Sync Paused", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if let pauseState {
            let status = NSMenuItem(title: AutoSyncText.status(pauseState, now: now), action: nil, keyEquivalent: "")
            status.isEnabled = false
            submenu.addItem(status)
            if pauseState.reason == .manual {
                submenu.addItem(MenuItemFactory.item(title: "Resume Auto-Sync") { [model] in
                    Task { await model.pauseAutoSync(until: nil) }
                })
            } else {
                let title = pauseState.until.map { "Sync Anyway Until \(AutoSyncText.moment($0, now: now))" } ?? "Sync Anyway"
                submenu.addItem(MenuItemFactory.item(title: title) { [model] in
                    Task { await model.syncAnywayUntil(pauseState.until) }
                })
            }
            submenu.addItem(.separator())
        }
        submenu.addItem(MenuItemFactory.item(title: "For 1 Hour") { [model] in
            Task { await model.pauseAutoSync(until: model.now.addingTimeInterval(3_600)) }
        })
        submenu.addItem(MenuItemFactory.item(title: "Until Tomorrow 9:00") { [model] in
            Task { await model.pauseAutoSync(until: AutoSyncText.tomorrowMorning(after: model.now)) }
        })
        submenu.addItem(MenuItemFactory.item(title: "Until Monday 9:00") { [model] in
            Task { await model.pauseAutoSync(until: AutoSyncText.nextMondayMorning(after: model.now)) }
        })
        submenu.addItem(MenuItemFactory.item(title: "Until I Resume") { [model] in
            Task { await model.pauseAutoSync(until: .distantFuture) }
        })
        submenu.addItem(.separator())
        submenu.addItem(MenuItemFactory.item(title: "Pause Schedule…") { [actions] in actions.openSettings() })
        let hint = NSMenuItem(title: "Refresh always checks now", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        submenu.addItem(hint)
        submenu.autoenablesItems = false
        item.submenu = submenu
        return item
    }
}

/// Builds `NSMenuItem`s that run a closure (the target is retained through `representedObject`).
enum MenuItemFactory {
    static func item(title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuActionTarget(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.run), keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        item.representedObject = target
        return item
    }
}

final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

/// Menu bar icon: the owner's glyphs in `Resources/` (`MenuBar-light*` for a dark menu bar, `MenuBar-dark*` for a
/// light one; `-dot` variants carry the mint signal dot). They are coloured, so not template images: one dynamic
/// `NSImage` picks the variant from the appearance it is drawn in (the status button's effective appearance), and
/// is redrawn whenever that appearance changes.
public enum MenuBarIcon {
    public static let pointSize = NSSize(width: 18, height: 18)

    /// - Parameter showsDot: true when anything needs the user or is ready for review.
    public static func image(showsDot: Bool) -> NSImage {
        let suffix = showsDot ? "-dot" : ""
        let forDarkBar = load("MenuBar-light" + suffix)
        let forLightBar = load("MenuBar-dark" + suffix)
        guard forDarkBar != nil || forLightBar != nil else { return fallback(showsDot: showsDot) }
        let image = NSImage(size: pointSize, flipped: false) { rect in
            let variant = isDark(NSAppearance.currentDrawing()) ? (forDarkBar ?? forLightBar) : (forLightBar ?? forDarkBar)
            variant?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        image.accessibilityDescription = showsDot ? "MergeCue, items need you or are ready" : "MergeCue"
        return image
    }

    /// Whether `appearance` is a dark (menu bar) appearance.
    public static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
    }

    private static func load(_ name: String) -> NSImage? {
        guard let image = Bundle.module.image(forResource: name) else { return nil }
        image.size = pointSize
        return image
    }

    private static func fallback(showsDot: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbol = NSImage(systemSymbolName: showsDot ? "arrow.triangle.pull" : "arrow.triangle.pull", accessibilityDescription: "MergeCue")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        symbol.isTemplate = true
        return symbol
    }
}
