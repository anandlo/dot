import AppKit
import DotCore
import Foundation

/// Runs one rewrite at a time for the transcript card.
///
/// It owns the state machine the card draws: offered, rewriting, blocked,
/// failed, and the explicit delivery outcomes. A successful request appends a
/// version; it never writes to another application and it never touches the
/// clipboard. The stream, the check and the explicit Copy or Paste are separate
/// steps on purpose, because each can fail in a way the person has to see.
@MainActor
final class RewriteRunner {
    /// The deadlines of one request.
    struct Timing: Sendable {
        /// How long a request may run in all, in seconds.
        ///
        /// A reasoning model on a cold connection can think for half a minute
        /// before it sends its first token, so the ceiling covers the thinking
        /// as well as the answer. A capped answer that is asked again runs
        /// inside the same deadline, so the retry cannot double the time the
        /// person waits.
        var total: TimeInterval = 45
        /// How long the service may take to show any sign of work, in seconds.
        ///
        /// The wait is measured to the first thing the service sends, which is
        /// an answer token or the reasoning that precedes it: a reasoning model
        /// on a cold connection can think for a while before its first word, and
        /// an attempt that ended in that time would report a service that is
        /// working as one that went quiet. A service that is still answering
        /// when the whole request's ``total`` runs out is ended there instead.
        var firstToken: TimeInterval = 15
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

    /// The selected version, when the card is showing one.
    var selectedVersion: RewriteVersion? { card?.selectedVersion }

    private let factory: any RewriteProviderFactory
    private let textFields: any TextFieldAccess
    private let copyToClipboard: (String) -> Void
    private let frontmost: () -> Int32?
    private let now: () -> Date
    private let timing: Timing
    /// Dot's own process, so an explicit paste can never write into the HUD.
    private let ownProcessIdentifier: Int32
    /// Dot's own bundle, so a field that belongs to Dot is never a target.
    private let ownBundleIdentifier: String
    /// The name the header shows for the application an explicit paste wrote
    /// into. It is resolved from the live process, never from the take's
    /// original destination.
    private let applicationName: (Int32) -> String?

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
    /// The task that clears the notice under the body.
    private var noteTask: Task<Void, Never>?
    /// The id the next appended version takes. Version 0 is the original.
    private var nextVersionID = 1
    /// Counts takes, so a late event from an old one can never reach a new card.
    private var take = 0
    /// Counts requests inside a take, so a late event from a cancelled one is
    /// ignored even when the take is still on screen.
    private var generation = 0
    /// Whether an answer token has arrived in the current request.
    ///
    /// It is kept apart from ``sawActivity`` because the two say different
    /// things: a service that reasons sends events before its first word, and
    /// only an answer token says the words the card draws have started.
    private var sawFirstToken = false
    /// Whether the service has shown any sign of work in the current request.
    ///
    /// An answer token and the reasoning that can precede it are both work. The
    /// first-token deadline reads this rather than ``sawFirstToken``, because a
    /// service that is thinking is alive even when it has not written a word.
    private var sawActivity = false
    /// How many characters of the answer the current request holds.
    ///
    /// It is kept for the log line a deadline writes, so a request that ended
    /// before the answer started can be told from one that was cut mid-answer.
    private var streamedCharacters = 0

