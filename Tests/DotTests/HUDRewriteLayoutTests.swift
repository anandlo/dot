import AppKit
import DotCore
import XCTest

@testable import Dot

/// The rewrite layer's geometry, the header it renames and the panel it lives in.
///
/// The card is one budget: the header, the body the text needs, and the rows
/// under it. These tests are the arithmetic the render proved, so a change to
/// one measurement cannot silently clip the chips or push the header out of the
/// card.
@MainActor
final class HUDRewriteLayoutTests: XCTestCase {
    private func offeredCard(_ original: String) -> RewriteCard {
        RewriteCard(original: original, choices: RewriteStyle.builtIns, destination: "Mail")
    }

    private func blockedCard(_ original: String) -> RewriteCard {
        RewriteCard(
            original: original,
            choices: RewriteStyle.builtIns,
            phase: .blocked(styleID: "concise", error: FaithfulnessCheck.numberChanged),
            draft: original,
            destination: "Mail"
        )
    }

    func testTheOfferedCardIsTheTranscriptCardPlusTheChipRow() {
        let text = HUDPreview.transcript
        let plain = HUD.transcriptSize(text: text)
        let offered = HUD.transcriptSize(text: text, rewrite: offeredCard(text))
        let expected = HUDRewriteLayout.rowTopGap
            + HUDRewriteLayout.chipHeight
            + HUDState.verticalPadding
        XCTAssertEqual(expected, 49, "12 pt above the chips, 24 pt of chips, 13 pt below")
        XCTAssertEqual(offered.width, HUDState.transcriptWidth)
        XCTAssertEqual(offered.height, plain.height + expected, accuracy: 1)
    }

    func testTheOfferedBodyIsTheSameBodyThePlainCardDraws() {
        // The chip row may not take a line from the words: the card grows, the
        // body keeps the height the transcript would have had.
        let text = HUDPreview.transcript
        let plain = HUD.transcriptSize(text: text)
        let offered = HUD.transcriptSize(text: text, rewrite: offeredCard(text))
        let plainBody = plain.height - HUDTheme.headerHeight - 1
        let offeredBody = offered.height - HUDTheme.headerHeight - 1
            - HUD.rewriteExtraHeight(offeredCard(text))
        XCTAssertEqual(offeredBody, plainBody, accuracy: 1)
    }

    func testTheCopiedCardAddsTheNoteAndTheChips() {
        let text = HUDPreview.transcript
        var card = offeredCard(text)
        card.append(id: 1, style: .concise, text: text, warning: nil)
        card.phase = .copied(versionID: 1)
        card.note = RewriteCard.clipboardNote
        let plain = HUD.transcriptSize(text: text)
        let copied = HUD.transcriptSize(text: text, rewrite: card)
        let expected = HUDRewriteLayout.noteGap
            + HUDRewriteLayout.noteHeight
            + HUDRewriteLayout.rowGap
            + HUDRewriteLayout.chipHeight
            + HUDState.verticalPadding
        XCTAssertEqual(copied.height, plain.height + expected, accuracy: 1)
    }

    func testTheBlockedCardCarriesTheErrorLineAndTheTwoButtons() {
        let text = HUDPreview.transcript
        let card = blockedCard(text)
        let plain = HUD.transcriptSize(text: text)
        let blocked = HUD.transcriptSize(text: text, rewrite: card)
        let expected = HUDRewriteLayout.noteGap
            + HUDRewriteLayout.noteHeight
            + HUDRewriteLayout.rowGap
            + HUDRewriteLayout.actionHeight
            + HUDState.verticalPadding
        XCTAssertEqual(blocked.height, plain.height + expected, accuracy: 1)
    }

    /// A running card pays for the chip row and for nothing above the draft.
    ///
    /// The click frame and the hundredth token must measure the same card, or
    /// the card would jump under the pointer the instant the user presses a
    /// chip. The body therefore keeps the height of the words that were there
    /// before the request, and the only thing above the draft is the header the
    /// card has always drawn.
    func testTheClickKeepsTheCardHeightAndNothingSitsAboveTheDraft() {
        let text = HUDPreview.transcript
        var card = offeredCard(text)
        card.phase = .rewriting(styleID: "concise", title: "Concise")
        let atTheClick = HUD.transcriptSize(text: text, rewrite: card)
        card.draft = "Dot records the microphone and pastes the words back."
        let midStream = HUD.transcriptSize(text: text, rewrite: card)
        let plain = HUD.transcriptSize(text: text)
        XCTAssertEqual(
            midStream.height,
            atTheClick.height,
            accuracy: 0.001,
            "the first token may not resize the card"
        )
        XCTAssertEqual(
            midStream.height,
            plain.height
                + HUDRewriteLayout.rowTopGap
                + HUDRewriteLayout.chipHeight
                + HUDState.verticalPadding,
            accuracy: 1,
            "the running card pays for the chips and nothing above the draft"
        )
        let original = HUD.transcriptContentHeight(text: text)
        XCTAssertGreaterThan(original, HUDTranscript.minBodyHeight)
        XCTAssertEqual(
            HUDRewriteLayout.streamingContentHeight(originalContentHeight: original),
            max(original, HUDTranscript.minBodyHeight),
            accuracy: 0.001,
            "the streaming body keeps the height of the words from before the request"
        )
        XCTAssertEqual(
            HUDRewriteLayout.streamingContentHeight(originalContentHeight: original),
            original,
            accuracy: 0.001
        )
    }

