import AppKit
import SwiftUI

/// The looping background glow (D42), after the "aurora" behind Calculus's Home header: soft brand-coloured blobs
/// drifting slowly at the top of the content area and dissolving into the background. The blobs are Core Animation
/// layers drifting in the render server, so the SwiftUI views over them are not re-evaluated every frame.
///
/// Holds still with Reduce Motion and while the window is hidden. Offscreen snapshots (which cannot capture
/// layers) draw the first keyframe in SwiftUI instead.
struct AuroraGlow: View {
    var colors: [Color] = AuroraGlow.brandColors
    /// Overall strength; dark mode shows it a little more than light mode.
    var opacity: Double = 0.65
    /// Seconds per drift keyframe (three keyframes per loop).
    var keyframeDuration: Double = 5

    /// MergeCue's icon family: violet, blue, cyan, plus a deeper indigo.
    static let brandColors: [Color] = [Color(hex: 0x8B5CF6), Color(hex: 0x3B82F6), Color(hex: 0x38C8F5), Color(hex: 0x4F46E5)]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.glassEffectsEnabled) private var isLiveRendering

    var body: some View {
        Group {
            if isLiveRendering {
                AuroraBlobs(colors: colors, keyframeDuration: keyframeDuration, isRunning: !reduceMotion)
            } else {
                StaticAurora(colors: colors)
            }
        }
        .opacity(opacity * (colorScheme == .dark ? 0.55 : 0.4))
        .mask {
            LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.5), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where blob `index` sits and how wide it is at `phase` (shared by the layers and the static frame).
    nonisolated static func layout(index: Int, phase: Int, in size: CGSize) -> (center: CGPoint, diameter: CGFloat) {
        let seed = Double(index)
        let angle = seed * 1.7 + Double(phase) * 2.1
        let x = size.width * (0.5 + 0.4 * cos(angle))
        let y = size.height * (0.4 + 0.32 * sin(angle * 1.3))
        let diameter = max(size.width, size.height) * (0.5 + 0.14 * sin(seed + Double(phase)))
        return (CGPoint(x: x, y: y), diameter)
    }
}

/// The first keyframe drawn in SwiftUI (snapshots).
private struct StaticAurora: View {
    let colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    let frame = AuroraGlow.layout(index: index, phase: 0, in: proxy.size)
                    Circle()
                        .fill(RadialGradient(colors: [color, color.opacity(0.55), color.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: frame.diameter / 2))
                        .frame(width: frame.diameter, height: frame.diameter)
                        .position(frame.center)
                }
            }
        }
        .clipped()
    }
}

private struct AuroraBlobs: NSViewRepresentable {
    let colors: [Color]
    let keyframeDuration: Double
    let isRunning: Bool

    func makeNSView(context: Context) -> AuroraBlobsView { AuroraBlobsView() }

    func updateNSView(_ view: AuroraBlobsView, context: Context) {
        view.update(colors: colors.map { NSColor($0) }, keyframeDuration: keyframeDuration, isRunning: isRunning)
    }
}

/// One radial-gradient layer per colour, eased through three keyframe layouts and back to the first, forever.
/// A new size lays the keyframes out again and restarts the drift; a hidden window pauses it.
final class AuroraBlobsView: NSView {
    private var blobs: [CAGradientLayer] = []
    private var colors: [NSColor] = []
    private var keyframeDuration: Double = 5
    private var isRunning = false
    private var laidOutSize: CGSize = .zero
    private var occlusionObserver: (any NSObjectProtocol)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(colors: [NSColor], keyframeDuration: Double, isRunning: Bool) {
        let rebuilds = colors != self.colors
        let restarts = rebuilds || keyframeDuration != self.keyframeDuration || isRunning != self.isRunning
        self.colors = colors
        self.keyframeDuration = keyframeDuration
        self.isRunning = isRunning
        if rebuilds { rebuildBlobs() }
        if restarts { layOut(force: true) }
    }

    override func layout() {
        super.layout()
        layOut(force: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncPause() }
            }
        }
        layOut(force: true)
        syncPause()
    }

    /// Stops the drift (speed 0) while the window is not visible.
    private func syncPause() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        layer?.speed = visible ? 1 : 0
    }

    private func rebuildBlobs() {
        blobs.forEach { $0.removeFromSuperlayer() }
        blobs = colors.map { color in
            // A radial falloff instead of a blur: a blur is a full-size offscreen pass per blob, every frame.
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            let cg = color.cgColor
            blob.colors = [cg, cg.copy(alpha: cg.alpha * 0.55) ?? cg, cg.copy(alpha: 0) ?? cg]
            blob.locations = [0, 0.35, 1]
            layer?.addSublayer(blob)
            return blob
        }
    }

    private func layOut(force: Bool) {
        let size = bounds.size
        guard size.width > 0, size.height > 0, force || size != laidOutSize else { return }
        laidOutSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, blob) in blobs.enumerated() {
            blob.removeAnimation(forKey: "drift")
            let frames = (0..<3).map { AuroraGlow.layout(index: index, phase: $0, in: size) }
            // Sized for the largest it gets; the drift scales it down (moves a bitmap instead of redrawing).
            let largest = frames.map(\.diameter).max() ?? 0
            blob.bounds = CGRect(x: 0, y: 0, width: largest * 1.5, height: largest * 1.5)
            blob.position = flipped(frames[0].center, in: size)
            let rest = frames[0].diameter / max(largest, 1)
            blob.transform = CATransform3DMakeScale(rest, rest, 1)

            guard isRunning, window != nil else { continue }
            let loop = frames + [frames[0]]
            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = loop.map { NSValue(point: flipped($0.center, in: size)) }
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = loop.map { $0.diameter / max(largest, 1) }
            for keyframes in [position, scale] {
                keyframes.keyTimes = [0, NSNumber(value: 1.0 / 3), NSNumber(value: 2.0 / 3), 1]
                keyframes.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            }
            let drift = CAAnimationGroup()
            drift.animations = [position, scale]
            drift.duration = keyframeDuration * 3
            drift.repeatCount = .infinity
            drift.isRemovedOnCompletion = false
            blob.add(drift, forKey: "drift")
        }
        CATransaction.commit()
    }

    /// Layer coordinates start at the bottom on macOS; the layouts are top-down like SwiftUI's.
    private func flipped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        isFlipped ? point : CGPoint(x: point.x, y: size.height - point.y)
    }
}

extension View {
    /// The screen backdrop: the content background with the looping aurora glow at the top.
    func auroraBackdrop(height: CGFloat = 480, opacity: Double = 0.65) -> some View {
        background(alignment: .top) {
            ZStack(alignment: .top) {
                Theme.contentBackground
                AuroraGlow(opacity: opacity).frame(height: height)
            }
            .ignoresSafeArea()
        }
    }
}
