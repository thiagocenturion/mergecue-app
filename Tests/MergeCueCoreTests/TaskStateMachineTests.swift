import Foundation
import MergeCueCore
import Testing

/// The required transition table from docs/ARCHITECTURE.md §2.6, written independently of the implementation.
private enum ExpectedTable {
    struct Row: Hashable {
        let from: TaskState
        let trigger: TaskTrigger
        let actor: TransitionActor
    }

    /// Every concrete trigger (spelled out here so a new trigger case forces a test update).
    static let triggers: [TaskTrigger] = [
        .claim, .heartbeat, .progress, .reportChanges, .reportTests, .submitResult,
        .fail(retryable: true), .fail(retryable: false), .agentBlocked, .leaseExpired,
        .approveAction(.applyPatch), .approveAction(.postReply), .approveAction(.resolveThread),
        .approveAction(.requestChanges), .approveAction(.commitAndPush), .approveAction(.merge),
        .rejectResult, .actionSucceeded, .actionBlocked, .actionFailed, .markDone,
        .cancel, .dismiss, .retry, .reopen, .block, .unblock,
    ]

    static let nonTerminal: [TaskState] = [.waitingForAgent, .working, .readyForReview, .approvedAction, .blocked, .failed, .stale]
    static let terminal: [TaskState] = [.done, .cancelled, .dismissed]

    static let rows: [Row: TaskState] = {
        var table: [Row: TaskState] = [:]
        func add(_ from: [TaskState], _ triggers: [TaskTrigger], _ actors: [TransitionActor], _ to: TaskState) {
            for state in from {
                for trigger in triggers {
                    for actor in actors {
                        let row = Row(from: state, trigger: trigger, actor: actor)
                        precondition(table[row] == nil, "duplicate row \(row)")
                        table[row] = to
                    }
                }
            }
        }
        add([.waitingForAgent], [.claim], [.agent], .working)
        add([.stale], [.claim], [.agent], .working)
        add([.working], [.heartbeat, .progress, .reportChanges, .reportTests], [.agent], .working)
        add([.working], [.submitResult], [.agent], .readyForReview)
        add([.working], [.fail(retryable: true), .fail(retryable: false)], [.agent], .failed)
        add([.working], [.agentBlocked], [.agent], .blocked)
        add([.working], [.leaseExpired], [.system], .stale)
        add([.readyForReview], RemoteActionKind.allCases.map { .approveAction($0) }, [.user], .approvedAction)
        add([.readyForReview], [.rejectResult], [.user], .waitingForAgent)
        add([.readyForReview], [.markDone], [.user], .done)
        add([.approvedAction], [.markDone], [.system], .done)
        add([.approvedAction], [.actionSucceeded], [.system], .readyForReview)
        add([.approvedAction], [.actionBlocked], [.system], .blocked)
        add([.approvedAction], [.actionFailed], [.system], .readyForReview)
        add(nonTerminal, [.cancel], [.user], .cancelled)
        add(nonTerminal, [.dismiss], [.user], .dismissed)
        add([.failed, .blocked, .stale], [.retry], [.user], .waitingForAgent)
        add(terminal, [.reopen], [.user], .waitingForAgent)
        add([.waitingForAgent, .working], [.block], [.system, .user], .blocked)
        add([.blocked], [.unblock], [.user], .waitingForAgent)
        return table
    }()
}

@Suite("Task state machine")
struct TaskStateMachineTests {
    // MARK: Exhaustive table

    @Test func triggerCatalogueIsComplete() {
        #expect(TaskTrigger.allTriggers == ExpectedTable.triggers)
        #expect(ExpectedTable.triggers.count == 27)
        #expect(TaskState.allCases.count == 10)
        #expect(TransitionActor.allCases.count == 3)
    }

