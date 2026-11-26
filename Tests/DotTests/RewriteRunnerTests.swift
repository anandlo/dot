import AppKit
import DotCore
import Foundation
import XCTest

@testable import Dot

/// Versions, not one rewrite.
///
/// The provider and the Accessibility API are both faked: the runner's job is
/// the order of the calls, the versions it keeps and the states it reports, and
/// none of that needs a socket or another application's window.
@MainActor
final class RewriteRunnerTests: XCTestCase {
    private let original = "Send the report to Priya by 5 pm, and don't forget the appendix."
    private let rewritten = "Send Priya the report by 5 pm; don't forget the appendix."
    private let formal = "Please send the report to Priya by 5 pm; do not forget the appendix."
    private let configuration = RewriteConfiguration.default

    private lazy var clock = MutableDate()
    private lazy var fields = FakeTextFieldAccess(document: original)
    private lazy var stream = RewriteStreamSpy(deltas: chunks(of: rewritten))
    private lazy var factory = RewriteFactorySpy(provider: stream)
    private lazy var copied: [String] = []
    private lazy var cards: [RewriteCard] = []
    private lazy var runner = makeRunner()

    private func makeRunner(
        factory: (any RewriteProviderFactory)? = nil,
        fields: FakeTextFieldAccess? = nil,
        frontmost: @escaping () -> Int32? = { 42 },
        timing: RewriteRunner.Timing = RewriteRunner.Timing(total: 2, firstToken: 1, failureNote: 0.2),
        ownProcessIdentifier: Int32 = 1_000_000,
        ownBundleIdentifier: String = "com.example.dot",
        applicationName: @escaping (Int32) -> String? = { _ in "Mail" }
    ) -> RewriteRunner {
        let runner = RewriteRunner(
            factory: factory ?? self.factory,
            textFields: fields ?? self.fields,
            copy: { [weak self] text in self?.copied.append(text) },
            frontmost: frontmost,
            now: { [weak self] in self?.clock.value ?? Date() },
            timing: timing,
            ownProcessIdentifier: ownProcessIdentifier,
            ownBundleIdentifier: ownBundleIdentifier,
            applicationName: applicationName
        )
        runner.onChange = { [weak self] card in
            if let card { self?.cards.append(card) }
        }
        return runner
    }

