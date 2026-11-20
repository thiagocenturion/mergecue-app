import SwiftUI

/// Shared motion (D41): spring presets, the CTA sheen, shimmering placeholders, staggered appearance and pulses.
/// Everything here honours Reduce Motion (System Settings › Accessibility › Display): movement turns into a plain
/// fade or nothing.
enum Motion {
    /// Buttons and chips while pressed.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.7)
    /// Hover highlights.
    static let hover = Animation.easeOut(duration: 0.16)
    /// Selection changes (chips, segments, tabs).
    static let snappy = Animation.snappy(duration: 0.28, extraBounce: 0.08)
    /// List inserts and removals, screen changes.
    static let smooth = Animation.smooth(duration: 0.38)
    /// Cards entering the screen.
    static let appear = Animation.spring(response: 0.5, dampingFraction: 0.82)

    /// Card insert / remove in lists.
    static let listTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .top)),
        removal: .opacity.combined(with: .scale(scale: 0.96))
    )

    /// Screen and detail changes.
    static let screenTransition = AnyTransition.opacity.combined(with: .offset(y: 10))
}

extension View {
    /// A soft highlight that sweeps across the view every few seconds (primary actions).
    func sheen<S: Shape>(active: Bool = true, shape: S) -> some View {
        modifier(SheenModifier(active: active, shape: shape))
    }

    /// A moving highlight over placeholder content while it loads.
    func shimmering(_ active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }

    /// Fades and lifts the view in on first appearance, `index` × 40 ms after the first one (capped).
    func appearStaggered(_ index: Int = 0) -> some View {
        modifier(StaggeredAppear(delay: Double(min(index, 8)) * 0.04))
    }

    /// A gentle repeating scale pulse (current step markers, live indicators).
    func pulsing(_ active: Bool = true) -> some View {
        modifier(PulseModifier(active: active))
    }
}

private struct SheenModifier<S: Shape>: ViewModifier {
    let active: Bool
    let shape: S
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if active, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let cycle = 4.5
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / 1.2
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(60, width * 0.35))
                            .rotationEffect(.degrees(18))
                            .offset(x: -width * 0.5 + CGFloat(phase) * width * 1.9)
                            .opacity(phase <= 1 ? 1 : 0)
                    }
                    .clipShape(shape)
                    .allowsHitTesting(false)
                    .blendMode(.plusLighter)
                }
            }
        }
    }
}

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, Theme.textPrimary.opacity(reduceMotion ? 0 : 0.12), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: phase * proxy.size.width * 1.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .opacity(reduceMotion ? 0.7 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
                }
        } else {
            content
        }
    }
}

private struct StaggeredAppear: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.appear.delay(delay)) { shown = true }
            }
    }
}

private struct PulseModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && on && !reduceMotion ? 1.12 : 1)
            .onAppear {
                guard active, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// Placeholder rows that shimmer while the first load runs (instead of an empty screen).
struct SkeletonCard: View {
    var lines = 3

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle().fill(Theme.surfaceRaised).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 10) {
                Capsule().fill(Theme.surfaceRaised).frame(width: 180, height: 10)
                Capsule().fill(Theme.surfaceRaised).frame(height: 14)
                ForEach(0..<max(0, lines - 2), id: \.self) { _ in
                    Capsule().fill(Theme.surfaceRaised).frame(width: 220, height: 10)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .shimmering()
        .accessibilityHidden(true)
    }
}
