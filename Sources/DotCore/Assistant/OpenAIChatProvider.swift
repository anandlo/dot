import Foundation

/// Any service that speaks OpenAI's Chat Completions shape.
///
/// One implementation covers the hosted OpenAI API, Groq, OpenRouter, xAI,
/// DeepSeek, Mistral, Gemini's compatibility endpoint, Ollama, LM Studio and
/// Azure OpenAI. The differences between them are a base URL, a header and a
/// path, so they are configuration here rather than a type each.
///
/// The wire shapes are the documented ones: `stream: true` returns
/// `chat.completion.chunk` objects over SSE, a tool call arrives as
/// `choices[0].delta.tool_calls[]` with an `index` and an incremental
/// `function.arguments` string, and the stream ends with `data: [DONE]`.
public struct OpenAIChatProvider: ChatProvider {
    /// The endpoint the reference shape answers on.
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    /// The path a chat completion is posted to.
    public static let defaultPath = "chat/completions"

    public let baseURL: URL
    public let path: String
    public let queryItems: [URLQueryItem]
    public let apiKey: String?
    public let authStyle: AuthStyle
    /// Headers the endpoint needs that are not the key, e.g. OpenRouter's
    /// attribution headers. A secret never belongs here; use `apiKey`.
    public let extraHeaders: [String: String]
    public let temperature: Double?
    /// Whether to ask for a usage chunk. OpenAI sends one when asked;
    /// endpoints that do not know the field may reject it, so it is off unless
    /// the catalogue turns it on for a vendor that documents it.
    public let includeUsage: Bool
    /// Body members the catalogue names for this call, e.g. a vendor's
    /// reasoning switch. A member the request already writes is never replaced.
    public let extraBody: [String: JSONValue]
    public let timeout: TimeInterval
    public let limits: AssistantStreamLimits
    private let session: URLSession

    public init(
        baseURL: URL = OpenAIChatProvider.defaultBaseURL,
        path: String = OpenAIChatProvider.defaultPath,
        queryItems: [URLQueryItem] = [],
        apiKey: String? = nil,
        authStyle: AuthStyle = .bearer,
        extraHeaders: [String: String] = [:],
        temperature: Double? = nil,
        includeUsage: Bool = false,
        extraBody: [String: JSONValue] = [:],
        timeout: TimeInterval = 120,
        limits: AssistantStreamLimits = .default,
        session: URLSession = OpenAIChatProvider.makeSession()
    ) {
        self.baseURL = baseURL
        self.path = path
        self.queryItems = queryItems
        self.apiKey = apiKey
        self.authStyle = authStyle
        self.extraHeaders = extraHeaders
        self.temperature = temperature
        self.includeUsage = includeUsage
        self.extraBody = extraBody
        self.timeout = timeout
        self.limits = limits
        self.session = session
    }

    /// The session a chat request is sent with.
    ///
    /// Ephemeral and cacheless like the speech providers, with a longer
    /// resource timeout: a tool-calling turn is several round trips and a long
    /// answer is one open stream.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }

    /// The address a completion is posted to.
    public var chatURL: URL {
        let base = baseURL.appendingPathComponent(path)
        guard !queryItems.isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return base }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? base
    }

    /// Builds the request a turn sends.
    ///
    /// The address is checked again here, not only where it was stored: a
    /// request that carries a conversation must not be posted in clear text to
    /// a host that is not this Mac, whatever wrote the string.
    public func makeRequest(
        messages: [ChatMessage],
        tools: [ChatToolSpec],
        model: String
    ) throws -> URLRequest {
        let url = chatURL
        if let rejection = EndpointPolicy.validate(url) { throw rejection }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw ProviderError.unavailable("No model is selected for this chat service.")
        }
        let body = OpenAIRequestBody(
            model: trimmedModel,
            messages: messages.map(OpenAIMessagePayload.init),
            tools: tools.isEmpty ? nil : tools.map(OpenAIToolPayload.init),
            stream: true,
            temperature: temperature,
            streamOptions: includeUsage ? OpenAIStreamOptions(includeUsage: true) : nil,
            extraBody: extraBody
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(authStyle.value(for: apiKey), forHTTPHeaderField: authStyle.header)
        }
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

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
        var state = OpenAIStreamState()
        var sawDone = false
        for try await event in HTTPTransport.eventStream(request, session: session, limits: limits) {
            if event.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                emit(state.takeCalls(), into: continuation)
                continuation.yield(.done(state.stopReason))
                sawDone = true
                break
            }
            let data = Data(event.data.utf8)
            guard let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
                  chunk.choices != nil || chunk.usage != nil
            else {
                // An event this build does not understand. The providers say
                // new event types may appear, so it is skipped; an error object
                // is the one exception, because it means the answer will not
                // arrive.
                if AssistantWireError.indicatesError(data) {
                    throw ProviderError.invalidResponse(
                        AssistantWireError.message(in: data) ?? "the service reported an error"
                    )
                }
                continue
            }
            if let usage = chunk.usage, usage.promptTokens != nil || usage.completionTokens != nil {
                continuation.yield(.usage(
                    input: usage.promptTokens ?? 0,
                    output: usage.completionTokens ?? 0
                ))
            }
            for choice in chunk.choices ?? [] {
                if let delta = choice.delta, let text = delta.content, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                }
                for fragment in choice.delta?.toolCalls ?? [] {
                    state.add(fragment)
                }
                if let reason = choice.finishReason {
                    state.stopReason = ChatStopReason(wire: reason)
                    // The documented shape puts every argument fragment before
                    // the finish reason, so the calls are complete here.
                    emit(state.takeCalls(), into: continuation)
                }
            }
        }
        if !sawDone {
            emit(state.takeCalls(), into: continuation)
            continuation.yield(.done(state.stopReason))
        }
    }

    private func emit(
        _ calls: [ToolCall],
        into continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) {
        for call in calls {
            continuation.yield(.toolCall(call))
        }
    }
}

