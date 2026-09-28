import Foundation
import MergeCueCore

/// Pure, testable text and status derivations for the redesigned screens (inbox cards, popover rows, task
/// headlines, the handoff "Context ready" checklist, the PR-head check). Everything is computed from `AppState`
/// values; nothing is assumed or faked.
public nonisolated enum Presentation {
    // MARK: Greeting

    /// "Good morning" (5–11), "Good afternoon" (12–17), "Good evening" (otherwise).
    public static func greeting(now: Date, firstName: String?, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: now)
        let part = switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
        guard let firstName, !firstName.isEmpty else { return part }
        return "\(part), \(firstName)"
    }

    /// The first word of a full name ("Thiago Centurion" → "Thiago"), nil for empty names.
    public static func firstName(_ fullName: String?) -> String? {
        guard let word = fullName?.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return nil }
        let name = String(word)
        return name.isEmpty ? nil : name
    }

    /// "1 item needs your attention" / "3 items need your attention" / "You're all caught up".
    public static func attentionSubtitle(count: Int) -> String {
        switch count {
        case 0: "You're all caught up"
        case 1: "1 item needs your attention"
        default: "\(count) items need your attention"
        }
    }

    /// Display name of a person, first word only ("Roman Koval" → "Roman", "rkoval" → "rkoval").
    static func shortName(_ person: Person) -> String {
        firstName(person.displayName) ?? person.username
    }

    // MARK: Attention items

    /// What an inbox card / popover row says about an attention item.
    public struct AttentionText: Sendable, Hashable {
        /// "Roman requested changes", "CI failed", "New review question".
        public var headline: String
        /// "RefundController.swift:88", "ci / unit-tests · 2 of 14 tests failed", the PR title.
        public var subtitle: String
        /// SF Symbol of the status glyph.
        public var symbol: String
        public var tone: Tone
        /// Comments in the item's thread (or on the whole PR/MR for non-thread items).
        public var commentCount: Int
    }

    public static func attentionText(_ item: AttentionItem, snapshot: ChangeRequestSnapshot?) -> AttentionText {
        let thread = item.thread.flatMap { snapshot?.thread($0) }
        let check = item.check.flatMap { snapshot?.check($0) }
        let rootAuthor = thread?.rootComment.map { shortName($0.author) }
        let latestAuthor = thread?.latestComment.map { shortName($0.author) }
        let location = thread?.anchor.map { anchor in
            let file = anchor.path.split(separator: "/").last.map(String.init) ?? anchor.path
            return anchor.line.map { "\(file):\($0)" } ?? file
        }
        let prTitle = snapshot?.summary.title ?? item.title
        let comments = thread?.comments.count ?? snapshot?.threads.reduce(0) { $0 + $1.comments.count } ?? 0

        let headline: String
        var subtitle = location ?? prTitle
        switch item.reason {
        case .changesRequested:
            headline = rootAuthor.map { "\($0) requested changes" } ?? "Changes requested"
        case .reviewComment:
            headline = rootAuthor.map { "New comment from \($0)" } ?? "New review comment"
        case .reviewerQuestion:
            headline = "New review question"
            if let body = thread?.rootComment?.body { subtitle = firstLine(body, limit: 70) }
        case .codeSuggestion:
            headline = rootAuthor.map { "Code suggestion from \($0)" } ?? "New code suggestion"
        case .reply:
            headline = latestAuthor.map { "New reply from \($0)" } ?? "New reply"
        case .ciFailed:
            headline = "CI failed"
            if let check { subtitle = check.summary.map { "\(check.name) · \(UIFormat.untrustedDisplay($0))" } ?? "\(check.name) failed" }
            else { subtitle = item.summary }
        case .reviewRequested:
            headline = snapshot.map { "\(shortName($0.summary.author)) requested your review" } ?? "Review requested"
        case .readyToMerge:
            headline = "Ready to merge"
            subtitle = item.summary
        case .mergeConflict:
            headline = "Merge conflict"
            subtitle = item.summary
        }
        return AttentionText(headline: headline, subtitle: subtitle, symbol: statusSymbol(item.reason), tone: item.reason.tone,
                             commentCount: comments)
    }

    static func statusSymbol(_ reason: AttentionReason) -> String {
        switch reason {
        case .changesRequested: "exclamationmark"
        case .ciFailed: "xmark"
        case .reviewerQuestion: "questionmark"
        case .reviewComment: "text.bubble.fill"
        case .codeSuggestion: "chevron.left.forwardslash.chevron.right"
        case .reply: "arrowshape.turn.up.left.fill"
        case .reviewRequested: "eye.fill"
        case .readyToMerge: "checkmark"
        case .mergeConflict: "arrow.triangle.merge"
        }
    }

    /// The first non-empty line of untrusted text, without Markdown fences, shortened to `limit` characters.
    static func firstLine(_ text: String, limit: Int) -> String {
        let line = UIFormat.untrustedDisplay(text).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// Label of the pill in the change request panel header ("Changes requested", "CI failed", "Question").
    public static func statusPill(_ reason: AttentionReason) -> String {
        switch reason {
        case .changesRequested: "Changes requested"
        case .ciFailed: "CI failed"
        case .reviewerQuestion: "Question"
        case .reviewComment: "New comment"
        case .codeSuggestion: "Suggestion"
        case .reply: "New reply"
        case .reviewRequested: "Review requested"
        case .readyToMerge: "Ready to merge"
        case .mergeConflict: "Merge conflict"
        }
    }

    /// Compact button title for list cards ("Investigate" instead of "Investigate with AI", "Review patch").
    public static func compactTitle(_ action: PrimaryAction, section: PopoverSection? = nil) -> String {
        switch action {
        case .createTask(_, let type): type == .investigateCI ? "Investigate" : type.actionTitle
        case .openTask(_, let title): section == .ready && title == "Review" ? "Review patch" : title
        default: action.title
        }
    }

    // MARK: Tasks

    /// "Address Roman's review", "Apply Taylor's suggestion", "Reply to Lucía", "Investigate ci / unit-tests".
    public static func taskTitle(_ record: TaskRecord, snapshot: ChangeRequestSnapshot?) -> String {
        let task = record.task
        let author = requesterName(record, snapshot: snapshot)
        switch task.type {
        case .fixReview: return author.map { "Address \($0)'s review" } ?? "Address the review"
        case .addressSuggestion: return author.map { "Apply \($0)'s suggestion" } ?? "Apply the suggestion"
        case .draftReply: return author.map { "Reply to \($0)" } ?? "Draft a reply"
        case .investigateCI:
            let check = task.origin.check.flatMap { snapshot?.check($0) }
            return check.map { "Investigate \($0.name)" } ?? "Investigate the CI failure"
        }
    }

    /// Who asked for the change: the thread's root author, else the quoted comment's author.
    static func requesterName(_ record: TaskRecord, snapshot: ChangeRequestSnapshot?) -> String? {
        if let thread = record.task.origin.thread.flatMap({ snapshot?.thread($0) }), let root = thread.rootComment {
            return shortName(root.author)
        }
        return record.task.trigger.quoted.first(where: { $0.source != UntrustedText.Source.ciLog })?.author
    }

    /// "Taylor's code suggestion", "Roman's requested change", "ci / unit-tests failure" (review subtitle).
    public static func taskOriginPhrase(_ record: TaskRecord, snapshot: ChangeRequestSnapshot?) -> String {
        let author = requesterName(record, snapshot: snapshot)
        switch record.task.type {
        case .fixReview: return author.map { "\($0)'s requested change" } ?? "Requested change"
        case .addressSuggestion: return author.map { "\($0)'s code suggestion" } ?? "Code suggestion"
        case .draftReply: return author.map { "\($0)'s question" } ?? "Reviewer question"
        case .investigateCI:
            let check = record.task.origin.check.flatMap { snapshot?.check($0) }
            return check.map { "\($0.name) failure" } ?? "CI failure"
        }
    }

    /// Headline of a task row in the popover ("Agent running tests", "Patch ready · 48 tests passed").
    public static func taskHeadline(_ record: TaskRecord, snapshot: ChangeRequestSnapshot?, now: Date) -> String {
        let task = record.task
        switch task.state {
        case .waitingForAgent: return taskTitle(record, snapshot: snapshot)
        case .working:
            guard record.hasRealClaim else { return taskTitle(record, snapshot: snapshot) }
            return workingPhrase(record.latestProgress?.data["phase"])
        case .readyForReview:
            var parts: [String] = []
            if record.artifact(.diff) != nil { parts.append("Patch ready") }
            else if task.proposedReply != nil { parts.append("Reply drafted") }
            else { parts.append("Result ready") }
            if let tests = testSummary(record) { parts.append(tests.text) }
            return parts.joined(separator: " · ")
        case .stale:
            let since = task.lease?.heartbeatAt ?? task.updatedAt
            return "No heartbeat for \(UIFormat.duration(from: since, to: now))"
        case .blocked: return task.checkout?.blockedReason ?? "Blocked"
        case .failed: return "The agent couldn't finish"
        case .approvedAction: return "Performing the approved action…"
        case .done, .cancelled, .dismissed: return task.state.displayName
        }
    }

    /// "Agent running tests" etc. from the agent-reported phase (never an estimate).
    public static func workingPhrase(_ phase: String?) -> String {
        switch phase {
        case "investigating": "Agent investigating"
        case "planning": "Agent planning the fix"
        case "editing": "Agent editing code"
        case "testing": "Agent running tests"
        case "finalizing": "Agent finalizing"
        default: "Agent working"
        }
    }

    /// Test outcome from the task's `test_run` artifact.
    public struct TestSummary: Sendable, Hashable {
        public enum Outcome: Sendable, Hashable { case passed, failed, notRun, unknown }
        public var outcome: Outcome
        /// "14 passed", "2 failed", "Not run".
        public var text: String
        public var passed: Int?
        public var failed: Int?
    }

    public static func testSummary(_ record: TaskRecord) -> TestSummary? {
        guard let artifact = record.artifact(.testRun) else { return nil }
        let status = artifact.metadata["status"] ?? "unknown"
        let passed = artifact.metadata["passed"].flatMap(Int.init)
        let failed = artifact.metadata["failed"].flatMap(Int.init)
        switch status {
        case "passed" where (failed ?? 0) == 0:
            return TestSummary(outcome: .passed, text: passed.map { "\($0) tests passed" } ?? "Tests passed", passed: passed, failed: failed)
        case "failed", "error", "passed":
            return TestSummary(outcome: .failed, text: failed.map { "\($0) failed" } ?? "Tests failed", passed: passed, failed: failed)
        case "not_run", "skipped":
            return TestSummary(outcome: .notRun, text: "Tests not run", passed: passed, failed: failed)
        default:
            return TestSummary(outcome: .unknown, text: "Tests \(status)", passed: passed, failed: failed)
        }
    }

    // MARK: Handoff context

    /// Availability of one piece of context the agent will fetch through MergeCue MCP.
    public enum ContextStatus: Sendable, Hashable {
        /// Present in MergeCue's state (green check).
        case ready
        /// Present but needs the user (amber warning), e.g. an unconfirmed or missing checkout mapping.
        case warning
        /// Not available / not checked by MergeCue (grey).
        case unavailable
    }

    public struct ContextItem: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable, Hashable { case thread, ciLog, diff, checks, repository, instructions }
        public var kind: Kind
        public var title: String
        public var detail: String
        public var status: ContextStatus
        public var id: String { kind.rawValue }
    }

    /// The "Context ready" checklist of the handoff screen, strictly from what `state` contains.
    public static func handoffContext(_ record: TaskRecord, state: AppState) -> [ContextItem] {
        let task = record.task
        let snapshot = state.changeRequests.first { $0.key == task.origin.changeRequest }
        var items: [ContextItem] = []

        if let threadKey = task.origin.thread {
            if let thread = snapshot?.thread(threadKey) {
                let count = thread.comments.count
                let who = thread.rootComment.map { " from \(shortName($0.author))" } ?? ""
                items.append(ContextItem(kind: .thread, title: "Review thread",
                                         detail: count == 1 ? "1 comment\(who)" : "\(count) comments\(who)", status: .ready))
            } else if !task.trigger.quoted.isEmpty {
                items.append(ContextItem(kind: .thread, title: "Review thread", detail: "Initial comment captured; thread not loaded", status: .warning))
            } else {
                items.append(ContextItem(kind: .thread, title: "Review thread", detail: "Not loaded", status: .unavailable))
            }
        }
        if task.origin.check != nil || task.trigger.quoted.contains(where: { $0.source == UntrustedText.Source.ciLog }) {
            let hasLog = task.trigger.quoted.contains { $0.source == UntrustedText.Source.ciLog }
            items.append(ContextItem(kind: .ciLog, title: "CI log excerpt",
                                     detail: hasLog ? "Bounded, redacted excerpt captured" : "No excerpt captured",
                                     status: hasLog ? .ready : .unavailable))
        }

        if let files = snapshot?.changedFiles, !files.isEmpty {
            let changes = files.reduce(0) { $0 + ($1.additions ?? 0) + ($1.deletions ?? 0) }
            let fileText = files.count == 1 ? "1 file" : "\(files.count) files"
            items.append(ContextItem(kind: .diff, title: "Relevant diff",
                                     detail: changes > 0 ? "\(fileText), \(changes) changes" : fileText, status: .ready))
        } else if task.trigger.anchor?.diffHunk != nil {
            items.append(ContextItem(kind: .diff, title: "Relevant diff", detail: "Diff hunk of the comment", status: .ready))
        } else {
            items.append(ContextItem(kind: .diff, title: "Relevant diff", detail: "Not fetched yet", status: .unavailable))
        }

        if let checks = snapshot?.checks, !checks.isEmpty {
            let failing = checks.filter(\.status.isFailing).count
            let pending = checks.filter(\.status.isPending).count
            let detail: String
            if failing > 0 { detail = failing == 1 ? "1 failing check" : "\(failing) failing checks" }
            else if pending > 0 { detail = pending == 1 ? "1 check running" : "\(pending) checks running" }
            else { detail = "All checks passing" }
            items.append(ContextItem(kind: .checks, title: "CI checks", detail: detail, status: failing > 0 || pending > 0 ? .warning : .ready))
        } else {
            items.append(ContextItem(kind: .checks, title: "CI checks", detail: "No checks reported", status: .unavailable))
        }

        items.append(repositoryContext(record, snapshot: snapshot, mappings: state.mappings))
        items.append(instructionsContext(record, state: state))
        return items
    }

    /// Which instruction files (AGENTS.md, CLAUDE.md) exist in the mapped checkout. MergeCue only checks that
    /// they exist; the agent reads them itself from its checkout.
    static func instructionsContext(_ record: TaskRecord, state: AppState) -> ContextItem {
        let task = record.task
        let checkout = task.checkout?.mappedCheckoutPath
            ?? state.mappings.first { $0.repo == task.origin.changeRequest.repo }?.checkoutPath
        guard let checkout else {
            return ContextItem(kind: .instructions, title: "Project instructions", detail: "Map a checkout to check for AGENTS.md / CLAUDE.md",
                               status: .unavailable)
        }
        guard let files = state.instructionFiles[checkout] else {
            return ContextItem(kind: .instructions, title: "Project instructions", detail: "Checkout not found on this Mac", status: .unavailable)
        }
        if files.isEmpty {
            return ContextItem(kind: .instructions, title: "Project instructions", detail: "No AGENTS.md or CLAUDE.md in the checkout",
                               status: .unavailable)
        }
        return ContextItem(kind: .instructions, title: "Project instructions",
                           detail: "\(files.joined(separator: ", ")) in the checkout — your agent reads it", status: .ready)
    }

    static func repositoryContext(_ record: TaskRecord, snapshot: ChangeRequestSnapshot?, mappings: [RepoMapping]) -> ContextItem {
        let task = record.task
        let repoKey = task.origin.changeRequest.repo
        let repoName = task.origin.changeRequestRef.repoFullPath.split(separator: "/").last.map(String.init) ?? task.origin.changeRequestRef.repoFullPath
        let branch = task.checkout?.targetBranch ?? snapshot?.summary.targetBranch ?? "main"
        if let checkout = task.checkout, checkout.policy == .blocked {
            return ContextItem(kind: .repository, title: "Mapped local repository",
                               detail: checkout.isGitButlerManaged ? "GitButler workspace — map a separate clone" : (checkout.blockedReason ?? "Blocked — map a safe checkout"),
                               status: .warning)
        }
        guard let mapping = mappings.first(where: { $0.repo == repoKey }) else {
            return ContextItem(kind: .repository, title: "Mapped local repository", detail: "Not mapped — map a checkout", status: .warning)
        }
        if !mapping.isConfirmed {
            return ContextItem(kind: .repository, title: "Mapped local repository",
                               detail: "\(repoName) — suggested, confirm the mapping", status: .warning)
        }
        return ContextItem(kind: .repository, title: "Mapped local repository", detail: "\(repoName) (\(branch))", status: .ready)
    }

    // MARK: Handoff progress

    /// The 4-step tracker: Task created → Waiting for agent → AI working → Ready for review.
    public enum HandoffStep: Int, Sendable, CaseIterable, Comparable {
        case created, waiting, working, ready

        public var title: String {
            switch self {
            case .created: "Task created"
            case .waiting: "Waiting for agent"
            case .working: "AI working"
            case .ready: "Ready for review"
            }
        }

        public static func < (lhs: HandoffStep, rhs: HandoffStep) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The active step. `working` only with a real claim (a lease), never on a guess.
    public static func handoffStep(_ record: TaskRecord) -> HandoffStep {
        switch record.task.state {
        case .waitingForAgent, .blocked: .waiting
        case .working: record.hasRealClaim ? .working : .waiting
        case .stale, .failed: .working
        case .readyForReview, .approvedAction, .done: .ready
        case .cancelled, .dismissed: .created
        }
    }

    // MARK: PR head

    public enum HeadCheck: Sendable, Hashable {
        /// The patch's base equals the PR/MR head MergeCue last fetched.
        case matches(String)
        /// The head moved after the task captured it.
        case moved(from: String, to: String)
        /// Not enough information (no SHA on either side).
        case unknown
    }

    /// Compares the SHA the task was built on (diff `base_sha`, else the trigger's head) with the latest fetched head.
    public static func headCheck(_ record: TaskRecord, snapshot: ChangeRequestSnapshot?) -> HeadCheck {
        let base = record.artifact(.diff)?.metadata["base_sha"] ?? record.task.trigger.headSHA ?? record.task.checkout?.baseSHA
        guard let base, !base.isEmpty, let head = snapshot?.summary.headSHA, !head.isEmpty else { return .unknown }
        return base == head ? .matches(head) : .moved(from: base, to: head)
    }

    // MARK: Sync

    /// The one-line sync state of the header / sidebar footer ("Synced just now", "Offline", "Reconnect GitLab").
    public struct SyncSummary: Sendable, Hashable {
        public var text: String
        public var tone: Tone
    }

    public static func syncSummary(accounts: [AccountState], now: Date, refreshing: Bool) -> SyncSummary {
        guard !accounts.isEmpty else { return SyncSummary(text: "No accounts", tone: .neutral) }
        if refreshing { return SyncSummary(text: "Syncing…", tone: .neutral) }
        if let expired = accounts.first(where: { $0.status.state == .authExpired }) {
            return SyncSummary(text: "Reconnect \(expired.kind.displayName)", tone: .critical)
        }
        if accounts.allSatisfy({ if case .offline = $0.status.state { true } else { false } }) {
            return SyncSummary(text: "Offline", tone: .attention)
        }
        let last = accounts.compactMap(\.status.lastSuccessAt).max()
        let hasProblem = accounts.contains { $0.status.state.isProblem }
        guard let last else { return SyncSummary(text: "Not synced yet", tone: hasProblem ? .attention : .neutral) }
        let age = now.timeIntervalSince(last)
        let text = age < 60 ? "Synced just now" : "Synced \(UIFormat.relative(from: last, now: now))"
        return SyncSummary(text: text, tone: hasProblem ? .attention : .success)
    }
}
