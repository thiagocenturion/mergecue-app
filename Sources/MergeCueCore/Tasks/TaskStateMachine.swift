import Foundation

/// Why a transition was rejected. The engine maps `terminalState` to the IPC `terminal_state` error and the
/// other cases to `invalid_transition`.
public enum TaskTransitionError: Error, Sendable, Hashable, LocalizedError {
    /// The task is `done`/`cancelled`/`dismissed`; only a user `reopen` can leave it.
    case terminalState(TaskState, trigger: TaskTrigger, actor: TransitionActor)
    /// The (state, trigger) pair is legal, but not for this actor (e.g. an agent trying to cancel).
    case actorNotPermitted(TaskState, trigger: TaskTrigger, actor: TransitionActor)
    /// The trigger is not allowed from this state for anyone.
    case invalidTransition(TaskState, trigger: TaskTrigger, actor: TransitionActor)

    public var from: TaskState {
        switch self {
        case .terminalState(let state, _, _), .actorNotPermitted(let state, _, _), .invalidTransition(let state, _, _): state
        }
    }

    public var trigger: TaskTrigger {
        switch self {
        case .terminalState(_, let trigger, _), .actorNotPermitted(_, let trigger, _), .invalidTransition(_, let trigger, _): trigger
        }
    }

    public var actor: TransitionActor {
        switch self {
        case .terminalState(_, _, let actor), .actorNotPermitted(_, _, let actor), .invalidTransition(_, _, let actor): actor
        }
    }

    public var errorDescription: String? {
        switch self {
        case .terminalState(let state, let trigger, let actor):
            "Task is \(state.rawValue); \(actor.rawValue) cannot \(trigger.name) a finished task (only the user can reopen it)."
        case .actorNotPermitted(let state, let trigger, let actor):
            "\(actor.rawValue) is not allowed to \(trigger.name) a task in \(state.rawValue)."
        case .invalidTransition(let state, let trigger, let actor):
            "Invalid transition: \(trigger.name) by \(actor.rawValue) from \(state.rawValue)."
        }
    }
}

/// The pure task transition table (docs/ARCHITECTURE.md §2.6). Anything not listed is illegal.
///
/// | From | Trigger (actor) | To |
/// | --- | --- | --- |
/// | *(create)* | — | `waiting_for_agent` (`initialState`) |
/// | waiting_for_agent, stale | claim (agent) | working |
/// | working | heartbeat / progress / reportChanges / reportTests (agent) | working |
/// | working | submitResult (agent) | ready_for_review |
/// | working | fail(retryable: true/false) (agent) | failed |
/// | working | agentBlocked (agent) | blocked |
/// | working | leaseExpired (system) | stale (never done) |
/// | ready_for_review | approveAction(kind) (user) | approved_action |
/// | ready_for_review | rejectResult (user) | waiting_for_agent |
/// | ready_for_review | markDone (user) | done |
/// | approved_action | markDone (system) | done — the final approved action succeeded |
/// | approved_action | actionSucceeded (system) | ready_for_review — more actions remain |
/// | approved_action | actionBlocked (system) | blocked |
/// | approved_action | actionFailed (system) | ready_for_review |
/// | any non-terminal | cancel (user) | cancelled |
/// | any non-terminal | dismiss (user) | dismissed |
/// | failed, blocked, stale | retry (user) | waiting_for_agent |
/// | done, cancelled, dismissed | reopen (user) | waiting_for_agent |
/// | waiting_for_agent, working | block (system or user) | blocked |
/// | blocked | unblock (user) | waiting_for_agent |
public enum TaskStateMachine {
    /// The only state a task can be created in.
    public static let initialState: TaskState = .waitingForAgent

    /// Returns the next state or throws `TaskTransitionError` for an illegal (state, trigger, actor) combination.
    public static func next(from state: TaskState, on trigger: TaskTrigger, by actor: TransitionActor) throws(TaskTransitionError) -> TaskState {
        if let next = transition(from: state, on: trigger, by: actor) {
            return next
        }
        if state.isTerminal {
            throw .terminalState(state, trigger: trigger, actor: actor)
        }
        if TransitionActor.allCases.contains(where: { transition(from: state, on: trigger, by: $0) != nil }) {
            throw .actorNotPermitted(state, trigger: trigger, actor: actor)
        }
        throw .invalidTransition(state, trigger: trigger, actor: actor)
    }

    /// Whether the transition is legal.
    public static func canTransition(from state: TaskState, on trigger: TaskTrigger, by actor: TransitionActor) -> Bool {
        transition(from: state, on: trigger, by: actor) != nil
    }

    /// Every concrete trigger `actor` may apply in `state`, in `TaskTrigger.allTriggers` order.
    public static func allowedTriggers(from state: TaskState, by actor: TransitionActor) -> [TaskTrigger] {
        TaskTrigger.allTriggers.filter { transition(from: state, on: $0, by: actor) != nil }
    }

    /// The trigger the engine passes after an approved remote action succeeded: `.markDone` when it was the last
    /// action (→ `done`), `.actionSucceeded` when more actions remain (→ `ready_for_review`).
    public static func triggerAfterSuccessfulAction(moreActionsRemain: Bool) -> TaskTrigger {
        moreActionsRemain ? .actionSucceeded : .markDone
    }

    // MARK: Table

    private static func transition(from state: TaskState, on trigger: TaskTrigger, by actor: TransitionActor) -> TaskState? {
        switch (state, trigger, actor) {
        // Agent claims (fresh or re-claim of a stale task with a new lease).
        case (.waitingForAgent, .claim, .agent), (.stale, .claim, .agent):
            return .working

        // Agent activity while holding the lease.
        case (.working, .heartbeat, .agent), (.working, .progress, .agent),
             (.working, .reportChanges, .agent), (.working, .reportTests, .agent):
            return .working
        case (.working, .submitResult, .agent):
            return .readyForReview
        case (.working, .fail, .agent):
            return .failed
        case (.working, .agentBlocked, .agent):
            return .blocked

        // Lease expiry never completes a task.
        case (.working, .leaseExpired, .system):
            return .stale

        // User review gate.
        case (.readyForReview, .approveAction, .user):
            return .approvedAction
        case (.readyForReview, .rejectResult, .user):
            return .waitingForAgent
        case (.readyForReview, .markDone, .user):
            return .done

        // Outcome of an approved remote action (performed by the engine).
        case (.approvedAction, .markDone, .system):
            return .done
        case (.approvedAction, .actionSucceeded, .system):
            return .readyForReview
        case (.approvedAction, .actionBlocked, .system):
            return .blocked
        case (.approvedAction, .actionFailed, .system):
            return .readyForReview

        // Lifecycle (user only).
        case (_, .cancel, .user) where !state.isTerminal:
            return .cancelled
        case (_, .dismiss, .user) where !state.isTerminal:
            return .dismissed
        case (.failed, .retry, .user), (.blocked, .retry, .user), (.stale, .retry, .user):
            return .waitingForAgent
        case (_, .reopen, .user) where state.isTerminal:
            return .waitingForAgent

        // Blocking.
        case (.waitingForAgent, .block, .system), (.waitingForAgent, .block, .user),
             (.working, .block, .system), (.working, .block, .user):
            return .blocked
        case (.blocked, .unblock, .user):
            return .waitingForAgent

        default:
            return nil
        }
    }
}
