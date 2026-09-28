import AppKit
import MergeCueCore
import SwiftUI
import Testing
@testable import MergeCueUI

/// The sidebar's account rows at the real sidebar width: the account label is never cut while there is room
/// ("Bitbucket (demo)" used to render as "Bitbucket (de…").
@Suite("Sidebar account row layout")
@MainActor
struct SidebarLayoutTests {
    /// The width a row gets inside the sidebar (`Sidebar` pads 12 pt on each side).
    static let rowWidth = Theme.sidebarWidth - 24

    func account(_ kind: ProviderKind, label: String) -> AccountState {
        let key = AccountKey(kind: kind, host: kind == .github ? "github.com" : kind == .gitlab ? "gitlab.com" : "bitbucket.org", remoteUserID: "1")
        let instance: ProviderInstance = kind == .github ? .githubCom : kind == .gitlab ? .gitlabCom : .bitbucketCloud
        let account = Account(id: key, instance: instance, username: "mona-dev", authMethod: .personalAccessToken,
                              label: label, connectedAt: testNow, isDemo: true)
        return AccountState(account: account, status: AccountSyncStatus(account: key, state: .ok, lastSuccessAt: testNow),
                            capabilities: CapabilityManifest(provider: kind, manifestVersion: 1, entries: [:]))
    }

    func fittingHeight(_ state: AccountState, model: AppModel) -> CGFloat {
        let host = NSHostingView(rootView: SidebarAccountRow(model: model, account: state).frame(width: Self.rowWidth))
        host.frame = NSRect(x: 0, y: 0, width: Self.rowWidth, height: 200)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Natural one-line width of a label in the row's font.
    func idealWidth(_ label: String) -> CGFloat {
        let host = NSHostingView(rootView: Text(label).font(.system(size: 12)).fixedSize())
        return host.fittingSize.width
    }

    @Test func demoLabelsFitOnOneLineAtTheSidebarWidth() async {
        let model = await makeModel()
        // Room left for the name column: horizontal padding, glyph, dot, chevron and the spacing between them.
        let chevron = NSHostingView(rootView: Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold)).fixedSize()).fittingSize.width
        let available = Self.rowWidth - 20 - 26 - 8 - chevron - 3 * SidebarAccountRow.spacing
        for (kind, label) in [(ProviderKind.bitbucketCloud, "Bitbucket (demo)"), (.github, "GitHub (demo)"), (.gitlab, "GitLab (demo)")] {
            #expect(idealWidth(label) <= available, "\(label) needs \(idealWidth(label)) of \(available) pt")
            #expect(fittingHeight(account(kind, label: label), model: model) == SidebarAccountRow.minHeight,
                    "\(label) stays a single-line, standard-height row")
        }
    }

    @Test func longLabelsWrapInsteadOfBeingCut() async {
        let model = await makeModel()
        let short = fittingHeight(account(.bitbucketCloud, label: "Bitbucket (demo)"), model: model)
        let long = fittingHeight(account(.bitbucketCloud, label: "acme-payments-platform workspace (read only)"), model: model)
        #expect(long > short, "a label wider than the column takes a second line")
        #expect(SidebarAccountRow.labelLineLimit == 2)
    }
}
