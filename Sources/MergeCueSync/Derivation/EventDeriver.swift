import Foundation
import MergeCueCore

/// Pure derivation of normalized `ChangeEvent`s from two snapshots of one change request.
///
/// Identity: every event id is `ChangeEvent.makeID` over (account, CR, type, namespaced object id, object version),
/// so re-deriving the same state (repeated polls, relaunch, a CR that re-appears) yields the same ids and the store
/// inserts each event once. Comment versions are based on the comment's creation, so edits never duplicate.
///
/// Semantics (previous → current):
/// - `review_comment`: a new root comment of a thread; `reply`: a new non-root comment. System notes are skipped.
///   Root comments of GitHub review-summary threads that belong to an approval / changes-requested review are
///   covered by the review event instead.
/// - `thread_resolved`: a thread flips to resolved.
/// - `approval` / `change_requested`: a new (or newly submitted) review with that verdict; for providers that
///   only expose reviewer verdicts, a reviewer's verdict changing to approved / changes requested.
/// - `ci_failed`: per check **name**, a transition into a failing status, or a new failing run of a check that was
///   already failing (a retry that failed again). `ci_recovered`: a passing status for a name that was failing
///   (in `previous`, or listed in `knownFailingCheckNames` when the failure was followed by a pending re-run).
///   Green re-runs produce nothing.
/// - `head_changed`: the head SHA moved (`nativeRefs["force_push"]` is "true" when the old head is no longer part
///   of the commit list; `nativeRefs["outdated_threads"]` counts threads whose anchor became outdated).
/// - `merged` / `closed_without_merge`: the state left `open`.
/// - `review_requested`: the current user's review is newly requested. `ready_to_merge`: readiness became
///   `readyToMerge` on an open CR.
/// - With `previous == nil` (baseline or a newly seen CR) the current content is reported: every comment, current
///   failing checks, approval / changes-requested reviews, a pending review request and readiness.
/// Events whose actor is the current user are flagged `isFromCurrentUser`; head changes on the user's own CR are
/// attributed to the user (providers do not report the pusher).
public enum EventDeriver {
    public static func derive(
        previous: ChangeRequestSnapshot?,
        current: ChangeRequestSnapshot,
        currentUserID: String,
        isBaseline: Bool,
        now: Date
    ) -> [ChangeEvent] {
        derive(
            previous: previous, current: current, currentUserID: currentUserID, isBaseline: isBaseline, now: now,
            knownFailingCheckNames: []
        )
    }

    /// Variant with extra history: `knownFailingCheckNames` are check names whose last *terminal* status was
    /// failing even if `previous` shows a pending re-run (the coordinator passes the names of unresolved CI
    /// attention items), so failure → pending → success still yields `ci_recovered`.
    public static func derive(
        previous: ChangeRequestSnapshot?,
        current: ChangeRequestSnapshot,
        currentUserID: String,
        isBaseline: Bool,
        now: Date,
        knownFailingCheckNames: Set<String>
    ) -> [ChangeEvent] {
        let builder = Builder(current: current, currentUserID: currentUserID, isBaseline: isBaseline, now: now)
        var events: [ChangeEvent] = []
        events += stateEvents(previous: previous, builder: builder)
        events += headEvents(previous: previous, builder: builder)
        events += reviewRequestEvents(previous: previous, builder: builder)
        events += commentEvents(previous: previous, builder: builder)
        events += resolutionEvents(previous: previous, builder: builder)
        events += reviewEvents(previous: previous, builder: builder)
        events += checkEvents(previous: previous, builder: builder, knownFailing: knownFailingCheckNames)
        events += readinessEvents(previous: previous, builder: builder)
        // A snapshot can in theory repeat an object (duplicate API rows); keep the first occurrence of each id.
        var seen = Set<String>()
        return events.filter { seen.insert($0.id).inserted }
    }

    // MARK: Object ids that are not comments/checks/reviews/heads

    /// `objectID` of lifecycle state events (merged / closed).
    public static let stateObjectID = "state"
    /// `objectID` of the review-requested event.
    public static let reviewRequestObjectID = "involvement/review_requested"
    /// `objectID` of ready-to-merge events.
    public static let readinessObjectID = "readiness"

    /// Stable version string of a check run (status, attempt, completion, commit).
    public static func checkVersion(_ check: CheckRun) -> String {
        [
            check.status.rawValue,
            String(check.attempt ?? 0),
            check.completedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "-",
            check.commitSHA ?? "-",
        ].joined(separator: "|")
    }

