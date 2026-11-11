import XCTest

@testable import DotCore

/// Speech is a stream, and the audio path is only fast if the first chunk is
/// handed over while the service is still generating. These tests run a real
/// loopback HTTP server, because the provider's request, the status check and the
/// reader are one path and a mock would not prove the path.
final class VoiceStreamTests: XCTestCase {
    private let settings = VoiceSettings(providerID: "openai", voiceID: "marin")

    private func baseURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    private func collect(_ stream: AsyncThrowingStream<VoiceChunk, Error>) async throws -> [VoiceChunk] {
        var chunks: [VoiceChunk] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }

    func testOpenAIStreamsTheWholeAnswerOverLoopback() async throws {
        let audio = Data((0..<10_000).map { UInt8($0 % 251) })
        let server = try StubServer(responses: [
            .init(status: 200, body: audio, contentType: "audio/pcm")
        ])
        let provider = OpenAIVoiceProvider(baseURL: baseURL(port: server.port), apiKey: "sk-test")
        let stream = try await provider.speech(text: "Hello there.", settings: settings)
        let chunks = try await collect(stream)

        XCTAssertEqual(chunks.count, 3, "10000 bytes is two full chunks and a remainder")
        XCTAssertEqual(chunks.map(\.data.count), [4096, 4096, 1808])
        XCTAssertEqual(chunks.reduce(Data(), { $0 + $1.data }), audio)
        XCTAssertEqual(chunks.first?.format, .pcm24k)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/audio/speech")
        XCTAssertEqual(request.header("Authorization"), "Bearer sk-test")
        let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        XCTAssertEqual(body?["input"] as? String, "Hello there.")
        XCTAssertEqual(body?["response_format"] as? String, "pcm")
    }

    func testElevenLabsStreamsOverLoopbackWithTheVoiceInThePath() async throws {
        let audio = Data(repeating: 7, count: 9_000)
        let server = try StubServer(responses: [
            .init(status: 200, body: audio, contentType: "audio/pcm")
        ])
        let provider = ElevenLabsVoiceProvider(baseURL: baseURL(port: server.port), apiKey: "xi-test")
        let stream = try await provider.speech(
            text: "One sentence.",
            settings: VoiceSettings(providerID: "elevenlabs", voiceID: "voice_9")
        )
        let chunks = try await collect(stream)

        XCTAssertEqual(chunks.reduce(Data(), { $0 + $1.data }), audio)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, "/v1/text-to-speech/voice_9/stream")
        XCTAssertEqual(request.header("xi-api-key"), "xi-test")
        XCTAssertTrue(request.query.contains("output_format=pcm_24000"))
    }

    func testARefusalCarriesTheServiceMessage() async throws {
        let server = try StubServer(responses: [
            .init(status: 401, json: #"{"error":{"message":"Invalid API key"}}"#)
        ])
        let provider = OpenAIVoiceProvider(baseURL: baseURL(port: server.port), apiKey: "sk-bad")
        do {
            _ = try await provider.speech(text: "Hi.", settings: settings)
            XCTFail("a 401 must not become a stream")
        } catch let ProviderError.rejected(status, message) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "Invalid API key")
        }
    }

    func testAnAnswerPastTheCeilingIsRefused() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, body: Data(repeating: 3, count: 5_000), contentType: "audio/pcm")
        ])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/audio/speech")!)
        request.httpMethod = "POST"
        do {
            let stream = try await VoiceByteStream.chunks(
                request,
                session: URLSession(configuration: .ephemeral),
                format: .pcm24k,
                limit: 1_000
            )
            _ = try await collect(stream)
            XCTFail("an answer larger than the limit must not be read to the end")
        } catch ProviderError.invalidResponse {
            // The ceiling is the whole point of the reader.
        }
    }

    func testTheFirstChunkArrivesBeforeTheAnswerIsComplete() async throws {
        let first = Data(repeating: 1, count: 4096)
        let second = Data(repeating: 2, count: 512)
        let server = try TwoPartStubServer(first: first, second: second)
        let provider = OpenAIVoiceProvider(baseURL: baseURL(port: server.port), apiKey: "sk-test")
        let stream = try await provider.speech(text: "Hello there.", settings: settings)
        var iterator = stream.makeAsyncIterator()

        let started = Date()
        let chunk = try await iterator.next()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(chunk?.data.count, 4096)
        XCTAssertLessThan(elapsed, 2, "the first chunk waited for the end of the answer")

        server.releaseSecondPart()
        var rest = Data()
        while let next = try await iterator.next() { rest.append(next.data) }
        XCTAssertEqual(rest.count, 512)
        XCTAssertTrue(server.requestText.contains("POST /v1/audio/speech"))
        XCTAssertTrue(server.requestText.lowercased().contains("authorization: bearer sk-test"))
    }
}
