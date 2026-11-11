import AppKit
import DotCore
import Foundation

/// Runs one rewrite at a time for the transcript card.
///
/// It owns the state machine the card draws: offered, rewriting, applied,
/// blocked, copied, failed. The stream, the check and the write are three
/// separate steps on purpose, because each can fail in a way the person has to
/// see: a stream that stops, a check that finds a changed number, a text field
/// that will not take the text.
@MainActor
final class RewriteRunner {
    /// The deadlines of one attempt.
    struct Timing: Sendable {
        /// How long an attempt may run in all, in seconds.
        var total: TimeInterval = 15
        /// How long the first token may take, in seconds.
        var firstToken: TimeInterval = 6
        /// How long the failure note stays on the card, in seconds.
        var failureNote: TimeInterval = 3

        static let `default` = Timing()
    }

    /// Called with the layer after every change, and with `nil` when the layer
    /// belongs to a take that is gone.
    var onChange: ((RewriteCard?) -> Void)?

    /// The layer the card draws, or `nil` when the take has no rewrite offer.
    private(set) var card: RewriteCard? {
        didSet { onChange?(card) }
    }

    private let factory: any RewriteProviderFactory
    private let textFields: any TextFieldAccess
    private let copy: (String) -> Void
    private let frontmost: () -> Int32?
    private let now: () -> Date
    private let timing: Timing

    /// The application the take was delivered into, when known.
    private var destination: String?
    /// How the take was delivered.
    private var delivery: HUDDelivery = .copied
    /// The insertion the paste made, when Accessibility could read it.
    private var anchor: InsertionAnchor?
    /// Whether the last capture found a password field.
    private var secureFocus = false
    /// The attempt that is running.
    private var attempt: Task<Void, Never>?
    /// The task that enforces the two deadlines.
    private var watchdog: Task<Void, Never>?
    /// The task that clears the failure note.
    private var noteTask: Task<Void, Never>?
    /// Counts attempts, so a late event from a cancelled one is ignored.
    private var generation = 0
    /// Whether a token has arrived in the current attempt.
    private var sawFirstToken = false

    init(
        factory: any RewriteProviderFactory,
        textFields: any TextFieldAccess,
        copy: @escaping (String) -> Void,
        frontmost: @escaping () -> Int32? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        now: @escaping () -> Date = Date.init,
        timing: Timing = .default
    ) {
        self.factory = factory
        self.textFields = textFields
        self.copy = copy
        self.frontmost = frontmost
        self.now = now
        self.timing = timing
    }

    /// Whether a finished take would get the chips.
    ///
    /// The caller asks this before the paste, because it is what decides
    /// whether an insertion anchor is captured at all. An install with no chat
    /// service therefore never touches the Accessibility API.
    func offersRewrite(
        for text: String,
        delivery: HUDDelivery,
        configuration: RewriteConfiguration
    ) -> Bool {
        RewriteOffer.shouldOffer(
            rewrite: configuration,
            providerID: factory.providerID,
            hasKey: factory.hasKey(),
            text: text,
            delivery: delivery
        )
    }

    /// Captures where the paste is about to go.
    ///
    /// It has to run immediately before the keystroke: the selected range is
    /// the point the text is inserted at, and asking any later would be reading
    /// a field that already holds the words.
    func captureAnchor(insertedText: String, at date: Date? = nil) -> InsertionAnchor? {
        secureFocus = false
        guard let field = textFields.focusedField() else { return nil }
        if field.isSecure {
            secureFocus = true
            return nil
        }
        let record = InsertionRecord(
            processIdentifier: field.processIdentifier,
            bundleIdentifier: field.bundleIdentifier,
            location: field.selection.location,
            length: insertedText.utf16.count,
            insertedText: insertedText,
            capturedAt: date ?? now()
        )
        return InsertionAnchor(record: record, field: field)
    }

    /// Starts a take: either the chips appear, or the layer is gone.
    ///
    /// - Returns: whether the chips were offered.
    @discardableResult
    func begin(
        text: String,
        delivery: HUDDelivery,
        destination: String?,
        configuration: RewriteConfiguration,
        anchor: InsertionAnchor?
    ) -> Bool {
        cancelWork()
        self.destination = destination
        self.delivery = delivery
        self.anchor = anchor
        let offered = !secureFocus && !(anchor?.field.isSecure ?? false) && offersRewrite(
            for: text,
            delivery: delivery,
            configuration: configuration
        )
        guard offered else {
            card = nil
            return false
        }
        card = RewriteCard(
            original: text,
            choices: configuration.choices,
            phase: .offered,
            destination: destination
        )
        return true
    }

