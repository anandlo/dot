import Foundation

/// Anthropic's Messages API, with tool use and streaming.
///
/// The stream is the documented one: `message_start`, then per content block a
/// `content_block_start`, one or more `content_block_delta` and a
/// `content_block_stop`, then `message_delta` carrying cumulative usage, then
/// `message_stop`, with `ping` allowed anywhere. Tool arguments arrive as
/// `input_json_delta.partial_json` fragments that are only valid when joined,
/// so they are accumulated and parsed when their block closes.
///
/// The same shape is served by LM Studio's Anthropic-compatible endpoint and by
/// services that translate to it, which is why the base URL and path are
/// parameters.
public struct AnthropicChatProvider: ChatProvider {
    /// The endpoint the reference shape answers on.
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    /// The path a message is posted to.
    public static let defaultPath = "v1/messages"
    /// The dated version of the API this implementation is written against.
    public static let defaultVersion = "2023-06-01"

    public let baseURL: URL
    public let path: String
    public let apiKey: String?
    public let version: String
    public let extraHeaders: [String: String]
    /// The header this endpoint asks every request of one conversation to
    /// carry, when it asks for one. `nil` for an endpoint that never asked.
    public let sessionHeader: AssistantSessionHeader?
    /// The id every request of this provider sends in ``sessionHeader``.
    ///
    /// It is minted once, when the provider is built, and never written to the
    /// configuration or a log: it names one conversation on the service, not
    /// the person or the account. A new provider is a new conversation, so a
    /// rewrite — which builds one per request — starts its own.
    let sessionID: String?
    public let maxTokens: Int
    public let temperature: Double?
    /// Body members the catalogue names for this call, e.g. a vendor's
    /// reasoning choice. A member the request already writes is never replaced.
    public let extraBody: [String: JSONValue]
    public let timeout: TimeInterval
    public let limits: AssistantStreamLimits
    private let session: URLSession

    public init(
        baseURL: URL = AnthropicChatProvider.defaultBaseURL,
        path: String = AnthropicChatProvider.defaultPath,
        apiKey: String? = nil,
        version: String = AnthropicChatProvider.defaultVersion,
        extraHeaders: [String: String] = [:],
        sessionHeader: AssistantSessionHeader? = nil,
        maxTokens: Int = 1024,
        temperature: Double? = nil,
        extraBody: [String: JSONValue] = [:],
        timeout: TimeInterval = 120,
        limits: AssistantStreamLimits = .default,
        session: URLSession = AnthropicChatProvider.makeSession()
    ) {
        self.baseURL = baseURL
        self.path = path
        self.apiKey = apiKey
        self.version = version
        self.extraHeaders = extraHeaders
        self.sessionHeader = sessionHeader
        self.sessionID = sessionHeader == nil ? nil : AssistantSessionHeader.makeIdentifier()
        self.maxTokens = max(1, maxTokens)
        self.temperature = temperature
        self.extraBody = extraBody
        self.timeout = timeout
        self.limits = limits
        self.session = session
    }

    /// The session a message is sent with: ephemeral and cacheless, with a
    /// resource timeout long enough for a tool-calling turn.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }

    /// The address a message is posted to.
    public var messagesURL: URL {
        AssistantEndpoint.url(base: baseURL, path: path)
    }

    /// Builds the request a turn sends.
    public func makeRequest(
        messages: [ChatMessage],
        tools: [ChatToolSpec],
        model: String
    ) throws -> URLRequest {
        let url = messagesURL
        if let rejection = EndpointPolicy.validate(url) { throw rejection }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw ProviderError.unavailable("Choose a model in Settings.")
        }
        let converted = AnthropicMessages.convert(messages)
        let body = AnthropicRequestBody(
            model: trimmedModel,
            maxTokens: maxTokens,
            system: converted.system,
            messages: converted.messages,
            tools: tools.isEmpty ? nil : tools.map(AnthropicToolPayload.init),
            stream: true,
            temperature: temperature,
            extraBody: extraBody
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // One id for this provider's whole life, so every request of the
        // conversation carries it. An endpoint that did not name a header in
        // the catalogue has no `sessionID` and is sent none.
        if let sessionHeader, let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: sessionHeader.rawValue)
        }
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

/// Turns Dot's conversation into the shape Anthropic reads.
///
/// Two rules shape it. Anthropic takes the system prompt as a top-level string,
/// not as a message. And its turns must alternate: consecutive messages of one
/// role are merged, which is what puts several tool results in the single user
/// turn the docs ask for.
private enum AnthropicMessages {
    struct Converted {
        var system: String?
        var messages: [AnthropicMessagePayload]
    }

