import SwiftUI

// MARK: - Buttons

/// Size of the MergeCue button styles.
enum ButtonSize {
    case small, compact, regular, tall, large

    var font: Font {
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
}

/// Primary action: the brand gradient (#38C8F5 → #3B82F6 → #8B5CF6) with white text.
struct GradientButtonStyle: ButtonStyle {
    var size: ButtonSize = .regular
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.7))
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius + (size == .large ? 2 : 0), style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.textTertiary.opacity(0.45)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius + (size == .large ? 2 : 0), style: .continuous)
                    .strokeBorder(.white.opacity(isEnabled ? 0.22 : 0.08), lineWidth: 1)
            )
            .shadow(color: Color(hex: 0x3B82F6).opacity(isEnabled ? 0.28 : 0), radius: 10, y: 3)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }
}

/// Secondary action: a filled neutral control with a subtle border.
struct SecondaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .regular
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(configuration.isPressed ? Theme.surfaceHover : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(Theme.borderStrong, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }
}

/// Outlined gradient action ("✦ Fix with AI" in the popover): dark fill, gradient border and text.
struct OutlinedGradientButtonStyle: ButtonStyle {
    var size: ButtonSize = .small
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(isEnabled ? AnyShapeStyle(LinearGradient(colors: [Theme.cyan, Color(hex: 0x6E8BFF)], startPoint: .leading, endPoint: .trailing))
                                       : AnyShapeStyle(Theme.textTertiary))
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(Theme.blue.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(Theme.brandGradient, lineWidth: 1.2).opacity(isEnabled ? 1 : 0.4))
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }
}

/// Tinted outline ("Review patch" in mint).
struct TintedOutlineButtonStyle: ButtonStyle {
    var color: Color
    var size: ButtonSize = .small

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(color)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(color.opacity(configuration.isPressed ? 0.2 : 0.09)))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(color.opacity(0.75), lineWidth: 1.1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }
}

/// Square icon button (external link, •••, copy).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(filled ? (configuration.isPressed ? Theme.surfaceHover : Theme.surfaceRaised) : (configuration.isPressed ? Theme.surfaceHover : .clear)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(filled ? Theme.border : .clear, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Plain text/icon button that highlights on press (sidebar rows, footers).
struct PlainRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The four-point sparkle used on AI actions.
struct SparkleIcon: View {
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
            .accessibilityHidden(true)
    }
}

// MARK: - Pills, badges, dots

/// Capsule status pill: coloured text, tinted fill and border, optional dot or symbol ("● Ready", "Waiting for agent").
struct StatusPill: View {
    var text: String
    var color: Color
    var symbol: String?
    var showsDot = false
    var size: CGFloat = 12.5

    var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                Circle().fill(color).frame(width: size * 0.6, height: size * 0.6)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
            }
            Text(text)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
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
            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(highlighted ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Theme.accent.opacity(0.28) : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// A coloured status glyph in a small filled circle ("!" for Needs you, "✓" for Ready).
struct StatusGlyph: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .accessibilityHidden(true)
    }
}

/// A thin circular progress ring (AI working). Static in snapshots, spinning in the app.
struct WorkingSpinner: View {
    var size: CGFloat = 26
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(AngularGradient(colors: [Theme.violet.opacity(0.1), Theme.violet, Theme.cyan], center: .center),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { rotation = 360 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In progress")
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
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                        .padding(.horizontal, isSelected ? 22 : 18)
                        .frame(height: 32)
                        .background(Capsule().fill(isSelected ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x2E6FF0), Color(hex: 0x2456C9)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Theme.surfaceRaised)))
                        .overlay(Capsule().strokeBorder(isSelected ? Color(hex: 0x69A2FF).opacity(0.9) : Theme.borderStrong, lineWidth: 1))
                        .shadow(color: isSelected ? Color(hex: 0x3B82F6).opacity(0.35) : .clear, radius: 8)
                }
                .buttonStyle(PlainRowButtonStyle())
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
                        .frame(height: height)
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
                                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
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
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius + 1, style: .continuous).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius + 1, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
    }

    @ViewBuilder
    private var field: some View {
        let base = TextField("Search", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textSecondary))
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.textPrimary)
        if let focus {
            base.focused(focus)
        } else {
            base
        }
    }
}

struct KeyCap: View {
    var key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .medium))
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
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(isActive ? Theme.accent.opacity(0.12) : Theme.surfaceRaised))
            .overlay(Capsule().strokeBorder(isActive ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(title) filter")
    }
}