    /// The representative run per check name: the most recently started/completed one (ties: last listed).
    public static func latestChecksByName(_ checks: [CheckRun]) -> [String: CheckRun] {
        var result: [String: CheckRun] = [:]
        for check in checks {
            guard let existing = result[check.name] else {
                result[check.name] = check
                continue
            }
            if recency(check) >= recency(existing) { result[check.name] = check }
        }
        return result
    }

    private static func recency(_ check: CheckRun) -> Date {
        max(check.startedAt ?? .distantPast, check.completedAt ?? .distantPast)
    }

    /// The comment kind used for classification: the adapter's `question`/`suggestion`/`system`, else the shared
    /// `CommentKind.classify` heuristic.
    public static func effectiveKind(_ comment: ReviewComment) -> CommentKind {
        comment.kind == .comment ? CommentKind.classify(body: comment.body) : comment.kind
    }

    // MARK: Sections

    private static func stateEvents(previous: ChangeRequestSnapshot?, builder: Builder) -> [ChangeEvent] {
        let current = builder.current
        guard let previous, previous.summary.state == .open, current.summary.state != .open else { return [] }
        let merged = current.summary.state == .merged
        return [builder.make(
            type: merged ? .merged : .closedWithoutMerge,
            objectID: stateObjectID,
            version: current.summary.state.rawValue,
            occurredAt: current.summary.updatedAt,
            summary: merged ? "Merged" : "Closed without merge"
        )]
    }

    private static func headEvents(previous: ChangeRequestSnapshot?, builder: Builder) -> [ChangeEvent] {
        let current = builder.current
        guard let previous, let oldHead = previous.summary.headSHA, let newHead = current.summary.headSHA,
              oldHead != newHead else { return [] }
        let commitSHAs = Set(current.commits.map(\.sha))
        let isForcePush = !commitSHAs.isEmpty && !commitSHAs.contains(oldHead)
        let previouslyOutdated = Set(previous.threads.filter(\.isOutdated).map(\.key))
        let newlyOutdated = current.threads.filter { $0.isOutdated && !previouslyOutdated.contains($0.key) }.count
        var summary = isForcePush
            ? "Force-pushed \(short(oldHead)) → \(short(newHead))"
            : "New commits \(short(oldHead)) → \(short(newHead))"
        if newlyOutdated > 0 {
            summary += "; \(newlyOutdated) comment thread\(newlyOutdated == 1 ? "" : "s") now outdated"
        }
        let isMine = current.summary.author.remoteID == builder.currentUserID
        return [builder.make(
            type: .headChanged,
            objectID: ChangeEvent.headObjectID(sha: newHead),
            version: newHead,
            occurredAt: current.summary.updatedAt,
            actor: isMine ? current.summary.author : nil,
            summary: summary,
            nativeRefs: [
                "previous_head": oldHead,
                "head": newHead,
                "force_push": isForcePush ? "true" : "false",
                "outdated_threads": String(newlyOutdated),
            ]
        )]
    }

    private static func reviewRequestEvents(previous: ChangeRequestSnapshot?, builder: Builder) -> [ChangeEvent] {
        let current = builder.current
        guard current.summary.state == .open, current.summary.involvement.contains(.reviewRequested),
              previous?.summary.involvement.contains(.reviewRequested) != true else { return [] }
        let author = current.summary.author
        return [builder.make(
            type: .reviewRequested,
            objectID: reviewRequestObjectID,
            version: current.summary.headSHA ?? String(current.summary.updatedAt.timeIntervalSinceReferenceDate),
            occurredAt: current.summary.updatedAt,
            actor: author,
            summary: "\(author.displayLabel) requested your review",
            forceNotOwn: true
        )]
    }

