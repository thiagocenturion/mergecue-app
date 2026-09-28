import Foundation
import MergeCueCore
import MergeCueIPC

/// IPC peer authentication for the app's private socket (DECISIONS D7, D11).
///
/// Every connection is already checked for the same uid (`getpeereid`) and must present the per-launch token.
/// When the running app is signed with a Team ID, peers must additionally be the bundled helper:
/// `anchor apple generic and certificate leaf[subject.OU] = "<team>" and identifier "com.thiagocenturion.MergeCue.mcp"`.
/// Unsigned / ad-hoc development builds (`swift build`, tests) fall back to uid + token only, and say so in the log.
public enum RuntimeIPC {
    /// The owner's team (DECISIONS D11).
    public static let expectedTeamIdentifier = "TTSKDZ455K"
    /// Code-signing identifier of the embedded `mergecue-mcp`.
    public static let helperIdentifier = "com.thiagocenturion.MergeCue.mcp"

    /// The helper requirement for `teamIdentifier`.
    public static func helperRequirement(teamIdentifier: String = expectedTeamIdentifier) -> String {
        CodeSignaturePeerValidator.requirement(teamIdentifier: teamIdentifier) + " and identifier \"\(helperIdentifier)\""
    }

    /// The validator for `policy` plus a human-readable description of what is enforced.
    public static func peerValidator(
        for policy: PeerValidationPolicy,
        currentTeamIdentifier: String? = CodeSignaturePeerValidator.currentTeamIdentifier()
    ) throws -> (validator: (any PeerValidator)?, description: String) {
        switch policy {
        case .disabled:
            return (nil, "uid + token (code-signature check disabled)")
        case .requirement(let text):
            return (try CodeSignaturePeerValidator(requirement: text), "uid + token + code requirement \(text)")
        case .automatic:
            guard let team = currentTeamIdentifier, !team.isEmpty else {
                return (nil, "uid + token only (unsigned development build: peer code signatures are not checked)")
            }
            if team != expectedTeamIdentifier {
                MCLog.ipc.notice("MergeCue is signed by team \(team), not \(expectedTeamIdentifier); requiring the helper from the same team.")
            }
            let requirement = helperRequirement(teamIdentifier: team)
            return (try CodeSignaturePeerValidator(requirement: requirement), "uid + token + \(requirement)")
        }
    }
}

/// Where the bundled `mergecue-mcp` helper lives.
///
/// 1. `MERGECUE_MCP_HELPER` (explicit override, must be executable);
/// 2. inside the app bundle: `MergeCue.app/Contents/MacOS/mergecue-mcp`;
/// 3. next to the running executable (SwiftPM products share one build directory);
/// 4. development fallback: this package's `.build/{debug,release}/mergecue-mcp`.
public enum MCPHelperLocator {
    public static let executableName = "mergecue-mcp"
    public static let overrideEnvironmentKey = "MERGECUE_MCP_HELPER"

    public static func locate(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        packageRoot: URL? = MCPHelperLocator.packageRoot
    ) -> URL? {
        candidates(bundle: bundle, environment: environment, packageRoot: packageRoot).first {
            FileManager.default.isExecutableFile(atPath: MergeCuePaths.fileSystemPath($0))
        }
    }

    public static func candidates(bundle: Bundle, environment: [String: String], packageRoot: URL?) -> [URL] {
        var result: [URL] = []
        if let override = environment[overrideEnvironmentKey], override.hasPrefix("/") {
            result.append(URL(filePath: override))
        }
        if bundle.bundleURL.pathExtension == "app" {
            result.append(bundle.bundleURL.appending(path: "Contents/MacOS/\(executableName)"))
        }
        if let executable = bundle.executableURL?.resolvingSymlinksInPath() {
            result.append(executable.deletingLastPathComponent().appending(path: executableName))
        }
        if let packageRoot {
            for configuration in ["debug", "release"] {
                result.append(packageRoot.appending(path: ".build/\(configuration)/\(executableName)"))
                result.append(packageRoot.appending(path: ".build/arm64-apple-macosx/\(configuration)/\(executableName)"))
            }
        }
        return result
    }

    /// The SwiftPM package root this file was compiled from (development builds only; nil in a shipped app,
    /// where the directory does not exist).
    public static var packageRoot: URL? {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = root.appending(path: "Package.swift")
        return FileManager.default.fileExists(atPath: MergeCuePaths.fileSystemPath(manifest)) ? root : nil
    }
}
