import XCTest

@testable import DotCore

/// OpenAI's Chat Completions shape: streaming text, streamed tool calls, and
/// the request the endpoint receives.
///
/// Every test runs against a real loopback server, the way the speech providers
/// are tested: there is no request interception in this repository, and the
/// bytes on the wire are the contract.
final class AssistantOpenAIProviderTests: XCTestCase {
    private func provider(_ server: StubServer, apiKey: String? = "sk-test-key") throws -> OpenAIChatProvider {
        OpenAIChatProvider(
            baseURL: try AssistantTestSupport.loopbackURL(server),
            apiKey: apiKey,
            session: AssistantTestSupport.session()
        )
    }

    private func sseResponse(_ payloads: [String]) -> StubServer.Response {
        StubServer.Response(
            status: 200,
            body: AssistantTestSupport.sse(payloads),
            contentType: "text/event-stream"
        )
    }

    func testStreamedTextArrivesAsDeltas() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                #"{"choices":[{"delta":{"role":"assistant"}}]}"#,
                #"{"choices":[{"delta":{"content":"Hello"}}]}"#,
                #"{"choices":[{"delta":{"content":" there"}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
                "[DONE]",
            ])
        ])
        let events = try await AssistantTestSupport.events(
            try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
        )
        XCTAssertEqual(events, [
            .textDelta("Hello"),
            .textDelta(" there"),
            .done(.endTurn),
        ])
    }

    func testTheRequestCarriesTheModelMessagesAndTools() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                #"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
                "[DONE]",
            ])
        ])
        let spec = ChatToolSpec(
            name: "remind",
            description: "Create a reminder.",
            parameters: [
                "type": "object",
                "properties": ["text": ["type": "string"]],
                "required": ["text"],
            ],
            risk: .write
        )
        let history: [ChatMessage] = [
            .user("remind me Friday"),
            .assistant("", toolCalls: [ToolCall(id: "call_1", name: "remind", arguments: ["text": "send the deck"])]),
            .result(ToolResult.success("call_1", "Reminder created.")),
        ]
        _ = try await AssistantTestSupport.events(
            try provider(server).stream(
                messages: history + [.user("thanks")],
                tools: [spec],
                model: "test-model"
            )
        )

        let received = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(received.method, "POST")
        XCTAssertEqual(received.path, "/v1/chat/completions")
        XCTAssertEqual(received.header("Authorization"), "Bearer sk-test-key")
        XCTAssertEqual(received.header("Accept"), "text/event-stream")

        let body = AssistantTestSupport.json(received.body)
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["stream"] as? Bool, true)

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "remind")
        XCTAssertEqual(function["description"] as? String, "Create a reminder.")
        XCTAssertEqual((function["parameters"] as? [String: Any])?["type"] as? String, "object")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, [
            "user", "assistant", "tool", "user",
        ])
        let assistant = messages[1]
        XCTAssertNil(assistant["content"], "an assistant turn that only asks for a tool has no text")
        let call = try XCTUnwrap((assistant["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual(call["id"] as? String, "call_1")
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, #"{"text":"send the deck"}"#)
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(messages[2]["content"] as? String, "Reminder created.")
    }

    func testAToolCallSplitAcrossChunksIsReassembled() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"remind","arguments":"{\"text\":\"send the "}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"deck\"}"}}]}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
                "[DONE]",
            ])
        ])
        let events = try await AssistantTestSupport.events(
            try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
        )
        XCTAssertEqual(events.count, 2)
        guard case .toolCall(let call) = events[0] else {
            return XCTFail("expected a tool call, got \(events)")
        }
        XCTAssertEqual(call.id, "call_a")
        XCTAssertEqual(call.name, "remind")
        XCTAssertEqual(call.arguments, ["text": "send the deck"])
        XCTAssertEqual(events[1], .done(.toolCalls))
    }

    func testTwoToolCallsAreKeptApartByIndex() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"calendar","arguments":"{\"day\":"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"remind","arguments":"{\"text\":"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\"Friday\"}"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"deck\"}"}}]}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
                "[DONE]",
            ])
        ])
        let events = try await AssistantTestSupport.events(
            try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
        )
        let calls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let call) = event { return call }
            return nil
        }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.name, "remind", "calls come back in index order, not arrival order")
        XCTAssertEqual(calls.first?.arguments["text"], .string("deck"))
        XCTAssertEqual(calls.last?.name, "calendar")
        XCTAssertEqual(calls.last?.arguments["day"], .string("Friday"))
    }

    func testAnErrorInsideTheStreamFailsTheRead() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                #"{"choices":[{"delta":{"content":"Hel"}}]}"#,
                #"{"error":{"message":"overloaded","type":"overloaded_error"}}"#,
            ])
        ])
        do {
            _ = try await AssistantTestSupport.events(
                try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
            )
            XCTFail("an error event must fail the read")
        } catch let error as ProviderError {
            guard case .invalidResponse(let message) = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
            XCTAssertTrue(message.contains("overloaded"))
        }
    }

    func testAnHTTPErrorCarriesItsStatusAndMessage() async throws {
        let server = try StubServer(responses: [
            StubServer.Response(status: 429, json: #"{"error":{"message":"slow down"}}"#)
        ])
        do {
            _ = try await AssistantTestSupport.events(
                try provider(server).stream(messages: [.user("hi")], tools: [], model: "test-model")
            )
            XCTFail("a failed status must fail the read")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .rejected(status: 429, message: "slow down"))
        }
    }

    func testAzureSendsItsKeyInTheAPIKeyHeader() async throws {
        let server = try StubServer(responses: [
            sseResponse([
                #"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
                "[DONE]",
            ])
        ])
        let provider = OpenAIChatProvider(
            baseURL: try AssistantTestSupport.loopbackURL(server),
            apiKey: "azure-key",
            authStyle: .apiKey,
            session: AssistantTestSupport.session()
        )
        _ = try await AssistantTestSupport.events(
            provider.stream(messages: [.user("hi")], tools: [], model: "deployment")
        )
        let received = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(received.header("api-key"), "azure-key")
        XCTAssertNil(received.header("Authorization"))
    }

    func testACleartextRemoteAddressIsRefusedBeforeTheRequest() async throws {
        let provider = OpenAIChatProvider(
            baseURL: URL(string: "http://example.com/v1")!,
            apiKey: "key",
            session: AssistantTestSupport.session()
        )
        do {
            _ = try await AssistantTestSupport.events(
                provider.stream(messages: [.user("hi")], tools: [], model: "test-model")
            )
            XCTFail("a clear text remote address must be refused")
        } catch let rejection as EndpointPolicy.Rejection {
            guard case .cleartextHost(let host) = rejection else {
                return XCTFail("expected cleartextHost, got \(rejection)")
            }
            XCTAssertEqual(host, "example.com")
        }
    }

    func testAnEmptyModelFailsBeforeTheRequest() async throws {
        let provider = OpenAIChatProvider(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "key",
            session: AssistantTestSupport.session()
        )
        do {
            _ = try await AssistantTestSupport.events(
                provider.stream(messages: [.user("hi")], tools: [], model: "  ")
            )
            XCTFail("an empty model must be refused")
        } catch let error as ProviderError {
            guard case .unavailable = error else {
                return XCTFail("expected unavailable, got \(error)")
            }
        }
    }

    func testCancellingTheConsumerCancelsTheRequest() async throws {
        let stub = try AssistantStreamStub(
            firstEvent: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"# + "\n\n",
            holdSeconds: 30
        )
        let provider = OpenAIChatProvider(
            baseURL: try EndpointPolicy.url(from: "http://127.0.0.1:\(stub.port)/v1"),
            apiKey: "key",
            session: AssistantTestSupport.session()
        )
        let sawText = expectation(description: "the first token arrived")
        let consuming = Task {
            for try await event in provider.stream(messages: [.user("hi")], tools: [], model: "m") {
                if event == .textDelta("Hi") {
                    sawText.fulfill()
                }
            }
        }
        await fulfillment(of: [sawText], timeout: 5)

        consuming.cancel()
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await consuming.result
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(ended, "a cancelled stream must stop reading the connection")
    }
}
