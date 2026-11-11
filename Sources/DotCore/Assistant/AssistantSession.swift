import Foundation

/// What one assistant turn produced.
public struct AssistantSessionResult: Sendable, Equatable {
    /// The answer text, from every model turn that carried any.
    public var text: String
    /// Why the turn ended.
    public var stopReason: AssistantStopReason
    /// The conversation including this turn, ready to be sent again.
    public var messages: [ChatMessage]
    /// How many tools ran.
    public var toolRuns: Int

    public init(text: String, stopReason: AssistantStopReason, messages: [ChatMessage], toolRuns: Int) {
        self.text = text
        self.stopReason = stopReason
        self.messages = messages
        self.toolRuns = toolRuns
    }
}

/// Why a turn ended.
public enum AssistantStopReason: Sendable, Equatable {
    /// The model answered without asking for another tool.
    case endTurn
    /// The step cap was reached with the model still asking for tools.
    case stepLimit
    /// The wall-clock cap was reached.
    case deadline
    /// The person stopped it.
    case cancelled
}

/// What a session reports while it works.
///
/// The session never asks for a confirmation and never renders anything: a
/// toolbox owns the confirmation a risky call needs, and a surface owns the
/// card. This stream is the whole vocabulary between them.
public enum AssistantSessionEvent: Sendable, Equatable {
    /// A model turn started, so the card can show that something is happening
    /// before the first token arrives.
    case thinking
    /// A piece of the answer, as the model produced it.
    case textDelta(String)
    /// One tool started. The arguments are never part of the event: they can
    /// carry calendar text, message bodies or file paths.
    case toolStarted(name: String)
    /// One tool finished.
    case toolFinished(name: String, ok: Bool)
    /// Token counts from one model turn, when the service reports them.
    case usage(input: Int, output: Int)
    /// The turn is over. This is always the last event.
    case finished(AssistantSessionResult)
    /// The turn could not finish. This is always the last event.
    case failed(String)
}

/// The bounds one turn runs inside.
public struct AssistantSessionConfiguration: Sendable, Equatable {
    /// How many model turns one request may take.
    public var maximumSteps: Int
    /// How many tool calls may run at once. Voice has little to gain from more
    /// than a few, and three destructive calls at once are three things to
    /// explain.
    public var maximumParallelTools: Int
    /// How long the whole turn may take.
    public var wallClock: Duration
    /// How long one model turn may take, streamed or not.
    public var stepTimeout: Duration
    /// How long to wait before each retry. The count of entries is the retry
    /// budget, and a retry only happens before the first token.
    public var retryDelays: [Duration]
    /// The prompt every turn starts with.
    public var systemPrompt: String

    public init(
        maximumSteps: Int = 6,
        maximumParallelTools: Int = 2,
        wallClock: Duration = .seconds(45),
        stepTimeout: Duration = .seconds(30),
        retryDelays: [Duration] = [.milliseconds(400), .milliseconds(1200)],
        systemPrompt: String = AssistantSessionConfiguration.voiceSystemPrompt
    ) {
        self.maximumSteps = max(1, maximumSteps)
        self.maximumParallelTools = max(1, maximumParallelTools)
        self.wallClock = wallClock
        self.stepTimeout = stepTimeout
        self.retryDelays = retryDelays
        self.systemPrompt = systemPrompt
    }

    /// The prompt a voice assistant needs.
    ///
    /// Short on purpose: every sentence here is paid for on every turn, and a
    /// long prompt makes a fast model slow. It says the four things that change
    /// an answer's shape for speech: short, act, one question, never invent.
    public static let voiceSystemPrompt = """
        You are Dot, a voice assistant on a Mac. The person spoke to you, and \
        your answer will be read aloud or pasted at their cursor.
        Answer in one or two short sentences unless more was asked for. No \
        lists, no markdown, no emoji.
        When a request needs an action, call the tool instead of describing it. \
        Never claim a result a tool did not return; if a tool fails, say so in \
        one sentence.
        If a required detail is missing, ask one short question and stop.
        Write numbers, dates and names so they read naturally aloud, and answer \
        in the language the person used.
        """

    /// The defaults a turn runs with.
    public static let `default` = AssistantSessionConfiguration()
}

