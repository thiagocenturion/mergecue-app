import Foundation
import MergeCueCore
import MergeCueEngine

// Mapping of the engine's snapshot to the UI's `AppState`.

extension EngineBackend {
    /// `EngineSnapshot` (+ agents, runtime info, instruction files found in mapped checkouts) → `AppState`.
    nonisolated static func makeState(
        _ snapshot: EngineSnapshot,
        agents: [AgentStatus],
        runtime: RuntimeInfo?,
        instructionFileNames: [String],
        fileManager: FileManager = .default
    ) -> AppState {
        let accounts = snapshot.accounts.map {
            AccountState(account: $0.account, status: $0.status, capabilities: $0.capabilities)
        }
        let tasks = snapshot.tasks.map { detail -> TaskRecord in
            var task = detail.task
            // The approval history lives in its own table too; keep whichever is more complete.
            if detail.approvals.count > task.approvals.count { task.approvals = detail.approvals }
            return TaskRecord(task: task, activities: detail.activities, artifacts: detail.artifacts)
        }
        var checkoutPaths = Set(snapshot.mappings.map(\.checkoutPath))
        for task in tasks {
            if let mapped = task.task.checkout?.mappedCheckoutPath { checkoutPaths.insert(mapped) }
        }
        return AppState(
            accounts: accounts,
            attention: snapshot.attention,
            tasks: tasks,
            changeRequests: snapshot.changeRequests,
            rules: snapshot.rules,
            mappings: snapshot.mappings,
            agents: agents,
            instructionFiles: instructionFiles(in: checkoutPaths, names: instructionFileNames, fileManager: fileManager),
            runtime: runtime,
            notificationsPausedUntil: snapshot.notificationsPausedUntil,
            quietHours: snapshot.quietHours,
            lastRefreshAt: snapshot.lastRefreshAt
        )
    }

    /// Which of `names` exist as regular files at the root of each checkout. Existence only: MergeCue never reads
    /// them (the agent does, from its own checkout).
    nonisolated static func instructionFiles(in checkouts: Set<String>, names: [String], fileManager: FileManager) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for checkout in checkouts {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: checkout, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let found = names.filter { name in
                var isDir: ObjCBool = false
                let path = (checkout as NSString).appendingPathComponent(name)
                return fileManager.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            }
            result[checkout] = found
        }
        return result
    }

    /// Engine preview → the approval sheet's `ActionPreview` (same id and fingerprint, so approving matches it).
    nonisolated static func actionPreview(_ preview: ReviewPreview) -> ActionPreview {
        var warnings = preview.warnings
        if preview.isSimulated {
            warnings.append("Demo data: approving goes through the real review gate, but the provider is a fixture — nothing reaches GitHub, GitLab or Bitbucket.")
        }
        return ActionPreview(
            id: preview.id, taskID: preview.taskID, action: preview.action, title: preview.title, target: preview.target,
            body: preview.body, headSHA: preview.headSHA, fingerprint: preview.fingerprint, warnings: warnings,
            canApprove: preview.canApprove, blockedReason: preview.blockedReason, createdAt: preview.createdAt,
            isSimulated: preview.isSimulated
        )
    }

    /// Any error of an engine/runtime call → a user-facing `AppBackendError` (messages redacted, never a token).
    nonisolated static func backendError(_ error: any Error) -> AppBackendError {
        switch error {
        case let error as AppBackendError:
            return error
        case let error as EngineError:
            switch error {
            case .notFound(let what): return .notFound(what)
            case .invalidTransition(let message): return .invalidTransition(message)
            case .writesDisabled(let account): return .writesDisabled(account: account)
            case .disabledByPolicy(let action): return .disabledByPolicy(action)
            case .unsupported(let message): return .unsupported(message)
            case .previewExpired: return .previewExpired
            case .invalidInput(let message): return .invalidInput(message)
            case .conflict(let message): return .invalidTransition(message)
            case .provider(let providerError): return .failed(providerMessage(providerError))
            case .failed(let message): return .failed(message)
            }
        case let error as LocalizedError:
            return .failed(SecretRedactor.redact(error.errorDescription ?? error.localizedDescription))
        default:
            return .failed(SecretRedactor.redact(error.localizedDescription))
        }
    }

    /// Provider failures in the owner's terms (connect probe, check logs, writes).
    nonisolated static func providerMessage(_ error: ProviderError) -> String {
        let detail = SecretRedactor.redact(error.errorDescription ?? error.code)
        switch error {
        case .unauthorized:
            return "The provider rejected the token (\(detail)). Check it was copied completely and hasn't expired."
        case .forbidden(let scope?, _):
            return "The token is missing the \(scope) scope. Create one with the listed scopes and connect again."
        case .offline:
            return "You're offline. MergeCue retries when the network is back."
        default:
            return detail
        }
    }
}
