import Foundation
import MergeCueCore
import MergeCueNetworking

extension GitLabProvider {
    /// Most projects whose merge requests are looked up for one involved listing.
    static let maxInvolvedProjects = 20
    /// Window used when the query has no `updatedSince`.
    static let defaultInvolvedWindow: TimeInterval = 30 * 86_400

    /// Open merge requests of others the user **commented on** (`ChangeRequestScope.involved`).
    ///
    /// GitLab has no "participant" filter on `/merge_requests`. Reviewers stay on a merge request after they review
    /// (their reviewer state changes to reviewed / approved / requested changes), so the review-requested listing
    /// (`reviewer_id=<me>`) already keeps reviewed merge requests. This listing adds the ones the user only
    /// commented on: one page of the user's own `GET /events?action=commented&target_type=note&after=<day>` →
    /// distinct (project, iid) pairs of merge-request notes → per project (at most `maxInvolvedProjects`)
    /// `GET /projects/:id/merge_requests?iids[]=…&state=opened`. The user's own merge requests are left to the
    /// authored listing.
    func listInvolved(_ query: ChangeRequestQuery) async throws -> ChangeRequestPage {
        let user = try await cachedUser()
        let userID = String(user.id)
        let account = AccountKey(instance: instance, remoteUserID: userID)
        let since = query.updatedSince ?? clock.now.addingTimeInterval(-Self.defaultInvolvedWindow)
        // `after` is a date (exclusive); step back one day so the window is never shorter than asked.
        let day = Self.eventDay(since.addingTimeInterval(-86_400))
        let events = try await api.getAll(
            GLEvent.self, "/events",
            query: [
                URLQueryItem(name: "action", value: "commented"),
                URLQueryItem(name: "target_type", value: "note"),
                URLQueryItem(name: "after", value: day),
            ],
            maxPages: 1
        ).items

        var projectOrder: [Int] = []
        var iidsByProject: [Int: [Int]] = [:]
        for event in events {
            guard let project = event.projectId, event.note?.noteableType == "MergeRequest", let iid = event.note?.noteableIid else {
                continue
            }
            if iidsByProject[project] == nil {
                guard projectOrder.count < Self.maxInvolvedProjects else { continue }
                projectOrder.append(project)
            }
            if !(iidsByProject[project] ?? []).contains(iid) { iidsByProject[project, default: []].append(iid) }
        }

        let prefixes = query.namespaces.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        var summaries: [ChangeRequestSummary] = []
        var seen = Set<String>()
        for project in projectOrder {
            let iids = (iidsByProject[project] ?? []).sorted()
            let items = [URLQueryItem(name: "state", value: "opened")] + iids.map { URLQueryItem(name: "iids[]", value: String($0)) }
            let mergeRequests = try await api.getAll(
                GLMergeRequest.self, GitLabAPI.project(String(project)) + "/merge_requests", query: items, maxPages: 1
            ).items
            for mr in mergeRequests where String(mr.author.id) != userID {
                let repository = GitLabMapping.repository(forListItem: mr, account: account, instance: instance)
                if !prefixes.isEmpty {
                    let path = repository.fullPath.lowercased()
                    guard prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                }
                let summary = GitLabMapping.summary(mr, repository: repository, involvement: [.participated], currentUserID: userID)
                guard summary.state == .open, seen.insert(summary.key.id).inserted else { continue }
                GitLabLinkCache.remember(changeRequest: summary.key, webURL: summary.webURL, projectWebURL: repository.webURL)
                summaries.append(summary)
            }
        }
        return ChangeRequestPage(items: summaries)
    }

    /// `YYYY-MM-DD` in UTC (the events API's `after` format).
    static func eventDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
