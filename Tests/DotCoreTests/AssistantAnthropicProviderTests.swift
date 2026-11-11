import XCTest

@testable import DotCore

/// Anthropic's Messages shape: named events, cumulative usage, and tool blocks
/// whose arguments only parse at the end.
final class AssistantAnthropicProviderTests: XCTestCase {
    private func provider(
        _ server: StubServer,
        apiKey: String? = "sk-ant-test"
    ) throws -> AnthropicChatProvider {
        AnthropicChatProvider(
            baseURL: try AssistantTestSupport.loopbackURL(server, path: ""),
            apiKey: apiKey,
            session: AssistantTestSupport.session()
        )
    }

    private func sseResponse(_ events: [(name: String?, data: String)]) -> StubServer.Response {
        StubServer.Response(
            status: 200,
            body: AssistantTestSupport.namedSSE(events),
            contentType: "text/event-stream"
        )
    }

    func testStreamedTextAndUsageArriveInOrder() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                (name: "message_start", data: #"{"type":"message_start","message":{"usage":{"input_tokens":12}}}"#),
                (name: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
                (name: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#),
                (name: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}"#),
                (name: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
                (name: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#),
                (name: "message_stop", data: #"{"type":"message_stop"}"#),
            ])
        ])
        let events = try await AssistantTestSupport.events(
            try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
        )
        XCTAssertEqual(events, [
            .textDelta("Hello"),
            .textDelta(" there"),
            .usage(input: 12, output: 5),
            .done(.endTurn),
        ])
    }

    func testAToolUseBlockIsAssembledFromJSONFragments() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                (name: "message_start", data: #"{"type":"message_start","message":{"usage":{"input_tokens":9}}}"#),
                (name: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"remind"}}"#),
                (name: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"text\":\"send the "}}"#),
                (name: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"deck\"}"}}"#),
                (name: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
                (name: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#),
                (name: "message_stop", data: #"{"type":"message_stop"}"#),
            ])
        ])
        let events = try await AssistantTestSupport.events(
            try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
        )
        XCTAssertEqual(events.count, 3)
        guard case .toolCall(let call) = events[0] else {
            return XCTFail("expected a tool call, got \(events)")
        }
        XCTAssertEqual(call.id, "toolu_1")
        XCTAssertEqual(call.name, "remind")
        XCTAssertEqual(call.arguments, ["text": "send the deck"])
        XCTAssertEqual(events[1], .usage(input: 9, output: 7))
        XCTAssertEqual(events[2], .done(.toolCalls))
    }

    func testTwoToolBlocksStreamedTogetherStayApart() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                (name: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_a","name":"remind"}}"#),
                (name: "content_block_start", data: #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_b","name":"calendar"}}"#),
                (name: "content_block_delta", data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"day\":\"Fri\"}"}}"#),
                (name: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"text\":\"deck\"}"}}"#),
                (name: "content_block_stop", data: #"{"type":"content_block_stop","index":1}"#),
                (name: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
                (name: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#),
                (name: "message_stop", data: #"{"type":"message_stop"}"#),
            ])
        ])
        let events = try await AssistantTestSupport.events(
            try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
        )
        let calls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }
        XCTAssertEqual(calls.map(\.name), ["calendar", "remind"], "each block closes with its own arguments")
        XCTAssertEqual(calls.first?.arguments["day"], .string("Fri"))
        XCTAssertEqual(calls.last?.arguments["text"], .string("deck"))
    }

    func testTheRequestShapeAnthropicExpects() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                (name: "message_stop", data: #"{"type":"message_stop"}"#),
            ])
        ])
        let spec = ChatToolSpec(
            name: "remind",
            description: "Create a reminder.",
            parameters: ["type": "object", "properties": ["text": ["type": "string"]]],
            risk: .write
        )
        let call = ToolCall(id: "toolu_1", name: "remind", arguments: ["text": "deck"])
        let messages: [ChatMessage] = [
            .system("be brief"),
            .user("remind me Friday"),
            .assistant("", toolCalls: [call]),
            .result(ToolResult.success("toolu_1", "Reminder created.")),
            .result(ToolResult.failure("toolu_1", "Calendar refused.")),
        ]
        _ = try await AssistantTestSupport.events(
            try provider(server).stream(messages: messages, tools: [spec], model: "claude-test")
        )

        let received = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(received.path, "/v1/messages")
        XCTAssertEqual(received.header("x-api-key"), "sk-ant-test")
        XCTAssertEqual(received.header("anthropic-version"), AnthropicChatProvider.defaultVersion)

        let body = AssistantTestSupport.json(received.body)
        XCTAssertEqual(body["system"] as? String, "be brief")
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicProviderLimits.answer)
        XCTAssertEqual(body["stream"] as? Bool, true)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "remind")
        XCTAssertEqual((tools.first?["input_schema"] as? [String: Any])?["type"] as? String, "object")

        let payload = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(payload.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let assistantBlocks = try XCTUnwrap(payload[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.first?["type"] as? String, "tool_use")
        XCTAssertEqual(assistantBlocks.first?["id"] as? String, "toolu_1")
        let resultBlocks = try XCTUnwrap(payload[2]["content"] as? [[String: Any]])
        XCTAssertEqual(resultBlocks.count, 2, "two tool results share one user turn")
        XCTAssertEqual(resultBlocks.first?["type"] as? String, "tool_result")
        XCTAssertEqual(resultBlocks.first?["tool_use_id"] as? String, "toolu_1")
        XCTAssertTrue(
            (resultBlocks.last?["content"] as? String)?.hasPrefix("Tool error: ") == true,
            "a failed tool is marked for the model"
        )
    }

    func testPingAndUnknownEventsAreTolerated() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                (name: "ping", data: #"{"type":"ping"}"#),
                (name: "message_banana", data: #"{"type":"message_banana"}"#),
                (name: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
                (name: "message_stop", data: #"{"type":"message_stop"}"#),
            ])
        ])
        let events = try await AssistantTestSupport.events(
            try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
        )
        XCTAssertEqual(events, [.textDelta("Hi"), .done(.endTurn)])
    }

    func testAnErrorEventFailsTheRead() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                (name: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            ])
        ])
        do {
            _ = try await AssistantTestSupport.events(
                try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
            )
            XCTFail("an error event must fail the read")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .invalidResponse("Overloaded"))
        }
    }

    func testAStreamThatEndsWithoutMessageStopStillFinishes() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                (name: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#),
            ])
        ])
        let events = try await AssistantTestSupport.events(
            try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
        )
        XCTAssertEqual(events, [.textDelta("Hi"), .done(.endTurn)])
    }
}

/// The Anthropic answer limit the catalogue asks for.
private enum AnthropicProviderLimits {
    static let answer = AssistantProviderCatalogue.anthropicAnswerLimit
}
