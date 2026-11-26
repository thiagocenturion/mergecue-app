import Foundation

/// Control surface of the sync service (`SyncCoordinator` in `MergeCueSync`).
public protocol SyncControlling: Sendable {
    func start() async
    func stop() async
    func refreshAll() async
    func refresh(account: AccountKey) async
    /// Reload accounts/credentials from the store.
    func accountsDidChange() async
    func statuses() async -> [AccountSyncStatus]
    /// Receives new (non-baseline, deduped) events after they were committed to the store.
    func setEventHandler(_ handler: @escaping @Sendable ([ChangeEvent]) async -> Void) async
    func setNotificationsPaused(until: Date?) async
    /// Per-category notification switches (additive; the default implementation ignores them).
    func setNotificationPreferences(_ preferences: NotificationPreferences) async
    /// Global quiet hours for notifications (additive; the default implementation ignores them).
    func setQuietHours(_ quietHours: QuietHours?) async
    /// Which scopes beyond "authored" are listed (additive; the default implementation ignores it).
    func setTrackingPreferences(_ preferences: TrackingPreferences) async
    /// The user came back to MergeCue (popover opened, main window became key): accounts refresh their lists
    /// (debounced per account) and retry change requests that failed terminally (additive; default no-op).
    func userDidReturn() async
    /// Change requests with an active agent task (waiting for / claimed by an agent): Sync refreshes their details
    /// at the fastest tier (additive; default no-op).
    func setActiveChangeRequests(_ keys: Set<ChangeRequestKey>) async
}

extension SyncControlling {
    public func setNotificationPreferences(_ preferences: NotificationPreferences) async {}
    public func setQuietHours(_ quietHours: QuietHours?) async {}
    public func setTrackingPreferences(_ preferences: TrackingPreferences) async {}
    public func userDidReturn() async {}
    public func setActiveChangeRequests(_ keys: Set<ChangeRequestKey>) async {}
}

/// One semantic notification per change request per sync cycle.
public struct GroupedNotification: Codable, Sendable, Hashable {
    public var id: String
    /// Change request id — groups notifications per CR in Notification Center.
    public var threadIdentifier: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var changeRequest: ChangeRequestKey
    public var attentionItemIDs: [String]
    /// What the notification announces besides attention items, e.g. `event:approval`, `event:merged`,
    /// `task:<id>`. A notification with topics is news: it is never withdrawn because its items stopped needing
    /// the user, only replaced by a newer one about the same things (D57).
    public var topics: [String]
    public var isUrgent: Bool
    public var webURL: URL?

    public init(
        id: String,
        threadIdentifier: String? = nil,
        title: String,
        subtitle: String,
        body: String,
        changeRequest: ChangeRequestKey,
        attentionItemIDs: [String] = [],
        topics: [String] = [],
        isUrgent: Bool = false,
        webURL: URL? = nil
    ) {
        self.id = id
        self.threadIdentifier = threadIdentifier ?? changeRequest.id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.changeRequest = changeRequest
        self.attentionItemIDs = attentionItemIDs
        self.topics = topics
        self.isUrgent = isUrgent
        self.webURL = webURL
    }
}

/// Delivers notifications (UserNotifications in the app, a recorder in tests).
public protocol NotificationDelivering: Sendable {
    /// Shows `notification`, replacing the delivered ones it supersedes (`NotificationHygiene.superseded`).
    func deliver(_ notification: GroupedNotification) async
    /// Removes the change request's delivered notifications whose attention items all stopped needing the user
    /// (`NotificationHygiene.stale`): approved again, acknowledged, dismissed, snoozed, resolved or merged (D57).
    func withdraw(changeRequest: ChangeRequestKey, keepingActionable actionable: Set<String>) async
}

extension NotificationDelivering {
    public func withdraw(changeRequest: ChangeRequestKey, keepingActionable actionable: Set<String>) async {}
}

/// A notification still shown in Notification Center, as far as MergeCue needs to know it.
public struct DeliveredNotification: Sendable, Hashable {
    public var id: String
    public var changeRequestID: String
    public var attentionItemIDs: [String]
    public var topics: [String]

    public init(id: String, changeRequestID: String, attentionItemIDs: [String], topics: [String]) {
        self.id = id
        self.changeRequestID = changeRequestID
        self.attentionItemIDs = attentionItemIDs
        self.topics = topics
    }
}

/// Keeps Notification Center free of duplicates (D57): one notification per thing that needs the user.
public enum NotificationHygiene {
    /// Delivered notifications that `new` repeats: same change request, and everything they announced (items and
    /// topics) is announced again by `new`. A second "Re-approval needed" replaces the first.
    public static func superseded(by new: GroupedNotification, delivered: [DeliveredNotification]) -> [String] {
        let items = Set(new.attentionItemIDs)
        let topics = Set(new.topics)
        return delivered.filter { old in
            old.id != new.id && old.changeRequestID == new.changeRequest.id
                && !(old.attentionItemIDs.isEmpty && old.topics.isEmpty)
                && Set(old.attentionItemIDs).isSubset(of: items) && Set(old.topics).isSubset(of: topics)
        }.map(\.id)
    }

    /// Delivered notifications of the change request about items that no longer need the user: they list items,
    /// no topic, and none of their items is in `actionable`.
    public static func stale(changeRequestID: String, actionable: Set<String>, delivered: [DeliveredNotification]) -> [String] {
        delivered.filter { old in
            old.changeRequestID == changeRequestID && old.topics.isEmpty && !old.attentionItemIDs.isEmpty
                && actionable.isDisjoint(with: old.attentionItemIDs)
        }.map(\.id)
    }
}

/// Coarse change signals the UI observes to refresh views.
public enum EngineChange: Sendable, Hashable {
    case accounts
    case syncStatus
    case attention
    case changeRequests
    /// A specific task changed, or nil for "tasks in general".
    case tasks(TaskID?)
    case rules
    case mappings
    case audit
}
