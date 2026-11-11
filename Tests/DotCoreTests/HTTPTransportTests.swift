import Foundation
import XCTest

@testable import DotCore

/// How much of a service's answer Dot will hold.
///
/// `URLSession.data(for:)` buffers the whole body before the caller sees it, so
/// an endpoint that answers with a gigabyte is a gigabyte of memory. The
/// transport reads with a ceiling instead.
final class HTTPTransportTests: XCTestCase {
    private func request(_ port: Int) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.httpBody = Data("audio".utf8)
        return request
    }

    func testAnAnswerInsideTheLimitIsRead() async throws {
        let server = try StubServer(responses: [
            .init(status: 200, json: #"{"text": "hello"}"#),
        ])
        let answer = try await HTTPTransport.send(
            request(server.port),
            session: OpenAICompatibleProvider.makeSession(),
            limit: 1_024
        )
        XCTAssertEqual(String(decoding: answer.data, as: UTF8.self), #"{"text": "hello"}"#)
        XCTAssertEqual((answer.response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testAnAnswerPastTheLimitIsRefusedInsteadOfBuffered() async throws {
        // Half a megabyte of markup, declared on the wire: exactly the shape a
        // proxy or a captive portal answers a POST with.
        let page = Data(String(repeating: "<html>not a transcript</html>", count: 20_000).utf8)
        let server = try StubServer(responses: [
            .init(status: 200, body: page, contentType: "text/html"),
        ])
        do {
            _ = try await HTTPTransport.send(
                request(server.port),
                session: OpenAICompatibleProvider.makeSession(),
                limit: 1_024
            )
            XCTFail("an oversized answer was accepted")
        } catch ProviderError.invalidResponse(let detail) {
            XCTAssertEqual(detail, ProviderErrorText.oversizedAnswer)
        }
    }

    func testAProviderRefusesAnOversizedErrorPage() async throws {
        // Past the ceiling the transport itself enforces, not the small one the
        // tests above use.
        let page = Data(String(repeating: "<html>blocked by a proxy</html>", count: 200_000).utf8)
        XCTAssertGreaterThan(page.count, HTTPTransport.maximumResponseBytes)
        let server = try StubServer(responses: [
            .init(status: 500, body: page, contentType: "text/html"),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "test-key"
        )
        do {
            _ = try await provider.transcribe(
                wav: WAVWriter.encode(samples: [0, 10]),
                model: nil,
                language: nil
            )
            XCTFail("the oversized answer was accepted")
        } catch ProviderError.invalidResponse(let detail) {
            XCTAssertEqual(detail, ProviderErrorText.oversizedAnswer)
        }
    }
}
