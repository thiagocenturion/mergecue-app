import AppKit
import MergeCueCore
import MergeCueRuntime
import SwiftUI
import Synchronization
import UserNotifications

/// Keys of the app's own preferences (UserDefaults).
public nonisolated enum LaunchPreferences {
    /// "live" or "demo": the mode chosen with Settings › General › Demo mode (launch arguments and
    /// `MERGECUE_BACKEND` take precedence).
    public static let backendModeKey = "MergeCueBackendMode"
    /// Set once the owner finished or closed the setup assistant.
    public static let onboardingCompletedKey = "MergeCueOnboardingCompleted.v1"
}

/// The app shell: builds the backend (async: the engine runtime starts its IPC server), the `AppModel`, the menu
/// bar status item + popover and the main window; forwards wake-ups, notification clicks and quitting to the backend.
///
/// ```swift
/// let delegate = MergeCueAppDelegate(asyncBackendFactory: { try await EngineBackend.launch(mode: .live, appVersion: "1.0") })
/// NSApplication.shared.delegate = delegate
/// NSApplication.shared.run()
/// ```
public final class MergeCueAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    public typealias BackendFactory = @MainActor () async throws -> any AppBackend

    private let backendFactory: BackendFactory
    public private(set) var model: AppModel?
    public private(set) var backend: (any AppBackend)?
    private var statusController: StatusItemController?
    private var windowController: MainWindowController?
    private var wakeObserver: NSObjectProtocol?
    private var pendingNotification: (changeRequestID: String?, attentionIDs: [String])?
    private var isTerminating = false
    private var backendStopped = false
    /// SIGTERM/SIGINT (`kill`, `pkill`, logout scripts) quit through `applicationShouldTerminate`, so the runtime
    /// stops and removes its IPC socket instead of leaving it behind.
    private var signalSources: [DispatchSourceSignal] = []
    /// Opens the main window right after launch (otherwise the app starts in the menu bar only).
    public var showsWindowOnLaunch = false
    /// Offer the setup assistant on the first live launch without accounts.
    public var offersOnboarding = true
    /// Arguments for relaunching into another mode (Settings › General › Demo mode). Nil disables switching.
    public var relaunchArguments: ((BackendMode) -> [String])? = { mode in ["--\(mode.rawValue)", "--show-window"] }

    /// A synchronous backend (preview, snapshots).
    public convenience init(backendFactory: @escaping @MainActor () -> any AppBackend) {
        self.init(asyncBackendFactory: { backendFactory() })
    }

    public init(asyncBackendFactory: @escaping BackendFactory) {
        self.backendFactory = asyncBackendFactory
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Bundle.main.bundleURL.pathExtension != "app", let icon = AppIconImage.image {
            NSApp.applicationIconImage = icon
        }
        if UserNotificationDeliverer.isAvailable {
            // Set before launch finishes so a click that launched the app is delivered too.
            UNUserNotificationCenter.current().delegate = self
        }
        installTerminationSignalHandlers()
        Task { await launch() }
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MCLog(category: "ui").notice("signal \(signalNumber) received; quitting")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func launch() async {
        let backend: any AppBackend
        do {
            backend = try await backendFactory()
        } catch {
            presentLaunchError(error)
            return
        }
        self.backend = backend
        let model = AppModel(backend: backend)
        self.model = model

        let windowController = MainWindowController(model: model)
        self.windowController = windowController
        model.openMainWindowHandler = { [weak windowController] in windowController?.show() }
        model.onboardingCompletedHandler = { UserDefaults.standard.set(true, forKey: LaunchPreferences.onboardingCompletedKey) }
        if relaunchArguments != nil, backend.mode != .preview {
            model.switchModeHandler = { [weak self] mode in self?.relaunch(into: mode) }
        }

        let statusController = StatusItemController(model: model, actions: StatusMenuActions(
            openMainWindow: { [weak model] in model?.showScreen(model?.screen ?? .inbox) },
            openSettings: { [weak model] in model?.showSettings() },
            quit: { NSApp.terminate(nil) }
        ))
        self.statusController = statusController
        model.closePopoverHandler = { [weak statusController] in statusController?.closePopover() }
        NSApp.mainMenu = MainMenuBuilder.makeMenu(model: model)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { await backend.handleSystemWake() }
        }

        await model.start()
        let needsOnboarding = offersOnboarding && backend.mode == .live && model.state.accounts.isEmpty
            && !UserDefaults.standard.bool(forKey: LaunchPreferences.onboardingCompletedKey)
        if needsOnboarding {
            model.showOnboarding()
        } else if showsWindowOnLaunch {
            model.showScreen(.inbox)
        }
        if let pending = pendingNotification {
            pendingNotification = nil
            model.openNotification(changeRequestID: pending.changeRequestID, attentionIDs: pending.attentionIDs)
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.showScreen(model?.screen ?? .inbox)
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Stops the backend (IPC socket removed) before quitting, bounded so quitting never hangs. The first request
    /// is cancelled, the backend stops outside AppKit's termination loop, then the app terminates for real.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let backend, !backendStopped else { return .terminateNow }
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        model?.stop()
        let log = MCLog(category: "ui")
        log.notice("quitting: stopping the backend")
        Task {
            await Self.shutdown(backend, timeout: .seconds(5))
            log.notice("backend stopped; terminating")
            self.backendStopped = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    public func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Opens the main window (e.g. from a notification or URL handler).
    public func showMainWindow() {
        model?.showScreen(model?.screen ?? .inbox)
    }

    /// Waits for `backend.shutdown()` at most `timeout` (a hung stop must not keep the app from quitting).
    private static func shutdown(_ backend: any AppBackend, timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = Mutex(false)
            let finish: @Sendable () -> Void = {
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume() }
            }
            Task.detached {
                await backend.shutdown()
                finish()
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                finish()
            }
        }
    }

    // MARK: Mode switching

    /// Stops this instance's backend, starts a new instance in `mode` and quits.
    private func relaunch(into mode: BackendMode) {
        guard let arguments = relaunchArguments?(mode) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: LaunchPreferences.backendModeKey)
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            model?.showBanner(.attention, "Saved. Relaunch MergeCue with \(arguments.first ?? "") to switch (development build).")
            return
        }
        isTerminating = true
        model?.stop()
        Task {
            if let backend { await Self.shutdown(backend, timeout: .seconds(5)) }
            self.backendStopped = true
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
            do {
                _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
            } catch {
                MCLog(category: "ui").error("Relaunch failed: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: Launch errors

    private func presentLaunchError(_ error: any Error) {
        NSApp.activate()
        let alert = NSAlert()
        if case RuntimeError.alreadyRunning(let socketPath)? = error as? RuntimeError {
            alert.messageText = "MergeCue is already running"
            alert.informativeText = "Another copy of MergeCue is serving the local agent channel (\(socketPath)). Use the MergeCue icon in the menu bar, or quit the other copy and open MergeCue again."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            others.first?.activate()
        } else {
            alert.alertStyle = .critical
            alert.messageText = "MergeCue couldn't start"
            alert.informativeText = SecretRedactor.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
        NSApp.terminate(nil)
    }

    // MARK: Notifications

    /// Notification click → the item (or change request) in the main window, via the deep-link `userInfo`.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let changeRequestID = info[UserNotificationDeliverer.Keys.changeRequestID] as? String
            ?? (info[UserNotificationDeliverer.Keys.deepLink] as? String).flatMap(Self.changeRequestID(fromDeepLink:))
        let attentionIDs = info[UserNotificationDeliverer.Keys.attentionItemIDs] as? [String] ?? []
        await MainActor.run {
            self.openNotification(changeRequestID: changeRequestID, attentionIDs: attentionIDs)
        }
    }

    /// Show banners while MergeCue is frontmost too.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated static func changeRequestID(fromDeepLink link: String) -> String? {
        guard let url = URL(string: link), url.scheme == "mergecue", url.host() == "change-request" else { return nil }
        let id = String(url.path(percentEncoded: false).drop(while: { $0 == "/" }))
        return id.isEmpty ? nil : id
    }

    private func openNotification(changeRequestID: String?, attentionIDs: [String]) {
        guard let model else {
            pendingNotification = (changeRequestID, attentionIDs)
            return
        }
        model.openNotification(changeRequestID: changeRequestID, attentionIDs: attentionIDs)
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
