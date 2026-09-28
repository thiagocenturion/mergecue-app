import MergeCueCore
import SwiftUI

/// Shows exactly what an approval will do, with warnings and the reason it cannot be approved (if any).
struct ApprovalSheet: View {
    let model: AppModel
    let preview: ActionPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.brandGradientDiagonal))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(preview.target)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            if preview.action == .applyPatch {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(DiffParser.parse(preview.body)) { DiffFileCard(file: $0) }
                    }
                }
                .frame(maxHeight: 340)
            } else {
                Text(preview.body)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground(Theme.surfaceSunken, radius: 10)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(preview.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if let reason = preview.blockedReason {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Theme.critical)
                    Text(reason)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if reason.contains("Settings") {
                        Button("Open Settings") {
                            dismiss()
                            model.pendingPreview = nil
                            model.showSettings(.accounts)
                        }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                    }
                }
                .padding(12)
                .cardBackground(Theme.critical.opacity(0.08), radius: 10, border: Theme.critical.opacity(0.35))
            }
            HStack(spacing: 10) {
                Text("Fingerprint \(String(preview.fingerprint.prefix(12)))…")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Your approval applies to exactly this content.")
                Spacer()
                Button("Decline") {
                    Task { await model.send(.declinePreview(preview)) }
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Cancel", role: .cancel) {
                    model.pendingPreview = nil
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button("Approve \(preview.action.displayName)") {
                    Task { await model.send(.approvePreview(preview)) }
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!preview.canApprove)
            }
        }
        .padding(24)
        .frame(width: 680)
        .background(Theme.panel)
    }

    private var symbol: String {
        switch preview.action {
        case .applyPatch: "square.and.arrow.down"
        case .postReply: "arrowshape.turn.up.left"
        case .resolveThread: "checkmark.bubble"
        case .requestChanges: "exclamationmark.bubble"
        case .commitAndPush: "arrow.up.circle"
        case .merge: "arrow.triangle.merge"
        }
    }
}
