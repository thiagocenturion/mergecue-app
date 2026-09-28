import Foundation

/// Proof that the user explicitly approved one specific `MCPRegistrationPlan` in the UI.
///
/// There is no public initializer and the type is not `Codable`: the only way to obtain one is
/// `RegistrationConsent.userConfirmed(_:)`, which is main-actor isolated and must be called only from the
/// confirmation button handler of the sheet that showed the plan's command, config snippet, touched files and
/// backup location. The consent is bound to the plan's digest and action, expires after `validity`, and
/// `AgentRegistrar` accepts each consent once.
public struct RegistrationConsent: Sendable, Hashable {
    /// How long a confirmation stays usable.
    public static let validity: TimeInterval = 10 * 60

    public let id: UUID
    public let planDigest: String
    public let action: RegistrationAction
    public let agent: AgentKind
    public let grantedAt: Date

    private init(plan: MCPRegistrationPlan, grantedAt: Date) {
        id = UUID()
        planDigest = plan.digest
        action = plan.action
        agent = plan.agent
        self.grantedAt = grantedAt
    }

    /// Records that the user confirmed `plan` after reviewing it. Call only from an explicit UI confirmation.
    @MainActor
    public static func userConfirmed(_ plan: MCPRegistrationPlan, at date: Date = Date()) -> RegistrationConsent {
        RegistrationConsent(plan: plan, grantedAt: date)
    }

    /// Whether this consent covers `plan` at `now`.
    public func covers(_ plan: MCPRegistrationPlan, now: Date) -> Bool {
        planDigest == plan.digest && action == plan.action && agent == plan.agent
            && now >= grantedAt.addingTimeInterval(-60) && now.timeIntervalSince(grantedAt) <= Self.validity
    }
}
