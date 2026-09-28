import MergeCueCore
import SwiftUI

/// Result review (`ready_for_review`): a focused screen with the task's milestones on the left, the diff / tests /
/// reply in the middle, the agent's summary, test outcome, proposed reply and PR-head check on the right, and the
/// review gate at the bottom — apply the patch first; publishing is a separate, later action.
struct TaskReviewScreen: View {
    @Bindable var model: AppModel
    let record: TaskRecord
    @State private var showsActivity = false

    private var task: MCTask { record.task }
    private var snapshot: ChangeRequestSnapshot? { model.snapshot(task.origin.changeRequest) }

    var body: some View {
        HStack(spacing: 0) {
            ReviewMilestonesColumn(model: model, record: record, showsActivity: $showsActivity)
                .frame(width: 262)
                .background(Theme.sidebarBackground)
            Rectangle().fill(Theme.divider).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, MainWindowMetrics.contentTopInset - 8)
                HStack(alignment: .top, spacing: 16) {
                    ReviewCenterCard(model: model, record: record)
                    ScrollView {
                        VStack(spacing: 14) {
                            WhatChangedCard(record: record)
                            TestsCard(record: record, now: model.now)
                            ProposedReplyCard(model: model, record: record)
                            HeadCheckCard(record: record, snapshot: snapshot, syncedAt: model.account(task.origin.account)?.status.lastSuccessAt, now: model.now)
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(width: 330)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                ReviewGateBar(model: model, record: record)
            }
            .background(Theme.contentBackground)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            BackButton { model.selectedTaskID = nil }
                .padding(.top, 4)
                .padding(.leading, -8)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    Text("Patch ready for review")
                        .scaledFont(Theme.screenTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    StatusPill(text: "Ready", color: Theme.mint, textColor: Theme.mintText, showsDot: true, size: 14, cueSymbol: "checkmark.circle.fill")
                }
                Text("\(task.origin.providerKind.shortName)  ·  \(task.origin.changeRequestRef.repoFullPath) \(task.origin.providerKind.formattedNumber(task.origin.changeRequest.number))  ·  \(Presentation.taskOriginPhrase(record, snapshot: snapshot))")
                    .scaledFont(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button {
                model.showChangeRequest(task.origin.changeRequest)
            } label: {
                Image(systemName: "book")
            }
            .buttonStyle(IconButtonStyle(size: 36, filled: false))
            .help("Show the \(task.origin.providerKind.changeRequestNoun)")
            .accessibilityLabel("Show the \(task.origin.providerKind.changeRequestNoun)")
            TaskActionsMenu(model: model, record: record)
        }
    }
}

/// Logo + the task's milestones (from its activity history) ending in "Waiting for your review".
struct ReviewMilestonesColumn: View {
    let model: AppModel
    let record: TaskRecord
    @Binding var showsActivity: Bool

    struct Milestone: Identifiable {
        var id: String
        var title: String
        var date: Date
        var failed = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: MainWindowMetrics.titlebarInset - 4)
            HStack(spacing: 12) {
                AppMark(size: 46)
                Text("MergeCue")
                    .scaledFont(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 18)
            ThemeDivider()
                .padding(.top, 18)
                .padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 0) {
                let items = milestones
                ForEach(items) { milestone in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 0) {
                            Image(systemName: milestone.failed ? "xmark" : "checkmark")
                                .scaledFont(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(milestone.failed ? Theme.critical : Theme.blue))
                            Rectangle().fill(Theme.borderStrong).frame(width: 1.5).frame(maxHeight: .infinity)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(milestone.title)
                                .scaledFont(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(UIFormat.relative(from: milestone.date, now: model.now))
                                .scaledFont(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .help(UIFormat.dateTime(milestone.date))
                        }
                        .padding(.bottom, 26)
                    }
                    .padding(.horizontal, 18)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "arrow.trianglehead.clockwise")
                        .scaledFont(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.cyan)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Waiting for your review")
                            .scaledFont(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Ready \(UIFormat.relative(from: readyAt, now: model.now) == "just now" ? "now" : UIFormat.relative(from: readyAt, now: model.now))")
                            .scaledFont(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .cardBackground(Theme.surfaceSelected, radius: 12, border: Theme.accent.opacity(0.45))
                .padding(.horizontal, 8)
                .accessibilityElement(children: .combine)
            }
            .padding(.top, 22)
            Spacer(minLength: 12)
            Button {
                showsActivity.toggle()
            } label: {
                Label("Full activity · \(record.activities.count)", systemImage: "list.bullet.rectangle")
                    .scaledFont(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(PlainRowButtonStyle())
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .popover(isPresented: $showsActivity, arrowEdge: .trailing) {
                ScrollView {
                    ActivityLog(record: record, now: model.now).padding(16)
                }
                .frame(width: 380, height: 420)
            }
        }
    }

    private var readyAt: Date {
        record.activities.last { $0.kind == .resultSubmitted }?.at ?? record.task.updatedAt
    }

    /// Trigger → claimed → patch prepared → tests finished (only what the history contains).
    var milestones: [Milestone] {
        let task = record.task
        let snapshot = model.snapshot(task.origin.changeRequest)
        var result: [Milestone] = []
        let author = Presentation.requesterName(record, snapshot: snapshot)
        let triggerTitle = switch task.type {
        case .fixReview: author.map { "\($0) requested a change" } ?? "Change requested"
        case .addressSuggestion: author.map { "\($0) suggested a change" } ?? "Code suggestion"
        case .draftReply: author.map { "\($0) asked a question" } ?? "Reviewer question"
        case .investigateCI: "CI failed"
        }
        let triggerDate = task.origin.thread.flatMap { snapshot?.thread($0)?.rootComment?.createdAt } ?? task.trigger.capturedAt
        result.append(Milestone(id: "trigger", title: triggerTitle, date: triggerDate))
        if let claim = record.activities.first(where: { $0.kind == .claimed }) {
            result.append(Milestone(id: claim.id, title: "\(claim.actorName ?? task.lease?.agentName ?? "The agent") started", date: claim.at))
        }
        if let changes = record.activities.last(where: { $0.kind == .changesReported }) {
            result.append(Milestone(id: changes.id, title: "Patch prepared", date: changes.at))
        } else if let diff = record.artifact(.diff) {
            result.append(Milestone(id: diff.id, title: "Patch prepared", date: diff.createdAt))
        }
        if let tests = record.activities.last(where: { $0.kind == .testsReported }) {
            let failed = Presentation.testSummary(record)?.outcome == .failed
            result.append(Milestone(id: tests.id, title: failed ? "Tests failed" : "Tests finished", date: tests.at, failed: failed))
        }
        return result
    }
}

/// Changes / Tests / Reply with the file list and diff viewer.
struct ReviewCenterCard: View {
    @Bindable var model: AppModel
    let record: TaskRecord

    var body: some View {
        let files = record.artifact(.diff).map { DiffParser.parse($0.content) } ?? []
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SegmentedTrack(options: ReviewTab.allCases, selection: $model.reviewTab, height: 34, equalWidths: false) { tab, selected in
                    Text(tab.title)
                        .scaledFont(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .frame(minWidth: 70)
                }
                .fixedSize()
                Spacer()
                if !files.isEmpty {
                    (Text("+\(additions)").foregroundStyle(Theme.mintText) + Text("  −\(deletions)").foregroundStyle(Theme.criticalText)
                        + Text("  ·  \(files.count) file\(files.count == 1 ? "" : "s")").foregroundStyle(Theme.textSecondary))
                        .scaledFont(.system(size: 13.5, weight: .medium).monospacedDigit())
                }
            }
            .padding(14)
            switch model.reviewTab {
            case .changes: changes(files)
            case .tests: tests
            case .reply: reply
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(Theme.panel, radius: 16)
    }

    @ViewBuilder
    private func changes(_ files: [DiffFile]) -> some View {
        if files.isEmpty {
            NothingSelected(title: "No code changes", symbol: "doc", message: "The agent didn't submit a diff for this task.")
        } else {
            let selected = files.first { $0.path == model.reviewSelectedFile } ?? files[0]
            VStack(spacing: 4) {
                ForEach(files) { file in
                    let isSelected = file.path == selected.path
                    Button {
                        model.reviewSelectedFile = file.path
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .scaledFont(.system(size: 14))
                                .foregroundStyle(Theme.textSecondary)
                            Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                                .scaledFont(.system(size: 14, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .help(file.path)
                            Spacer()
                            Text("+\(file.additions)").foregroundStyle(Theme.mintText)
                            Text("−\(file.deletions)").foregroundStyle(Theme.criticalText)
                        }
                        .scaledFont(.system(size: 13.5, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .frame(minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Theme.surfaceSelected : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainRowButtonStyle())
                    .accessibilityLabel("\(file.path), \(file.additions) additions, \(file.deletions) deletions")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 14)
            DiffFileCard(file: selected)
                .padding(14)
        }
    }

    @ViewBuilder
    private var tests: some View {
        if let artifact = record.artifact(.testRun) {
            ScrollView {
                TestRunDetail(artifact: artifact, now: model.now).padding(16)
            }
        } else {
            NothingSelected(title: "No test run reported", symbol: "flask",
                            message: "The agent didn't report a test run. Review the diff carefully before applying.")
        }
    }

    @ViewBuilder
    private var reply: some View {
        if let reply = record.task.proposedReply {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(reply)
                        .scaledFont(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardBackground(Theme.surfaceSunken, radius: 12)
                    Text("Posting happens only after you approve a preview of exactly this text — use Publish changes below.")
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
            }
        } else {
            NothingSelected(title: "No reply proposed", symbol: "bubble.left", message: "The agent didn't draft a reply for this task.")
        }
    }
}

/// One file of the diff: path header, hunk headers, numbered red/green rows.
struct DiffFileCard: View {
    let file: DiffFile
    @State private var viewport: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.textSecondary)
                Text(file.path)
                    .scaledFont(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                Menu {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file.path, forType: .string)
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.textSecondary).frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("File actions")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(minHeight: 42)
            ThemeDivider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(file.lines) { line in
                        if line.kind == .hunk {
                            Text(line.text)
                                .scaledFont(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize()
                                .padding(.leading, 60)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .background(Theme.surfaceSunken)
                        } else if line.kind != .meta {
                            CodeLineRow(line: line)
                        }
                    }
                }
                .padding(.bottom, 8)
                .frame(minWidth: viewport.width, minHeight: viewport.height, alignment: .topLeading)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        }
        .cardBackground(Theme.surface, radius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Diff of \(file.path)")
    }
}

// MARK: - Right cards

struct ReviewSideCard<Trailing: View, Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .scaledFont(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22)
                Text(title)
                    .scaledFont(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 6)
                trailing
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(Theme.surface, radius: 16)
    }
}

/// The agent's summary as bullets, plus known risks.
struct WhatChangedCard: View {
    let record: TaskRecord

    var body: some View {
        ReviewSideCard(title: "What changed", symbol: "doc.text") { EmptyView() } content: {
            VStack(alignment: .leading, spacing: 10) {
                let bullets = Self.sentences(record.task.resultSummary)
                if bullets.isEmpty {
                    Text("The agent didn't include a summary.")
                        .scaledFont(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, sentence in
                    bullet(sentence, color: Theme.textPrimary)
                }
                ForEach(record.task.knownRisks, id: \.self) { risk in
                    bullet("Risk: \(risk)", color: Theme.waiting)
                }
                Text("Summary reported by \(record.task.agentLabel ?? "the agent")")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func bullet(_ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color.opacity(0.8)).frame(width: 5, height: 5).offset(y: -2)
            Text(text)
                .scaledFont(.system(size: 13.5))
                .foregroundStyle(color == Theme.textPrimary ? Theme.textPrimary.opacity(0.9) : color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func sentences(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { result.append(sentence) }
        }
        return result
    }
}

/// Test outcome from the `test_run` artifact (failed states shown honestly).
struct TestsCard: View {
    let record: TaskRecord
    let now: Date

    var body: some View {
        let summary = Presentation.testSummary(record)
        let artifact = record.artifact(.testRun)
        ReviewSideCard(title: "Tests", symbol: "flask") {
            if let summary {
                StatusPill(text: pillText(summary), color: color(summary.outcome), textColor: textColor(summary.outcome), showsDot: true, size: 12.5)
            } else {
                StatusPill(text: "Not reported", color: Theme.textSecondary, textColor: Theme.textSecondary, size: 12)
            }
        } content: {
            Text(description(summary, artifact: artifact))
                .scaledFont(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pillText(_ summary: Presentation.TestSummary) -> String {
        switch summary.outcome {
        case .passed: summary.passed.map { "\($0) passed" } ?? "Passed"
        case .failed: summary.failed.map { "\($0) failed" } ?? "Failed"
        case .notRun: "Not run"
        case .unknown: summary.text
        }
    }

    private func textColor(_ outcome: Presentation.TestSummary.Outcome) -> Color {
        switch outcome {
        case .passed: Theme.mintText
        case .failed: Theme.criticalText
        case .notRun, .unknown: Theme.waitingText
        }
    }

    private func color(_ outcome: Presentation.TestSummary.Outcome) -> Color {
        switch outcome {
        case .passed: Theme.mint
        case .failed: Theme.critical
        case .notRun, .unknown: Theme.waiting
        }
    }

    private func description(_ summary: Presentation.TestSummary?, artifact: Artifact?) -> String {
        guard let summary, let artifact else {
            return "The agent didn't report running tests. Review the diff carefully before applying it."
        }
        let command = artifact.metadata["command"] ?? artifact.title
        let who = artifact.reportedBy == .agent ? "reported by the agent" : "run by MergeCue"
        switch summary.outcome {
        case .passed: return "`\(command)` passed in the task worktree (\(who)). Review the changes, then apply the patch to your local branch."
        case .failed: return "`\(command)` failed (\(who)). Check the Tests tab before applying anything."
        case .notRun: return "`\(command)` was not run (\(who))."
        case .unknown: return "`\(command)`: \(summary.text) (\(who))."
        }
    }
}

/// The agent's proposed reply with a copy button.
struct ProposedReplyCard: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        ReviewSideCard(title: "Proposed reply", symbol: "bubble.left") { EmptyView() } content: {
            if let reply = record.task.proposedReply {
                ZStack(alignment: .bottomTrailing) {
                    Text(reply)
                        .scaledFont(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        .lineSpacing(3)
                        .lineLimit(9)
                        .textSelection(.enabled)
                        .padding(12)
                        .padding(.bottom, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        model.copyToPasteboard(reply)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(IconButtonStyle(size: 26, filled: false))
                    .help("Copy the proposed reply")
                    .accessibilityLabel("Copy the proposed reply")
                    .padding(6)
                }
                .cardBackground(Theme.surfaceSunken, radius: 10, border: Theme.borderStrong)
            } else {
                Text("No reply proposed.")
                    .scaledFont(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// Whether the patch is based on the PR/MR head MergeCue last fetched.
struct HeadCheckCard: View {
    let record: TaskRecord
    let snapshot: ChangeRequestSnapshot?
    /// When the head was last fetched (the account's last successful sync).
    var syncedAt: Date?
    var now: Date

    private var freshness: String {
        let fetched = syncedAt.map { "Head fetched \(UIFormat.relative(from: $0, now: now))" } ?? "Head not fetched yet"
        return "\(fetched); MergeCue re-reads it right before applying or posting."
    }

    var body: some View {
        let check = Presentation.headCheck(record, snapshot: snapshot)
        let noun = record.task.origin.providerKind.changeRequestAbbreviation
        let ref = "\(record.task.origin.changeRequestRef.repoFullPath) \(record.task.origin.providerKind.formattedNumber(record.task.origin.changeRequest.number))"
        switch check {
        case .matches:
            ReviewSideCard(title: "Current \(noun) head matches", symbol: "arrow.triangle.branch") {
                Image(systemName: "checkmark.circle")
                    .scaledFont(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.mint)
            } content: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This patch is based on the latest state of \(ref).")
                        .scaledFont(.system(size: 13.5))
                        .foregroundStyle(Theme.textSecondary)
                    Text(freshness)
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .moved(let from, let to):
            ReviewSideCard(title: "\(noun) head moved", symbol: "arrow.triangle.branch") {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.waiting)
            } content: {
                Text("The patch was built on \(UIFormat.shortSHA(from)); \(ref) is now at \(UIFormat.shortSHA(to)). Applying may conflict — consider asking the agent to rebase.")
                    .scaledFont(.system(size: 13.5))
                    .foregroundStyle(Theme.waitingText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .unknown:
            ReviewSideCard(title: "\(noun) head not verified", symbol: "arrow.triangle.branch") {
                Image(systemName: "questionmark.circle").foregroundStyle(Theme.textTertiary)
            } content: {
                Text("MergeCue has no head SHA to compare yet. It re-checks right before applying.")
                    .scaledFont(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Review gate

/// Apply reviewed patch · Discard · "Nothing is pushed or posted without your approval." · Publish changes.
struct ReviewGateBar: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        let task = record.task
        let hasDiff = record.artifact(.diff) != nil
        let approved = Set(task.approvals.filter { $0.decision == .approved }.map(\.action))
        let applied = approved.contains(.applyPatch)
        let canPublish = !hasDiff || applied
        let canReply = task.proposedReply != nil && task.origin.thread != nil
        HStack(spacing: 16) {
            if hasDiff {
                Button {
                    Task { await model.send(.requestActionPreview(task.id, .applyPatch)) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: applied ? "checkmark.circle.fill" : "checkmark.circle")
                            .scaledFont(.system(size: 19, weight: .medium))
                        Text(applied ? "Patch applied" : "Apply reviewed patch")
                    }
                    .padding(.horizontal, 12)
                }
                .buttonStyle(GradientButtonStyle(size: .large))
                .disabled(applied)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Preview the exact patch and approve applying it to your local checkout (⌘↩)")
            }
            Button {
                Task { await model.send(.rejectResult(task.id, note: nil)) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trash")
                    Text("Discard")
                }
                .padding(.horizontal, 12)
            }
            .buttonStyle(SecondaryButtonStyle(size: .large))
            .help("Reject this result and put the task back in the queue for an agent")
            Rectangle().fill(Theme.divider).frame(width: 1, height: 34)
            Text("Nothing is pushed or posted without your approval.")
                .scaledFont(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Menu {
                    Button("Post reply…") { Task { await model.send(.requestActionPreview(task.id, .postReply)) } }
                        .disabled(!canReply || approved.contains(.postReply))
                    Button("Resolve thread…") { Task { await model.send(.requestActionPreview(task.id, .resolveThread)) } }
                        .disabled(task.origin.thread == nil || approved.contains(.resolveThread))
                    Divider()
                    Button("Mark done") { Task { await model.send(.markTaskDone(task.id)) } }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Publish changes")
                    }
                    .scaledFont(.system(size: 14, weight: .medium))
                    .foregroundStyle(canPublish ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 4)
                    .frame(minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceRaised.opacity(canPublish ? 1 : 0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!canPublish)
                .help(canPublish ? "Post the reply or resolve the thread — each with its own preview and approval" : "Apply the patch first")
                .accessibilityLabel(canPublish ? "Publish changes" : "Publish changes, available after applying the patch")
                Text(hasDiff ? "Applies patch first. Publishing comes next." : "Each action shows a preview first.")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Theme.contentBackground)
        .overlay(alignment: .top) { ThemeDivider() }
        .padding(.top, 16)
    }
}
