import SwiftUI

// CardView and its styles, ported from Calculus (UIComponents/Styles/CardViewStyle, D43): the same Liquid Glass card
// (`.glassEffect(.regular[.interactive()], in: 32 pt rect)`), the same press feedback (scale 1.04, brightness +0.05,
// spring) through a transparent overlay button, and the same flat fallback where glass is unavailable. macOS
// adaptations: availability is macOS 26, hover lifts the card (iOS's `.hoverEffect(.lift)`), the fallback uses
// MergeCue's surface colour, and offscreen snapshots (`glassEffectsEnabled` off) use the fallback.

/// A card: content on Liquid Glass with 32 pt corners. With an `action` the whole card is a button.
struct CardView: View {
    var action: (() -> Void)?
    let content: () -> any View
    /// A style given at the call site wins over the environment and does not leak into nested cards.
    private let explicitStyle: (any CardViewStyle)?

    @Environment(\.cardViewStyle) private var style
    @Environment(\.glassEffectsEnabled) private var glassEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var isHovering = false

    init(action: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> any View) {
        self.action = action
        self.content = content
        self.explicitStyle = nil
    }

    init(style: some CardViewStyle, action: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> any View) {
        self.action = action
        self.content = content
        self.explicitStyle = style
    }

    var body: some View {
        if action != nil {
            // The tap target is a transparent button OVERLAY, not a wrapper: glass sits above the content in
            // hit-testing order and swallows clicks when the styled card is a Button label.
            cardContent
                .scaleEffect(isPressed && !reduceMotion ? 1.04 : isHovering && !reduceMotion ? 1.01 : 1)
                .brightness(isPressed ? 0.05 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0.1), value: isPressed)
                .animation(Motion.hover, value: isHovering)
                .overlay {
                    Button {
                        action?()
                    } label: {
                        Color.clear.contentShape(SmoothRect())
                    }
                    .buttonStyle(PressReportingButtonStyle(isPressed: $isPressed))
                    .accessibilityHidden(true)
                }
                .onHover { isHovering = $0 }
                // The overlay button is invisible to VoiceOver; expose the card as one button with its content.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        let resolved: any CardViewStyle = explicitStyle ?? (glassEnabled ? style : FlatCardViewStyle())
        return AnyView(resolved.makeBody(configuration: CardViewStyleConfiguration(
            content: .init(content: content()),
            isInteractive: action != nil
        )))
    }
}

/// Mirrors the pressed state into a binding so the feedback can be applied to the card itself.
private struct PressReportingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in isPressed = newValue }
    }
}

// MARK: - Styles

struct CardViewStyleConfiguration {
    /// Type-erased card content.
    struct Content: View {
        init<ContentType: View>(content: ContentType) { body = AnyView(content) }
        var body: AnyView
    }

    let content: CardViewStyleConfiguration.Content
    /// True when the card is tappable. Styles whose effect layers take part in hit testing (Liquid Glass) use
    /// their interactive variant so clicks reach the button.
    var isInteractive = false
}

protocol CardViewStyle {
    associatedtype Body: View
    typealias Configuration = CardViewStyleConfiguration

    func makeBody(configuration: Self.Configuration) -> Self.Body
}

extension View {
    func cardViewStyle(_ style: some CardViewStyle) -> some View {
        environment(\.cardViewStyle, style)
    }
}

private struct CardViewStyleKey: EnvironmentKey {
    static var defaultValue: any CardViewStyle {
        if #available(macOS 26.0, *) {
            LiquidGlassCardViewStyle()
        } else {
            FlatCardViewStyle()
        }
    }
}

extension EnvironmentValues {
    var cardViewStyle: any CardViewStyle {
        get { self[CardViewStyleKey.self] }
        set { self[CardViewStyleKey.self] = newValue }
    }
}

/// Calculus's `LiquidGlassCardViewStyle`: padded content on regular glass, interactive when tappable.
@available(macOS 26.0, *)
struct LiquidGlassCardViewStyle: CardViewStyle {
    var cornerRadius: CGFloat = Theme.radius
    var padding: CGFloat = Theme.cardPadding

    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(padding)
            .liquidGlassSurface(interactive: configuration.isInteractive, cornerRadius: cornerRadius)
    }
}

@available(macOS 26.0, *)
extension CardViewStyle where Self == LiquidGlassCardViewStyle {
    static var liquidGlass: LiquidGlassCardViewStyle { .init() }
}

/// The fallback (macOS 15, offscreen snapshots): Calculus's shadow card without the shadow, which scroll views
/// would clip into a hard line (see the shadow rule in the owner's instructions); the surface colour carries it.
struct FlatCardViewStyle: CardViewStyle {
    var cornerRadius: CGFloat = Theme.radius
    var padding: CGFloat = Theme.cardPadding

    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(padding)
            .background(SmoothRect(radius: cornerRadius).fill(Theme.surface))
            .overlay(SmoothRect(radius: cornerRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

extension CardViewStyle where Self == FlatCardViewStyle {
    static var flat: FlatCardViewStyle { .init() }
}

// MARK: - The one glass call

extension View {
    /// The Liquid Glass surface every MergeCue container uses (CardView, `cardBackground`, `glassCard`,
    /// `selectableGlass`): Calculus's `.glassEffect(.regular[.interactive()], in: rect(cornerRadius: 32))`, drawn
    /// with `SmoothRect` so corners never leave hairlines. `tint` marks selection and status callouts.
    @available(macOS 26.0, *)
    func liquidGlassSurface(interactive: Bool, cornerRadius: CGFloat = Theme.radius, tint: Color? = nil) -> some View {
        glassEffect(Glass.mergeCue(tint: tint, interactive: interactive), in: SmoothRect(radius: cornerRadius))
    }
}

@available(macOS 26.0, *)
extension Glass {
    /// `.regular`, optionally tinted, interactive for clickable surfaces.
    static func mergeCue(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.22)) }
        return interactive ? glass.interactive() : glass
    }
}
