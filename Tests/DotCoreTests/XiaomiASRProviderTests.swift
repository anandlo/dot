import XCTest

@testable import DotCore

final class XiaomiASRProviderTests: XCTestCase {
    private func makeWAV() -> Data {
        WAVWriter.encode(samples: [0, 100, -100, 1_000, -1_000])
    }

    func testTheRequestIsAChatCompletionWithTheAudioAsADataURL() async throws {
        let wav = makeWAV()
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"choices":[{"message":{"content":"the transcript"}}]}"#),
        ])
        let provider = XiaomiASRProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "test-key",
            systemLanguage: "en-CA"
        )

        let transcript = try await provider.transcribe(wav: wav, model: nil, language: nil)

        XCTAssertEqual(transcript, "the transcript")
        XCTAssertEqual(server.requests.count, 1)
        let request = server.requests[0]
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/chat/completions")
        XCTAssertEqual(request.header("api-key"), "test-key")
        XCTAssertNil(request.header("Authorization"))
        XCTAssertEqual(request.header("Content-Type"), "application/json")

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, XiaomiASRProvider.defaultModel)

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "input_audio")
        let audio = try XCTUnwrap(content[0]["input_audio"] as? [String: Any])
        let data = try XCTUnwrap(audio["data"] as? String)
        XCTAssertEqual(data, "data:audio/wav;base64," + wav.base64EncodedString())

        // Nothing was chosen, so the Mac's own language is sent rather than a
        // request that asks the service to guess.
        let options = try XCTUnwrap(body["asr_options"] as? [String: Any])
        XCTAssertEqual(options["language"] as? String, "en")
    }

    func testNoHintIsSentForALanguageTheServiceDoesNotName() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"choices":[{"message":{"content":"ok"}}]}"#),
        ])
        let provider = XiaomiASRProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "test-key",
            systemLanguage: "fr-FR"
        )

        _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: server.requests[0].body) as? [String: Any]
        )
        XCTAssertNil(
            body["asr_options"],
            "the request carries no language option rather than an undefined value"
        )
    }

    func testTheConfiguredModelAndLanguageAreSent() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"choices":[{"message":{"content":"ok"}}]}"#),
        ])
        let provider = XiaomiASRProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "test-key"
        )

        _ = try await provider.transcribe(
            wav: makeWAV(),
            model: "custom-model",
            language: "zh_CN"
        )

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: server.requests[0].body) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "custom-model")
        let options = try XCTUnwrap(body["asr_options"] as? [String: Any])
        XCTAssertEqual(options["language"] as? String, "zh")
    }

    func testTheLanguageTheRequestAsksForIsTheServiceOwnName() {
        // A stored choice is kept, and normalized to the two names the API has.
        XCTAssertEqual(XiaomiASRProvider.asrLanguage("en_US", system: "zh-Hans"), "en")
        XCTAssertEqual(XiaomiASRProvider.asrLanguage("EN", system: nil), "en")
        XCTAssertEqual(XiaomiASRProvider.asrLanguage("zh-Hans", system: "en-CA"), "zh")

        // `auto`, or nothing stored, means the person did not choose: the Mac's
        // language is the best answer, and it is what stops an English
        // recording from being answered in Chinese.
        XCTAssertEqual(XiaomiASRProvider.asrLanguage(nil, system: "en-CA"), "en")
        XCTAssertEqual(XiaomiASRProvider.asrLanguage("", system: "zh-Hans"), "zh")
        XCTAssertEqual(XiaomiASRProvider.asrLanguage("auto", system: "en-US"), "en")

        // A language the service does not name is no hint at all.
        XCTAssertNil(XiaomiASRProvider.asrLanguage("fr", system: "en-CA"))
        XCTAssertNil(XiaomiASRProvider.asrLanguage("auto", system: "fr-FR"))
        XCTAssertNil(XiaomiASRProvider.asrLanguage(nil, system: nil))
        XCTAssertNil(XiaomiASRProvider.asrLanguage("", system: ""))
    }

    func testAnArrayOfTextPartsIsJoined() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"choices":[{"message":{"content":[{"type":"text","text":"Hello "},{"type":"text","text":"world<|eot|>"}]}}]}"#),
        ])
        let provider = XiaomiASRProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "test-key"
        )

        let transcript = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
        XCTAssertEqual(transcript, "Hello world")
    }

    func testTheLanguageTagAndControlTokensAreRemoved() {
        XCTAssertEqual(
            XiaomiASRProvider.cleanTranscript("<chinese> 你好 world <|eot|>"),
            "你好 world"
        )
        XCTAssertEqual(
            XiaomiASRProvider.cleanTranscript("<|a|b|>The meeting is at four."),
            "The meeting is at four."
        )
    }

    func testAReasoningBlockIsRemovedWithItsContent() {
        XCTAssertEqual(
            // The model pads the tags before the `>`: both spellings are
            // blocks, and neither may leave its reasoning behind.
            XiaomiASRProvider.cleanTranscript("<think >weigh the options</think >The meeting is at four."),
            "The meeting is at four."
        )
        XCTAssertEqual(
            XiaomiASRProvider.cleanTranscript("<think>weigh the options</think>The meeting is at four."),
            "The meeting is at four."
        )
        XCTAssertEqual(
            XiaomiASRProvider.cleanTranscript("The meeting\n\n is at four."),
            "The meeting is at four."
        )
    }

    func testThePlainTextReasoningMarkerIsRemovedOnlyAsAToken() {
        XCTAssertEqual(
            XiaomiASRProvider.cleanTranscript("think>The meeting is at four."),
            "The meeting is at four."
        )
        XCTAssertEqual(
            XiaomiASRProvider.cleanTranscript("thinking>The meeting is at four."),
            "The meeting is at four."
        )
        XCTAssertEqual(
            XiaomiASRProvider.cleanTranscript("The meeting is at four. think>"),
            "The meeting is at four."
        )
        XCTAssertEqual(
            XiaomiASRProvider.cleanTranscript("I think so."),
            "I think so."
        )
        XCTAssertEqual(
            XiaomiASRProvider.cleanTranscript("  The   meeting \n is at four.  "),
            "The meeting is at four."
        )
        XCTAssertEqual(
            XiaomiASRProvider.stripCJKCharacters("Hello world! 10 apples and 123 oranges."),
            "Hello world! 10 apples and 123 oranges."
        )
        XCTAssertEqual(
            XiaomiASRProvider.stripCJKCharacters("Hello 嗯 world!"),
            "Hello world!"
        )
        XCTAssertEqual(
            XiaomiASRProvider.stripCJKCharacters("1. Hello world!"),
            "Hello world!"
        )
        XCTAssertEqual(
            XiaomiASRProvider.stripCJKCharacters("Can you hear me? I'm testing this app. 1."),
            "Can you hear me? I'm testing this app."
        )
        XCTAssertEqual(
            XiaomiASRProvider.stripCJKCharacters("10."),
            ""
        )
    }

    func testAKeyIsTheOnlyRequirement() async {
        let provider = XiaomiASRProvider(apiKey: "test-key")
        let ready = await provider.isAvailable()
        XCTAssertTrue(ready)
        XCTAssertTrue(provider.requiresCredential)
        XCTAssertEqual(provider.maxSegmentSeconds, 30)

        let withoutKey = XiaomiASRProvider()
        let unavailable = await withoutKey.isAvailable()
        XCTAssertFalse(unavailable)
    }

    func testNoKeyFailsWithoutARequest() async {
        let provider = XiaomiASRProvider(baseURL: URL(string: "http://127.0.0.1:1/v1")!)
        do {
            _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
            XCTFail("the provider should have failed")
        } catch let error as ProviderError {
            guard case .missingCredential = error else {
                return XCTFail("expected missingCredential, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTheUpstreamStatusBecomesARejectedError() async throws {
        let server = try StubServer(responses: [
            .init(status: 401, json: #"{"error":{"message":"Invalid API key"}}"#),
        ])
        let provider = XiaomiASRProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "wrong"
        )

        do {
            _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
            XCTFail("the provider should have failed")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .rejected(status: 401, message: "Invalid API key"))
        }
    }

    func testEveryUpstreamFailureUsesTheTypedErrors() async throws {
        let statuses = [403, 429, 500, 503]
        for status in statuses {
            let server = try StubServer(responses: [
                .init(status: status, json: #"{"message":"upstream said no"}"#),
            ])
            let provider = XiaomiASRProvider(
                baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
                apiKey: "test-key"
            )
            do {
                _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
                XCTFail("HTTP \(status) should have failed")
            } catch let error as ProviderError {
                XCTAssertEqual(
                    error,
                    .rejected(status: status, message: "upstream said no")
                )
            }
        }
    }

    func testAnAnswerThatIsNotJSONIsAnInvalidResponse() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, body: Data("not json".utf8), contentType: "text/plain"),
        ])
        let provider = XiaomiASRProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "test-key"
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
            .init(status: 200, json: #"{"choices":[{"message":{"content":"<|eot|>"}}]}"#),
        ])
        let provider = XiaomiASRProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "test-key"
        )

        do {
            _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
            XCTFail("the provider should have failed")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .noSpeech)
        }
    }

    func testAnUnreachableServiceIsATransportError() async {
        let provider = XiaomiASRProvider(
            baseURL: URL(string: "http://127.0.0.1:1/v1")!,
            apiKey: "test-key",
            timeout: 3
        )

        do {
            _ = try await provider.transcribe(wav: makeWAV(), model: nil, language: nil)
            XCTFail("the provider should have failed")
        } catch let error as ProviderError {
            guard case .transport = error else {
                return XCTFail("expected transport, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
