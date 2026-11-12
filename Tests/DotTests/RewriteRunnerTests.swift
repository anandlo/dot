import AppKit
import DotCore
import Foundation
import XCTest

@testable import Dot

/// One rewrite, from a chip to the text field.
///
/// The provider and the Accessibility API are both faked: the runner's job is
/// the order of the calls and the states it reports, and neither of those needs
/// a socket or another application's window.
@MainActor
final class RewriteRunnerTests: XCTestCase {
    private let original = "Send the report to Priya by 5 pm, and don't forget the appendix."
    private let rewritten = "Send Priya the report by 5 pm; don't forget the appendix."
    private let configuration = RewriteConfiguration.default

    // Every property is lazy: each test gets its own instance, and the first
    // line of a test that touches one builds the harness on the main actor.
    private lazy var clock = MutableDate()
    private lazy var fields = FakeTextFieldAccess(document: original)
    private lazy var stream = RewriteStreamSpy(deltas: chunks(of: rewritten))
    private lazy var factory = RewriteFactorySpy(provider: stream)
    private lazy var copied: [String] = []
    private lazy var cards: [RewriteCard] = []
    private lazy var runner = makeRunner()

    private func makeRunner() -> RewriteRunner {
        let runner = RewriteRunner(
            factory: factory,
            textFields: fields,
            copy: { [weak self] text in self?.copied.append(text) },
            frontmost: { 42 },
            now: { [weak self] in self?.clock.value ?? Date() },
            timing: RewriteRunner.Timing(total: 2, firstToken: 1, failureNote: 0.2)
        )
        runner.onChange = { [weak self] card in
            if let card { self?.cards.append(card) }
        }
        return runner
    }

