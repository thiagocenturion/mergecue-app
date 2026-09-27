import AppKit
import MergeCueCore
import SwiftUI

/// The app shell: builds the `AppModel` from a backend, the menu bar status item + popover and the main window.
///
/// The Xcode app target (and `mergecue-snapshots --app`) only needs:
/// ```swift
/// let delegate = MergeCueAppDelegate(backendFactory: { MergeCuePreview.makeBackend() })
/// NSApplication.shared.delegate = delegate
/// NSApplication.shared.run()
/// ```
public final class MergeCueAppDelegate: NSObject, NSApplicationDelegate {
    private let backendFactory: @MainActor () -> any AppBackend
    public private(set) var model: AppModel?
    private var statusController: StatusItemController?
    private var windowController: MainWindowController?
    /// Opens the main window right after launch (otherwise the app starts in the menu bar only).
    public var showsWindowOnLaunch = false

    public init(backendFactory: @escaping @MainActor () -> any AppBackend) {
        self.backendFactory = backendFactory
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Bundle.main.bundleURL.pathExtension != "app", let icon = AppIconImage.image {
            NSApp.applicationIconImage = icon
        }
        let model = AppModel(backend: backendFactory())
        self.model = model

        let windowController = MainWindowController(model: model)
        self.windowController = windowController
        model.openMainWindowHandler = { [weak windowController] in windowController?.show() }

        let statusController = StatusItemController(model: model, actions: StatusMenuActions(
            openMainWindow: { [weak model] in model?.showScreen(model?.screen ?? .inbox) },
            openSettings: { [weak model] in model?.showSettings() },
            quit: { NSApp.terminate(nil) }
        ))
        self.statusController = statusController
        model.closePopoverHandler = { [weak statusController] in statusController?.closePopover() }

        NSApp.mainMenu = MainMenuBuilder.makeMenu(model: model)
        Task { await model.start() }
        if showsWindowOnLaunch { model.showScreen(.inbox) }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.showScreen(model?.screen ?? .inbox)
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    /// Opens the main window (e.g. from a notification or URL handler).
    public func showMainWindow() {
        model?.showScreen(model?.screen ?? .inbox)
    }
}

/// The main menu: app menu, Edit (text editing in fields), View (⌘1–⌘5, ⌘R) and Window.
enum MainMenuBuilder {
    static func makeMenu(model: AppModel) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MergeCue")
        appMenu.addItem(MenuItemFactory.item(title: "About MergeCue") { model.showSettings(.about) })
        appMenu.addItem(.separator())
        appMenu.addItem(MenuItemFactory.item(title: "Settings…", key: ",") { model.showSettings() })
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide MergeCue", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit MergeCue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        for screen in MainScreen.allCases {
            view.addItem(MenuItemFactory.item(title: screen.title, key: String(screen.shortcutDigit)) { model.showScreen(screen) })
        }
        view.addItem(.separator())
        view.addItem(MenuItemFactory.item(title: "Refresh", key: "r") { Task { await model.refresh() } })
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }
}
