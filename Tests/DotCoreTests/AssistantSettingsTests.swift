import XCTest

@testable import DotCore

/// The assistant's record in the configuration file.
///
/// A hand-edited file is the case these tests exist for: one unknown enum, or
/// one field of the wrong type, must not reset the model, the address or the
/// step cap the person chose.
final class AssistantSettingsTests: XCTestCase {
    func testDefaults() {
        let settings = AssistantSettings.default
        XCTAssertEqual(settings.providerID, "openai")
        XCTAssertEqual(settings.model, "")
        XCTAssertNil(settings.baseURL)
        XCTAssertNil(settings.temperature)
        XCTAssertEqual(settings.maxSteps, 6)
        XCTAssertNil(settings.apiStyle)
    }

    func testOneBadEnumDoesNotResetTheRestOfTheRecord() throws {
        let json = """
        {"provider":"anthropic","model":"claude-test","maxSteps":4,
         "temperature":0.3,"apiStyle":"gemini-space"}
        """
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.providerID, "anthropic")
        XCTAssertEqual(settings.model, "claude-test")
        XCTAssertEqual(settings.maxSteps, 4)
        XCTAssertEqual(settings.temperature, 0.3)
        XCTAssertNil(settings.apiStyle, "an unknown shape falls back to the catalogue row")
    }

    func testAFieldOfTheWrongTypeDoesNotResetTheRestOfTheRecord() throws {
        let json = #"{"provider":7,"model":"kept","maxSteps":"many","temperature":"warm"}"#
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.providerID, "openai")
        XCTAssertEqual(settings.model, "kept")
        XCTAssertEqual(settings.maxSteps, 6)
        XCTAssertNil(settings.temperature)
    }

    func testAMissingRecordIsTheDefault() throws {
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, .default)
    }

    func testSanitizedClampsValues() {
        var settings = AssistantSettings.default
        settings.maxSteps = 99
        settings.temperature = 5
        settings.providerID = "  anthropic "
        settings.baseURL = "   "
        let clean = settings.sanitized()
        XCTAssertEqual(clean.maxSteps, AssistantSettings.maximumSteps)
        XCTAssertEqual(clean.temperature, 2)
        XCTAssertEqual(clean.providerID, "anthropic")
        XCTAssertNil(clean.baseURL)
    }

    func testSanitizedRaisesAStepCapOfZero() {
        var settings = AssistantSettings.default
        settings.maxSteps = 0
        XCTAssertEqual(settings.sanitized().maxSteps, AssistantSettings.minimumSteps)
    }

    func testRoundTrip() throws {
        var settings = AssistantSettings.default
        settings.providerID = "anthropic"
        settings.model = "claude-test"
        settings.baseURL = "https://proxy.example.com/v1"
        settings.temperature = 0.2
        settings.maxSteps = 4
        settings.apiStyle = .anthropic

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testResolvedModelFallsBackToTheFirstSuggestion() {
        var settings = AssistantSettings.default
        settings.model = "   "
        XCTAssertEqual(settings.resolvedModel(using: ["first", "second"]), "first")
        XCTAssertEqual(settings.resolvedModel(using: []), "")

        settings.model = " second "
        XCTAssertEqual(settings.resolvedModel(using: ["first"]), "second")
    }
}
