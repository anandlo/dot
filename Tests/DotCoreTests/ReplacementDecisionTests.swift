import XCTest

@testable import DotCore

/// Whether a rewrite may replace the pasted transcript.
///
/// Every row of the decision table is one test: the range is the only record of
/// where the words went, and a condition that is not checked here is a
/// condition that can overwrite somebody else's sentence.
final class ReplacementDecisionTests: XCTestCase {
    private let pastedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func record(
        pid: Int32 = 42,
        location: Int = 120,
        length: Int = 78,
        text: String = "Send the report to Priya by 5 pm on Thursday, and don't forget the appendix.",
        at date: Date? = nil
    ) -> InsertionRecord {
        InsertionRecord(
            processIdentifier: pid,
            bundleIdentifier: "com.apple.mail",
            location: location,
            length: length,
            insertedText: text,
            capturedAt: date ?? pastedAt
        )
    }

    private func decide(
        anchor: InsertionRecord?,
        after seconds: TimeInterval = 2,
        pid: Int32? = 42,
        focused: Bool = true,
        live: String? = "Send the report to Priya by 5 pm on Thursday, and don't forget the appendix."
    ) -> ReplacementOutcome {
        ReplacementDecision.decide(
            anchor: anchor,
            now: pastedAt.addingTimeInterval(seconds),
            processIdentifier: pid,
            focusedIsAnchor: focused,
            textInRange: live
        )
    }

    func testNoAnchorIsUnreadable() {
        XCTAssertEqual(decide(anchor: nil), .clipboardOnly(.unreadable))
    }

    func testAnotherApplicationIsTheApplicationChanged() {
        XCTAssertEqual(decide(anchor: record(), pid: 99), .clipboardOnly(.appChanged))
    }

    func testAnUnknownFrontmostApplicationIsTheApplicationChanged() {
        XCTAssertEqual(decide(anchor: record(), pid: nil), .clipboardOnly(.appChanged))
    }

    func testAPasteOlderThanTwentySecondsIsTooLate() {
        XCTAssertEqual(decide(anchor: record(), after: 20.5), .clipboardOnly(.tooLate))
    }

    func testTwentySecondsExactlyIsStillTrusted() {
        XCTAssertEqual(decide(anchor: record(), after: 20), .replace)
    }

    func testAnotherFocusedElementIsTheFocusMoved() {
        XCTAssertEqual(decide(anchor: record(), focused: false), .clipboardOnly(.focusMoved))
    }

    func testDifferentTextAtTheRangeIsTheTextChanged() {
        XCTAssertEqual(
            decide(anchor: record(), live: "Send the report to Priya by 6 pm."),
            .clipboardOnly(.textChanged)
        )
    }

    func testUnreadableTextIsTheTextChanged() {
        XCTAssertEqual(decide(anchor: record(), live: nil), .clipboardOnly(.textChanged))
    }

    func testTheSameRangeIsReplaced() {
        XCTAssertEqual(decide(anchor: record()), .replace)
    }

    func testAClockThatWentBackwardsIsUnreadable() {
        XCTAssertEqual(decide(anchor: record(), after: -5), .clipboardOnly(.unreadable))
    }

    func testTheReasonsHaveStableNamesForTheLog() {
        XCTAssertEqual(ReplacementReason.appChanged.rawValue, "appChanged")
        XCTAssertEqual(ReplacementReason.tooLate.rawValue, "tooLate")
        XCTAssertEqual(ReplacementReason.unreadable.rawValue, "unreadable")
        XCTAssertEqual(ReplacementReason.focusMoved.rawValue, "focusMoved")
        XCTAssertEqual(ReplacementReason.textChanged.rawValue, "textChanged")
        XCTAssertEqual(ReplacementReason.readBackFailed.rawValue, "readBackFailed")
        XCTAssertEqual(ReplacementReason.allCases.count, 6)
    }

    // MARK: - The comparison

    func testWhitespaceCurlyQuotesAndTheLeadingCapitalAreIgnored() {
        XCTAssertTrue(ReplacementDecision.matches(
            inserted: "Ask Sam what he's doing today.",
            live: "  ask Sam what he\u{2019}s doing\ntoday.  "
        ))
        XCTAssertTrue(ReplacementDecision.matches(
            inserted: "Ask Sam what he's doing today.",
            live: "Ask Sam what he\u{2019}s doing today."
        ))
    }

    func testAChangedWordIsADifferentText() {
        XCTAssertFalse(ReplacementDecision.matches(
            inserted: "Ask Sam what he's doing today.",
            live: "Ask Sam what he is doing today."
        ))
    }

    func testNormalisingKeepsEverythingAfterTheFirstLetter() {
        XCTAssertEqual(
            ReplacementDecision.normalised("  Hello   World  "),
            "hello World"
        )
        XCTAssertEqual(ReplacementDecision.normalised(""), "")
    }

    func testTheRecordOfARewriteKeepsThePlaceAndTakesTheNewLength() {
        let before = record()
        let after = before.replacing(
            length: 69,
            text: "Send Priya the report by 5 pm Thursday; don't forget the appendix.",
            at: pastedAt.addingTimeInterval(9)
        )
        XCTAssertEqual(after.location, before.location)
        XCTAssertEqual(after.processIdentifier, before.processIdentifier)
        XCTAssertEqual(after.length, 69)
        XCTAssertEqual(after.capturedAt, pastedAt.addingTimeInterval(9))
        XCTAssertNotEqual(after.insertedText, before.insertedText)
    }
}