    private func chunks(of text: String, size: Int = 4) -> [String] {
        stride(from: 0, to: text.count, by: size).map { offset in
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: min(size, text.count - offset))
            return String(text[start ..< end])
        }
    }

    private func begin(
        runner: RewriteRunner? = nil,
        text: String? = nil,
        anchor: Bool = true,
        delivery: HUDDelivery = .pasted,
        at takenAt: Date? = nil
    ) -> Bool {
        let target = runner ?? self.runner
        let source = text ?? original
        let captured = anchor
            ? target.captureAnchor(insertedText: source, at: clock.value)
            : nil
        return target.begin(
            text: source,
            delivery: delivery,
            destination: "Mail",
            configuration: configuration,
            anchor: captured,
            at: takenAt
        )
    }

    private func generated(_ runner: RewriteRunner? = nil) -> Bool {
        (runner ?? self.runner).card.map { card in
            card.versions.contains { !$0.isOriginal }
        } ?? false
    }

    /// Waits for the runner's main-actor task, yielding the actor so it runs.
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

    /// Asserts that a condition becomes true after the runner's task runs.
    private func expectTrue(
        _ predicate: @escaping () -> Bool,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let held = await wait(predicate)
        XCTAssertTrue(held, message, file: file, line: line)
    }

    private func isBlocked(_ runner: RewriteRunner? = nil) -> Bool {
        (runner ?? self.runner).card?.isBlocked == true
    }

    // MARK: - The day a rewrite is filed under

    /// A sentence said again on another day has its rewrite filed under the day
    /// it was said again.
    ///
    /// The history keeps the first date it saw for a sentence, so a lookup there
    /// would file the second day's rewrite under the first day, and the first
    /// day's file would change under a person reading it.
    func testARewriteIsFiledUnderTheDeliveryThatProducedIt() async throws {
        let dayOne = utc(2026, 11, 16, 9, 0)
        let dayFive = utc(2026, 11, 20, 9, 0)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let calendar = fixedUTC()
        let archive = TranscriptArchive(calendar: { calendar }, now: { Date() })
        let dayOneFile = folder.appendingPathComponent("2026-11-16.md")

        try await archive.recordTake("Sounds good.", at: dayOne, folder: folder)
        let firstDay = try Data(contentsOf: dayOneFile)

        XCTAssertTrue(begin(text: "Sounds good.", at: dayFive))
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }

        let record = try XCTUnwrap(runner.card?.archiveRecord)
        XCTAssertEqual(record.takenAt, dayFive, "the card did not carry this delivery's instant")
        try await archive.recordTake(record.text, at: record.takenAt, folder: folder)
        try await archive.recordVersions(
            of: record.text,
            takenAt: record.takenAt,
            versions: record.versions,
            folder: folder
        )

        let fifthDay = try String(
            contentsOf: folder.appendingPathComponent("2026-11-20.md"),
            encoding: .utf8
        )
        XCTAssertTrue(fifthDay.contains("### Concise"), fifthDay)
        XCTAssertEqual(try Data(contentsOf: dayOneFile), firstDay, "day 1's file changed")
    }

    private func fixedUTC() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = TimeZone(secondsFromGMT: 0) { calendar.timeZone = timeZone }
        return calendar
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        let calendar = fixedUTC()
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? Date()
    }

    // MARK: - Offering

    func testTheChipsAreOfferedForAnEligibleTake() {
        XCTAssertTrue(begin())
        XCTAssertEqual(runner.card?.phase, .offered)
        XCTAssertEqual(runner.card?.original, original)
        XCTAssertEqual(runner.card?.versions.count, 1)
        XCTAssertEqual(runner.card?.selectedVersion, RewriteVersion.original(text: original))
        XCTAssertEqual(runner.card?.choices.map(\.title), [
            "Agent prompt", "Concise", "Professional", "Casual", "Gen Z",
        ])
        XCTAssertEqual(runner.card?.destination, "Mail")
        XCTAssertEqual(cards.count, 1)
    }

    func testAShortDictationGetsTheStyleControls() {
        XCTAssertTrue(begin(text: "Send it."))
        XCTAssertEqual(runner.card?.choices.count, RewriteStyle.builtIns.count)
        XCTAssertTrue(runner.card?.showsChips == true)
        XCTAssertEqual(runner.card?.selectedVersion.isOriginal, true)
    }

    /// A long dictation, below the 3,000 character cap, still gets the controls.
    func testALongDictationBelowTheCapGetsTheStyleControls() {
        let long = String(repeating: "Words said in a meeting. ", count: 100)
        XCTAssertLessThan(long.count, RewriteOffer.maximumInputCharacters)
        XCTAssertTrue(begin(text: long))
        XCTAssertEqual(runner.card?.original, long)
        XCTAssertEqual(runner.card?.choices.count, RewriteStyle.builtIns.count)
        XCTAssertTrue(runner.card?.showsChips == true)
    }

    /// The cap is the only length gate that can explain a missing row.
    func testATranscriptOverTheCapGetsNoControls() {
        let tooLong = String(repeating: "a", count: RewriteOffer.maximumInputCharacters + 1)
        XCTAssertFalse(begin(text: tooLong))
        XCTAssertNil(runner.card)
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

    func testAnAssistantThatWasNeverSetUpOffersNoChips() {
        factory.isSetUp = false
        XCTAssertFalse(runner.offersRewrite(
            for: original,
            delivery: .pasted,
            configuration: configuration
        ))
        XCTAssertFalse(begin(anchor: false))
        XCTAssertNil(runner.card)
    }

    func testTheRewriteSwitchTurnsTheChipsOff() {
        var off = configuration
        off.enabled = false
        XCTAssertFalse(runner.offersRewrite(for: original, delivery: .pasted, configuration: off))
        XCTAssertFalse(runner.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: off,
            anchor: nil
        ))
        XCTAssertNil(runner.card)
    }

    // MARK: - Streaming

    func testTheDraftStreamsIntoTheCardInOrder() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        _ = await wait { self.runner.card?.draft == self.rewritten }
        let streamed = cards.map(\.draft).filter { !$0.isEmpty }
        XCTAssertGreaterThan(streamed.count, 2, "the card never showed a partial rewrite")
        for index in streamed.indices.dropFirst() {
            XCTAssertTrue(
                streamed[index].hasPrefix(streamed[index - 1]),
                "the card did not receive the deltas in order: \(streamed)"
            )
        }
        XCTAssertEqual(streamed.last, rewritten)
        await expectTrue { self.generated() }
    }

    func testGeneratingNeverWritesOrCopies() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        XCTAssertEqual(fields.writes, [], "a generated version wrote to the field")
        XCTAssertEqual(copied, [], "a generated version touched the clipboard")
        XCTAssertEqual(runner.card?.versions.count, 2)
        XCTAssertTrue(runner.card?.selectedVersion.isOriginal == false)
    }

    func testTheRequestCarriesNoToolsAndWrapsTheTranscript() async {
        XCTAssertTrue(begin())
        runner.choose(.formal, configuration: configuration)
        await expectTrue { self.generated() }
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
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        XCTAssertEqual(factory.temperatures, [0.2])
        XCTAssertEqual(stream.lastModel, factory.modelName)
    }

    // MARK: - Versions

    func testASecondStyleReceivesTheSameOriginal() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        runner.choose(.formal, configuration: configuration)
        await expectTrue { self.runner.card?.versions.count == 3 }
        XCTAssertEqual(factory.makeCount, 2)
        let messages = stream.lastMessages ?? []
        XCTAssertEqual(
            messages.last?.text,
            "<transcript>\n" + original + "\n</transcript>",
            "the second request did not receive the original"
        )
        XCTAssertEqual(runner.card?.versions.map(\.id), [0, 1, 2])
        XCTAssertEqual(runner.card?.versions.map(\.title), ["Original", "Concise", "Professional"])
        XCTAssertEqual(runner.card?.selectedVersion.title, "Professional")
    }

    func testBothResultsAreRetainedInOrder() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        runner.choose(.formal, configuration: configuration)
        await expectTrue { self.runner.card?.versions.count == 3 }
        XCTAssertEqual(runner.card?.versions.map(\.text), [original, rewritten, rewritten])
        XCTAssertEqual(runner.card?.versions.map(\.id), [0, 1, 2])
        XCTAssertEqual(runner.card?.selectedIndex, 2)
    }

    func testRepeatSameStyleKeepsDistinctVersions() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.runner.card?.versions.count == 2 }
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.runner.card?.versions.count == 3 }
        let versions = runner.card?.versions ?? []
        XCTAssertEqual(versions.map(\.id), [0, 1, 2])
        XCTAssertEqual(versions.filter { $0.styleID == "concise" }.map(\.ordinal), [1, 2])
        XCTAssertEqual(versions.last?.label, "Concise 2")
        XCTAssertEqual(stream.callCount, 2, "the repeat did not ask the service again")
    }

    func testSelectingAnExistingStyleDoesNotRegenerate() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        let calls = stream.callCount
        runner.selectStyle(.concise, configuration: configuration)
        XCTAssertEqual(stream.callCount, calls, "selecting an existing style asked again")
        XCTAssertEqual(runner.card?.selectedVersion.id, 1)
        XCTAssertEqual(runner.card?.versions.count, 2)
    }

    func testSelectingAStyleThatNeverRanStartsOneRequest() async {
        XCTAssertTrue(begin())
        runner.selectStyle(.formal, configuration: configuration)
        await expectTrue { self.generated() }
        XCTAssertEqual(stream.callCount, 1)
        XCTAssertEqual(runner.card?.selectedVersion.styleID, "formal")
    }

    func testRerunAppendsAnotherVersionOfTheSelectedStyle() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        runner.rerun(configuration: configuration)
        await expectTrue { self.runner.card?.versions.count == 3 }
        XCTAssertEqual(stream.callCount, 2)
        XCTAssertEqual(runner.card?.versions.last?.styleID, "concise")
        XCTAssertEqual(runner.card?.versions.last?.ordinal, 2)
    }

    func testNavigationNeverRegeneratesAndStopsAtTheEnds() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        XCTAssertEqual(runner.card?.selectedVersion.id, 1)
        XCTAssertFalse(runner.card?.canGoNext == true)
        runner.selectNext()
        XCTAssertEqual(runner.card?.selectedVersion.id, 1, "next moved past the last version")
        runner.selectPrevious()
        XCTAssertEqual(runner.card?.selectedVersion.id, 0)
        runner.selectPrevious()
        XCTAssertEqual(runner.card?.selectedVersion.id, 0, "previous moved past the original")
        runner.selectNext()
        XCTAssertEqual(runner.card?.selectedVersion.id, 1)
        XCTAssertEqual(stream.callCount, 1, "navigation asked the service again")
    }

    func testSelectingAVersionDoesNotWriteOrCopy() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        runner.select(versionID: 1)
        runner.selectPrevious()
        runner.selectNext()
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [])
        XCTAssertEqual(runner.card?.versions.count, 2)
    }

    // MARK: - Delivery

    func testCopySelectedCopiesTheChosenVersionAndKeepsTheCard() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertTrue(runner.copySelected(text))
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(fields.writes, [], "Copy wrote to the field")
        XCTAssertEqual(runner.card?.versions.count, 2)
        XCTAssertEqual(runner.card?.selectedVersion.id, 1)
        if case .copied(let id) = runner.card?.phase {
            XCTAssertEqual(id, 1)
        } else {
            XCTFail("phase was \(String(describing: runner.card?.phase))")
        }
    }

    func testCopyRejectsTextThatIsNotTheSelectedVersion() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        XCTAssertFalse(runner.copySelected("Some other text"))
        XCTAssertEqual(copied, [])
    }

    func testPasteSelectedInsertsAtTheCurrentCaretNotTheOldInsertion() async {
        // The take has an anchor covering the original transcript. The caret
        // has since moved to 5; Paste must use the caret, not the old range.
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        fields.selection = NSRange(location: 5, length: 0)

        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertTrue(runner.pasteSelected(text))

        let source = original as NSString
        let expected = source.substring(to: 5) + rewritten + source.substring(from: 5)
        XCTAssertEqual(fields.document, expected)
        XCTAssertEqual(fields.writes, [rewritten])
        XCTAssertEqual(copied, [], "a successful paste also copied")
        XCTAssertEqual(runner.card?.versions.count, 2)
        XCTAssertEqual(runner.card?.canUndo, false, "a cursor paste cannot undo to unknown prior text")
        // The read-back selects the version; the caret is collapsed to its end.
        XCTAssertEqual(
            fields.selection,
            NSRange(location: 5 + rewritten.utf16.count, length: 0),
            "the next keystroke would overwrite the version"
        )
        if case .applied(let id) = runner.card?.phase {
            XCTAssertEqual(id, 1)
        } else {
            XCTFail("phase was \(String(describing: runner.card?.phase))")
        }
    }

    func testPasteUsesTheChosenVersionAtTheCursor() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.runner.card?.versions.count == 2 }
        runner.choose(.formal, configuration: configuration)
        await expectTrue { self.runner.card?.versions.count == 3 }
        runner.select(versionID: 1)
        fields.selection = NSRange(location: 0, length: (original as NSString).length)

        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertTrue(runner.pasteSelected(text))
        XCTAssertEqual(fields.document, rewritten, "the latest version was pasted instead")
        XCTAssertEqual(runner.card?.versions.map(\.text), [original, rewritten, rewritten])
        XCTAssertEqual(runner.card?.canUndo, false)
    }

    func testPasteReplacesTheCurrentSelection() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        let selection = NSRange(location: 4, length: 10)
        fields.selection = selection

        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertTrue(runner.pasteSelected(text))

        let source = original as NSString
        let expected = source.substring(to: selection.location)
            + rewritten
            + source.substring(from: selection.upperBound)
        XCTAssertEqual(fields.document, expected)
    }

    func testCopiedTakeCanPasteAtTheCursor() async {
        XCTAssertTrue(begin(anchor: false, delivery: .copied))
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        fields.selection = NSRange(location: 0, length: 0)

        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertTrue(runner.pasteSelected(text))
        XCTAssertEqual(fields.document, rewritten + original)
        XCTAssertEqual(fields.writes, [rewritten])
        XCTAssertEqual(copied, [])
    }

    func testPasteWithChangedFocusCopiesAndNeverWrites() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        fields.focused = false
        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertFalse(runner.pasteSelected(text))
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(runner.card?.note, RewriteCard.pasteFailedNote)
        if case .copied = runner.card?.phase {} else {
            XCTFail("phase was \(String(describing: runner.card?.phase))")
        }
    }

    func testPasteRejectsAFieldNotOwnedByTheFrontmostApp() async {
        let local = makeRunner(frontmost: { 99 })
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.generated(local) }
        let text = local.card?.selectedVersion.text ?? ""
        XCTAssertFalse(local.pasteSelected(text))
        XCTAssertEqual(fields.writes, [], "a version was written into a field another app owns")
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(local.card?.note, RewriteCard.pasteFailedNote)
    }

    func testExplicitPasteMayTargetAnotherAppOwnedByTheFrontmostProcess() async {
        let local = makeRunner(applicationName: { _ in "Notes" })
        fields.bundleIdentifier = "com.apple.Notes"
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.generated(local) }
        fields.selection = NSRange(location: 0, length: 0)
        let text = local.card?.selectedVersion.text ?? ""
        XCTAssertTrue(local.pasteSelected(text))
        XCTAssertEqual(fields.writes, [rewritten])
        XCTAssertEqual(local.card?.deliveryDestination, "Notes")
    }

    func testPasteRejectsDotOwnProcess() async {
        let local = makeRunner(ownProcessIdentifier: 42)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.generated(local) }
        let text = local.card?.selectedVersion.text ?? ""
        XCTAssertFalse(local.pasteSelected(text))
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [rewritten])
    }

    func testPasteRejectsASecureField() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        fields.secure = true
        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertFalse(runner.pasteSelected(text))
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(runner.card?.note, RewriteCard.pasteFailedNote)
    }

    func testPasteWithMissingFieldCopies() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        fields.hasFocusedField = false
        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertFalse(runner.pasteSelected(text))
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(runner.card?.note, RewriteCard.pasteFailedNote)
    }

    func testPasteAbortsWhenTheSelectionMovesBeforeTheWrite() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        // The click sees a caret at 0; the re-read sees it at 5.
        fields.fieldSelectionScript = [NSRange(location: 0, length: 0), NSRange(location: 5, length: 0)]
        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertFalse(runner.pasteSelected(text))
        XCTAssertEqual(fields.writes, [], "the stale selection was written")
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(runner.card?.note, RewriteCard.pasteFailedNote)
    }

    func testPasteAbortsWhenTheFrontmostApplicationChangesBeforeTheWrite() async {
        var calls = 0
        let local = makeRunner(frontmost: {
            calls += 1
            return calls == 1 ? 42 : 99
        })
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.generated(local) }
        let text = local.card?.selectedVersion.text ?? ""
        XCTAssertFalse(local.pasteSelected(text))
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(local.card?.note, RewriteCard.pasteFailedNote)
    }

    func testPasteRejectsAnOverflowingSelection() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        fields.selection = NSRange(location: Int.max, length: 1)
        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertFalse(runner.pasteSelected(text))
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [rewritten])
        XCTAssertTrue(fields.calls.allSatisfy { $0 == "focusedField" })
    }

    func testPasteWriteFailureCopiesWithUnverifiedNote() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        fields.failsSetText = true
        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertFalse(runner.pasteSelected(text))
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(runner.card?.note, RewriteCard.pasteUnverifiedNote)
        if case .copied = runner.card?.phase {} else {
            XCTFail("a failed write was reported as pasted")
        }
    }

    func testPasteReadBackMismatchCopiesWithUnverifiedNote() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        fields.readBackScript = ["garbage"]
        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertFalse(runner.pasteSelected(text))
        XCTAssertEqual(copied, [rewritten])
        XCTAssertEqual(runner.card?.note, RewriteCard.pasteUnverifiedNote)
        // The fake's read selects the range it read, as AX does. The failed
        // verification must not collapse it as if the paste were confirmed.
        XCTAssertEqual(
            fields.selection,
            NSRange(location: 0, length: rewritten.utf16.count),
            "a failed read-back was treated as a confirmed paste"
        )
        XCTAssertEqual(fields.writes, [rewritten], "the write did happen; only verification failed")
        if case .copied = runner.card?.phase {} else {
            XCTFail("an unverified write was reported as pasted")
        }
    }

    func testPasteIsRefusedWhileADraftStreams() async {
        let slow = RewriteStreamSpy(deltas: chunks(of: rewritten), milliseconds: 20, holdsOpen: true)
        let slowFactory = RewriteFactorySpy(provider: slow)
        let local = makeRunner(factory: slowFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.draft.isEmpty == false }
        let text = local.card?.selectedVersion.text ?? ""
        XCTAssertFalse(local.pasteSelected(text))
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [])
        XCTAssertTrue(local.card?.canDeliverSelected == false)
    }

    func testPasteRejectsTextThatIsNotTheSelectedVersion() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        XCTAssertFalse(runner.pasteSelected("Some other text"))
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [])
    }

    func testPastingTheOriginalAtTheCursorUsesTheCurrentSelection() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        runner.select(versionID: 0)
        fields.selection = NSRange(location: 5, length: 0)
        let text = runner.card?.selectedVersion.text ?? ""
        XCTAssertTrue(runner.pasteSelected(text))

        let source = original as NSString
        let expected = source.substring(to: 5) + original + source.substring(from: 5)
        XCTAssertEqual(fields.document, expected)
        XCTAssertEqual(runner.card?.canUndo, false)
        XCTAssertEqual(runner.card?.versions.count, 2)
    }

    // MARK: - Blocked

    func testABlockedDraftIsNotAVersionAndWritesNothing() async {
        let insecure = "Send Priya the report; don't forget the appendix."
        let bad = RewriteStreamSpy(deltas: chunks(of: insecure))
        let badFactory = RewriteFactorySpy(provider: bad)
        let local = makeRunner(factory: badFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.isBlocked(local) }
        XCTAssertEqual(local.card?.versions.count, 1, "a blocked draft became a version")
        XCTAssertEqual(local.card?.draft, insecure)
        let selected = local.card?.selectedVersion.text ?? ""
        XCTAssertFalse(local.pasteSelected(selected), "a blocked draft was pasteable")
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [])
    }

    func testUseAnywayKeepsTheDraftWithoutWriting() async {
        let insecure = "Send Priya the report; don't forget the appendix."
        let bad = RewriteStreamSpy(deltas: chunks(of: insecure))
        let badFactory = RewriteFactorySpy(provider: bad)
        let local = makeRunner(factory: badFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.isBlocked(local) }
        local.useAnyway()
        XCTAssertEqual(local.card?.versions.count, 2)
        XCTAssertEqual(local.card?.selectedVersion.text, insecure)
        XCTAssertEqual(fields.writes, [], "Use anyway wrote without an explicit Paste")
        XCTAssertEqual(copied, [])
        XCTAssertEqual(local.card?.phase, .offered)
    }

    func testKeepOriginalDiscardsTheDraftAndKeepsEveryVersion() async {
        let insecure = "Send Priya the report; don't forget the appendix."
        let bad = RewriteStreamSpy(deltas: chunks(of: insecure))
        let queueFactory = RewriteFactorySpy(provider: stream)
        queueFactory.queue = [bad]
        let local = makeRunner(factory: queueFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.generated(local) }
        local.choose(.formal, configuration: configuration)
        await expectTrue { self.isBlocked(local) }
        local.keepOriginal()
        XCTAssertEqual(local.card?.versions.count, 2, "Keep original deleted a version")
        XCTAssertEqual(local.card?.selectedVersion.isOriginal, true)
        XCTAssertEqual(local.card?.draft, "")
        XCTAssertEqual(fields.writes, [])
    }

    // MARK: - Failure and staleness

    func testProviderFailurePreservesTheVersionsAlreadyKept() async {
        let failing = RewriteStreamSpy(deltas: [], error: ProviderError.unavailable("no service"))
        let queueFactory = RewriteFactorySpy(provider: stream)
        queueFactory.queue = [failing]
        let local = makeRunner(factory: queueFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.generated(local) }
        local.choose(.formal, configuration: configuration)
        await expectTrue { local.card?.note == RewriteCard.failureNote }
        XCTAssertEqual(local.card?.versions.count, 2, "the failure removed a version")
        XCTAssertEqual(local.card?.selectedVersion.id, 1)
        XCTAssertEqual(fields.writes, [])
    }

    func testCancellingARequestPreservesTheVersionsAlreadyKept() async {
        let slow = RewriteStreamSpy(deltas: chunks(of: formal), milliseconds: 30, holdsOpen: true)
        let queueFactory = RewriteFactorySpy(provider: stream)
        queueFactory.queue = [slow]
        let local = makeRunner(factory: queueFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.generated(local) }
        local.choose(.formal, configuration: configuration)
        await expectTrue { local.card?.draft.isEmpty == false }
        local.cancelStream()
        XCTAssertEqual(local.card?.versions.count, 2)
        XCTAssertEqual(local.card?.selectedVersion.id, 1)
        XCTAssertEqual(local.card?.draft, "")
        XCTAssertEqual(fields.writes, [])
    }

    func testSelectingAnEarlierVersionStopsTheStreamAndKeepsBoth() async {
        let slow = RewriteStreamSpy(deltas: chunks(of: formal), milliseconds: 30, holdsOpen: true)
        let queueFactory = RewriteFactorySpy(provider: stream)
        queueFactory.queue = [slow]
        let local = makeRunner(factory: queueFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.generated(local) }
        local.choose(.formal, configuration: configuration)
        await expectTrue { local.card?.draft.isEmpty == false }
        local.select(versionID: 1)
        XCTAssertEqual(local.card?.versions.count, 2)
        XCTAssertEqual(local.card?.selectedVersion.id, 1)
        XCTAssertEqual(local.card?.phase, .offered)
        XCTAssertEqual(fields.writes, [])
    }

    func testANewTakeInvalidatesTheOldStream() async {
        let slow = RewriteStreamSpy(deltas: chunks(of: rewritten), milliseconds: 25, holdsOpen: true)
        let slowFactory = RewriteFactorySpy(provider: slow)
        let local = makeRunner(factory: slowFactory)
        XCTAssertTrue(begin(runner: local, text: original))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.draft.isEmpty == false }
        let second = "A different take entirely, said later in the day."
        XCTAssertTrue(begin(runner: local, text: second))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(local.card?.original, second)
        XCTAssertEqual(local.card?.versions.count, 1)
        XCTAssertEqual(local.card?.selectedVersion.isOriginal, true)
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [])
    }

    func testResetPreventsALateCompletionFromReattaching() async {
        let slow = RewriteStreamSpy(deltas: chunks(of: rewritten), milliseconds: 25, holdsOpen: true)
        let slowFactory = RewriteFactorySpy(provider: slow)
        let local = makeRunner(factory: slowFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.draft.isEmpty == false }
        local.reset()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(local.card, "a cancelled request reattached after reset")
        XCTAssertEqual(fields.writes, [])
    }

    // MARK: - Incomplete output

    func testAnAnswerAtTheOutputCapIsNotOfferedAsFinished() async {
        let long = RewriteStreamSpy(deltas: Array(repeating: "abcdefgh", count: 500))
        let longFactory = RewriteFactorySpy(provider: long)
        let local = makeRunner(factory: longFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.note == RewriteCard.truncationNote }
        XCTAssertEqual(long.callCount, 2, "the capped answer was not asked again")
        XCTAssertEqual(local.card?.versions.count, 1, "a capped answer became a version")
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [])
    }

    func testAnAnswerWithoutADoneEventIsAFailureAndNotACutOff() async {
        let unfinished = RewriteStreamSpy(deltas: chunks(of: rewritten), finishWithoutDone: true)
        let unfinishedFactory = RewriteFactorySpy(provider: unfinished)
        let local = makeRunner(factory: unfinishedFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.note != nil }
        XCTAssertEqual(
            local.card?.note,
            RewriteCard.failureNote,
            "no .done arrived, so nothing says the service cut the answer off"
        )
        XCTAssertNotEqual(local.card?.note, RewriteCard.truncationNote)
        XCTAssertEqual(local.card?.versions.count, 1)
        XCTAssertEqual(fields.writes, [])
    }

    // MARK: - The deadlines

    /// The reasoning a service streams counts as work.
    ///
    /// The service reasons from a fifth of a second and keeps reasoning until
    /// its answer lands well past the first-token deadline. An attempt that
    /// counted only answer tokens failed at the deadline and threw the answer
    /// away; this one stays alive and keeps the version.
    func testAServiceThatReasonsKeepsTheRequestAlive() async {
        let provider = TimedRewriteProvider([
            TimedRewriteProvider.Beat(200, .thinking),
            TimedRewriteProvider.Beat(500, .thinking),
            TimedRewriteProvider.Beat(800, .thinking),
            TimedRewriteProvider.Beat(1_100, .thinking),
            TimedRewriteProvider.Beat(1_400, .thinking),
            TimedRewriteProvider.Beat(1_600, .textDelta(rewritten)),
            TimedRewriteProvider.Beat(1_650, .done(.endTurn)),
        ])
        let local = makeRunner(factory: ScriptedRewriteFactory(provider: provider))
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { self.generated(local) }
        XCTAssertNil(local.card?.note, "a service that was reasoning was reported as one that failed")
        XCTAssertEqual(local.card?.versions.count, 2)
        XCTAssertEqual(local.card?.selectedVersion.id, 1)
        XCTAssertEqual(local.card?.draft, "")
        XCTAssertEqual(fields.writes, [])
    }

    /// Silence up to the first deadline fails the attempt with the note.
    func testSilenceBeforeTheFirstDeadlineFailsTheAttempt() async {
        let provider = TimedRewriteProvider([
            TimedRewriteProvider.Beat(1_300, .textDelta(rewritten)),
            TimedRewriteProvider.Beat(1_350, .done(.endTurn)),
        ])
        let local = makeRunner(factory: ScriptedRewriteFactory(provider: provider))
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.note == RewriteCard.failureNote }
        XCTAssertFalse(generated(local), "an attempt the deadline ended kept a version")
        XCTAssertEqual(local.card?.draft, "")
        XCTAssertEqual(local.card?.phase, .offered)
    }

    /// Reasoning that never reaches an answer is ended by the total deadline.
    ///
    /// The service reasons from a tenth of a second and never writes a word. The
    /// first deadline is passed over because the reasoning is work, so the
    /// attempt lives until the whole request's budget runs out: the reading
    /// below is what tells the two deadlines apart.
    func testReasoningThatNeverAnswersIsEndedAtTheTotalDeadline() async {
        let beats = stride(from: 100, through: 3_000, by: 300).map { milliseconds in
            TimedRewriteProvider.Beat(milliseconds, .thinking)
        }
        let provider = TimedRewriteProvider(beats)
        let local = makeRunner(factory: ScriptedRewriteFactory(provider: provider))
        XCTAssertTrue(begin(runner: local))
        let start = ContinuousClock.now
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.note == RewriteCard.failureNote }
        let elapsed = ContinuousClock.now - start
        XCTAssertFalse(generated(local), "an attempt that only reasoned kept a version")
        XCTAssertEqual(local.card?.draft, "", "reasoning is not an answer and reached the draft")
        XCTAssertEqual(local.card?.phase, .offered)
        XCTAssertGreaterThanOrEqual(
            elapsed,
            .milliseconds(1_900),
            "the attempt ended before the whole request's two seconds ran out, so the first deadline still read reasoning as silence"
        )
    }

    // MARK: - The output cap

    /// The cap the runner uses for a take, from the style and the transcript.
    private func cap(for style: RewriteStyle, input: String) -> Int {
        RewritePrompt.outputLimit(inputCharacters: input.count, style: style)
    }

    /// A text of exactly `count` characters that keeps the take's number and
    /// negation, so the check's own errors cannot decide the outcome.
    private func answer(exactly count: Int) -> String {
        let sentence = "Send Priya the report by 5 pm; do not forget the appendix. "
        var text = ""
        while text.count + sentence.count <= count { text += sentence }
        return text + String(repeating: "z", count: count - text.count)
    }

    func testAnAnswerThatEndsExactlyAtTheCapIsKept() async {
        let input = "Send the report to Priya by 5 pm, and do not forget the appendix."
        let limit = cap(for: .formal, input: input)
        XCTAssertEqual(limit, 1_600, "the premise: this take's cap is the prose floor")
        let text = answer(exactly: limit)
        XCTAssertEqual(text.count, limit)
        let exact = RewriteStreamSpy(deltas: chunks(of: text))
        let exactFactory = RewriteFactorySpy(provider: exact)
        let local = makeRunner(factory: exactFactory)

        XCTAssertTrue(begin(runner: local, text: input))
        local.choose(.formal, configuration: configuration)
        await expectTrue { local.card?.versions.count == 2 }
        XCTAssertNil(local.card?.note, "an answer that ends at the cap was reported as cut off")
        XCTAssertEqual(local.card?.selectedVersion.text, text, "the last characters were dropped")
        XCTAssertEqual(local.card?.selectedVersion.styleID, "formal")
    }

    func testAnAnswerOverTheCapIsCutAndTheStreamIsLeft() async {
        let input = "Send the report to Priya by 5 pm, and do not forget the appendix."
        let limit = cap(for: .formal, input: input)
        // Ten times the first cap, so both attempts are cut with most of the
        // answer still arriving: the first is cut at 1,600 characters and the
        // retry at 3,200 of the 16,000 this holds. The count of deltas a stream
        // delivered is read at the producer's yield rather than at the
        // consumer's read, so the headroom is what keeps a loaded runner from
        // making a drained stream look drained: 319 chunks here.
        let text = answer(exactly: limit * 10)
        let deltas = chunks(of: text, size: 40)
        let over = RewriteStreamSpy(
            deltas: deltas,
            milliseconds: 1,
            holdsOpen: true
        )
        let overFactory = RewriteFactorySpy(provider: over)
        // A watchdog far longer than the wait below: if the cap were noticed
        // only when the attempt's deadline ended, this test could not see the
        // truncation note at all.
        let local = makeRunner(
            factory: overFactory,
            timing: RewriteRunner.Timing(total: 30, firstToken: 20, failureNote: 5)
        )

        XCTAssertTrue(begin(runner: local, text: input))
        local.choose(.formal, configuration: configuration)
        await expectTrue { local.card?.note == RewriteCard.truncationNote }
        XCTAssertEqual(
            over.callCount,
            2,
            "the capped attempt was not asked again, so the retry's cut was not measured"
        )
        XCTAssertEqual(deltas.count, 400, "the premise: the answer is 400 chunks of forty")
        // Leaving the stream is what cancels the service's producer: a loop
        // that kept reading would still be inside `holdsOpen`'s sleep, and the
        // producer would have sent the whole script by then. What is asserted is
        // therefore the state of the two streams and not how long the answer
        // took, which measures the machine.
        await expectTrue { over.stopped.count == 2 }
        XCTAssertEqual(
            over.deliveredDeltas.count,
            2,
            "the answer was not streamed twice, so the count does not cover the retry"
        )
        for (index, delivered) in over.deliveredDeltas.enumerated() {
            XCTAssertLessThan(
                delivered,
                deltas.count,
                "stream \(index + 1) was drained past the cap instead of left at it: it delivered all \(delivered) deltas"
            )
        }
        for reason in over.stopped.map({ $0.1 }) {
            guard case .cancelled = reason else {
                return XCTFail("a stream finished instead of being left at the cap")
            }
        }
        XCTAssertEqual(local.card?.versions.count, 1, "a capped answer became a version")
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [])
    }

    func testAnAnswerTheServiceCutShortSaysSo() async {
        let provider = ScriptedChatProvider(events: [
            .textDelta(rewritten),
            .done(.length),
        ])
        let local = makeRunner(factory: ScriptedRewriteFactory(provider: provider))
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.note != nil }
        XCTAssertEqual(local.card?.note, RewriteCard.truncationNote)
        XCTAssertEqual(local.card?.versions.count, 1)
    }

    func testAnAnswerTheServiceSuppressedIsAFailure() async {
        for stop in [ChatStopReason.contentFilter, .other("refusal"), .toolCalls] {
            let provider = ScriptedChatProvider(events: [.textDelta(rewritten), .done(stop)])
            let local = makeRunner(factory: ScriptedRewriteFactory(provider: provider))
            XCTAssertTrue(begin(runner: local, text: original))
            local.choose(.concise, configuration: configuration)
            await expectTrue { local.card?.note != nil }
            XCTAssertEqual(local.card?.note, RewriteCard.failureNote, "\(stop)")
            XCTAssertEqual(local.card?.versions.count, 1, "\(stop)")
        }
    }

    /// The report's regression: a 15-word note becomes a 650-character Agent
    /// prompt, which the old 400-character cap cut off every time.
    func testATypicalVoiceNoteBecomesAStructuredAgentPrompt() async {
        let input = "Add a retry to the uploader when the request fails and keep the same error copy."
        XCTAssertEqual(input.count, 80)
        XCTAssertEqual(cap(for: .prompt, input: input), 3_600)

        let text = agentPrompt(exactly: 650)
        XCTAssertEqual(text.count, 650)
        let prompt = RewriteStreamSpy(deltas: chunks(of: text))
        let promptFactory = RewriteFactorySpy(provider: prompt)
        let local = makeRunner(factory: promptFactory)

        XCTAssertTrue(begin(runner: local, text: input))
        local.choose(.prompt, configuration: configuration)
        await expectTrue { local.card?.versions.count == 2 }
        XCTAssertNil(local.card?.note)
        XCTAssertEqual(
            local.card?.selectedVersion.text,
            text,
            "the version is the model's output as it stands"
        )
        XCTAssertEqual(local.card?.selectedVersion.styleID, "prompt")
    }

    /// A structured Agent prompt of exactly `count` characters.
    ///
    /// The tail pads the fixture to the length the report names: the placeholder
    /// lines repeat, and the last one absorbs the remainder.
    private func agentPrompt(exactly count: Int) -> String {
        var text = """
        ## Goal
        Add a retry to the uploader when the request fails, and keep the same error copy.

        ## Context
        The uploader currently fails the whole upload when one request fails.

        ## Requirements
        1. Retry the request when it fails.
        2. Keep the same error copy.

        ## Constraints
        Do not change anything else.

        ## Done when
        A failed request is retried and the same error copy is shown.

        ## Open questions
        [missing: how many times to retry]
        """
        let line = "\n[missing: the backoff between retries]"
        while text.count + line.count <= count { text += line }
        if text.count < count {
            text += String(repeating: "x", count: count - text.count)
        }
        return text
    }

    // MARK: - The client cap and the retry

    /// The cap of each attempt, as the card was drawn while it streamed.
    ///
    /// A capped attempt writes the prefix it kept into the draft, so the longest
    /// draft a take showed is the cap that attempt enforced.
    private func draftLengths() -> [Int] {
        cards.map(\.draft.count)
    }

    func testAnAnswerThatAlwaysExceedsTheCapIsAskedTwiceAndThenReported() async {
        let input = "Send the report to Priya by 5 pm, and do not forget the appendix."
        let limit = cap(for: .formal, input: input)
        XCTAssertEqual(limit, 1_600, "the premise: this take's cap is the prose floor")
        // Longer than the cap of the retry, so both attempts are cut.
        let over = RewriteStreamSpy(deltas: Array(repeating: "abcdefgh", count: 500))
        let local = makeRunner(factory: RewriteFactorySpy(provider: over))

        XCTAssertTrue(begin(runner: local, text: input))
        local.choose(.formal, configuration: configuration)
        await expectTrue { local.card?.note == RewriteCard.truncationNote }

        XCTAssertEqual(over.callCount, 2, "the capped answer was asked more than once")
        XCTAssertEqual(
            RewriteRunner.retryLimit(after: limit),
            limit * 2,
            "the retry did not double the cap"
        )
        let lengths = draftLengths()
        XCTAssertTrue(
            lengths.contains(limit),
            "the first attempt did not stop at its own cap: \(lengths.max() ?? 0)"
        )
        XCTAssertEqual(
            lengths.max(),
            limit * 2,
            "the second attempt did not enforce twice the first cap"
        )
        XCTAssertEqual(local.card?.versions.count, 1, "a capped answer became a version")
        XCTAssertEqual(local.card?.isStreaming, false)
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [])
    }

    func testAnAnswerThatFinishesOnTheRetryBecomesOneVersion() async {
        let input = "Send the report to Priya by 5 pm, and do not forget the appendix."
        let limit = cap(for: .formal, input: input)
        // Longer than the first cap and shorter than twice it: only a second
        // attempt with the longer cap can keep this answer whole.
        let text = answer(exactly: limit + 600)
        let over = RewriteStreamSpy(deltas: chunks(of: answer(exactly: limit * 2)))
        let complete = RewriteStreamSpy(deltas: chunks(of: text))
        let factory = RewriteFactorySpy(provider: over)
        factory.queue = [complete]
        let local = makeRunner(factory: factory)

        XCTAssertTrue(begin(runner: local, text: input))
        local.choose(.formal, configuration: configuration)
        await expectTrue { local.card?.versions.count == 2 }

        XCTAssertEqual(over.callCount, 1, "the first attempt was asked again")
        XCTAssertEqual(complete.callCount, 1, "the answer that finished was asked again")
        XCTAssertNil(local.card?.note, "an answer that finished on the retry was reported as cut off")
        XCTAssertEqual(local.card?.versions.count, 2, "the retry appended a second version")
        XCTAssertEqual(local.card?.versions.filter { !$0.isOriginal }.count, 1)
        XCTAssertEqual(local.card?.selectedVersion.text, text)
        XCTAssertEqual(local.card?.phase, .offered)
    }

    func testAnAnswerTheServiceCutShortIsNotAskedAgain() async {
        let provider = ScriptedChatProvider(events: [
            .textDelta(rewritten),
            .done(.length),
        ])
        let local = makeRunner(factory: ScriptedRewriteFactory(provider: provider))
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.note != nil }

        XCTAssertEqual(provider.callCount, 1, "a provider length was retried as a client cap")
        XCTAssertEqual(local.card?.note, RewriteCard.truncationNote)
        XCTAssertEqual(local.card?.versions.count, 1)
    }

    func testAnAnswerTheServiceSuppressedIsNotAskedAgain() async {
        let provider = ScriptedChatProvider(events: [
            .textDelta(rewritten),
            .done(.contentFilter),
        ])
        let local = makeRunner(factory: ScriptedRewriteFactory(provider: provider))
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.note != nil }

        XCTAssertEqual(provider.callCount, 1, "a content filter was retried")
        XCTAssertEqual(local.card?.note, RewriteCard.failureNote)
        XCTAssertEqual(local.card?.versions.count, 1)
    }

    func testAStreamWithoutADoneIsNotAskedAgain() async {
        let unfinished = RewriteStreamSpy(deltas: chunks(of: rewritten), finishWithoutDone: true)
        let local = makeRunner(factory: RewriteFactorySpy(provider: unfinished))
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.note != nil }

        XCTAssertEqual(unfinished.callCount, 1, "a stream with no stop reason was retried")
        XCTAssertEqual(local.card?.note, RewriteCard.failureNote)
        XCTAssertEqual(local.card?.versions.count, 1)
    }

    func testCancellingDuringTheRetryLeavesNoVersionAndNoNote() async {
        let over = RewriteStreamSpy(deltas: Array(repeating: "abcdefgh", count: 500))
        let slow = RewriteStreamSpy(deltas: chunks(of: formal), milliseconds: 25, holdsOpen: true)
        let factory = RewriteFactorySpy(provider: over)
        factory.queue = [slow]
        let local = makeRunner(factory: factory)

        XCTAssertTrue(begin(runner: local))
        local.choose(.formal, configuration: configuration)
        await expectTrue({ slow.callCount == 1 }, "the retry never started")
        local.cancelStream()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(local.card?.versions.count, 1, "a cancelled retry became a version")
        XCTAssertNil(local.card?.note, "a cancelled retry was reported as cut off")
        XCTAssertEqual(local.card?.phase, .offered)
        XCTAssertEqual(local.card?.draft, "")
        XCTAssertEqual(fields.writes, [])
        XCTAssertEqual(copied, [])
    }

    func testTheOutputCapIsTheFloorOfTheStyleAndFourOrFiveTimesALongerInput() {
        let prose = RewriteStyle.formal
        let structured = RewriteStyle.prompt
        XCTAssertEqual(cap(for: prose, input: String(repeating: "a", count: 100)), 1_600)
        XCTAssertEqual(cap(for: structured, input: String(repeating: "a", count: 100)), 3_600)
        XCTAssertEqual(cap(for: prose, input: String(repeating: "a", count: 1_000)), 4_000)
        XCTAssertEqual(cap(for: structured, input: String(repeating: "a", count: 1_000)), 5_000)
    }

    // MARK: - Rebase

    func testAnInlineEditRebasesTheOriginalAndClearsOlderVersions() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        let edited = "Send the report to Priya by 5 pm."
        runner.rebaseOriginal(edited)
        XCTAssertEqual(runner.card?.original, edited)
        XCTAssertEqual(runner.card?.versions.count, 1)
        XCTAssertEqual(runner.card?.selectedVersion.text, edited)
        XCTAssertEqual(runner.card?.note, RewriteCard.rebaseNote)
        runner.choose(.formal, configuration: configuration)
        await expectTrue { self.generated() }
        XCTAssertEqual(
            stream.lastMessages?.last?.text,
            "<transcript>\n" + edited + "\n</transcript>",
            "the request used the stale original"
        )
    }
}

