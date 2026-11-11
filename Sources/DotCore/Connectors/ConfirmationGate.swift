import Foundation

/// What the HUD island shows before a tool runs.
///
/// The sentence is built from validated arguments by the tool itself, so it can
/// never contain a value the schema rejected, and it is the only text a person
/// needs to decide. The rest is context: which connector, what risk, which
/// symbol.
public struct ConfirmationRequest: Sendable, Equatable {
    /// The id of the call being confirmed.
    public let callID: String
    /// The tool's name.
    public let toolName: String
    /// The connector's id, for its symbol and settings row.
    public let connectorID: ConnectorID
    /// The connector's display name.
    public let connectorName: String
    /// What the tool declared it does.
    public let risk: ToolRisk
    /// The sentence to show: "Add a reminder, Send the deck, Friday at 9?"
    public let summary: String

    /// Creates a request.
    public init(
        callID: String,
        toolName: String,
        connectorID: ConnectorID,
        connectorName: String,
        risk: ToolRisk,
        summary: String
    ) {
        self.callID = callID
        self.toolName = toolName
        self.connectorID = connectorID
        self.connectorName = connectorName
        self.risk = risk
        self.summary = summary
    }
}

/// The app's answer to "may this run?".
///
/// The app installs a gate that puts the request in the HUD island and waits.
/// The toolbox awaits it before any call whose policy is `ask`, and a `false`
/// means the connector is never reached: there is no code path from a declined
/// confirmation to a side effect.
public struct ConfirmationGate: Sendable {
    /// The app's implementation.
    private let handler: @Sendable (ConfirmationRequest) async -> Bool

    /// Creates a gate.
    ///
    /// - Parameter handler: shows the request and returns whether the person
    ///   confirmed. It may run for as long as the person takes.
    public init(_ handler: @escaping @Sendable (ConfirmationRequest) async -> Bool) {
        self.handler = handler
    }

    /// Asks for a decision.
    ///
    /// - Parameter request: what the HUD shows.
    /// - Returns: whether the call may run.
    public func confirm(_ request: ConfirmationRequest) async -> Bool {
        await handler(request)
    }

    /// A gate that refuses everything.
    ///
    /// This is what a headless process, a test, and the app before it has
    /// installed its HUD use. It is the safe default: a missing HUD must not
    /// become an automatic yes.
    public static let denyAll = ConfirmationGate { _ in false }

    /// A gate that approves everything. Only a test uses this.
    public static let allowAll = ConfirmationGate { _ in true }
}
