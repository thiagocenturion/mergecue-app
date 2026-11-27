import MergeCueCore
import SwiftUI

/// The "opens outside MergeCue" glyph (D59): the same arrow-out-of-a-box as the PR header's open-in-browser button.
/// Every button or menu item that sends the owner to the browser carries it next to its title.
struct OutsideLinkGlyph: View {
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: Self.symbol)
            .scaledFont(.system(size: size, weight: .semibold))
            .accessibilityHidden(true)
    }

    static let symbol = "arrow.up.right.square"
}

/// A button title followed by the outside glyph: "Open in GitHub ↗".
struct OutsideLinkLabel: View {
    let title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(title)
            OutsideLinkGlyph()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint("Opens in your browser")
    }
}

/// Approve (D59): approves in the app after a confirmation when the account may write, otherwise opens the
/// provider page with the outside glyph. Same button either way.
struct ApproveButton: View {
    let model: AppModel
    let changeRequest: ChangeRequestKey
    var fullWidth = true
    /// The primary (gradient) style; false draws it as a secondary button beside another primary action.
    var prominent = true

    var body: some View {
        let route = model.approvalRoute(changeRequest)
        Button {
            model.approve(changeRequest)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal").accessibilityHidden(true)
                Text("Approve")
                if route?.opensBrowser == true { OutsideLinkGlyph(size: 12) }
            }
        }
        .modifier(ApproveButtonStyle(prominent: prominent, size: prominent && !fullWidth ? .regular : .large, fullWidth: fullWidth))
        .help(Self.help(route, kind: changeRequest.kind))
        .accessibilityLabel(route?.opensBrowser == true ? "Approve in \(changeRequest.kind.displayName)" : "Approve")
        .accessibilityHint(Self.help(route, kind: changeRequest.kind))
    }

    static func help(_ route: ActionRoute?, kind: ProviderKind) -> String {
        switch route {
        case .browser(_, let reason)?: reason
        default: "Approve as you on \(kind.displayName), for the commits you see now"
        }
    }
}

/// Gradient when Approve is the primary action, the secondary glass capsule otherwise.
private struct ApproveButtonStyle: ViewModifier {
    var prominent: Bool
    var size: ButtonSize
    var fullWidth: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(GradientButtonStyle(size: size, fullWidth: fullWidth))
        } else {
            content.buttonStyle(SecondaryButtonStyle(size: size, fullWidth: fullWidth))
        }
    }
}

/// "Approve acme/payments-api #42?" before an in-app approval (D59): it is public and posted as the owner.
struct ApprovalConfirmation: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.alert(
            model.pendingApproval.map(model.approvalTitle) ?? "Approve?",
            isPresented: Binding(get: { model.pendingApproval != nil }, set: { if !$0 { model.pendingApproval = nil } }),
            presenting: model.pendingApproval
        ) { key in
            Button("Approve") { Task { await model.confirmApproval() } }
            Button("Cancel", role: .cancel) { model.pendingApproval = nil }
        } message: { key in
            Text("Your approval is posted to \(key.kind.displayName) as you, for the commits you see now. Everyone on the \(key.kind.changeRequestAbbreviation) can see it.")
        }
    }
}

extension View {
    func approvalConfirmation(_ model: AppModel) -> some View { modifier(ApprovalConfirmation(model: model)) }
}