    private func chunks(of text: String) -> [String] {
        stride(from: 0, to: text.count, by: 4).map { offset in
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: min(4, text.count - offset))
            return String(text[start ..< end])
        }
    }

    private func begin(anchor: Bool = true, delivery: HUDDelivery = .pasted) -> Bool {
        let captured = anchor
            ? runner.captureAnchor(insertedText: original, at: clock.value)
            : nil
        return runner.begin(
            text: original,
            delivery: delivery,
            destination: "Mail",
            configuration: configuration,
            anchor: captured
        )
    }

    private func isApplied() -> Bool {
        if case .applied = runner.card?.phase { return true }
        return false
    }

    private func isCopied() -> Bool {
        if case .copied = runner.card?.phase { return true }
        return false
    }

    private func isBlocked() -> Bool {
        if case .blocked = runner.card?.phase { return true }
        return false
    }

    private func isOffered() -> Bool {
        if case .offered = runner.card?.phase { return true }
        return false
    }

    private func wait(
        _ predicate: @escaping () -> Bool,
        seconds: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    // MARK: - Offering

    func testTheChipsAreOfferedForAnEligibleTake() {
        XCTAssertTrue(begin())
        XCTAssertEqual(runner.card?.phase, .offered)
        XCTAssertEqual(runner.card?.original, original)
        XCTAssertEqual(runner.card?.choices.map(\.title), [
            "Agent prompt", "Concise", "Plain English", "Casual", "Formal",
        ])
        XCTAssertEqual(runner.card?.destination, "Mail")
        XCTAssertEqual(cards.count, 1)
    }

    func testASecureFieldGetsNoChips() {
        fields.secure = true
        XCTAssertTrue(runner.captureAnchor(insertedText: original, at: clock.value) == nil)
        XCTAssertFalse(begin())
        XCTAssertNil(runner.card)
        XCTAssertTrue(cards.isEmpty, "no card was ever offered")
    }

    func testNoKeyMeansNoChipsAndNoAccessibilityCall() {
        factory.keyPresent = false
        // This is the app's order: the offer is decided before the anchor is
        // captured, so an ineligible take never reads the Accessibility API.
        let offered = runner.offersRewrite(
            for: original,
            delivery: .pasted,
            configuration: configuration
        )
        XCTAssertFalse(offered)
        XCTAssertTrue(fields.calls.isEmpty, "the text field was touched: \(fields.calls)")
        XCTAssertFalse(begin(anchor: false))
        XCTAssertNil(runner.card)
    }

    func testAnIneligibleServiceIsNotOffered() {
        XCTAssertTrue(runner.offersRewrite(for: original, delivery: .pasted, configuration: configuration))
        factory.keyPresent = false
        XCTAssertFalse(runner.offersRewrite(for: original, delivery: .pasted, configuration: configuration))
        factory.keyPresent = true
        factory.providerID = "ollama"
        XCTAssertTrue(runner.offersRewrite(for: original, delivery: .copied, configuration: configuration))
    }

    func testALocalServiceNeedsNoKeyForTheChips() {
        factory.providerID = "lmstudio"
        factory.keyPresent = false
        XCTAssertTrue(runner.offersRewrite(for: original, delivery: .pasted, configuration: configuration))
    }

    func testAnAssistantThatWasNeverSetUpOffersNoChips() {
        // The key is there, because the speech provider stored it; the
        // assistant was never chosen, so there is nothing to rewrite with.
        factory.isSetUp = false
        XCTAssertFalse(runner.offersRewrite(for: original, delivery: .pasted, configuration: configuration))
        XCTAssertTrue(fields.calls.isEmpty, "the text field was touched: \(fields.calls)")
        XCTAssertFalse(begin(anchor: false))
        XCTAssertNil(runner.card)
    }

    // MARK: - Streaming

    func testTheRewriteStreamsIntoTheCardInOrder() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        _ = await wait { self.runner.card?.rewrite == self.rewritten }
        let streamed = cards.map(\.rewrite).filter { !$0.isEmpty }
        XCTAssertGreaterThan(streamed.count, 2, "the card never showed a partial rewrite")
        for index in 1 ..< streamed.count {
            XCTAssertTrue(
                streamed[index].hasPrefix(streamed[index - 1]),
                "the card did not receive the deltas in order: \(streamed)"
            )
        }
        XCTAssertEqual(streamed.last, rewritten)
        let applied = await wait { self.isApplied() }
        XCTAssertTrue(applied)
    }

    func testTheRequestCarriesNoToolsAndWrapsTheTranscript() async {
        XCTAssertTrue(begin())
        runner.choose(.formal, configuration: configuration)
        _ = await wait { self.isApplied() }
        XCTAssertEqual(stream.callCount, 1)
        XCTAssertEqual(stream.lastTools, [], "a rewrite may never call a tool")
        let messages = stream.lastMessages ?? []
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertTrue(messages.first?.text.contains(RewriteStyleID.formal.template) == true)
        XCTAssertTrue(messages.first?.text.contains(RewritePrompt.dataSentence) == true)
        XCTAssertEqual(messages.last?.role, .user)
        XCTAssertEqual(messages.last?.text, "<transcript>\n" + original + "\n</transcript>")
    }

    func testTheTemperatureIsTheRewriteTemperature() async {
        XCTAssertTrue(begin())
        runner.choose(.plain, configuration: configuration)
        _ = await wait { self.isApplied() }
        XCTAssertEqual(factory.temperatures, [0.2])
        XCTAssertEqual(stream.lastModel, factory.modelName)
    }
}

extension RewriteRunnerTests {
    // MARK: - The write

