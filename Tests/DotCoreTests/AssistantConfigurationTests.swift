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
        XCTAssertEqual(assistant.model, "", "no hardcoded model suggestion")
        XCTAssertFalse(assistant.isSetUp, "a fresh install has no assistant service chosen")
    }

    func testAFileWithoutTheBlockKeepsTheDefaults() throws {
        let config = try load(#"{"provider": "deepgram", "autoPaste": false}"#)
        XCTAssertEqual(config.assistant, AssistantConfiguration.default)
        XCTAssertEqual(config.provider, "deepgram")
        XCTAssertFalse(config.autoPaste)
    }

    func testALegacyConfigWithRetiredFieldsDecodesCleanly() throws {
        let config = try load(#"""
        {
          "provider": "deepgram",
          "assistantHotkey": { "keyCode": 0, "modifiers": 256, "label": "⌘A" },
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
        XCTAssertEqual(config.assistant.chat.providerID, "anthropic")
        XCTAssertEqual(config.assistant.chat.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(config.assistant.chat.maxSteps, 4)
    }

    func testTheBlockRoundTrips() throws {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.groq
        config.assistant = AssistantConfiguration(
            chat: AssistantSettings(
                providerID: "groq",
                model: "llama-3.3-70b-versatile",
                temperature: 0.4,
                maxSteps: 3,
                apiStyle: .openAICompatible
            ),
            rewrite: RewriteConfiguration(enabled: true, styles: [.concise]),
            isSetUp: true,
            serviceChosen: true
        )

        let data = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(DotConfig.self, from: data)
        XCTAssertEqual(restored, config)
    }

    func testTheAssistantIsNeverStoredUnderProviders() throws {
        var config = DotConfig.default
        config.assistant.chat.model = "gpt-4o"
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        XCTAssertNotNil(payload?["assistant"], "the block is a top level key")
        let providers = try XCTUnwrap(payload?["providers"] as? [String: Any])
        XCTAssertNil(providers["assistant"])
    }

    // MARK: - A choice kept while the assistant is off

    func testAFileWithoutTheChoiceFlagSaysNothingAboutIt() throws {
        let config = try load(#"{"assistant": {"chat": {"provider": "custom"}}}"#)
        XCTAssertNil(
            config.assistant.serviceChosen,
            "absent is not false: a file written before the flag keeps its stored service readable"
        )
        XCTAssertFalse(config.assistant.isSetUp)
    }

    func testTheChoiceFlagRoundTripsAndIsWrittenOnlyWhenItExists() throws {
        var config = DotConfig.default
        config.assistant.serviceChosen = false
        let data = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(DotConfig.self, from: data)
        XCTAssertEqual(restored, config)

        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let assistant = try XCTUnwrap(payload?["assistant"] as? [String: Any])
        XCTAssertEqual(assistant["serviceChosen"] as? Bool, false)

        config.assistant.serviceChosen = nil
        let absent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        XCTAssertNil((absent?["assistant"] as? [String: Any])?["serviceChosen"])
    }

    func testABadChoiceFlagIsReadAsAbsentRatherThanFalse() throws {
        let config = try load(#"{"assistant": {"serviceChosen": "no"}}"#)
        XCTAssertNil(config.assistant.serviceChosen)
    }

    func testTurningOffKeepsTheServiceModelAndAddress() throws {
        // The page writes false and leaves the rest of the record alone. A
        // file round-tripped after "None" still has everything needed to turn
        // the same endpoint back on.
        var config = DotConfig.default
        config.assistant.chat = AssistantSettings(
            providerID: "custom",
            model: "my-model",
            baseURL: "https://proxy.example.com/v1"
        )
        config.assistant.serviceChosen = false
        config.assistant.isSetUp = false
        let restored = try JSONDecoder().decode(
            DotConfig.self,
            from: JSONEncoder().encode(config)
        )
        XCTAssertEqual(restored.assistant.chat.providerID, "custom")
        XCTAssertEqual(restored.assistant.chat.model, "my-model")
        XCTAssertEqual(restored.assistant.chat.baseURL, "https://proxy.example.com/v1")
        XCTAssertEqual(restored.assistant.serviceChosen, false)
        XCTAssertFalse(restored.assistant.isSetUp)
    }
}
