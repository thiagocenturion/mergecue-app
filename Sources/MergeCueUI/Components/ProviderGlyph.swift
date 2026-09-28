import MergeCueCore
import SwiftUI

extension ProviderKind {
    /// "GitHub", "GitLab", "Bitbucket" (compact labels in cards and the sidebar).
    var shortName: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucketCloud: "Bitbucket"
        }
    }

    var brandMark: BrandMark {
        switch self {
        case .github: .github
        case .gitlab: .gitlab
        case .bitbucketCloud: .bitbucket
        }
    }
}

/// The provider's mark in its brand colour (GitHub adapts to the appearance, GitLab orange, Bitbucket blue).
struct ProviderGlyph: View {
    var kind: ProviderKind
    var size: CGFloat = 16

    var body: some View {
        BrandMarkShape(mark: kind.brandMark)
            .fill(Self.fill(kind), style: FillStyle(eoFill: false))
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.displayName)
    }

    static func fill(_ kind: ProviderKind) -> AnyShapeStyle {
        switch kind {
        case .github: AnyShapeStyle(Theme.adaptive(light: 0x0F172A, dark: 0xF5F7FB))
        case .gitlab: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFCA326), Color(hex: 0xFC6D26), Color(hex: 0xE24329)],
                                                   startPoint: .bottom, endPoint: .top))
        case .bitbucketCloud: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x2684FF), Color(hex: 0x0052CC)], startPoint: .topTrailing, endPoint: .bottomLeading))
        }
    }

    static func color(_ kind: ProviderKind) -> Color {
        switch kind {
        case .github: Theme.textPrimary
        case .gitlab: Color(hex: 0xFC6D26)
        case .bitbucketCloud: Color(hex: 0x2684FF)
        }
    }
}

/// Provider mark on a round or rounded-square badge (inbox cards: circle; popover rows: tile).
struct ProviderBadge: View {
    enum Style { case circle, tile }

    var kind: ProviderKind
    var size: CGFloat = 40
    var style: Style = .circle

    var body: some View {
        ZStack {
            switch (style, kind) {
            case (.circle, .github):
                // The GitHub mark is itself a disc with the Octocat cut out.
                ProviderGlyph(kind: .github, size: size)
            case (.circle, .bitbucketCloud):
                Circle().fill(LinearGradient(colors: [Color(hex: 0x2F8BFF), Color(hex: 0x0B5FD9)], startPoint: .top, endPoint: .bottom))
                BrandMarkShape(mark: .bitbucket).fill(.white).frame(width: size * 0.5, height: size * 0.5)
            case (.circle, .gitlab):
                Circle().fill(Theme.surfaceRaised)
                Circle().strokeBorder(Theme.border, lineWidth: 1)
                ProviderGlyph(kind: .gitlab, size: size * 0.58)
            case (.tile, _):
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Theme.adaptive(light: 0xFFFFFF, dark: 0x0E1424))
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
                ProviderGlyph(kind: kind, size: size * 0.58)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.displayName)
    }
}

/// The mark of a coding agent (Claude Code: Claude's starburst; Codex: the OpenAI mark).
struct AgentMark: View {
    var kind: AgentKind
    var size: CGFloat = 16
    /// Draws the mark in one colour (e.g. white on the gradient button).
    var monochrome: Color?

    var body: some View {
        switch kind {
        case .claudeCode:
            BrandMarkShape(mark: .claude)
                .fill(monochrome ?? Color(hex: 0xD97757))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .codex:
            BrandMarkShape(mark: .openAI)
                .fill(monochrome ?? Theme.textPrimary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

extension AgentKind {
    /// Short product name used on buttons ("Claude Code", "Codex").
    var shortName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// Provider glyph + "namespace/repo #42" in one line.
struct ChangeRequestRefLabel: View {
    var kind: ProviderKind
    var repoFullPath: String
    var number: Int
    var font: ThemeFont = .subheadline
    var glyphSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 6) {
            ProviderGlyph(kind: kind, size: glyphSize)
            Text("\(Text(repoFullPath).foregroundStyle(Theme.textSecondary)) \(Text(kind.formattedNumber(number)).fontWeight(.semibold).foregroundStyle(Theme.textPrimary))")
                .scaledFont(font)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.displayName) \(kind.changeRequestNoun) \(repoFullPath) number \(number)")
    }
}