extension RewriteRunnerTests {
    // MARK: - The standing rules Dot appends

    /// A runner whose stream answers with `text`, holding the take's record of
    /// standing rules.
    ///
    /// Each call builds its own, so the rules tests do not share the outer
    /// harness's stream, and the record is the one the request reads: the block
    /// is captured when a request starts, not when a version is appended.
    private func makeLocalRunner(
        answering text: String,
        configuration: RewriteConfiguration? = nil
    ) -> (runner: RewriteRunner, fields: FakeTextFieldAccess) {
        let stream = RewriteStreamSpy(deltas: chunks(of: text))
        let factory = RewriteFactorySpy(provider: stream)
        let fields = FakeTextFieldAccess(document: original)
        let runner = makeRunner(factory: factory, fields: fields)
        let anchor = runner.captureAnchor(insertedText: original, at: clock.value)
        _ = runner.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: configuration ?? self.configuration,
            anchor: anchor
        )
        return (runner, fields)
    }

    private func hasGenerated(_ runner: RewriteRunner) -> Bool {
        runner.card?.versions.contains { !$0.isOriginal } == true
    }

    /// A record with the block on, holding `rules`.
    private func standing(_ rules: String) -> RewriteConfiguration {
        var configuration = self.configuration
        configuration.standingRulesEnabled = true
        configuration.setStandingRules(rules)
        return configuration
    }

    /// The version is the model's output, with nothing appended when the block
    /// is off.
    ///
    /// The Agent prompt asks the model for the task, and the block is a setting
    /// the person may not have written: a text nobody typed has no place under
    /// an answer.
    func testThePromptStyleKeepsTheModelOutputAsItIs() async {
        let local = makeLocalRunner(answering: aPrompt())
        local.runner.choose(.prompt, configuration: configuration)
        await expectTrue { self.hasGenerated(local.runner) }
        XCTAssertEqual(local.runner.card?.selectedVersion.text, aPrompt())
        XCTAssertFalse(
            local.runner.card?.selectedVersion.text.contains("## House rules") == true,
            "a block nobody wrote was appended to the model's answer"
        )
        XCTAssertEqual(local.fields.writes, [], "the version was written before an explicit Paste")
    }

    /// No style gets a block while the setting is off.
    func testNoStyleGetsABlockAppended() async {
        let local = makeLocalRunner(answering: rewritten)
        local.runner.choose(.concise, configuration: configuration)
        await expectTrue { self.hasGenerated(local.runner) }
        XCTAssertEqual(local.runner.card?.selectedVersion.text, rewritten)
        XCTAssertFalse(local.runner.card?.selectedVersion.text.contains("## House rules") == true)
    }

    /// The block Dot appends sits one blank line under the Agent prompt's answer.
    func testTheStandingRulesAreAppendedToAnAgentPromptVersion() async {
        let rules = "## House rules\n- Run the build and the tests.\n- Never touch main."
        let local = makeLocalRunner(answering: aPrompt(), configuration: standing(rules))
        local.runner.choose(.prompt, configuration: standing(rules))
        await expectTrue { self.hasGenerated(local.runner) }
        XCTAssertEqual(
            local.runner.card?.selectedVersion.text,
            aPrompt() + "\n\n" + rules
        )
    }

    /// Copy and Paste deliver the version with the block in it.
    ///
    /// The block is part of the saved version, so what a Paste writes and what
    /// Copy puts on the clipboard are the same text the card shows.
    func testCopyAndPasteCarryTheBlock() async {
        let rules = "- Run the build and the tests."
        let local = makeLocalRunner(answering: aPrompt(), configuration: standing(rules))
        local.runner.choose(.prompt, configuration: standing(rules))
        await expectTrue { self.hasGenerated(local.runner) }
        let text = local.runner.card?.selectedVersion.text ?? ""
        XCTAssertEqual(text, aPrompt() + "\n\n" + rules)

        XCTAssertTrue(local.runner.copySelected(text))
        XCTAssertEqual(copied.last, text)

        local.fields.selection = NSRange(location: 0, length: 0)
        XCTAssertTrue(local.runner.pasteSelected(text))
        XCTAssertEqual(local.fields.writes, [text], "the paste wrote the answer without the block")
    }

    /// The block belongs to the Agent prompt and to nothing else.
    func testNoOtherStyleCarriesTheBlock() async {
        let rules = "- Run the build and the tests."
        let local = makeLocalRunner(answering: rewritten, configuration: standing(rules))
        local.runner.choose(.concise, configuration: standing(rules))
        await expectTrue { self.hasGenerated(local.runner) }
        XCTAssertEqual(local.runner.card?.selectedVersion.text, rewritten)
    }

    /// The check reads the model's output, which is the answer Dot keeps.
    func testTheLengthCheckReadsTheModelOutput() async {
        let local = makeLocalRunner(answering: original)
        local.runner.choose(.prompt, configuration: configuration)
        await expectTrue { self.hasGenerated(local.runner) }
        XCTAssertNil(
            local.runner.card?.selectedVersion.warning,
            "a faithful answer was reported as a length change"
        )
    }

    /// A block long enough to break the Agent prompt's band still leaves the
    /// version unreported, because the band measured the answer alone.
    ///
    /// The premise is measured first: the transcript and the answer are the
    /// same text, so the answer alone is inside the band, and the same answer
    /// with the block under it is outside it.
    func testABlockThatBreaksTheBandIsNotCountedAsALengthChange() async {
        let answer = original
        let rules = String(repeating: "Standing rule line. ", count: 20)
        let record = standing(rules)
        let style = RewriteStyle(.prompt)
        XCTAssertTrue(
            FaithfulnessCheck.check(original: original, rewrite: answer, style: style).isFaithful,
            "the premise: the answer alone is faithful"
        )
        XCTAssertEqual(
            FaithfulnessCheck.check(
                original: original,
                rewrite: answer + "\n\n" + rules,
                style: style
            ).warnings,
            [FaithfulnessCheck.lengthChanged],
            "the premise: counting the block breaks the band"
        )

        let local = makeLocalRunner(answering: answer, configuration: record)
        local.runner.choose(.prompt, configuration: record)
        await expectTrue { self.hasGenerated(local.runner) }
        XCTAssertEqual(local.runner.card?.selectedVersion.text, answer + "\n\n" + rules)
        XCTAssertNil(
            local.runner.card?.selectedVersion.warning,
            "the block was measured as part of the model's answer"
        )
    }

    /// A draft the check refused is delivered with the block when it is taken.
    func testUsingABlockedDraftAnywayCarriesTheBlock() async {
        // A number the answer dropped: an error, so the card asks first.
        let answer = "Send the report to Priya, and don't forget the appendix."
        let rules = "- Run the build and the tests."
        let local = makeLocalRunner(answering: answer, configuration: standing(rules))
        local.runner.choose(.prompt, configuration: standing(rules))
        await expectTrue { self.isBlocked(local.runner) }
        XCTAssertEqual(
            local.runner.card?.draft,
            answer,
            "the draft holds words the model never wrote"
        )
        local.runner.useAnyway()
        await expectTrue { self.hasGenerated(local.runner) }
        XCTAssertEqual(local.runner.card?.selectedVersion.text, answer + "\n\n" + rules)
    }

    /// A structured Agent prompt, as the style asks for it.
    private func aPrompt() -> String {
        """
        ## Goal
        Send the report to Priya by 5 pm.

        ## Context
        The appendix is not attached yet.

        ## Requirements
        1. Send the report to Priya by 5 pm.
        2. Do not forget the appendix.
        """
    }
}