    init(
        factory: any RewriteProviderFactory,
        textFields: any TextFieldAccess,
        copy: @escaping (String) -> Void,
        frontmost: @escaping () -> Int32? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        now: @escaping () -> Date = Date.init,
        timing: Timing = .default,
        ownProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        ownBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        applicationName: @escaping (Int32) -> String? = {
            NSRunningApplication(processIdentifier: $0)?.localizedName
        }
    ) {
        self.factory = factory
        self.textFields = textFields
        self.copyToClipboard = copy
        self.frontmost = frontmost
        self.now = now
        self.timing = timing
        self.ownProcessIdentifier = ownProcessIdentifier
        self.ownBundleIdentifier = ownBundleIdentifier
        self.applicationName = applicationName
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
            assistant: factory.assistant,
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

    /// Starts a take: either the versions appear, or the layer is gone.
    ///
    /// The original is version 0 and is never replaced. Starting a take
    /// invalidates every request from the previous one.
    ///
    /// - Parameters:
    ///   - text: the transcript the take produced.
    ///   - delivery: how the transcript was delivered.
    ///   - destination: the application the transcript went to, when known.
    ///   - configuration: the rewrite settings in force.
    ///   - anchor: where the paste inserted the transcript, when it did.
    ///   - saved: the versions the history already holds for this exact text.
    ///     A person who dictates a sentence they have had rewritten before
    ///     keeps those versions rather than erasing them, and the next
    ///     generation takes the id after the last one saved. The card opens on
    ///     the original: the words that were just delivered are what the take
    ///     put in the application, so the saved selection belongs to the history
    ///     click that restores it, not to a fresh dictation.
    /// - Returns: whether the versions were offered.
    @discardableResult
    func begin(
        text: String,
        delivery: HUDDelivery,
        destination: String?,
        configuration: RewriteConfiguration,
        anchor: InsertionAnchor?,
        saved: RewriteSnapshot? = nil
    ) -> Bool {
        cancelWork()
        take += 1
        self.destination = destination
        self.delivery = delivery
        self.anchor = anchor
        self.nextVersionID = 1
        let offered = !secureFocus && !(anchor?.field.isSecure ?? false) && offersRewrite(
            for: text,
            delivery: delivery,
            configuration: configuration
        )
        guard offered else {
            card = nil
            return false
        }
        let seeded = Self.seeded(saved, original: text)
        nextVersionID = seeded.nextVersionID
        card = RewriteCard(
            original: text,
            choices: configuration.choices,
            phase: .offered,
            versions: seeded.versions,
            selectedVersionID: 0,
            destination: destination
        )
        return true
    }

    /// Shows the versions a history entry kept, without asking the service.
    ///
    /// This is the history click: the original is already on the clipboard, and
    /// the card shows the version that was selected when the take was left. It
    /// is deliberately independent of whether the rewrite is switched on, set
    /// up or short enough: saved words are reviewable offline, and a card whose
    /// generation choices are empty is read-only. Generation itself still goes
    /// through ``request(_:configuration:)``, so restoring can never bypass the
    /// readiness, enabled and length gates.
    ///
    /// - Parameters:
    ///   - original: the transcript the entry holds.
    ///   - saved: the versions and the selection the entry kept.
    ///   - configuration: the rewrite settings in force now.
    /// - Returns: whether a versioned card was shown.
    @discardableResult
    func restore(
        original: String,
        saved: RewriteSnapshot,
        configuration: RewriteConfiguration
    ) -> Bool {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let seeded = Self.seeded(saved, original: text)
        guard seeded.versions.count > 1 else { return false }
        cancelWork()
        take += 1
        destination = nil
        delivery = .copied
        anchor = nil
        secureFocus = false
        nextVersionID = seeded.nextVersionID
        card = RewriteCard(
            original: text,
            choices: generationChoices(for: text, configuration: configuration),
            phase: .offered,
            versions: seeded.versions,
            selectedVersionID: seeded.selectedVersionID
        )
        return true
    }

    /// The version list a card starts with when the entry already has versions.
    ///
    /// The original is always rebuilt from the entry's text, so a file cannot
    /// say a different transcript was dictated. A snapshot with nothing
    /// readable left is the same as no snapshot.
    private static func seeded(
        _ saved: RewriteSnapshot?,
        original: String
    ) -> (versions: [RewriteVersion], selectedVersionID: Int, nextVersionID: Int) {
        let originalVersion = RewriteVersion.original(text: original)
        guard let normalized = saved?.normalized(), !normalized.versions.isEmpty else {
            return ([originalVersion], 0, 1)
        }
        return (
            [originalVersion] + normalized.versions,
            normalized.selectedVersionID,
            normalized.nextVersionID
        )
    }

    /// The styles this transcript may be rewritten with right now.
    ///
    /// The saved versions are reviewed whatever this says; it only decides
    /// which chips can start a request. It is the same test a fresh take uses,
    /// so a restored card cannot offer a style a new dictation would not.
    private func generationChoices(
        for text: String,
        configuration: RewriteConfiguration
    ) -> [RewriteStyle] {
        RewriteOffer.shouldOffer(
            rewrite: configuration,
            assistant: factory.assistant,
            hasKey: factory.hasKey(),
            text: text,
            delivery: .copied
        ) ? configuration.choices : []
    }

    /// Forgets the layer, with no note and no attempt left running.
    func reset() {
        cancelWork()
        take += 1
        anchor = nil
        secureFocus = false
        destination = nil
        delivery = .copied
        nextVersionID = 1
        card = nil
    }

    /// A style chip was clicked.
    ///
    /// An existing style selects its latest version: nothing is generated by
    /// changing the review. A style that has never run starts one request. The
    /// rerun affordance is the only way to ask for another version of a style
    /// that already has one.
    func selectStyle(_ style: RewriteStyle, configuration: RewriteConfiguration) {
        guard let current = card,
              configuration.style(for: style.id) != nil
        else { return }
        if current.isStreaming, current.activeStyleID == style.id {
            cancelStream()
            return
        }
        if let latest = current.latestVersion(styleID: style.id) {
            select(versionID: latest.id)
        } else {
            request(style, configuration: configuration)
        }
    }

    /// Runs a style, always appending another version.
    func choose(_ style: RewriteStyle, configuration: RewriteConfiguration) {
        request(style, configuration: configuration)
    }

    /// Runs the selected version's style again, appending a new version.
    ///
    /// A restored version may name a style the person has since removed, or one
    /// that cannot run right now. The version stays reviewable and the arrows
    /// still reach it; the rerun says why it cannot ask again instead of
    /// inventing an instruction for a style that is gone.
    func rerun(configuration: RewriteConfiguration) {
        guard let current = card,
              current.canDeliverSelected,
              let styleID = current.selectedVersion.styleID
        else { return }
        guard let style = current.choices.first(where: { $0.id == styleID }) else {
            // A style the settings no longer name is gone; a style that is
            // named but cannot run right now is a different sentence.
            showNote(
                configuration.style(for: styleID) == nil
                    ? Self.unavailableStyleNote
                    : Self.unavailableNowNote
            )
            Log.shared.info("rewrite.rerun.unavailable", ["style": .string(styleID)])
            return
        }
        request(style, configuration: configuration)
    }

    /// Selects a version by id. It stops any request that was running and
    /// changes nothing outside the card.
    func select(versionID: Int) {
        guard card?.versions.contains(where: { $0.id == versionID }) == true else { return }
        cancelWork()
        settleDraft()
        card?.select(versionID: versionID)
    }

    /// Selects the version before the current one.
    func selectPrevious() {
        guard card?.canGoPrevious == true else { return }
        cancelWork()
        settleDraft()
        card?.goPrevious()
    }

    /// Selects the version after the current one.
    func selectNext() {
        guard card?.canGoNext == true else { return }
        cancelWork()
        settleDraft()
        card?.goNext()
    }

    /// Stops the stream and leaves the versions that already exist.
    func cancelStream() {
        guard card?.isStreaming == true else { return }
        cancelWork()
        card?.phase = .offered
        card?.draft = ""
        card?.draftWarning = nil
        card?.note = nil
    }

    /// Accepts a draft the check refused, as a version, without delivering it.
    func useAnyway() {
        guard let current = card,
              case .blocked(let styleID, _) = current.phase,
              let style = current.choices.first(where: { $0.id == styleID })
        else { return }
        let text = current.draft
        let warning = current.draftWarning
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(note: RewriteCard.failureNote)
            return
        }
        cancelWork()
        appendVersion(style: style, text: text, warning: warning)
    }