    func testTheRewriteReplacesTheTextAndOffersUndo() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        let applied = await wait { self.isApplied() }
        XCTAssertTrue(applied, "phase was \(String(describing: runner.card?.phase))")
        XCTAssertEqual(fields.document, rewritten)
        XCTAssertEqual(fields.writes, [rewritten])
        XCTAssertEqual(Array(fields.calls.suffix(3)), ["select", "setText", "read"])
        XCTAssertEqual(
            fields.selections.last,
            NSRange(location: 0, length: (original as NSString).length),
            "the range that was selected is the one the transcript is in"
        )
        XCTAssertEqual(runner.card?.canUndo, true)
        XCTAssertNil(runner.card?.note)
        XCTAssertEqual(copied, [], "a rewrite that was written is not also copied")
    }

    func testUndoRestoresTheOriginal() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        let applied = await wait { self.isApplied() }
        XCTAssertTrue(applied)
        runner.undo()
        XCTAssertEqual(fields.document, original)
        XCTAssertEqual(fields.writes, [rewritten, original])
        XCTAssertTrue(isOffered())
        XCTAssertEqual(runner.card?.canUndo, false)
    }

    func testTheSecondChipCancelsTheFirstWithinTwoHundredMilliseconds() async {
        let slow = RewriteStreamSpy(
            deltas: chunks(of: rewritten),
            milliseconds: 40,
            holdsOpen: true
        )
        let localFactory = RewriteFactorySpy(provider: slow)
        let localFields = FakeTextFieldAccess(document: original)
        let local = RewriteRunner(
            factory: localFactory,
            textFields: localFields,
            copy: { _ in },
            frontmost: { 42 },
            now: { self.clock.value },
            timing: RewriteRunner.Timing(total: 2, firstToken: 1, failureNote: 0.2)
        )
        let anchor = local.captureAnchor(insertedText: original, at: clock.value)
        XCTAssertTrue(local.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: configuration,
            anchor: anchor
        ))
        local.choose(.concise, configuration: configuration)
        let started = await wait {
            slow.callCount == 1 && (local.card?.rewrite.isEmpty == false)
        }
        XCTAssertTrue(started, "the first stream never produced a token")
        let switchedAt = Date()
        local.choose(.formal, configuration: configuration)
        let stopped = await wait { !slow.stopped.isEmpty }
        XCTAssertTrue(stopped, "the first stream was never cancelled")
        guard let first = slow.stopped.first else { return }
        XCTAssertLessThan(
            first.0.timeIntervalSince(switchedAt),
            0.2,
            "the first stream took \(first.0.timeIntervalSince(switchedAt)) s to stop"
        )
        if case .cancelled = first.1 {} else {
            XCTFail("the first stream ended with \(first.1)")
        }
        let restarted = await wait { slow.callCount == 2 }
        XCTAssertTrue(restarted, "the second chip never asked the service")
        XCTAssertEqual(localFields.writes, [], "the cancelled stream wrote without being asked")
    }

    func testAFaithfulnessErrorBlocksTheApplyAndUseAnywayApplies() async {
        let insecure = "Send Priya the report; don't forget the appendix."
        let bad = RewriteStreamSpy(deltas: chunks(of: insecure))
        let localFactory = RewriteFactorySpy(provider: bad)
        let localFields = FakeTextFieldAccess(document: original)
        let local = RewriteRunner(
            factory: localFactory,
            textFields: localFields,
            copy: { _ in },
            frontmost: { 42 },
            now: { self.clock.value },
            timing: RewriteRunner.Timing(total: 2, firstToken: 1, failureNote: 0.2)
        )
        let anchor = local.captureAnchor(insertedText: original, at: clock.value)
        XCTAssertTrue(local.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: configuration,
            anchor: anchor
        ))
        local.choose(.concise, configuration: configuration)
        let blocked = await wait {
            if case .blocked = local.card?.phase { return true }
            return false
        }
        XCTAssertTrue(blocked)
        XCTAssertEqual(local.card?.rewrite, insecure)
        XCTAssertEqual(localFields.writes, [], "a blocked rewrite wrote without being asked")
        local.useAnyway()
        XCTAssertEqual(localFields.writes, [insecure])
        if case .applied = local.card?.phase {} else {
            XCTFail("Use anyway did not apply: \(String(describing: local.card?.phase))")
        }
    }

    func testKeepOriginalReturnsToTheChips() async {
        let insecure = "Send Priya the report; don't forget the appendix."
        let bad = RewriteStreamSpy(deltas: chunks(of: insecure))
        let localFactory = RewriteFactorySpy(provider: bad)
        let localFields = FakeTextFieldAccess(document: original)
        let local = RewriteRunner(
            factory: localFactory,
            textFields: localFields,
            copy: { _ in },
            frontmost: { 42 },
            now: { self.clock.value },
            timing: RewriteRunner.Timing(total: 2, firstToken: 1, failureNote: 0.2)
        )
        let anchor = local.captureAnchor(insertedText: original, at: clock.value)
        _ = local.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: configuration,
            anchor: anchor
        )
        local.choose(.concise, configuration: configuration)
        _ = await wait {
            if case .blocked = local.card?.phase { return true }
            return false
        }
        local.keepOriginal()
        XCTAssertEqual(local.card?.rewrite, "")
        XCTAssertNil(local.card?.warning)
        XCTAssertEqual(localFields.writes, [])
        if case .offered = local.card?.phase {} else {
            XCTFail("Keep original did not return to the chips")
        }
    }
}

