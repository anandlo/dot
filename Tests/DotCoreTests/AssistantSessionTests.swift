import XCTest

@testable import DotCore

/// The turn loop: steps, parallel tools, retries and cancellation.
///
/// The provider and the toolbox are the two seams of the session, so a scripted
/// provider and a recording toolbox are what the loop is tested with. The
/// adapters are tested against a real loopback server in their own files.
final class AssistantSessionTests: XCTestCase {
    /// A provider that answers with a script, one entry per model turn.
    private final class ScriptedProvider: ChatProvider, @unchecked Sendable {
        enum Turn {
            case events([ChatEvent])
            case eventsThenFailure([ChatEvent], ProviderError)
            case failure(ProviderError)
            case hang(after: String?)
        }

        private let lock = NSLock()
        private var turns: [Turn]
        private var attempts = 0
        private var histories: [[ChatMessage]] = []

        init(_ turns: [Turn]) {
            self.turns = turns
        }

        var attemptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }

        var lastMessages: [ChatMessage] {
            lock.lock()
            defer { lock.unlock() }
            return histories.last ?? []
        }

        func stream(
            messages: [ChatMessage],
            tools: [ChatToolSpec],
            model: String
        ) -> AsyncThrowingStream<ChatEvent, Error> {
            lock.lock()
            attempts += 1
            histories.append(messages)
            let turn = turns.isEmpty ? Turn.events([.done(.endTurn)]) : turns.removeFirst()
            lock.unlock()
            switch turn {
            case .events(let events):
                return AsyncThrowingStream { continuation in
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                }
            case .eventsThenFailure(let events, let error):
                return AsyncThrowingStream { continuation in
                    for event in events { continuation.yield(event) }
                    continuation.finish(throwing: error)
                }
            case .failure(let error):
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: error)
                }
            case .hang(let text):
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        if let text { continuation.yield(.textDelta(text)) }
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        }
    }

    /// A toolbox that records what ran, and can be slow or refuse.
    private actor RecordingToolbox: AssistantToolbox {
        private let offered: [ChatToolSpec]
        private let delay: Duration
        private let failing: Set<String>
        private var invoked: [ToolCall] = []

        init(specs: [ChatToolSpec], delay: Duration = .zero, failing: Set<String> = []) {
            offered = specs
            self.delay = delay
            self.failing = failing
        }

        func specs() async -> [ChatToolSpec] { offered }

        func invoke(_ call: ToolCall) async -> ToolResult {
            invoked.append(call)
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            if failing.contains(call.name) {
                return .failure(call.id, "\(call.name) refused")
            }
            return .success(call.id, "\(call.name) done")
        }

        func invokedCalls() -> [ToolCall] { invoked }
    }

    private func events(
        _ stream: AsyncStream<AssistantSessionEvent>
    ) async -> [AssistantSessionEvent] {
        var collected: [AssistantSessionEvent] = []
        for await event in stream {
            collected.append(event)
        }
        return collected
    }

    private func result(in events: [AssistantSessionEvent]) -> AssistantSessionResult? {
        for event in events {
            if case .finished(let result) = event { return result }
        }
        return nil
    }

    private func spec(_ name: String, risk: ToolRisk = .read) -> ChatToolSpec {
        ChatToolSpec(
            name: name,
            description: "The \(name) tool.",
            parameters: ["type": "object"],
            risk: risk
        )
    }

    func testATurnWithNoToolsAnswersAndReportsEndTurn() async {
        let provider = ScriptedProvider([
            .events([.textDelta("Hello"), .done(.endTurn)])
        ])
        let toolbox = RecordingToolbox(specs: [])
        let session = AssistantSession(provider: provider, model: "m", toolbox: toolbox)

        let collected = await events(session.run(prompt: "hi"))
        XCTAssertEqual(collected.first, .thinking)
        XCTAssertTrue(collected.contains(.textDelta("Hello")))
        guard let result = result(in: collected) else { return XCTFail("no result") }
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertEqual(result.toolRuns, 0)
        XCTAssertEqual(result.messages.last?.role, .assistant)
        XCTAssertEqual(result.messages.last?.text, "Hello")
        XCTAssertEqual(provider.attemptCount, 1)
        let invoked = await toolbox.invokedCalls()
        XCTAssertEqual(invoked, [])
    }

    func testToolCallsRunInParallelAndResultsKeepTheirOrder() async {
        let remind = ToolCall(id: "call_a", name: "remind", arguments: ["text": "deck"])
        let calendar = ToolCall(id: "call_b", name: "calendar", arguments: ["day": "Fri"])
        let provider = ScriptedProvider([
            .events([.toolCall(remind), .toolCall(calendar), .done(.toolCalls)]),
            .events([.textDelta("Both done."), .done(.endTurn)]),
        ])
        let toolbox = RecordingToolbox(
            specs: [spec("remind", risk: .write), spec("calendar")],
            delay: .milliseconds(300)
        )
        let session = AssistantSession(provider: provider, model: "m", toolbox: toolbox)

        let clock = ContinuousClock()
        let start = clock.now
        let collected = await events(session.run(prompt: "do both"))
        let elapsed = AssistantTestSupport.milliseconds(from: start, to: clock.now)
        XCTAssertLessThan(elapsed, 500, "two 300 ms tools must overlap, not queue")

        guard let result = result(in: collected) else { return XCTFail("no result") }
        XCTAssertEqual(result.toolRuns, 2)
        let toolMessages = result.messages.filter { $0.role == .tool }
        XCTAssertEqual(toolMessages.map(\.toolCallID), ["call_a", "call_b"])
        XCTAssertEqual(toolMessages.map(\.text), ["remind done", "calendar done"])
        let started = collected.filter { event in
            if case .toolStarted = event { return true }
            return false
        }
        let finished = collected.filter { event in
            if case .toolFinished = event { return true }
            return false
        }
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(finished.count, 2)
    }

    func testTheStepCapStopsAToolLoop() async {
        let turn = ScriptedProvider.Turn.events([
            .toolCall(ToolCall(id: "call_a", name: "remind", arguments: [:])),
            .done(.toolCalls),
        ])
        let provider = ScriptedProvider(Array(repeating: turn, count: 5))
        let toolbox = RecordingToolbox(specs: [spec("remind")])
        let session = AssistantSession(
            provider: provider,
            model: "m",
            toolbox: toolbox,
            configuration: AssistantSessionConfiguration(maximumSteps: 3)
        )

        let collected = await events(session.run(prompt: "loop"))
        guard let result = result(in: collected) else { return XCTFail("no result") }
        XCTAssertEqual(result.stopReason, .stepLimit)
        XCTAssertEqual(result.toolRuns, 2, "the third model turn has nowhere to send its calls")
        XCTAssertEqual(provider.attemptCount, 3)
    }

    func testARateLimitedTurnIsRetriedBeforeTheFirstToken() async {
        let provider = ScriptedProvider([
            .failure(.rejected(status: 429, message: "slow down")),
            .events([.textDelta("Hi"), .done(.endTurn)]),
        ])
        let session = AssistantSession(
            provider: provider,
            model: "m",
            toolbox: RecordingToolbox(specs: []),
            configuration: AssistantSessionConfiguration(retryDelays: [.milliseconds(10)])
        )

        let collected = await events(session.run(prompt: "hi"))
        XCTAssertEqual(result(in: collected)?.text, "Hi")
        XCTAssertEqual(provider.attemptCount, 2)
    }

    func testAnErrorAfterTheFirstTokenIsNotRetried() async {
        let provider = ScriptedProvider([
            .eventsThenFailure([.textDelta("Hel")], .rejected(status: 503, message: "unavailable"))
        ])
        let session = AssistantSession(
            provider: provider,
            model: "m",
            toolbox: RecordingToolbox(specs: []),
            configuration: AssistantSessionConfiguration(retryDelays: [.milliseconds(10)])
        )

        let collected = await events(session.run(prompt: "hi"))
        XCTAssertTrue(collected.contains(.textDelta("Hel")))
        let failures = collected.compactMap { event -> String? in
            if case .failed(let message) = event { return message }
            return nil
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(provider.attemptCount, 1, "a retry after a token would repeat the words")
    }

    func testARejectedKeyIsNotRetried() async {
        let provider = ScriptedProvider([
            .failure(.rejected(status: 401, message: "bad key"))
        ])
        let session = AssistantSession(
            provider: provider,
            model: "m",
            toolbox: RecordingToolbox(specs: []),
            configuration: AssistantSessionConfiguration(retryDelays: [.milliseconds(10)])
        )

        let collected = await events(session.run(prompt: "hi"))
        XCTAssertEqual(provider.attemptCount, 1)
        let failures = collected.compactMap { event -> String? in
            if case .failed(let message) = event { return message }
            return nil
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("401") == true, "the status reaches the card")
    }

    func testAProviderThatNeverAnswersHitsTheWallClock() async {
        let provider = ScriptedProvider([.hang(after: nil)])
        let session = AssistantSession(
            provider: provider,
            model: "m",
            toolbox: RecordingToolbox(specs: []),
            configuration: AssistantSessionConfiguration(
                wallClock: .milliseconds(150),
                stepTimeout: .seconds(5),
                retryDelays: []
            )
        )

        let clock = ContinuousClock()
        let start = clock.now
        let collected = await events(session.run(prompt: "hi"))
        let elapsed = AssistantTestSupport.milliseconds(from: start, to: clock.now)
        XCTAssertLessThan(elapsed, 3_000)
        XCTAssertEqual(result(in: collected)?.stopReason, .deadline)
    }

    func testCancellingTheConsumerStopsTheTurn() async {
        let provider = ScriptedProvider([.hang(after: "Hi")])
        let session = AssistantSession(
            provider: provider,
            model: "m",
            toolbox: RecordingToolbox(specs: [])
        )
        let sawToken = expectation(description: "the first token arrived")
        let consuming = Task {
            for await event in session.run(prompt: "hi") {
                if event == .textDelta("Hi") {
                    sawToken.fulfill()
                }
            }
        }
        await fulfillment(of: [sawToken], timeout: 5)

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
        XCTAssertTrue(ended, "cancelling the consumer must end the turn")
    }

    func testTheSystemPromptComesFirstAndHistoryIsKept() async {
        let provider = ScriptedProvider([.events([.textDelta("ok"), .done(.endTurn)])])
        let history: [ChatMessage] = [
            .user("earlier"),
            .assistant("answer"),
            .system("this is ignored"),
        ]
        let session = AssistantSession(
            provider: provider,
            model: "m",
            toolbox: RecordingToolbox(specs: [])
        )

        _ = await events(session.run(prompt: "now", history: history))
        let received = provider.lastMessages
        XCTAssertEqual(received.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertEqual(received.first?.text, AssistantSessionConfiguration.voiceSystemPrompt)
        XCTAssertEqual(received.last?.text, "now")
    }

    func testAToolFailureIsReportedToTheModelAndToTheSurface() async {
        let call = ToolCall(id: "call_a", name: "remind", arguments: [:])
        let provider = ScriptedProvider([
            .events([.toolCall(call), .done(.toolCalls)]),
            .events([.textDelta("It failed."), .done(.endTurn)]),
        ])
        let toolbox = RecordingToolbox(specs: [spec("remind")], failing: ["remind"])
        let session = AssistantSession(provider: provider, model: "m", toolbox: toolbox)

        let collected = await events(session.run(prompt: "remind me"))
        XCTAssertTrue(collected.contains(.toolFinished(name: "remind", ok: false)))
        let toolMessage = result(in: collected)?.messages.last { $0.role == .tool }
        XCTAssertTrue(toolMessage?.text.hasPrefix("Tool error: ") == true)
        XCTAssertEqual(toolMessage?.toolCallID, "call_a")
    }
}
