import XCTest

@testable import DotCore

final class ProviderRegistryTests: XCTestCase {
    func testTheConfigSelectsTheRightProvider() throws {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.openAI
        let provider = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        XCTAssertEqual(provider.id, "openai")
        XCTAssertEqual(provider.displayName, "OpenAI-compatible")

        config.provider = ProviderIdentifier.apple
        let apple = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        XCTAssertEqual(apple.id, "apple")
        XCTAssertEqual(apple.displayName, "Apple Speech")

        config.provider = ProviderIdentifier.xiaomi
        let xiaomi = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        XCTAssertEqual(xiaomi.id, "xiaomi")
        XCTAssertEqual(xiaomi.displayName, "Xiaomi ASR")

        config.provider = ProviderIdentifier.azure
        let azure = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        XCTAssertEqual(azure.id, "azure")
        XCTAssertEqual(azure.displayName, "Azure Speech")

        config.provider = ProviderIdentifier.deepgram
        let deepgram = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        XCTAssertEqual(deepgram.id, "deepgram")
        XCTAssertEqual(deepgram.displayName, "Deepgram")

        config.provider = ProviderIdentifier.elevenLabs
        let elevenLabs = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        XCTAssertEqual(elevenLabs.id, "elevenlabs")
        XCTAssertEqual(elevenLabs.displayName, "ElevenLabs")
    }

    func testAnUnknownProviderFailsCleanly() {
        var config = DotConfig.default
        config.provider = "does-not-exist"
        XCTAssertThrowsError(try ProviderRegistry.selectedProvider(config: config, credentials: .empty)) { error in
            XCTAssertEqual(error as? ProviderRegistryError, .unknownProvider("does-not-exist"))
            XCTAssertEqual(
                (error as? ProviderRegistryError)?.errorDescription,
                "There is no provider called 'does-not-exist'."
            )
        }
    }

    func testTheOpenAIProviderNeedsABaseURL() {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.openAI
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(model: "whisper-1")
        XCTAssertThrowsError(try ProviderRegistry.selectedProvider(config: config, credentials: .empty)) { error in
            XCTAssertEqual(error as? ProviderRegistryError, .missingBaseURL("openai"))
        }
    }

    func testTheBuiltInProvidersAreTheOnesTheMenuOffers() {
        XCTAssertEqual(
            ProviderRegistry.builtInIDs,
            ["openai", "groq", "azure", "deepgram", "elevenlabs", "xiaomi", "apple"]
        )
    }

    func testNoProviderNameMentionsAModelBrand() {
        // A provider's own name never names a model. It is built from an empty
        // credential cache on purpose: this test used to take the app's live
        // cache, so it decrypted the user's keys and waited on the Keychain's
        // authorization for minutes. A unit test never reads a keychain.
        var config = DotConfig.default
        for id in ProviderRegistry.builtInIDs {
            config.provider = id
            let provider = try? ProviderRegistry.selectedProvider(config: config, credentials: .empty)
            XCTAssertNotNil(provider)
            let name = provider?.displayName ?? ""
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(name.lowercased().contains("mi" + "mo"))
        }
    }

    func testTheXiaomiProviderNeedsAKey() async {
        let provider: any Provider = XiaomiASRProvider()
        XCTAssertTrue(provider.requiresCredential)
        // Sixty seconds, the length the MiMo model handles in one clip.
        XCTAssertEqual(provider.maxSegmentSeconds, 60)
    }