/// Runs one request: model, tools, model again, until it answers or a bound
/// stops it.
///
/// A session is created per turn and holds nothing between turns beyond the
/// provider the caller built. It never retains the answer, the conversation or
/// the tools: the ``AssistantSessionResult`` and the caller's own history are
/// the state.
///
/// The turn is bounded from both ends. ``AssistantSessionConfiguration/maximumSteps``
/// caps how many times the model may ask for tools, and
/// ``AssistantSessionConfiguration/wallClock`` caps the whole turn, including a
/// provider that accepts the connection and then stops talking. Cancelling the
/// consuming task cancels the request and the tools.
public struct AssistantSession: Sendable {
    private let provider: any ChatProvider
    private let toolbox: any AssistantToolbox
    private let model: String
    private let configuration: AssistantSessionConfiguration

    public init(
        provider: any ChatProvider,
        model: String,
        toolbox: any AssistantToolbox,
        configuration: AssistantSessionConfiguration = .default
    ) {
        self.provider = provider
        self.model = model
        self.toolbox = toolbox
        self.configuration = configuration
    }

    /// Runs one request.
    ///
    /// - Parameters:
    ///   - prompt: what the person asked, after transcription.
    ///   - history: earlier turns of this conversation. A system message in it
    ///     is ignored: the session owns the system prompt.
    /// - Returns: the events of the turn, ending in ``AssistantSessionEvent/finished(_:)``
    ///   or ``AssistantSessionEvent/failed(_:)``.
    public func run(
        prompt: String,
        history: [ChatMessage] = []
    ) -> AsyncStream<AssistantSessionEvent> {
        AsyncStream { continuation in
            let task = Task {
                let last = await drive(prompt: prompt, history: history, continuation: continuation)
                continuation.yield(last)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The loop: a model turn, then the tools it asked for, then another model
    /// turn, until a bound or an answer ends it.
    private func drive(
        prompt: String,
        history: [ChatMessage],
        continuation: AsyncStream<AssistantSessionEvent>.Continuation
    ) async -> AssistantSessionEvent {
        var messages: [ChatMessage] = []
        let system = configuration.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { messages.append(.system(system)) }
        messages.append(contentsOf: history.filter { $0.role != .system })
        messages.append(.user(prompt))

        // A name a provider would reject is dropped here, before the request,
        // so one badly named tool cannot fail the whole turn.
        let specs = await toolbox.specs().filter { $0.hasValidName }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.wallClock)
        var answer = ""
        var toolRuns = 0
        var steps = 0

        func finish(_ reason: AssistantStopReason) -> AssistantSessionEvent {
            .finished(AssistantSessionResult(
                text: answer,
                stopReason: reason,
                messages: messages,
                toolRuns: toolRuns
            ))
        }

        while steps < configuration.maximumSteps {
            if Task.isCancelled { return finish(.cancelled) }
            if clock.now >= deadline { return finish(.deadline) }
            steps += 1
            continuation.yield(.thinking)
            let outcome = await modelTurn(
                messages: messages,
                tools: specs,
                deadline: deadline,
                continuation: continuation
            )
            switch outcome {
            case .cancelled:
                return finish(.cancelled)
            case .deadline:
                return finish(.deadline)
            case .failed(let message):
                return .failed(message)
            case .completed(let text, let calls):
                answer += text
                messages.append(.assistant(text, toolCalls: calls))
                if calls.isEmpty {
                    return finish(.endTurn)
                }
                if steps >= configuration.maximumSteps {
                    // The model asked for more work than the cap allows, so
                    // running the tools could not produce an answer.
                    return finish(.stepLimit)
                }
                let results = await runTools(calls, continuation: continuation)
                messages.append(contentsOf: results.map(ChatMessage.result))
                toolRuns += calls.count
            }
        }
        return finish(.stepLimit)
    }
}

extension AssistantSession {
    private enum TurnOutcome: Sendable {
        case completed(text: String, calls: [ToolCall])
        case cancelled
        case deadline
        case failed(String)
    }

    private enum Attempt: Sendable {
        case completed(text: String, calls: [ToolCall])
        case cancelled
        case stepTimedOut
        case failed(message: String, retryable: Bool)
    }

    /// One model turn, retried only while no token has been produced.
    private func modelTurn(
        messages: [ChatMessage],
        tools: [ChatToolSpec],
        deadline: ContinuousClock.Instant,
        continuation: AsyncStream<AssistantSessionEvent>.Continuation
    ) async -> TurnOutcome {
        var attempt = 0
        while true {
            let outcome = await attemptTurn(
                messages: messages,
                tools: tools,
                deadline: deadline,
                continuation: continuation
            )
            switch outcome {
            case .completed(let text, let calls):
                return .completed(text: text, calls: calls)
            case .cancelled:
                return .cancelled
            case .stepTimedOut:
                // A step that ran out of time is a stuck service, unless it is
                // the whole turn that ran out of time. The clock answers that.
                if ContinuousClock.now >= deadline { return .deadline }
                return .failed("The model stopped responding.")
            case .failed(let message, let retryable):
                guard retryable, attempt < configuration.retryDelays.count else {
                    return .failed(message)
                }
                let delay = configuration.retryDelays[attempt]
                attempt += 1
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return .cancelled
                }
                if ContinuousClock.now >= deadline { return .deadline }
            }
        }
    }

    /// One request to the provider, raced against its own deadline.
    ///
    /// A provider that accepts the connection and then stops talking would
    /// otherwise hang the turn; the race makes the step budget real instead of
    /// advisory.
    private func attemptTurn(
        messages: [ChatMessage],
        tools: [ChatToolSpec],
        deadline: ContinuousClock.Instant,
        continuation: AsyncStream<AssistantSessionEvent>.Continuation
    ) async -> Attempt {
        let budget = min(configuration.stepTimeout, deadline - ContinuousClock.now)
        guard budget > .zero else { return .stepTimedOut }
        return await withTaskGroup(of: Attempt?.self) { group in
            group.addTask {
                await collect(messages: messages, tools: tools, continuation: continuation)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: budget)
                    return nil
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if Task.isCancelled { return .cancelled }
            // `nil` is the deadline child waking, not an answer from the model.
            guard let first else { return .stepTimedOut }
            return first
        }
    }

    /// Reads one streamed answer into a value, forwarding it as it arrives.
    private func collect(
        messages: [ChatMessage],
        tools: [ChatToolSpec],
        continuation: AsyncStream<AssistantSessionEvent>.Continuation
    ) async -> Attempt {
        var text = ""
        var calls: [ToolCall] = []
        var producedOutput = false
        do {
            for try await event in provider.stream(messages: messages, tools: tools, model: model) {
                switch event {
                case .textDelta(let delta):
                    guard !delta.isEmpty else { continue }
                    producedOutput = true
                    text += delta
                    continuation.yield(.textDelta(delta))
                case .toolCall(let call):
                    producedOutput = true
                    calls.append(call)
                case .usage(let input, let output):
                    continuation.yield(.usage(input: input, output: output))
                case .done:
                    break
                }
            }
            return .completed(text: text, calls: calls)
        } catch {
            if Task.isCancelled { return .cancelled }
            // A retry is only safe before the first token: after one, a second
            // attempt would say the same words twice.
            return .failed(
                message: AssistantSession.description(of: error),
                retryable: !producedOutput && AssistantSession.isRetryable(error)
            )
        }
    }

    /// Runs the calls the model asked for, several at once.
    ///
    /// The results come back in the order the calls were asked for, not the
    /// order they finished, so the conversation the model reads is the same one
    /// it wrote. A call that never ran, because the turn was cancelled, still
    /// gets a result so the message list stays consistent.
    private func runTools(
        _ calls: [ToolCall],
        continuation: AsyncStream<AssistantSessionEvent>.Continuation
    ) async -> [ToolResult] {
        guard !calls.isEmpty else { return [] }
        let limit = min(max(1, configuration.maximumParallelTools), calls.count)
        var results = calls.map { ToolResult.failure($0.id, "The tool did not run.") }
        await withTaskGroup(of: (Int, ToolResult).self) { group in
            var next = 0
            for _ in 0..<limit {
                let index = next
                next += 1
                continuation.yield(.toolStarted(name: calls[index].name))
                let call = calls[index]
                group.addTask {
                    (index, await self.toolbox.invoke(call))
                }
            }
            while let finished = await group.next() {
                let (index, result) = finished
                results[index] = result
                continuation.yield(.toolFinished(name: calls[index].name, ok: !result.isError))
                guard next < calls.count, !Task.isCancelled else { continue }
                let started = next
                next += 1
                continuation.yield(.toolStarted(name: calls[started].name))
                let call = calls[started]
                group.addTask {
                    (started, await self.toolbox.invoke(call))
                }
            }
        }
        return results
    }

    /// Whether an error is one the service asks to be tried again.
    ///
    /// Only a rate limit and a server-side failure qualify. A rejected key, an
    /// unavailable service or a malformed answer would fail identically on the
    /// next attempt, and a turn that retried them would only be slower.
    static func isRetryable(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderError,
              case .rejected(let status, _) = providerError
        else { return false }
        return status == 429 || (500...599).contains(status)
    }

    /// The message a surface can show for an error.
    static func description(of error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
