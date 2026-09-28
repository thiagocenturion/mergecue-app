import AppKit
import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@Suite("Redesign presentation (greeting, cards, handoff context, review checks)")
struct PresentationTests {
    // MARK: Greeting

    @Test func greetingFollowsTimeOfDayAndFirstName() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func at(_ hour: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: hour)))
        }
        #expect(Presentation.greeting(now: try at(9), firstName: "Thiago", calendar: calendar) == "Good morning, Thiago")
        #expect(Presentation.greeting(now: try at(13), firstName: "Thiago", calendar: calendar) == "Good afternoon, Thiago")
        #expect(Presentation.greeting(now: try at(21), firstName: nil, calendar: calendar) == "Good evening")
        #expect(Presentation.firstName("Thiago Centurion") == "Thiago")
        #expect(Presentation.firstName("  ") == nil)
        #expect(Presentation.attentionSubtitle(count: 1) == "1 item needs your attention")
        #expect(Presentation.attentionSubtitle(count: 3) == "3 items need your attention")
    }

    @MainActor
    @Test func greetingNameFallsBackToTheAccount() async {
        let model = await makeModel()
        #expect(model.userFirstName == "Mona")
        let named = AppModel(backend: MergeCuePreview.makeBackend(variant: .standard, now: testNow),
                             initialState: previewState(), environment: .fixed(now: testNow, userFullName: "Thiago Centurion"))
        #expect(named.userFirstName == "Thiago")
    }

    // MARK: Cards

    @Test func attentionHeadlinesNameThePeopleInvolved() throws {
        let state = previewState()
        func text(_ kind: ProviderKind, _ number: Int, _ reason: AttentionReason) throws -> Presentation.AttentionText {
            let item = try #require(state.attention(kind, number: number, reason: reason))
            return Presentation.attentionText(item, snapshot: state.changeRequests.first { $0.key == item.changeRequest })
        }
        let changes = try text(.github, 42, .changesRequested)
        #expect(changes.headline == "Roman requested changes")
        #expect(changes.subtitle == "RefundController.swift:88")
        #expect(changes.commentCount == 4)
        let ci = try text(.gitlab, 42, .ciFailed)
        #expect(ci.headline == "CI failed")
        #expect(ci.subtitle.hasPrefix("test:integration"))
        #expect(try text(.bitbucketCloud, 42, .reviewerQuestion).headline == "New review question")
    }

    @Test func compactTitlesMatchTheCards() {
        #expect(Presentation.compactTitle(.createTask(attentionID: "a", type: .investigateCI)) == "Investigate")
        #expect(Presentation.compactTitle(.createTask(attentionID: "a", type: .fixReview)) == "Fix with AI")
        #expect(Presentation.compactTitle(.openTask(TaskID.generate(), title: "Review"), section: .ready) == "Review patch")
    }

    // MARK: Handoff honesty

    @Test func contextChecklistReflectsRealAvailability() throws {
        var state = previewState()
        let waiting = try #require(state.task(in: .waitingForAgent))
        var items = Presentation.handoffContext(waiting, state: state)
        // The preview mapping for checkout-web is only "probable" (not confirmed): amber, never green.
        #expect(items.first { $0.kind == .repository }?.status == .warning)
        // MergeCue does not read project instructions itself: grey, never a fake green check.
        #expect(items.first { $0.kind == .instructions }?.status == .unavailable)
        #expect(items.first { $0.kind == .thread }?.status == .ready)

        state.mappings.removeAll()
        items = Presentation.handoffContext(waiting, state: state)
        let repository = try #require(items.first { $0.kind == .repository })
        #expect(repository.status == .warning)
        #expect(repository.detail == "Not mapped — map a checkout")

        state.changeRequests.removeAll()
        items = Presentation.handoffContext(waiting, state: state)
        #expect(items.first { $0.kind == .checks }?.status == .unavailable)
        #expect(!items.allSatisfy { $0.status == .ready })
    }

    @Test func blockedCheckoutIsAWarning() throws {
        let state = previewState()
        let blocked = try #require(state.task(in: .blocked))
        let repository = try #require(Presentation.handoffContext(blocked, state: state).first { $0.kind == .repository })
        #expect(repository.status == .warning)
        #expect(repository.detail.contains("GitButler"))
    }

    @Test func trackerShowsAIWorkingOnlyWithAClaim() throws {
        let state = previewState()
        let working = try #require(state.task(in: .working))
        #expect(Presentation.handoffStep(working) == .working)
        var unclaimed = working
        unclaimed.task.lease = nil
        #expect(Presentation.handoffStep(unclaimed) == .waiting)
        #expect(Presentation.handoffStep(try #require(state.task(in: .waitingForAgent))) == .waiting)
        #expect(Presentation.handoffStep(try #require(state.task(in: .readyForReview))) == .ready)
    }

    // MARK: Result review

    @Test func testSummaryIsHonestAboutFailures() throws {
        let state = previewState()
        var ready = try #require(state.task(in: .readyForReview))
        #expect(Presentation.testSummary(ready)?.outcome == .passed)
        #expect(Presentation.testSummary(ready)?.passed == 48)
        let index = try #require(ready.artifacts.firstIndex { $0.kind == .testRun })
        ready.artifacts[index].metadata["status"] = "failed"
        ready.artifacts[index].metadata["failed"] = "2"
        #expect(Presentation.testSummary(ready)?.outcome == .failed)
        #expect(Presentation.taskHeadline(ready, snapshot: nil, now: testNow) == "Patch ready · 2 failed")
        ready.artifacts.remove(at: index)
        #expect(Presentation.testSummary(ready) == nil)
    }

    @Test func headCheckDetectsAMovedHead() throws {
        var state = previewState()
        let ready = try #require(state.task(in: .readyForReview))
        let snapshotIndex = try #require(state.changeRequests.firstIndex { $0.key == ready.task.origin.changeRequest })
        guard case .matches = Presentation.headCheck(ready, snapshot: state.changeRequests[snapshotIndex]) else {
            Issue.record("expected the preview's ready task to match its PR head")
            return
        }
        state.changeRequests[snapshotIndex].summary.headSHA = "0000000000000000000000000000000000000001"
        guard case .moved = Presentation.headCheck(ready, snapshot: state.changeRequests[snapshotIndex]) else {
            Issue.record("expected a moved head")
            return
        }
        #expect(Presentation.headCheck(ready, snapshot: nil) == .unknown)
    }

    // MARK: Sync

    @Test func syncSummaryShowsProblems() {
        let state = previewState()
        #expect(Presentation.syncSummary(accounts: state.accounts, now: testNow, refreshing: false).text == "Synced 2 min ago")
        #expect(Presentation.syncSummary(accounts: state.accounts, now: testNow, refreshing: false).tone == .attention)
        let expired = previewState(.authExpired)
        #expect(Presentation.syncSummary(accounts: expired.accounts, now: testNow, refreshing: false).text == "Reconnect GitLab")
        #expect(Presentation.syncSummary(accounts: [], now: testNow, refreshing: false).text == "No accounts")
    }

    // MARK: Marks and menu bar

    @Test func brandMarksParse() {
        for mark in BrandMark.allCases {
            let bounds = mark.path.boundingRect
            #expect(bounds.width > 18 && bounds.width <= 24.5, "\(mark) width \(bounds.width)")
            #expect(bounds.height > 10 && bounds.height <= 24.5, "\(mark) height \(bounds.height)")
        }
    }

    @Test func svgParserHandlesCompactSyntax() {
        // Relative arc with flags glued to the next number ("0 00-.768.892") and dotted numbers (".6.113").
        let path = SVGPathParser.parse("M.778 1.213a.768.768 0 00-.768.892l3.263 19.81c.084.5.515.868 1.022.873zM1 1h.6.113v2z")
        #expect(!path.isEmpty)
        #expect(path.boundingRect.minX < 1)
    }

    @MainActor
    @Test func menuBarIconPicksTheVariantForTheAppearance() throws {
        let image = MenuBarIcon.image(showsDot: true)
        #expect(!image.isTemplate)
        #expect(image.size == MenuBarIcon.pointSize)
        func centerPixel(_ appearance: NSAppearance.Name) throws -> CGFloat {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = MenuBarIcon.pointSize
            let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
            try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: NSRect(origin: .zero, size: MenuBarIcon.pointSize))
                NSGraphicsContext.restoreGraphicsState()
            }
            // Brightest opaque pixel of the glyph body.
            var brightest: CGFloat = 0
            for x in 0..<36 { for y in 10..<30 {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.9 { brightest = max(brightest, color.brightnessComponent) }
            } }
            return brightest
        }
        let dark = try centerPixel(.darkAqua)
        let light = try centerPixel(.aqua)
        #expect(dark > 0.8)
        #expect(light < dark)
    }
}
