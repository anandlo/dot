import XCTest

@testable import DotCore

/// The assistant's block of the configuration file.
///
/// It is one top level key, and every field inside it decodes tolerantly: a
/// value this build cannot read resets only the field it is in. That rule is
/// what keeps a hand edited file from losing the dictation provider as well.
final class AssistantConfigurationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-assistant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func load(_ json: String) throws -> DotConfig {
        let url = directory.appendingPathComponent("config-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return DotConfig.load(from: url)
    }

    func testTheShippedDefaults() {
        let assistant = DotConfig.default.assistant
        XCTAssertEqual(assistant.chat.providerID, "openai")
        XCTAssertEqual(assistant.model, "gpt-4o-mini", "the catalogue's first suggestion")
        XCTAssertEqual(assistant.voice.providerID, ProviderIdentifier.apple)
        XCTAssertEqual(assistant.voice.speed, 1.0)
        XCTAssertEqual(assistant.connectors, ConnectorSettings.default)
        XCTAssertEqual(assistant.delivery, .paste)
        XCTAssertTrue(assistant.actionsEnabled)
        XCTAssertFalse(assistant.isSetUp, "a fresh install has no assistant service chosen")
        XCTAssertEqual(DotConfig.default.assistantHotkey, Hotkey.defaultAssistant)
    }

    func testAFileWithoutTheBlockKeepsTheDefaults() throws {
        let config = try load(#"{"provider": "deepgram", "autoPaste": false}"#)
        XCTAssertEqual(config.assistant, AssistantConfiguration.default)
        XCTAssertEqual(config.assistantHotkey, Hotkey.defaultAssistant)
        XCTAssertEqual(config.provider, "deepgram")
        XCTAssertFalse(config.autoPaste)
    }

    func testABadDeliveryResetsOnlyThatField() throws {
        let config = try load(#"""
        {
          "provider": "deepgram",
          "assistant": {
            "chat": { "provider": "anthropic", "model": "claude-sonnet-4-20250514", "maxSteps": 4 },
            "voice": { "providerID": "elevenlabs", "voiceID": "rachel", "speed": 1.4 },
            "connectors": { "enabled": ["files", "notes"], "policies": {} },
            "delivery": "shout",
            "actionsEnabled": false
          }
        }
        """#)
        XCTAssertEqual(config.provider, "deepgram", "the dictation provider survived")
        XCTAssertEqual(config.assistant.delivery, .paste, "only the delivery fell back")
        XCTAssertEqual(config.assistant.chat.providerID, "anthropic")
        XCTAssertEqual(config.assistant.chat.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(config.assistant.chat.maxSteps, 4)
        XCTAssertEqual(config.assistant.voice.providerID, "elevenlabs")
        XCTAssertEqual(config.assistant.voice.voiceID, "rachel")
        XCTAssertEqual(config.assistant.voice.speed, 1.4)
        XCTAssertEqual(config.assistant.connectors.enabled, [.files, .notes])
        XCTAssertFalse(config.assistant.actionsEnabled)
    }

    func testTheBlockRoundTrips() throws {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.groq
        config.assistantHotkey = Hotkey(
            keyCode: 15,
            modifiers: HotkeyModifiers.mask(.control, .option),
            label: Hotkey.makeLabel(keyCode: 15, modifiers: HotkeyModifiers.mask(.control, .option))
        )
        config.assistant = AssistantConfiguration(
            chat: AssistantSettings(
                providerID: "groq",
                model: "llama-3.3-70b-versatile",
                temperature: 0.4,
                maxSteps: 3,
                apiStyle: .openAICompatible
            ),
            voice: VoiceSettings(providerID: "elevenlabs", voiceID: "rachel", speed: 1.25),
            connectors: ConnectorSettings(enabled: [.files, .calendar], policies: ["calendar_create": .ask]),
            delivery: .pasteAndSpeak,
            actionsEnabled: false
        )

        let data = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(DotConfig.self, from: data)
        XCTAssertEqual(restored, config)
        XCTAssertEqual(restored.assistantHotkey.label, Hotkey.makeLabel(
            keyCode: 15,
            modifiers: HotkeyModifiers.mask(.control, .option)
        ))
    }

    func testTheDeliveryIsWrittenAsItsOwnName() throws {
        var config = DotConfig.default
        config.assistant.delivery = .pasteAndSpeak
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        let assistant = try XCTUnwrap(payload?["assistant"] as? [String: Any])
        XCTAssertEqual(assistant["delivery"] as? String, "paste-and-speak")
        XCTAssertEqual(assistant["actionsEnabled"] as? Bool, true)
        XCTAssertNil(assistant["apiKey"])
    }

    func testTheAssistantIsNeverStoredUnderProviders() throws {
        var config = DotConfig.default
        config.assistant.chat.model = "gpt-4o"
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        XCTAssertNotNil(payload?["assistant"], "the block is a top level key")
        let providers = try XCTUnwrap(payload?["providers"] as? [String: Any])
        XCTAssertNil(providers["assistant"])
    }

    func testAVoiceBlockWithNoProviderKeepsItsSpeedAndTakesTheMacVoice() throws {
        let config = try load(#"{"assistant": {"voice": {"speed": 1.75}}}"#)
        XCTAssertEqual(config.assistant.voice.providerID, ProviderIdentifier.apple)
        XCTAssertEqual(config.assistant.voice.speed, 1.75)
    }

    func testAnUnreadableHotkeyKeepsTheDefaultOne() throws {
        let config = try load(#"{"assistantHotkey": {"keyCode": "a"}}"#)
        XCTAssertEqual(config.assistantHotkey, Hotkey.defaultAssistant)
    }
}
