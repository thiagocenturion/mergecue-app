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
}

extension SyncControlling {
    public func setNotificationPreferences(_ preferences: NotificationPreferences) async {}
    public func setQuietHours(_ quietHours: QuietHours?) async {}
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
        self.isUrgent = isUrgent
        self.webURL = webURL
    }
}

/// Delivers notifications (UserNotifications in the app, a recorder in tests).
public protocol NotificationDelivering: Sendable {
    func deliver(_ notification: GroupedNotification) async
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
