import Foundation

/// How an answer reaches the person once it has arrived.
///
/// The assistant extends dictation rather than replacing it: the answer is
/// either typed where the person was already writing, or read out loud, or
/// both. Nothing here opens a window.
public enum AnswerDelivery: String, Codable, Sendable, CaseIterable {
    /// Put the answer on the clipboard and paste it at the cursor.
    case paste
    /// Read the answer out loud as it arrives.
    case speak
    /// Paste it and read it out.
    case pasteAndSpeak = "paste-and-speak"

    /// The name Settings shows for the choice.
    public var title: String {
        switch self {
        case .paste: "Paste at the cursor"
        case .speak: "Speak"
        case .pasteAndSpeak: "Paste and speak"
        }
    }

    /// Whether the answer is pasted into the app the person was in.
    public var pastes: Bool {
        switch self {
        case .paste, .pasteAndSpeak: true
        case .speak: false
        }
    }

    /// Whether the answer is read out loud.
    public var speaks: Bool {
        switch self {
        case .speak, .pasteAndSpeak: true
        case .paste: false
        }
    }
}

/// Everything the voice assistant reads.
///
/// It is one top-level block of the configuration file, not a field of any
/// provider: ``ProviderMigration`` deletes keys it does not know from the
/// `providers` table, and an assistant setting living there would be erased on
/// the next launch.
///
/// Decoding is tolerant field by field, the rule invariant 9 states: a bad
/// value resets only the field it is in, so a hand-edited file that misspells
/// the delivery mode keeps the model, the voice and the connectors.
public struct AssistantConfiguration: Codable, Sendable, Equatable {
    /// The service, model and sampling the answers are asked of.
    public var chat: AssistantSettings
    /// The voice the answers are read with.
    public var voice: VoiceSettings
    /// Which connected apps the assistant may use, and when it must ask.
    public var connectors: ConnectorSettings
    /// Where a finished answer goes.
    public var delivery: AnswerDelivery
    /// Whether the connected apps are offered to the model at all.
    ///
    /// Off means every turn is a plain question: no tool schemas are sent, so
    /// an action cannot be proposed, let alone run.
    public var actionsEnabled: Bool

    /// The voice a fresh configuration speaks with: the one on this Mac.
    public static let defaultVoice = VoiceSettings(providerID: VoiceProviderID.apple)

    /// The configuration a fresh install starts with.
    ///
    /// The chat model is left empty on purpose: the catalogue row's first
    /// suggestion is resolved at ask time, so a fresh install sends a model
    /// that exists today and a new build can suggest another without rewriting
    /// the person's file.
    public static let `default` = AssistantConfiguration()

    /// Creates an assistant configuration.
    public init(
        chat: AssistantSettings = .default,
        voice: VoiceSettings = AssistantConfiguration.defaultVoice,
        connectors: ConnectorSettings = .default,
        delivery: AnswerDelivery = .paste,
        actionsEnabled: Bool = true
    ) {
        self.chat = chat
        self.voice = voice
        self.connectors = connectors
        self.delivery = delivery
        self.actionsEnabled = actionsEnabled
    }

    /// The model id a turn is asked for, resolved from the catalogue.
    public var model: String {
        AssistantProviderCatalogue.model(for: chat)
    }

    private enum CodingKeys: String, CodingKey {
        case chat
        case voice
        case connectors
        case delivery
        case actionsEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AssistantConfiguration.default
        chat = ((try? container.decodeIfPresent(AssistantSettings.self, forKey: .chat)) ?? nil) ?? fallback.chat
        connectors = ((try? container.decodeIfPresent(ConnectorSettings.self, forKey: .connectors)) ?? nil)
            ?? fallback.connectors
        // The delivery is the block's only enum valued key. A spelling this
        // build does not know loads as the default for that one field.
        delivery = ((try? container.decodeIfPresent(AnswerDelivery.self, forKey: .delivery)) ?? nil)
            ?? fallback.delivery
        actionsEnabled = ((try? container.decodeIfPresent(Bool.self, forKey: .actionsEnabled)) ?? nil)
            ?? fallback.actionsEnabled
        // A voice block with no provider is not a choice of silence: the voice
        // on this Mac fills in, and the speed the person set is kept.
        var storedVoice = ((try? container.decodeIfPresent(VoiceSettings.self, forKey: .voice)) ?? nil)
            ?? fallback.voice
        if !storedVoice.isConfigured {
            storedVoice.providerID = fallback.voice.providerID
        }
        voice = storedVoice
    }
}
