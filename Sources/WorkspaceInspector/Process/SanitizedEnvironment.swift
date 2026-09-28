import Foundation

/// Builds the environment for every child process MergeCue starts.
///
/// Starting from the inherited environment it:
/// - removes **every** `GIT_*` variable (no `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_CONFIG_*`,
///   `GIT_OBJECT_DIRECTORY`, … can leak in from the app's launch context and redirect git to another repo),
///   plus `SSH_ASKPASS` / `DISPLAY`-style prompt helpers;
/// - disables every interactive path: `GIT_TERMINAL_PROMPT=0`, an empty `GIT_ASKPASS`/`SSH_ASKPASS` (git then runs
///   no askpass program, not even `core.askPass`), `SSH_ASKPASS_REQUIRE=never`, `GCM_INTERACTIVE=never` (Git
///   Credential Manager), `GIT_EDITOR`/`EDITOR`/`VISUAL=false`;
/// - disables pagers (`GIT_PAGER=cat`, `PAGER=cat`) and localization (`LC_ALL=C`, `LANG=C`) so output is parseable;
/// - sets `GIT_OPTIONAL_LOCKS=0` so read-only commands like `git status` never rewrite the user's index;
/// - finally applies `overrides` (tests use this for a hermetic `HOME` / `GIT_CONFIG_GLOBAL`).
///
/// Credential helpers configured by the user (osxkeychain, `gh auth git-credential`, …) and the SSH agent
/// (`SSH_AUTH_SOCK`) keep working: MergeCue never injects tokens into git.
enum SanitizedEnvironment {
    static let removedVariables: Set<String> = [
        "SSH_ASKPASS", "SUDO_ASKPASS", "LESS", "LESSOPEN", "MANPAGER",
    ]

    static let fixedVariables: [String: String] = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "",
        "SSH_ASKPASS": "",
        "SSH_ASKPASS_REQUIRE": "never",
        "GCM_INTERACTIVE": "never",
        "GIT_PAGER": "cat",
        "PAGER": "cat",
        "GIT_EDITOR": "false",
        "EDITOR": "false",
        "VISUAL": "false",
        "GIT_MERGE_AUTOEDIT": "no",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
        "LANG": "C",
        "TERM": "dumb",
        "NO_COLOR": "1",
    ]

    static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    /// Apps launched from Finder get a minimal `PATH`; append the standard and Homebrew directories so the user's
    /// credential helpers (`gh`, `git-credential-manager`) and filters (`git-lfs`) are found.
    static func completedPath(_ inherited: String?) -> String {
        var components = (inherited ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for directory in defaultPath.split(separator: ":").map(String.init) where !components.contains(directory) {
            components.append(directory)
        }
        return components.joined(separator: ":")
    }

    static func make(inherited: [String: String], overrides: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for (key, value) in inherited {
            if key.hasPrefix("GIT_") || key.hasPrefix("LC_") || removedVariables.contains(key) { continue }
            environment[key] = value
        }
        environment["PATH"] = completedPath(environment["PATH"])
        for (key, value) in fixedVariables { environment[key] = value }
        for (key, value) in overrides { environment[key] = value }
        return environment
    }
}
