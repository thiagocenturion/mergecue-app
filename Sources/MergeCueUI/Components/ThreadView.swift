import AppKit
import MergeCueCore
import SwiftUI

/// Renders an untrusted comment body: inline Markdown (no links), fenced code and ```suggestion blocks.
struct CommentBody: View {
    var text: String
    var font: ThemeFont = .system(size: 13.5)

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
                                .scaledFont(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.violetText)
                                .padding(.horizontal, 10)
                                .padding(.top, 7)
                        }
                        ScrollView(.horizontal) {
                            Text(segment.text.replacingOccurrences(of: "\t", with: "    "))
                                .scaledFont(Theme.mono)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                    }
                    .background(segment.language == "suggestion" ? Theme.mint.opacity(0.08) : Theme.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                } else {
                    Text(Self.inlineMarkdown(segment.text))
                        .scaledFont(font)
                        .foregroundStyle(Theme.textPrimary.opacity(0.92))
                        .lineSpacing(3)
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
            attributed[run.range].font = .system(size: 12.5, design: .monospaced)
            attributed[run.range].backgroundColor = Theme.surfaceRaised
        }
        return attributed
    }
}

/// A review thread: root comment, the code it points at, then every reply in time order.
struct ThreadView: View {
    var thread: ReviewThread
    var providerKind: ProviderKind
    /// Comments at or after this date (not by the current user) are marked "New".
    var unreadSince: Date?
    var currentUserID: String?
    var now: Date
    /// Reviewer / author roles for the chips.
    var reviewers: Set<String> = []
    var authorID: String?
    var checkoutPath: String?
    var onOpen: ((URL) -> Void)?
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader { header }
            ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                CommentCard(comment: comment, role: role(of: comment), isNew: isNew(comment), now: now,
                            providerKind: providerKind, onOpen: onOpen)
                if index == 0, let anchor = thread.anchor, anchor.diffHunk != nil {
                    CodeContextCard(anchor: anchor, checkoutPath: checkoutPath, onOpen: onOpen)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let anchor = thread.anchor {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(anchor.path + (anchor.line.map { ":\($0)" } ?? ""))
                    .scaledFont(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                if anchor.isOutdated {
                    Chip(text: "Outdated", symbol: "clock.arrow.circlepath", tone: .attention)
                        .help("The code changed after this comment (force-push or new commits). The hunk shows the original position.")
                }
            } else {
                Label(thread.key.kind == .reviewSummary ? "Review summary" : "Conversation", systemImage: "bubble.left.and.bubble.right")
                    .scaledFont(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if let resolved = thread.isResolved {
                Chip(text: resolved ? "Resolved" : "Unresolved", symbol: resolved ? "checkmark.circle" : "circle.dashed",
                     tone: resolved ? .success : .neutral)
            }
        }
    }

    private func role(of comment: ReviewComment) -> String? {
        if comment.author.remoteID == authorID { return "Author" }
        if reviewers.contains(comment.author.remoteID) { return "Reviewer" }
        return nil
    }

    private func isNew(_ comment: ReviewComment) -> Bool {
        guard let unreadSince else { return false }
        return comment.createdAt >= unreadSince && comment.author.remoteID != currentUserID
    }
}

/// One comment: initial avatar, name, relative time, role chip, ••• menu and the (untrusted) body.
struct CommentCard: View {
    var comment: ReviewComment
    var role: String?
    var isNew = false
    var now: Date
    var providerKind: ProviderKind
    var onOpen: ((URL) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Avatar(name: comment.author.displayLabel, size: 34)
                Text(comment.author.displayName.flatMap(Presentation.firstName) ?? comment.author.username)
                    .scaledFont(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .help("@\(comment.author.username)")
                Text(UIFormat.relative(from: comment.createdAt, now: now))
                    .scaledFont(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .help(UIFormat.dateTime(comment.createdAt))
                if comment.author.isBot { Chip(text: "Bot") }
                switch comment.kind {
                case .question: Chip(text: "Question", symbol: "questionmark", tone: .progress)
                case .suggestion: Chip(text: "Suggestion", symbol: "chevron.left.forwardslash.chevron.right", tone: .progress)
                case .comment, .system: EmptyView()
                }
                Spacer(minLength: 6)
                if isNew {
                    Chip(text: "New", symbol: "circle.fill", tone: .progress)
                        .accessibilityLabel("Unread")
                }
                if let role {
                    Text(role)
                        .scaledFont(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surfaceRaised))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
                }
                Menu {
                    Button("Copy Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SecretRedactor.redact(comment.body), forType: .string)
                    }
                    if let url = comment.webURL, let onOpen {
                        Button("Open in \(providerKind.displayName)") { onOpen(url) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .scaledFont(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Comment actions")
            }
            CommentBody(text: comment.body)
                .padding(.leading, 46)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(Theme.surface)
        .overlay(alignment: .leading) {
            if isNew {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3).padding(.vertical, 12)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The code a comment points at: file name, line, "Open in editor", numbered lines with − / + rows.
struct CodeContextCard: View {
    var anchor: DiffAnchor
    var checkoutPath: String?
    var onOpen: ((URL) -> Void)?

    var body: some View {
        let file = DiffParser.parse(anchor.diffHunk ?? "", defaultPath: anchor.path).first
        let lines = file?.lines.filter { $0.kind != .hunk && $0.kind != .meta } ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc")
                    .scaledFont(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(anchor.path.split(separator: "/").last.map(String.init) ?? anchor.path)
                    .scaledFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(anchor.path)
                if anchor.isOutdated {
                    Chip(text: "Outdated", symbol: "clock.arrow.circlepath", tone: .attention)
                }
                Spacer(minLength: 8)
                if let line = anchor.line {
                    Text("Line \(line)")
                        .scaledFont(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Button {
                    if let url = editorURL { onOpen?(url) }
                } label: {
                    HStack(spacing: 6) {
                        Text("Open in editor")
                        Image(systemName: "arrow.up.right.square").scaledFont(.system(size: 11))
                    }
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .disabled(editorURL == nil)
                .help(editorURL == nil ? "Map a local checkout to open this file" : "Open \(anchor.path) from your mapped checkout")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ThemeDivider()
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        CodeLineRow(line: line, isAnchor: isAnchor(line))
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
        }
        .cardBackground(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code context, \(anchor.path)\(anchor.line.map { " line \($0)" } ?? "")")
    }

    private var editorURL: URL? {
        guard let checkoutPath else { return nil }
        let expanded = (checkoutPath as NSString).expandingTildeInPath
        return URL(filePath: expanded).appending(path: anchor.path)
    }

    private func isAnchor(_ line: DiffLine) -> Bool {
        guard let target = anchor.line else { return false }
        switch line.kind {
        case .added: return line.newNumber == target
        case .removed: return line.oldNumber == target
        default: return false
        }
    }
}

/// A numbered code row with − / + markers and red / green backgrounds.
struct CodeLineRow: View {
    var line: DiffLine
    var isAnchor = false
    var numberWidth: CGFloat = 46

    var body: some View {
        HStack(spacing: 0) {
            Text((line.kind == .removed ? line.oldNumber : line.newNumber).map(String.init) ?? "")
                .scaledFont(.system(size: 11.5, weight: isAnchor ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isAnchor ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: numberWidth, alignment: .trailing)
                .padding(.trailing, 14)
            Text(marker)
                .scaledFont(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(markerColor)
                .frame(width: 18, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .scaledFont(.system(size: 12, design: .monospaced))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: 16)
        }
        .frame(minHeight: 22)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        default: ""
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .added: Theme.diffAddedText
        case .removed: Theme.diffRemovedText
        default: Theme.textTertiary
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .added, .removed: Theme.textPrimary
        case .hunk, .meta: Theme.textSecondary
        case .context: Theme.textPrimary.opacity(0.82)
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Theme.diffAddedBackground
        case .removed: Theme.diffRemovedBackground
        default: .clear
        }
    }

    private var accessibilityText: String {
        switch line.kind {
        case .added: "Added line \(line.newNumber ?? 0): \(line.text)"
        case .removed: "Removed line \(line.oldNumber ?? 0): \(line.text)"
        case .hunk: "Hunk \(line.text)"
        default: "Line \(line.newNumber ?? 0): \(line.text)"
        }
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
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(provenance)
                    .scaledFont(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("Untrusted — shown as data")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            if quote.source == UntrustedText.Source.ciLog {
                Text(quote.text)
                    .scaledFont(Theme.monoSmall)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(12)
                    .textSelection(.enabled)
            } else {
                CommentBody(text: quote.text)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(Theme.surfaceSunken, radius: 10)
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
