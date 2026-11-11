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
    }

    private let lock = NSLock()
    private var reply: Reply
    private var conversations: [[ChatMessage]] = []
    private var toolLists: [[ChatToolSpec]] = []
    private var models: [String] = []
    private var terminations: [(Date, AsyncThrowingStream<ChatEvent, Error>.Continuation.Termination)] = []

    init(
        deltas: [String],
        milliseconds: Int = 0,
        error: Error? = nil,
        holdsOpen: Bool = false
    ) {
        reply = Reply(deltas: deltas, milliseconds: milliseconds, error: error, holdsOpen: holdsOpen)
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
                }
                if reply.holdsOpen {
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish()
                } else if let error = reply.error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.yield(.done(.endTurn))
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

/// The factory a rewrite is asked of, with every call counted.
@MainActor
final class RewriteFactorySpy: RewriteProviderFactory {
    let provider: RewriteStreamSpy
    var providerID = "anthropic"
    var keyPresent = true
    var modelName = "claude-3-5-haiku-20241022"
    var error: Error?
    private(set) var makeCount = 0
    private(set) var temperatures: [Double] = []

    init(provider: RewriteStreamSpy) {
        self.provider = provider
    }

    func hasKey() -> Bool { keyPresent }
    func model() -> String { modelName }

    func makeProvider(temperature: Double) async throws -> any ChatProvider {
        makeCount += 1
        temperatures.append(temperature)
        if let error { throw error }
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
            bundleIdentifier: "com.apple.mail",
            element: AXUIElementCreateSystemWide(),
            selection: NSRange(location: 0, length: 0),
            isSecure: secure
        )
    }

    func focusedField() -> FocusedTextField? {
        calls.append("focusedField")
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
