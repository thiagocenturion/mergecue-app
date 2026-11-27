import Foundation
import MergeCueCore

/// Finished tasks (done, cancelled, dismissed) of one pull/merge request, newest first.
public nonisolated struct FinishedTaskGroup: Sendable, Hashable, Identifiable {
    public var changeRequest: ChangeRequestKey
    public var providerKind: ProviderKind
    public var repoFullPath: String
    /// The PR/MR title (untrusted provider text, display only).
    public var title: String
    public var records: [TaskRecord]
    /// When the newest task of the group finished.
    public var latest: Date

    public var id: String { changeRequest.id }
    /// "acme/payments-api #42" (GitLab: "!42").
    public var refText: String { "\(repoFullPath) \(providerKind.formattedNumber(changeRequest.number))" }
}

/// Groups finished tasks by pull/merge request for the Finished tasks screen (open tasks stay on the Tasks list).
public nonisolated enum FinishedTasks {
    /// Whether a task belongs on the Finished screen.
    public static func isFinished(_ record: TaskRecord) -> Bool {
        TaskGroup.group(for: record.task.state) == .finished
    }

    /// When the task finished: its last move into a terminal state, else its last update.
    public static func finishedAt(_ record: TaskRecord) -> Date {
        record.activities.last { $0.toState.map { TaskGroup.group(for: $0) == .finished } ?? false }?.at ?? record.task.updatedAt
    }

    /// One group per PR/MR, the most recently finished PR/MR first; tasks newest first inside each group.
    /// `titles` gives the current PR/MR title when MergeCue still has its snapshot.
    public static func groups(_ tasks: [TaskRecord], titles: [ChangeRequestKey: String] = [:]) -> [FinishedTaskGroup] {
        let finished = tasks.filter(isFinished)
        let byChangeRequest = Dictionary(grouping: finished) { $0.task.origin.changeRequest }
        return byChangeRequest.compactMap { key, records -> FinishedTaskGroup? in
            let sorted = records.sorted { finishedAt($0) > finishedAt($1) }
            guard let first = sorted.first else { return nil }
            return FinishedTaskGroup(
                changeRequest: key,
                providerKind: first.task.origin.providerKind,
                repoFullPath: first.task.origin.changeRequestRef.repoFullPath,
                title: titles[key] ?? first.task.origin.title,
                records: sorted,
                latest: finishedAt(first)
            )
        }
        .sorted { $0.latest != $1.latest ? $0.latest > $1.latest : $0.id < $1.id }
    }
}
