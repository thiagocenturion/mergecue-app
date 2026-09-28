import SwiftUI

/// MergeCue's text size setting (Settings › General › Text size).
///
/// macOS has no system-wide Dynamic Type for Mac apps: SwiftUI on macOS renders `.body`, `Font.system(size:)` and
/// `@ScaledMetric` at fixed sizes whatever `dynamicTypeSize` says. MergeCue therefore scales text itself: the window
/// and popover roots apply `.dynamicTypeSize(preference.dynamicTypeSize)`, and every font goes through
/// `scaledFont(_:)`, which multiplies the token's point size by `Theme.textScale(for:)`. Layouts use minimum heights
/// so larger text grows its controls instead of clipping.
public nonisolated enum TextSizePreference: String, Sendable, Hashable, CaseIterable, Identifiable {
    case standard, large, larger

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Default"
        case .large: "Large"
        case .larger: "Larger"
        }
    }

    /// The Dynamic Type size applied at the window and popover roots.
    public var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .standard: .large
        case .large: .xLarge
        case .larger: .xxLarge
        }
    }
}

extension Theme {
    /// Multiplier for point sizes at a Dynamic Type size (`.large`, the default, is 1).
    nonisolated static func textScale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.85
        case .small: 0.9
        case .medium: 0.95
        case .large: 1
        case .xLarge: 1.15
        case .xxLarge: 1.3
        case .xxxLarge: 1.45
        default: 1.6 // accessibility sizes
        }
    }
}

extension EnvironmentValues {
    /// `Theme.textScale(for: dynamicTypeSize)`: multiply fixed metrics (icon circles, row heights) by it.
    var textScale: CGFloat { Theme.textScale(for: dynamicTypeSize) }
}

/// A font token: point size, weight and design at the default text size. Rendered by `scaledFont(_:)`, which
/// scales it with the text size setting. The static members mirror the macOS text styles' default sizes.
struct ThemeFont: Sendable, Hashable {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    var monospacedDigits = false

    /// The SwiftUI font at `scale` (sizes round to the nearest half point).
    func font(scale: CGFloat = 1) -> Font {
        let font = Font.system(size: (size * scale * 2).rounded() / 2, weight: weight, design: design)
        return monospacedDigits ? font.monospacedDigit() : font
    }

    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> ThemeFont {
        ThemeFont(size: size, weight: weight, design: design)
    }

    static func system(_ style: ThemeFont, design: Font.Design) -> ThemeFont {
        var copy = style
        copy.design = design
        return copy
    }

    func weight(_ weight: Font.Weight) -> ThemeFont {
        var copy = self
        copy.weight = weight
        return copy
    }

    func monospaced() -> ThemeFont {
        var copy = self
        copy.design = .monospaced
        return copy
    }

    func monospacedDigit() -> ThemeFont {
        var copy = self
        copy.monospacedDigits = true
        return copy
    }

    // macOS text style sizes (NSFont.preferredFont(forTextStyle:)).
    static let largeTitle = ThemeFont(size: 26)
    static let title = ThemeFont(size: 22)
    static let title2 = ThemeFont(size: 17)
    static let title3 = ThemeFont(size: 15)
    static let headline = ThemeFont(size: 13, weight: .bold)
    static let subheadline = ThemeFont(size: 11)
    static let body = ThemeFont(size: 13)
    static let callout = ThemeFont(size: 12)
    static let footnote = ThemeFont(size: 10)
    static let caption = ThemeFont(size: 10)
    static let caption2 = ThemeFont(size: 10, weight: .medium)
}

/// Applies a `ThemeFont` at the environment's text scale.
struct ScaledFontModifier: ViewModifier {
    var token: ThemeFont
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(token.font(scale: Theme.textScale(for: dynamicTypeSize)))
    }
}

extension View {
    /// Sets the font from a token, scaled with Settings › General › Text size.
    func scaledFont(_ token: ThemeFont) -> some View {
        modifier(ScaledFontModifier(token: token))
    }
}
