import Foundation

/// Built-in rule templates. All are inactive until the user activates them in the app.
public enum RuleTemplates {
    /// Fixed timestamp so templates are deterministic values (2026-01-01T00:00:00Z).
    public static let templateDate = Date(timeIntervalSince1970: 1_767_225_600)

    /// Failed CI on my PR/MR → create an "investigate CI" task.
    public static let failedCIOnMyChangeRequest = Rule(
        id: "tpl_failed_ci",
        name: "Failed CI on my PR/MR",
        isActive: false,
        origin: .template,
        eventTypes: [.ciFailed],
        involvement: [.authored],
        action: .createTask(.investigateCI),
        maxFiresPerHour: 10,
        createdAt: templateDate
    )

    /// New requested change on my PR/MR → create a "fix review" task.
    public static let newRequestedChange = Rule(
        id: "tpl_requested_change",
        name: "New requested change",
        isActive: false,
        origin: .template,
        eventTypes: [.changeRequested],
        involvement: [.authored],
        action: .createTask(.fixReview),
        maxFiresPerHour: 10,
        createdAt: templateDate
    )

    /// A reviewer asks a question on my PR/MR → notify.
    public static let reviewerQuestion = Rule(
        id: "tpl_reviewer_question",
        name: "Reviewer question",
        isActive: false,
        origin: .template,
        eventTypes: [.reviewComment, .reply],
        involvement: [.authored],
        commentKinds: [.question],
        action: .notify,
        maxFiresPerHour: 30,
        createdAt: templateDate
    )

    /// A PR/MR is ready for my review (review requested) → notify.
    public static let changeRequestReadyForReview = Rule(
        id: "tpl_ready_for_review",
        name: "PR/MR ready for my review",
        isActive: false,
        origin: .template,
        eventTypes: [.reviewRequested],
        involvement: [.reviewRequested],
        action: .notify,
        maxFiresPerHour: 30,
        createdAt: templateDate
    )

    /// The four built-in templates, in display order.
    public static let all: [Rule] = [
        failedCIOnMyChangeRequest,
        newRequestedChange,
        reviewerQuestion,
        changeRequestReadyForReview,
    ]

    public static func template(id: String) -> Rule? {
        all.first { $0.id == id }
    }

    /// A new, still inactive rule copied from `template` with a fresh id and timestamps.
    public static func instantiate(_ template: Rule, id: String, now: Date) -> Rule {
        var rule = template
        rule.id = id
        rule.isActive = false
        rule.origin = .template
        rule.createdAt = now
        rule.updatedAt = now
        return rule
    }
}
