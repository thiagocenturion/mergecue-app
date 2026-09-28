import AppKit
import SwiftUI

/// One appearance-aware colour: a light and a dark value, each with an optional Increase Contrast variant
/// (System Settings › Accessibility › Display › Increase contrast, reported by AppKit as the
/// `accessibilityHighContrast…` appearances). Raw values stay inspectable so tests can check contrast ratios.
struct ColorToken: Sendable, Hashable {
    struct Value: Sendable, Hashable {
        var hex: UInt32
        var alpha: CGFloat = 1
    }

    var light: Value
    var dark: Value
    var lightHighContrast: Value?
    var darkHighContrast: Value?

    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1,
         lightHighContrast: UInt32? = nil, darkHighContrast: UInt32? = nil,
         lightHighContrastAlpha: CGFloat? = nil, darkHighContrastAlpha: CGFloat? = nil) {
        self.light = Value(hex: light, alpha: lightAlpha)
        self.dark = Value(hex: dark, alpha: darkAlpha)
        if lightHighContrast != nil || lightHighContrastAlpha != nil {
            self.lightHighContrast = Value(hex: lightHighContrast ?? light, alpha: lightHighContrastAlpha ?? lightAlpha)
        }
        if darkHighContrast != nil || darkHighContrastAlpha != nil {
            self.darkHighContrast = Value(hex: darkHighContrast ?? dark, alpha: darkHighContrastAlpha ?? darkAlpha)
        }
    }

    /// The value used for an appearance (Increase Contrast falls back to the regular value when not specified).
    func resolved(dark isDark: Bool, highContrast: Bool) -> Value {
        if isDark { return highContrast ? (darkHighContrast ?? dark) : dark }
        return highContrast ? (lightHighContrast ?? light) : light
    }

    var nsColor: NSColor {
        let token = self
        return NSColor(name: nil) { appearance in
            let value = token.resolved(dark: ThemeAppearance.isDark(appearance), highContrast: ThemeAppearance.isHighContrast(appearance))
            return NSColor(hex: value.hex, alpha: value.alpha)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// Appearance queries shared by the colour tokens and the menu bar icon.
enum ThemeAppearance {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                                                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                                .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark])
        return match == .darkAqua || match == .vibrantDark || match == .accessibilityHighContrastDarkAqua
            || match == .accessibilityHighContrastVibrantDark
    }

    /// True for the Increase Contrast appearances.
    static func isHighContrast(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                                                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                                                .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark])
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            || match == .accessibilityHighContrastVibrantLight || match == .accessibilityHighContrastVibrantDark
    }
}

/// WCAG 2.x relative luminance and contrast ratio (sRGB), used by tests and by `Palette` documentation.
enum Contrast {
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    static func ratio(_ lhs: UInt32, _ rhs: UInt32) -> Double {
        let (a, b) = (luminance(lhs), luminance(rhs))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `foreground` at `alpha` composited over the opaque `background`.
    static func composite(_ foreground: UInt32, alpha: CGFloat, over background: UInt32) -> UInt32 {
        var out: UInt32 = 0
        for shift in [UInt32(16), 8, 0] {
            let f = Double((foreground >> shift) & 0xFF), b = Double((background >> shift) & 0xFF)
            out |= UInt32((f * Double(alpha) + b * (1 - Double(alpha))).rounded()) << shift
        }
        return out
    }

    /// A colour between `a` (t = 0) and `b` (t = 1), interpolated in sRGB like SwiftUI gradients.
    static func interpolate(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        composite(b, alpha: CGFloat(t), over: a)
    }
}

/// The raw colour values behind `Theme` (owner mockups in `Design/mockups/`). Text tokens meet WCAG AA (4.5:1) on
/// every surface they are drawn on — including the 14 % status tints of chips and pills — and control boundaries
/// and the focus ring meet 3:1 (`ContrastTests` checks every pair). Status fills (dots, glyph circles, borders)
/// keep the brighter mockup colours; text in a status colour uses the `…Text` variants.
enum Palette {
    // MARK: Surfaces
    static let windowBackground = ColorToken(light: 0xF3F5FA, dark: 0x0B1020)
    static let sidebarBackground = ColorToken(light: 0xE9EDF5, dark: 0x0D1324)
    static let contentBackground = ColorToken(light: 0xF3F5FA, dark: 0x0F1629)
    static let surface = ColorToken(light: 0xFFFFFF, dark: 0x141B2D)
    static let surfaceSunken = ColorToken(light: 0xF5F7FB, dark: 0x0F1526)
    static let surfaceRaised = ColorToken(light: 0xF1F4F9, dark: 0x1A2236)
    static let surfaceHover = ColorToken(light: 0xEEF2F8, dark: 0x192136)
    static let surfaceSelected = ColorToken(light: 0xE8F0FF, dark: 0x16224A)
    static let popoverBackground = ColorToken(light: 0xF7F8FC, dark: 0x111728)
    /// The change request panel next to the inbox list.
    static let panel = ColorToken(light: 0xFFFFFF, dark: 0x10172A)
    static let terminalBackground = ColorToken(light: 0x0F1424, dark: 0x0A0F1C)

