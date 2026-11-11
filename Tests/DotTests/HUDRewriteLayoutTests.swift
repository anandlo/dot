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
            rewrite: original,
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
        card.phase = .copied(styleID: "concise")
        card.rewrite = text
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

    func testTheRunningCardReservesTheDimmedOriginalAndTheChips() {
        let text = HUDPreview.transcript
        var card = offeredCard(text)
        card.phase = .rewriting(styleID: "concise", title: "Concise")
        card.rewrite = "Dot records the microphone and pastes the words back."
        let plain = HUD.transcriptSize(text: text)
        let running = HUD.transcriptSize(text: text, rewrite: card)
        let dimmed = CGFloat(HUDRewriteLayout.dimmedOriginalLines)
            * HUDRewriteLayout.dimmedLineHeight
            + HUDRewriteLayout.dimmedGap
        XCTAssertGreaterThanOrEqual(running.height, plain.height + dimmed - 1)
        XCTAssertLessThanOrEqual(running.height, plain.height + dimmed + 120)
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

        card.phase = .applied(styleID: "concise")
        XCTAssertTrue(card.showsChips, "a second style rewrites the original")
        XCTAssertEqual(card.activeStyleID, "concise")
    }

    func testTheCardOffersTheChipsForEightSeconds() {
        XCTAssertEqual(HUDDwell.rewriteSeconds, 8)
        XCTAssertEqual(HUDDwell.rewriteLeaveSeconds, 3)
        XCTAssertGreaterThan(HUDDwell.rewriteSeconds, HUDDwell.defaultSeconds - 2.1)
    }

    // MARK: - The header

    func testTheHeaderNamesTheRewriteAndTheApplication() {
        var card = offeredCard(HUDPreview.transcript)
        card.phase = .applied(styleID: "concise")
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REWRITTEN IN MAIL"
        )
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .copied, destination: "Mail"),
            "REWRITTEN",
            "nothing was pasted, so no application is named"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Rewritten into Mail"
        )
    }

    func testTheClipboardOutcomeKeepsTheWordCopied() {
        var card = offeredCard(HUDPreview.transcript)
        card.phase = .copied(styleID: "concise")
        XCTAssertEqual(HUDHeader.title(for: card, delivery: .copied, destination: nil), "COPIED")
        XCTAssertEqual(HUDHeader.accessibilityLabel(for: card, delivery: .copied, destination: nil), "Copied")
    }

    func testAnOfferedCardKeepsTheTranscriptHeader() {
        let card = offeredCard(HUDPreview.transcript)
        let deliveryTitle = HUDHeader.title(delivery: .pasted, destination: "Mail")
        XCTAssertEqual(HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"), deliveryTitle)
        XCTAssertEqual(deliveryTitle, "PASTED INTO MAIL")
    }

    func testTheRewrittenTitleIsCutToTheHeaderCap() {
        var card = offeredCard(HUDPreview.transcript)
        card.phase = .applied(styleID: "concise")
        let long = String(repeating: "Wide Application ", count: 8)
        let title = HUDHeader.title(for: card, delivery: .pasted, destination: long)
        XCTAssertLessThanOrEqual(HUDHeader.width(of: title), HUDHeader.maximumTitleWidth)
        XCTAssertTrue(title.hasSuffix("…"))
    }
}
