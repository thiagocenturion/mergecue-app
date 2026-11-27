import Foundation

/// When a command's result message becomes an in-app banner (toast). Banners are for what the screen cannot show:
/// problems (attention, critical) always; success and neutral messages only for commands whose effect happens
/// out of sight (the clipboard, a remote write, a file, deleted data, an agent's configuration, a diagnostic) or
/// that explain why nothing happened. Everything else (acknowledge, snooze, task status, rules, settings) is
/// silent: the change is already visible where the owner clicked.
extension AppCommand {
    /// Whether a success or neutral result message of this command is shown as a banner.
    nonisolated var announcesSuccess: Bool {
        switch self {
        case .copyHandoffCommand, .openPromptInAgent, .openReviewInAgent, .openURL, .approvePreview, .approveChangeRequest, .cleanUpWorktrees, .disconnectAccount,
             .applyAgentRegistration, .deleteAgentConfigBackups, .findCheckouts, .sendTestNotification,
             .exportDatabase, .resetAllData:
            true
        default:
            false
        }
    }
}

extension AppCommandResult {
    /// Whether this result's message is shown as a banner after `command`.
    nonisolated func showsBanner(after command: AppCommand, tone: Tone) -> Bool {
        guard message != nil else { return false }
        return tone == .attention || tone == .critical || command.announcesSuccess
    }
}