/// The factory for a scripted service: set up, keyed, one model, one stream.
///
/// The shared rewrite spy answers with `.done(.endTurn)`. The stop reasons a
/// service can report instead are what these tests are about, so they are
/// scripted through the assistant's own test double.
@MainActor
private final class ScriptedRewriteFactory: RewriteProviderFactory {
    private let provider: any ChatProvider

    init(provider: any ChatProvider) {
        self.provider = provider
    }

    var assistant: AssistantConfiguration {
        var configuration = AssistantConfiguration.default
        configuration.isSetUp = true
        configuration.chat = AssistantSettings(providerID: "anthropic", model: "test-model")
        return configuration
    }

    func hasKey() -> Bool { true }
    func model() -> String { "test-model" }
    func makeProvider(temperature: Double) async throws -> any ChatProvider { provider }
}

/// Restoring the versions a history entry kept.
///
/// A restored card is a review surface: it reads what was saved, it never asks
/// the service for anything until the person explicitly reruns a style, and the
/// generation gates of a fresh take still decide whether that is possible.
@MainActor
extension RewriteRunnerTests {
    private func historySnapshot(
        _ versions: [RewriteVersion],
        selected: Int
    ) -> RewriteSnapshot {
        RewriteSnapshot(versions: versions, selectedVersionID: selected)
    }