extension RewriteRunnerTests {
    // MARK: - Refusals

    func testAReadBackMismatchRetriesOnceAndThenCopies() async {
        fields.readBackScript = ["garbage", nil, "garbage"]
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        let copiedOut = await wait { self.isCopied() }
        XCTAssertTrue(copiedOut, "phase was \(String(describing: runner.card?.phase))")
        XCTAssertEqual(fields.writes.count, 2, "one write and one retry")
        XCTAssertEqual(fields.document, rewritten, "the retry left the text in place")
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(runner.card?.note, RewriteCard.clipboardNote)
        XCTAssertEqual(runner.card?.canUndo, false)
    }

    func testAReadBackMismatchThatClearsOnTheRetryIsApplied() async {
        fields.readBackScript = ["garbage", nil, nil]
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        let applied = await wait { self.isApplied() }
        XCTAssertTrue(applied, "phase was \(String(describing: runner.card?.phase))")
        XCTAssertEqual(fields.writes.count, 2)
        XCTAssertEqual(copied, [])
    }

    func testAFieldThatIsNoLongerFocusedCopiesTheRewrite() async {
        XCTAssertTrue(begin())
        fields.focused = false
        runner.choose(.concise, configuration: configuration)
        let copiedOut = await wait { self.isCopied() }
        XCTAssertTrue(copiedOut)
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [rewritten])
    }

    func testAnAnchorOlderThanTwentySecondsCopiesTheRewrite() async {
        XCTAssertTrue(begin())
        clock.value = clock.value.addingTimeInterval(25)
        runner.choose(.concise, configuration: configuration)
        let copiedOut = await wait { self.isCopied() }
        XCTAssertTrue(copiedOut)
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [rewritten])
    }

    func testTheTextAtTheRangeChangingCopiesTheRewrite() async {
        XCTAssertTrue(begin())
        fields.document = "Something else entirely."
        runner.choose(.concise, configuration: configuration)
        let copiedOut = await wait { self.isCopied() }
        XCTAssertTrue(copiedOut)
        XCTAssertEqual(fields.writes, [])
    }

    func testACopiedTakeWritesTheClipboardWithNoAccessibility() async {
        XCTAssertTrue(begin(anchor: false, delivery: .copied))
        runner.choose(.formal, configuration: configuration)
        let copiedOut = await wait { self.isCopied() }
        XCTAssertTrue(copiedOut)
        XCTAssertTrue(fields.calls.isEmpty, "a copied take touched the text field: \(fields.calls)")
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(runner.card?.note, RewriteCard.clipboardNote)
    }

    func testAFailureReturnsToTheChipsWithANoteThatExpires() async {
        let failing = RewriteStreamSpy(deltas: [], error: ProviderError.unavailable("no service"))
        let localFactory = RewriteFactorySpy(provider: failing)
        let localFields = FakeTextFieldAccess(document: original)
        let local = RewriteRunner(
            factory: localFactory,
            textFields: localFields,
            copy: { _ in },
            frontmost: { 42 },
            now: { self.clock.value },
            timing: RewriteRunner.Timing(total: 2, firstToken: 1, failureNote: 0.15)
        )
        let anchor = local.captureAnchor(insertedText: original, at: clock.value)
        _ = local.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: configuration,
            anchor: anchor
        )
        local.choose(.concise, configuration: configuration)
        let failed = await wait { local.card?.note == RewriteCard.failureNote }
        XCTAssertTrue(failed, "phase was \(String(describing: local.card?.phase))")
        if case .offered = local.card?.phase {} else {
            XCTFail("a failed rewrite did not return to the chips")
        }
        let cleared = await wait { local.card?.note == nil }
        XCTAssertTrue(cleared, "the failure note never went away")
        XCTAssertEqual(localFields.writes, [])
    }

    func testAProviderThatNeverAnswersTimesOut() async {
        let mute = RewriteStreamSpy(deltas: [], holdsOpen: true)
        let localFactory = RewriteFactorySpy(provider: mute)
        let localFields = FakeTextFieldAccess(document: original)
        let local = RewriteRunner(
            factory: localFactory,
            textFields: localFields,
            copy: { _ in },
            frontmost: { 42 },
            now: { self.clock.value },
            timing: RewriteRunner.Timing(total: 5, firstToken: 0.15, failureNote: 0.15)
        )
        let anchor = local.captureAnchor(insertedText: original, at: clock.value)
        _ = local.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: configuration,
            anchor: anchor
        )
        local.choose(.concise, configuration: configuration)
        let failed = await wait { local.card?.note == RewriteCard.failureNote }
        XCTAssertTrue(failed, "the six second first-token deadline did not fire")
        XCTAssertEqual(localFields.writes, [])
    }

    func testCancelDuringTheStreamAppliesNothing() async {
        let slow = RewriteStreamSpy(deltas: chunks(of: rewritten), milliseconds: 20, holdsOpen: true)
        let localFactory = RewriteFactorySpy(provider: slow)
        let localFields = FakeTextFieldAccess(document: original)
        let local = RewriteRunner(
            factory: localFactory,
            textFields: localFields,
            copy: { _ in },
            frontmost: { 42 },
            now: { self.clock.value },
            timing: RewriteRunner.Timing(total: 2, firstToken: 1, failureNote: 0.2)
        )
        let anchor = local.captureAnchor(insertedText: original, at: clock.value)
        _ = local.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: configuration,
            anchor: anchor
        )
        local.choose(.concise, configuration: configuration)
        _ = await wait { local.card?.rewrite.isEmpty == false }
        local.cancelStream()
        if case .offered = local.card?.phase {} else {
            XCTFail("cancelling did not return to the chips")
        }
        XCTAssertEqual(local.card?.rewrite, "")
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(localFields.writes, [], "a cancelled rewrite wrote to the field")
        XCTAssertEqual(local.card?.rewrite, "")
    }

    func testASecondStyleRewritesTheOriginalNotTheRewrite() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        _ = await wait { self.isApplied() }
        runner.choose(.formal, configuration: configuration)
        _ = await wait { self.isApplied() && self.stream.callCount == 2 }
        XCTAssertEqual(stream.callCount, 2)
        let second = stream.lastMessages ?? []
        XCTAssertEqual(second.last?.text, "<transcript>\n" + original + "\n</transcript>")
        XCTAssertTrue(second.first?.text.contains(RewriteStyleID.formal.template) == true)
    }
}

