import SwiftUI

/// Transient message. Announced to VoiceOver when shown (AppModel.showBanner); critical ones stay until dismissed,
/// and the others' timer pauses while the pointer is over the banner or keyboard focus is inside it.
struct BannerView: View {
    let banner: Banner
    var onHold: (Bool) -> Void = { _ in }
    var onDismiss: () -> Void
    @State private var isHovering = false
    @FocusState private var dismissFocused: Bool

    var body: some View {
        let color = banner.tone == .neutral ? Theme.accent : Theme.color(banner.tone)
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(banner.message)
                .scaledFont(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .scaledFont(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 18, minHeight: 18)
            }
            .buttonStyle(PlainRowButtonStyle())
            .focused($dismissFocused)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .onHover { hovering in
            isHovering = hovering
            onHold(hovering || dismissFocused)
        }
        .onChange(of: dismissFocused) { _, focused in onHold(focused || isHovering) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(toneLabel): \(banner.message)")
    }

    private var toneLabel: String {
        switch banner.tone {
        case .critical: "Error"
        case .attention: "Warning"
        case .success: "Done"
        case .neutral, .progress: "Message"
        }
    }

    private var symbol: String {
        switch banner.tone {
        case .critical: "exclamationmark.octagon.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .neutral, .progress: "info.circle.fill"
        }
    }
}