    /// Every (state × trigger × actor) combination: legal ones reach exactly the table's target, all others throw.
    @Test(arguments: TaskState.allCases)
    func tableIsExact(_ state: TaskState) {
        for trigger in ExpectedTable.triggers {
            for actor in TransitionActor.allCases {
                let expected = ExpectedTable.rows[.init(from: state, trigger: trigger, actor: actor)]
                let actual: TaskState?
                do {
                    actual = try TaskStateMachine.next(from: state, on: trigger, by: actor)
                } catch {
                    actual = nil
                }
                #expect(actual == expected, "\(state.rawValue) --\(trigger.name)/\(actor.rawValue)--> \(String(describing: actual)), expected \(String(describing: expected))")
                #expect(TaskStateMachine.canTransition(from: state, on: trigger, by: actor) == (expected != nil))
            }
        }
    }

    @Test func tableSize() {
        var legal = 0
        for state in TaskState.allCases {
            for actor in TransitionActor.allCases {
                legal += TaskStateMachine.allowedTriggers(from: state, by: actor).count
            }
        }
        #expect(legal == ExpectedTable.rows.count)
        #expect(ExpectedTable.rows.count == 48)
    }

    @Test(arguments: TaskState.allCases)
    func allowedTriggersMatchTheTable(_ state: TaskState) {
        for actor in TransitionActor.allCases {
            let expected = ExpectedTable.triggers.filter { ExpectedTable.rows[.init(from: state, trigger: $0, actor: actor)] != nil }
            #expect(TaskStateMachine.allowedTriggers(from: state, by: actor) == expected)
        }
    }

    @Test func errorClassification() {
        for state in TaskState.allCases {
            for trigger in ExpectedTable.triggers {
                for actor in TransitionActor.allCases where ExpectedTable.rows[.init(from: state, trigger: trigger, actor: actor)] == nil {
                    let legalForSomeoneElse = TransitionActor.allCases.contains {
                        ExpectedTable.rows[.init(from: state, trigger: trigger, actor: $0)] != nil
                    }
                    do {
                        _ = try TaskStateMachine.next(from: state, on: trigger, by: actor)
                        Issue.record("expected rejection for \(state) \(trigger) \(actor)")
                    } catch {
                        #expect(error.from == state && error.trigger == trigger && error.actor == actor)
                        switch error {
                        case .terminalState:
                            #expect(state.isTerminal)
                        case .actorNotPermitted:
                            #expect(!state.isTerminal && legalForSomeoneElse)
                        case .invalidTransition:
                            #expect(!state.isTerminal && !legalForSomeoneElse)
                        }
                        #expect(error.errorDescription?.isEmpty == false)
                    }
                }
            }
        }
    }

    // MARK: Named scenarios

    private func run(_ steps: [(TaskTrigger, TransitionActor)], from start: TaskState = TaskStateMachine.initialState) throws -> [TaskState] {
        var state = start
        var path = [state]
        for (trigger, actor) in steps {
            state = try TaskStateMachine.next(from: state, on: trigger, by: actor)
            path.append(state)
        }
        return path
    }

    @Test func creationStateIsWaitingForAgent() {
        #expect(TaskStateMachine.initialState == .waitingForAgent)
    }

    @Test func claimSubmitApproveDone() throws {
        let path = try run([
            (.claim, .agent),
            (.heartbeat, .agent),
            (.progress, .agent),
            (.reportChanges, .agent),
            (.reportTests, .agent),
            (.submitResult, .agent),
            (.approveAction(.postReply), .user),
            (TaskStateMachine.triggerAfterSuccessfulAction(moreActionsRemain: false), .system),
        ])
        #expect(path == [.waitingForAgent, .working, .working, .working, .working, .working, .readyForReview, .approvedAction, .done])
    }

    @Test func multipleApprovedActionsReturnToReview() throws {
        let path = try run([
            (.claim, .agent),
            (.submitResult, .agent),
            (.approveAction(.postReply), .user),
            (TaskStateMachine.triggerAfterSuccessfulAction(moreActionsRemain: true), .system),
            (.approveAction(.resolveThread), .user),
            (TaskStateMachine.triggerAfterSuccessfulAction(moreActionsRemain: false), .system),
        ])
        #expect(path == [.waitingForAgent, .working, .readyForReview, .approvedAction, .readyForReview, .approvedAction, .done])
    }

