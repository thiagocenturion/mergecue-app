import MergeCueCore
import SwiftUI

/// Renders an untrusted comment or description body as Markdown: headings, paragraphs, bullet / numbered / task
/// lists, quotes, fenced code (```suggestion and ```diff styled), tables, rules, emphasis, code spans and links.
///
/// The text is redacted and stripped of control sequences before anything is shown or selectable. Links are kept
/// only when `onOpen` is set and are http(s) only; a click goes through `onOpen` (the app's `WebLinkPolicy`, which
/// asks before opening unfamiliar hosts). Images are never loaded: they show as a link named after their alt text.
/// HTML comments, which providers hide, are shown muted so hidden text is never invisible here.
struct CommentBody: View {
    var text: String
    var font: ThemeFont = .system(size: 13.5)
    var onOpen: ((URL) -> Void)?

    var body: some View {
        let blocks = MarkdownParser.parse(UIFormat.untrustedDisplay(text))
        MarkdownBlocksView(blocks: blocks, style: MarkdownStyle(font: font, allowsLinks: onOpen != nil), depth: 0)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                if let onOpen, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" { onOpen(url) }
                return .handled
            })
    }
}

/// Fonts and link handling shared by every block of one body.
struct MarkdownStyle {
    var font: ThemeFont
    var allowsLinks: Bool

    func headingFont(_ level: Int) -> ThemeFont {
        let size: CGFloat = switch level {
        case 1: font.size + 5
        case 2: font.size + 3
        case 3: font.size + 1.5
        default: font.size
        }
        return .system(size: size, weight: .semibold)
    }
}

/// A run of Markdown blocks (recursive through quotes and list items).
struct MarkdownBlocksView: View {
    var blocks: [MarkdownBlock]
    var style: MarkdownStyle
    var depth: Int
    @Environment(\.textScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 5) {
                Text(inline(text))
                    .scaledFont(style.headingFont(level))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if level <= 2 { ThemeDivider() }
            }
            .padding(.top, depth == 0 ? 4 : 0)
        case .paragraph(let text):
            let attributed = inline(text)
            if !attributed.characters.isEmpty {
                Text(attributed)
                    .scaledFont(style.font)
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(ordered: ordered, number: start + offset, checked: item.checked)
                        AnyView(MarkdownBlocksView(blocks: item.blocks, style: style, depth: depth + 1))
                    }
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.borderStrong)
                    .frame(width: 3)
                AnyView(MarkdownBlocksView(blocks: blocks, style: style, depth: depth + 1))
                    .opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            MarkdownCodeBlock(language: language, text: text)
        case .table(let header, let alignments, let rows):
            MarkdownTable(header: header.map(inline), alignments: alignments, rows: rows.map { $0.map(inline) }, font: style.font)
        case .rule:
            ThemeDivider().padding(.vertical, 2)
        case .hiddenComment(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "eye.slash")
                    .accessibilityHidden(true)
                Text("Hidden in the provider: \(text)")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scaledFont(.system(size: max(11, style.font.size - 1.5)))
            .foregroundStyle(Theme.textTertiary)
            .help("Providers hide HTML comments when they render this text. MergeCue shows them because hidden text can carry instructions aimed at agents.")
        }
    }

    @ViewBuilder
    private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .scaledFont(.system(size: style.font.size))
                .foregroundStyle(checked ? Theme.accent : Theme.textSecondary)
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if ordered {
            Text("\(number).")
                .scaledFont(ThemeFont(size: style.font.size, monospacedDigits: true))
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 18 * textScale, alignment: .trailing)
        } else {
            Text(depth % 2 == 0 ? "•" : "◦")
                .scaledFont(.system(size: style.font.size, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 10 * textScale)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        MarkdownInline.render(text, codeSize: style.font.size - 1, textScale: textScale, allowsLinks: style.allowsLinks)
    }
}

