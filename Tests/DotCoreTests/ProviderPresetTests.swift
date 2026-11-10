import XCTest

@testable import DotCore

final class ProviderPresetTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-preset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The rows

    func testTheRowsCarryTheirOwnNameEndpointAndModel() {
        XCTAssertEqual(ProviderPreset.openAI.name, "OpenAI")
        XCTAssertEqual(ProviderPreset.openAI.providerID, ProviderIdentifier.openAI)
        XCTAssertEqual(ProviderPreset.openAI.baseURL, "https://api.openai.com/v1")
        XCTAssertNil(ProviderPreset.openAI.model)
        XCTAssertEqual(ProviderPreset.openAI.key, .required)

        XCTAssertEqual(ProviderPreset.groq.name, "Groq")
        XCTAssertEqual(ProviderPreset.groq.providerID, ProviderIdentifier.groq)
        XCTAssertEqual(ProviderPreset.groq.baseURL, "https://api.groq.com/openai/v1")
        XCTAssertNil(ProviderPreset.groq.model)
        XCTAssertEqual(ProviderPreset.groq.key, .required)

        XCTAssertEqual(ProviderPreset.custom.providerID, ProviderIdentifier.openAI)
        XCTAssertNil(ProviderPreset.custom.baseURL)
        XCTAssertNil(ProviderPreset.custom.model)
        XCTAssertEqual(ProviderPreset.custom.key, .optional)
        XCTAssertTrue(ProviderPreset.custom.hasEndpoint)

        XCTAssertEqual(ProviderPreset.deepgram.name, "Deepgram")
        XCTAssertEqual(ProviderPreset.deepgram.providerID, ProviderIdentifier.deepgram)
        XCTAssertEqual(ProviderPreset.deepgram.baseURL, "https://api.deepgram.com/v1")
        XCTAssertNil(ProviderPreset.deepgram.model)
        XCTAssertEqual(ProviderPreset.deepgram.key, .required)
        XCTAssertTrue(ProviderPreset.deepgram.isOffered, "the picker offers Deepgram")

        XCTAssertEqual(ProviderPreset.elevenLabs.name, "ElevenLabs")
        XCTAssertEqual(ProviderPreset.elevenLabs.providerID, ProviderIdentifier.elevenLabs)
        XCTAssertEqual(ProviderPreset.elevenLabs.baseURL, "https://api.elevenlabs.io/v1")
        XCTAssertNil(ProviderPreset.elevenLabs.model)
        XCTAssertEqual(ProviderPreset.elevenLabs.key, .required)
        XCTAssertTrue(ProviderPreset.elevenLabs.isOffered, "the picker offers ElevenLabs")

        XCTAssertEqual(ProviderPreset.xiaomi.name, "Xiaomi ASR")
        XCTAssertEqual(ProviderPreset.xiaomi.providerID, ProviderIdentifier.xiaomi)
        XCTAssertEqual(ProviderPreset.xiaomi.baseURL, "https://api.xiaomimimo.com/v1")
        XCTAssertNil(ProviderPreset.xiaomi.model)
        XCTAssertEqual(ProviderPreset.xiaomi.key, .required)
        XCTAssertFalse(ProviderPreset.xiaomi.isOffered)
        XCTAssertEqual(ProviderPreset.xiaomi.symbol, "waveform.badge.mic")

        XCTAssertEqual(ProviderPreset.apple.providerID, ProviderIdentifier.apple)
        XCTAssertNil(ProviderPreset.apple.baseURL)
        XCTAssertNil(ProviderPreset.apple.model)
        XCTAssertEqual(ProviderPreset.apple.key, .none)
        XCTAssertFalse(ProviderPreset.apple.hasEndpoint)
        XCTAssertFalse(ProviderPreset.apple.needsKey)

        XCTAssertEqual(ProviderPreset.azure.name, "Azure Speech")
        XCTAssertEqual(ProviderPreset.azure.providerID, ProviderIdentifier.azure)
        XCTAssertEqual(ProviderPreset.azure.baseURL, "https://eastus.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1")
        XCTAssertNil(ProviderPreset.azure.model)
        XCTAssertEqual(ProviderPreset.azure.key, .required)
        XCTAssertTrue(ProviderPreset.azure.hasEndpoint)
        XCTAssertTrue(ProviderPreset.azure.isOffered)
    }

    func testTheRowsAreAlphabeticalSoNoServiceIsRecommended() {
        // The first row of a list reads as the recommendation. There is none:
        // the list is ordered by name, and every row is a normal row.
        XCTAssertEqual(
            ProviderPreset.all.map(\.id),
            ["on-device", "azure", "custom", "deepgram", "elevenlabs", "groq", "openai"]
        )
        XCTAssertEqual(
            ProviderPreset.all.map(\.name),
            ProviderPreset.all.map(\.name).sorted()
        )
    }

    func testEveryRowSelectsAProviderDotShips() {
        for preset in ProviderPreset.all {
            XCTAssertTrue(
                ProviderRegistry.knows(preset.providerID),
                "the row \(preset.id) names a provider nothing can build"
            )
            XCTAssertFalse(preset.name.isEmpty, preset.id)
            XCTAssertFalse(preset.symbol.isEmpty, preset.id)
        }
    }

    func testEveryProviderDotShipsIsDescribedByARow() {
        // Every provider Dot can build is described by a row, and every row the
        // picker draws names a provider Dot builds.
        for id in ProviderRegistry.builtInIDs {
            XCTAssertTrue(
                ProviderPreset.declared.contains { $0.providerID == id },
                "no row describes \(id)"
            )
        }
        for preset in ProviderPreset.all {
            XCTAssertTrue(ProviderRegistry.knows(preset.providerID), preset.id)
        }
        XCTAssertFalse(
            ProviderPreset.all.contains { $0.providerID == ProviderIdentifier.xiaomi }
        )
        XCTAssertTrue(
            ProviderPreset.declared.contains { $0.providerID == ProviderIdentifier.xiaomi },
            "the stored configuration still needs its row"
        )
    }

    func testTheRowsHaveOneIdEach() {
        XCTAssertEqual(Set(ProviderPreset.all.map(\.id)).count, ProviderPreset.all.count)
        for preset in ProviderPreset.all {
            XCTAssertEqual(ProviderPreset.preset(id: preset.id), preset)
        }
        XCTAssertNil(ProviderPreset.preset(id: "does-not-exist"))
    }

    // MARK: - Applying

    func testApplyingANamedRowSetsTheEndpointAndKeepsTheLanguage() {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.xiaomi
        config.providers[ProviderIdentifier.groq] = ProviderConfig(language: "en")

        ProviderPreset.groq.apply(to: &config)

        XCTAssertEqual(config.provider, ProviderIdentifier.groq)
        let settings = config.settings(for: ProviderIdentifier.groq)
        XCTAssertEqual(settings.baseURL, "https://api.groq.com/openai/v1")
        XCTAssertNil(settings.model)
        XCTAssertEqual(settings.language, "en")
    }

    func testApplyingTheOnDeviceRowOnlySelectsIt() {
        var config = DotConfig.default
        let original = config.providers

        ProviderPreset.apple.apply(to: &config)

        XCTAssertEqual(config.provider, ProviderIdentifier.apple)
        XCTAssertEqual(config.providers, original, "an on-device row has nothing to fill in")
    }

    func testTheCustomRowSelectsTheProviderButLeavesTheFieldsAlone() {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.apple
        let original = ProviderConfig(
            model: "my-model",
            baseURL: "https://voice.example.com/v1",
            language: "en",
            authStyle: .apiKey
        )
        config.providers[ProviderIdentifier.openAI] = original

        ProviderPreset.custom.apply(to: &config)

        XCTAssertEqual(config.provider, ProviderIdentifier.openAI)
        XCTAssertEqual(config.settings(for: ProviderIdentifier.openAI), original)
    }

    func testThePresentedRowFollowsTheProviderAndTheBaseURL() {
        var config = DotConfig.default
        XCTAssertEqual(ProviderPreset.presenting(config), .openAI)

        // Xiaomi with its default endpoint presents as the Xiaomi row.
        config.provider = ProviderIdentifier.xiaomi
        XCTAssertEqual(ProviderPreset.presenting(config), .xiaomi)

        // A stored custom endpoint presents as a custom endpoint.
        config.providers[ProviderIdentifier.xiaomi] = ProviderConfig(
            model: "stored-model",
            baseURL: "https://voice.example.com/v1"
        )
        let stored = ProviderPreset.presenting(config)
        XCTAssertEqual(stored.id, ProviderPreset.custom.id)
        XCTAssertEqual(stored.providerID, ProviderIdentifier.xiaomi)

        config.provider = ProviderIdentifier.apple
        XCTAssertEqual(ProviderPreset.presenting(config), .apple)

        config.provider = ProviderIdentifier.openAI
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            model: "whisper-large-v3",
            baseURL: "https://api.groq.com/openai/v1/"
        )
        XCTAssertEqual(ProviderPreset.presenting(config), .groq)

        config.providers[ProviderIdentifier.openAI] = ProviderConfig()
        XCTAssertEqual(ProviderPreset.presenting(config), .custom)

        // A selection waiting for the launch correction is presented as the
        // custom endpoint too: the card never draws an empty selection.
        config.provider = ProviderIdentifier.bridge
        let unknown = ProviderPreset.presenting(config)
        XCTAssertEqual(unknown.id, ProviderPreset.custom.id)
        XCTAssertEqual(unknown.providerID, ProviderIdentifier.bridge)
    }

    // MARK: - The custom row

    func testACustomEndpointRoundTripsThroughTheConfigurationUntouched() throws {
        var config = DotConfig.default
        ProviderPreset.custom.apply(to: &config)
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            model: "house-model",
            baseURL: "http://127.0.0.1:8765/v1",
            language: "zh",
            authStyle: .apiKey
        )

        let url = directory.appendingPathComponent("config.json")
        try config.save(to: url)
        let loaded = DotConfig.load(from: url)

        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.provider, ProviderIdentifier.openAI)
        // The row is the custom one, carrying the stored values, and it is named
        // after the endpoint's host: "Custom endpoint" would say what shape the
        // service is and nothing about which one is running.
        let presented = ProviderPreset.presenting(loaded)
        XCTAssertEqual(presented.id, ProviderPreset.custom.id)
        XCTAssertEqual(presented.providerID, ProviderIdentifier.openAI)
        XCTAssertEqual(presented.baseURL, "http://127.0.0.1:8765/v1")
        XCTAssertEqual(presented.model, "house-model")
        XCTAssertEqual(presented.name, "127.0.0.1")
        let settings = loaded.settings(for: ProviderIdentifier.openAI)
        XCTAssertEqual(settings.baseURL, "http://127.0.0.1:8765/v1")
        XCTAssertEqual(settings.model, "house-model")
        XCTAssertEqual(settings.language, "zh")
        XCTAssertEqual(settings.authStyle, .apiKey)
    }

    func testAServerOnThisMacIsAProviderWithNoKey() throws {
        // The custom row is what makes a local model server reachable: the
        // endpoint is the user's, and nothing about the row requires a key.
        var config = DotConfig.default
        ProviderPreset.custom.apply(to: &config)
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            model: "whisper-1",
            baseURL: "http://127.0.0.1:8765/v1"
        )

        XCTAssertEqual(ProviderPreset.custom.key, .optional)
        let provider = try ProviderRegistry.makeProvider(
            id: ProviderIdentifier.openAI,
            config: config,
            credentials: .empty
        )
        XCTAssertEqual(provider.id, ProviderIdentifier.openAI)
        XCTAssertEqual(provider.maxSegmentSeconds, 30)
    }

    // MARK: - A stored provider the picker no longer offers

    func testAStoredProviderWithNoRowIsPresentedAsACustomEndpoint() throws {
        // The state a person who configured an earlier build is in: the file
        // selects a provider id no row offers any more. It has to read as a
        // custom endpoint, with the endpoint, the model and the auth style it
        // already had, and no launch may need to fix it first.
        var config = DotConfig.default
        config.provider = ProviderIdentifier.xiaomi
        config.providers[ProviderIdentifier.xiaomi] = ProviderConfig(
            model: "stored-model",
            baseURL: "https://voice.example.com/v1",
            language: "zh",
            authStyle: .apiKey
        )

        let url = directory.appendingPathComponent("stored.json")
        try config.save(to: url)
        let loaded = DotConfig.load(from: url)

        let presented = ProviderPreset.presenting(loaded)

        XCTAssertEqual(presented.id, ProviderPreset.custom.id)
        XCTAssertEqual(presented.name, "voice.example.com", "the row is named by the endpoint it points at")
        XCTAssertEqual(presented.providerID, ProviderIdentifier.xiaomi, "the row keeps the stored id")
        XCTAssertEqual(presented.baseURL, "https://voice.example.com/v1")
        XCTAssertEqual(presented.model, "stored-model")
        XCTAssertEqual(presented.key, .required)
        XCTAssertTrue(presented.hasEndpoint)
        // Nothing about the stored settings moved.
        XCTAssertEqual(loaded.settings(for: ProviderIdentifier.xiaomi), config.settings(for: ProviderIdentifier.xiaomi))
        XCTAssertEqual(loaded.settings(for: ProviderIdentifier.xiaomi).authStyle, .apiKey)
        XCTAssertEqual(loaded.settings(for: ProviderIdentifier.xiaomi).language, "zh")
    }

    func testTheRowsOfAStoredProviderHoldItsCustomRow() {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.xiaomi
        config.providers[ProviderIdentifier.xiaomi] = ProviderConfig(
            model: "stored-model",
            baseURL: "https://voice.example.com/v1"
        )

        let rows = ProviderPreset.rows(for: config)

        XCTAssertEqual(rows.count, ProviderPreset.all.count, "the picker grows no second row")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "one row per id")
        let custom = rows.filter { $0.id == ProviderPreset.custom.id }
        XCTAssertEqual(custom.count, 1)
        XCTAssertEqual(custom.first?.providerID, ProviderIdentifier.xiaomi)
        XCTAssertEqual(custom.first?.baseURL, "https://voice.example.com/v1")
        XCTAssertEqual(custom.first?.model, "stored-model")
    }

    func testChoosingThePresentedRowKeepsTheStoredProviderAndEndpoint() {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.xiaomi
        let stored = ProviderConfig(
            model: "stored-model",
            baseURL: "https://voice.example.com/v1",
            language: "en",
            authStyle: .apiKey
        )
        config.providers[ProviderIdentifier.xiaomi] = stored

        ProviderPreset.presenting(config).apply(to: &config)

        XCTAssertEqual(config.provider, ProviderIdentifier.xiaomi, "a row may not re-point a stored config")
        XCTAssertEqual(config.settings(for: ProviderIdentifier.xiaomi), stored)
    }

    func testAnEmptyStoredEndpointIsLeftEmptyRatherThanInvented() {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.xiaomi
        config.providers[ProviderIdentifier.xiaomi] = ProviderConfig()

        let presented = ProviderPreset.presenting(config)

        XCTAssertNil(presented.baseURL)
        XCTAssertNil(presented.model)
        presented.apply(to: &config)
        XCTAssertEqual(config.settings(for: ProviderIdentifier.xiaomi), ProviderConfig())
    }

    func testChoosingAnotherRowFromAStoredProviderReturnsThePlainCustomRow() {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.xiaomi

        ProviderPreset.groq.apply(to: &config)
        let rows = ProviderPreset.rows(for: config)

        XCTAssertEqual(config.provider, ProviderIdentifier.groq)
        XCTAssertEqual(
            rows.first { $0.id == ProviderPreset.custom.id }?.providerID,
            ProviderIdentifier.openAI,
            "the custom row means the stored one only while the stored provider is selected"
        )
    }

    func testEveryRowProducesAConfigurationTheNextLaunchCanBuild() throws {
        for preset in ProviderPreset.all {
            var config = DotConfig.default
            preset.apply(to: &config)
            if preset.id == ProviderPreset.custom.id {
                // The one row that carries no endpoint needs one to be usable.
                config.providers[preset.providerID] = ProviderConfig(
                    model: "whisper-1",
                    baseURL: "http://127.0.0.1:8765/v1"
                )
            }
            let url = directory.appendingPathComponent("\(preset.id).json")
            try config.save(to: url)
            let loaded = DotConfig.load(from: url)
            XCTAssertEqual(loaded.provider, preset.providerID, preset.id)
            XCTAssertEqual(
                ProviderPreset.presenting(loaded).id,
                preset.id,
                "the saved row is the row that comes back"
            )
            XCTAssertNoThrow(
                try ProviderRegistry.selectedProvider(config: loaded, credentials: .empty),
                preset.id
            )
        }
    }
}