    /// Returns to the original without writing anything.
    func keepOriginal() {
        guard card != nil else { return }
        cancelWork()
        card?.keepOriginal()
    }

    // MARK: - Explicit delivery

    /// Copies the selected version and leaves every other one where it is.
    ///
    /// - Parameter text: the words the button was drawn against, so a click can
    ///   never copy a different version than the one it named.
    /// - Returns: whether the clipboard was written.
    @discardableResult
    func copySelected(_ text: String) -> Bool {
        guard let current = card,
              current.canDeliverSelected,
              current.selectedVersion.text == text
        else { return false }
        copyToClipboard(text)
        card?.phase = .copied(versionID: current.selectedVersion.id)
        card?.note = nil
        Log.shared.info("rewrite.version.copied", [
            "version": .int(current.selectedVersion.id),
            "style": .string(current.selectedVersion.styleID ?? "original"),
            "characters": .int(text.count),
        ])
        return true
    }

    /// Writes the selected version at the current cursor or selection.
    ///
    /// A Paste click is an explicit act, so it targets the field that is
    /// focused at that moment, not the insertion of the previous dictation. The
    /// field has to belong to the actual frontmost application, must not be
    /// Dot's own HUD, must not be secure, and must offer a sane UTF-16 range.
    /// The captured selection is re-checked immediately before the write; a
    /// caret that moved in between is not written at the stale position.
    ///
    /// There is exactly one write attempt and one read-back. Any failure (no
    /// field, wrong owner, secure field, moved selection, failed select or
    /// write, mismatched read-back) puts the version on the clipboard and says
    /// so. Nothing is retried and no phase says PASTED before the read-back
    /// confirms the words.
    ///
    /// - Parameter text: the words the button was drawn against.
    /// - Returns: whether the version was written and verified in the field.
    @discardableResult
    func pasteSelected(_ text: String) -> Bool {
        guard let current = card,
              current.canDeliverSelected,
              current.selectedVersion.text == text,
              let selected = current.versions.first(where: { $0.id == current.selectedVersion.id })
        else { return false }

        // The field is captured at the click. The selection comes from this
        // read, never from an old insertion anchor.
        guard let field = textFields.focusedField(),
              !field.isSecure,
              field.processIdentifier != ownProcessIdentifier,
              ownBundleIdentifier.isEmpty || field.bundleIdentifier != ownBundleIdentifier,
              let frontmostIdentifier = frontmost(),
              frontmostIdentifier == field.processIdentifier,
              let range = Self.insertionRange(field.selection, insertedText: text)
        else {
            fallBackToClipboard(text, version: selected, note: RewriteCard.pasteFailedNote)
            return false
        }

        // Re-read immediately before the write. The same field must still be
        // focused and the selection must not have moved under the click.
        guard let fresh = textFields.focusedField(),
              fresh.processIdentifier == field.processIdentifier,
              fresh.bundleIdentifier == field.bundleIdentifier,
              fresh.selection == field.selection,
              !fresh.isSecure,
              frontmost() == field.processIdentifier,
              textFields.isFocused(field)
        else {
            fallBackToClipboard(text, version: selected, note: RewriteCard.pasteFailedNote)
            return false
        }

        // One attempt only. A failed select or write is not retried into
        // whatever happens to hold the focus afterwards.
        guard textFields.select(range, in: field) else {
            fallBackToClipboard(text, version: selected, note: RewriteCard.pasteFailedNote)
            return false
        }
        guard textFields.setText(text, in: field) else {
            // The setter reported failure, but it may have written before it
            // did. Do not tell the person the field is unchanged.
            fallBackToClipboard(text, version: selected, note: RewriteCard.pasteUnverifiedNote)
            return false
        }
        let newRange = NSRange(location: range.location, length: text.utf16.count)
        guard textFields.text(in: newRange, of: field) == text else {
            fallBackToClipboard(text, version: selected, note: RewriteCard.pasteUnverifiedNote)
            return false
        }

        // Reading the range back selects it. Leave the caret at the end, so
        // the next keystroke appends instead of replacing the whole version.
        if !textFields.select(NSRange(location: newRange.upperBound, length: 0), in: field) {
            Log.shared.warn("rewrite.paste.caret", ["reason": .string("collapseFailed")])
        }

        card?.phase = .applied(versionID: selected.id)
        card?.note = nil
        card?.canUndo = false
        card?.deliveryDestination = applicationName(field.processIdentifier)
        Log.shared.info("rewrite.version.pastedAtCursor", [
            "version": .int(selected.id),
            "style": .string(selected.styleID ?? "original"),
            "characters": .int(text.count),
            "selection": .int(range.location),
            "selection_length": .int(range.length),
        ])
        return true
    }

