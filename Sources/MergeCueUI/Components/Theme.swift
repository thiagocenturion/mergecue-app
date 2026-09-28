import AppKit
import MergeCueCore
import SwiftUI

/// Colors derived from the app icon (cyan → violet, mint signal dot), used sparingly on top of system colors.
enum Theme {
    /// Brand accent between the icon's cyan and violet (buttons, selection, "AI working").
    static let accent = adaptive(light: 0x4A63F0, dark: 0x6A78FA)
    static let cyan = adaptive(light: 0x0891B2, dark: 0x3BD4F5)
    static let violet = adaptive(light: 0x7C3AED, dark: 0xA78BFA)
    /// Success / ready (the icon's mint dot).
    static let mint = adaptive(light: 0x0E9F6E, dark: 0x3EE0A1)
    static let attention = adaptive(light: 0xC2410C, dark: 0xFB923C)
    static let critical = adaptive(light: 0xDC2626, dark: 0xF87171)

    /// The icon's gradient, for the tiny app mark and progress accents.
    static let brandGradient = LinearGradient(
        colors: [Color(hex: 0x2BD9FE), Color(hex: 0x3B82F6), Color(hex: 0x8B5CF6)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .attention: attention
        case .critical: critical
        case .progress: accent
        case .success: mint
        }
    }

    /// Subtle background for chips and callouts.
    static func tint(_ tone: Tone) -> Color {
        color(tone).opacity(tone == .neutral ? 0.12 : 0.14)
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // MARK: Metrics

    static let popoverWidth: CGFloat = 380
    static let popoverMaxHeight: CGFloat = 600
    static let cornerRadius: CGFloat = 8
    static let cardRadius: CGFloat = 10
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
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 8)
                    if let trailing { trailing }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
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
        .font(.caption.weight(.medium))
        .foregroundStyle(tone == .neutral ? Color.secondary : Theme.color(tone))
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.attention)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Theme.attention.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Theme.attention.opacity(0.35), lineWidth: 0.5))
            .help(mode.explanation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityHint(mode.explanation)
        }
    }
}

/// Initials in a tinted circle (no remote avatars are loaded).
struct Avatar: View {
    var name: String
    var size: CGFloat = 22

    var body: some View {
        let initials = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            .prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let palette: [Color] = [Theme.cyan, Theme.accent, Theme.violet, Theme.mint, Theme.attention]
        let index = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF } % palette.count
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(palette[index].gradient))
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
