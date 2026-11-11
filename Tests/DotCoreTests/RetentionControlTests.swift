import XCTest
@testable import DotCore

/// The zero-retention setting only exists where a request can carry it.
///
/// A switch labelled zero retention that changes nothing in the request is a
/// promise about someone else's servers that Dot cannot keep. These tests hold
/// the line: the three vendors that document a per-request parameter keep the
/// setting, the two that decide retention on the account do not, and no request
/// grows a parameter no vendor documents.
final class RetentionControlTests: XCTestCase {
    private let perRequestProviders = [
        ProviderIdentifier.deepgram,
        ProviderIdentifier.elevenLabs,
        ProviderIdentifier.azure,
    ]

    func testThePerRequestProvidersAreTheDocumentedOnes() {
        XCTAssertEqual(RetentionControl.parameter(for: ProviderIdentifier.deepgram), "mip_opt_out")
        XCTAssertEqual(RetentionControl.parameter(for: ProviderIdentifier.elevenLabs), "enable_logging")
        XCTAssertEqual(RetentionControl.parameter(for: ProviderIdentifier.azure), "storeAudio")

        for id in perRequestProviders {
            XCTAssertTrue(
                RetentionControl.supportsPerRequestControl(id),
                "\(id) documents a per-request control and must keep the setting"
            )
        }
    }

    func testAccountLevelProvidersHaveNoPerRequestControl() {
        for id in [ProviderIdentifier.openAI, ProviderIdentifier.groq] {
            XCTAssertEqual(RetentionControl.control(for: id), .providerSetting)
            XCTAssertFalse(RetentionControl.supportsPerRequestControl(id))
            XCTAssertNil(RetentionControl.parameter(for: id))
        }
    }

    func testOnDeviceAndStoredEndpointsSayWhatTheyCanSay() {
        XCTAssertEqual(RetentionControl.control(for: ProviderIdentifier.apple), .onDevice)
        XCTAssertEqual(RetentionControl.control(for: ProviderIdentifier.xiaomi), .endpointPolicy)
        XCTAssertEqual(RetentionControl.control(for: "com.example.custom"), .endpointPolicy)
        XCTAssertFalse(RetentionControl.supportsPerRequestControl(ProviderIdentifier.xiaomi))
    }

    func testOnlyProvidersThatCanHonourItStartWithTheSetting() {
        let providers = DotConfig.default.providers

        for id in perRequestProviders {
            XCTAssertEqual(
                providers[id]?.zeroDataRetention,
                true,
                "\(id) applies the setting, so a fresh configuration should ask for it"
            )
        }
        for id in [ProviderIdentifier.openAI, ProviderIdentifier.groq, ProviderIdentifier.xiaomi] {
            XCTAssertNil(
                providers[id]?.zeroDataRetention,
                "\(id) cannot apply the setting, so a fresh configuration must not promise it"
            )
        }
    }

    func testTheStoredSettingStillReachesTheThreeProviders() {
        let deepgram = DeepgramProvider(zeroDataRetention: true)
        let deepgramURL = deepgram.listenURL(model: nil, language: nil).absoluteString
        XCTAssertTrue(deepgramURL.contains("mip_opt_out=true"))

        let elevenLabs = ElevenLabsProvider(zeroDataRetention: true)
        let request = elevenLabs.buildTranscriptionRequest(
            apiKey: "key",
            wav: Data(),
            model: nil,
            language: nil,
            boundary: "Boundary"
        )
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"enable_logging\"\r\n\r\nfalse"))

        let azure = AzureSpeechProvider(zeroDataRetention: true)
        XCTAssertTrue(azure.endpointURL(language: "en").absoluteString.contains("storeAudio=false"))
    }

    func testOpenAISendsNoRetentionParameter() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "ok"}"#),
        ])
        var config = DotConfig.default
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            baseURL: "http://127.0.0.1:\(server.port)/v1",
            zeroDataRetention: true,
            temperature: 0.0,
            prompt: "context",
            responseFormat: "json"
        )
        let provider = try ProviderRegistry.makeProvider(
            id: ProviderIdentifier.openAI,
            config: config,
            credentials: .empty
        )

        _ = try await provider.transcribe(
            wav: WAVWriter.encode(samples: [0, 100, -100]),
            model: "whisper-1",
            language: "en"
        )

        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(
            multipartFieldNames(in: server.requests[0].body).isDisjoint(with: retentionNames),
            "the OpenAI request carries a retention parameter the vendor does not document"
        )
    }

    func testGroqSendsNoRetentionParameter() throws {
        let provider = GroqProvider(apiKey: "gsk_test", prompt: "context")
        let request = try provider.buildRequest(
            wav: WAVWriter.encode(samples: [0, 100, -100]),
            model: "whisper-large-v3",
            language: "en"
        )

        let body = try XCTUnwrap(request.httpBody)
        XCTAssertTrue(
            multipartFieldNames(in: body).isDisjoint(with: retentionNames),
            "the Groq request carries a retention parameter the vendor does not document"
        )
    }

    /// The names that would look like a retention control in a request.
    private var retentionNames: Set<String> {
        [
            "mip_opt_out", "enable_logging", "storeAudio", "store",
            "retention", "retention_policy", "zero_data_retention",
        ]
    }

    /// The `name` of every part in a multipart body.
    private func multipartFieldNames(in body: Data) -> Set<String> {
        let text = String(decoding: body, as: UTF8.self)
        var names: Set<String> = []
        var remainder = Substring(text)
        while let start = remainder.range(of: "name=\"") {
            let rest = remainder[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            names.insert(String(rest[..<end]))
            remainder = rest[end...]
        }
        return names
    }
}
