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

/// Owns the `NSStatusItem` (template glyph + compact "Needs you" count) and the click-opened `NSPopover`.
/// Left click toggles the popover; right-click or control-click shows the menu.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let actions: StatusMenuActions
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

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
        observeModel()
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
        let urgent = model.sections.hasUrgent
        button.image = MenuBarIcon.image(alert: urgent)
        if count > 0 && model.showCountInMenuBar {
            button.attributedTitle = NSAttributedString(string: "\(count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium),
                .baselineOffset: 0.5,
            ])
        } else {
            button.title = ""
        }
        button.toolTip = model.menuBarToolTip
        button.setAccessibilityLabel(model.menuBarAccessibilityLabel)
        button.setAccessibilityHelp("Click to show what needs you. Control-click for more options.")
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

    func showPopover() {
        guard let button = statusItem.button else { return }
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
            let item = NSMenuItem(title: "\(badge) — not live", action: nil, keyEquivalent: "")
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

        menu.addItem(.separator())
        menu.addItem(MenuItemFactory.item(title: "Settings…", key: ",") { [actions] in actions.openSettings() })
        menu.addItem(.separator())
        menu.addItem(MenuItemFactory.item(title: "Quit MergeCue", key: "q") { [actions] in actions.quit() })
        menu.autoenablesItems = false
        return menu
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

/// Menu bar glyphs: the template images shipped in MergeCueUI's resources (`MenuBarIcon`, `MenuBarIconAlert`), or an
/// SF Symbol fallback while those assets are missing.
enum MenuBarIcon {
    static func image(alert: Bool) -> NSImage {
        let name = alert ? "MenuBarIconAlert" : "MenuBarIcon"
        if let image = Bundle.module.image(forResource: name) ?? (alert ? Bundle.module.image(forResource: "MenuBarIcon") : nil) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            image.accessibilityDescription = "MergeCue"
            return image
        }
        return fallback(alert: alert)
    }

    private static func fallback(alert: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbol = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "MergeCue")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        guard alert else {
            symbol.isTemplate = true
            return symbol
        }
        // Same glyph with a small dot, still a template image (no color in the menu bar).
        let size = NSSize(width: max(symbol.size.width, 16) + 3, height: max(symbol.size.height, 16))
        let badged = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: NSRect(x: 0, y: (rect.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width - 6.5, y: rect.height - 6.5, width: 6.5, height: 6.5)).fill()
            return true
        }
        badged.isTemplate = true
        badged.accessibilityDescription = "MergeCue, urgent items"
        return badged
    }
}
