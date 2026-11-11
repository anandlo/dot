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
}