    /// Every opaque surface text can be drawn on (tests iterate over these).
    static let surfaces: [(String, ColorToken)] = [
        ("windowBackground", windowBackground), ("sidebarBackground", sidebarBackground), ("contentBackground", contentBackground),
        ("surface", surface), ("surfaceSunken", surfaceSunken), ("surfaceRaised", surfaceRaised), ("surfaceHover", surfaceHover),
        ("surfaceSelected", surfaceSelected), ("popoverBackground", popoverBackground), ("panel", panel),
    ]
    /// Surfaces that carry chips, pills, tinted buttons and callouts (status tints are composited over these).
    static let tintedSurfaces: [(String, ColorToken)] = [
        ("surface", surface), ("popoverBackground", popoverBackground), ("contentBackground", contentBackground),
        ("windowBackground", windowBackground), ("surfaceSunken", surfaceSunken),
    ]
    /// Surfaces next to bordered controls (buttons, search fields, filter chips).
    static let controlSurfaces: [(String, ColorToken)] = [
        ("surface", surface), ("popoverBackground", popoverBackground), ("contentBackground", contentBackground),
        ("windowBackground", windowBackground), ("surfaceSelected", surfaceSelected),
    ]

    // MARK: Lines
    static let border = ColorToken(light: 0x0F172A, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08,
                                   lightHighContrastAlpha: 0.42, darkHighContrastAlpha: 0.42)
    static let borderStrong = ColorToken(light: 0x0F172A, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.14,
                                         lightHighContrastAlpha: 0.55, darkHighContrastAlpha: 0.55)
    static let divider = ColorToken(light: 0x0F172A, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.07,
                                    lightHighContrastAlpha: 0.35, darkHighContrastAlpha: 0.35)
    /// Boundary of interactive controls (buttons, fields, filter chips): ≥ 3:1 against the surfaces around them.
    static let controlBorder = ColorToken(light: 0x7F889B, dark: 0x677189, lightHighContrast: 0x4A5366, darkHighContrast: 0x9AA3B8)

    // MARK: Text
    static let textPrimary = ColorToken(light: 0x0F172A, dark: 0xF3F5FA, lightHighContrast: 0x000000, darkHighContrast: 0xFFFFFF)
    static let textSecondary = ColorToken(light: 0x566074, dark: 0xA3ACBF, lightHighContrast: 0x3A4252, darkHighContrast: 0xCDD3DF)
    static let textTertiary = ColorToken(light: 0x5F677A, dark: 0x8A93A8, lightHighContrast: 0x474F60, darkHighContrast: 0xB7BECC)