    func testTheTallestRewriteCardStillFitsThePanel() {
        let long = HUDPreview.longTranscript
        let tallest = HUD.transcriptSize(text: long, rewrite: blockedCard(long))
        XCTAssertLessThanOrEqual(
            tallest.height,
            HUD.maximumCardHeight,
            "the panel would cut a rewrite card of \(tallest.height) pt"
        )
        XCTAssertGreaterThan(HUD.maximumCardHeight, 300)
    }

    func testALongerTranscriptScrollsInsteadOfGrowingPastThePanel() {
        let veryLong = Array(repeating: HUDPreview.longTranscript, count: 4)
            .joined(separator: " ")
        let card = HUD.transcriptSize(text: veryLong, rewrite: blockedCard(veryLong))
        XCTAssertLessThanOrEqual(card.height, HUD.maximumCardHeight)
        let body = card.height - HUDTheme.headerHeight - 1
            - HUD.rewriteExtraHeight(blockedCard(veryLong))
        XCTAssertEqual(body, HUDTranscript.maxBodyHeight, accuracy: 1, "the body scrolls at its cap")
    }

    func testTheLayerOnlyShowsWhatItsPhaseAllows() {
        let text = "Send it."
        var card = offeredCard(text)
        XCTAssertTrue(card.showsChips)
        XCTAssertFalse(card.showsRewrite)
        XCTAssertFalse(card.isStreaming)

        card.phase = .rewriting(styleID: "concise", title: "Concise")
        XCTAssertTrue(card.isStreaming)
        XCTAssertTrue(card.showsChips, "another chip can be picked while one runs")
        XCTAssertEqual(card.activeStyleID, "concise")

        card.phase = .blocked(styleID: "concise", error: FaithfulnessCheck.numberChanged)
        XCTAssertFalse(card.showsChips, "a refused rewrite asks one question, not another style")
        XCTAssertTrue(card.showsRewrite)

        card.append(id: 1, style: .concise, text: text, warning: nil)
        card.phase = .applied(versionID: 1)
        XCTAssertTrue(card.showsChips, "a second style starts from the original")
        XCTAssertEqual(card.selectedVersion.styleID, "concise")
    }

    func testTheCardKeepsTheVersionsForAMinute() {
        XCTAssertEqual(HUDDwell.rewriteSeconds, 60)
        XCTAssertEqual(HUDDwell.rewriteLeaveSeconds, 60)
        XCTAssertGreaterThan(HUDDwell.rewriteSeconds, HUDDwell.maximumSeconds)
    }

    // MARK: - The header

