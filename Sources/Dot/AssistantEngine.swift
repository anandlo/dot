import AppKit
import DotCore
import Foundation

/// What a turn is asked of, and how far it may go.
///
/// The coordinator reads the configuration live rather than holding a copy: the
/// person can change the service, the voice or the delivery while Dot runs, and
/// the next question must use what they chose.
struct AssistantRuntimeSettings: Sendable, Equatable {
    /// The assistant's block of the configuration file.
    var configuration: AssistantConfiguration
    /// Whether a finished answer may be pasted at the cursor.
    var autoPaste: Bool
    /// Dot's own bundle identifier, so a paste is never aimed at Dot.
    var ownBundleIdentifier: String

    /// Creates a runtime snapshot.
    init(
        configuration: AssistantConfiguration = .default,
        autoPaste: Bool = true,
        ownBundleIdentifier: String = ""
    ) {
        self.configuration = configuration
        self.autoPaste = autoPaste
        self.ownBundleIdentifier = ownBundleIdentifier
    }
}

/// Builds the engine one turn runs on.
///
/// It is a protocol so a test can answer every question about the network
/// without one, and so the count of components a turn has created is a number a
/// test can read. The provider and the toolbox are built here together because
/// they are two halves of the same decision: which service, and which apps.
protocol ChatProviderFactory: Sendable {
    /// Whether a chat service has a key, answered without decrypting it.
    func hasKey(for providerID: String) -> Bool

    /// Builds the provider a turn streams from.
    func makeProvider(_ settings: AssistantSettings) async throws -> any ChatProvider

    /// Builds the tools a turn may use, with the names the card shows for them.
    func makeTools(_ configuration: AssistantConfiguration, gate: ConfirmationGate) async -> AssistantTools
}

/// A toolbox and the display names of the connectors behind its tools.
///
/// The session reports a tool name (`reminders_create`); the card says "Using
/// Reminders". The mapping belongs to whoever built the toolbox, because the
/// names live on the connectors and nowhere else.
struct AssistantTools: Sendable {
    /// The tools themselves.
    var toolbox: any AssistantToolbox
    /// The display names of the connectors that own the tools, keyed by tool.
    var connectorNames: [String: String]

    /// A toolbox with nothing in it, for a turn that may not act.
    static let none = AssistantTools(toolbox: NoTools(), connectorNames: [:])

    /// The name the card shows for a tool.
    ///
    /// - Parameter tool: the tool's name, as the model called it.
    /// - Returns: the connector's display name, or the namespace of the tool
    ///   with its first letter raised when the connector is unknown.
    func connectorName(for tool: String) -> String {
        if let name = connectorNames[tool] { return name }
        guard let namespace = tool.split(separator: "_").first, !namespace.isEmpty else { return tool }
        return namespace.prefix(1).uppercased() + namespace.dropFirst()
    }
}

/// A toolbox that offers nothing.
///
/// Used when the person turned actions off: no schema is sent, so the model
/// cannot propose one, and a call that arrives anyway is refused.
struct NoTools: AssistantToolbox {
    func specs() async -> [ChatToolSpec] { [] }

    func invoke(_ call: ToolCall) async -> ToolResult {
        .failure(call.id, "Actions are turned off.")
    }
}

/// Speaks an answer while it is still arriving.
@MainActor
protocol AnswerSpeaker: AnyObject {
    /// Called when the last sentence has been scheduled.
    var onFinish: (() -> Void)? { get set }

    /// Called when a sentence could not be synthesised.
    var onFailure: ((String) -> Void)? { get set }

    /// Starts a turn with the chosen voice.
    ///
    /// - Parameter settings: the voice, model and speed.
    /// - Returns: `false` when the voice cannot be built, in which case the
    ///   answer is not spoken at all.
    func beginSpeaking(_ settings: VoiceSettings) async -> Bool

    /// Adds a piece of the answer.
    func feed(_ delta: String)

    /// Marks the end of the answer.
    func finishSpeaking()

    /// Silences the voice at once, keeping the turn.
    func stopSpeaking()

    /// Releases the audio engine now.
    func tearDownSpeech()
}

/// Reads an answer behind any application, without stealing its focus.
@MainActor
protocol AnswerPaster: AnyObject {
    /// The application in front right now.
    var frontmostApp: FrontmostApp? { get }

    /// Whether Dot may post a synthetic key event.
    var accessibilityGranted: Bool { get }

    /// Puts the text on the clipboard as a concealed item and registers it as a
    /// secret with the logger.
    func copy(_ text: String)

    /// Posts the paste keystroke into the frontmost application.
    @discardableResult
    func paste() -> Bool

    /// Asks the system for the permission a paste needs.
    func requestAccessibility()
}

/// The card, as the coordinator sees it.
///
/// The coordinator never builds a card and never lays one out: it says what is
/// happening and the island draws it. That is what keeps the turn logic free of
/// AppKit and runnable in a test.
@MainActor
protocol AssistantHUD: AnyObject {
    /// A question is on its way to the service.
    func showAssistantThinking(question: String)

    /// The answer is using one of the connected apps.
    func showAssistantTool(connectorName: String)

    /// The answer, in whatever state it is in.
    func showAssistantAnswer(text: String, state: AssistantAnswerState)

    /// A connected app is waiting for a yes or a no.
    func showAssistantConfirm(
        _ request: ConfirmationRequest,
        onAllow: @escaping () -> Void,
        onCancel: @escaping () -> Void
    )

    /// The confirmation is over, whatever the answer was.
    func hideAssistantConfirm()

    /// The turn is over and the card goes away.
    func hideAssistant()

    /// Something went wrong, or something needs saying.
    func showAssistantMessage(_ text: String, symbol: String)
}
