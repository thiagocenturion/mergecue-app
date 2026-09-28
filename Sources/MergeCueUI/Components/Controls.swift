import SwiftUI

// MARK: - Buttons

/// Size of the MergeCue button styles. Heights are minimums: larger text (Settings › General › Text size) grows
/// the control instead of clipping its label.
enum ButtonSize {
    case small, compact, regular, tall, large

    var font: ThemeFont {
        switch self {
        case .small: .system(size: 12.5, weight: .semibold)
        case .compact: .system(size: 12.5, weight: .semibold)
        case .regular: .system(size: 13.5, weight: .semibold)
        case .tall: .system(size: 14.5, weight: .semibold)
        case .large: .system(size: 16, weight: .semibold)
        }
    }

    var height: CGFloat {
        switch self {
        case .small: 30
        case .compact: 34
        case .regular: 36
        case .tall: 46
        case .large: 50
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: 12
        case .compact: 11
        case .regular: 16
        case .tall: 16
        case .large: 22
        }
    }

    /// Vertical padding that only matters once scaled text is taller than `height`.
    var verticalPadding: CGFloat { 5 }
}

/// Primary action: the text-safe brand gradient (#087EA3 → #1B6DF5 → #8452F5, ≥ 4.5:1 with white) with white text.
struct GradientButtonStyle: ButtonStyle {
    var size: ButtonSize = .regular
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius + (size == .large ? 2 : 0), style: .continuous)
        configuration.label
            .scaledFont(size.font)
            .foregroundStyle(isEnabled ? Color.white : Theme.textSecondary)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(minHeight: size.height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(shape.fill(isEnabled ? AnyShapeStyle(Theme.actionGradient) : AnyShapeStyle(Theme.surfaceRaised)))
            .overlay(shape.strokeBorder(isEnabled ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(Theme.controlBorder), lineWidth: 1))
            .shadow(color: Color(hex: 0x3B82F6).opacity(isEnabled ? 0.28 : 0), radius: 10, y: 3)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(shape)
    }
}

/// Secondary action: a filled neutral control with a visible (≥ 3:1) boundary.
struct SecondaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .regular
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        configuration.label
            .scaledFont(size.font)
            .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(minHeight: size.height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(shape.fill(configuration.isPressed ? Theme.surfaceHover : Theme.surfaceRaised))
            .overlay(shape.strokeBorder(Theme.controlBorder.opacity(isEnabled ? 1 : 0.5), lineWidth: 1))
            .contentShape(shape)
    }
}

/// Outlined gradient action ("✦ Fix with AI" in the popover): tinted fill, gradient border and text-safe gradient text.
struct OutlinedGradientButtonStyle: ButtonStyle {
    var size: ButtonSize = .small
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        configuration.label
            .scaledFont(size.font)
            .foregroundStyle(isEnabled ? AnyShapeStyle(Theme.actionTextGradient) : AnyShapeStyle(Theme.textSecondary))
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(minHeight: size.height)
            .background(shape.fill(Theme.blue.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .overlay(shape.strokeBorder(Theme.brandGradient, lineWidth: 1.2).opacity(isEnabled ? 1 : 0.4))
            .contentShape(shape)
    }
}

/// Tinted outline ("Review patch" in mint): the status colour for the border and fill, its text variant for the label.
struct TintedOutlineButtonStyle: ButtonStyle {
    var color: Color
    var textColor: Color
    var size: ButtonSize = .small

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        configuration.label
            .scaledFont(size.font)
            .foregroundStyle(textColor)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(minHeight: size.height)
            .background(shape.fill(color.opacity(configuration.isPressed ? 0.2 : 0.09)))
            .overlay(shape.strokeBorder(color, lineWidth: 1.1))
            .contentShape(shape)
    }
}

