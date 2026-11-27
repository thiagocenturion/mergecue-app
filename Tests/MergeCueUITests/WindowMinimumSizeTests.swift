import AppKit
import Foundation
@testable import MergeCueUI
import Testing

@Suite("Main window minimum size (D50)")
@MainActor
struct WindowMinimumSizeTests {
    @Test func theWindowCannotBeSmallerThanTheMinimum() throws {
        let model = AppModel(backend: MergeCuePreview.makeBackend(variant: .standard, now: testNow), environment: .fixed(now: testNow))
        let controller = MainWindowController(model: model)
        let window = try #require(controller.window)
        window.orderFront(nil)
        defer { window.close() }
        let minimum = MainWindowMetrics.minimumSize

        // Shrinking the window (any path) is undone by the content view's required constraints.
        window.setContentSize(NSSize(width: 300, height: 200))
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        let content = window.contentRect(forFrameRect: window.frame).size
        #expect(content.width >= minimum.width, "width \(content.width)")
        #expect(content.height >= minimum.height, "height \(content.height)")

        // A live resize (dragging an edge) asks the delegate; it never goes below the minimum either.
        let proposed = controller.windowWillResize(window, to: NSSize(width: 500, height: 400))
        let clamped = window.contentRect(forFrameRect: NSRect(origin: .zero, size: proposed)).size
        #expect(clamped.width >= minimum.width)
        #expect(clamped.height >= minimum.height)
    }
}
