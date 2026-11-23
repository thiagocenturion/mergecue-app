import AppKit
import MergeCueCore
@testable import MergeCueUI
import SwiftUI
import Testing

/// Renders the change request panel in a window and checks that a focus request really scrolls it (D51).
@Suite("Detail focus scrolls the panel (D51)", .serialized)
@MainActor
struct DetailFocusScrollTests {
    @Test(arguments: [false, true])
    func focusRequestScrollsToTheTargetAndIsConsumed(reviewers: Bool) async throws {
        let model = await makeModel()
        let snapshot = try #require(model.state.changeRequests.first { ConversationGrouping.conversations($0).count >= 3 })
        let lastThread = try #require(ConversationGrouping.conversations(snapshot).last?.first?.key)
        model.selectedChangeRequestID = snapshot.key.id
        model.detailFocusRequest = DetailFocusRequest(changeRequestID: snapshot.key.id,
                                                      target: reviewers ? .reviewers : .thread(lastThread))
        let hosting = NSHostingView(rootView: ChangeRequestPanel(model: model, changeRequest: snapshot.key, focus: nil)
            .environment(\.glassEffectsEnabled, false)
            .environment(\.animatesFocusScroll, false)
            .frame(width: 700, height: 600))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }

        var offset: CGFloat = 0
        for _ in 0..<50 where offset == 0 {
            try await Task.sleep(for: .milliseconds(100))
            offset = Self.mainScrollView(in: hosting)?.contentView.bounds.origin.y ?? 0
        }
        #expect(offset > 0, "the panel scrolled to the focus target")
        #expect(model.detailFocusRequest == nil, "the request is consumed")
    }

    /// The tallest scroll view: the panel's content (code snippets add short horizontal ones).
    private static func mainScrollView(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        return all(view).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
}
