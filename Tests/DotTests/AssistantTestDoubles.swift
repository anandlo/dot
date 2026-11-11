import DotCore
import Foundation
import XCTest

@testable import Dot

/// A chat service that answers from a script and remembers what it was asked.
final class ScriptedChatProvider: ChatProvider, @unchecked Sendable {
    /// How fast the script is delivered.
    enum Pace {
        /// Every event at once.
        case instant
        /// One event every `milliseconds`.
        case paced(Int)
    }

    private let scripts: [[ChatEvent]]
    private let pace: Pace
    private let lock = NSLock()
    private var received: [[ChatMessage]] = []
    private var termination: AsyncThrowingStream<ChatEvent, Error>.Continuation.Termination?

    init(scripts: [[ChatEvent]], pace: Pace = .instant) {
        self.scripts = scripts
        self.pace = pace
    }

    convenience init(events: [ChatEvent], pace: Pace = .instant) {
        self.init(scripts: [events], pace: pace)
    }

    /// Every conversation the provider was asked to answer, oldest first.
    var conversations: [[ChatMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// How many requests reached the service.
    var callCount: Int { conversations.count }

    /// Why the last stream ended, once it has.
    var lastTermination: AsyncThrowingStream<ChatEvent, Error>.Continuation.Termination? {
        lock.lock()
        defer { lock.unlock() }
        return termination
    }

    func stream(
        messages: [ChatMessage],
        tools: [ChatToolSpec],
        model: String
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock()
        received.append(messages)
        lock.unlock()
        let script = nextScript()
        let pace = self.pace
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in script {
                    if case .paced(let milliseconds) = pace {
                        try? await Task.sleep(for: .milliseconds(milliseconds))
                    }
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] reason in
                task.cancel()
                self?.record(reason)
            }
        }
    }

    /// The script the next request is answered from.
    ///
    /// A turn with a tool makes two requests, so a script per request keeps the
    /// second answer from replaying the first one's tool call.
    private func nextScript() -> [ChatEvent] {
        lock.lock()
        defer { lock.unlock() }
        let index = min(max(received.count - 1, 0), scripts.count - 1)
        return scripts[index]
    }

    private func record(_ reason: AsyncThrowingStream<ChatEvent, Error>.Continuation.Termination) {
        lock.lock()
        termination = reason
        lock.unlock()
    }
}

/// The engine factory, with every call counted.
final class FakeChatFactory: ChatProviderFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let provider: ScriptedChatProvider
    private let hasKey: Bool
    private var providerCalls = 0
    private var toolCalls = 0
    private var storedSpy: SpyToolbox?
    private let toolbox: (any AssistantToolbox)?

    init(provider: ScriptedChatProvider, hasKey: Bool = true, toolbox: (any AssistantToolbox)? = nil) {
        self.provider = provider
        self.hasKey = hasKey
        self.toolbox = toolbox
    }

    var providerCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return providerCalls
    }

    var toolCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return toolCalls
    }

    func hasKey(for providerID: String) -> Bool { hasKey }

    func makeProvider(_ settings: AssistantSettings) async throws -> any ChatProvider {
        noteProviderCall()
        return provider
    }

    func makeTools(
        _ configuration: AssistantConfiguration,
        gate: ConfirmationGate
    ) async -> AssistantTools {
        noteToolCall()
        let built = toolbox ?? SpyToolbox(gate: gate)
        if let spy = built as? SpyToolbox {
            noteSpy(spy)
        }
        return AssistantTools(toolbox: built, connectorNames: ["reminders_create": "Reminders"])
    }

    /// The spy connector the factory built, so a test can count what ran.
    var spy: SpyToolbox? {
        lock.lock()
        defer { lock.unlock() }
        return storedSpy
    }

    private func noteSpy(_ spy: SpyToolbox) {
        lock.lock()
        storedSpy = spy
        lock.unlock()
    }

    private func noteProviderCall() {
        lock.lock()
        providerCalls += 1
        lock.unlock()
    }

    private func noteToolCall() {
        lock.lock()
        toolCalls += 1
        lock.unlock()
    }
}