    @Test func reviewWithoutRemoteActionCanBeMarkedDoneByUser() throws {
        #expect(try run([(.claim, .agent), (.submitResult, .agent), (.markDone, .user)]).last == .done)
        #expect(throws: TaskTransitionError.self) { try TaskStateMachine.next(from: .readyForReview, on: .markDone, by: .agent) }
        #expect(throws: TaskTransitionError.self) { try TaskStateMachine.next(from: .readyForReview, on: .markDone, by: .system) }
    }

    @Test func actionFailureAndBlockOutcomes() throws {
        #expect(try TaskStateMachine.next(from: .approvedAction, on: .actionFailed, by: .system) == .readyForReview)
        #expect(try TaskStateMachine.next(from: .approvedAction, on: .actionBlocked, by: .system) == .blocked)
        #expect(throws: TaskTransitionError.self) { try TaskStateMachine.next(from: .approvedAction, on: .actionSucceeded, by: .user) }
    }

    @Test func leaseExpiryMakesTaskStaleNeverDone() throws {
        #expect(try TaskStateMachine.next(from: .working, on: .leaseExpired, by: .system) == .stale)
        #expect(throws: TaskTransitionError.self) { try TaskStateMachine.next(from: .working, on: .leaseExpired, by: .agent) }
        for trigger in [TaskTrigger.submitResult, .markDone, .heartbeat, .actionSucceeded, .leaseExpired] {
            for actor in TransitionActor.allCases {
                #expect(throws: TaskTransitionError.self) { try TaskStateMachine.next(from: .stale, on: trigger, by: actor) }
            }
        }
    }

    /// Without a user decision nothing can reach `done`: explore every agent/system path.
    @Test func agentsAndSystemAloneCanNeverReachDone() {
        var frontier: [TaskState] = [TaskStateMachine.initialState]
        var seen: Set<TaskState> = [TaskStateMachine.initialState]
        while let state = frontier.popLast() {
            for actor in [TransitionActor.agent, .system] {
                for trigger in TaskStateMachine.allowedTriggers(from: state, by: actor) {
                    guard let next = try? TaskStateMachine.next(from: state, on: trigger, by: actor) else { continue }
                    if seen.insert(next).inserted { frontier.append(next) }
                }
            }
        }
        #expect(!seen.contains(.done))
        #expect(!seen.contains(.approvedAction))
        #expect(seen == [.waitingForAgent, .working, .readyForReview, .failed, .blocked, .stale])
    }

    @Test func staleTaskCanBeReclaimedOrRetried() throws {
        let path = try run([(.claim, .agent), (.leaseExpired, .system), (.claim, .agent), (.submitResult, .agent)])
        #expect(path == [.waitingForAgent, .working, .stale, .working, .readyForReview])
        #expect(try TaskStateMachine.next(from: .stale, on: .retry, by: .user) == .waitingForAgent)
        #expect(throws: TaskTransitionError.self) { try TaskStateMachine.next(from: .stale, on: .retry, by: .agent) }
    }

