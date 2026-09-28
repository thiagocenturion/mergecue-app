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
    static let windowBackground = adaptive(light: 0xF3F5FA, dark: 0x0B1020)
    /// Sidebar column.
    static let sidebarBackground = adaptive(light: 0xE9EDF5, dark: 0x0D1324)
    /// The content column (between sidebar and detail).
    static let contentBackground = adaptive(light: 0xF3F5FA, dark: 0x0F1629)
    /// Cards and panels.
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x141B2D)
    /// Nested areas inside cards (code, command fields, quotes).
    static let surfaceSunken = adaptive(light: 0xF5F7FB, dark: 0x0F1526)
    /// Raised controls on cards (secondary buttons, segmented tracks).
    static let surfaceRaised = adaptive(light: 0xF1F4F9, dark: 0x1A2236)
    /// Hovered rows.
    static let surfaceHover = adaptive(light: 0xEEF2F8, dark: 0x192136)
    /// Selected card / navigation item.
    static let surfaceSelected = adaptive(light: 0xE8F0FF, dark: 0x16224A)
    /// The popover body.
    static let popoverBackground = adaptive(light: 0xF7F8FC, dark: 0x111728)
    /// Terminal-style preview panel (dark in both appearances, like a real terminal).
    static let terminalBackground = adaptive(light: 0x0F1424, dark: 0x0A0F1C)

    /// 1 px card borders (~8 % white in dark mode).
    static let border = adaptive(light: 0x0F172A, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08)
    static let borderStrong = adaptive(light: 0x0F172A, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.14)
    static let divider = adaptive(light: 0x0F172A, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.07)

    // MARK: Text

    static let textPrimary = adaptive(light: 0x0F172A, dark: 0xF3F5FA)
    static let textSecondary = adaptive(light: 0x566074, dark: 0xA3ACBF)
    static let textTertiary = adaptive(light: 0x8891A3, dark: 0x6E778C)

    // MARK: Status and brand

    /// Brand accent between the icon's cyan and violet (selection, links, focus).
    static let accent = adaptive(light: 0x2F6BF0, dark: 0x4C8DFF)
    static let cyan = adaptive(light: 0x0891B2, dark: 0x38C8F5)
    static let blue = adaptive(light: 0x2563EB, dark: 0x3B82F6)
    static let violet = adaptive(light: 0x7C3AED, dark: 0x9B7BFA)
    /// "Needs you" (red/pink).
    static let needs = adaptive(light: 0xE03A5C, dark: 0xF0506E)
    /// "Waiting for agent" (amber).
    static let waiting = adaptive(light: 0xB7700B, dark: 0xF5B544)
    /// "AI working" (violet → cyan).
    static let working = violet
    /// "Ready" / success (the icon's mint dot).
    static let mint = adaptive(light: 0x0B9A73, dark: 0x3FE6B4)
    /// Warnings that are not errors (rate limited, unconfirmed mapping, stale).
    static let attention = waiting
    static let critical = adaptive(light: 0xDC2F4D, dark: 0xF0506E)

    /// Diff rows.
    static let diffAddedBackground = adaptive(light: 0x0B9A73, dark: 0x1FAF7A, lightAlpha: 0.12, darkAlpha: 0.20)
    static let diffRemovedBackground = adaptive(light: 0xDC2F4D, dark: 0xC7384F, lightAlpha: 0.10, darkAlpha: 0.26)
    static let diffAddedText = adaptive(light: 0x08785A, dark: 0x6BF0C0)
    static let diffRemovedText = adaptive(light: 0xB42340, dark: 0xFF8FA3)

    /// Syntax-ish accents for code (keywords / types) — deliberately light-touch.
    static let codeKeyword = adaptive(light: 0x7C3AED, dark: 0xC792EA)
    static let codeType = adaptive(light: 0x0E7490, dark: 0x82AAFF)

    /// Primary action gradient (#38C8F5 → #3B82F6 → #8B5CF6).
    static let gradientStops: [Color] = [Color(hex: 0x38C8F5), Color(hex: 0x3B82F6), Color(hex: 0x8B5CF6)]
    static let brandGradient = LinearGradient(colors: gradientStops, startPoint: .leading, endPoint: .trailing)
    static let brandGradientDiagonal = LinearGradient(colors: gradientStops, startPoint: .topLeading, endPoint: .bottomTrailing)

    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: textSecondary
        case .attention: waiting
        case .critical: critical
        case .progress: violet
        case .success: mint
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

    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static func adaptiveNSColor(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
    }

    // MARK: Type

    /// "Good afternoon, Thiago".
    static let largeTitle = Font.system(size: 30, weight: .bold)
    /// Task and review headlines ("Patch ready for review").
    static let screenTitle = Font.system(size: 28, weight: .bold)
    static let panelTitle = Font.system(size: 19, weight: .semibold)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13.5)
    static let bodyMedium = Font.system(size: 13.5, weight: .medium)
    static let meta = Font.system(size: 12.5)
    static let caption = Font.system(size: 11.5)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11.5, design: .monospaced)

    // MARK: Metrics

    static let popoverWidth: CGFloat = 440
    static let popoverMaxHeight: CGFloat = 720
    static let cornerRadius: CGFloat = 8
    static let cardRadius: CGFloat = 13
    static let controlRadius: CGFloat = 9
    static let sidebarWidth: CGFloat = 232
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
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(Theme.cardTitle)
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
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.color(tone))
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
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.waiting)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Theme.waiting.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Theme.waiting.opacity(0.35), lineWidth: 0.75))
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
            .font(.system(size: size * 0.46, weight: .semibold))
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
                    .overlay(Image(systemName: "forward.end.fill").font(.system(size: size * 0.5)).foregroundStyle(Theme.brandGradient))
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