    private static func commentEvents(previous: ChangeRequestSnapshot?, builder: Builder) -> [ChangeEvent] {
        let current = builder.current
        let previousThreads = Dictionary(
            (previous?.threads ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var events: [ChangeEvent] = []
        for thread in current.threads {
            let known = Set(previousThreads[thread.key]?.comments.map(\.id) ?? [])
            let coveredByReview = isReviewSummaryCoveredByVerdict(thread, reviews: current.reviews)
            for (index, comment) in thread.comments.enumerated() where !known.contains(comment.id) {
                let kind = effectiveKind(comment)
                guard kind != .system else { continue }
                let isRoot = index == 0 && comment.inReplyToID == nil
                if isRoot && coveredByReview { continue }
                let verb = isRoot ? "commented" : "replied"
                var refs: [String: String] = [:]
                if let url = comment.webURL ?? thread.webURL { refs["url"] = url.absoluteString }
                if let anchor = thread.anchor {
                    refs["path"] = anchor.path
                    if let line = anchor.line { refs["line"] = String(line) }
                }
                events.append(builder.make(
                    type: isRoot ? .reviewComment : .reply,
                    objectID: ChangeEvent.commentObjectID(thread: thread.key, commentID: comment.id),
                    version: "created:\(comment.createdAt.timeIntervalSinceReferenceDate)",
                    occurredAt: comment.createdAt,
                    actor: comment.author,
                    thread: thread.key,
                    commentID: comment.id,
                    commentKind: kind,
                    summary: "\(comment.author.displayLabel) \(verb): \(excerpt(comment.body))",
                    nativeRefs: refs
                ))
            }
        }
        return events
    }

    private static func resolutionEvents(previous: ChangeRequestSnapshot?, builder: Builder) -> [ChangeEvent] {
        guard let previous else { return [] }
        let previousThreads = Dictionary(previous.threads.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return builder.current.threads.compactMap { thread in
            guard thread.isResolved == true, let before = previousThreads[thread.key], before.isResolved != true else {
                return nil
            }
            return builder.make(
                type: .threadResolved,
                objectID: thread.key.id,
                version: "resolved:" + (thread.latestComment?.id ?? "-"),
                occurredAt: thread.lastActivityAt,
                thread: thread.key,
                summary: "Thread resolved" + (thread.anchor.map { " (\($0.path))" } ?? ""),
                forceNotOwn: true
            )
        }
    }

    private static func reviewEvents(previous: ChangeRequestSnapshot?, builder: Builder) -> [ChangeEvent] {
        let current = builder.current
        let known = Set((previous?.reviews ?? []).map { "\($0.remoteID)|\($0.state.rawValue)" })
        var events: [ChangeEvent] = []
        for review in current.reviews where !known.contains("\(review.remoteID)|\(review.state.rawValue)") {
            guard let type = eventType(for: review.state) else { continue }
            let body = review.body.map { excerpt($0) } ?? ""
            let verb = type == .approval ? "approved" : "requested changes"
            events.append(builder.make(
                type: type,
                objectID: ChangeEvent.reviewObjectID(review.remoteID),
                version: review.state.rawValue,
                occurredAt: review.submittedAt ?? builder.now,
                actor: review.author,
                summary: body.isEmpty ? "\(review.author.displayLabel) \(verb)" : "\(review.author.displayLabel) \(verb): \(body)"
            ))
        }
        // Providers without review objects (or verdicts not backed by one): reviewer verdict transitions.
        let previousVerdicts = Dictionary(
            (previous?.reviewers ?? []).map { ($0.person.remoteID, $0.state) }, uniquingKeysWith: { first, _ in first }
        )
        for reviewer in current.reviewers {
            guard let type = eventType(for: reviewer.state), previousVerdicts[reviewer.person.remoteID] != reviewer.state
            else { continue }
            let backedByReview = current.reviews.contains {
                $0.author.remoteID == reviewer.person.remoteID && $0.state == reviewer.state
            }
            guard !backedByReview else { continue }
            let verb = type == .approval ? "approved" : "requested changes"
            events.append(builder.make(
                type: type,
                objectID: ChangeEvent.reviewObjectID("reviewer:\(reviewer.person.remoteID)"),
                version: "\(reviewer.state.rawValue)@\(current.summary.headSHA ?? "-")",
                occurredAt: current.summary.updatedAt,
                actor: reviewer.person,
                summary: "\(reviewer.person.displayLabel) \(verb)"
            ))
        }
        return events
    }

    private static func checkEvents(
        previous: ChangeRequestSnapshot?, builder: Builder, knownFailing: Set<String>
    ) -> [ChangeEvent] {
        let currentByName = latestChecksByName(builder.current.checks)
        let previousByName = latestChecksByName(previous?.checks ?? [])
        // A GitLab pipeline aggregate duplicates its failing jobs: when a job of the same pipeline fails, only the
        // job is reported, so one failure yields one CI event (and one attention item / notification line).
        let pipelinesWithFailingJobs = Set(builder.current.checks.compactMap { check -> String? in
            guard check.key.source == .gitlabJob, check.status.isFailing else { return nil }
            return check.logLocator["pipeline_id"]
        })
        var events: [ChangeEvent] = []
        for name in currentByName.keys.sorted() {
            guard let check = currentByName[name] else { continue }
            let before = previousByName[name]
            let wasFailing = before?.status.isFailing == true
                || (knownFailing.contains(name) && before?.status.isPassing != true)
            if check.status.isFailing {
                if check.key.source == .gitlabPipeline, pipelinesWithFailingJobs.contains(check.key.remoteID) { continue }
                let sameRun = before.map { $0.key == check.key && checkVersion($0) == checkVersion(check) } ?? false
                guard !(before?.status.isFailing == true && sameRun) else { continue }
                events.append(checkEvent(.ciFailed, check: check, builder: builder))
            } else if check.status.isPassing && wasFailing {
                events.append(checkEvent(.ciRecovered, check: check, builder: builder))
            }
        }
        return events
    }

    private static func checkEvent(_ type: ChangeEventType, check: CheckRun, builder: Builder) -> ChangeEvent {
        var refs = ["check_name": check.name, "status": check.status.rawValue]
        if let url = check.detailsURL { refs["url"] = url.absoluteString }
        if let sha = check.commitSHA { refs["commit"] = sha }
        let at = check.commitSHA.map { " on \(short($0))" } ?? ""
        let summary = type == .ciFailed
            ? "\(check.name) \(check.status.displayName.lowercased())\(at)"
            : "\(check.name) passed again\(at)"
        return builder.make(
            type: type,
            objectID: ChangeEvent.checkObjectID(check.key),
            version: checkVersion(check),
            occurredAt: check.completedAt ?? check.startedAt ?? builder.now,
            check: check.key,
            summary: summary,
            nativeRefs: refs
        )
    }

    private static func readinessEvents(previous: ChangeRequestSnapshot?, builder: Builder) -> [ChangeEvent] {
        let current = builder.current
        guard current.summary.state == .open, current.readiness == .readyToMerge,
              previous?.readiness != .readyToMerge else { return [] }
        return [builder.make(
            type: .readyToMerge,
            objectID: readinessObjectID,
            version: current.summary.headSHA ?? "-",
            occurredAt: current.summary.updatedAt,
            summary: "Ready to merge",
            forceNotOwn: true
        )]
    }

    // MARK: Helpers

    private static func eventType(for state: ReviewState) -> ChangeEventType? {
        switch state {
        case .approved: .approval
        case .changesRequested: .changeRequested
        case .commented, .pending, .dismissed: nil
        }
    }

    /// GitHub review bodies are threads keyed `rv:<review id>`; when that review is an approval or a
    /// changes-requested verdict, the review event already reports it.
    private static func isReviewSummaryCoveredByVerdict(_ thread: ReviewThread, reviews: [Review]) -> Bool {
        guard thread.key.kind == .reviewSummary else { return false }
        let remoteID = thread.key.remoteID
        let reviewID = remoteID.hasPrefix(ThreadKey.githubReviewSummaryPrefix)
            ? String(remoteID.dropFirst(ThreadKey.githubReviewSummaryPrefix.count))
            : remoteID
        return reviews.contains { $0.remoteID == reviewID && eventType(for: $0.state) != nil }
    }

    /// First line-ish excerpt of untrusted text, redacted and bounded (display only).
    static func excerpt(_ text: String, maxBytes: Int = 160) -> String {
        let flattened = SecretRedactor.redact(text)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
            .joined(separator: " ")
        let bounded = BoundedText.truncate(flattened, maxBytes: maxBytes)
        return bounded.isTruncated ? bounded.text + "…" : bounded.text
    }

    static func short(_ sha: String) -> String {
        String(sha.prefix(7))
    }

    /// Shared construction of events for one snapshot.
    struct Builder {
        let current: ChangeRequestSnapshot
        let currentUserID: String
        let isBaseline: Bool
        let now: Date

        func make(
            type: ChangeEventType,
            objectID: String,
            version: String,
            occurredAt: Date,
            actor: Person? = nil,
            thread: ThreadKey? = nil,
            commentID: String? = nil,
            check: CheckKey? = nil,
            commentKind: CommentKind? = nil,
            summary: String,
            nativeRefs: [String: String] = [:],
            forceNotOwn: Bool = false
        ) -> ChangeEvent {
            ChangeEvent(
                type: type,
                changeRequest: current.key,
                repoFullPath: current.summary.repository.fullPath,
                title: current.summary.title,
                objectID: objectID,
                objectVersion: version,
                occurredAt: occurredAt,
                detectedAt: now,
                actor: actor,
                isFromCurrentUser: !forceNotOwn && actor?.remoteID == currentUserID,
                isBaseline: isBaseline,
                thread: thread,
                commentID: commentID,
                check: check,
                commentKind: commentKind,
                summary: summary,
                nativeRefs: nativeRefs
            )
        }
    }
}
