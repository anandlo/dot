import Foundation

/// A JSON value as the assistant sends and receives it.
///
/// Tool schemas and tool arguments are both JSON, and the two places they
/// appear (a request body and a streamed argument fragment) have to agree on
/// what a value is. A concrete enum keeps that agreement checkable and keeps
/// `Any` out of every type that crosses a concurrency boundary.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The value of an object member, or `nil` when this is not an object or
    /// the key is absent.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    /// The string this value carries, when it carries one.
    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// The object this value carries, when it carries one.
    public var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    /// Whether this is an object with no members.
    public var isEmptyObject: Bool {
        objectValue?.isEmpty == true
    }

    /// The compact JSON text of the value, with its keys in a fixed order so a
    /// test can compare two encodings.
    public var compactJSON: String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The Foundation object this value maps to.
    var jsonObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let flag): flag
        case .number(let number): number
        case .string(let text): text
        case .array(let items): items.map(\.jsonObject)
        case .object(let members): members.mapValues(\.jsonObject)
        }
    }

    /// Reads JSON text, treating empty input as an empty object.
    ///
    /// Models send `{}`, `""` or nothing at all for a tool with no arguments,
    /// and a streamed argument string arrives empty for the same reason. An
    /// empty string is therefore the empty object, not a parse failure.
    ///
    /// - Parameter text: the JSON text, when there is any.
    /// - Returns: the value, or `nil` when the text is not JSON.
    public static func parse(_ text: String?) -> JSONValue? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .object([:]) }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              )
        else { return nil }
        return JSONValue(any: parsed)
    }

    /// Wraps a Foundation object, as produced by `JSONSerialization`.
    init(any value: Any) {
        switch value {
        case let members as [String: Any]:
            self = .object(members.mapValues(JSONValue.init(any:)))
        case let items as [Any]:
            self = .array(items.map(JSONValue.init(any:)))
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case is NSNull:
            self = .null
        default:
            self = .null
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([JSONValue].self) {
            self = .array(items)
        } else if let members = try? container.decode([String: JSONValue].self) {
            self = .object(members)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .number(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items)
        case .object(let members): try container.encode(members)
        }
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

/// Who wrote a message.
public enum ChatRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
    /// The result of a tool the assistant asked for.
    case tool
}

/// One turn of a conversation.
///
/// A tool call is carried twice on purpose: the assistant's turn stores the
/// calls it made, and the tool's turn stores the call it answers through
/// ``toolCallID``. That is the shape every provider's wire format needs, so no
/// adapter has to reconstruct it.
public struct ChatMessage: Sendable, Equatable, Codable {
    public var role: ChatRole
    public var text: String
    public var toolCalls: [ToolCall]
    public var toolCallID: String?

    public init(
        role: ChatRole,
        text: String = "",
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, text: text)
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text)
    }

    public static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, toolCalls: toolCalls)
    }

    /// The answer to one tool call, as the model reads it.
    ///
    /// A failed result is marked in its text because neither provider gives a
    /// tool message a failure flag that every compatible endpoint carries. A
    /// model that reads "Tool error: ..." can try another way, which is the
    /// point of reporting the failure at all.
    public static func result(_ result: ToolResult) -> ChatMessage {
        let content = result.isError ? "Tool error: " + result.content : result.content
        return ChatMessage(role: .tool, text: content, toolCallID: result.callID)
    }
}

/// What a tool is allowed to do, ordered from harmless to irreversible.
///
/// The toolbox decides whether a call needs a person's confirmation; the
/// session and the surfaces show the risk without having to know the tool. The
/// order is the scale: a step that runs a ``destructive`` tool is the one a
/// surface must be able to stop.
public enum ToolRisk: String, Codable, Sendable, CaseIterable, Comparable {
    case read
    case write
    case destructive
    /// Talks to something outside this Mac, so the result is not local data.
    case external

    /// The scale a set of calls is judged by: the worst risk in it.
    ///
    /// `external` ranks above `read` because it leaves this Mac, and below
    /// `write` because it does not change anything the person owns.
    public var order: Int {
        switch self {
        case .read: 0
        case .external: 1
        case .write: 2
        case .destructive: 3
        }
    }

    public static func < (lhs: ToolRisk, rhs: ToolRisk) -> Bool {
        lhs.order < rhs.order
    }

    /// Whether a call at this risk can change something outside Dot.
    public var changesState: Bool {
        self == .write || self == .destructive
    }
}

/// One tool the model may call.
public struct ChatToolSpec: Sendable, Equatable {
    /// The longest name both providers accept.
    public static let maximumNameLength = 128

    public var name: String
    public var description: String
    public var parameters: JSONValue
    public var risk: ToolRisk

