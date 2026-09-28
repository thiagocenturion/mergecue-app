import MergeCueCore
import SwiftUI

/// The "Connect account" sheet (Settings › Accounts, Reconnect): header + `ConnectAccountForm`.
struct ConnectAccountSheet: View {
    let model: AppModel
    let kind: ProviderKind
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderGlyph(kind: kind, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(kind.displayName)").scaledFont(.title3.weight(.semibold))
                    Text(ProviderInstance.default(for: kind).host).scaledFont(.callout).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                ModeBadge(mode: model.mode)
            }
            ConnectAccountForm(model: model, kind: kind, showsCancel: true) {
                model.connectSheetKind = nil
                dismiss()
            }
        }
        .padding(22)
        .frame(width: 540)
    }
}

/// Per-provider connection form (sheet and setup assistant): least-privilege scopes, a link to create the token,
/// and a `SecureField` whose value is handed over as an opaque `SecretValue` and cleared immediately. Tokens are
/// never logged, echoed or shown again. Remote writes stay off for new accounts.
struct ConnectAccountForm: View {
    let model: AppModel
    let kind: ProviderKind
    var showsCancel: Bool
    /// Called after a successful connection (or Cancel).
    var onFinished: () -> Void
    @State private var method: AuthMethod
    @State private var token = ""
    @State private var email = ""
    @State private var instanceURL = "https://gitlab.com"
    @State private var wantsWrites = false
    @State private var isConnecting = false
    /// The token field takes keyboard focus when the form appears (it is the one required input).
    @FocusState private var tokenFocused: Bool