/// A toolbox that counts what it was asked to run.
final class SpyToolbox: AssistantToolbox, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: ConfirmationGate
    private var invocations = 0
    private let call: ToolCall

    init(gate: ConfirmationGate, call: ToolCall = ToolCall(
        id: "call-1",
        name: "reminders_create",
        arguments: .object([:])
    )) {
        self.gate = gate
        self.call = call
    }

    /// How many calls reached the connectors. A declined confirmation must
    /// leave this at zero.
    var invokeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    func specs() async -> [ChatToolSpec] {
        [ChatToolSpec(name: call.name, description: "Add a reminder", parameters: .object([:]), risk: .write)]
    }

    func invoke(_ call: ToolCall) async -> ToolResult {
        let allowed = await gate.confirm(ConfirmationRequest(
            callID: call.id,
            toolName: call.name,
            connectorID: .reminders,
            connectorName: "Reminders",
            risk: .write,
            summary: "Add a reminder"
        ))
        guard allowed else { return .failure(call.id, "Declined") }
        noteInvocation()
        return .success(call.id, "Added")
    }

    private func noteInvocation() {
        lock.lock()
        invocations += 1
        lock.unlock()
    }
}

/// The voice, with every delta kept.
@MainActor
final class FakeSpeaker: AnswerSpeaker {
    var onFinish: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private(set) var begins = 0
    private(set) var feeds: [String] = []
    private(set) var finishes = 0
    private(set) var stops = 0
    private(set) var teardowns = 0
    var canSpeak = true

    func beginSpeaking(_ settings: VoiceSettings) async -> Bool {
        begins += 1
        return canSpeak
    }

    func feed(_ delta: String) {
        feeds.append(delta)
    }

    func finishSpeaking() {
        finishes += 1
    }

    func stopSpeaking() {
        stops += 1
    }

    func tearDownSpeech() {
        teardowns += 1
    }

    /// Plays the end of the answer, as the player does when its queue empties.
    func finishPlayback() {
        onFinish?()
    }
}

/// The clipboard and the frontmost application, as a test sees them.
@MainActor
final class FakePaster: AnswerPaster {
    var frontmostApp: FrontmostApp?
    var accessibilityGranted = true
    private(set) var copies: [String] = []
    private(set) var pastes = 0
    private(set) var accessibilityRequests = 0

    func copy(_ text: String) {
        copies.append(text)
    }

    @discardableResult
    func paste() -> Bool {
        pastes += 1
        return true
    }

    func requestAccessibility() {
        accessibilityRequests += 1
    }
}

/// The island, with every state kept.
@MainActor
final class FakeAssistantHUD: AssistantHUD {
    enum Event: Equatable {
        case thinking(String)
        case tool(String)
        case answer(String, AssistantAnswerState)
        case confirm(String)
        case hideConfirm
        case hide
        case message(String, String)
    }

    private(set) var events: [Event] = []
    private(set) var allow: (() -> Void)?
    private(set) var cancel: (() -> Void)?

    var answers: [AssistantAnswerState] {
        events.compactMap { event in
            if case .answer(_, let state) = event { return state }
            return nil
        }
    }

    var lastAnswerText: String? {
        for event in events.reversed() {
            if case .answer(let text, _) = event { return text }
        }
        return nil
    }

    func showAssistantThinking(question: String) {
        events.append(.thinking(question))
    }

    func showAssistantTool(connectorName: String) {
        events.append(.tool(connectorName))
    }

    func showAssistantAnswer(text: String, state: AssistantAnswerState) {
        events.append(.answer(text, state))
    }

    func showAssistantConfirm(
        _ request: ConfirmationRequest,
        onAllow: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        allow = onAllow
        cancel = onCancel
        events.append(.confirm(request.summary))
    }

    func hideAssistantConfirm() {
        events.append(.hideConfirm)
    }

    func hideAssistant() {
        events.append(.hide)
    }

    func showAssistantMessage(_ text: String, symbol: String) {
        events.append(.message(text, symbol))
    }
}

/// A clock a test can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Waits for a condition on the main actor, up to a deadline.
@MainActor
func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(4))
    }
    return condition()
}