    static func convert(_ messages: [ChatMessage]) -> Converted {
        var systemParts: [String] = []
        var converted: [AnthropicMessagePayload] = []
        for message in messages {
            switch message.role {
            case .system:
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { systemParts.append(text) }
            case .user:
                append([.text(message.text)], role: "user", to: &converted)
            case .assistant:
                var blocks: [AnthropicContentBlock] = []
                if !message.text.isEmpty { blocks.append(.text(message.text)) }
                blocks.append(contentsOf: message.toolCalls.map { AnthropicContentBlock.toolUse($0) })
                append(blocks, role: "assistant", to: &converted)
            case .tool:
                guard let callID = message.toolCallID else { continue }
                append([.toolResult(callID: callID, text: message.text)], role: "user", to: &converted)
            }
        }
        return Converted(
            system: systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n"),
            messages: converted
        )
    }

    private static func append(
        _ blocks: [AnthropicContentBlock],
        role: String,
        to messages: inout [AnthropicMessagePayload]
    ) {
        guard !blocks.isEmpty else { return }
        if let last = messages.last, last.role == role {
            messages[messages.count - 1].content.append(contentsOf: blocks)
        } else {
            messages.append(AnthropicMessagePayload(role: role, content: blocks))
        }
    }
}

// MARK: - Wire shapes

private struct AnthropicRequestBody: Encodable {
    var model: String
    var maxTokens: Int
    var system: String?
    var messages: [AnthropicMessagePayload]
    var tools: [AnthropicToolPayload]?
    var stream: Bool
    var temperature: Double?
    /// Members the catalogue adds for one call, e.g. a reasoning choice.
    var extraBody: [String: JSONValue] = [:]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnthropicJSONKey.self)
        // The members this shape owns. A row may add to the body; it may not
        // replace a member the request already writes.
        var written: Set<String> = ["model", "messages", "stream", "max_tokens"]
        try container.encode(model, forKey: AnthropicJSONKey("model"))
        try container.encode(maxTokens, forKey: AnthropicJSONKey("max_tokens"))
        try container.encode(messages, forKey: AnthropicJSONKey("messages"))
        try container.encode(stream, forKey: AnthropicJSONKey("stream"))
        if let system {
            written.insert("system")
            try container.encode(system, forKey: AnthropicJSONKey("system"))
        }
        if let tools {
            written.insert("tools")
            try container.encode(tools, forKey: AnthropicJSONKey("tools"))
        }
        if let temperature {
            written.insert("temperature")
            try container.encode(temperature, forKey: AnthropicJSONKey("temperature"))
        }
        for (name, value) in extraBody where !written.contains(name) {
            try container.encode(value, forKey: AnthropicJSONKey(name))
        }
    }
}

/// A body member of the message request.
///
/// The members are named rather than listed in a `CodingKeys` enum because a
/// catalogue row adds one this file has never heard of, and one container can
/// only be keyed by one type.
private struct AnthropicJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) {
        stringValue = name
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

struct AnthropicMessagePayload: Encodable {
    var role: String
    var content: [AnthropicContentBlock]
}

struct AnthropicContentBlock: Encodable {
    var type: String
    var text: String?
    var id: String?
    var name: String?
    var input: JSONValue?
    var toolUseID: String?
    var content: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case toolUseID = "tool_use_id"
        case content
    }

    static func text(_ text: String) -> AnthropicContentBlock {
        AnthropicContentBlock(type: "text", text: text)
    }

    static func toolUse(_ call: ToolCall) -> AnthropicContentBlock {
        AnthropicContentBlock(type: "tool_use", id: call.id, name: call.name, input: call.arguments)
    }

    static func toolResult(callID: String, text: String) -> AnthropicContentBlock {
        AnthropicContentBlock(type: "tool_result", toolUseID: callID, content: text)
    }
}

private struct AnthropicToolPayload: Encodable {
    var name: String
    var description: String
    var inputSchema: JSONValue

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }

    init(_ spec: ChatToolSpec) {
        name = spec.name
        description = spec.description
        inputSchema = spec.parameters
    }
}

