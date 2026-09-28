// mergecue-snapshots — visual QA for MergeCueUI with synthetic preview data.
//
//   swift run mergecue-snapshots                 Render every screen (light + dark) to docs/evidence/snapshots/
//   swift run mergecue-snapshots --out <dir>     … to another directory
//   swift run mergecue-snapshots --only popover  Render scenes whose name contains "popover"
//   swift run mergecue-snapshots --app [variant] Run the app interactively with preview data
//                                                (variants: standard, authExpired, allCaughtUp, noAccounts)
//
// Everything rendered here is labeled "Preview data"; nothing is fetched from providers.
//
// Window scenes render the real `MainWindowView` at the window size and composite the title bar controls of a titled
// window configured exactly like the app's (full-size content, transparent title bar), so the traffic lights are in
// the picture and any overlap with the sidebar is visible. Scene names starting with 1-4 correspond to the owner's
// mockups in Design/mockups/.

import AppKit
import MergeCueCore
import MergeCueUI
import SwiftUI

let arguments = CommandLine.arguments

func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    let value = arguments[index + 1]
    return value.hasPrefix("--") ? nil : value
}

if arguments.contains("--app") {
    let variant = argument(after: "--app").flatMap(PreviewVariant.init(rawValue:)) ?? .standard
    let app = NSApplication.shared
    let delegate = MergeCueAppDelegate(backendFactory: { MergeCuePreview.makeBackend(variant: variant) })
    delegate.showsWindowOnLaunch = !arguments.contains("--menu-bar-only")
    app.delegate = delegate
    app.run()
    exit(0)
}

// MARK: - Scenes

enum SceneKind {
    /// A single view sized to fit (popover, sheets).
    case view((AppModel) -> AnyView)
    /// The main window.
    case window
    /// The menu bar icon on light and dark menu bar strips.
    case menuBar
}

struct Scene {
    var name: String
    var variant: PreviewVariant = .standard
    var size: NSSize?
    var configure: (AppModel) -> Void = { _ in }
    var kind: SceneKind
}

let now = MergeCuePreview.referenceDate()
let outputDirectory = URL(filePath: argument(after: "--out") ?? "docs/evidence/snapshots", directoryHint: .isDirectory)
let filter = argument(after: "--only")
let windowSize = MainWindowMetrics.defaultSize
let popover = SceneKind.view { AnyView(PopoverView(model: $0)) }
let window = SceneKind.window

/// Mirrors what the preview backend returns for the ready task (the backend is async; scenes render synchronously).
func samplePreview(_ model: AppModel, _ action: RemoteActionKind) -> ActionPreview {
    let ready = model.state.tasks.first { $0.task.state == .readyForReview }
    let taskID = ready?.id ?? TaskID.generate()
    let isPatch = action == .applyPatch
    return ActionPreview(
        id: "pv_snapshot", taskID: taskID, action: action,
        title: isPatch ? "Apply patch to ~/Developer/acme/payments-api-clean" : "Post reply on acme/payments-api #61",
        target: isPatch ? "~/Developer/acme/payments-api-clean · branch feature/network-retry · base c4d5e6f"
                        : "GitHub · mona-dev · thread · Sources/Payments/RetryPolicy.swift:22",
        body: isPatch ? (ready?.artifact(.diff)?.content ?? "") : (ready?.task.proposedReply ?? ""),
        headSHA: ready?.task.trigger.headSHA, fingerprint: "3f9a1c7e5b2d4f60a8c1e3b5d7f9a1c3",
        warnings: [isPatch ? "MergeCue checks for a clean state and conflicts right before applying."
                           : "MergeCue re-checks the thread and head right before posting.",
                   "Preview data: approving records your decision, but nothing is written or posted."],
        canApprove: isPatch,
        blockedReason: isPatch ? nil : "Remote writes are off for GitHub · mona-dev. Turn them on in Settings › Accounts to post or resolve.",
        createdAt: now, isSimulated: true)
}

func showTask(_ state: TaskState) -> (AppModel) -> Void {
    { model in
        model.screen = .tasks
        model.selectedTaskID = model.state.tasks.first { $0.task.state == state }?.id
    }
}