    @Test(arguments: [TaskState.done, .cancelled, .dismissed])
    func reopenIsUserOnly(_ state: TaskState) throws {
        #expect(try TaskStateMachine.next(from: state, on: .reopen, by: .user) == .waitingForAgent)
        #expect(throws: TaskTransitionError.terminalState(state, trigger: .reopen, actor: .agent)) {
            try TaskStateMachine.next(from: state, on: .reopen, by: .agent)
        }
        #expect(throws: TaskTransitionError.terminalState(state, trigger: .reopen, actor: .system)) {
            try TaskStateMachine.next(from: state, on: .reopen, by: .system)
        }
    }

    @Test(arguments: [TaskState.done, .cancelled, .dismissed])
    func agentsCannotResurrectTerminalStates(_ state: TaskState) {
        for trigger in ExpectedTable.triggers {
            #expect(throws: TaskTransitionError.terminalState(state, trigger: trigger, actor: .agent)) {
                try TaskStateMachine.next(from: state, on: trigger, by: .agent)
            }
        }
        #expect(TaskStateMachine.allowedTriggers(from: state, by: .agent).isEmpty)
        #expect(TaskStateMachine.allowedTriggers(from: state, by: .system).isEmpty)
        #expect(TaskStateMachine.allowedTriggers(from: state, by: .user) == [.reopen])
    }

    @Test(arguments: TaskState.allCases)
    func agentCannotCancelDismissApproveOrDecide(_ state: TaskState) {
        let forbidden: [TaskTrigger] = [.cancel, .dismiss, .markDone, .rejectResult, .retry, .reopen, .unblock, .block, .leaseExpired,
                                        .actionSucceeded, .actionBlocked, .actionFailed]
            + RemoteActionKind.allCases.map { .approveAction($0) }
        for trigger in forbidden {
            #expect(!TaskStateMachine.canTransition(from: state, on: trigger, by: .agent), "\(state) \(trigger.name)")
            #expect(throws: TaskTransitionError.self) { try TaskStateMachine.next(from: state, on: trigger, by: .agent) }
        }
    }

    @Test func agentCancelIsReportedAsActorNotPermitted() {
        #expect(throws: TaskTransitionError.actorNotPermitted(.working, trigger: .cancel, actor: .agent)) {
            try TaskStateMachine.next(from: .working, on: .cancel, by: .agent)
        }
        #expect(throws: TaskTransitionError.actorNotPermitted(.readyForReview, trigger: .approveAction(.merge), actor: .agent)) {
            try TaskStateMachine.next(from: .readyForReview, on: .approveAction(.merge), by: .agent)
        }
        #expect(throws: TaskTransitionError.invalidTransition(.waitingForAgent, trigger: .submitResult, actor: .agent)) {
            try TaskStateMachine.next(from: .waitingForAgent, on: .submitResult, by: .agent)
        }
    }

    @Test func cancelAndDismissFromEveryActiveState() throws {
        for state in ExpectedTable.nonTerminal {
            #expect(try TaskStateMachine.next(from: state, on: .cancel, by: .user) == .cancelled)
            #expect(try TaskStateMachine.next(from: state, on: .dismiss, by: .user) == .dismissed)
        }
    }

    @Test func blockAndUnblock() throws {
        #expect(try run([(.block, .system), (.unblock, .user)]) == [.waitingForAgent, .blocked, .waitingForAgent])
        #expect(try run([(.claim, .agent), (.block, .user), (.retry, .user)]) == [.waitingForAgent, .working, .blocked, .waitingForAgent])
        #expect(try run([(.claim, .agent), (.agentBlocked, .agent)]).last == .blocked)
        #expect(throws: TaskTransitionError.self) { try TaskStateMachine.next(from: .blocked, on: .unblock, by: .system) }
    }

    @Test func failAndRetry() throws {
        #expect(try run([(.claim, .agent), (.fail(retryable: true), .agent), (.retry, .user)]) == [.waitingForAgent, .working, .failed, .waitingForAgent])
        #expect(try run([(.claim, .agent), (.fail(retryable: false), .agent)]).last == .failed)
    }

    @Test func rejectResultReturnsToWaiting() throws {
        #expect(try run([(.claim, .agent), (.submitResult, .agent), (.rejectResult, .user)]).last == .waitingForAgent)
    }

    // MARK: Encoding

    @Test func triggersRoundTripWithStableJSON() throws {
        for trigger in ExpectedTable.triggers {
            #expect(try Fixture.roundTrip(trigger) == trigger)
        }
        #expect(try Fixture.json(TaskTrigger.fail(retryable: true)) == #"{"retryable":true,"type":"fail"}"#)
        #expect(try Fixture.json(TaskTrigger.approveAction(.postReply)) == #"{"action":"post_reply","type":"approve_action"}"#)
        #expect(try Fixture.json(TaskTrigger.leaseExpired) == #"{"type":"lease_expired"}"#)
        #expect(throws: DecodingError.self) { try Fixture.decode(TaskTrigger.self, from: #"{"type":"teleport"}"#) }
    }

    @Test func stateVocabulary() {
        #expect(Set(TaskState.allCases.filter(\.isTerminal)) == [.done, .cancelled, .dismissed])
        #expect(TaskState.active == Set(ExpectedTable.nonTerminal))
        #expect(TaskState.waitingForAgent.rawValue == "waiting_for_agent")
        #expect(TaskState.readyForReview.displayName == "Ready for review")
    }
}
