import Foundation
import MergeCueCore

/// Builds the immutable trigger snapshot of a new task: the exact reviewer comment(s) or CI log excerpt that
/// caused it, as bounded + redacted `UntrustedText` (data, never instructions).
enum TriggerSnapshotBuilder {
    /// Per quoted comment.
    static let maxCommentBytes = 4 * 1024
    /// Comments quoted from one thread (root + latest replies).
    static let maxQuotedComments = 10
    /// CI log excerpt captured at creation.
    static let maxLogBytes = 8 * 1024
    /// Review bodies quoted for a "changes requested" item without a thread.
    static let maxQuotedReviews = 3

    static func build(
        snapshot: ChangeRequestSnapshot,
        thread: ThreadKey?,
        check: CheckKey?,
        reason: AttentionReason?,
        eventType: ChangeEventType?,
        log: LogExcerpt?,
        now: Date
    ) -> TaskTriggerSnapshot {
        var quoted: [UntrustedText] = []
        var anchor: DiffAnchor?
        if let thread, let stored = snapshot.thread(thread) {
            quoted = quotedComments(stored)
            anchor = stored.anchor
        } else if let check, let run = snapshot.check(check) {
            quoted = quotedCheck(run, log: log)
        } else if reason == .changesRequested || eventType == .changeRequested {
            quoted = snapshot.reviews
                .filter { $0.state == .changesRequested && !($0.body ?? "").isEmpty }
                .suffix(maxQuotedReviews)
                .map {
                    UntrustedText.bounded(
                        source: UntrustedText.Source.reviewSummary, author: $0.author.username,
                        createdAt: $0.submittedAt, text: $0.body ?? "", maxBytes: maxCommentBytes
                    )
                }
        }
        return TaskTriggerSnapshot(
            eventType: eventType,
            capturedAt: now,
            headSHA: snapshot.summary.headSHA,
            sourceBranch: snapshot.summary.sourceBranch,
            targetBranch: snapshot.summary.targetBranch,
            quoted: quoted,
            anchor: anchor
        )
    }

    /// Root comment plus the latest replies (system notes skipped), each bounded.
    static func quotedComments(_ thread: ReviewThread) -> [UntrustedText] {
        let source = thread.key.kind == .reviewSummary ? UntrustedText.Source.reviewSummary : UntrustedText.Source.reviewComment
        let comments = thread.comments.filter { $0.kind != .system }
        let selected: [ReviewComment]
        if comments.count > maxQuotedComments, let first = comments.first {
            selected = [first] + comments.suffix(maxQuotedComments - 1)
        } else {
            selected = comments
        }
        return selected.map {
            UntrustedText.bounded(
                source: source, author: $0.author.username, createdAt: $0.createdAt, text: $0.body,
                maxBytes: maxCommentBytes
            )
        }
    }

    static func quotedCheck(_ check: CheckRun, log: LogExcerpt?) -> [UntrustedText] {
        if let log, !log.text.isEmpty {
            return [UntrustedText.bounded(source: UntrustedText.Source.ciLog, createdAt: check.completedAt, text: log.text, maxBytes: maxLogBytes)]
        }
        if let summary = check.summary, !summary.isEmpty {
            return [UntrustedText.bounded(source: UntrustedText.Source.ciLog, createdAt: check.completedAt, text: summary, maxBytes: maxLogBytes)]
        }
        return []
    }
}