let scenes: [Scene] = [
    // The four mockup screens.
    Scene(name: "1-main-inbox", size: windowSize, configure: { model in
        model.screen = .inbox
        model.selectedAttentionID = model.state.attention.first {
            $0.providerKind == .github && $0.number == 42 && $0.reason == .changesRequested
        }?.id
    }, kind: window),
    Scene(name: "2-menubar-popover", kind: popover),
    Scene(name: "3-agent-handoff", size: windowSize, configure: showTask(.waitingForAgent), kind: window),
    Scene(name: "4-result-review", size: windowSize, configure: showTask(.readyForReview), kind: window),
    Scene(name: "menubar-icon", kind: .menuBar),

    // Other states.
    Scene(name: "popover-keyboard-selection", configure: { model in
        model.movePopoverSelection(by: 1)
        model.movePopoverSelection(by: 1)
    }, kind: popover),
    Scene(name: "popover-after-fix-with-ai", configure: { model in
        if let waiting = model.state.tasks.first(where: { $0.task.state == .waitingForAgent }) {
            model.handoffOffer = HandoffOffer(taskID: waiting.id)
        }
    }, kind: popover),
    Scene(name: "popover-empty", variant: .allCaughtUp, kind: popover),
    Scene(name: "popover-error", variant: .authExpired, kind: popover),
    Scene(name: "popover-onboarding", variant: .noAccounts, kind: popover),
    Scene(name: "window-inbox-ci", size: windowSize, configure: { model in
        model.screen = .inbox
        model.selectedAttentionID = model.state.attention.first { $0.providerKind == .gitlab && $0.reason == .ciFailed }?.id
    }, kind: window),
    Scene(name: "window-inbox-question", size: windowSize, configure: { model in
        model.screen = .inbox
        model.selectedAttentionID = model.state.attention.first { $0.providerKind == .bitbucketCloud && $0.reason == .reviewerQuestion }?.id
    }, kind: window),
    Scene(name: "window-inbox-empty", variant: .allCaughtUp, size: windowSize, configure: { model in
        model.screen = .inbox
    }, kind: window),
    Scene(name: "window-pr-detail", size: windowSize, configure: { model in
        model.screen = .changeRequests
        model.selectedChangeRequestID = model.state.changeRequests.first {
            $0.summary.providerKind == .github && $0.summary.key.number == 42
        }?.id
    }, kind: window),
    Scene(name: "window-prs-account-errors", variant: .authExpired, size: windowSize, configure: { model in
        model.screen = .changeRequests
        model.selectedChangeRequestID = model.state.changeRequests.first {
            $0.summary.providerKind == .bitbucketCloud && $0.summary.key.number == 42
        }?.id
    }, kind: window),
    Scene(name: "window-tasks", size: windowSize, configure: { $0.screen = .tasks }, kind: window),
    Scene(name: "window-task-working", size: windowSize, configure: showTask(.working), kind: window),
    Scene(name: "window-task-blocked", size: windowSize, configure: showTask(.blocked), kind: window),
    Scene(name: "window-task-stale", size: windowSize, configure: showTask(.stale), kind: window),
    Scene(name: "window-task-failed", size: windowSize, configure: showTask(.failed), kind: window),
    Scene(name: "window-review-tests", size: windowSize, configure: { model in
        showTask(.readyForReview)(model)
        model.reviewTab = .tests
    }, kind: window),
    Scene(name: "window-rules", size: windowSize, configure: { model in
        model.screen = .rules
        model.selectedRuleID = model.state.rules.first { $0.origin == .agentProposal }?.id
    }, kind: window),
    Scene(name: "window-settings-accounts", variant: .authExpired, size: windowSize, configure: { model in
        model.screen = .settings
        model.settingsTab = .accounts
    }, kind: window),
    Scene(name: "window-settings-agents", size: windowSize, configure: { model in
        model.screen = .settings
        model.settingsTab = .agents
    }, kind: window),
    Scene(name: "window-settings-about", size: windowSize, configure: { model in
        model.screen = .settings
        model.settingsTab = .about
    }, kind: window),
    Scene(name: "sheet-approve-reply-blocked", kind: .view { model in
        AnyView(MergeCuePreview.approvalSheet(model: model, preview: samplePreview(model, .postReply)))
    }),
    Scene(name: "sheet-approve-patch", kind: .view { model in
        AnyView(MergeCuePreview.approvalSheet(model: model, preview: samplePreview(model, .applyPatch)))
    }),
    Scene(name: "sheet-connect-gitlab", kind: .view { model in
        AnyView(MergeCuePreview.connectAccountSheet(model: model, kind: .gitlab).background(Color(nsColor: .windowBackgroundColor)))
    }),
]

// MARK: - Rendering

/// Offscreen window that reports itself key, so controls render in their active appearance.
final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

func settle(_ seconds: TimeInterval = 0.5) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func writePNG(of view: NSView, to url: URL) -> Bool {
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds
    guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
    view.cacheDisplay(in: bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    do {
        try data.write(to: url)
        return true
    } catch {
        FileHandle.standardError.write(Data("mergecue-snapshots: cannot write \(url.path): \(error)\n".utf8))
        return false
    }
}

/// Hosts a single view (sized to fit unless `size` is given) and writes its PNG.
func renderView(_ view: AnyView, size: NSSize?, appearance: NSAppearance.Name, to url: URL) -> Bool {
    let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
    let window = SnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size ?? NSSize(width: 404, height: 600)),
                                styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    settle(0.25)
    if size == nil {
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.fittingSize)
    }
    settle()
    defer { window.orderOut(nil) }
    return writePNG(of: hosting, to: url)
}

