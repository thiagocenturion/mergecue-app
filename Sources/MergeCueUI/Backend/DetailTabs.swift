import Foundation
import MergeCueCore

/// Detail tabs for the Inbox and Pull requests screens (D48): opening an item adds a tab (with tabs on); closing the
/// last one shows the empty state. With tabs off, the panel has a close button instead.
extension AppModel {
    /// Most open tabs per screen; the oldest closes first.
    static let maxDetailTabs = 8

    func openDetailTab(_ id: String, in tabs: inout [String]) {
        guard detailTabsEnabled == true, !tabs.contains(id) else { return }
        tabs.append(id)
        if tabs.count > Self.maxDetailTabs { tabs.removeFirst(tabs.count - Self.maxDetailTabs) }
    }

    /// Inbox: closes a tab (or, without tabs, the detail) and selects its neighbour.
    public func closeInboxDetail(_ id: String) {
        let next = Self.neighbour(of: id, in: inboxTabs)
        inboxTabs.removeAll { $0 == id }
        if selectedAttentionID == id { selectedAttentionID = next }
    }

    /// Pull requests: closes a tab (or, without tabs, the detail) and selects its neighbour.
    public func closeChangeRequestDetail(_ id: String) {
        let next = Self.neighbour(of: id, in: prTabs)
        prTabs.removeAll { $0 == id }
        if selectedChangeRequestID == id { selectedChangeRequestID = next }
    }

    /// The tab after `id`, else the one before, else nil.
    static func neighbour(of id: String, in tabs: [String]) -> String? {
        guard let index = tabs.firstIndex(of: id) else { return nil }
        if index + 1 < tabs.count { return tabs[index + 1] }
        return index > 0 ? tabs[index - 1] : nil
    }
}
