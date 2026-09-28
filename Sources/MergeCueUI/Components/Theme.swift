import AppKit
import MergeCueCore
import SwiftUI

/// Design tokens of MergeCue (owner mockups in `Design/mockups/`): deep navy/graphite surfaces in dark mode, a
/// cool off-white variant in light mode, the icon's cyan → blue → violet gradient for primary actions and one colour
/// per status (Needs you, Waiting for agent, AI working, Ready). Every colour is appearance-aware; views never
/// hard-code hex values.
enum Theme {
    // MARK: Surfaces

    /// Window background (behind the columns).
    static let windowBackground = Palette.windowBackground.color
    /// Sidebar column.
    static let sidebarBackground = Palette.sidebarBackground.color
    /// The content column (between sidebar and detail).
    static let contentBackground = Palette.contentBackground.color
    /// Cards and panels.
    static let surface = Palette.surface.color
    /// Nested areas inside cards (code, command fields, quotes).
    static let surfaceSunken = Palette.surfaceSunken.color
    /// Raised controls on cards (secondary buttons, segmented tracks).
    static let surfaceRaised = Palette.surfaceRaised.color
    /// Hovered rows.
    static let surfaceHover = Palette.surfaceHover.color
    /// Selected card / navigation item.
    static let surfaceSelected = Palette.surfaceSelected.color
    /// The popover body.
    static let popoverBackground = Palette.popoverBackground.color
    /// Terminal-style preview panel (dark in both appearances, like a real terminal).
    static let terminalBackground = Palette.terminalBackground.color

    /// 1 px card borders (~8 % white in dark mode; much stronger with Increase Contrast).
    static let border = Palette.border.color
    static let borderStrong = Palette.borderStrong.color
    static let divider = Palette.divider.color
    /// Boundary of buttons, fields and filter chips (≥ 3:1 against the surrounding surface).
    static let controlBorder = Palette.controlBorder.color
    /// Keyboard focus ring (full opacity, ≥ 3:1 on every surface).
    static let focusRing = Palette.focusRing.color

    // MARK: Text

    static let textPrimary = Palette.textPrimary.color
    static let textSecondary = Palette.textSecondary.color
    static let textTertiary = Palette.textTertiary.color

    // MARK: Status and brand

    /// Brand accent between the icon's cyan and violet (selection, links, focus). Use `accentText` for text.
    static let accent = Palette.accent.color
    static let cyan = Palette.cyan.color
    static let blue = Palette.blue.color
    static let violet = Palette.violet.color
    /// "Needs you" (red/pink).
    static let needs = Palette.needs.color
    /// "Waiting for agent" (amber).
    static let waiting = Palette.waiting.color
    /// "AI working" (violet → cyan).
    static let working = violet
    /// "Ready" / success (the icon's mint dot).
    static let mint = Palette.mint.color
    /// Warnings that are not errors (rate limited, unconfirmed mapping, stale).
    static let attention = waiting
    static let critical = Palette.critical.color

    /// Text in a status colour (links, chips, pills, tinted buttons): ≥ 4.5:1 on every surface and on the status tint.
    static let accentText = Palette.accentText.color
    static let cyanText = Palette.cyanText.color
    static let violetText = Palette.violetText.color
    static let needsText = Palette.needsText.color
    static let waitingText = Palette.waitingText.color
    static let attentionText = waitingText
    static let mintText = Palette.mintText.color
    static let criticalText = Palette.criticalText.color
    /// Glyphs drawn on a status fill (white in light mode, deep navy on the bright dark-mode fills).
    static let onStatusFill = Palette.onStatusFill.color

    /// Diff rows.
    static let diffAddedBackground = Palette.diffAddedBackground.color
    static let diffRemovedBackground = Palette.diffRemovedBackground.color
    static let diffAddedText = Palette.diffAddedText.color
    static let diffRemovedText = Palette.diffRemovedText.color

    /// Syntax-ish accents for code (keywords / types) — deliberately light-touch.
    static let codeKeyword = Palette.codeKeyword.color
    static let codeType = Palette.codeType.color

