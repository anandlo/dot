import XCTest

@testable import DotCore

final class OpenAICompatibleProviderTests: XCTestCase {
    private func makeWAV() -> Data {
        WAVWriter.encode(samples: [0, 100, -100, 1_000, -1_000])
    }

    func testTheRequestIsAMultipartFormWithTheAudioInAFilePart() async throws {
        let wav = makeWAV()
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "the transcript"}"#),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "secret-key"
        )
        let transcript = try await provider.transcribe(wav: wav, model: "whisper-1", language: "en")
        XCTAssertEqual(transcript, "the transcript")

        XCTAssertEqual(server.requests.count, 1)
        let request = server.requests[0]
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.header("Authorization"), "Bearer secret-key")
        XCTAssertNotNil(request.header("Content-Type"))
        XCTAssertTrue(request.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)

        let body = String(decoding: request.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\""))
        XCTAssertTrue(body.contains("filename=\"audio.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.contains("name=\"model\""))
        XCTAssertTrue(body.contains("whisper-1"))
        XCTAssertTrue(body.contains("name=\"language\""))
        XCTAssertTrue(body.contains("en"))
    }

    func testTheKeyTravelsInTheHeaderTheServiceDocuments() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "ok"}"#),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "secret-key",
            authStyle: .apiKey
        )
        _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)

        let request = server.requests[0]
        XCTAssertEqual(request.header("api-key"), "secret-key")
        XCTAssertNil(request.header("Authorization"), "the bearer header is not also sent")
    }

    func testTheModelAndLanguageAreLeftOutWhenThereAreNone() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "ok"}"#),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!
        )
        _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
        let body = String(decoding: server.requests[0].body, as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"model\""))
        XCTAssertFalse(body.contains("name=\"language\""))
    }

    func testNoKeyMeansNoAuthorizationHeader() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "ok"}"#),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!
        )
        _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
        XCTAssertNil(server.requests[0].header("Authorization"))
    }

    func testTheHexShapeIsUnderstoodAsWell() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"transcript": "the other shape"}"#),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!
        )
        let transcript = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
        XCTAssertEqual(transcript, "the other shape")
    }

    func testAFailedAnswerBecomesATypedError() async throws {
        let server = try StubServer(responses: [
            .init(
                status: 401,
                json: #"{"error": {"message": "Invalid or missing bearer token", "type": "invalid_request_error"}}"#
            ),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "wrong"
        )
        do {
            _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
            XCTFail("the provider should have failed")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .rejected(status: 401, message: "Invalid or missing bearer token"))
            XCTAssertEqual(
                error.errorDescription,
                "The service answered HTTP 401: Invalid or missing bearer token"
            )
        }
    }

    func testAnAnswerWithoutTextIsReported() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"nope": true}"#),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!
        )
        do {
            _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
            XCTFail("the provider should have failed")
        } catch let error as ProviderError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testAnEmptyTranscriptIsReportedAsNoSpeech() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "   "}"#),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!
        )
        do {
            _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
            XCTFail("the provider should have failed")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .noSpeech)
        }
    }

    func testTheServiceThatCannotBeReachedIsReported() async throws {
        let port = Int.random(in: 49_000...65_000)
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!
        )
        do {
            _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
            XCTFail("the provider should have failed")
        } catch let error as ProviderError {
            guard case .transport = error else {
                return XCTFail("expected transport, got \(error)")
            }
        }
    }

    func testTheEndpointIsBuiltFromTheBaseURL() {
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "https://api.openai.com/v1")!
        )
        XCTAssertEqual(
            provider.transcriptionURL.absoluteString,
            "https://api.openai.com/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            provider.modelsURL.absoluteString,
            "https://api.openai.com/v1/models"
        )
    }

    func testConfigurableParametersAreSentInMultipartBody() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "detailed transcription with timestamps"}"#),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "test-openai-key",
            temperature: 0.25,
            prompt: "Special medical domain terminology",
            responseFormat: "verbose_json",
            timestampsGranularity: "both"
        )

        let transcript = try await provider.transcribe(wav: makeWAV(), model: "whisper-1", language: "en")
        XCTAssertEqual(transcript, "detailed transcription with timestamps")

        XCTAssertEqual(server.requests.count, 1)
        let body = String(decoding: server.requests[0].body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("name=\"temperature\"\r\n\r\n0.25\r\n"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nSpecial medical domain terminology\r\n"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        XCTAssertTrue(body.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"))
        XCTAssertTrue(body.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment\r\n"))
    }

    func testRegistryBuildsOpenAIWithAllConfigurableSettings() throws {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.openAI
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            model: "whisper-1",
            baseURL: "https://api.openai.com/v1",
            timestampsGranularity: "word",
            zeroDataRetention: true,
            temperature: 0.1,
            prompt: "Prompt guide",
            responseFormat: "verbose_json"
        )

        let provider = try ProviderRegistry.makeProvider(id: ProviderIdentifier.openAI, config: config, credentials: .empty)
        guard let openAI = provider as? OpenAICompatibleProvider else {
            XCTFail("Expected OpenAICompatibleProvider")
            return
        }

        XCTAssertEqual(openAI.temperature, 0.1)
        XCTAssertEqual(openAI.prompt, "Prompt guide")
        XCTAssertEqual(openAI.responseFormat, "verbose_json")
        XCTAssertEqual(openAI.timestampsGranularity, "word")
        XCTAssertFalse(
            RetentionControl.supportsPerRequestControl(openAI.id),
            "OpenAI decides retention on the account, so the setting must not reach a request"
        )
    }
}
