import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore

/// Maps internal failures to the two public error surfaces: `IPCError` (agents) and `EngineError` (UI).
enum EngineErrorMapping {
    /// IPC/MCP view of any failure. Messages are redacted by the IPC server again before they leave the process.
    static func ipcError(from error: any Error) -> IPCError {
        switch error {
        case let error as IPCError:
            return error
        case let error as TaskTransitionError:
            return ipcError(from: error)
        case let error as StoreError:
            switch error {
            case .versionConflict(let current):
                return IPCError(
                    code: .versionConflict,
                    message: "The task changed in the meantime (current version \(current)). Call get_task and retry with the current version.",
                    retryable: true,
                    data: ["current_version": .number(Double(current))]
                )
            case .notFound:
                return IPCError(code: .notFound, message: "The requested record does not exist.")
            case .invalidValue(let message):
                return IPCError.validationFailed(message)
            default:
                return IPCError.internalError("MergeCue could not access its database.", retryable: error.isBusy)
            }
        case let error as EngineError:
            switch error {
            case .notFound(let what): return IPCError(code: .notFound, message: "\(what) was not found.")
            case .invalidTransition(let message): return IPCError(code: .invalidTransition, message: message)
            case .unsupported(let message): return IPCError(code: .unsupported, message: message)
            case .invalidInput(let message): return IPCError.invalidParams(message)
            case .conflict(let message): return IPCError(code: .versionConflict, message: message, retryable: true)
            case .provider(let providerError): return ipcError(from: providerError)
            case .writesDisabled, .disabledByPolicy, .previewExpired:
                return IPCError(code: .unsupported, message: error.errorDescription ?? "Not available.")
            case .failed(let message): return IPCError.internalError(message)
            }
        case let error as ProviderError:
            return ipcError(from: error)
        case is CancellationError:
            return IPCError.internalError("The request was cancelled.", retryable: true, reason: "cancelled")
        default:
            if let providerError = ProviderError.classify(error) {
                return ipcError(from: providerError)
            }
            return IPCError.internalError("MergeCue could not complete the request.")
        }
    }

    static func ipcError(from error: TaskTransitionError) -> IPCError {
        switch error {
        case .terminalState(let state, _, _):
            IPCError(
                code: .terminalState,
                message: "Task is \(state.rawValue); finished tasks cannot be changed by an agent (only the owner can reopen it).",
                data: ["state": .string(state.rawValue)]
            )
        case .actorNotPermitted, .invalidTransition:
            IPCError(
                code: .invalidTransition,
                message: error.errorDescription ?? "Invalid transition.",
                data: ["state": .string(error.from.rawValue), "trigger": .string(error.trigger.name)]
            )
        }
    }

    static func ipcError(from error: ProviderError) -> IPCError {
        let message = error.errorDescription ?? error.code
        switch error {
        case .unsupported: return IPCError(code: .unsupported, message: message)
        case .notFound: return IPCError(code: .notFound, message: message)
        case .rateLimited: return IPCError(code: .rateLimited, message: message, retryable: true)
        default: return IPCError.internalError(message, retryable: error.isRetryable, reason: "provider_\(error.code)")
        }
    }

    /// UI view of any failure.
    static func engineError(from error: any Error) -> EngineError {
        switch error {
        case let error as EngineError:
            return error
        case let error as TaskTransitionError:
            return .invalidTransition(error.errorDescription ?? "This action is not available for the task's state.")
        case let error as StoreError:
            switch error {
            case .versionConflict: return .conflict("The task changed in the meantime. Reload and try again.")
            case .notFound: return .notFound("The record")
            case .invalidValue(let message): return .invalidInput(message)
            default: return .failed(error.errorDescription ?? "Database error.")
            }
        case let error as ProviderError:
            return .provider(error)
        case let error as IPCError:
            return .failed(error.message)
        case let error as WorkspaceError:
            return .failed(error.errorDescription ?? "Workspace error.")
        case is CancellationError:
            return .failed("Cancelled.")
        default:
            if let providerError = ProviderError.classify(error) {
                return .provider(providerError)
            }
            return .failed(SecretRedactor.redact(error.localizedDescription))
        }
    }
}