    /// A UTF-16 selection that can be written without overflowing.
    ///
    /// Negative locations and lengths are impossible from AX, but a malformed
    /// answer must not reach arithmetic that would trap. The end of the current
    /// selection and the end of the inserted text both have to be representable.
    static func insertionRange(_ selection: NSRange, insertedText: String) -> NSRange? {
        guard selection.location >= 0, selection.length >= 0 else { return nil }
        let (_, selectionOverflow) = selection.location.addingReportingOverflow(selection.length)
        guard !selectionOverflow else { return nil }
        let (_, insertionOverflow) = selection.location
            .addingReportingOverflow(insertedText.utf16.count)
        guard !insertionOverflow else { return nil }
        return selection
    }

    /// Puts the transcript back through the anchor the paste used.
    ///
    /// A refusal is not an error the person has to act on: the original goes on
    /// the clipboard and the card selects it again.
    func undo() {
        guard let current = card, current.canUndo, let anchor else { return }
        cancelWork()
        switch replace(anchor: anchor, with: current.original) {
        case .replace:
            card?.phase = .offered
            card?.draft = ""
            card?.draftWarning = nil
            card?.note = nil
            card?.canUndo = false
            card?.select(versionID: 0)
        case .clipboardOnly(let reason):
            Log.shared.warn("rewrite.undo.clipboard", ["reason": .string(reason.rawValue)])
            copyToClipboard(current.original)
            card?.phase = .offered
            card?.draft = ""
            card?.draftWarning = nil
            card?.note = nil
            card?.canUndo = false
            card?.select(versionID: 0)
        }
    }