    /// Forgets the layer, with no note and no attempt left running.
    func reset() {
        cancelWork()
        anchor = nil
        secureFocus = false
        card = nil
    }

    /// Runs a style, replacing whatever was running.
    func choose(_ style: RewriteStyle, configuration: RewriteConfiguration) {
        guard let current = card else { return }
        // The chips rewrite the original, never the rewrite they are looking
        // at: two styles in a row are two attempts at the same words.
        guard configuration.style(for: style.id) != nil else { return }
        generation += 1
        let token = generation
        sawFirstToken = false
        card?.phase = .rewriting(styleID: style.id, title: style.title)
        card?.rewrite = ""
        card?.warning = nil
        card?.note = nil
        attempt?.cancel()
        attempt = Task { [weak self] in
            await self?.run(style: style, text: current.original, token: token)
        }
        watch(token: token)
    }

    /// Stops the stream and leaves the original on the card.
    func cancelStream() {
        guard card?.isStreaming == true else { return }
        cancelWork()
        card?.phase = .offered
        card?.rewrite = ""
        card?.warning = nil
    }

    /// Applies a rewrite the check refused.
    func useAnyway() {
        guard let current = card,
              case .blocked(let styleID, _) = current.phase,
              let style = current.choices.first(where: { $0.id == styleID })
        else { return }
        apply(style: style, text: current.rewrite, token: generation)
    }

    /// Returns to the chips without writing anything.
    func keepOriginal() {
        card?.phase = .offered
        card?.rewrite = ""
        card?.warning = nil
        card?.note = nil
        card?.canUndo = false
    }

    // MARK: - The stream

