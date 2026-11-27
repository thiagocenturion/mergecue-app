import Foundation
import MergeCueCore

/// Approvals on the owner's pull/merge requests, highlighted until seen (D47).
public nonisolated struct ApprovalHighlight: Sendable, Hashable, Identifiable {
    public var changeRequest: ChangeRequestKey
    public var title: String
    public var repoFullPath: String
    /// Everyone whose current verdict is "approved", latest first.
    public var approvers: [Person]
    /// Approvers the owner has not seen yet (a subset of `approvers`).
    public var newApprovers: [Person]
    public var latestApprovalAt: Date?
    public var requiredCount: Int?
    public var isSatisfied: Bool?

    public var id: String { changeRequest.id }
    public var providerKind: ProviderKind { changeRequest.kind }

    /// "Approved by Mona", "Approved by Mona and Devon", "Approved by Mona and 2 others".
    public var headline: String {
        let names = (newApprovers.isEmpty ? approvers : newApprovers).map { Presentation.shortName($0) }
        switch names.count {
        case 0: return "Approved"
        case 1: return "Approved by \(names[0])"
        case 2: return "Approved by \(names[0]) and \(names[1])"
        default: return "Approved by \(names[0]) and \(names.count - 1) others"
        }
    }

    /// "2 of 2 required approvals", "Ready to merge", or "3 approvals".
    public var progressText: String {
        if let requiredCount { return "\(approvers.count) of \(requiredCount) required approval\(requiredCount == 1 ? "" : "s")" }
        if isSatisfied == true { return "Approval rules met" }
        return "\(approvers.count) approval\(approvers.count == 1 ? "" : "s")"
    }
}

public nonisolated enum ApprovalDerivation {
    /// Current approvers of a change request: approved reviews (an author's latest review wins), reviewer verdicts
    /// and the provider's approval list, with the most recent approval time when known.
    public static func approvers(_ snapshot: ChangeRequestSnapshot) -> (people: [Person], latest: Date?) {
        var latestByAuthor: [String: Review] = [:]
        for review in snapshot.reviews where review.state != .commented && review.state != .pending {
            let current = latestByAuthor[review.author.remoteID]
            if current == nil || (review.submittedAt ?? .distantPast) >= (current?.submittedAt ?? .distantPast) {
                latestByAuthor[review.author.remoteID] = review
            }
        }
        var people: [String: (Person, Date?)] = [:]
        for review in latestByAuthor.values where review.state == .approved {
            people[review.author.remoteID] = (review.author, review.submittedAt)
        }
        for reviewer in snapshot.reviewers where reviewer.state == .approved && people[reviewer.person.remoteID] == nil {
            people[reviewer.person.remoteID] = (reviewer.person, nil)
        }
        for person in snapshot.approvals.approvedBy where people[person.remoteID] == nil {
            // A later "changes requested" review overrides a stale approval list entry.
            if latestByAuthor[person.remoteID]?.state == .changesRequested { continue }
            people[person.remoteID] = (person, nil)
        }
        let sorted = people.values.sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }
        return (sorted.map(\.0), sorted.compactMap(\.1).max())
    }

    /// Open change requests the owner authored that have approvals nobody marked as seen.
    public static func highlights(state: AppState, seen: [String: Set<String>]) -> [ApprovalHighlight] {
        state.changeRequests.compactMap { snapshot in
            guard snapshot.summary.state == .open, snapshot.summary.involvement.contains(.authored) else { return nil }
            let (people, latest) = approvers(snapshot)
            let known = seen[snapshot.key.id] ?? []
            let new = people.filter { !known.contains($0.remoteID) }
            guard !new.isEmpty else { return nil }
            return ApprovalHighlight(
                changeRequest: snapshot.key, title: snapshot.summary.title, repoFullPath: snapshot.summary.repository.fullPath,
                approvers: people, newApprovers: new, latestApprovalAt: latest,
                requiredCount: snapshot.approvals.requiredCount, isSatisfied: snapshot.approvals.isSatisfied
            )
        }
        .sorted { ($0.latestApprovalAt ?? .distantPast) > ($1.latestApprovalAt ?? .distantPast) }
    }

    /// Every current approver per change request (to mark them seen).
    public static func allApprovers(state: AppState) -> [String: Set<String>] {
        Dictionary(state.changeRequests.map { ($0.key.id, Set(approvers($0).people.map(\.remoteID))) }, uniquingKeysWith: { $0.union($1) })
    }
}

extension AppModel {
    /// New approvals on the owner's open pull/merge requests, newest first.
    public var approvalHighlights: [ApprovalHighlight] {
        ApprovalDerivation.highlights(state: state, seen: seenApprovals)
    }

    /// The approval chip of a change request ("2 approvals", short "2" or "1/2"), nil without approvals.
    public func approvalSummary(_ changeRequest: ChangeRequestKey) -> ApprovalSummary? {
        guard let snapshot = snapshot(changeRequest) else { return nil }
        let people = ApprovalDerivation.approvers(snapshot).people
        guard !people.isEmpty else { return nil }
        let known = seenApprovals[changeRequest.id] ?? []
        let required = snapshot.approvals.requiredCount
        return ApprovalSummary(
            count: people.count, required: required,
            text: required.map { "\(people.count) of \($0) approvals" } ?? (people.count == 1 ? "1 approval" : "\(people.count) approvals"),
            short: required.map { "\(people.count)/\($0)" } ?? "\(people.count)",
            isNew: people.contains { !known.contains($0.remoteID) }, isSatisfied: snapshot.approvals.isSatisfied == true
        )
    }

    /// Marks the change request's current approvals as seen (opening it, or dismissing the highlight).
    public func markApprovalsSeen(_ changeRequest: ChangeRequestKey) {
        guard let snapshot = snapshot(changeRequest) else { return }
        let people = Set(ApprovalDerivation.approvers(snapshot).people.map(\.remoteID))
        guard !people.isSubset(of: seenApprovals[changeRequest.id] ?? []) else { return }
        seenApprovals[changeRequest.id, default: []].formUnion(people)
    }

    /// First run: everything already approved counts as seen, so only approvals that arrive later light up.
    func baselineApprovalsIfNeeded() {
        guard !approvalsBaselined, isLoaded, !state.changeRequests.isEmpty else { return }
        seenApprovals = ApprovalDerivation.allApprovers(state: state).merging(seenApprovals) { $0.union($1) }
        approvalsBaselined = true
    }
}

/// Approvals of one change request for chips and rows.
public nonisolated struct ApprovalSummary: Sendable, Hashable {
    public var count: Int
    public var required: Int?
    /// "2 approvals", "1 of 2 approvals".
    public var text: String
    /// "2", "1/2".
    public var short: String
    public var isNew: Bool
    public var isSatisfied: Bool
}
