import XCTest
@testable import DotCore

final class GroqProviderTests: XCTestCase {
    func testDefaultsAndMetadata() {
        let provider = GroqProvider(apiKey: "gsk_test123")
        XCTAssertEqual(provider.id, "groq")
        XCTAssertEqual(provider.displayName, "Groq")
        XCTAssertTrue(provider.requiresCredential)
        XCTAssertEqual(provider.maxSegmentSeconds, 120)
        XCTAssertEqual(provider.baseURL, GroqProvider.defaultBaseURL)
        XCTAssertEqual(GroqProvider.defaultModel, "whisper-large-v3-turbo")
        XCTAssertTrue(provider.zeroDataRetention)
    }

    func testSupportedModelsCatalog() {
        let models = GroqProvider.supportedModels
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models[0].id, "whisper-large-v3-turbo")
        XCTAssertEqual(models[1].id, "whisper-large-v3")
        XCTAssertEqual(models[2].id, "distil-whisper-large-v3-en")
    }

    func testBuildRequestHeadersAndFields() throws {
        let provider = GroqProvider(
            apiKey: "gsk_secretKey",
            temperature: 0.2,
            prompt: "Test context vocabulary",
            responseFormat: "verbose_json",
            zeroDataRetention: true
        )
        let sampleWav = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        let request = try provider.buildRequest(wav: sampleWav, model: "whisper-large-v3", language: "en")

        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gsk_secretKey")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains("name=\"model\"\r\n\r\nwhisper-large-v3\r\n"))
        XCTAssertTrue(bodyString.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(bodyString.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        XCTAssertTrue(bodyString.contains("name=\"temperature\"\r\n\r\n0.20\r\n"))
        XCTAssertTrue(bodyString.contains("name=\"prompt\"\r\n\r\nTest context vocabulary\r\n"))
        XCTAssertTrue(bodyString.contains("filename=\"audio.wav\""))
    }

    func testMissingApiKeyThrows() {
        let provider = GroqProvider(apiKey: nil)
        let wav = Data([0x01, 0x02])
        XCTAssertThrowsError(try provider.buildRequest(wav: wav, model: nil, language: nil)) { error in
            guard case ProviderError.missingCredential = error else {
                return XCTFail("expected missingCredential, got \(error)")
            }
        }
    }

    func testParseJsonTranscript() throws {
        let json = """
        {
            "text": "The quick brown fox jumps over the lazy dog."
        }
        """.data(using: .utf8)!

        let result = try GroqProvider.transcript(in: json, format: "json")
        XCTAssertEqual(result, "The quick brown fox jumps over the lazy dog.")
    }

    func testParsePlainTextTranscript() throws {
        let text = "Direct transcription output text.".data(using: .utf8)!
        let result = try GroqProvider.transcript(in: text, format: "text")
        XCTAssertEqual(result, "Direct transcription output text.")
    }

    func testErrorMessageExtraction() {
        let errorJson = """
        {
            "error": {
                "message": "Invalid API Key provided",
                "type": "invalid_request_error"
            }
        }
        """.data(using: .utf8)!
        let message = GroqProvider.errorMessage(in: errorJson)
        XCTAssertEqual(message, "Invalid API Key provided")
    }

    func testTimestampGranularitiesInVerboseJson() throws {
        let sampleWav = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])

        let providerWord = GroqProvider(apiKey: "key", responseFormat: "verbose_json", timestampsGranularity: "word")
        let reqWord = try providerWord.buildRequest(wav: sampleWav, model: nil, language: nil)
        let bodyWord = String(decoding: reqWord.httpBody!, as: UTF8.self)
        XCTAssertTrue(bodyWord.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"))

        let providerBoth = GroqProvider(apiKey: "key", responseFormat: "verbose_json", timestampsGranularity: "both")
        let reqBoth = try providerBoth.buildRequest(wav: sampleWav, model: nil, language: nil)
        let bodyBoth = String(decoding: reqBoth.httpBody!, as: UTF8.self)
        XCTAssertTrue(bodyBoth.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"))
        XCTAssertTrue(bodyBoth.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment\r\n"))
    }

    func testRegistryBuildsGroqWithAllConfigurableSettings() throws {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.groq
        config.providers[ProviderIdentifier.groq] = ProviderConfig(
            timestampsGranularity: "both",
            zeroDataRetention: true,
            temperature: 0.35,
            prompt: "Technical terminology dictionary",
            responseFormat: "verbose_json"
        )

        let provider = try ProviderRegistry.makeProvider(id: ProviderIdentifier.groq, config: config, credentials: .empty)
        guard let groq = provider as? GroqProvider else {
            XCTFail("Expected GroqProvider")
            return
        }

        XCTAssertEqual(groq.temperature, 0.35)
        XCTAssertEqual(groq.prompt, "Technical terminology dictionary")
        XCTAssertEqual(groq.responseFormat, "verbose_json")
        XCTAssertEqual(groq.timestampsGranularity, "both")
        XCTAssertTrue(groq.zeroDataRetention)
    }
}