    private func savedConcise(id: Int = 2) -> RewriteSnapshot {
        historySnapshot(
            [RewriteVersion(id: id, origin: .style("concise"), title: "Concise", text: rewritten, ordinal: 1)],
            selected: id
        )
    }

    func testRestoringSavedVersionsMakesNoRequest() {
        XCTAssertTrue(runner.restore(original: original, saved: savedConcise(), configuration: configuration))
        XCTAssertEqual(runner.card?.original, original)
        XCTAssertEqual(runner.card?.versions.map(\.id), [0, 2])
        XCTAssertEqual(runner.card?.selectedVersionID, 2)
        XCTAssertEqual(runner.card?.selectedVersion.text, rewritten)
        XCTAssertEqual(runner.card?.phase, .offered)
        XCTAssertEqual(runner.card?.destination, nil, "a restored card claimed a destination")
        XCTAssertEqual(factory.makeCount, 0, "restoring asked for a provider")
        XCTAssertEqual(stream.callCount, 0, "restoring asked the service")
        XCTAssertTrue(fields.calls.isEmpty, "restoring touched the text field")
        XCTAssertTrue(copied.isEmpty)
    }

    func testSelectingAndNavigatingARestoredCardMakesNoRequest() {
        let saved = historySnapshot(
            [
                RewriteVersion(id: 2, origin: .style("concise"), title: "Concise", text: rewritten, ordinal: 1),
                RewriteVersion(id: 5, origin: .style("formal"), title: "Professional", text: formal, ordinal: 1),
            ],
            selected: 5
        )
        XCTAssertTrue(runner.restore(original: original, saved: saved, configuration: configuration))
        XCTAssertEqual(runner.card?.selectedVersionID, 5)
        runner.selectPrevious()
        XCTAssertEqual(runner.card?.selectedVersionID, 2)
        runner.selectPrevious()
        XCTAssertEqual(runner.card?.selectedVersionID, 0)
        runner.selectNext()
        XCTAssertEqual(runner.card?.selectedVersionID, 2)
        runner.select(versionID: 5)
        XCTAssertEqual(runner.card?.selectedVersionID, 5)
        runner.selectStyle(.concise, configuration: configuration)
        XCTAssertEqual(runner.card?.selectedVersionID, 2)
        XCTAssertEqual(factory.makeCount, 0, "reviewing a restored card asked for a provider")
        XCTAssertEqual(stream.callCount, 0, "reviewing a restored card asked the service")
        XCTAssertTrue(fields.writes.isEmpty)
        XCTAssertTrue(copied.isEmpty)
    }

