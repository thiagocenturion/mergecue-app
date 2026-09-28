import Foundation
import MergeCueCore

/// Plain-string DTO fields that come from providers or third parties (PR/MR titles, branch names, attention
/// summaries, check names, author names, git error text). They travel as ordinary strings for wire compatibility,
/// but every DTO that carries them lists their JSON paths in `untrusted_fields`, and the Core → DTO initializers
/// clean them (`clean(_:)`): terminal control sequences stripped, secrets redacted.
public enum UntrustedFields {
    /// Terminal controls stripped (`TerminalControlStripper`) and secrets redacted (`SecretRedactor`).
    public static func clean(_ text: String) -> String {
        SecretRedactor.redact(TerminalControlStripper.strip(text))
    }

    /// `clean(_:)` for optionals.
    public static func clean(_ text: String?) -> String? {
        text.map(clean)
    }

    public static let taskContext = [
        "source.title", "checkout.source_branch", "checkout.target_branch", "checkout.blocked_reason",
        "trigger.anchor.path", "trigger.untrusted_content", "artifacts[].title",
    ]
    public static let taskSummary = ["title"]
    public static let attentionItem = ["title", "summary"]
    public static let changeContext = [
        "title", "author", "source_branch", "target_branch", "description", "reviews[].author", "threads[].path",
        "threads[].last_author", "checks[].name", "changed_files[].path",
    ]
    public static let thread = ["anchor.path", "comments[].author", "comments[].body"]
    public static let ciFailure = ["name", "excerpt"]
}
