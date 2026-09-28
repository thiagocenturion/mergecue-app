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
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log.error("Could not deliver a notification: \(error.localizedDescription)")
        }
    }
}