    /// Enforces the two deadlines of an attempt.
    private func watch(token: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.timing.firstToken))
            guard !Task.isCancelled, self.generation == token else { return }
            guard self.sawFirstToken else {
                self.fail()
                return
            }
            let remaining = max(0, self.timing.total - self.timing.firstToken)
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, self.generation == token, self.card?.isStreaming == true else {
                return
            }
            self.fail()
        }
    }

    private func run(style: RewriteStyle, text: String, token: Int) async {
        do {
            let provider = try await factory.makeProvider(temperature: RewritePrompt.temperature)
            let messages = RewritePrompt.messages(for: style, text: text)
            let limit = RewritePrompt.outputLimit(inputCharacters: text.count)
            var accumulated = ""
            let stream = provider.stream(messages: messages, tools: [], model: factory.model())
            for try await event in stream {
                try Task.checkCancellation()
                guard generation == token, card != nil else { return }
                guard case .textDelta(let delta) = event else { continue }
                sawFirstToken = true
                accumulated += delta
                if accumulated.count >= limit {
                    accumulated = String(accumulated.prefix(limit))
                }
                card?.rewrite = accumulated
                if accumulated.count >= limit { break }
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            finish(style: style, text: accumulated, token: token)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            fail()
        }
    }

    /// Checks the finished rewrite and applies it, or asks first.
    private func finish(style: RewriteStyle, text: String, token: Int) {
        guard generation == token, let current = card else { return }
        let rewrite = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rewrite.isEmpty else {
            fail()
            return
        }
        let report = FaithfulnessCheck.check(
            original: current.original,
            rewrite: rewrite,
            style: style
        )
        card?.rewrite = rewrite
        card?.warning = report.firstWarning
        guard let error = report.firstError else {
            apply(style: style, text: rewrite, token: token)
            return
        }
        card?.phase = .blocked(styleID: style.id, error: error)
        card?.canUndo = false
        card?.note = nil
    }

    private func fail() {
        cancelWork()
        card?.phase = .offered
        card?.rewrite = ""
        card?.warning = nil
        card?.canUndo = false
        card?.note = RewriteCard.failureNote
        let token = generation
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.timing.failureNote ?? 3))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.card?.note = nil
        }
    }

    /// Stops every task of the current attempt and invalidates its events.
    private func cancelWork() {
        generation += 1
        attempt?.cancel()
        watchdog?.cancel()
        noteTask?.cancel()
        attempt = nil
        watchdog = nil
        noteTask = nil
        sawFirstToken = false
    }

    // MARK: - The write

    /// Writes a rewrite where the transcript went, or puts it on the clipboard.
    private func apply(style: RewriteStyle, text: String, token: Int) {
        guard generation == token else { return }
        cancelAttemptTasks()
        if delivery == .pasted, let anchor {
            switch replace(anchor: anchor, with: text) {
            case .replace:
                card?.phase = .applied(styleID: style.id)
                card?.note = nil
                card?.canUndo = true
                return
            case .clipboardOnly(let reason):
                Log.shared.warn("rewrite.clipboard", ["reason": .string(reason.rawValue)])
            }
        }
        copy(text)
        card?.phase = .copied(styleID: style.id)
        card?.note = RewriteCard.clipboardNote
        card?.canUndo = false
    }

    /// Puts the transcript back through the anchor the rewrite used.
    ///
    /// A refusal is not an error the person has to act on: the original goes on
    /// the clipboard and the card shows it again.
    func undo() {
        guard let current = card, current.canUndo, let anchor else { return }
        cancelWork()
        switch replace(anchor: anchor, with: current.original) {
        case .replace:
            card?.phase = .offered
            card?.rewrite = ""
            card?.warning = nil
            card?.note = nil
            card?.canUndo = false
        case .clipboardOnly(let reason):
            Log.shared.warn("rewrite.undo.clipboard", ["reason": .string(reason.rawValue)])
            copy(current.original)
            card?.phase = .offered
            card?.rewrite = ""
            card?.warning = nil
            card?.note = nil
            card?.canUndo = false
        }
    }

    private func cancelAttemptTasks() {
        attempt?.cancel()
        watchdog?.cancel()
        attempt = nil
        watchdog = nil
    }

    /// Replaces the anchored range, following the decision table.
    private func replace(anchor: InsertionAnchor, with text: String) -> ReplacementOutcome {
        let field = anchor.field
        let range = NSRange(location: anchor.record.location, length: anchor.record.length)
        let focused = textFields.isFocused(field)
        let live = focused ? textFields.text(in: range, of: field) : nil
        let outcome = ReplacementDecision.decide(
            anchor: anchor.record,
            now: now(),
            processIdentifier: frontmost(),
            focusedIsAnchor: focused,
            textInRange: live
        )
        guard outcome == .replace else { return outcome }
        let newRange = NSRange(location: anchor.record.location, length: text.utf16.count)
        guard write(text, selecting: range, reading: newRange, in: field) else {
            return retryWrite(text, selecting: range, reading: newRange, in: field)
                ? .replace
                : .clipboardOnly(.readBackFailed)
        }
        self.anchor = InsertionAnchor(
            record: anchor.record.replacing(length: text.utf16.count, text: text, at: now()),
            field: field
        )
        return .replace
    }

    /// Retries a write once, only while the anchored range still verifies.
    ///
    /// The anchor verifies in one of two ways: the range still holds the words
    /// that were inserted, so the first write never took, or it already holds
    /// the rewrite, so the text is in place and only its read-back failed. Both
    /// are safe to write again; anything else is somebody else's sentence and
    /// the rewrite goes to the clipboard.
    private func retryWrite(
        _ text: String,
        selecting range: NSRange,
        reading newRange: NSRange,
        in field: FocusedTextField
    ) -> Bool {
        guard textFields.isFocused(field) else { return false }
        if ReplacementDecision.matches(
            inserted: text,
            live: textFields.text(in: newRange, of: field)
        ) {
            return write(text, selecting: newRange, reading: newRange, in: field)
        }
        if let anchor, ReplacementDecision.matches(
            inserted: anchor.record.insertedText,
            live: textFields.text(in: range, of: field)
        ) {
            return write(text, selecting: range, reading: newRange, in: field)
        }
        return false
    }

    /// Selects the old range, writes over it and reads the new one back.
    private func write(
        _ text: String,
        selecting range: NSRange,
        reading newRange: NSRange,
        in field: FocusedTextField
    ) -> Bool {
        guard textFields.select(range, in: field) else { return false }
        guard textFields.setText(text, in: field) else { return false }
        guard let readBack = textFields.text(in: newRange, of: field) else { return false }
        return readBack == text
    }
}