    func testTheHeaderNamesTheRewriteAndTheApplication() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.phase = .applied(versionID: 1)
        card.deliveryDestination = "Mail"
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REWRITTEN IN MAIL"
        )
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .copied, destination: "Mail"),
            "REWRITTEN IN MAIL",
            "the explicit paste named the field it actually wrote into"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Rewritten into Mail"
        )
    }

    func testAppliedPasteWithoutARecordedTargetIsNeutral() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.phase = .applied(versionID: 1)
        // The take's destination is Mail, but no actual cursor target was
        // recorded. Naming Mail would claim a delivery that may have gone
        // elsewhere.
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REWRITTEN"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Rewritten"
        )
    }

    func testTheClipboardOutcomeKeepsTheWordCopied() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.phase = .copied(versionID: 1)
        XCTAssertEqual(HUDHeader.title(for: card, delivery: .copied, destination: nil), "COPIED")
        XCTAssertEqual(HUDHeader.accessibilityLabel(for: card, delivery: .copied, destination: nil), "Copied")
    }

    func testAnOfferedCardKeepsTheTranscriptHeader() {
        let card = offeredCard(HUDPreview.transcript)
        let deliveryTitle = HUDHeader.title(delivery: .pasted, destination: "Mail")
        XCTAssertEqual(HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"), deliveryTitle)
        XCTAssertEqual(deliveryTitle, "PASTED INTO MAIL")
    }

    // MARK: - What the header names on a versioned card

    func testAGeneratedVersionWithoutDeliverySaysPreview() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PREVIEW"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Preview"
        )
    }

    func testTheOriginalVersionKeepsTheTakeDeliveryEvenWithVersions() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.select(versionID: 0)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PASTED INTO MAIL"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Pasted into Mail"
        )
        // An explicit paste of the original says PASTED, and names only the
        // field it actually wrote into, never the take's old destination.
        card.phase = .applied(versionID: 0)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PASTED"
        )
        card.deliveryDestination = "Notes"
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PASTED INTO NOTES"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Pasted into Notes"
        )
    }

    func testAStreamingRewriteSaysRewriting() {
        var card = offeredCard(HUDPreview.transcript)
        card.phase = .rewriting(styleID: "concise", title: "Concise")
        card.draft = "Dot records"
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REWRITING"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Rewriting"
        )
    }

    func testABlockedRewriteSaysReview() {
        var card = offeredCard(HUDPreview.transcript)
        card.phase = .blocked(styleID: "concise", error: FaithfulnessCheck.numberChanged)
        card.draft = HUDPreview.rewrite
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REVIEW"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Review"
        )
    }

    func testCopyThenNavigatingAwayAndBackSaysPreview() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.phase = .copied(versionID: 1)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "COPIED"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Copied"
        )

        card.select(versionID: 0)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PASTED INTO MAIL"
        )
        card.select(versionID: 1)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PREVIEW",
            "the copy of another selection is still being reported"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Preview"
        )
    }

    func testPasteThenNavigatingAwayAndBackSaysPreview() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.phase = .applied(versionID: 1)
        card.deliveryDestination = "Mail"
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REWRITTEN IN MAIL"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Rewritten into Mail"
        )

        card.select(versionID: 0)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PASTED INTO MAIL"
        )
        card.select(versionID: 1)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PREVIEW",
            "the paste of another selection is still being reported"
        )
    }

    func testADeliveryPhaseForAnotherVersionDoesNotDescribeTheSelection() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.append(id: 2, style: .formal, text: HUDPreview.rewrite, warning: nil)
        card.phase = .copied(versionID: 1)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PREVIEW"
        )
        card.phase = .applied(versionID: 1)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PREVIEW"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Preview"
        )
    }

    func testCopyingTheOriginalSaysCopied() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.select(versionID: 0)
        card.phase = .copied(versionID: 0)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "COPIED"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Copied"
        )
    }

    func testCursorPasteIntoAnotherAppNamesThatApp() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.phase = .applied(versionID: 1)
        card.deliveryDestination = "Notes"
        // The take was pasted into Mail originally; the explicit cursor paste
        // went to Notes and that is the only application the header may name.
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REWRITTEN IN NOTES"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Rewritten into Notes"
        )
    }

    func testTheRewrittenTitleIsCutToTheHeaderCap() {
        var card = offeredCard(HUDPreview.transcript)
        card.append(id: 1, style: .concise, text: HUDPreview.rewrite, warning: nil)
        card.phase = .applied(versionID: 1)
        let long = String(repeating: "Wide Application ", count: 8)
        card.deliveryDestination = long
        let title = HUDHeader.title(for: card, delivery: .pasted, destination: "Mail")
        XCTAssertLessThanOrEqual(HUDHeader.width(of: title), HUDHeader.maximumTitleWidth)
        XCTAssertTrue(title.hasSuffix("…"))
    }
}

extension HUDRewriteLayoutTests {
    // MARK: - The chip row

    /// Every built-in chip at its label's width, gaps included.
    private func chipRowWidth(_ styles: [RewriteStyle]) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: HUDRewriteLayout.chipFontSize, weight: .medium),
        ]
        let widths = styles.map { style in
            ceil((style.title as NSString).size(withAttributes: attributes).width)
                + HUDRewriteLayout.chipHPadding * 2
        }
        return widths.reduce(0, +)
            + CGFloat(max(0, widths.count - 1)) * HUDRewriteLayout.chipGap
    }

    /// The five shipped chips still draw in one row.
    ///
    /// The card's height is the height of one chip row (``HUDRewriteLayout``
    /// budgets it once), so a sixth built-in style would have to be measured
    /// here before it ships. The styles that were absorbed left room in the
    /// budget rather than taking it.
    func testTheFiveChipsFitOneRow() {
        let width = chipRowWidth(RewriteStyle.builtIns)
        let available = HUDState.transcriptWidth - HUDTheme.padding * 2
        XCTAssertLessThanOrEqual(
            width,
            available,
            "the chips need \(width) pt of a \(available) pt row"
        )
        XCTAssertEqual(RewriteStyle.builtIns.map(\.title), [
            "Agent prompt", "Concise", "Professional", "Casual", "Gen Z",
        ])
        XCTAssertEqual(
            HUD.rewriteExtraHeight(offeredCard(HUDPreview.transcript)),
            HUDRewriteLayout.rowTopGap + HUDRewriteLayout.chipHeight + HUDState.verticalPadding,
            "a sixth chip may not add a second row to the card"
        )
    }

    func testAnAppliedPromptCardFitsThePanel() {
        let text = HUDPreview.transcript
        var card = offeredCard(text)
        card.append(
            id: 1,
            style: .prompt,
            text: HUDPreview.promptRewrite,
            warning: nil
        )
        card.phase = .applied(versionID: 1)
        let size = HUD.transcriptSize(text: text, rewrite: card)
        XCTAssertLessThanOrEqual(size.height, HUD.maximumCardHeight)
        let body = size.height - HUDTheme.headerHeight - 1
            - HUD.rewriteExtraHeight(card)
        XCTAssertEqual(body, HUDTranscript.maxBodyHeight, accuracy: 1, "the body scrolls at its cap")
    }
}