    /// Rebases the layer after an inline edit.
    ///
    /// An edit changes the words every version was built from, so the versions
    /// are cleared rather than left to be fed stale text. The card says so in
    /// one line. An edit is an explicit act, unlike copying or navigating.
    func rebaseOriginal(_ text: String) {
        guard var current = card else { return }
        cancelWork()
        anchor = nil
        nextVersionID = 1
        current.rebase(original: text)
        card = current
    }

    // MARK: - The stream

    /// Runs one request against the original, never against a previous version.
    ///
    /// The gate is asked again here rather than trusted from the chip that was
    /// drawn: a card can outlive the settings it was built under, and a request
    /// must not start for a style that is switched off, has no key, or is
    /// longer than the service accepts.
    private func request(_ style: RewriteStyle, configuration: RewriteConfiguration) {
        guard let current = card,
              configuration.style(for: style.id) != nil,
              generationChoices(for: current.original, configuration: configuration)
                  .contains(where: { $0.id == style.id })
        else { return }
        cancelWork()
        generation += 1
        let token = generation
        let takeToken = take
        sawFirstToken = false
        sawActivity = false
        streamedCharacters = 0
        // One assignment, one change: the card goes from idle to running in a
        // single step, so the HUD is told once rather than once per field.
        var running = current
        running.phase = .rewriting(styleID: style.id, title: style.title)
        running.draft = ""
        running.draftWarning = nil
        running.note = nil
        running.lastNavigation = nil
        card = running
        attempt = Task { [weak self] in
            await self?.run(
                style: style,
                text: current.original,
                token: token,
                take: takeToken
            )
        }
        watch(token: token, take: takeToken)
    }

