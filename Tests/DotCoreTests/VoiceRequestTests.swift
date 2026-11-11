import XCTest

@testable import DotCore

/// The request is the contract with a vendor: the endpoint, the auth header, and
/// the fields are the parts that break silently when a service changes. These
/// tests pin every one of them without a network, which is what lets a provider
/// be corrected before a person hears the failure.
final class VoiceRequestTests: XCTestCase {
    private func json(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let endpoint = URL(string: "https://example.test/v1")!

    // MARK: - OpenAI

    func testOpenAIRequestUsesBearerAuthAndPCM() throws {
        let provider = OpenAIVoiceProvider(apiKey: "sk-test")
        let settings = VoiceSettings(
            providerID: "openai",
            voiceID: "cedar",
            speed: 1.5,
            model: "gpt-4o-mini-tts",
            instructions: "Speak like a radio host"
        )
        let request = try provider.request(for: "Hello there.", settings: settings)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try json(request.httpBody)
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(body["input"] as? String, "Hello there.")
        XCTAssertEqual(body["voice"] as? String, "cedar")
        XCTAssertEqual(body["response_format"] as? String, "pcm")
        XCTAssertEqual(body["speed"] as? Double, 1.5)
        XCTAssertEqual(body["instructions"] as? String, "Speak like a radio host")
    }

    func testOpenAIDropsInstructionsOnTheLegacyModels() throws {
        let provider = OpenAIVoiceProvider(apiKey: "sk-test")
        let settings = VoiceSettings(providerID: "openai", model: "tts-1", instructions: "warm")
        let body = try json(try provider.request(for: "Hi.", settings: settings).httpBody)
        XCTAssertNil(body["instructions"], "tts-1 ignores instructions, so Dot must not send them")
    }

    func testOpenAIRefusesAnOverlongInputAndAMissingKey() {
        let provider = OpenAIVoiceProvider(apiKey: nil)
        XCTAssertThrowsError(try provider.request(for: "Hi.", settings: VoiceSettings(providerID: "openai"))) {
            guard case ProviderError.missingCredential = $0 else {
                return XCTFail("expected missingCredential, got \($0)")
            }
        }
        let keyed = OpenAIVoiceProvider(apiKey: "sk-test")
        let long = String(repeating: "a", count: OpenAIVoiceProvider.maximumInputCharacters + 1)
        XCTAssertThrowsError(try keyed.request(for: long, settings: VoiceSettings(providerID: "openai")))
    }

    // MARK: - ElevenLabs

    func testElevenLabsStreamsPCMForTheVoiceInThePath() throws {
        let provider = ElevenLabsVoiceProvider(apiKey: "xi-test")
        let settings = VoiceSettings(
            providerID: "elevenlabs",
            voiceID: "voice_123",
            speed: 1.8,
            model: "eleven_flash_v2_5"
        )
        let request = try provider.request(for: "One sentence.", settings: settings)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.elevenlabs.io/v1/text-to-speech/voice_123/stream?output_format=pcm_24000"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "xi-test")
        let body = try json(request.httpBody)
        XCTAssertEqual(body["text"] as? String, "One sentence.")
        XCTAssertEqual(body["model_id"] as? String, "eleven_flash_v2_5")
        let voiceSettings = try XCTUnwrap(body["voice_settings"] as? [String: Any])
        XCTAssertEqual(voiceSettings["speed"] as? Double, 1.2, "the endpoint only accepts 0.7 through 1.2")
    }
}

// MARK: - Cartesia

extension VoiceRequestTests {
    func testCartesiaAsksForRawPCMWithTheVersionHeader() throws {
        let provider = CartesiaVoiceProvider(apiKey: "cartesia-test")
        let settings = VoiceSettings(
            providerID: "cartesia",
            voiceID: "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4",
            speed: 0.2,
            model: "sonic-3.5"
        )
        let request = try provider.request(for: "A sentence.", settings: settings)
        XCTAssertEqual(request.url?.absoluteString, "https://api.cartesia.ai/tts/bytes")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "cartesia-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), "2026-08-14")
        let body = try json(request.httpBody)
        XCTAssertEqual(body["model_id"] as? String, "sonic-3.5")
        XCTAssertEqual(body["transcript"] as? String, "A sentence.")
        let voice = try XCTUnwrap(body["voice"] as? [String: Any])
        XCTAssertEqual(voice["id"] as? String, "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4")
        XCTAssertEqual(body["language"] as? String, "en")
        XCTAssertNil(body["locale"], "Cartesia refuses a request that sets both language and locale")
        let output = try XCTUnwrap(body["output_format"] as? [String: Any])
        XCTAssertEqual(output["container"] as? String, "raw")
        XCTAssertEqual(output["encoding"] as? String, "pcm_s16le")
        XCTAssertEqual(output["sample_rate"] as? Int, 24_000)
        let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
        XCTAssertEqual(generation["speed"] as? Double, 0.6, "the endpoint's floor is 0.6")
    }

    func testCartesiaNeedsAVoiceAndAKey() {
        let provider = CartesiaVoiceProvider(apiKey: "k")
        XCTAssertThrowsError(try provider.request(for: "Hi.", settings: VoiceSettings(providerID: "cartesia"))) {
            guard case ProviderError.unavailable = $0 else {
                return XCTFail("expected an unavailable voice, got \($0)")
            }
        }
        let keyless = CartesiaVoiceProvider(apiKey: nil)
        let settings = VoiceSettings(providerID: "cartesia", voiceID: "voice")
        XCTAssertThrowsError(try keyless.request(for: "Hi.", settings: settings))
    }