    init(model: AppModel, kind: ProviderKind, showsCancel: Bool, onFinished: @escaping () -> Void) {
        self.model = model
        self.kind = kind
        self.showsCancel = showsCancel
        self.onFinished = onFinished
        _method = State(initialValue: ConnectGuide.methods(for: kind)[0])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if kind == .github {
                githubCLI
                HStack(spacing: 8) {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    Text("or paste a token").scaledFont(.caption).foregroundStyle(Theme.textSecondary).fixedSize()
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
            } else if ConnectGuide.methods(for: kind).count > 1 {
                Picker("Method", selection: $method) {
                    ForEach(ConnectGuide.methods(for: kind), id: \.self) { Text(ConnectGuide.title(for: $0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text(ConnectGuide.explanation(for: kind, method: tokenMethod))
                .scaledFont(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            scopes
            if kind == .gitlab {
                TextField("Instance URL", text: $instanceURL)
                    .textFieldStyle(.roundedBorder)
                    .help("GitLab.com is tested. The instance URL is part of the account's identity.")
                Toggle("I want MergeCue to post replies and resolve threads (needs the api scope)", isOn: $wantsWrites)
                    .scaledFont(.callout)
            }
            if let url = ConnectGuide.tokenPage(for: kind, method: tokenMethod, wantsWrites: wantsWrites, instance: gitlabInstance) {
                Button {
                    Task { await model.send(.openURL(url)) }
                } label: {
                    Label(kind == .github ? "Create token (repo, read:org)" : "Create token", systemImage: "safari")
                }
                .buttonStyle(.link)
                .help(url.absoluteString)
            }
            if tokenMethod == .bitbucketAPIToken {
                TextField("Atlassian account email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
            }
            SecureField(tokenMethod == .bitbucketAccessToken ? "Access token" : "Token", text: $token)
                .textFieldStyle(.roundedBorder)
                .focused($tokenFocused)
                .accessibilityHint("Stored only in your Keychain")
                .onSubmit { if canConnect { connect(method: tokenMethod) } }
            Label("Stored only in your Keychain — never logged, synced or shown again. Remote writes stay off until you turn them on per account.",
                  systemImage: "lock.shield")
                .scaledFont(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.mode == .preview {
                Label("Preview data: the connection is simulated and the token is discarded.", systemImage: "info.circle")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.attentionText)
            } else if model.mode == .demo {
                Label("Demo mode: real providers are not contacted. Switch off Demo mode in Settings › General to connect your accounts.",
                      systemImage: "info.circle")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isConnecting { ProgressView().controlSize(.small) }
                Spacer()
                if showsCancel {
                    Button("Cancel", role: .cancel) { finish() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Connect") { connect(method: tokenMethod) }
                    .buttonStyle(GradientButtonStyle(size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect || isConnecting)
            }
        }
        .onChange(of: method) { _, _ in token = "" }
        .onDisappear { token = "" }
        .defaultFocus($tokenFocused, true)
        .task {
            // After the sheet's own first-responder pass.
            try? await Task.sleep(for: .milliseconds(150))
            tokenFocused = true
        }
    }

    private var githubCLI: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                connect(method: .githubCLIImport)
            } label: {
                Label("Use my GitHub CLI login", systemImage: "terminal")
            }
            .buttonStyle(SecondaryButtonStyle(size: .compact))
            .disabled(isConnecting)
            .help("Runs `gh auth token` once and stores a copy of that token in your Keychain")
            Text("Reuses the account you're signed in to with `gh auth login` (its scopes, usually repo and read:org). Nothing is imported until you click.")
                .scaledFont(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scopes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scopes").scaledFont(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            ForEach(ConnectGuide.scopes(for: kind, method: tokenMethod, wantsWrites: wantsWrites), id: \.self) { scope in
                Label {
                    Text(scope).scaledFont(.callout)
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.mint)
                }
            }
            Text(ConnectGuide.writeNote(for: kind))
                .scaledFont(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken))
    }

    /// The method of the token field (GitHub's CLI import is a separate button).
    private var tokenMethod: AuthMethod {
        kind == .github ? .personalAccessToken : method
    }

    private var gitlabInstance: ProviderInstance? {
        guard kind == .gitlab else { return nil }
        return ConnectGuide.gitlabInstance(from: instanceURL)
    }

    private var canConnect: Bool {
        if kind == .gitlab, gitlabInstance == nil { return false }
        switch tokenMethod {
        case .githubCLIImport, .oauthDeviceFlow: return true
        case .bitbucketAPIToken: return !token.isEmpty && email.contains("@")
        case .personalAccessToken, .bitbucketAccessToken: return !token.isEmpty
        }
    }

    private func connect(method: AuthMethod) {
        let secret = method == .githubCLIImport || token.isEmpty ? nil : SecretValue(token)
        token = ""
        isConnecting = true
        let request = ConnectAccountRequest(kind: kind, method: method, instance: gitlabInstance, token: secret,
                                            email: method == .bitbucketAPIToken ? email : nil)
        Task {
            let result = await model.send(.connectAccount(request))
            isConnecting = false
            if result != nil { finish() }
        }
    }

    private func finish() {
        token = ""
        onFinished()
    }
}

/// Provider-specific connection guidance (DECISIONS D8: PATs, GitHub CLI import, Atlassian API tokens; no app passwords).
nonisolated enum ConnectGuide {
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
            "Reuse the account you're signed in to with the GitHub CLI. Nothing is imported until you click."
        case (.github, _):
            "A classic token with repo and read:org, or a fine-grained token limited to the repositories you review."
        case (.gitlab, _):
            "Create a personal access token on GitLab. read_api is enough to read merge requests, discussions and pipelines."
        case (.bitbucketCloud, .bitbucketAccessToken):
            "Use a workspace or repository access token (Bearer). It only sees that workspace or repository."
        case (.bitbucketCloud, _):
            "Create an Atlassian API token with Bitbucket scopes and enter your Atlassian account email. App passwords are deprecated and not supported."
        }
    }

    static func scopes(for kind: ProviderKind, method: AuthMethod, wantsWrites: Bool = false) -> [String] {
        switch kind {
        case .github:
            method == .githubCLIImport
                ? ["Uses the scopes of your gh session (usually repo, read:org)"]
                : ["Classic: repo, read:org", "Fine-grained: Pull requests, Checks, Commit statuses, Contents, Metadata — Read"]
        case .gitlab:
            wantsWrites ? ["api (read + replies and thread resolution)"] : ["read_api"]
        case .bitbucketCloud:
            ["read:user:bitbucket", "read:workspace:bitbucket", "read:repository:bitbucket", "read:pullrequest:bitbucket", "read:pipeline:bitbucket"]
        }
    }

    static func writeNote(for kind: ProviderKind) -> String {
        switch kind {
        case .github: "Replies and thread resolution use the same token (fine-grained: Pull requests — Read and write) and stay off until you turn on remote writes for the account."
        case .gitlab: "Replies and thread resolution need the api scope — request it only if you'll turn on remote writes."
        case .bitbucketCloud: "Replies need write:pullrequest:bitbucket — only if you'll turn on remote writes."
        }
    }

    static func tokenPage(for kind: ProviderKind, method: AuthMethod, wantsWrites: Bool = false, instance: ProviderInstance? = nil) -> URL? {
        switch (kind, method) {
        case (.github, _):
            return URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org&description=MergeCue")
        case (.gitlab, _):
            let base = (instance ?? .gitlabCom).webURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return URL(string: "\(base)/-/user_settings/personal_access_tokens?name=MergeCue&scopes=\(wantsWrites ? "api" : "read_api")")
        case (.bitbucketCloud, .bitbucketAccessToken):
            return URL(string: "https://support.atlassian.com/bitbucket-cloud/docs/access-tokens/")
        case (.bitbucketCloud, _):
            return URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")
        }
    }

    /// `https://gitlab.example.com` → a GitLab instance (API at `/api/v4`); nil unless it is a plain https URL.
    static func gitlabInstance(from text: String) -> ProviderInstance? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty,
              url.path().isEmpty, url.query() == nil, url.user() == nil else { return nil }
        if host.lowercased() == "gitlab.com" { return .gitlabCom }
        return ProviderInstance(kind: .gitlab, webURL: url, apiURL: url.appending(path: "api/v4"))
    }
}