// MARK: - Wire shapes

private struct OpenAIRequestBody: Encodable {
    var model: String
    var messages: [OpenAIMessagePayload]
    var tools: [OpenAIToolPayload]?
    var stream: Bool
    var temperature: Double?
    var streamOptions: OpenAIStreamOptions?
    /// Members the catalogue adds for one call, e.g. a reasoning switch.
    var extraBody: [String: JSONValue] = [:]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: OpenAIJSONKey.self)
        // The members this shape owns. A row may add to the body; it may not
        // replace a member the request already writes.
        var written: Set<String> = ["model", "messages", "stream"]
        try container.encode(model, forKey: OpenAIJSONKey("model"))
        try container.encode(messages, forKey: OpenAIJSONKey("messages"))
        if let tools {
            written.insert("tools")
            try container.encode(tools, forKey: OpenAIJSONKey("tools"))
        }
        try container.encode(stream, forKey: OpenAIJSONKey("stream"))
        if let temperature {
            written.insert("temperature")
            try container.encode(temperature, forKey: OpenAIJSONKey("temperature"))
        }
        if let streamOptions {
            written.insert("stream_options")
            try container.encode(streamOptions, forKey: OpenAIJSONKey("stream_options"))
        }
        for (name, value) in extraBody where !written.contains(name) {
            try container.encode(value, forKey: OpenAIJSONKey(name))
        }
    }
}

/// A body member of the chat completion request.
///
/// The members are named rather than listed in a `CodingKeys` enum because a
/// catalogue row adds one this file has never heard of, and one container can
/// only be keyed by one type.
private struct OpenAIJSONKey: CodingKey {
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

private struct OpenAIStreamOptions: Encodable {
    var includeUsage: Bool

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

private struct OpenAIMessagePayload: Encodable {
    var role: String
    var content: String?
    var toolCalls: [OpenAIToolCallPayload]?
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    init(_ message: ChatMessage) {
        role = message.role.rawValue
        // An assistant turn that only asked for tools has no text; sending an
        // empty string there is not the documented shape.
        content = message.text.isEmpty && !message.toolCalls.isEmpty ? nil : message.text
        toolCalls = message.toolCalls.isEmpty ? nil : message.toolCalls.map(OpenAIToolCallPayload.init)
        toolCallID = message.toolCallID
    }
}

private struct OpenAIToolCallPayload: Encodable {
    var id: String
    var type = "function"
    var function: OpenAIFunctionCallPayload

    init(_ call: ToolCall) {
        id = call.id
        function = OpenAIFunctionCallPayload(name: call.name, arguments: call.argumentsJSON)
    }
}

private struct OpenAIFunctionCallPayload: Encodable {
    var name: String
    var arguments: String
}

private struct OpenAIToolPayload: Encodable {
    var type = "function"
    var function: OpenAIToolFunctionPayload

    init(_ spec: ChatToolSpec) {
        function = OpenAIToolFunctionPayload(
            name: spec.name,
            description: spec.description,
            parameters: spec.parameters
        )
    }
}

private struct OpenAIToolFunctionPayload: Encodable {
    var name: String
    var description: String
    var parameters: JSONValue
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCallFragment: Decodable {
                struct Function: Decodable {
                    var name: String?
                    var arguments: String?
                }

                var index: Int?
                var id: String?
                var function: Function?
            }

            var content: String?
            var toolCalls: [ToolCallFragment]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }

        var delta: Delta?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        var promptTokens: Int?
        var completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    var choices: [Choice]?
    var usage: Usage?
}

/// Reassembles streamed tool calls.
///
/// The fragments arrive as a positional array: `index` names the call, `name`
/// arrives once (and may be split), and `arguments` is a JSON string that
/// arrives in pieces that are only valid when concatenated in order. The
/// assembled calls are handed back in index order so a provider that reorders
/// its chunks cannot reorder the results.
private struct OpenAIStreamState {
    private struct Partial {
        var id: String?
        var name: String
        var arguments: String
    }

    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []
    var stopReason: ChatStopReason = .endTurn

    mutating func add(_ fragment: OpenAIStreamChunk.Choice.Delta.ToolCallFragment) {
        let index = fragment.index ?? order.last ?? 0
        var partial = partials[index] ?? Partial(id: nil, name: "", arguments: "")
        if let id = fragment.id, !id.isEmpty, partial.id == nil {
            partial.id = id
        }
        if let name = fragment.function?.name, !name.isEmpty {
            partial.name += name
        }
        if let arguments = fragment.function?.arguments {
            partial.arguments += arguments
        }
        if partials[index] == nil {
            order.append(index)
        }
        partials[index] = partial
    }

    /// The completed calls, and a reset so a second call cannot repeat them.
    ///
    /// The fragments arrive in whatever order the service emits them, and the
    /// index is the only thing that says which call a fragment belongs to. The
    /// answer is sorted by index so the conversation the model reads lists its
    /// calls in the order it wrote them.
    mutating func takeCalls() -> [ToolCall] {
        let calls = order.sorted().compactMap { index -> ToolCall? in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            return ToolCall(
                id: partial.id ?? "call_\(index)",
                name: partial.name,
                argumentsJSON: partial.arguments
            )
        }
        partials.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        return calls
    }
}