    func testARestoredCardIsReadOnlyWhenTheRewriteIsOff() {
        var off = configuration
        off.enabled = false
        XCTAssertTrue(runner.restore(original: original, saved: savedConcise(), configuration: off))
        XCTAssertEqual(runner.card?.versions.count, 2)
        XCTAssertTrue(runner.card?.choices.isEmpty == true, "a switched-off rewrite still offered a style")
        runner.selectStyle(.concise, configuration: off)
        runner.choose(.formal, configuration: off)
        runner.rerun(configuration: off)
        XCTAssertEqual(factory.makeCount, 0, "a switched-off rewrite asked for a provider")
        XCTAssertEqual(stream.callCount, 0, "a switched-off rewrite asked the service")
        XCTAssertEqual(runner.card?.note, RewriteRunner.unavailableNowNote)
    }

    func testARestoredCardIsReadOnlyWithoutAKey() {
        factory.keyPresent = false
        XCTAssertTrue(runner.restore(original: original, saved: savedConcise(), configuration: configuration))
        XCTAssertTrue(runner.card?.choices.isEmpty == true)
        runner.choose(.formal, configuration: configuration)
        XCTAssertEqual(factory.makeCount, 0)
        XCTAssertEqual(stream.callCount, 0)
    }

    func testARestoredCardIsReadOnlyWhenTheTranscriptIsTooLong() {
        let tooLong = String(repeating: "a", count: RewriteOffer.maximumInputCharacters + 1)
        let saved = historySnapshot(
            [RewriteVersion(id: 1, origin: .style("concise"), title: "Concise", text: rewritten, ordinal: 1)],
            selected: 1
        )
        XCTAssertTrue(runner.restore(original: tooLong, saved: saved, configuration: configuration))
        XCTAssertEqual(runner.card?.versions.count, 2, "a long transcript lost its saved versions")
        XCTAssertTrue(runner.card?.choices.isEmpty == true)
        runner.choose(.concise, configuration: configuration)
        XCTAssertEqual(factory.makeCount, 0)
        XCTAssertEqual(stream.callCount, 0)
    }

