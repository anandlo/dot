import AppKit
import ApplicationServices
import DotCore
import Foundation
import XCTest

@testable import Dot

/// A chat service that answers a rewrite from a script and records the request.
final class RewriteStreamSpy: ChatProvider, @unchecked Sendable {
    struct Reply {
        var deltas: [String]
        var milliseconds: Int
        var error: Error?
        var holdsOpen: Bool
        var finishWithoutDone: Bool
    }

    private let lock = NSLock()
    private var reply: Reply
    private var conversations: [[ChatMessage]] = []
    private var toolLists: [[ChatToolSpec]] = []
    private var models: [String] = []
    private var terminations: [(Date, AsyncThrowingStream<ChatEvent, Error>.Continuation.Termination)] = []
    private var deliveries: [Int] = []

    init(
        deltas: [String],
        milliseconds: Int = 0,
        error: Error? = nil,
        holdsOpen: Bool = false,
        finishWithoutDone: Bool = false
    ) {
        reply = Reply(
            deltas: deltas,
            milliseconds: milliseconds,
            error: error,
            holdsOpen: holdsOpen,
            finishWithoutDone: finishWithoutDone
        )
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return conversations.count
    }

    var lastMessages: [ChatMessage]? {
        lock.lock()
        defer { lock.unlock() }
        return conversations.last
    }

    var lastTools: [ChatToolSpec]? {
        lock.lock()
        defer { lock.unlock() }
        return toolLists.last
    }

    var lastModel: String? {
        lock.lock()
        defer { lock.unlock() }
        return models.last
    }

    /// How many deltas each stream delivered, in the order the streams were asked
    /// for.
    ///
    /// A stream the consumer left is cancelled before its producer has sent
    /// everything, so its count is short of the script; a stream that was read
    /// to the end counts every delta it was given. The test reads it instead of
    /// timing the answer, which measures the machine rather than the cap.
    var deliveredDeltas: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return deliveries
    }

    /// Every stream the consumer stopped, with when it happened.
    var stopped: [(Date, AsyncThrowingStream<ChatEvent, Error>.Continuation.Termination)] {
        lock.lock()
        defer { lock.unlock() }
        return terminations
    }

    func stream(
        messages: [ChatMessage],
        tools: [ChatToolSpec],
        model: String
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock()
        conversations.append(messages)
        toolLists.append(tools)
        models.append(model)
        deliveries.append(0)
        let index = deliveries.count - 1
        let reply = self.reply
        lock.unlock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for delta in reply.deltas {
                    if reply.milliseconds > 0 {
                        try? await Task.sleep(for: .milliseconds(reply.milliseconds))
                    }
                    if Task.isCancelled { break }
                    continuation.yield(.textDelta(delta))
                    self.lock.withLock { self.deliveries[index] += 1 }
                }
                if reply.holdsOpen {
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish()
                } else if let error = reply.error {
                    continuation.finish(throwing: error)
                } else {
                    if !reply.finishWithoutDone {
                        continuation.yield(.done(.endTurn))
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { [weak self] reason in
                task.cancel()
                self?.lock.lock()
                self?.terminations.append((Date(), reason))
                self?.lock.unlock()
            }
        }
    }
}

/// A chat service that answers one rewrite from a script with arrival times.
///
/// Each event carries the moment it reaches the consumer, measured from the
/// request, so a test can say when a service starts reasoning and when its
/// first word lands without a sleep of its own. The waits are bounded by the
/// script: the last event's time is the longest anything here can take.
final class TimedRewriteProvider: ChatProvider, @unchecked Sendable {
    /// One event the service sends, and when it arrives.
    struct Beat {
        /// Milliseconds from the request to the event.
        var after: Int
        /// The event the service sends.
        var event: ChatEvent

        init(_ after: Int, _ event: ChatEvent) {
            self.after = after
            self.event = event
        }
    }

    private let script: [Beat]
    private let lock = NSLock()
    private var requests = 0

    init(_ script: [Beat]) {
        self.script = script
    }