extension RewriteRunnerTests {
    func testTheStreamStopsAtTheOutputCap() async {
        let long = RewriteStreamSpy(
            deltas: Array(repeating: "abcdefgh", count: 120)
        )
        let localFactory = RewriteFactorySpy(provider: long)
        let localFields = FakeTextFieldAccess(document: original)
        let local = RewriteRunner(
            factory: localFactory,
            textFields: localFields,
            copy: { _ in },
            frontmost: { 42 },
            now: { self.clock.value },
            timing: RewriteRunner.Timing(total: 3, firstToken: 1, failureNote: 0.2)
        )
        let anchor = local.captureAnchor(insertedText: original, at: clock.value)
        _ = local.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: configuration,
            anchor: anchor
        )
        local.choose(.plain, configuration: configuration)
        let capped = await wait { local.card?.rewrite.count == 400 }
        XCTAssertTrue(capped, "the rewrite was \(local.card?.rewrite.count ?? 0) characters")
        let limit = RewritePrompt.outputLimit(inputCharacters: original.count)
        XCTAssertEqual(limit, 400)
        // A rewrite that does not finish is not applied, whatever its length.
        _ = await wait { self.isBlocked() || self.isCopied() }
        XCTAssertEqual(localFields.writes, [])
    }
}

extension RewriteRunnerTests {
    // MARK: - The working rules