/// Inline Markdown through `AttributedString`, after a light pass over the HTML that descriptions often carry.
enum MarkdownInline {
    static func render(_ text: String, codeSize: CGFloat, textScale: CGFloat, allowsLinks: Bool) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let prepared = prepare(text)
        guard var attributed = try? AttributedString(markdown: prepared, options: options) else { return AttributedString(prepared) }
        for run in attributed.runs {
            if let link = run.link {
                let scheme = link.scheme?.lowercased()
                if allowsLinks, scheme == "https" || scheme == "http" {
                    attributed[run.range].foregroundColor = Theme.accentText
                    attributed[run.range].underlineStyle = .single
                } else {
                    attributed[run.range].link = nil
                }
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: (codeSize * textScale * 2).rounded() / 2, design: .monospaced)
                attributed[run.range].backgroundColor = Theme.surfaceRaised
            }
        }
        return attributed
    }

    /// `<br>` → line break, `<b>`/`<strong>`/`<i>`/`<em>`/`<code>` → Markdown, images → a link named after the alt
    /// text, other common layout tags (`details`, `summary`, `p`, `sub`, …) dropped.
    nonisolated static func prepare(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            ("<br\\s*/?>", "\n"),
            ("</?(b|strong)>", "**"),
            ("</?(i|em)>", "*"),
            ("</?code>", "`"),
            ("</?(details|summary|p|div|span|sub|sup|kbd|ins|small|center)(\\s[^>]*)?>", ""),
            ("<img\\s[^>]*alt=\"([^\"]*)\"[^>]*src=\"([^\"]+)\"[^>]*/?>", "![$1]($2)"),
            ("<img\\s[^>]*src=\"([^\"]+)\"[^>]*alt=\"([^\"]*)\"[^>]*/?>", "![$2]($1)"),
            ("<img\\s[^>]*src=\"([^\"]+)\"[^>]*/?>", "![]($1)"),
            ("!\\[\\]\\(", "![Image]("),
            ("!\\[([^\\]]*)\\]\\(", "[Image: $1]("),
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        return result.replacingOccurrences(of: "[Image: Image](", with: "[Image](")
    }
}

/// A fenced code block: horizontal scrolling, ```suggestion labelled and tinted, ```diff lines coloured.
struct MarkdownCodeBlock: View {
    var language: String
    var text: String

    var body: some View {
        let isSuggestion = language.lowercased() == "suggestion"
        let isDiff = language.lowercased() == "diff" || language.lowercased() == "patch"
        VStack(alignment: .leading, spacing: 0) {
            if isSuggestion {
                Label("Suggested change", systemImage: "chevron.left.forwardslash.chevron.right")
                    .scaledFont(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.violetText)
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
            } else if !language.isEmpty, !isDiff {
                Text(language)
                    .scaledFont(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line))
                            .scaledFont(Theme.mono)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isDiff ? Self.diffBackground(line) : .clear)
                    }
                }
                .padding(.vertical, 9)
            }
            .scrollIndicators(.never)
        }
        .clipShape(SmoothRect())
        .glassCard(tint: isSuggestion ? Theme.mint : nil)
    }

    private static func diffBackground(_ line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return Theme.diffAddedBackground }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return Theme.diffRemovedBackground }
        return .clear
    }
}

/// A GFM table: bold header row, column alignment, row dividers, horizontal scrolling when wide.
struct MarkdownTable: View {
    var header: [AttributedString]
    var alignments: [MarkdownAlignment]
    var rows: [[AttributedString]]
    var font: ThemeFont

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column, isHeader: true)
                            .gridColumnAlignment(gridAlignment(column))
                    }
                }
                .background(Theme.surfaceRaised)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, column: column, isHeader: false)
                        }
                    }
                }
            }
            .overlay(SmoothRect().strokeBorder(Theme.border))
            .clipShape(SmoothRect())
        }
        .scrollIndicators(.never)
    }

    private func gridAlignment(_ column: Int) -> HorizontalAlignment {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func cellView(_ text: AttributedString, column: Int, isHeader: Bool) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .leading
        return Text(text)
            .scaledFont(isHeader ? font.weight(.semibold) : font)
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .frame(maxWidth: 320, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}