    // MARK: - Azure

    func testAzureSpeaksSSMLOnTheRegionEndpoint() throws {
        let provider = AzureVoiceProvider(region: "westeurope", apiKey: "azure-key")
        let settings = VoiceSettings(
            providerID: "azure",
            voiceID: "en-GB-SoniaNeural",
            speed: 1.25
        )
        let request = try provider.request(for: "Q&A, 3 < 4.", settings: settings)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://westeurope.tts.speech.microsoft.com/cognitiveservices/v1"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "azure-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/ssml+xml")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Microsoft-OutputFormat"),
            "raw-24khz-16bit-mono-pcm"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Dot")
        let ssml = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(ssml.contains(#"<voice name="en-GB-SoniaNeural">"#))
        XCTAssertTrue(ssml.contains(#"<prosody rate="+25%">"#))
        XCTAssertTrue(ssml.contains(#"xml:lang="en-GB""#))
        XCTAssertTrue(ssml.contains("Q&amp;A, 3 &lt; 4."))
    }

    func testAzureSlowSpeedIsANegativeProsodyRate() {
        let ssml = AzureVoiceProvider.ssml(
            text: "Slow down.",
            settings: VoiceSettings(providerID: "azure", speed: 0.5)
        )
        XCTAssertTrue(ssml.contains(#"<prosody rate="-50%">"#))
    }

    func testAzureBaseURLOverrideWins() throws {
        let provider = AzureVoiceProvider(region: "eastus", baseURL: endpoint, apiKey: "k")
        let request = try provider.request(for: "Hi.", settings: VoiceSettings(providerID: "azure"))
        XCTAssertEqual(request.url, endpoint)
    }

    // MARK: - Deepgram

    func testDeepgramUsesTheTokenSchemeAndLinear16Query() throws {
        let provider = DeepgramVoiceProvider(apiKey: "dg-test")
        let settings = VoiceSettings(providerID: "deepgram", model: "aura-2-zeus-en")
        let request = try provider.request(for: "A sentence.", settings: settings)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.deepgram.com/v1/speak?model=aura-2-zeus-en&encoding=linear16&sample_rate=24000&mip_opt_out=true"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token dg-test")
        let body = try json(request.httpBody)
        XCTAssertEqual(body["text"] as? String, "A sentence.")
    }

    func testDeepgramVoiceWinsOverModel() throws {
        let provider = DeepgramVoiceProvider(apiKey: "dg-test")
        let settings = VoiceSettings(
            providerID: "deepgram",
            voiceID: "aura-2-draco-en",
            model: "aura-2-thalia-en"
        )
        XCTAssertEqual(provider.resolvedVoiceModel(settings), "aura-2-draco-en")
        let request = try provider.request(for: "Hi.", settings: settings)
        XCTAssertTrue(request.url?.absoluteString.contains("model=aura-2-draco-en") == true)
    }

    func testEveryProviderReusesAVendorIDForTheSharedKey() {
        XCTAssertEqual(VoiceProviderID.openAI, ProviderIdentifier.openAI)
        XCTAssertEqual(VoiceProviderID.elevenLabs, ProviderIdentifier.elevenLabs)
        XCTAssertEqual(VoiceProviderID.azure, ProviderIdentifier.azure)
        XCTAssertEqual(VoiceProviderID.deepgram, ProviderIdentifier.deepgram)
        XCTAssertEqual(VoiceProviderID.apple, ProviderIdentifier.apple)
        XCTAssertEqual(Set(VoiceProviderID.all).count, VoiceProviderID.all.count)
    }
}

// MARK: - The address rule

extension VoiceRequestTests {
    func testACleartextRemoteEndpointIsRefused() {
        let provider = OpenAIVoiceProvider(
            baseURL: URL(string: "http://api.example.com/v1")!,
            apiKey: "k"
        )
        XCTAssertThrowsError(try provider.request(for: "Hi.", settings: VoiceSettings(providerID: "openai"))) {
            guard case ProviderError.unavailable(let detail) = $0 else {
                return XCTFail("expected the endpoint to be refused, got \($0)")
            }
            XCTAssertTrue(detail.contains("api.example.com"))
        }
    }

    func testALoopbackEndpointIsAllowed() throws {
        let provider = ElevenLabsVoiceProvider(
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            apiKey: "k"
        )
        let settings = VoiceSettings(providerID: "elevenlabs", voiceID: "v")
        XCTAssertNoThrow(try provider.request(for: "Hi.", settings: settings))
    }

    func testEndpointPolicyReadsAStoredAddress() throws {
        let fallback = OpenAIVoiceProvider.defaultBaseURL
        XCTAssertEqual(try VoiceEndpoint.url("", fallback: fallback), fallback)
        XCTAssertEqual(
            try VoiceEndpoint.url("https://proxy.example.com/v1", fallback: fallback).host,
            "proxy.example.com"
        )
        XCTAssertThrowsError(try VoiceEndpoint.url("ftp://example.com", fallback: fallback))
    }
}