/// Renders `view` into a bitmap through a borderless offscreen window.
func bitmap(of view: AnyView, size: NSSize, appearance: NSAppearance.Name) -> NSBitmapImageRep? {
    let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
    let window = SnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                                styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    settle(1.0)
    defer { window.orderOut(nil) }
    hosting.layoutSubtreeIfNeeded()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    return rep
}

/// The main window. The window content is rendered through a borderless host (a titled window's frame view does not
/// capture root scroll views reliably), then the real title bar controls of an identically configured titled
/// window are composited on top, so the traffic lights sit exactly where the app shows them.
func renderWindow(model: AppModel, size: NSSize, appearance: NSAppearance.Name, to url: URL) -> Bool {
    let titled = SnapshotWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
    MainWindowMetrics.configure(titled, badge: model.mode.badgeText)
    titled.setFrameAutosaveName("")
    titled.appearance = NSAppearance(named: appearance)
    titled.isOpaque = false
    titled.backgroundColor = .clear
    titled.contentView = NSView()
    titled.setContentSize(size)
    titled.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
    titled.orderFrontRegardless()
    settle(0.3)
    defer { titled.orderOut(nil) }
    guard let frameView = titled.contentView?.superview,
          let chrome = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds),
          let content = bitmap(of: AnyView(MainWindowView(model: model)), size: size, appearance: appearance) else { return false }
    frameView.cacheDisplay(in: frameView.bounds, to: chrome)
    guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: content.pixelsWide, pixelsHigh: content.pixelsHigh,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
    output.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
    content.draw(in: NSRect(origin: .zero, size: size))
    // Title bar controls only (the rest of the titled window is empty).
    let buttons = NSRect(x: 0, y: size.height - 32, width: 90, height: 32)
    chrome.draw(in: buttons, from: buttons, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = output.representation(using: .png, properties: [:]) else { return false }
    do {
        try data.write(to: url)
        return true
    } catch {
        return false
    }
}

/// Draws the status item's icon + count like the menu bar does, in the given appearance.
final class MenuBarStrip: NSView {
    var showsDot = false
    var count: Int?

    override func draw(_ dirtyRect: NSRect) {
        let dark = MenuBarIcon.isDark(effectiveAppearance)
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        bounds.fill()
        let image = MenuBarIcon.image(showsDot: showsDot)
        let origin = NSPoint(x: 10, y: (bounds.height - 18) / 2)
        image.draw(in: NSRect(origin: origin, size: MenuBarIcon.pointSize))
        if let count {
            let text = NSAttributedString(string: "\(count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
            text.draw(at: NSPoint(x: origin.x + 21, y: (bounds.height - text.size().height) / 2))
        }
    }
}

/// Both variants (plain / dot) at 1× and 2×, in one strip per appearance.
func renderMenuBar(appearance: NSAppearance.Name, to url: URL) -> Bool {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    container.appearance = NSAppearance(named: appearance)
    let plain = MenuBarStrip(frame: NSRect(x: 0, y: 0, width: 110, height: 24))
    let dot = MenuBarStrip(frame: NSRect(x: 120, y: 0, width: 140, height: 24))
    dot.showsDot = true
    dot.count = 3
    container.addSubview(plain)
    container.addSubview(dot)
    let window = SnapshotWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 260, height: 24), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentView = container
    window.orderFrontRegardless()
    settle(0.2)
    defer { window.orderOut(nil) }
    return writePNG(of: container, to: url)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("mergecue-snapshots: cannot create \(outputDirectory.path): \(error)\n".utf8))
    exit(1)
}

var written: [String] = []
for scene in scenes where filter.map({ scene.name.contains($0) }) ?? true {
    for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
        let model = MergeCuePreview.makeModel(variant: scene.variant, now: now)
        scene.configure(model)
        let url = outputDirectory.appending(path: "\(scene.name)-\(suffix).png")
        let ok = switch scene.kind {
        case .view(let make): renderView(make(model), size: scene.size, appearance: appearance, to: url)
        case .window: renderWindow(model: model, size: scene.size ?? windowSize, appearance: appearance, to: url)
        case .menuBar: renderMenuBar(appearance: appearance, to: url)
        }
        if ok {
            written.append(url.lastPathComponent)
        }
    }
}
print("mergecue-snapshots: wrote \(written.count) PNGs to \(outputDirectory.path(percentEncoded: false))")
for name in written { print("  \(name)") }
