import MergeCueCore
import SwiftUI

/// Per-provider connect sheet: auth method, least-privilege scopes, token page link, and a `SecureField` whose value
/// is handed over as an opaque `SecretValue` and cleared immediately.
struct ConnectAccountSheet: View {
    let model: AppModel
    let kind: ProviderKind
    @Environment(\.dismiss) private var dismiss
    @State private var method: AuthMethod
    @State private var token = ""
    @State private var email = ""
    @State private var isConnecting = false

    init(model: AppModel, kind: ProviderKind) {
        self.model = model
        self.kind = kind
        _method = State(initialValue: ConnectGuide.methods(for: kind)[0])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderGlyph(kind: kind, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(kind.displayName)").font(.title3.weight(.semibold))
                    Text(ProviderInstance.default(for: kind).host).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                ModeBadge(mode: model.mode)
            }
            let methods = ConnectGuide.methods(for: kind)
            if methods.count > 1 {
                Picker("Method", selection: $method) {
                    ForEach(methods, id: \.self) { Text(ConnectGuide.title(for: $0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(ConnectGuide.explanation(for: kind, method: method))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(ConnectGuide.scopes(for: kind, method: method), id: \.self) { scope in
                        Label {
                            Text(scope).font(.callout)
                        } icon: {
                            Image(systemName: "checkmark.circle").foregroundStyle(Theme.mint)
                        }
                    }
                    Text(ConnectGuide.writeNote(for: kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Least-privilege scopes").font(.callout.weight(.semibold))
            }
            if method != .githubCLIImport {
                if let url = ConnectGuide.tokenPage(for: kind, method: method) {
                    Button {
                        Task { await model.send(.openURL(url)) }
                    } label: {
                        Label("Open the token page in your browser", systemImage: "safari")
                    }
                    .buttonStyle(.link)
                }
                if method == .bitbucketAPIToken {
                    TextField("Atlassian account email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                }
                SecureField(method == .bitbucketAccessToken ? "Access token" : "Token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityHint("Stored only in your Keychain")
                Label("Stored only in your Keychain — never logged, synced or shown again.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("MergeCue asks the GitHub CLI for the token of your current `gh auth login` session and stores a copy in your Keychain.",
                      systemImage: "terminal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.mode != .live {
                Label("\(model.mode.badgeText ?? "Preview"): the connection is simulated and the token is discarded.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.attention)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(method == .githubCLIImport ? "Import" : "Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect || isConnecting)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onChange(of: method) { _, _ in token = "" }
    }

    private var canConnect: Bool {
        switch method {
        case .githubCLIImport, .oauthDeviceFlow: true
        case .bitbucketAPIToken: !token.isEmpty && email.contains("@")
        case .personalAccessToken, .bitbucketAccessToken: !token.isEmpty
        }
    }

    private func connect() {
        let secret = token.isEmpty ? nil : SecretValue(token)
        token = ""
        isConnecting = true
        let request = ConnectAccountRequest(kind: kind, method: method, token: secret, email: method == .bitbucketAPIToken ? email : nil)
        Task {
            let result = await model.send(.connectAccount(request))
            isConnecting = false
            if result != nil { close() }
        }
    }

    private func close() {
        token = ""
        model.connectSheetKind = nil
        dismiss()
    }
}

/// Provider-specific connection guidance (ARCHITECTURE D8: PATs, GitHub CLI import, Atlassian API tokens; no app passwords).
enum ConnectGuide {
    static func methods(for kind: ProviderKind) -> [AuthMethod] {
        switch kind {
        case .github: [.personalAccessToken, .githubCLIImport]
        case .gitlab: [.personalAccessToken]
        case .bitbucketCloud: [.bitbucketAPIToken, .bitbucketAccessToken]
        }
    }

    static func title(for method: AuthMethod) -> String {
        switch method {
        case .personalAccessToken: "Personal access token"
        case .githubCLIImport: "GitHub CLI"
        case .bitbucketAPIToken: "API token + email"
        case .bitbucketAccessToken: "Workspace access token"
        case .oauthDeviceFlow: "Sign in with browser"
        }
    }

    static func explanation(for kind: ProviderKind, method: AuthMethod) -> String {
        switch (kind, method) {
        case (.github, .githubCLIImport):
            "Reuse the account you're signed in to with the GitHub CLI. Nothing is imported until you click Import."
        case (.github, _):
            "Create a fine-grained personal access token limited to the repositories you review, or a classic token."
        case (.gitlab, _):
            "Create a personal access token on GitLab.com. MergeCue treats the instance URL as part of the account identity."
        case (.bitbucketCloud, .bitbucketAccessToken):
            "Use a workspace or repository access token (Bearer). It only sees that workspace or repository."
        case (.bitbucketCloud, _):
            "Create an Atlassian API token with Bitbucket scopes and enter the email of your Atlassian account. App passwords are deprecated and not supported."
        }
    }

    static func scopes(for kind: ProviderKind, method: AuthMethod) -> [String] {
        switch kind {
        case .github:
            method == .githubCLIImport
                ? ["Uses the scopes of your gh session (usually repo, read:org)"]
                : ["Fine-grained: Pull requests, Checks, Commit statuses, Contents, Metadata — Read", "Classic: repo, read:org"]
        case .gitlab:
            ["read_api"]
        case .bitbucketCloud:
            ["read:user:bitbucket", "read:workspace:bitbucket", "read:repository:bitbucket", "read:pullrequest:bitbucket", "read:pipeline:bitbucket"]
        }
    }

    static func writeNote(for kind: ProviderKind) -> String {
        switch kind {
        case .github: "Replies and thread resolution need Pull requests: Read and write (fine-grained) — only if you turn on remote writes."
        case .gitlab: "Replies and thread resolution need the api scope — only if you turn on remote writes."
        case .bitbucketCloud: "Replies need write:pullrequest:bitbucket — only if you turn on remote writes."
        }
    }

    static func tokenPage(for kind: ProviderKind, method: AuthMethod) -> URL? {
        switch (kind, method) {
        case (.github, _): URL(string: "https://github.com/settings/personal-access-tokens/new")
        case (.gitlab, _): URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens")
        case (.bitbucketCloud, .bitbucketAccessToken): URL(string: "https://support.atlassian.com/bitbucket-cloud/docs/access-tokens/")
        case (.bitbucketCloud, _): URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")
        }
    }
}
