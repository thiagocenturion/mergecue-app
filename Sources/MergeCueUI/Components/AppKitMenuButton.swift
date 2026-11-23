import AppKit
import SwiftUI

/// One entry of an `AppKitMenuButton` menu.
enum AppKitMenuEntry {
    case action(String, () -> Void)
    case divider
}

/// An icon button that shows an AppKit `NSMenu` under itself (D52).
///
/// Used instead of SwiftUI `Menu` in the menu bar popover: there, the first click also activates the app and moves
/// keyboard focus, and the re-render that follows closed a SwiftUI menu about half a second after it opened. An
/// `NSMenu` runs its own tracking loop, so updates to the view tree can't take it down.
struct AppKitMenuButton<Label: View>: View {
    /// Built when the button is clicked, so the menu reflects the current state.
    let entries: () -> [AppKitMenuEntry]
    @ViewBuilder let label: () -> Label

    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.show(entries())
        } label: {
            label()
        }
        .buttonStyle(IconButtonStyle(size: 30, filled: false))
        .background(MenuAnchorView(anchor: anchor).allowsHitTesting(false))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows a menu")
    }
}

/// Holds the AppKit view the menu is positioned against.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?

    func show(_ entries: [AppKitMenuEntry]) {
        guard let view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .action(let title, let handler): menu.addItem(MenuItemFactory.item(title: title, handler: handler))
            case .divider: menu.addItem(.separator())
            }
        }
        // Make sure the popover is the key window of an active app before tracking starts.
        if !NSApp.isActive { NSApp.activate() }
        view.window?.makeKey()
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
