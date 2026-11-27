import Foundation
import MergeCueCore
import UserNotifications

/// Delivers Sync's grouped notifications through `UNUserNotificationCenter`, one per change request per cycle
/// (`threadIdentifier` groups them in Notification Center).
///
/// `UNUserNotificationCenter` only works inside an app bundle; anywhere else (`swift test`, the headless demo
/// host, `mergecue-snapshots`) notifications are logged instead of delivered. Demo notifications are titled
/// "Demo · …" so they can never be mistaken for live activity.
///
/// Clicking a notification is handled by the app (its `UNUserNotificationCenterDelegate`): `userInfo` carries the
/// deep link (`Keys.deepLink` = `mergecue://change-request/<id>`), the change request id, the attention item ids
/// and the provider web URL.
public final class UserNotificationDeliverer: NotificationDelivering {
    /// `userInfo` keys of delivered notifications.
    public enum Keys {
        public static let deepLink = "mergecue.deep_link"
        public static let changeRequestID = "mergecue.change_request_id"
        public static let attentionItemIDs = "mergecue.attention_item_ids"
        public static let topics = "mergecue.topics"
        public static let webURL = "mergecue.web_url"
        public static let isDemo = "mergecue.is_demo"
    }

    public let isDemo: Bool
    private let log = MCLog(category: "runtime")

    public init(isDemo: Bool) {
        self.isDemo = isDemo
    }

    /// True inside an `.app` bundle with a bundle identifier (UserNotifications traps otherwise).
    public static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// The in-app deep link for a change request.
    public static func deepLink(for changeRequest: ChangeRequestKey) -> URL? {
        var components = URLComponents()
        components.scheme = "mergecue"
        components.host = "change-request"
        components.path = "/" + changeRequest.id
        return components.url
    }

    /// The `userInfo` of a notification (also used by tests).
    public static func userInfo(for notification: GroupedNotification, isDemo: Bool) -> [String: any Sendable] {
        var info: [String: any Sendable] = [
            Keys.changeRequestID: notification.changeRequest.id,
            Keys.attentionItemIDs: notification.attentionItemIDs,
            Keys.topics: notification.topics,
            Keys.isDemo: isDemo,
        ]
        if let link = deepLink(for: notification.changeRequest) { info[Keys.deepLink] = link.absoluteString }
        if let url = notification.webURL { info[Keys.webURL] = url.absoluteString }
        return info
    }

    /// Asks for alert/sound/badge permission (call once, e.g. after onboarding). False outside an app bundle.
    public func requestAuthorization() async -> Bool {
        guard Self.isAvailable else { return false }
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            log.error("Notification authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Settings › Notifications › "Send Test Notification": delivers one native macOS notification now and returns
    /// why macOS won't show it as a banner (nil when it will, unless a Focus mode mutes it: apps cannot read Focus).
    /// Asks for permission first when macOS hasn't asked yet.
    public func deliverTest() async -> String? {
        guard Self.isAvailable else { return "Notifications only work in the installed MergeCue app, not in this build." }
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = await requestAuthorization()
            status = await center.notificationSettings().authorizationStatus
        }
        switch status {
        case .denied:
            return "macOS blocks MergeCue's notifications. Turn them on in System Settings › Notifications › MergeCue."
        case .notDetermined:
            return "macOS hasn't allowed notifications for MergeCue yet."
        case .provisional:
            return "macOS delivers MergeCue's notifications quietly (Notification Center only, no banner). "
                + "Choose Banners or Alerts in System Settings › Notifications › MergeCue."
        default:
            break
        }
        let settings = await center.notificationSettings()
        if settings.alertSetting == .disabled || settings.alertStyle == .none {
            return "macOS shows MergeCue's notifications without a banner (alert style None). "
                + "Choose Banners or Alerts in System Settings › Notifications › MergeCue."
        }
        let content = UNMutableNotificationContent()
        content.title = isDemo ? "Demo · MergeCue test" : "MergeCue test"
        content.body = "Notifications work. You'll get one grouped notification per pull or merge request."
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: "ntf_test_\(UUID().uuidString)", content: content, trigger: nil)
        do {
            try await center.add(request)
            log.notice("Test notification delivered (authorization \(status.rawValue)).")
            return nil
        } catch {
            log.error("Test notification failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    public func deliver(_ notification: GroupedNotification) async {
        let title = isDemo ? "Demo · \(notification.title)" : notification.title
        guard Self.isAvailable else {
            log.notice("notification (not in an app bundle, not delivered): \(title) — \(notification.subtitle)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.threadIdentifier = notification.threadIdentifier
        content.userInfo = Self.userInfo(for: notification, isDemo: isDemo)
        content.sound = notification.isUrgent ? .default : nil
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        do {
            // One notification per thing (D57): drop the delivered ones this one repeats.
            let center = UNUserNotificationCenter.current()
            let superseded = NotificationHygiene.superseded(by: notification, delivered: await Self.delivered(center))
            if !superseded.isEmpty { center.removeDeliveredNotifications(withIdentifiers: superseded) }
            try await center.add(request)
            log.notice("Notification delivered for \(notification.changeRequest.kind.rawValue) change request (\(notification.attentionItemIDs.count) item(s)).")
        } catch {
            log.error("Could not deliver a notification: \(error.localizedDescription)")
        }
    }

    public func withdraw(changeRequest: ChangeRequestKey, keepingActionable actionable: Set<String>) async {
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let stale = NotificationHygiene.stale(changeRequestID: changeRequest.id, actionable: actionable,
                                              delivered: await Self.delivered(center))
        guard !stale.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: stale)
        log.notice("Withdrew \(stale.count) notification(s) that no longer need you.")
    }

    /// MergeCue's notifications still in Notification Center.
    static func delivered(_ center: UNUserNotificationCenter) async -> [DeliveredNotification] {
        await center.deliveredNotifications().compactMap { delivered in
            let request = delivered.request
            let info = request.content.userInfo
            guard let changeRequestID = info[Keys.changeRequestID] as? String else { return nil }
            return DeliveredNotification(
                id: request.identifier, changeRequestID: changeRequestID,
                attentionItemIDs: info[Keys.attentionItemIDs] as? [String] ?? [],
                topics: info[Keys.topics] as? [String] ?? []
            )
        }
    }
}
