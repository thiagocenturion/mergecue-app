import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@Suite("Status set by hand (D40)")
@MainActor
struct TaskStatusMenuTests {
    @Test func choicesFollowTheStateMachine() async throws {
        let model = await makeModel()
        let waiting = try #require(model.state.task(in: .waitingForAgent))
        #expect(TaskStatusChoice.current(waiting.state) == .waiting)
        #expect(TaskStatusChoice.waiting.command(for: waiting.task) == nil)
        #expect(TaskStatusChoice.inProgress.command(for: waiting.task)?.description == "startTaskManually")
        #expect(TaskStatusChoice.done.command(for: waiting.task)?.description == "markTaskDone")

        _ = await model.send(.startTaskManually(waiting.id))
        let started = try #require(model.task(waiting.id))
        #expect(started.state == .working)
        #expect(started.isManuallyInProgress)
        #expect(TaskStateStyle.label(started) == "In progress")
        #expect(TaskStatusChoice.waiting.command(for: started.task)?.description == "retryTask")

        _ = await model.send(.markTaskDone(waiting.id))
        let done = try #require(model.task(waiting.id))
        #expect(done.state == .done)
        #expect(TaskStatusChoice.waiting.command(for: done.task)?.description == "reopenTask")
        #expect(TaskStatusChoice.inProgress.command(for: done.task) == nil)
    }
}
