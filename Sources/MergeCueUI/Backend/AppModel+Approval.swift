import Foundation
import MergeCueCore

/// Where an action runs (D59): in the app, or on the provider's page in the browser when the app may not do it
/// there (writes switched off for the account, a token without the scope, an adapter without the capability).
/// Buttons stay the same either way; the browser route adds the "opens outside" glyph.
public nonisolated enum ActionRoute: Sendable, Hashable {
    case inApp
    /// The page to open, and why the action does not run in the app.
    case browser(URL, reason: String)

    public var opensBrowser: Bool {
        if case .browser = self { true } else { false }
    }
}

extension AppModel {
    /// Whether the owner can approve `key` at all: an open PR/MR of someone else they have not approved yet.
    public func showsApprove(_ key: ChangeRequestKey) -> Bool {
        guard let snapshot = snapshot(key), snapshot.summary.state == .open else { return false }
        let me = key.account.remoteUserID
        guard !ViewerReview.isAuthored(snapshot, userID: me) else { return false }
        return ViewerReview.currentVerdict(snapshot, userID: me) != .approved
    }

    /// In the app when the account's writes are on and its adapter can approve; else the provider page where the
    /// approve button is (GitHub: the Files tab's "Review changes"; GitLab and Bitbucket: the PR/MR page).
    public func approvalRoute(_ key: ChangeRequestKey) -> ActionRoute? {
        guard let snapshot = snapshot(key) else { return nil }
        let provider = key.kind.displayName
        let page = key.kind == .github ? snapshot.summary.webURL.appending(path: "files") : snapshot.summary.webURL
        guard let account = state.accounts.first(where: { $0.id == key.account }) else {
            return .browser(page, reason: "Opens \(provider) to approve it there.")
        }
        guard account.account.writesEnabled else {
            return .browser(page, reason: "Writes are off for this account in MergeCue, so this opens \(provider) to approve it there.")
        }
        let support = account.capabilities.support(for: .approve)
        guard support.isUsable else {
            return .browser(page, reason: "\(support.userFacingDescription). Opens \(provider) to approve it there.")
        }
        return .inApp
    }

    /// The Approve button: asks for confirmation before approving in the app, or opens the provider page. From the
    /// popover (`fromPopover`) the PR/MR opens in the main window first, so the owner confirms with it in view.
    public func approve(_ key: ChangeRequestKey, fromPopover: Bool = false) {
        switch approvalRoute(key) {
        case .inApp?:
            if fromPopover { showChangeRequest(key) }
            pendingApproval = key
        case .browser(let url, _)?: openLink(url)
        case nil: break
        }
    }

    /// The owner confirmed: approve in the app.
    public func confirmApproval() async {
        guard let key = pendingApproval else { return }
        pendingApproval = nil
        await send(.approveChangeRequest(key))
    }

    /// "Approve acme/payments-api #42?" for the confirmation alert.
    public func approvalTitle(_ key: ChangeRequestKey) -> String {
        let repo = snapshot(key)?.summary.repository.fullPath ?? ""
        return "Approve \(repo) \(key.kind.formattedNumber(key.number))?"
    }
}

/// An agent action the app may not perform, done on the provider page instead (D59): the button keeps its place
/// with the outside glyph; replies and change requests are copied first so they can be pasted there.
public nonisolated struct BrowserFallback: Sendable, Hashable {
    /// "Post reply in GitHub".
    public var title: String
    public var url: URL
    /// Text copied before opening (the reply or the change request), nil when there is nothing to paste.
    public var textToCopy: String?
}

extension AppModel {
    /// The browser route of a provider write the account may not do from the app (writes off, token without the
    /// scope, adapter without the capability). Nil for local actions and for blocks of another kind (stale head,
    /// policy), which keep the disabled Approve and its reason.
    public func browserFallback(for preview: ActionPreview) -> BrowserFallback? {
        guard let capability = preview.action.requiredCapability, let record = task(preview.taskID) else { return nil }
        let origin = record.task.origin
        guard let account = state.accounts.first(where: { $0.id == origin.account }) else { return nil }
        let allowed = account.account.writesEnabled && account.capabilities.support(for: capability).isUsable
        guard !allowed else { return nil }
        let provider = origin.providerKind.displayName
        let item = origin.attentionItemID.flatMap { attentionItem($0) }
        let url: URL
        switch preview.action {
        case .postReply, .resolveThread: url = item.flatMap { providerURL(for: $0) } ?? origin.webURL
        case .requestChanges: url = origin.providerKind == .github ? origin.webURL.appending(path: "files") : origin.webURL
        case .merge, .applyPatch, .commitAndPush: url = origin.webURL
        }
        let copies = preview.action == .postReply || preview.action == .requestChanges
        return BrowserFallback(title: "\(preview.action.displayName) in \(provider)", url: url,
                               textToCopy: copies && !preview.body.isEmpty ? preview.body : nil)
    }

    /// Copies the text (when any) and opens the provider page.
    public func performInBrowser(_ fallback: BrowserFallback) {
        if let text = fallback.textToCopy { copyToPasteboard(text, confirmation: "Copied. Paste it on the page that opens.") }
        openLink(fallback.url)
    }
}
