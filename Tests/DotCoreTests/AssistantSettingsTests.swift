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

    /// One id for the catalogue row and the Keychain item.
    ///
    /// A hand-edited file with a space around its id must be read the same way
    /// by the request builder, the menu, the rewrite offer and the page: a
    /// trimmed id in one place and an untrimmed one in another is a key item
    /// the service was never told about.
    func testTheResolvedProviderIDIsTrimmedOnceAndFallsBackToTheDefault() {
        var settings = AssistantSettings.default
        settings.providerID = "  anthropic  "
        XCTAssertEqual(settings.resolvedProviderID, "anthropic")
        XCTAssertEqual(settings.sanitized().providerID, settings.resolvedProviderID)

        settings.providerID = "\n\t"
        XCTAssertEqual(settings.resolvedProviderID, AssistantSettings.defaultProviderID)
        XCTAssertEqual(settings.sanitized().providerID, AssistantSettings.defaultProviderID)

        settings.providerID = "lmstudio"
        XCTAssertEqual(settings.resolvedProviderID, "lmstudio")
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
        XCTAssertEqual(
            settings.resolvedModel(using: []),
            "",
            "no row suggests a model, so an empty record names none"
        )

        settings.model = " second "
        XCTAssertEqual(settings.resolvedModel(using: ["first"]), "second")
    }

    // MARK: - The model's reasoning and route

    private func discovery() -> DiscoveredModel {
        DiscoveredModel(
            id: "gpt-6-luna",
            name: "GPT-6 Luna",
            reasoning: ModelReasoningSupport(efforts: ["low", "high"], toggle: true, defaultEffort: "low"),
            route: ModelAPIRoute(
                style: .openAICompatible,
                baseURL: URL(string: "https://opencode.ai/inference/go/openai/v1")!
            ),
            supportsTemperature: false
        )
    }

    func testTheReasoningChoiceAndTheDiscoveryRoundTrip() throws {
        var settings = AssistantSettings.default
        settings.model = "gpt-6-luna"
        settings.reasoningVariant = "high"
        settings.discoveredModel = discovery()

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.reasoningVariant, "high")
        XCTAssertEqual(decoded.discoveredModel?.supportsTemperature, false)
        XCTAssertEqual(decoded.discoveredModel?.reasoning?.defaultEffort, "low")
        XCTAssertEqual(
            decoded.discoveredModel?.route?.style,
            .openAICompatible,
            "the shape a model is served as survives the file"
        )
    }

    func testNothingAboutADiscoveryIsWrittenWhenNoneExists() throws {
        var settings = AssistantSettings.default
        settings.model = "gpt-4o"
        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["reasoningVariant"])
        XCTAssertNil(object["discoveredModel"], "a fresh record writes no discovery")
    }

    func testAnUnreadableDiscoveryResetsOnlyItself() throws {
        let json = """
        {"provider":"anthropic","model":"claude-test",
         "reasoningVariant":7,"discoveredModel":"not-a-model"}
        """
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.model, "claude-test", "the rest of the record survived")
        XCTAssertEqual(settings.providerID, "anthropic")
        XCTAssertNil(settings.reasoningVariant, "a value of the wrong type says nothing")
        XCTAssertNil(settings.discoveredModel)
    }

    func testSanitizedTrimsTheChoiceAndDropsADiscoveryForAnotherModel() {
        var settings = AssistantSettings.default
        settings.model = "gpt-4o"
        settings.reasoningVariant = "  "
        settings.discoveredModel = discovery()
        let clean = settings.sanitized()
        XCTAssertNil(clean.reasoningVariant)
        XCTAssertNil(
            clean.discoveredModel,
            "a discovery describes the model it was read for, not another one"
        )
    }

    func testChoosingAServiceClearsWhatTheServicePublished() {
        var settings = AssistantSettings.default
        settings.providerID = "openai"
        settings.model = "gpt-6-luna"
        settings.reasoningVariant = "high"
        settings.discoveredModel = discovery()

        settings.selectProvider("anthropic")
        XCTAssertEqual(settings.providerID, "anthropic")
        XCTAssertNil(settings.reasoningVariant, "a level one vendor documents means nothing to another")
        XCTAssertNil(settings.discoveredModel, "a route names an address the new service does not serve")
        XCTAssertEqual(settings.model, "gpt-6-luna", "the model id is the page's to clear")
    }

    func testChoosingTheSameServiceChangesNothing() {
        var settings = AssistantSettings.default
        settings.providerID = "openai"
        settings.reasoningVariant = "high"
        settings.discoveredModel = discovery()
        settings.selectProvider("  openai  ")
        XCTAssertEqual(settings.reasoningVariant, "high")
        XCTAssertNotNil(settings.discoveredModel)
    }
}