    func testTheDeepgramProviderNeedsAKeyAndBuildsRequests() throws {
        let provider = DeepgramProvider(
            apiKey: "dg-secret-key",
            smartFormat: true,
            punctuate: true,
            paragraphs: true,
            fillerWords: true,
            profanityFilter: true,
            numerals: true,
            diarize: true,
            keyterms: "Dot, Deepgram"
        )
        XCTAssertTrue(provider.requiresCredential)
        let url = provider.listenURL(model: "nova-3", language: "en_US")
        let urlString = url.absoluteString
        XCTAssertTrue(urlString.contains("/v1/listen?"))
        XCTAssertTrue(urlString.contains("model=nova-3"))
        XCTAssertTrue(urlString.contains("smart_format=true"))
        XCTAssertTrue(urlString.contains("punctuate=true"))
        XCTAssertTrue(urlString.contains("paragraphs=true"))
        XCTAssertTrue(urlString.contains("filler_words=true"))
        XCTAssertTrue(urlString.contains("profanity_filter=true"))
        XCTAssertTrue(urlString.contains("numerals=true"))
        XCTAssertTrue(urlString.contains("diarize=true"))
        XCTAssertTrue(urlString.contains("language=en"))
        XCTAssertTrue(urlString.contains("keyterm=Dot"))
        XCTAssertTrue(urlString.contains("keyterm=Deepgram"))
        XCTAssertTrue(urlString.contains("mip_opt_out=true"))

        let responseJSON = """
        {
          "results": {
            "channels": [
              {
                "alternatives": [
                  {
                    "transcript": "Hello from Deepgram Nova 3.",
                    "confidence": 0.99
                  }
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!
        let parsed = try DeepgramProvider.transcript(in: responseJSON)
        XCTAssertEqual(parsed, "Hello from Deepgram Nova 3.")
    }

    func testTheElevenLabsProviderNeedsAKeyAndBuildsRequests() throws {
        let provider = ElevenLabsProvider(
            apiKey: "el-secret-key",
            tagAudioEvents: true,
            noVerbatim: true,
            diarize: true,
            numSpeakers: 4,
            detectSpeakerRoles: true,
            useSpeakerLibrary: true,
            timestampsGranularity: "character",
            entityDetection: "pii",
            keyterms: "Scribe, Dot",
            transcriptEdit: "Format dates in ISO 8601."
        )
        XCTAssertTrue(provider.requiresCredential)
        let request = provider.buildTranscriptionRequest(
            apiKey: "el-secret-key",
            wav: Data([0x52, 0x49, 0x46, 0x46]),
            model: "scribe_v2",
            language: "en_US",
            boundary: "test-boundary"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "el-secret-key")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=test-boundary"
        )
        let bodyString = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("name=\"model_id\"\r\n\r\nscribe_v2"))
        XCTAssertTrue(bodyString.contains("name=\"language_code\"\r\n\r\nen"))
        XCTAssertTrue(bodyString.contains("name=\"tag_audio_events\"\r\n\r\ntrue"))
        XCTAssertTrue(bodyString.contains("name=\"no_verbatim\"\r\n\r\ntrue"))
        XCTAssertTrue(bodyString.contains("name=\"diarize\"\r\n\r\ntrue"))
        XCTAssertTrue(bodyString.contains("name=\"num_speakers\"\r\n\r\n4"))
        XCTAssertTrue(bodyString.contains("name=\"detect_speaker_roles\"\r\n\r\ntrue"))
        XCTAssertTrue(bodyString.contains("name=\"use_speaker_library\"\r\n\r\ntrue"))
        XCTAssertTrue(bodyString.contains("name=\"timestamps_granularity\"\r\n\r\ncharacter"))
        XCTAssertTrue(bodyString.contains("name=\"enable_logging\"\r\n\r\nfalse"))
        XCTAssertTrue(bodyString.contains("name=\"entity_detection\"\r\n\r\npii"))
        XCTAssertTrue(bodyString.contains("name=\"keyterms\"\r\n\r\nScribe"))
        XCTAssertTrue(bodyString.contains("name=\"keyterms\"\r\n\r\nDot"))
        XCTAssertTrue(bodyString.contains("name=\"transcript_edit\"\r\n\r\nFormat dates in ISO 8601."))

        let responseJSON = """
        {
          "language_code": "en",
          "language_probability": 0.99,
          "text": "Hello from ElevenLabs Scribe v2."
        }
        """.data(using: .utf8)!
        let parsed = try ElevenLabsProvider.transcript(in: responseJSON)
        XCTAssertEqual(parsed, "Hello from ElevenLabs Scribe v2.")
    }

    func testTheOpenAIProviderCanUseAKey() {
        let provider: any Provider = OpenAICompatibleProvider(
            baseURL: URL(string: "https://api.openai.com/v1")!
        )
        XCTAssertTrue(provider.requiresCredential)
    }

    func testTheAppleProviderNeedsNoKey() {
        let provider: any Provider = AppleSpeechProvider()
        XCTAssertFalse(provider.requiresCredential)
    }

    func testTheRegistryUsesTheAuthHeaderTheConfigurationNames() throws {
        // The header is a setting of the endpoint, so the registry has to hand
        // it to the provider instead of assuming one spelling.
        var config = DotConfig.default
        config.provider = ProviderIdentifier.openAI
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            model: "whisper-1",
            baseURL: "http://127.0.0.1:8765/v1",
            authStyle: .apiKey
        )

        let provider = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        let compatible = try XCTUnwrap(provider as? OpenAICompatibleProvider)
        XCTAssertEqual(compatible.authStyle, .apiKey)
        XCTAssertEqual(compatible.baseURL.absoluteString, "http://127.0.0.1:8765/v1")

        // No choice means the documented default.
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            model: "whisper-1",
            baseURL: "http://127.0.0.1:8765/v1"
        )
        let plain = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        XCTAssertEqual((plain as? OpenAICompatibleProvider)?.authStyle, .bearer)
    }

    func testTheDefaultSegmentLengthIsThirtySeconds() {
        let providers: [any Provider] = [
            OpenAICompatibleProvider(baseURL: URL(string: "https://api.openai.com/v1")!),
            AppleSpeechProvider(),
            DefaultCapabilityProvider(),
        ]
        for provider in providers {
            XCTAssertEqual(provider.maxSegmentSeconds, 30, provider.id)
        }
    }

    func testTheXiaomiProviderAcceptsSixtySeconds() {
        XCTAssertEqual(XiaomiASRProvider().maxSegmentSeconds, 60)
    }

    func testAProviderThatOverridesTheCapabilitiesKeepsThem() {
        let provider: any Provider = OverridingCapabilityProvider()
        XCTAssertTrue(provider.requiresCredential)
        XCTAssertEqual(provider.maxSegmentSeconds, 12)
    }
}

/// A provider that relies on the protocol extension defaults.
private struct DefaultCapabilityProvider: Provider {
    let id = "default"
    let displayName = "Default"

    func isAvailable() async -> Bool { true }

    func transcribe(wav: Data, model: String?, language: String?) async throws -> String { "" }
}

/// A provider that overrides both capabilities.
private struct OverridingCapabilityProvider: Provider {
    let id = "override"
    let displayName = "Override"
    let requiresCredential = true
    let maxSegmentSeconds = 12

    func isAvailable() async -> Bool { true }

    func transcribe(wav: Data, model: String?, language: String?) async throws -> String { "" }
}