/// Square icon button (external link, •••, copy).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var filled = true
    @Environment(\.textScale) private var textScale

    func makeBody(configuration: Configuration) -> some View {
        let side = size * max(1, textScale)
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        configuration.label
            .scaledFont(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: side, height: side)
            .background(shape.fill(filled ? (configuration.isPressed ? Theme.surfaceHover : Theme.surfaceRaised) : (configuration.isPressed ? Theme.surfaceHover : .clear)))
            .overlay(shape.strokeBorder(filled ? Theme.controlBorder : .clear, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Plain text/icon button that highlights on press (sidebar rows, footers).
struct PlainRowButtonStyle: ButtonStyle {
    /// Corner radius of the hit and focus shape (the system keyboard focus ring follows it).
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The four-point sparkle used on AI actions.
struct SparkleIcon: View {
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: "sparkle")
            .scaledFont(.system(size: size, weight: .semibold))
            .accessibilityHidden(true)
    }
}

// MARK: - Pills, badges, dots

/// Capsule status pill: text in the status's text colour, tinted fill and border, optional dot or symbol
/// ("● Ready", "Waiting for agent"). With Differentiate Without Color the dot becomes `cueSymbol`.
struct StatusPill: View {
    var text: String
    var color: Color
    /// Label colour; pass the status's `…Text` token (defaults to `Theme.textPrimary`).
    var textColor: Color = Theme.textPrimary
    var symbol: String?
    var showsDot = false
    var size: CGFloat = 12.5
    /// Symbol shown instead of the dot when the user asked to differentiate without colour.
    var cueSymbol: String = "circle.fill"
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                if differentiateWithoutColor {
                    Image(systemName: cueSymbol)
                        .scaledFont(.system(size: size * 0.8, weight: .semibold))
                        .foregroundStyle(color)
                } else {
                    Circle().fill(color).frame(width: size * 0.6, height: size * 0.6)
                }
            }
            if let symbol {
                Image(systemName: symbol)
                    .scaledFont(.system(size: size, weight: .semibold))
            }
            Text(text)
                .scaledFont(.system(size: size, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, size * 0.85)
        .padding(.vertical, size * 0.38)
        .background(Capsule().fill(color.opacity(0.13)))
        .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Rounded count badge ("3" next to Inbox).
struct CountBadge: View {
    var count: Int
    var highlighted = false

    var body: some View {
        Text("\(count)")
            .scaledFont(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(highlighted ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Theme.accent.opacity(0.28) : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// A coloured status glyph in a small filled circle ("!" for Needs you, "✓" for Ready). The glyph is white on the
/// light-mode fills and deep navy on the bright dark-mode fills (≥ 3:1 either way).
struct StatusGlyph: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 18
    @Environment(\.textScale) private var textScale

    var body: some View {
        let side = size * textScale
        Image(systemName: symbol)
            .font(.system(size: side * 0.55, weight: .heavy))
            .foregroundStyle(Theme.onStatusFill)
            .frame(width: side, height: side)
            .background(Circle().fill(color))
            .accessibilityHidden(true)
    }
}

/// A thin circular progress ring (AI working). Spins in the app; static in snapshots and with Reduce Motion.
struct WorkingSpinner: View {
    var size: CGFloat = 26
    @State private var rotation: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(AngularGradient(colors: [Theme.violet.opacity(0.1), Theme.violet, Theme.cyan], center: .center),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? 0 : rotation))
        }
        .frame(width: size, height: size)
        .onAppear { startSpinning() }
        .onChange(of: reduceMotion) { _, _ in startSpinning() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In progress")
    }

    private func startSpinning() {
        guard !reduceMotion else {
            rotation = 0
            return
        }
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { rotation = 360 }
    }
}

/// A section's coloured dot, or its symbol when the user asked to differentiate without colour.
struct SectionMarker: View {
    var section: PopoverSection
    var size: CGFloat = 10
    var glow = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Group {
            if differentiateWithoutColor {
                Image(systemName: Theme.symbol(section))
                    .scaledFont(.system(size: size * 1.2, weight: .semibold))
                    .foregroundStyle(Theme.color(section))
            } else {
                Circle()
                    .fill(Theme.color(section))
                    .frame(width: size, height: size)
                    .shadow(color: glow ? Theme.color(section).opacity(0.5) : .clear, radius: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Segmented controls and tabs

/// Capsule filter chips ("All", "Mine", "Reviewing").
struct FilterChips<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .scaledFont(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                        .padding(.horizontal, isSelected ? 22 : 18)
                        .padding(.vertical, 4)
                        .frame(minHeight: 32)
                        .background(Capsule().fill(isSelected ? AnyShapeStyle(LinearGradient(colors: Palette.selectedChipStops.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Theme.surfaceRaised)))
                        .overlay(Capsule().strokeBorder(isSelected ? Color(hex: 0x69A2FF).opacity(0.9) : Theme.controlBorder, lineWidth: 1))
                        .shadow(color: isSelected ? Color(hex: 0x3B82F6).opacity(0.35) : .clear, radius: 8)
                }
                .buttonStyle(PlainRowButtonStyle(cornerRadius: 16))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}

/// A segmented track with a highlighted selection (agent picker, Changes / Tests / Reply).
struct SegmentedTrack<Value: Hashable, Label: View>: View {
    var options: [Value]
    @Binding var selection: Value
    var height: CGFloat = 34
    var equalWidths = true
    @ViewBuilder var label: (Value, Bool) -> Label

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    label(option, isSelected)
                        .frame(maxWidth: equalWidths ? .infinity : nil)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .frame(minHeight: height)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                .fill(isSelected ? Theme.surfaceSelected : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                .strokeBorder(isSelected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.clear), lineWidth: 1.2)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainRowButtonStyle())
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius + 3, style: .continuous).fill(Theme.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius + 3, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Underlined tabs (Conversation / Files / Checks / Timeline).
struct UnderlineTabs<Value: Hashable>: View {
    var options: [(Value, String, Int?)]
    @Binding var selection: Value

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let isSelected = option.0 == selection
                    Button {
                        selection = option.0
                    } label: {
                        VStack(spacing: 9) {
                            HStack(spacing: 7) {
                                Text(option.1)
                                    .scaledFont(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                                if let count = option.2 {
                                    CountBadge(count: count)
                                }
                            }
                            .padding(.horizontal, 2)
                            Capsule()
                                .fill(isSelected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.clear))
                                .frame(height: 2.5)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(PlainRowButtonStyle())
                    .accessibilityLabel(option.2.map { "\(option.1), \($0)" } ?? option.1)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

// MARK: - Search

/// Rounded search field with a magnifying glass and a ⌘K hint.
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var showsShortcut = false
    var focus: FocusState<Bool>.Binding?

    @FocusState private var ownFocus: Bool

    private var isFieldFocused: Bool { focus?.wrappedValue ?? ownFocus }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius + 1, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else if showsShortcut {
                HStack(spacing: 3) {
                    KeyCap("⌘")
                    KeyCap("K")
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background(shape.fill(Theme.surfaceRaised))
        .overlay(shape.strokeBorder(Theme.controlBorder, lineWidth: 1))
        .overlay {
            if isFieldFocused {
                shape.inset(by: -3).strokeBorder(Theme.focusRing, lineWidth: 2).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let base = TextField("Search", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textSecondary))
            .textFieldStyle(.plain)
            .scaledFont(.system(size: 13.5))
            .foregroundStyle(Theme.textPrimary)
        if let focus {
            base.focused(focus)
        } else {
            base.focused($ownFocus)
        }
    }
}

struct KeyCap: View {
    var key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .scaledFont(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Thin horizontal divider in the theme colour.
struct ThemeDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }
}

/// A compact pull-down used by filter bars.
struct FilterMenu<Content: View>: View {
    var title: String
    var isActive: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").scaledFont(.system(size: 9, weight: .semibold))
            }
            .scaledFont(.system(size: 12, weight: .medium))
            .foregroundStyle(isActive ? Theme.accentText : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(minHeight: 26)
            .background(Capsule().fill(isActive ? Theme.accent.opacity(0.12) : Theme.surfaceRaised))
            .overlay(Capsule().strokeBorder(isActive ? Theme.accent : Theme.controlBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(title) filter")
    }
}
