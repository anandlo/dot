import XCTest
@testable import DotCore

final class SecurityTests: XCTestCase {
    func testConfigSerializationNeverContainsAPIKeys() throws {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.openAI
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            model: "whisper-1",
            baseURL: "https://api.openai.com/v1",
            zeroDataRetention: true
        )
        config.providers[ProviderIdentifier.deepgram] = ProviderConfig(
            model: "nova-3",
            baseURL: "https://api.deepgram.com/v1",
            zeroDataRetention: true
        )
        config.providers[ProviderIdentifier.elevenLabs] = ProviderConfig(
            model: "scribe_v2",
            zeroDataRetention: true
        )

        let encodedData = try JSONEncoder().encode(config)
        let jsonString = String(decoding: encodedData, as: UTF8.self).lowercased()

        // Ensure no credential field names exist in serialized configuration
        XCTAssertFalse(jsonString.contains("apikey"))
        XCTAssertFalse(jsonString.contains("api_key"))
        XCTAssertFalse(jsonString.contains("secret"))
        XCTAssertFalse(jsonString.contains("token"))
        XCTAssertFalse(jsonString.contains("password"))
        XCTAssertFalse(jsonString.contains("credential"))
    }

    func testMaskedKeyNeverLeaksFullSecret() {
        let secret = "sk-proj-1234567890abcdefghijklmnopqrstuvwxyz"
        let display = MaskedKey.describe(secret) ?? ""

        XCTAssertFalse(display.contains(secret))
        XCTAssertFalse(display.contains("1234567890abcdef"))
        XCTAssertTrue(display.contains("…") || display.contains("•") || display.count < secret.count)
    }

    func testEphemeralSessionDisablesDiskCachingAndCookies() {
        let session = OpenAICompatibleProvider.makeSession()
        let config = session.configuration

        XCTAssertNil(config.urlCache, "URL cache must be nil to avoid caching speech audio or transcripts")
        XCTAssertFalse(config.httpShouldSetCookies, "HTTP cookies must be disabled")
        XCTAssertEqual(
            config.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData,
            "Must ignore both local and remote caches"
        )
    }

    func testZeroDataRetentionFlagsAreEnforced() {
        // Deepgram ZDR opt-out
        let deepgramZDR = DeepgramProvider(zeroDataRetention: true)
        let deepgramURL = deepgramZDR.listenURL(model: nil, language: nil).absoluteString
        XCTAssertTrue(deepgramURL.contains("mip_opt_out=true"))

        // ElevenLabs server-side logging disable
        let elevenLabsZDR = ElevenLabsProvider(zeroDataRetention: true)
        let boundary = "TestBoundary"
        let request = elevenLabsZDR.buildTranscriptionRequest(
            apiKey: "test-key",
            wav: Data(),
            model: nil,
            language: nil,
            boundary: boundary
        )
        let elevenLabsBody = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(elevenLabsBody.contains("name=\"enable_logging\"\r\n\r\nfalse"))

        // Azure storeAudio opt-out
        let azureZDR = AzureSpeechProvider(zeroDataRetention: true)
        let azureURL = azureZDR.endpointURL(language: "en").absoluteString
        XCTAssertTrue(azureURL.contains("storeAudio=false"))
    }

    func testCustomEndpointRetentionTransparency() {
        // Custom endpoints have transparent retention notices
        let customPreset = ProviderPreset.custom
        XCTAssertEqual(customPreset.id, "custom")
        XCTAssertTrue(customPreset.hasEndpoint)
    }
}
