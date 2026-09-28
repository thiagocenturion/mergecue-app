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
// Window scenes render the sidebar, list and detail columns as separate root hosting views side by side: on macOS 26
// the NavigationSplitView's glass sidebar and nested SwiftUI scroll content don't draw into cacheDisplay bitmaps.
// The running app uses the same column views inside MainWindowView's NavigationSplitView.

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

// MARK: - Snapshot rendering

enum SceneKind {
    /// A single view sized to fit (popover, sheets).
    case view((AppModel) -> AnyView)
    /// The main window, composed from its sidebar, list and detail columns.
    case window
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
let windowSize = NSSize(width: 1_320, height: 860)
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

let scenes: [Scene] = [
    Scene(name: "popover", kind: popover),
    Scene(name: "popover-keyboard-selection", configure: { model in
        model.movePopoverSelection(by: 1)
        model.movePopoverSelection(by: 1)
    }, kind: popover),
    Scene(name: "popover-after-fix-with-ai", configure: { model in
        if let waiting = model.state.tasks.first(where: { $0.task.state == .waitingForAgent }) {
            model.handoffOffer = HandoffOffer(taskID: waiting.id)
        }
        model.showBanner(.success, "Command copied — paste it into Claude Code. The task stays “Waiting for agent” until the agent claims it.")
    }, kind: popover),
    Scene(name: "popover-empty", variant: .allCaughtUp, kind: popover),
    Scene(name: "popover-error", variant: .authExpired, kind: popover),
    Scene(name: "popover-onboarding", variant: .noAccounts, kind: popover),
    Scene(name: "window-inbox", size: windowSize, configure: { model in
        model.screen = .inbox
        model.selectedAttentionID = model.state.attention.first {
            $0.providerKind == .github && $0.number == 42 && $0.reason == .changesRequested
        }?.id
    }, kind: window),
    Scene(name: "window-inbox-ci", size: windowSize, configure: { model in
        model.screen = .inbox
        model.inboxFilter.provider = .gitlab
        model.selectedAttentionID = model.state.attention.first { $0.providerKind == .gitlab && $0.reason == .ciFailed }?.id
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
    Scene(name: "window-task-ready", size: windowSize, configure: { model in
        model.screen = .tasks
        model.selectedTaskID = model.state.tasks.first { $0.task.state == .readyForReview }?.id
    }, kind: window),
    Scene(name: "window-task-working", size: windowSize, configure: { model in
        model.screen = .tasks
        model.selectedTaskID = model.state.tasks.first { $0.task.state == .working }?.id
    }, kind: window),
    Scene(name: "window-task-waiting", size: windowSize, configure: { model in
        model.screen = .tasks
        model.selectedTaskID = model.state.tasks.first { $0.task.state == .waitingForAgent }?.id
    }, kind: window),
    Scene(name: "window-task-blocked", size: windowSize, configure: { model in
        model.screen = .tasks
        model.selectedTaskID = model.state.tasks.first { $0.task.state == .blocked }?.id
    }, kind: window),
    Scene(name: "window-rules", size: windowSize, configure: { model in
        model.screen = .rules
        model.selectedRuleID = model.state.rules.first { $0.origin == .agentProposal }?.id
    }, kind: window),
    Scene(name: "window-settings-accounts", variant: .authExpired, size: windowSize, configure: { model in
        model.screen = .settings
        model.settingsTab = .accounts
    }, kind: window),
    Scene(name: "window-settings-about", size: windowSize, configure: { model in
        model.screen = .settings
        model.settingsTab = .about
    }, kind: window),
    Scene(name: "sheet-approve-reply-blocked", kind: .view { model in
        AnyView(MergeCuePreview.approvalSheet(model: model, preview: samplePreview(model, .postReply))
            .background(Color(nsColor: .windowBackgroundColor)))
    }),
    Scene(name: "sheet-approve-patch", kind: .view { model in
        AnyView(MergeCuePreview.approvalSheet(model: model, preview: samplePreview(model, .applyPatch))
            .background(Color(nsColor: .windowBackgroundColor)))
    }),
    Scene(name: "sheet-connect-gitlab", kind: .view { model in
        AnyView(MergeCuePreview.connectAccountSheet(model: model, kind: .gitlab).background(Color(nsColor: .windowBackgroundColor)))
    }),
]

/// Offscreen window that reports itself key, so controls render in their active (accent) appearance.
final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// Paints the column backgrounds and separators behind the composed window columns.
final class ColumnCanvas: NSView {
    var sidebarWidth: CGFloat = 0
    var listWidth: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height).fill()
        NSColor.controlBackgroundColor.setFill()
        NSRect(x: sidebarWidth, y: 0, width: listWidth, height: bounds.height).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: sidebarWidth - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: sidebarWidth + listWidth - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

func makeWindow(size: NSSize, appearance: NSAppearance.Name) -> NSWindow {
    let window = SnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                                styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.backgroundColor = .windowBackgroundColor
    window.isReleasedWhenClosed = false
    return window
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
    let window = makeWindow(size: size ?? NSSize(width: 380, height: 600), appearance: appearance)
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

/// Composes the main window's three columns as separate root hosting views and writes the PNG.
func renderWindow(model: AppModel, size: NSSize, appearance: NSAppearance.Name, to url: URL) -> Bool {
    let sidebarWidth: CGFloat = 220
    let listWidth: CGFloat = 380
    let canvas = ColumnCanvas(frame: NSRect(origin: .zero, size: size))
    canvas.sidebarWidth = sidebarWidth
    canvas.listWidth = listWidth
    let frames: [(MainWindowColumn, NSRect)] = [
        (.sidebar, NSRect(x: 0, y: 0, width: sidebarWidth - 1, height: size.height)),
        (.content, NSRect(x: sidebarWidth, y: 0, width: listWidth - 1, height: size.height)),
        (.detail, NSRect(x: sidebarWidth + listWidth, y: 0, width: size.width - sidebarWidth - listWidth, height: size.height)),
    ]
    for (column, frame) in frames {
        let hosting = NSHostingView(rootView: MainWindowColumnView(model: model, column: column).environment(\.controlActiveState, .key))
        hosting.frame = frame
        hosting.autoresizingMask = [.height]
        canvas.addSubview(hosting)
    }
    let window = makeWindow(size: size, appearance: appearance)
    window.contentView = canvas
    window.orderFrontRegardless()
    settle(0.8)
    defer { window.orderOut(nil) }
    return writePNG(of: canvas, to: url)
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
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        let model = MergeCuePreview.makeModel(variant: scene.variant, now: now)
        scene.configure(model)
        let url = outputDirectory.appending(path: "\(scene.name)-\(suffix).png")
        let ok = switch scene.kind {
        case .view(let make): renderView(make(model), size: scene.size, appearance: appearance, to: url)
        case .window: renderWindow(model: model, size: scene.size ?? windowSize, appearance: appearance, to: url)
        }
        if ok {
            written.append(url.lastPathComponent)
        }
    }
}
print("mergecue-snapshots: wrote \(written.count) PNGs to \(outputDirectory.path(percentEncoded: false))")
for name in written { print("  \(name)") }
