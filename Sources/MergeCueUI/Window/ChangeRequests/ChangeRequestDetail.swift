import MergeCueCore
import SwiftUI

/// PR/MR detail: heading, people/approvals, checks with CI excerpt viewer, review threads (full replies, time
/// order), commits, changed files and links.
struct ChangeRequestDetail: View {
    let model: AppModel

    var body: some View {
        if let snapshot = model.snapshot(id: model.selectedChangeRequestID) {
            ChangeRequestDetailContent(model: model, snapshot: snapshot)
                .id(snapshot.id)
        } else {
            NothingSelected(title: "Select a pull or merge request", symbol: "arrow.triangle.pull",
                            message: "Pick a PR/MR to see its reviews, checks and threads.")
        }
    }
}

struct ChangeRequestDetailContent: View {
    let model: AppModel
    let snapshot: ChangeRequestSnapshot

    var body: some View {
        let summary = snapshot.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heading(summary)
                let tasks = model.tasks(for: snapshot.key)
                if !tasks.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(tasks) { LinkedTaskCard(model: model, record: $0) }
                    }
                }
                if let description = snapshot.description, !description.isEmpty {
                    Card("Description", systemImage: "text.alignleft") {
                        CommentBody(text: description)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    peopleCard
                    checksSummaryCard
                }
                .fixedSize(horizontal: false, vertical: true)
                failingChecks
                threadsCard
                HStack(alignment: .top, spacing: 16) {
                    commitsCard
                    filesCard
                }
                .fixedSize(horizontal: false, vertical: true)
                linksCard
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func heading(_ summary: ChangeRequestSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ChangeRequestRefLabel(kind: summary.providerKind, repoFullPath: summary.repository.fullPath, number: summary.key.number,
                                      font: .callout, glyphSize: 16)
                Spacer()
                Button {
                    Task { await model.send(.openURL(summary.webURL)) }
                } label: {
                    Label("Open in \(summary.providerKind.displayName)", systemImage: "arrow.up.right.square")
                }
            }
            Text(summary.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Chip(text: stateText(summary), symbol: summary.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull",
                     tone: summary.state == .merged ? .success : (summary.state == .open ? .progress : .neutral))
                Chip(text: snapshot.readiness.displayText, symbol: readinessSymbol, tone: readinessTone)
                if summary.involvement.contains(.reviewRequested) { Chip(text: "Your review requested", symbol: "eye", tone: .progress) }
            }
            Text("@\(summary.author.username) wants to merge \(Text(summary.sourceBranch).font(.callout.monospaced())) into \(Text(summary.targetBranch).font(.callout.monospaced())) · updated \(UIFormat.relative(from: summary.updatedAt, now: model.now))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stateText(_ summary: ChangeRequestSummary) -> String {
        if summary.isDraft { return "Draft" }
        switch summary.state {
        case .open: return "Open"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    private var readinessSymbol: String {
        switch snapshot.readiness {
        case .readyToMerge: "checkmark.seal.fill"
        case .checksGreen: "checkmark.circle"
        case .blocked: "hand.raised.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var readinessTone: Tone {
        switch snapshot.readiness {
        case .readyToMerge: .success
        case .checksGreen: .success
        case .blocked: .attention
        case .unknown: .neutral
        }
    }

    private var peopleCard: some View {
        Card("Reviewers", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 8) {
                if snapshot.reviewers.isEmpty {
                    Text("No reviewers requested").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(snapshot.reviewers, id: \.person.remoteID) { reviewer in
                    HStack(spacing: 8) {
                        Avatar(name: reviewer.person.displayLabel, size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(reviewer.person.displayLabel).font(.callout)
                            Text("@" + reviewer.person.username).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if reviewer.isRequired == true {
                            Text("Required").font(.caption).foregroundStyle(.tertiary)
                        }
                        ReviewStateChip(state: reviewer.state)
                    }
                    .accessibilityElement(children: .combine)
                }
                Divider()
                Text(approvalText)
                    .font(.caption)
                    .foregroundStyle(snapshot.approvals.isSatisfied == true ? Theme.mint : Color.secondary)
            }
        }
    }

    private var approvalText: String {
        let approved = snapshot.approvals.approvedBy.count
        if let required = snapshot.approvals.requiredCount {
            return "\(approved) of \(required) required approvals"
        }
        return approved == 0 ? "No approvals yet (approval rules unknown)" : "\(approved) approval\(approved == 1 ? "" : "s")"
    }

    private var checksSummaryCard: some View {
        Card("Checks", systemImage: "checklist", trailing: AnyView(ChecksBadge(state: snapshot.aggregateCheckState).font(.caption))) {
            VStack(alignment: .leading, spacing: 7) {
                if snapshot.checks.isEmpty {
                    Text("No checks reported").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(snapshot.checks) { check in
                    HStack(spacing: 8) {
                        CheckStatusIcon(status: check.status)
                        Text(check.name)
                            .font(.callout)
                            .lineLimit(1)
                        if check.isRequired == true {
                            Text("Required").font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(check.summary ?? check.status.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var failingChecks: some View {
        let failing = snapshot.checks.filter { $0.status.isFailing && $0.key.source != .gitlabPipeline }
        ForEach(failing) { check in
            Card("Failing check · \(check.name)", systemImage: "xmark.octagon") {
                CheckDetail(model: model, check: check)
            }
        }
    }

    private var threadsCard: some View {
        let threads = snapshot.threads.sorted { lhs, rhs in
            if lhs.isUnresolved != rhs.isUnresolved { return lhs.isUnresolved }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        let unresolved = snapshot.unresolvedThreadCount
        return Card("Review threads", systemImage: "bubble.left.and.bubble.right",
                    trailing: AnyView(Text(unresolved == 0 ? "All resolved" : "\(unresolved) unresolved")
                        .font(.caption).foregroundStyle(unresolved == 0 ? Theme.mint : Theme.attention))) {
            if threads.isEmpty {
                Text("No review threads yet").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
                    if index > 0 { Divider().padding(.vertical, 12) }
                    let item = model.state.attention.first { $0.thread == thread.key }
                    ThreadView(thread: thread, providerKind: snapshot.summary.providerKind,
                               unreadSince: item?.isUnread == true ? item?.createdAt : nil,
                               currentUserID: snapshot.key.account.remoteUserID, now: model.now) { url in
                        Task { await model.send(.openURL(url)) }
                    }
                }
            }
        }
    }

    private var commitsCard: some View {
        Card("Commits · \(snapshot.commits.count)", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(snapshot.commits, id: \.sha) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(UIFormat.shortSHA(commit.sha))
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(commit.title).font(.callout).lineLimit(2)
                            Text([commit.author.map { "@\($0)" }, commit.authoredAt.map { UIFormat.relative(from: $0, now: model.now) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var filesCard: some View {
        let additions = snapshot.changedFiles.compactMap(\.additions).reduce(0, +)
        let deletions = snapshot.changedFiles.compactMap(\.deletions).reduce(0, +)
        return Card("Changed files · \(snapshot.changedFiles.count)", systemImage: "doc.on.doc",
                    trailing: AnyView(HStack(spacing: 4) {
                        Text("+\(additions)").foregroundStyle(Theme.mint)
                        Text("−\(deletions)").foregroundStyle(Theme.critical)
                    }.font(.caption.monospacedDigit().weight(.semibold)))) {
            ChangedFileList(files: snapshot.changedFiles)
        }
    }

    private var linksCard: some View {
        Card("Links", systemImage: "link") {
            VStack(alignment: .leading, spacing: 6) {
                Button("Open \(snapshot.summary.providerKind.changeRequestAbbreviation) in \(snapshot.summary.providerKind.displayName)") {
                    Task { await model.send(.openURL(snapshot.summary.webURL)) }
                }
                .buttonStyle(.link)
                Text("Reference: \(snapshot.summary.ref.string)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Snapshot fetched \(UIFormat.relative(from: snapshot.fetchedAt, now: model.now))\(snapshot.baseSHA.map { " · base \(UIFormat.shortSHA($0))" } ?? "") · head \(UIFormat.shortSHA(snapshot.summary.headSHA))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ChangedFileList: View {
    let files: [ChangedFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(files, id: \.path) { file in
                HStack(spacing: 8) {
                    Image(systemName: symbol(file.status))
                        .foregroundStyle(color(file.status))
                        .frame(width: 16)
                        .accessibilityLabel(file.status.rawValue)
                    Text(file.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 6)
                    if let additions = file.additions { Text("+\(additions)").foregroundStyle(Theme.mint) }
                    if let deletions = file.deletions { Text("−\(deletions)").foregroundStyle(Theme.critical) }
                }
                .font(.caption.monospacedDigit())
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func symbol(_ status: FileChangeStatus) -> String {
        switch status {
        case .added: "plus.square"
        case .removed: "minus.square"
        case .renamed, .copied: "arrow.right.square"
        case .modified, .unknown: "square.and.pencil"
        }
    }

    private func color(_ status: FileChangeStatus) -> Color {
        switch status {
        case .added: Theme.mint
        case .removed: Theme.critical
        default: .secondary
        }
    }
}

struct ReviewStateChip: View {
    var state: ReviewState

    var body: some View {
        switch state {
        case .approved: Chip(text: "Approved", symbol: "checkmark", tone: .success)
        case .changesRequested: Chip(text: "Changes requested", symbol: "exclamationmark.bubble", tone: .attention)
        case .commented: Chip(text: "Commented", symbol: "text.bubble")
        case .pending: Chip(text: "Pending", symbol: "clock")
        case .dismissed: Chip(text: "Dismissed", symbol: "xmark")
        }
    }
}

/// Compact change request card used in the Inbox detail.
struct ChangeRequestSummaryCard: View {
    let model: AppModel
    let snapshot: ChangeRequestSnapshot

    var body: some View {
        let summary = snapshot.summary
        Card(summary.providerKind.changeRequestNoun.capitalized, systemImage: "arrow.triangle.pull",
             trailing: AnyView(Button("Show Details") { model.showChangeRequest(summary.key) }.buttonStyle(.link))) {
            VStack(alignment: .leading, spacing: 8) {
                Text("@\(summary.author.username) · \(summary.sourceBranch) → \(summary.targetBranch)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    ChecksBadge(state: snapshot.aggregateCheckState)
                    Label(approvalLine, systemImage: "hand.thumbsup")
                    Label("\(snapshot.unresolvedThreadCount) unresolved", systemImage: "bubble.left")
                    Label("\(snapshot.changedFiles.count) files", systemImage: "doc.on.doc")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if case .blocked(let reasons) = snapshot.readiness, !reasons.isEmpty {
                    Text("Blocked: " + reasons.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Theme.attention)
                }
            }
        }
    }

    private var approvalLine: String {
        let approved = snapshot.approvals.approvedBy.count
        if let required = snapshot.approvals.requiredCount { return "\(approved)/\(required) approvals" }
        return "\(approved) approvals"
    }
}
