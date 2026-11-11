import XCTest

@testable import DotCore

/// A voice setting is a person's choice, and a configuration file can be edited,
/// roll back to an older build or hold a value this build has never heard of.
/// None of those may reset the choice, which is the rule the rest of Dot's
/// configuration already follows.
final class VoiceSettingsTests: XCTestCase {
    func testDecodesEveryField() throws {
        let json = """
        {"providerID":"elevenlabs","voiceID":"abc","speed":1.25,"model":"eleven_flash_v2_5",
         "qualityFloor":"premium","instructions":"warm"}
        """
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.providerID, "elevenlabs")
        XCTAssertEqual(settings.voiceID, "abc")
        XCTAssertEqual(settings.speed, 1.25)
        XCTAssertEqual(settings.model, "eleven_flash_v2_5")
        XCTAssertEqual(settings.qualityFloor, .premium)
        XCTAssertEqual(settings.instructions, "warm")
    }

    func testAnUnknownQualityFloorKeepsTheRestOfTheSetting() throws {
        let json = #"{"providerID":"azure","qualityFloor":"ultra","voiceID":"en-US-JennyNeural"}"#
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: Data(json.utf8))
        XCTAssertNil(settings.qualityFloor)
        XCTAssertEqual(settings.providerID, "azure")
        XCTAssertEqual(settings.voiceID, "en-US-JennyNeural")
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.providerID, "")
        XCTAssertNil(settings.voiceID)
        XCTAssertEqual(settings.speed, VoiceSettings.defaultSpeed)
        XCTAssertNil(settings.model)
        XCTAssertNil(settings.qualityFloor)
        XCTAssertFalse(settings.isConfigured)
    }

    func testSpeedsThatAreNotRatesBecomeTheDefault() {
        var settings = VoiceSettings(providerID: "openai", speed: 0)
        XCTAssertEqual(settings.effectiveSpeed, 1)
        settings.speed = -2
        XCTAssertEqual(settings.effectiveSpeed, 1)
        settings.speed = .nan
        XCTAssertEqual(settings.effectiveSpeed, 1)
        settings.speed = 9
        XCTAssertEqual(settings.effectiveSpeed, VoiceSettings.speedRange.upperBound)
    }

    func testProviderRangeNarrowsTheSpeed() {
        let settings = VoiceSettings(providerID: "elevenlabs", speed: 1.8)
        XCTAssertEqual(settings.speed(within: 0.7...1.2), 1.2)
        XCTAssertEqual(settings.speed(within: 0.5...2.0), 1.8)
    }

    func testVoiceAndModelFallBackWhenBlank() {
        let settings = VoiceSettings(providerID: "cartesia", voiceID: "  ", model: " ")
        XCTAssertNil(settings.resolvedVoiceID(fallback: nil))
        XCTAssertEqual(settings.resolvedVoiceID(fallback: "default"), "default")
        XCTAssertEqual(settings.resolvedModel(fallback: "sonic-3.6"), "sonic-3.6")
    }

    func testRoundTripsThroughJSON() throws {
        let settings = VoiceSettings(
            providerID: "deepgram",
            voiceID: "aura-2-thalia-en",
            speed: 1.1,
            model: "aura-2-thalia-en",
            qualityFloor: .enhanced,
            instructions: "calm"
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testEncodedSettingCarriesNoSecretShapedKey() throws {
        let data = try JSONEncoder().encode(VoiceSettings(providerID: "openai"))
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["apikey", "api_key", "secret", "token", "password", "credential"] {
            XCTAssertFalse(text.contains(forbidden), "the encoded setting contains \(forbidden)")
        }
    }
}