    /// How many requests reached the service.
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stream(
        messages: [ChatMessage],
        tools: [ChatToolSpec],
        model: String
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock()
        requests += 1
        lock.unlock()
        let script = self.script
        return AsyncThrowingStream { continuation in
            let task = Task {
                let start = ContinuousClock.now
                for beat in script {
                    let wait = ContinuousClock.now.duration(
                        to: start.advanced(by: .milliseconds(beat.after))
                    )
                    if wait > .zero {
                        try? await Task.sleep(for: wait)
                    }
                    if Task.isCancelled { break }
                    continuation.yield(beat.event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The factory a rewrite is asked of, with every call counted.
@MainActor
final class RewriteFactorySpy: RewriteProviderFactory {
    let provider: RewriteStreamSpy
    var providerID = "anthropic"
    var isSetUp = true
    var keyPresent = true
    var modelName = "claude-3-5-haiku-20241022"
    var error: Error?
    /// Providers returned before ``provider``, in order, so a test can make the
    /// first request succeed and the second fail without rebuilding the runner.
    var queue: [RewriteStreamSpy] = []
    private(set) var makeCount = 0
    private(set) var temperatures: [Double] = []

    init(provider: RewriteStreamSpy) {
        self.provider = provider
    }

    var assistant: AssistantConfiguration {
        var configuration = AssistantConfiguration.default
        configuration.isSetUp = isSetUp
        configuration.chat = AssistantSettings(providerID: providerID, model: modelName)
        return configuration
    }

    func hasKey() -> Bool { keyPresent }
    func model() -> String { modelName }

    func makeProvider(temperature: Double) async throws -> any ChatProvider {
        makeCount += 1
        temperatures.append(temperature)
        if let error { throw error }
        // The first request uses the standing provider; the queue supplies the
        // providers of later requests, which is how a test makes the first
        // answer succeed and the second fail or stall.
        if makeCount > 1, !queue.isEmpty { return queue.removeFirst() }
        return provider
    }
}

/// A text field that is only memory.
///
/// It records every call, so a test can assert the order the rewrite writes in
/// and, just as important, that an ineligible take never touched it.
@MainActor
final class FakeTextFieldAccess: TextFieldAccess {
    var document: String
    var selection = NSRange(location: 0, length: 0)
    var focused = true
    var secure = false
    var bundleIdentifier = "com.apple.mail"
    var hasFocusedField = true
    /// When set, each `focusedField()` call takes the next selection, so a test
    /// can move the caret between the click and the write.
    var fieldSelectionScript: [NSRange] = []
    var failsSelect = false
    var failsSetText = false
    /// What the reads after a write return, in order. A `nil` entry falls
    /// through to the document.
    var readBackScript: [String?] = []
    private(set) var calls: [String] = []
    private(set) var selections: [NSRange] = []
    private(set) var writes: [String] = []

    init(document: String) {
        self.document = document
    }

    var field: FocusedTextField {
        FocusedTextField(
            processIdentifier: 42,
            bundleIdentifier: bundleIdentifier,
            element: AXUIElementCreateSystemWide(),
            selection: selection,
            isSecure: secure
        )
    }

    func focusedField() -> FocusedTextField? {
        calls.append("focusedField")
        guard hasFocusedField else { return nil }
        if !fieldSelectionScript.isEmpty {
            selection = fieldSelectionScript.removeFirst()
        }
        return field
    }

    func isFocused(_ field: FocusedTextField) -> Bool {
        calls.append("isFocused")
        return focused
    }

    func text(in range: NSRange, of field: FocusedTextField) -> String? {
        calls.append("read")
        if !writes.isEmpty, !readBackScript.isEmpty {
            if let scripted = readBackScript.removeFirst() { return scripted }
        }
        let ns = document as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    @discardableResult
    func select(_ range: NSRange, in field: FocusedTextField) -> Bool {
        calls.append("select")
        selections.append(range)
        guard !failsSelect else { return false }
        selection = range
        return true
    }

    @discardableResult
    func setText(_ text: String, in field: FocusedTextField) -> Bool {
        calls.append("setText")
        guard !failsSetText else { return false }
        let ns = NSMutableString(string: document)
        ns.replaceCharacters(in: selection, with: text)
        document = ns as String
        writes.append(text)
        selection = NSRange(location: selection.location, length: (text as NSString).length)
        return true
    }
}

/// A date the test can move.
final class MutableDate {
    var value = Date(timeIntervalSinceReferenceDate: 800_000_000)
}

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