    /// Enforces the two deadlines of a request.
    ///
    /// The first is the wait for any sign of work, so a service that reasons
    /// before it answers keeps the attempt alive and only silence fails it. The
    /// second is the whole request's budget, and it ends an attempt that is
    /// still streaming. Both report the cause and show the same note.
    private func watch(token: Int, take takeToken: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            guard let self else { return }
            let start = ContinuousClock.now
            try? await Task.sleep(for: .seconds(self.timing.firstToken))
            guard !Task.isCancelled,
                  self.generation == token,
                  self.take == takeToken
            else { return }
            guard self.sawActivity else {
                self.failDeadline(
                    reason: "first_token_timeout",
                    elapsed: ContinuousClock.now - start
                )
                return
            }
            let remaining = max(0, self.timing.total - self.timing.firstToken)
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled,
                  self.generation == token,
                  self.take == takeToken,
                  self.card?.isStreaming == true
            else { return }
            self.failDeadline(reason: "total_timeout", elapsed: ContinuousClock.now - start)
        }
    }

    /// Reports a request a deadline ended and shows the note for it.
    ///
    /// The line says which deadline fired, the style, the model, how long the
    /// request ran and how far the answer got. It never carries the text: the
    /// log is a file on disk that outlives the take.
    private func failDeadline(reason: String, elapsed: Duration) {
        Log.shared.warn("rewrite.attempt.failed", [
            "reason": .string(reason),
            "style": .string(card?.activeStyleID ?? "none"),
            "model": .string(factory.model()),
            // Milliseconds, the same readings the HUD's own timing lines write.
            "elapsed_ms": .double(elapsed / .milliseconds(1)),
            "characters": .int(streamedCharacters),
        ])
        fail(note: RewriteCard.failureNote)
    }

    /// Why an attempt produced no version.
    ///
    /// The causes are kept apart because they send the person looking in
    /// different places: Dot's own cap, the service's token ceiling, and a
    /// connection that ended without the answer's end are three different
    /// problems, and only two of them are a cut-off answer.
    enum IncompleteAnswer {
        /// Dot stopped reading at its own cap.
        case outputCap
        /// The service reported its token ceiling.
        case providerLength
        /// The service suppressed the answer.
        case contentFilter
        /// The service asked for a tool a rewrite never offers.
        case toolCalls
        /// A stop reason this build does not know.
        case unexpectedStop
        /// The stream ended without a `.done`.
        case missingStop

        /// The sentence the card shows.
        var note: String {
            switch self {
            case .outputCap, .providerLength: RewriteCard.truncationNote
            case .contentFilter, .toolCalls, .unexpectedStop, .missingStop: RewriteCard.failureNote
            }
        }

        /// The name the log line carries.
        var reason: String {
            switch self {
            case .outputCap: "client_cap"
            case .providerLength: "provider_length"
            case .contentFilter: "content_filter"
            case .toolCalls: "tool_calls"
            case .unexpectedStop: "unexpected_stop"
            case .missingStop: "missing_stop"
            }
        }

        /// The cause of an attempt with nothing to keep, or `nil` when the
        /// model finished its answer on its own.
        static func of(stop: ChatStopReason?, hitCap: Bool) -> IncompleteAnswer? {
            if hitCap { return .outputCap }
            guard let stop else { return .missingStop }
            switch stop {
            case .endTurn: return nil
            case .length: return .providerLength
            case .contentFilter: return .contentFilter
            case .toolCalls: return .toolCalls
            case .other: return .unexpectedStop
            }
        }
    }

    /// What one streaming attempt produced.
    private struct AttemptOutput {
        /// The text the attempt accumulated. A capped attempt holds the prefix
        /// it kept.
        var text: String
        /// The stop reason the service sent, when it sent one.
        var stop: ChatStopReason?
        /// Whether Dot stopped reading at its own cap.
        var hitCap: Bool
    }

    /// The highest output cap a retry may use, in characters.
    static let maximumAttemptCharacters = 16_000

    /// The cap a retry uses: twice the attempt's own cap, never above the
    /// ceiling.
    ///
    /// It is `nil` when the ceiling leaves no room to raise the cap, so a take
    /// whose first cap already reached it is not asked again under the same
    /// limit.
    static func retryLimit(after limit: Int) -> Int? {
        let doubled = limit > maximumAttemptCharacters / 2
            ? maximumAttemptCharacters
            : limit * 2
        return doubled > limit ? doubled : nil
    }