    /// The icon's gradient (#38C8F5 → #3B82F6 → #8B5CF6) for decoration: borders, underlines, icons.
    static let gradientStops: [Color] = Palette.brandStops.map { Color(hex: $0) }
    static let brandGradient = LinearGradient(colors: gradientStops, startPoint: .leading, endPoint: .trailing)
    static let brandGradientDiagonal = LinearGradient(colors: gradientStops, startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Fill behind white text (primary buttons): the brand hues deepened to ≥ 4.5:1 with white at every point.
    static let actionGradient = LinearGradient(colors: Palette.actionStops.map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing)
    /// Text or icon in the brand gradient on light surfaces ("✦ Fix with AI" outline button).
    static let actionTextGradient = LinearGradient(colors: [cyanText, accentText], startPoint: .leading, endPoint: .trailing)

    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: textSecondary
        case .attention: waiting
        case .critical: critical
        case .progress: violet
        case .success: mint
        }
    }

    /// Text in a tone's colour (≥ 4.5:1 on surfaces and on `tint(tone)`).
    static func textColor(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: textSecondary
        case .attention: waitingText
        case .critical: criticalText
        case .progress: violetText
        case .success: mintText
        }
    }

    /// Subtle background for chips, pills and callouts.
    static func tint(_ tone: Tone) -> Color {
        color(tone).opacity(tone == .neutral ? 0.12 : 0.14)
    }

    /// The colour of a popover / inbox section.
    static func color(_ section: PopoverSection) -> Color {
        switch section {
        case .needsYou: needs
        case .waitingForAgent: waiting
        case .aiWorking: cyan
        case .ready: mint
        }
    }

    /// Text in a section's colour.
    static func textColor(_ section: PopoverSection) -> Color {
        switch section {
        case .needsYou: needsText
        case .waitingForAgent: waitingText
        case .aiWorking: cyanText
        case .ready: mintText
        }
    }

    /// Shape cue that goes with a section's colour (Differentiate Without Color, legends).
    static func symbol(_ section: PopoverSection) -> String {
        switch section {
        case .needsYou: "exclamationmark.circle.fill"
        case .waitingForAgent: "clock.fill"
        case .aiWorking: "sparkles"
        case .ready: "checkmark.circle.fill"
        }
    }

    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        ColorToken(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha).color
    }

    static func adaptiveNSColor(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        ColorToken(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha).nsColor
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        ThemeAppearance.isDark(appearance)
    }

    // MARK: Type (scaled with Settings › General › Text size through `scaledFont(_:)`)

    /// "Good afternoon, Thiago".
    static let largeTitle = ThemeFont(size: 30, weight: .bold)
    /// Task and review headlines ("Patch ready for review").
    static let screenTitle = ThemeFont(size: 28, weight: .bold)
    static let panelTitle = ThemeFont(size: 19, weight: .semibold)
    static let cardTitle = ThemeFont(size: 15, weight: .semibold)
    static let body = ThemeFont(size: 13.5)
    static let bodyMedium = ThemeFont(size: 13.5, weight: .medium)
    static let meta = ThemeFont(size: 12.5)
    static let caption = ThemeFont(size: 11.5)
    static let mono = ThemeFont(size: 12, design: .monospaced)
    static let monoSmall = ThemeFont(size: 11.5, design: .monospaced)

    // MARK: Metrics

    static let popoverWidth: CGFloat = 440
    static let popoverMaxHeight: CGFloat = 720
    static let cornerRadius: CGFloat = 8
    static let cardRadius: CGFloat = 13
    static let controlRadius: CGFloat = 9
    static let sidebarWidth: CGFloat = 232
    /// Icon-only sidebar used when the window is narrower than `MainWindowMetrics.compactSidebarThreshold`.
    static let compactSidebarWidth: CGFloat = 76
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension View {
    /// The standard card: surface fill, 1 px subtle border, 13 pt continuous corners.
    func cardBackground(_ fill: Color = Theme.surface, radius: CGFloat = Theme.cardRadius, border: Color = Theme.border) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: 1))
    }
}

/// A grouped container with a title, used by detail panes.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, systemImage: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .scaledFont(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .scaledFont(Theme.cardTitle)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    if let trailing { trailing }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// Small capsule with a symbol and text, colored by tone.
struct Chip: View {
    var text: String
    var symbol: String?
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(1)
        }
        .scaledFont(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.textColor(tone))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Theme.tint(tone)))
    }
}

/// The persistent badge shown whenever the data is not live ("Preview data", "Demo data").
struct ModeBadge: View {
    var mode: BackendMode
    var compact = false

    var body: some View {
        if let text = mode.badgeText {
            HStack(spacing: 4) {
                Image(systemName: mode == .preview ? "eye.trianglebadge.exclamationmark" : "shippingbox")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                if !compact { Text(text) }
            }
            .scaledFont(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.waitingText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Theme.waiting.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Theme.waiting.opacity(0.6), lineWidth: 0.75))
            .help(mode.explanation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityHint(mode.explanation)
        }
    }
}

/// Initial in a muted circle (no remote avatars are loaded).
struct Avatar: View {
    var name: String
    var size: CGFloat = 22

    var body: some View {
        let initial = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            .first?.first.map { String($0).uppercased() } ?? "?"
        let palette: [Color] = [Color(hex: 0x6B5B95), Color(hex: 0x4F6D8F), Color(hex: 0x5B7A6E), Color(hex: 0x8A6A4F), Color(hex: 0x5E6478)]
        let index = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF } % palette.count
        Text(initial)
            .scaledFont(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(Circle().fill(palette[index]))
            .accessibilityHidden(true)
    }
}

/// The small app mark (the approved icon when available, otherwise a gradient glyph).
struct AppMark: View {
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = AppIconImage.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color(hex: 0x111827))
                    .overlay(Image(systemName: "forward.end.fill").scaledFont(.system(size: size * 0.5)).foregroundStyle(Theme.brandGradient))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The approved app icon: the bundle's icon inside the app, otherwise the copy shipped with MergeCueUI.
enum AppIconImage {
    static let image: NSImage? = {
        if Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app",
           let icon = NSImage(named: NSImage.applicationIconName), icon.isValid {
            return icon
        }
        return Bundle.module.image(forResource: "AppMark")
    }()
}
