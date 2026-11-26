import Network
import XCTest

@testable import DotCore

/// The framing rules of `text/event-stream`.
///
/// The decoder is the one place every provider's stream passes through, so the
/// rules are tested on their own before any provider is involved: Anthropic
/// names its events and OpenAI does not, a payload can be split across several
/// `data:` lines, and a comment must never become an event.
final class AssistantSSEDecoderTests: XCTestCase {
    func testABlankLineDispatchesTheCollectedEvent() throws {
        let events = try SSEDecoder.decode("data: hello\n\n")
        XCTAssertEqual(events, [SSEEvent(name: nil, data: "hello")])
    }

    func testAColonStartsACommentThatIsIgnored() throws {
        let events = try SSEDecoder.decode(": keep-alive\ndata: hello\n\n")
        XCTAssertEqual(events, [SSEEvent(name: nil, data: "hello")])
    }

    func testSeveralDataLinesAreJoinedWithANewline() throws {
        let events = try SSEDecoder.decode("data: first\ndata: second\n\n")
        XCTAssertEqual(events, [SSEEvent(name: nil, data: "first\nsecond")])
    }

    func testTheEventNameIsCarried() throws {
        let events = try SSEDecoder.decode("event: content_block_delta\ndata: {\"a\":1}\n\n")
        XCTAssertEqual(events, [SSEEvent(name: "content_block_delta", data: "{\"a\":1}")])
    }

    func testACrlfBodyDecodesLikeAnLfBody() throws {
        let events = try SSEDecoder.decode("event: ping\r\ndata: {\"type\":\"ping\"}\r\n\r\n")
        XCTAssertEqual(events, [SSEEvent(name: "ping", data: "{\"type\":\"ping\"}")])
    }

    func testAnEventWithNoDataIsNotDispatched() throws {
        let events = try SSEDecoder.decode("event: ping\n\n")
        XCTAssertEqual(events, [])
    }

    func testOnlyOneSpaceAfterTheColonIsRemoved() throws {
        let events = try SSEDecoder.decode("data:  two spaces\n\n")
        XCTAssertEqual(events, [SSEEvent(name: nil, data: " two spaces")])
    }

    func testUnknownFieldsAreIgnored() throws {
        let events = try SSEDecoder.decode("id: 42\nretry: 1000\ndata: payload\n\n")
        XCTAssertEqual(events, [SSEEvent(name: nil, data: "payload")])
    }

    func testALastEventWithoutItsBlankLineIsFlushed() throws {
        let events = try SSEDecoder.decode("data: last")
        XCTAssertEqual(events, [SSEEvent(name: nil, data: "last")])
    }

    func testAnEventLargerThanTheLimitThrows() {
        var decoder = SSEDecoder(limits: AssistantStreamLimits(maximumEventBytes: 8))
        XCTAssertThrowsError(try decoder.consume(line: "data: 123456789")) { error in
            guard case ProviderError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testTheNameIsClearedAfterAnEventIsDispatched() throws {
        var decoder = SSEDecoder()
        _ = try decoder.consume(line: "event: first")
        XCTAssertEqual(try decoder.consume(line: "data: one"), nil)
        XCTAssertEqual(try decoder.consume(line: ""), SSEEvent(name: "first", data: "one"))
        _ = try decoder.consume(line: "data: two")
        XCTAssertEqual(try decoder.consume(line: ""), SSEEvent(name: nil, data: "two"))
    }

    func testChunkedEventStreamDecodesSplitUTF8AcrossChunks() async throws {
        let message = "こんにちは 𐍈 café"
        let sseBytes = Array("data: \(message)\r\n\r\n".utf8)
        let splitPoint = 12 // inside the multi-byte UTF-8 sequence
        let firstChunk = Data(sseBytes[..<splitPoint])
        let secondChunk = Data(sseBytes[splitPoint...])

        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "dot.sse.chunked.test")
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: head + firstChunk, completion: .contentProcessed { _ in
                    queue.asyncAfter(deadline: .now() + 0.03) {
                        connection.send(content: secondChunk, isComplete: true, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        let port = Int(listener.port?.rawValue ?? 0)

        let session = OpenAICompatibleProvider.makeSession()
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream")!)
        var events: [SSEEvent] = []
        for try await event in HTTPTransport.eventStream(request, session: session) {
            events.append(event)
        }
        XCTAssertEqual(events, [SSEEvent(name: nil, data: message)])
    }

    func testChunkedEventStreamEnforcesMaximumLineBytes() async throws {
        let oversizedLine = "data: " + String(repeating: "x", count: 128) + "\n\n"
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "dot.sse.limit.test")
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: head + Data(oversizedLine.utf8), isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        let port = Int(listener.port?.rawValue ?? 0)

        let session = OpenAICompatibleProvider.makeSession()
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream")!)
        let limits = AssistantStreamLimits(maximumLineBytes: 64)
        do {
            for try await _ in HTTPTransport.eventStream(request, session: session, limits: limits) {}
            XCTFail("oversized SSE line was accepted")
        } catch ProviderError.invalidResponse(let detail) {
            XCTAssertEqual(detail, ProviderErrorText.oversizedAnswer)
        }
    }
}
