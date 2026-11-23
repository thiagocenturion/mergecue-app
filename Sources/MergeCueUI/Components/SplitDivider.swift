import AppKit
import SwiftUI

/// A draggable split line between two columns (D49): hover shows the left/right resize cursor and a highlighted
/// grabber; dragging resizes the controlled pane within `range`; double-click restores the default width.
struct SplitDivider: View {
    /// Width of the controlled pane.
    @Binding var width: CGFloat
    var range: ClosedRange<CGFloat>
    /// True when the controlled pane is left of the line (dragging right grows it), false when it is on the right.
    var controlsLeadingPane: Bool
    var onReset: () -> Void
    var onCommit: () -> Void

    @State private var isHovering = false
    @State private var dragStart: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = isHovering || dragStart != nil
        ZStack {
            Rectangle().fill(Color.clear)
            Capsule()
                .fill(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.divider))
                .frame(width: active ? 3 : 1)
                .frame(maxHeight: active ? 72 : .infinity)
                .padding(.vertical, active ? 0 : 24)
                .shadow(color: Theme.accent.opacity(active ? 0.45 : 0), radius: 6)
                .animation(reduceMotion ? nil : Motion.hover, value: active)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear { if isHovering { NSCursor.pop() } }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? width
                    if dragStart == nil { dragStart = start }
                    let delta = controlsLeadingPane ? value.translation.width : -value.translation.width
                    width = min(max(start + delta, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in
                    dragStart = nil
                    onCommit()
                }
        )
        .onTapGesture(count: 2) { withAnimation(Motion.smooth) { onReset() } }
        .help("Drag to resize. Double-click to restore.")
        .accessibilityElement()
        .accessibilityLabel("Column divider")
        .accessibilityValue("\(Int(width)) points")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = controlsLeadingPane ? 20 : -20
            switch direction {
            case .increment: width = min(max(width + step, range.lowerBound), range.upperBound)
            case .decrement: width = min(max(width - step, range.lowerBound), range.upperBound)
            @unknown default: break
            }
            onCommit()
        }
    }
}

extension AppModel {
    /// The saved width of a split pane (`key` per screen), nil for the default.
    public func splitWidth(_ key: String) -> CGFloat? {
        splitWidths[key].map { CGFloat($0) }
    }

    public func setSplitWidth(_ key: String, _ width: CGFloat?) {
        splitWidths[key] = width.map(Double.init)
    }
}