    // MARK: Status and brand (fills, dots, borders, icons)
    static let accent = ColorToken(light: 0x2F6BF0, dark: 0x4C8DFF)
    static let cyan = ColorToken(light: 0x0891B2, dark: 0x38C8F5)
    static let blue = ColorToken(light: 0x2563EB, dark: 0x3B82F6)
    static let violet = ColorToken(light: 0x7C3AED, dark: 0x9B7BFA)
    static let needs = ColorToken(light: 0xE03A5C, dark: 0xF0506E)
    static let waiting = ColorToken(light: 0xB7700B, dark: 0xF5B544)
    static let mint = ColorToken(light: 0x0B9A73, dark: 0x3FE6B4)
    static let critical = ColorToken(light: 0xDC2F4D, dark: 0xF0506E)

    // MARK: Status text (≥ 4.5:1 on every surface and on the status's own tint)
    static let accentText = ColorToken(light: 0x1154EA, dark: 0x5492FF, lightHighContrast: 0x0B3FB8, darkHighContrast: 0x86B2FF)
    static let cyanText = ColorToken(light: 0x066D86, dark: 0x38C8F5, lightHighContrast: 0x04566A)
    static let violetText = ColorToken(light: 0x7530EC, dark: 0x9E7FFA, lightHighContrast: 0x5A1BC4, darkHighContrast: 0xBBA5FC)
    static let needsText = ColorToken(light: 0xBE1E3F, dark: 0xF15D79, lightHighContrast: 0x991533, darkHighContrast: 0xF78CA0)
    static let waitingText = ColorToken(light: 0x8F5809, dark: 0xF5B544, lightHighContrast: 0x6E4306)
    static let mintText = ColorToken(light: 0x087255, dark: 0x3FE6B4, lightHighContrast: 0x055A42)
    static let criticalText = ColorToken(light: 0xBC203B, dark: 0xF15D79, lightHighContrast: 0x991533, darkHighContrast: 0xF78CA0)

    /// Each status fill with its text variant (tests check the text on the fill's tint).
    static let statusPairs: [(name: String, fill: ColorToken, text: ColorToken)] = [
        ("accent", accent, accentText), ("cyan", cyan, cyanText), ("violet", violet, violetText), ("needs", needs, needsText),
        ("waiting", waiting, waitingText), ("mint", mint, mintText), ("critical", critical, criticalText),
    ]

    /// Glyph drawn on a status fill (StatusGlyph): white on the deeper light-mode fills, deep navy on the bright
    /// dark-mode fills (white on #3FE6B4 was 1.6:1).
    static let onStatusFill = ColorToken(light: 0xFFFFFF, dark: 0x0B1020)
    /// The full-opacity keyboard focus ring (≥ 3:1 against every surface).
    static let focusRing = ColorToken(light: 0x1154EA, dark: 0x5492FF, lightHighContrast: 0x0B3FB8, darkHighContrast: 0x86B2FF)

    // MARK: Diff and code
    static let diffAddedBackground = ColorToken(light: 0x0B9A73, dark: 0x1FAF7A, lightAlpha: 0.12, darkAlpha: 0.20)
    static let diffRemovedBackground = ColorToken(light: 0xDC2F4D, dark: 0xC7384F, lightAlpha: 0.10, darkAlpha: 0.26)
    static let diffAddedText = ColorToken(light: 0x066C50, dark: 0x6BF0C0)
    static let diffRemovedText = ColorToken(light: 0xB42340, dark: 0xFF8FA3)
    static let codeKeyword = ColorToken(light: 0x7C3AED, dark: 0xC792EA)
    static let codeType = ColorToken(light: 0x0E7490, dark: 0x82AAFF)

    // MARK: Gradients
    /// The icon's cyan → blue → violet, for decoration only (borders, underlines, icons): #38C8F5 → #3B82F6 → #8B5CF6.
    static let brandStops: [UInt32] = [0x38C8F5, 0x3B82F6, 0x8B5CF6]
    /// The same hues deepened until white text reaches 4.5:1 at every point: fills behind text (primary buttons,
    /// the "Fix with AI" split button). White on the old stops was 1.95 / 3.68 / 4.23:1.
    static let actionStops: [UInt32] = [0x087EA3, 0x1B6DF5, 0x8452F5]
    /// Selected filter chip fill (white text).
    static let selectedChipStops: [UInt32] = [0x2B6DF0, 0x2456C9]
}
