import AppKit
import Foundation
import MergeCueCore
import MergeCueRuntime
import Synchronization
import SwiftUI
import UserNotifications

/// Key-value storage for UI preferences. The installed app uses `UserDefaults`; tests and snapshots keep them in
/// memory so they never touch the user's defaults.
public struct PreferenceStore: Sendable {
    public var load: @Sendable (String) -> String?
    public var save: @Sendable (String, String?) -> Void

    public init(load: @escaping @Sendable (String) -> String?, save: @escaping @Sendable (String, String?) -> Void) {
        self.load = load
        self.save = save
    }

    /// `UserDefaults.standard`.
    public static var userDefaults: PreferenceStore {
        PreferenceStore(
            load: { UserDefaults.standard.string(forKey: $0) },
            save: { key, value in
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        )
    }

    /// A private in-memory store (optionally pre-filled).
    public static func inMemory(_ initial: [String: String] = [:]) -> PreferenceStore {
        let storage = Mutex(initial)
        return PreferenceStore(
            load: { key in storage.withLock { $0[key] } },
            save: { key, value in storage.withLock { $0[key] = value } }
        )
    }
}

/// UserDefaults keys of the UI preferences.
public nonisolated enum UIPreferenceKeys {
    public static let textSize = "MergeCueTextSize"
    public static let globalHotKey = "MergeCueGlobalHotKey"
}

/// The global shortcut that shows the popover from any app (Settings › General › Keyboard). Registered as a Carbon
/// hot key, which needs no Accessibility permission.
public nonisolated enum HotKeyPreset: String, Sendable, Hashable, CaseIterable, Identifiable {
    case off
    case controlOptionCommandM
    case optionCommandM
    case controlOptionM
    case shiftCommandSpace

    public static let defaultPreset = HotKeyPreset.controlOptionCommandM

    public var id: String { rawValue }

    /// "⌃⌥⌘M".
    public var displayName: String {
        switch self {
        case .off: "Off"
        case .controlOptionCommandM: "⌃⌥⌘M"
        case .optionCommandM: "⌥⌘M"
        case .controlOptionM: "⌃⌥M"
        case .shiftCommandSpace: "⇧⌘Space"
        }
    }

    /// Spoken form for VoiceOver ("Control Option Command M").
    public var spokenName: String {
        switch self {
        case .off: "Off"
        case .controlOptionCommandM: "Control Option Command M"
        case .optionCommandM: "Option Command M"
        case .controlOptionM: "Control Option M"
        case .shiftCommandSpace: "Shift Command Space"
        }
    }

    /// Carbon virtual key code (kVK_ANSI_M = 0x2E, kVK_Space = 0x31); nil when off.
    public var keyCode: UInt32? {
        switch self {
        case .off: nil
        case .controlOptionCommandM, .optionCommandM, .controlOptionM: 0x2E
        case .shiftCommandSpace: 0x31
        }
    }

    /// Carbon modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
    public var carbonModifiers: UInt32 {
        switch self {
        case .off: 0
        case .controlOptionCommandM: 0x1000 | 0x800 | 0x100
        case .optionCommandM: 0x800 | 0x100
        case .controlOptionM: 0x1000 | 0x800
        case .shiftCommandSpace: 0x200 | 0x100
        }
    }
}

/// The app's notification permission as macOS reports it.
public nonisolated enum NotificationPermission: String, Sendable, Hashable {
    /// Not read yet.
    case unknown
    /// Can't be known here: notifications only work in the installed app (not in SwiftPM builds, snapshots, tests).
    case unavailable
    case notDetermined
    case denied
    case authorized
    case provisional

    public var title: String {
        switch self {
        case .unknown: "Checking…"
        case .unavailable: "Not available in this build"
        case .notDetermined: "Not requested yet"
        case .denied: "Off in System Settings"
        case .authorized: "Allowed"
        case .provisional: "Delivered quietly"
        }
    }

    public var explanation: String {
        switch self {
        case .unknown: "Reading the permission from macOS."
        case .unavailable: "macOS delivers notifications only to the installed MergeCue app. Development builds run from SwiftPM log them instead."
        case .notDetermined: "macOS hasn't asked yet. Allow notifications to hear about items that need you."
        case .denied: "MergeCue can't show notifications. Turn them on in System Settings › Notifications › MergeCue."
        case .authorized: "MergeCue can show alerts. Change their style in System Settings › Notifications › MergeCue."
        case .provisional: "Notifications go to Notification Center without alerts. Change this in System Settings › Notifications › MergeCue."
        }
    }

    public var tone: Tone {
        switch self {
        case .authorized: .success
        case .denied: .attention
        case .provisional, .notDetermined: .neutral
        case .unknown, .unavailable: .neutral
        }
    }

    /// Reads the permission from `UNUserNotificationCenter` inside the app bundle; `.unavailable` elsewhere.
    public static func current() async -> NotificationPermission {
        guard UserNotificationDeliverer.isAvailable else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .ephemeral: return .authorized
        case .provisional: return .provisional
        @unknown default: return .unknown
        }
    }

    /// Opens System Settings › Notifications (on MergeCue's page when the bundle identifier is known).
    @MainActor
    public static func openSystemSettings() {
        var link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let id = Bundle.main.bundleIdentifier { link += "?id=\(id)" }
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

/// Posts VoiceOver announcements (banners, onboarding steps).
public enum AccessibilityAnnouncer {
    @MainActor
    public static func announce(_ message: String, tone: Tone = .neutral) {
        var text = AttributedString(message)
        text.accessibilitySpeechAnnouncementPriority = tone == .critical ? .high : .default
        AccessibilityNotification.Announcement(text).post()
    }
}
