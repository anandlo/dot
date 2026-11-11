import DotCore
import XCTest

@testable import Dot

/// The island's assistant states, measured.
///
/// The renders are how they are looked at; these are the numbers that keep the
/// renders honest: the card sizes, the body bounds and the two labels that can
/// be longer than the room they have.
@MainActor
final class AssistantHUDLayoutTests: XCTestCase {
    func testTheOneLineCards() {
        XCTAssertEqual(HUDState.assistantCard.width, 520)
        XCTAssertEqual(HUDState.assistantCard.height, 54)
        XCTAssertEqual(HUDState.assistantWidth, 520)
    }

    func testTheAnswerCardIsTheTranscriptCard() {
        let short = HUD.assistantAnswerSize(text: "Yes.")
        XCTAssertEqual(short.width, HUDState.transcriptWidth)
        XCTAssertGreaterThanOrEqual(
            short.height,
            HUDState.headerHeight + 1 + HUDTranscript.minBodyHeight
        )
        XCTAssertEqual(
            short.height,
            HUDState.headerHeight + 1 + HUDTheme.transcriptLineHeight + HUDTheme.verticalPadding * 2,
            "one line of text and the padding around it"
        )

        let long = HUD.assistantAnswerSize(text: String(repeating: "A long answer. ", count: 80))
        XCTAssertEqual(long.width, HUDState.transcriptWidth)
        XCTAssertEqual(
            long.height,
            HUDState.headerHeight + 1 + HUDTranscript.maxBodyHeight,
            "the body stops growing at its limit and scrolls instead"
        )
        XCTAssertTrue(HUDTranscript.scrolls(contentHeight: 400))
    }

    func testTheConfirmationHoldsThreeLinesAndNotMore() {
        XCTAssertEqual(HUDConfirmLayout.width, 520)
        XCTAssertEqual(HUDConfirmLayout.buttonHeight, 30)
        XCTAssertEqual(HUDConfirmLayout.buttonGap, 8)
        XCTAssertEqual(
            HUDConfirmLayout.height(summaryLines: 0),
            HUDConfirmLayout.height(summaryLines: 1),
            "a card never collapses to nothing"
        )
        XCTAssertEqual(
            HUDConfirmLayout.height(summaryLines: 9),
            HUDConfirmLayout.height(summaryLines: 3),
            "a request longer than three lines scrolls nowhere: it is cut at three"
        )
    }

    func testARequestOfOneHundredAndTwentyCharactersNeedsThreeLinesAtMost() {
        let summary = String(repeating: "abcde ", count: 20)
        XCTAssertGreaterThanOrEqual(summary.count, 120)
        let lines = HUD.assistantSummaryLines(summary)
        XCTAssertLessThanOrEqual(lines, HUDConfirmLayout.maximumSummaryLines)
        XCTAssertGreaterThan(lines, 1, "120 characters cannot be one line")
    }

    func testTheHeadersNameWhatHappened() {
        XCTAssertEqual(AssistantAnswerState.streaming.label, "ANSWER")
        XCTAssertEqual(AssistantAnswerState.spoken.label, "ANSWER")
        XCTAssertEqual(AssistantAnswerState.copied.label, "COPIED")
        XCTAssertEqual(AssistantAnswerState.speaking.label, "SPEAKING")
        XCTAssertEqual(AssistantAnswerState.pasted("Mail").label, "PASTED INTO MAIL")
        XCTAssertEqual(AssistantAnswerState.pasted(nil).label, "PASTED")
        XCTAssertEqual(AssistantAnswerState.pasted("  ").label, "PASTED")
    }

    func testALongApplicationNameIsCutToTheRoomTheHeaderHas() {
        let name = String(repeating: "Very Long Application Name ", count: 4)
        let title = HUDHeader.title(for: .pasted(name))
        XCTAssertLessThanOrEqual(HUDHeader.width(of: title), HUDHeader.maximumTitleWidth)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(HUDHeader.accessibilityLabel(for: .pasted("Mail")), "Pasted into Mail")
    }

    func testThePrimaryButtonNamesWhatADestructiveCallDoes() {
        let write = ConfirmationRequest(
            callID: "1",
            toolName: "reminders_create",
            connectorID: .reminders,
            connectorName: "Reminders",
            risk: .write,
            summary: "Add a reminder"
        )
        XCTAssertEqual(write.allowTitle, "Allow")
        XCTAssertFalse(write.isDestructive)

        var destructive = write
        destructive = ConfirmationRequest(
            callID: "2",
            toolName: "notes_delete",
            connectorID: .notes,
            connectorName: "Notes",
            risk: .destructive,
            summary: "Delete the note"
        )
        XCTAssertEqual(destructive.allowTitle, "Delete")
        XCTAssertTrue(destructive.isDestructive)
    }
}