    /// Runs the attempts of one request and keeps the answer that finished.
    ///
    /// Dot's own cap is the only cause a retry can answer, so a capped attempt
    /// is asked once more with a cap twice as long before the card reports that
    /// the answer was cut off. Every other incomplete answer is final: a token
    /// ceiling, a suppression, a tool call or a stream that ended without a stop
    /// reason is not made better by reading more.
    private func run(
        style: RewriteStyle,
        text: String,
        token: Int,
        take takeToken: Int
    ) async {
        do {
            var limit = RewritePrompt.outputLimit(inputCharacters: text.count, style: style)
            var retried = false
            while true {
                guard let attempt = try await streamAttempt(
                    style: style,
                    text: text,
                    limit: limit,
                    token: token,
                    take: takeToken
                ) else { return }
                // A capped answer and an answer the service cut short are both
                // incomplete. Neither becomes a version and neither is silently
                // presented as finished.
                guard let incomplete = IncompleteAnswer.of(
                    stop: attempt.stop,
                    hitCap: attempt.hitCap
                ) else {
                    // The only answer left is one the model finished on its own.
                    finish(
                        style: style,
                        text: attempt.text,
                        token: token,
                        take: takeToken
                    )
                    return
                }
                if case .outputCap = incomplete,
                   !retried,
                   let raised = Self.retryLimit(after: limit) {
                    Log.shared.warn("rewrite.attempt.retried", [
                        "style": .string(style.id),
                        "previous_limit": .int(limit),
                        "limit": .int(raised),
                        "characters": .int(attempt.text.count),
                    ])
                    retried = true
                    limit = raised
                    continue
                }
                fail(
                    note: incomplete.note,
                    reason: incomplete.reason,
                    stop: attempt.stop,
                    style: style,
                    characters: attempt.text.count,
                    limit: limit
                )
                return
            }
        } catch {
            guard generation == token, take == takeToken, !Task.isCancelled else { return }
            fail(note: RewriteCard.failureNote)
        }
    }

    /// Streams one attempt and returns what it produced.
    ///
    /// It returns `nil` when the attempt is no longer the current one: a newer
    /// request, a new take or a gone card has already made its events stale.
    /// The cap is enforced by leaving the stream, not by leaving the switch: a
    /// `break` inside a case would go on reading a service that is still
    /// sending, and the attempt would sit there until a deadline ended it.
    private func streamAttempt(
        style: RewriteStyle,
        text: String,
        limit: Int,
        token: Int,
        take takeToken: Int
    ) async throws -> AttemptOutput? {
        try Task.checkCancellation()
        guard generation == token, take == takeToken, card != nil else { return nil }
        let provider = try await factory.makeProvider(temperature: RewritePrompt.temperature)
        guard generation == token, take == takeToken, card != nil else { return nil }
        let model = factory.model()
        Log.shared.info("rewrite.attempt.started", [
            "style": .string(style.id),
            "input": .int(text.count),
            "limit": .int(limit),
            "model": .string(model),
        ])
        var accumulated = ""
        var stop: ChatStopReason?
        var hitCap = false
        let stream = provider.stream(
            messages: RewritePrompt.messages(for: style, text: text),
            tools: [],
            model: model
        )
        streamLoop: for try await event in stream {
            try Task.checkCancellation()
            guard generation == token, take == takeToken, card != nil else { return nil }
            switch event {
            case .thinking:
                // A service that reasons before it answers is working, and it
                // has sent no word of the answer, so only the deadlines' first
                // reading changes.
                sawActivity = true
            case .textDelta(let delta):
                sawFirstToken = true
                sawActivity = true
                // An answer that ends exactly at the cap is a whole answer,
                // so only a delta that would pass it is a cut. A service
                // that stops at the cap still sends `.done(.endTurn)`.
                if accumulated.count + delta.count > limit {
                    accumulated = String((accumulated + delta).prefix(limit))
                    streamedCharacters = accumulated.count
                    hitCap = true
                    card?.appendDraft(accumulated, at: CACurrentMediaTime())
                    break streamLoop
                }
                accumulated += delta
                streamedCharacters = accumulated.count
                // The append carries the reading of the clock it landed on, so
                // the body can bring the newest words up to the card's ink
                // without a timer of its own.
                card?.appendDraft(accumulated, at: CACurrentMediaTime())
            case .done(let reason):
                stop = reason
            case .toolCall, .usage:
                continue
            }
        }
        try Task.checkCancellation()
        guard generation == token, take == takeToken else { return nil }
        return AttemptOutput(text: accumulated, stop: stop, hitCap: hitCap)
    }

