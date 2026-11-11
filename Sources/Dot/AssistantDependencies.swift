import DotCore
import Foundation

/// The live engine the assistant runs on.
///
/// It is the one place that turns the person's settings into a request: which
/// catalogue row, which key, which apps. The coordinator above it knows only the
/// protocols, so a test drives a turn without a Keychain item or a socket.
struct AssistantCatalogueFactory: ChatProviderFactory {
    /// The session cache every key read goes through.
    let credentials: CredentialCache
    /// Where tool calls are recorded.
    let log: ToolCallLog

    /// Whether a chat service has a key, answered from the Keychain item's
    /// attributes and never from its data.
    func hasKey(for providerID: String) -> Bool {
        AssistantCredentials.hasKey(for: providerID)
    }

    func makeProvider(_ settings: AssistantSettings) async throws -> any ChatProvider {
        let row = AssistantProviderCatalogue.row(for: settings.providerID)
        // A service on this Mac has no key to read, and reading one would ask
        // the person for a Keychain item they never made.
        let key = row.requiresKey
            ? await AssistantCredentials.resolvedKey(for: settings.providerID, cache: credentials)
            : nil
        return try AssistantProviderCatalogue.makeProvider(settings: settings, apiKey: key)
    }

    func makeTools(_ configuration: AssistantConfiguration, gate: ConfirmationGate) async -> AssistantTools {
        let registry = ConnectorCatalog.registry(
            settings: configuration.connectors,
            gate: gate,
            log: log
        )
        let summaries = await registry.summaries()
        var names: [String: String] = [:]
        for summary in summaries {
            for tool in summary.tools {
                names[tool.name] = summary.displayName
            }
        }
        return AssistantTools(toolbox: registry, connectorNames: names)
    }
}

/// The voice, as the coordinator sees it.
///
/// The player is built by the factory closure rather than at launch, because a
/// person who never asks the assistant never needs an audio engine.
@MainActor
final class SpeechAnswerSpeaker: AnswerSpeaker {
    private let player = SpeechPlayer()
    private let credentials: CredentialCache

    /// Called when the last sentence has been scheduled.
    var onFinish: (() -> Void)? {
        didSet { player.onFinish = onFinish }
    }

    /// Called when a sentence could not be synthesised.
    var onFailure: ((String) -> Void)? {
        didSet { player.onFailure = { [weak self] error in self?.onFailure?(error.localizedDescription) } }
    }

    init(credentials: CredentialCache) {
        self.credentials = credentials
    }

    func beginSpeaking(_ settings: VoiceSettings) async -> Bool {
        guard let provider = await VoiceProviderFactory.make(
            providerID: settings.providerID,
            credentials: credentials
        ) else { return false }
        player.begin(provider: provider, settings: settings)
        return true
    }

    func feed(_ delta: String) {
        player.feed(delta)
    }

    func finishSpeaking() {
        player.finishText()
    }

    func stopSpeaking() {
        player.stop()
    }

    func tearDownSpeech() {
        player.teardown()
    }

    /// Whether audio is still being synthesised or played.
    var isSpeaking: Bool { player.isSpeaking }
}

/// The clipboard and the frontmost application, as the coordinator sees them.
///
/// The answer is put on the clipboard the way a transcript is: marked with the
/// private types a clipboard manager honours, so an answer cannot become a
/// permanent entry in somebody's clipboard history.
@MainActor
final class PasteAnswerPaster: AnswerPaster {
    var frontmostApp: FrontmostApp? { Paste.frontmostApp }

    var accessibilityGranted: Bool { Paste.accessibilityGranted }

    func copy(_ text: String) {
        Paste.copy(text)
    }

    @discardableResult
    func paste() -> Bool {
        Paste.pasteCommand()
    }

    func requestAccessibility() {
        Paste.requestAccessibility()
    }
}

/// Whether the tool log may write the argument values of a call.
///
/// The setting lives on the main actor with the rest of the configuration, and
/// the log asks for it from whatever thread a tool finished on. The answer is
/// mirrored here so the log reads a value instead of reaching across actors.
final class LogArgumentsFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    /// Whether a record may carry the values a tool was called with.
    var isOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Records the current setting.
    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
