import Foundation

/// What a tool call needs before it may run.
///
/// The three answers are the whole safety model. A default is derived from the
/// tool's risk, so a new read tool is usable without a settings change and a
/// new write tool is not.
public enum ToolPolicy: String, Codable, Sendable, CaseIterable, Comparable {
    /// Run without asking.
    case allow
    /// Ask the person first, every time.
    case ask
    /// Do not run, and do not offer the tool.
    case never

    /// The order of the three answers, from least to most restrictive.
    public var order: Int {
        switch self {
        case .allow: 0
        case .ask: 1
        case .never: 2
        }
    }

    public static func < (lhs: ToolPolicy, rhs: ToolPolicy) -> Bool {
        lhs.order < rhs.order
    }

    /// The shipped default for a risk. Nothing is approved without asking
    /// unless it only reads.
    ///
    /// - Parameter risk: what the tool declared it does.
    /// - Returns: the policy a person would have chosen for it.
    public static func derived(from risk: ToolRisk) -> ToolPolicy {
        switch risk {
        case .read: .allow
        case .write, .destructive, .external: .ask
        }
    }

    /// The policy after the safety floor is applied.
    ///
    /// A destructive or external call always confirms, whatever the stored
    /// policy says. That is what "never auto" means here: a hand-edited
    /// configuration, or a future settings bug, cannot approve sending a
    /// message or trashing a file without a person seeing it. Only `never`
    /// outranks the floor.
    ///
    /// - Parameter risk: what the tool declared it does.
    /// - Returns: the policy the registry acts on.
    public func enforced(for risk: ToolRisk) -> ToolPolicy {
        guard self != .never else { return .never }
        switch risk {
        case .destructive, .external: return .ask
        case .read, .write: return self
        }
    }

    /// The sentence the settings row shows under the picker.
    public var explanation: String {
        switch self {
        case .allow: "Runs without asking."
        case .ask: "Asks you in the HUD before it runs."
        case .never: "Not offered to the assistant."
        }
    }
}

/// The policy a call actually went through, for the log and for the HUD.
public enum ToolDecision: String, Sendable, Equatable {
    /// The policy allowed it and it ran.
    case allowed
    /// The person confirmed it and it ran.
    case confirmed
    /// The person declined it, so nothing happened.
    case declined
    /// The stored policy is `never`.
    case blockedByPolicy
    /// The tool or connector is not available this turn.
    case unavailable
    /// The arguments did not match the schema, so nothing happened.
    case invalidArguments

    /// Whether the tool ran. Only these decisions have side effects.
    public var ran: Bool {
        self == .allowed || self == .confirmed
    }
}

/// Reads the policy for a tool, honouring a per-tool override.
public struct ToolPolicyTable: Sendable, Equatable {
    /// The overrides a person set, keyed by tool name.
    public let overrides: [String: ToolPolicy]

    /// Creates a table.
    public init(overrides: [String: ToolPolicy] = [:]) {
        self.overrides = overrides
    }

    /// The policy for one tool: the override when there is one, the risk
    /// default otherwise.
    public func policy(for tool: ConnectorTool) -> ToolPolicy {
        (overrides[tool.name] ?? ToolPolicy.derived(from: tool.risk)).enforced(for: tool.risk)
    }

    /// The stored override, if one was set.
    public func override(forTool name: String) -> ToolPolicy? {
        overrides[name]
    }
}