    /// A runner whose stream answers with `text` and whose field holds the
    /// original. Each call builds its own, so the rules tests do not share the
    /// outer harness's stream.
    private func makeLocalRunner(
        answering text: String
    ) -> (runner: RewriteRunner, fields: FakeTextFieldAccess) {
        let stream = RewriteStreamSpy(deltas: chunks(of: text))
        let factory = RewriteFactorySpy(provider: stream)
        let fields = FakeTextFieldAccess(document: original)
        let runner = RewriteRunner(
            factory: factory,
            textFields: fields,
            copy: { _ in },
            frontmost: { 42 },
            now: { self.clock.value },
            timing: RewriteRunner.Timing(total: 2, firstToken: 1, failureNote: 0.2)
        )
        let anchor = runner.captureAnchor(insertedText: original, at: clock.value)
        _ = runner.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: configuration,
            anchor: anchor
        )
        return (runner, fields)
    }

    func testThePromptStyleWritesTheRulesAfterTheModelOutput() async {
        let local = makeLocalRunner(answering: original)
        local.runner.choose(.prompt, configuration: configuration)
        let applied = await wait {
            if case .applied = local.runner.card?.phase { return true }
            return false
        }
        XCTAssertTrue(applied, "phase was \(String(describing: local.runner.card?.phase))")
        let expected = original + "\n\n" + RewriteConfiguration.defaultWorkingRules
        XCTAssertEqual(local.fields.document, expected)
        XCTAssertEqual(local.runner.card?.rewrite, expected, "the card shows what was written")
        XCTAssertEqual(local.fields.writes, [expected])
    }

    func testTheRulesAreNotWrittenForAnotherStyle() async {
        let local = makeLocalRunner(answering: rewritten)
        local.runner.choose(.concise, configuration: configuration)
        let applied = await wait {
            if case .applied = local.runner.card?.phase { return true }
            return false
        }
        XCTAssertTrue(applied, "phase was \(String(describing: local.runner.card?.phase))")
        XCTAssertEqual(local.fields.document, rewritten)
        XCTAssertFalse(local.fields.document.contains("## Working rules"))
    }

    func testTheRulesAreNotWrittenWhenTheSwitchIsOff() async {
        var off = configuration
        off.workingRulesEnabled = false
        let local = makeLocalRunner(answering: original)
        local.runner.choose(.prompt, configuration: off)
        let applied = await wait {
            if case .applied = local.runner.card?.phase { return true }
            return false
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(local.fields.document, original, "the prompt style alone was written")
    }

    func testTheRulesAreNotWrittenWhenTheFieldIsEmpty() async {
        var empty = configuration
        empty.workingRules = ""
        let local = makeLocalRunner(answering: original)
        local.runner.choose(.prompt, configuration: empty)
        let applied = await wait {
            if case .applied = local.runner.card?.phase { return true }
            return false
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(local.fields.document, original)
    }

    /// The check reads the model's output, not the text Dot writes.
    ///
    /// The output here is the transcript, which is inside the prompt style's
    /// 0.8 to 3.0 band. The rules would take the text far past 3.0, so a check
    /// that saw them would raise the length warning.
    func testTheLengthCheckReadsTheOutputWithoutTheRules() async {
        let local = makeLocalRunner(answering: original)
        local.runner.choose(.prompt, configuration: configuration)
        let applied = await wait {
            if case .applied = local.runner.card?.phase { return true }
            return false
        }
        XCTAssertTrue(applied)
        XCTAssertNil(
            local.runner.card?.warning,
            "the rules were counted against the length band: \(String(describing: local.runner.card?.warning))"
        )
        let ratio = Double(local.fields.document.count) / Double(original.count)
        XCTAssertGreaterThan(ratio, 3.0, "the rules are long enough to break the band")
    }
}
