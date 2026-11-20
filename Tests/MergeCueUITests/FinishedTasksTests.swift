import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

/// Finished tasks leave the Tasks list and are grouped by pull/merge request on their own screen.
@Suite("Finished tasks")
struct FinishedTasksTests {
    func finishing(_ record: TaskRecord, as state: TaskState, at date: Date, number: Int? = nil) throws -> TaskRecord {
        var copy = record
        copy.task.id = try #require(TaskID(rawValue: "mc_" + String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(6))))
        copy.task.state = state
        copy.task.lease = nil
        if let number {
            let key = copy.task.origin.changeRequest
            copy.task.origin.changeRequest = ChangeRequestKey(repo: key.repo, remoteID: String(number), number: number)
        }
        copy.activities.append(TaskActivity(
            id: "act_" + copy.id.rawValue, taskID: copy.id, at: date, actor: .user, kind: state == .done ? .completed : state == .cancelled ? .cancelled : .dismissed,
            message: "Finished", fromState: record.task.state, toState: state
        ))
        return copy
    }

    @Test func groupsByChangeRequestNewestFirst() throws {
        let state = previewState()
        let base = try #require(state.task(in: .readyForReview))
        let a1 = try finishing(base, as: .done, at: testNow.addingTimeInterval(-86_400), number: 7)
        let a2 = try finishing(base, as: .dismissed, at: testNow.addingTimeInterval(-3_600), number: 7)
        let b1 = try finishing(base, as: .cancelled, at: testNow.addingTimeInterval(-7_200), number: 8)
        let open = base
        let groups = FinishedTasks.groups([a1, open, b1, a2], titles: [a1.task.origin.changeRequest: "Retry webhooks"])
        #expect(groups.map(\.changeRequest.number) == [7, 8], "the PR whose task finished last comes first")
        #expect(groups[0].records.map(\.id) == [a2.id, a1.id], "newest task first inside a PR")
        #expect(groups[0].title == "Retry webhooks")
        #expect(groups[0].latest == testNow.addingTimeInterval(-3_600))
        #expect(groups[1].title == b1.task.origin.title, "falls back to the task's own title without a snapshot")
        #expect(!groups.flatMap(\.records).contains { $0.id == open.id }, "open tasks never appear")
        #expect(FinishedTasks.finishedAt(a1) == testNow.addingTimeInterval(-86_400))
    }

    @Test func taskListHidesFinishedTasksByDefault() throws {
        var state = previewState()
        let base = try #require(state.task(in: .readyForReview))
        state.tasks.append(try finishing(base, as: .done, at: testNow))
        #expect(state.tasks.contains(where: FinishedTasks.isFinished))
        #expect(TaskGroup.allCases.filter { $0 != .finished }.allSatisfy { group in
            state.tasks.filter { TaskGroup.group(for: $0.task.state) == group }.allSatisfy { !FinishedTasks.isFinished($0) }
        })
    }
}
