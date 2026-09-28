import SwiftUI

/// Makes a custom list (inbox cards, PR/MR rows, rules) keyboard-operable like a native table: the list takes
/// focus (click a row, or Tab with keyboard navigation on), ↑/↓ move the selection, Return or Space open the
/// selected row, ⌘↩ runs its primary action. The selected row draws the focus indicator (`keyboardSelectionRing`);
/// with no selection the list itself shows a 2 pt ring.
struct KeyboardListModifier: ViewModifier {
    var isFocused: FocusState<Bool>.Binding
    var hasSelection: Bool
    var onMove: (Int) -> Void
    var onOpen: () -> Void
    var onPrimary: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused(isFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) {
                onMove(1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                onMove(-1)
                return .handled
            }
            .onKeyPress(keys: [.return, .space], phases: .down) { press in
                guard hasSelection else { return .ignored }
                if press.key == .return && press.modifiers.contains(.command) {
                    guard let onPrimary else { return .ignored }
                    onPrimary()
                } else if press.modifiers.isEmpty {
                    onOpen()
                } else {
                    return .ignored
                }
                return .handled
            }
            .overlay {
                if isFocused.wrappedValue && !hasSelection {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.focusRing, lineWidth: 2)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Arrow-key selection, Return/Space to open and ⌘↩ for the primary action (see `KeyboardListModifier`).
    func keyboardList(isFocused: FocusState<Bool>.Binding, hasSelection: Bool, onMove: @escaping (Int) -> Void,
                      onOpen: @escaping () -> Void, onPrimary: (() -> Void)? = nil) -> some View {
        modifier(KeyboardListModifier(isFocused: isFocused, hasSelection: hasSelection, onMove: onMove, onOpen: onOpen, onPrimary: onPrimary))
    }

    /// The selected row of a focused keyboard list: a full-opacity 2 pt focus-ring border (≥ 3:1 on every surface).
    func keyboardSelectionRing(_ active: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            if active {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.focusRing, lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