    public init(name: String, description: String, parameters: JSONValue, risk: ToolRisk) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.risk = risk
    }

    /// Whether the name is one both providers accept: `[A-Za-z0-9_-]`, 1 to
    /// 128 characters. Anthropic documents the rule and OpenAI rejects a
    /// malformed name, so the toolbox is checked before a turn starts.
    public var hasValidName: Bool {
        guard (1...Self.maximumNameLength).contains(name.count) else { return false }
        return name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
    }
}

/// A call the model asked for.
public struct ToolCall: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// A call whose arguments arrived as JSON text.
    ///
    /// A model that streams its arguments sends fragments to be joined; a model
    /// that sends them whole sometimes sends an empty string instead of `{}`.
    /// Both become a value here, and text that is not JSON becomes an empty
    /// object so a malformed argument cannot stop the turn: the tool reports
    /// the missing field instead.
    public init(id: String, name: String, argumentsJSON: String?) {
        self.init(id: id, name: name, arguments: JSONValue.parse(argumentsJSON) ?? .object([:]))
    }

    /// The arguments as the JSON text a provider sends back.
    public var argumentsJSON: String { arguments.compactJSON }
}

/// What a tool answered.
public struct ToolResult: Sendable, Equatable, Codable {
    public var callID: String
    public var content: String
    public var isError: Bool

    public init(callID: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.content = content
        self.isError = isError
    }

    /// A successful answer.
    public static func success(_ callID: String, _ content: String) -> ToolResult {
        ToolResult(callID: callID, content: content)
    }

    /// A tool that could not do what it was asked.
    public static func failure(_ callID: String, _ content: String) -> ToolResult {
        ToolResult(callID: callID, content: content, isError: true)
    }
}

/// Why the model stopped.
public enum ChatStopReason: Sendable, Equatable {
    /// The model finished its answer.
    case endTurn
    /// The model wants tools run before it continues.
    case toolCalls
    /// The answer hit the token ceiling, so it is cut off.
    case length
    /// The service suppressed the answer.
    case contentFilter
    /// A reason this build does not know. Kept verbatim so the log can say it.
    case other(String)

    /// Reads a wire value, mapping the names the providers document.
    public init(wire: String?) {
        switch wire?.lowercased() {
        case "stop", "end_turn", "stop_sequence", "message_stop": self = .endTurn
        case "tool_calls", "tool_use", "function_call": self = .toolCalls
        case "length", "max_tokens": self = .length
        case "content_filter", "refusal": self = .contentFilter
        case let other?: self = .other(other)
        case nil: self = .endTurn
        }
    }
}

/// One thing that happened while a model was answering.
///
/// A provider yields these in wire order and yields exactly one ``done(_:)``
/// last. Anything after it is a bug in the provider, and a consumer may stop
/// reading after it.
public enum ChatEvent: Sendable, Equatable {
    /// A piece of the answer, as it was produced.
    case textDelta(String)
    /// A complete tool call. Providers that stream arguments accumulate their
    /// fragments before yielding this, so a consumer never sees a partial call.
    case toolCall(ToolCall)
    /// Token counts, when the service reports them.
    case usage(input: Int, output: Int)
    /// The end of the answer, with the reason the model stopped.
    case done(ChatStopReason)
}

/// A service that can hold a conversation and call tools.
///
/// This is a second capability beside ``Provider``, not a wider one: a speech
/// provider takes audio and returns text, and a chat provider takes messages
/// and returns a stream of events. Nothing about one is meaningful for the
/// other.
///
/// The stream must cancel the underlying request when the consuming task is
/// cancelled, must never yield a partial tool call, and must yield ``ChatEvent/done(_:)``
/// exactly once unless it throws.
public protocol ChatProvider: Sendable {
    /// Streams one answer.
    ///
    /// - Parameters:
    ///   - messages: the conversation so far, oldest first, including tool
    ///     results as ``ChatRole/tool`` turns.
    ///   - tools: the tools the model may call. Empty means the model answers
    ///     without tools and must not ask for one.
    ///   - model: the model id to ask for.
    func stream(
        messages: [ChatMessage],
        tools: [ChatToolSpec],
        model: String
    ) -> AsyncThrowingStream<ChatEvent, Error>
}

/// The tools one session may call.
///
/// The session executes calls in parallel and knows nothing about what they do.
/// A toolbox owns the confirmation a risky call needs, so the session has no
/// branch for it: a call either returns a result or reports an error.
public protocol AssistantToolbox: Sendable {
    /// The tools to offer the model this turn.
    func specs() async -> [ChatToolSpec]

    /// Runs one call.
    ///
    /// A tool that fails answers with ``ToolResult/isError`` rather than
    /// throwing: the model can read the failure and try another way, and a
    /// thrown error would end the turn.
    ///
    /// - Parameter call: the call the model asked for.
    func invoke(_ call: ToolCall) async -> ToolResult
}