extension AnthropicChatProvider {
    /// Streams one answer.
    public func stream(
        messages: [ChatMessage],
        tools: [ChatToolSpec],
        model: String
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(messages: messages, tools: tools, model: model)
                    try await read(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads the streamed answer and yields its events.
    private func read(
        _ request: URLRequest,
        into continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        var state = AnthropicStreamState()
        var sawStop = false
        for try await event in HTTPTransport.eventStream(request, session: session, limits: limits) {
            let data = Data(event.data.utf8)
            guard let payload = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data) else {
                if AssistantWireError.indicatesError(data) {
                    throw ProviderError.invalidResponse(
                        AssistantWireError.message(in: data) ?? "the service reported an error"
                    )
                }
                continue
            }
            switch payload.type ?? event.name ?? "" {
            case "message_start":
                if let usage = payload.message?.usage {
                    state.inputTokens = usage.inputTokens ?? state.inputTokens
                }
            case "content_block_start":
                state.open(index: payload.index ?? 0, block: payload.contentBlock)
            case "content_block_delta":
                // A text delta carries `text`, a reasoning delta carries
                // `thinking` and an argument delta carries `partial_json`. Only
                // one of them is ever present.
                if payload.delta?.type == "thinking_delta",
                   let thinking = payload.delta?.thinking,
                   !thinking.isEmpty {
                    continuation.yield(.thinking)
                }
                if let text = payload.delta?.text, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                }
                if let partial = payload.delta?.partialJSON {
                    state.appendJSON(partial, at: payload.index ?? 0)
                }
            case "content_block_stop":
                if let call = state.close(index: payload.index ?? 0) {
                    continuation.yield(.toolCall(call))
                }
            case "message_delta":
                if let reason = payload.delta?.stopReason {
                    state.stopReason = ChatStopReason(wire: reason)
                }
                if let usage = payload.usage {
                    state.inputTokens = usage.inputTokens ?? state.inputTokens
                    state.outputTokens = usage.outputTokens ?? state.outputTokens
                    continuation.yield(.usage(input: state.inputTokens, output: state.outputTokens))
                }
            case "message_stop":
                state.emitOpenCalls(into: continuation)
                continuation.yield(.done(state.stopReason))
                sawStop = true
            case "error":
                throw ProviderError.invalidResponse(
                    payload.error?.message ?? "the service reported an error"
                )
            default:
                // `ping`, and any event type a newer revision adds. Anthropic
                // documents that they may appear, so a stream that carries one
                // is still a valid stream.
                continue
            }
            if sawStop { break }
        }
        if !sawStop {
            state.emitOpenCalls(into: continuation)
            continuation.yield(.done(state.stopReason))
        }
    }
}

private struct AnthropicStreamEvent: Decodable {
    struct Message: Decodable {
        var usage: Usage?
    }

    struct ContentBlockStart: Decodable {
        var type: String?
        var id: String?
        var name: String?
    }

    struct Delta: Decodable {
        var type: String?
        var text: String?
        /// The reasoning a `thinking_delta` carries. It is reported as activity
        /// and never as text.
        var thinking: String?
        var partialJSON: String?
        var stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case thinking
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    struct Usage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct WireError: Decodable {
        var type: String?
        var message: String?
    }

    var type: String?
    var index: Int?
    var message: Message?
    var contentBlock: ContentBlockStart?
    var delta: Delta?
    var usage: Usage?
    var error: WireError?

    enum CodingKeys: String, CodingKey {
        case type
        case index
        case message
        case contentBlock = "content_block"
        case delta
        case usage
        case error
    }
}

/// Reassembles the tool calls of one streamed turn.
///
/// A `tool_use` block opens with its name and id, then receives argument JSON in
/// fragments, and is only parseable at `content_block_stop`. The index is the
/// block's, so two tool blocks can be open at once and are still told apart.
private struct AnthropicStreamState {
    private struct OpenTool {
        var id: String
        var name: String
        var json: String
    }

    private var open: [Int: OpenTool] = [:]
    private var order: [Int] = []
    var inputTokens = 0
    var outputTokens = 0
    var stopReason: ChatStopReason = .endTurn

    mutating func open(index: Int, block: AnthropicStreamEvent.ContentBlockStart?) {
        guard let block, block.type == "tool_use", let name = block.name, !name.isEmpty else { return }
        if open[index] == nil {
            order.append(index)
        }
        open[index] = OpenTool(id: block.id ?? "tool_\(index)", name: name, json: "")
    }

    mutating func appendJSON(_ fragment: String, at index: Int) {
        guard var tool = open[index] else { return }
        tool.json += fragment
        open[index] = tool
    }

    mutating func close(index: Int) -> ToolCall? {
        guard let tool = open.removeValue(forKey: index) else { return nil }
        order.removeAll { $0 == index }
        return ToolCall(id: tool.id, name: tool.name, argumentsJSON: tool.json)
    }

    /// Yields a block that never received its stop event, then forgets it.
    mutating func emitOpenCalls(into continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
        for index in order {
            guard let tool = open[index] else { continue }
            continuation.yield(.toolCall(
                ToolCall(id: tool.id, name: tool.name, argumentsJSON: tool.json)
            ))
        }
        open.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}
