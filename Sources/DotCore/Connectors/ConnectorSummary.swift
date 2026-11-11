import Foundation

/// One row of the Connectors page.
///
/// Everything the page draws comes from here, so the view has no branch per
/// connector and a new connector appears in Settings without a view change.
public struct ConnectorSummary: Sendable, Equatable, Identifiable {
    /// The connector's id.
    public let id: ConnectorID
    /// The name shown.
    public let displayName: String
    /// The SF Symbol shown.
    public let symbol: String
    /// The sentence under the name.
    public let detail: String
    /// Whether the person switched it on.
    public let isEnabled: Bool
    /// The current permission, including how to fix a refusal.
    public let permission: ConnectorPermission
    /// The tools and their policies.
    public let tools: [ToolSummary]

    /// Creates a summary.
    public init(
        id: ConnectorID,
        displayName: String,
        symbol: String,
        detail: String,
        isEnabled: Bool,
        permission: ConnectorPermission,
        tools: [ToolSummary]
    ) {
        self.id = id
        self.displayName = displayName
        self.symbol = symbol
        self.detail = detail
        self.isEnabled = isEnabled
        self.permission = permission
        self.tools = tools
    }

    /// Whether the tools are actually offered to the model.
    ///
    /// Switched on and permitted are separate switches, and the page shows both
    /// so a person can tell "I turned it off" from "macOS is blocking it".
    public var isAvailable: Bool {
        isEnabled && permission.allowsTools
    }

    /// One tool of a connector, as a settings row.
    public struct ToolSummary: Sendable, Equatable, Identifiable {
        /// The tool's name.
        public let name: String
        /// The name shown.
        public let title: String
        /// What it does.
        public let detail: String
        /// The risk it declared.
        public let risk: ToolRisk
        /// The policy in force, after overrides and the safety floor.
        public let policy: ToolPolicy

        /// The identity the list uses.
        public var id: String { name }

        /// Creates a row.
        public init(name: String, title: String, detail: String, risk: ToolRisk, policy: ToolPolicy) {
            self.name = name
            self.title = title
            self.detail = detail
            self.risk = risk
            self.policy = policy
        }
    }
}
