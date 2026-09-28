import AppKit
import Foundation
import MergeCueCore
import SwiftUI
import Testing
@testable import MergeCueUI

/// Banners (announced, critical ones persistent, timer paused while held), the notification permission shown in
/// Settings, and text scaling.
@Suite("Accessibility feedback")
@MainActor
struct AccessibilityFeedbackTests {
    @Test func bannersAreAnnouncedAndCriticalOnesStay() async {
        var announced: [(String, Tone)] = []
        var environment = AppEnvironment.fixed(now: testNow)
        environment.announce = { announced.append(($0, $1)) }
        let model = AppModel(backend: MergeCuePreview.makeBackend(variant: .standard, now: testNow), environment: environment)
        model.showBanner(.critical, "Sync failed")
        model.showBanner(.success, "Copied")
        #expect(announced.map(\.0) == ["Sync failed", "Copied"])
        #expect(announced.first?.1 == .critical)
        #expect(Banner.autoDismissDelay(for: .critical) == nil, "errors stay until dismissed")
        #expect(Banner.autoDismissDelay(for: .success) == .seconds(5))
        #expect(Banner.autoDismissDelay(for: .attention) == .seconds(8))
    }

    @Test func holdingABannerPausesItsTimer() async throws {
        let model = await makeModel()
        model.showBanner(.neutral, "Refreshed")
        let banner = try #require(model.banners.last)
        model.setBannerHeld(banner.id, true)
        #expect(model.isBannerHeld(banner.id))
        // A held banner outlives its delay; released, it goes.
        let held = Task { await model.autoDismissBanner(banner.id, after: .milliseconds(250)) }
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.banners.contains { $0.id == banner.id })
        model.setBannerHeld(banner.id, false)
        await held.value
        #expect(!model.banners.contains { $0.id == banner.id })
        #expect(!model.isBannerHeld(banner.id))
    }

    @Test func notificationPermissionIsReadFromTheEnvironment() async {
        let model = await makeModel()
        #expect(model.notificationPermission == .unknown)
        await model.refreshNotificationPermission()
        #expect(model.notificationPermission == .unavailable, "tests, snapshots and SwiftPM builds can't read it")
        #expect(!model.canOpenNotificationSettings)

        var opened = 0
        var environment = AppEnvironment.fixed(now: testNow)
        environment.notificationPermission = { .denied }
        environment.openNotificationSettings = { opened += 1 }
        let app = AppModel(backend: MergeCuePreview.makeBackend(variant: .standard, now: testNow), environment: environment)
        await app.refreshNotificationPermission()
        #expect(app.notificationPermission == .denied)
        #expect(app.canOpenNotificationSettings)
        app.openNotificationSettings()
        #expect(opened == 1)
        #expect(NotificationPermission.denied.explanation.contains("System Settings"))
    }

    @Test func textScaleGrowsWithTheSetting() {
        let scales = TextSizePreference.allCases.map { Theme.textScale(for: $0.dynamicTypeSize) }
        #expect(scales == scales.sorted())
        #expect(scales.first == 1)
        #expect(Set(scales).count == scales.count)
        #expect(ThemeFont.body.size == 13, "macOS body size")
        #expect(Theme.body.monospacedDigit().monospacedDigits)
    }

    /// `scaledFont` really renders larger text and taller buttons (macOS ignores `dynamicTypeSize` for plain fonts).
    @Test func scaledFontAndButtonsGrow() {
        func size(_ preference: TextSizePreference) -> (text: NSSize, button: NSSize) {
            let text = NSHostingView(rootView: Text("Fix with AI").scaledFont(Theme.body).fixedSize()
                .dynamicTypeSize(preference.dynamicTypeSize)).fittingSize
            let button = NSHostingView(rootView: Button("Fix with AI") {}.buttonStyle(GradientButtonStyle(size: .regular)).fixedSize()
                .dynamicTypeSize(preference.dynamicTypeSize)).fittingSize
            return (text, button)
        }
        let standard = size(.standard), larger = size(.larger)
        #expect(larger.text.width > standard.text.width * 1.2)
        #expect(larger.text.height > standard.text.height)
        #expect(standard.button.height == ButtonSize.regular.height, "default size keeps the mockup's 36 pt button")
        #expect(larger.button.height >= standard.button.height)
        #expect(larger.button.width > standard.button.width)
    }
}
