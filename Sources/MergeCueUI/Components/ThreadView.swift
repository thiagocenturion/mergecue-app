import MergeCueCore
import SwiftUI

/// Renders an untrusted comment body: inline Markdown (no links), fenced code and ```suggestion blocks.
struct CommentBody: View {
    var text: String

    private struct Segment: Identifiable {
        var id: Int
        var isCode: Bool
        var language: String
        var text: String
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var buffer: [Substring] = []
        var inFence = false
        var language = ""
        func push(code: Bool) {
            let joined = buffer.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || code {
                result.append(Segment(id: result.count, isCode: code, language: language, text: joined))
            }
            buffer = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    push(code: true)
                    inFence = false
                    language = ""
                } else {
                    push(code: false)
                    inFence = true
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            buffer.append(line)
        }
        push(code: inFence)
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                if segment.isCode {
                    VStack(alignment: .leading, spacing: 0) {
                        if segment.language == "suggestion" {
                            Label("Suggested change", systemImage: "chevron.left.forwardslash.chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 10)
                                .padding(.top, 6)
                        }
                        ScrollView(.horizontal) {
                            Text(segment.text.replacingOccurrences(of: "\t", with: "    "))
                                .font(.system(.callout, design: .monospaced))
                                .fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                    }
                    .background(segment.language == "suggestion" ? Theme.mint.opacity(0.10) : Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                } else {
                    Text(Self.inlineMarkdown(segment.text))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Inline Markdown (code spans, emphasis) with links removed — reviewer text is untrusted.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].link = nil
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.body, design: .monospaced)
            attributed[run.range].backgroundColor = Color(nsColor: .quaternaryLabelColor).opacity(0.35)
        }
        return attributed
    }
}

/// A review thread: anchor (file/line + diff hunk, outdated marker) and the full reply chain in time order.
struct ThreadView: View {
    var thread: ReviewThread
    var providerKind: ProviderKind
    /// Comments at or after this date (not by the current user) are marked "New".
    var unreadSince: Date?
    var currentUserID: String?
    var now: Date
    var onOpen: ((URL) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let anchor = thread.anchor, let hunk = anchor.diffHunk {
                DiffView(diff: hunk, defaultPath: anchor.path, showFileHeaders: false)
                    .opacity(anchor.isOutdated ? 0.75 : 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                    if index > 0 { Divider().padding(.leading, 34) }
                    CommentRow(comment: comment, isReply: index > 0, isNew: isNew(comment), now: now)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let anchor = thread.anchor {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(anchor.path + (anchor.line.map { ":\($0)" } ?? ""))
                    .font(.callout.monospaced().weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                if anchor.isOutdated {
                    Chip(text: "Outdated", symbol: "clock.arrow.circlepath", tone: .attention)
                        .help("The code changed after this comment (force-push or new commits). The hunk shows the original position.")
                }
            } else {
                Label(thread.key.kind == .reviewSummary ? "Review summary" : "Conversation", systemImage: "bubble.left.and.bubble.right")
                    .font(.callout.weight(.medium))
            }
            Spacer(minLength: 8)
            if let resolved = thread.isResolved {
                Chip(text: resolved ? "Resolved" : "Unresolved", symbol: resolved ? "checkmark.circle" : "circle.dashed",
                     tone: resolved ? .success : .neutral)
            }
            if let url = thread.webURL, let onOpen {
                Button {
                    onOpen(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open in \(providerKind.displayName)")
                .accessibilityLabel("Open thread in \(providerKind.displayName)")
            }
        }
    }

    private func isNew(_ comment: ReviewComment) -> Bool {
        guard let unreadSince else { return false }
        return comment.createdAt >= unreadSince && comment.author.remoteID != currentUserID
    }
}

private struct CommentRow: View {
    var comment: ReviewComment
    var isReply: Bool
    var isNew: Bool
    var now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: comment.author.displayLabel, size: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.author.displayLabel)
                        .font(.callout.weight(.semibold))
                    Text("@" + comment.author.username)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if comment.author.isBot { Chip(text: "Bot") }
                    switch comment.kind {
                    case .question: Chip(text: "Question", symbol: "questionmark", tone: .attention)
                    case .suggestion: Chip(text: "Suggestion", symbol: "chevron.left.forwardslash.chevron.right", tone: .progress)
                    case .comment, .system: EmptyView()
                    }
                    Spacer(minLength: 6)
                    if isNew {
                        Chip(text: "New", symbol: "circle.fill", tone: .progress)
                            .accessibilityLabel("Unread")
                    }
                    Text(UIFormat.relative(from: comment.createdAt, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(UIFormat.dateTime(comment.createdAt))
                }
                CommentBody(text: comment.body)
            }
        }
        .padding(.leading, isReply ? 0 : 0)
        .overlay(alignment: .leading) {
            if isNew {
                Rectangle().fill(Theme.accent).frame(width: 2).offset(x: -8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Quoted untrusted text (exact initial comment, CI excerpt) with its provenance.
struct UntrustedQuote: View {
    var quote: UntrustedText
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "quote.opening")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(provenance)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Untrusted — shown as data")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if quote.source == UntrustedText.Source.ciLog {
                Text(quote.text)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(12)
                    .textSelection(.enabled)
            } else {
                CommentBody(text: quote.text)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.35)).frame(width: 3).padding(.vertical, 6)
        }
    }

    private var provenance: String {
        let source = switch quote.source {
        case UntrustedText.Source.reviewComment: "Review comment"
        case UntrustedText.Source.ciLog: "CI log excerpt"
        case UntrustedText.Source.prDescription: "Description"
        case UntrustedText.Source.reviewSummary: "Review"
        default: quote.source
        }
        var parts = [source]
        if let author = quote.author { parts.append("by @\(author)") }
        if let date = quote.createdAt { parts.append(UIFormat.relative(from: date, now: now)) }
        return parts.joined(separator: " · ")
    }
}