    func testARestoredDeletedStyleIsNavigableButCannotRerun() {
        let saved = historySnapshot(
            [RewriteVersion(
                id: 1,
                origin: .style("retired"),
                title: "Retired style",
                text: rewritten,
                ordinal: 1,
                warning: "Review this."
            )],
            selected: 1
        )
        XCTAssertTrue(runner.restore(original: original, saved: saved, configuration: configuration))
        XCTAssertEqual(runner.card?.selectedVersion.styleID, "retired")
        XCTAssertEqual(runner.card?.selectedVersion.title, "Retired style")
        XCTAssertEqual(runner.card?.selectedVersion.warning, "Review this.")
        XCTAssertTrue(runner.card?.choices.contains { $0.id == "retired" } == false)
        runner.selectPrevious()
        XCTAssertEqual(runner.card?.selectedVersionID, 0)
        runner.selectNext()
        XCTAssertEqual(runner.card?.selectedVersionID, 1)
        runner.rerun(configuration: configuration)
        XCTAssertEqual(runner.card?.note, RewriteRunner.unavailableStyleNote)
        XCTAssertEqual(factory.makeCount, 0, "a removed style was asked for anyway")
        XCTAssertEqual(stream.callCount, 0)
        XCTAssertEqual(runner.card?.versions.count, 2, "the note dropped a version")
    }