    /// Checks the finished rewrite and keeps it, or asks first.
    ///
    /// The text Dot keeps is what the model wrote, trimmed: nothing is appended
    /// to it, so the faithfulness check and the version the person reads are the
    /// same text.
    private func finish(
        style: RewriteStyle,
        text: String,
        token: Int,
        take takeToken: Int
    ) {
        guard generation == token,
              take == takeToken,
              let current = card
        else { return }
        let output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            fail(note: RewriteCard.failureNote)
            return
        }
        let report = FaithfulnessCheck.check(
            original: current.original,
            rewrite: output,
            style: style
        )
        guard let error = report.firstError else {
            cancelWork()
            appendVersion(style: style, text: output, warning: report.firstWarning)
            return
        }
        card?.phase = .blocked(styleID: style.id, error: error)
        card?.draft = output
        card?.draftWarning = report.firstWarning
        card?.note = nil
    }

    private func appendVersion(style: RewriteStyle, text: String, warning: String?) {
        guard var current = card else { return }
        let id = nextVersionID
        nextVersionID += 1
        current.append(id: id, style: style, text: text, warning: warning)
        card = current
    }

    /// Clears a refused or running draft after a selection change.
    private func settleDraft() {
        guard var current = card, current.isStreaming || current.isBlocked else { return }
        current.phase = .offered
        current.draft = ""
        current.draftWarning = nil
        current.note = nil
        card = current
    }

    /// Reports why an attempt produced no version and shows the matching note.
    ///
    /// The line carries the cause, the stop reason, the length and the cap. It
    /// never carries the transcript or the rewrite: the log is a file on disk
    /// that outlives the take.
    private func fail(
        note: String,
        reason: String,
        stop: ChatStopReason?,
        style: RewriteStyle,
        characters: Int,
        limit: Int
    ) {
        Log.shared.warn("rewrite.attempt.failed", [
            "reason": .string(reason),
            "stop": .string(Self.stopName(stop)),
            "characters": .int(characters),
            "limit": .int(limit),
            "style": .string(style.id),
        ])
        fail(note: note)
    }

    /// The log's name for a stop reason, so a missing one is not a blank field.
    private static func stopName(_ stop: ChatStopReason?) -> String {
        guard let stop else { return "none" }
        switch stop {
        case .endTurn: return "endTurn"
        case .toolCalls: return "toolCalls"
        case .length: return "length"
        case .contentFilter: return "contentFilter"
        case .other(let value): return "other(\(value))"
        }
    }

    /// The sentence the card shows when a style a saved version names is gone.
    static let unavailableStyleNote = "That style is no longer available."
    /// The sentence the card shows when the style still exists but cannot run.
    static let unavailableNowNote = "Rewriting isn't available right now."

    private func fail(note: String) {
        cancelWork()
        card?.phase = .offered
        card?.draft = ""
        card?.draftWarning = nil
        showNote(note)
    }

    /// Shows one line under the body and takes it away again.
    ///
    /// It changes no phase and discards no version: it is the answer to an act
    /// that could not be carried out, not a report that an attempt failed.
    private func showNote(_ note: String) {
        card?.note = note
        let token = generation
        let takeToken = take
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.timing.failureNote ?? 3))
            guard !Task.isCancelled,
                  let self,
                  self.generation == token,
                  self.take == takeToken
            else { return }
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
        sawActivity = false
        streamedCharacters = 0
    }

    // MARK: - The write

    private func fallBackToClipboard(
        _ text: String,
        version: RewriteVersion,
        note: String
    ) {
        copyToClipboard(text)
        card?.phase = .copied(versionID: version.id)
        card?.note = note
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
    /// the version goes to the clipboard.
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