    func testRerunAfterRestoreAppendsTheNextID() async {
        let saved = historySnapshot(
            [
                RewriteVersion(id: 3, origin: .style("concise"), title: "Concise", text: rewritten, ordinal: 1),
                RewriteVersion(id: 7, origin: .style("formal"), title: "Professional", text: formal, ordinal: 1),
            ],
            selected: 3
        )
        XCTAssertTrue(runner.restore(original: original, saved: saved, configuration: configuration))
        XCTAssertEqual(factory.makeCount, 0)
        XCTAssertEqual(runner.card?.versions.count, 3, "the restored list is the premise")
        runner.rerun(configuration: configuration)
        await expectTrue { self.runner.card?.versions.count == 4 }
        XCTAssertEqual(runner.card?.versions.map(\.id), [0, 3, 7, 8])
        XCTAssertEqual(runner.card?.versions.last?.styleID, "concise")
        XCTAssertEqual(runner.card?.versions.last?.ordinal, 2)
        XCTAssertEqual(runner.card?.selectedVersionID, 8)
        XCTAssertEqual(stream.lastMessages?.last?.text, "<transcript>\n" + original + "\n</transcript>")
    }

    func testRestoringStopsTheStreamOfThePreviousTake() async {
        let slow = RewriteStreamSpy(deltas: chunks(of: rewritten), milliseconds: 20, holdsOpen: true)
        let slowFactory = RewriteFactorySpy(provider: slow)
        let local = makeRunner(factory: slowFactory)
        XCTAssertTrue(begin(runner: local))
        local.choose(.concise, configuration: configuration)
        await expectTrue { local.card?.draft.isEmpty == false }

        XCTAssertTrue(local.restore(original: original, saved: savedConcise(), configuration: configuration))
        XCTAssertEqual(local.card?.draft, "")
        XCTAssertEqual(local.card?.isStreaming, false)
        XCTAssertEqual(local.card?.versions.count, 2)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(local.card?.versions.count, 2, "a cancelled draft attached itself to the restored card")
        XCTAssertEqual(local.card?.draft, "")
    }

    func testRestoringShowsTheSelectedVersionAndKeepsEveryOneReachable() {
        let saved = historySnapshot(
            [
                RewriteVersion(id: 1, origin: .style("concise"), title: "Concise", text: rewritten, ordinal: 1),
                RewriteVersion(id: 4, origin: .style("formal"), title: "Professional", text: formal, ordinal: 1),
            ],
            selected: 1
        )
        XCTAssertTrue(runner.restore(original: original, saved: saved, configuration: configuration))
        XCTAssertEqual(runner.card?.selectedVersionID, 1)
        XCTAssertEqual(runner.card?.selectedIndex, 1)
        XCTAssertEqual(runner.card?.bodyText, rewritten)
        XCTAssertTrue(runner.card?.showsRewrite == true)
        XCTAssertTrue(runner.card?.showsChips == true)
        XCTAssertTrue(runner.card?.canGoPrevious == true)
        XCTAssertTrue(runner.card?.canGoNext == true)
        XCTAssertEqual(runner.card?.versions.map(\.title), ["Original", "Concise", "Professional"])
    }

    func testAnEmptySnapshotOrAnEmptyOriginalShowsNothing() {
        XCTAssertFalse(runner.restore(
            original: original,
            saved: RewriteSnapshot(versions: [], selectedVersionID: 3),
            configuration: configuration
        ))
        XCTAssertNil(runner.card)
        XCTAssertFalse(runner.restore(original: "   ", saved: savedConcise(), configuration: configuration))
        XCTAssertNil(runner.card)
        XCTAssertEqual(factory.makeCount, 0)
    }

    /// Dictating the same sentence again keeps the versions it already has, but
    /// shows the words that were just delivered: the saved selection belongs to
    /// the history click that restores it, never to a fresh take.
    func testASecondTakeOfTheSameWordsKeepsTheSavedVersions() async {
        let saved = savedConcise(id: 6)
        XCTAssertTrue(runner.begin(
            text: original,
            delivery: .pasted,
            destination: "Mail",
            configuration: configuration,
            anchor: nil,
            saved: saved
        ))
        XCTAssertEqual(runner.card?.versions.map(\.id), [0, 6], "a repeated take erased the versions history kept")
        XCTAssertEqual(runner.card?.selectedVersionID, 0, "a fresh take opened on the saved selection")
        XCTAssertEqual(runner.card?.bodyText, original, "a fresh take showed the old rewrite instead of what was pasted")
        XCTAssertEqual(runner.card?.showsRewrite, false)
        XCTAssertEqual(runner.card?.phase, .offered)
        XCTAssertEqual(
            runner.card.map {
                HUDHeader.title(for: $0, delivery: .pasted, destination: "Mail")
            },
            "PASTED INTO MAIL",
            "the header of a fresh take did not describe the delivery on screen"
        )
        runner.select(versionID: 6)
        XCTAssertEqual(runner.card?.bodyText, rewritten, "the saved version became unreachable")
        runner.select(versionID: 0)
        runner.rerun(configuration: configuration)
        // The original is selected, so there is no style to rerun.
        XCTAssertEqual(factory.makeCount, 0)
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.runner.card?.versions.count == 3 }
        XCTAssertEqual(runner.card?.versions.map(\.id), [0, 6, 7], "the next generation did not take the id after the last saved one")
    }

    func testAnInlineEditLeavesNothingFromTheOldWordsToPersist() async {
        XCTAssertTrue(begin())
        runner.choose(.concise, configuration: configuration)
        await expectTrue { self.generated() }
        XCTAssertNotNil(RewriteSnapshot(card: runner.card!))
        runner.rebaseOriginal("Send the report to Priya tomorrow.")
        XCTAssertEqual(runner.card?.versions.count, 1)
        XCTAssertNil(
            RewriteSnapshot(card: runner.card!),
            "versions built on the old words could still be written onto the edited transcript"
        )
    }
}

/// A remembered transcript that never had a rewrite.
@MainActor
extension RewriteRunnerTests {
    /// The card a history click leaves behind when the entry kept no versions:
    /// the style choices, drawn from the current settings, and no request.
    func testARememberedTranscriptWithoutVersionsOffersItsStylesWithoutAsking() {
        XCTAssertTrue(runner.begin(
            text: original,
            delivery: .copied,
            destination: nil,
            configuration: configuration,
            anchor: nil,
            saved: nil
        ))
        XCTAssertEqual(runner.card?.choices.count, RewriteStyle.builtIns.count)
        XCTAssertEqual(runner.card?.versions.count, 1)
        XCTAssertEqual(runner.card?.destination, nil)
        XCTAssertTrue(runner.card?.showsChips == true)
        XCTAssertEqual(factory.makeCount, 0, "opening the card asked for a provider")
        XCTAssertEqual(stream.callCount, 0, "opening the card asked the service")
        XCTAssertTrue(fields.calls.isEmpty)
        XCTAssertTrue(copied.isEmpty)
    }

    func testARememberedTranscriptOffersNothingWhenTheRewriteCannotRun() {
        var off = configuration
        off.enabled = false
        XCTAssertFalse(runner.begin(
            text: original,
            delivery: .copied,
            destination: nil,
            configuration: off,
            anchor: nil,
            saved: nil
        ))
        XCTAssertNil(runner.card)
        XCTAssertEqual(factory.makeCount, 0)
    }

    func testPasteSelectedOutcomeDistinguishesPastedFallbackAndIgnored() async {
        XCTAssertEqual(runner.pasteSelectedOutcome(original), .ignored)

        XCTAssertTrue(begin())
        XCTAssertEqual(runner.pasteSelectedOutcome("different text"), .ignored)
        XCTAssertEqual(runner.pasteSelectedOutcome(original), .pasted)

        let noFocusRunner = makeRunner(frontmost: { nil })
        XCTAssertTrue(begin(runner: noFocusRunner, anchor: false))
        XCTAssertEqual(noFocusRunner.pasteSelectedOutcome(original), .fallbackCopied)
        XCTAssertEqual(copied.last, original)
    }
}
