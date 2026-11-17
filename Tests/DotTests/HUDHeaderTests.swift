import AppKit
import DotCore
@testable import Dot
import XCTest

/// The header of the transcript card names where the words went.
///
/// The label is short at the best of times and an application name is as long
/// as its maker likes, so the two things that can go wrong are a header that
/// claims a paste into nothing and a long name that pushes the clock and the
/// buttons out of the card. Both are measured rather than eyeballed.
final class HUDHeaderTests: XCTestCase {
    func testAPasteNamesTheApplication() {
        XCTAssertEqual(
            HUDHeader.title(delivery: .pasted, destination: "Mail"),
            "PASTED INTO MAIL"
        )
    }

    func testAPasteWithoutANameIsOnlyAPaste() {
        XCTAssertEqual(HUDHeader.title(delivery: .pasted, destination: nil), "PASTED")
        XCTAssertEqual(HUDHeader.title(delivery: .pasted, destination: ""), "PASTED")
        XCTAssertEqual(HUDHeader.title(delivery: .pasted, destination: "   "), "PASTED")
    }

    func testALongNameIsCutWithAnEllipsis() {
        let title = HUDHeader.title(
            delivery: .pasted,
            destination: "Microsoft Visual Studio Code Insiders"
        )

        XCTAssertTrue(title.hasPrefix("PASTED INTO "), "the delivery words were cut: \(title)")
        XCTAssertTrue(title.hasSuffix("…"), "the cut is not marked: \(title)")
        XCTAssertTrue(title.contains("MICROSOFT"), "the name was lost entirely: \(title)")
        XCTAssertFalse(title.contains("INSIDERS"), "the name was not cut at all: \(title)")
        XCTAssertLessThanOrEqual(
            HUDHeader.width(of: title),
            HUDHeader.maximumTitleWidth,
            "the title is wider than the room the header has"
        )
    }

    func testACopiedTranscriptKeepsItsWording() {
        XCTAssertEqual(HUDHeader.title(delivery: .copied, destination: "Mail"), "COPIED")
        XCTAssertEqual(HUDHeader.title(delivery: .copied, destination: nil), "COPIED")
        XCTAssertEqual(HUDHeader.title(delivery: .failed, destination: "Mail"), "FAILED")
    }

    func testTheHeaderIsReadAsASentence() {
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(delivery: .pasted, destination: "Mail"),
            "Pasted into Mail"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(delivery: .pasted, destination: nil),
            "Pasted"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(delivery: .copied, destination: "Mail"),
            "Copied"
        )
    }

    @MainActor
    func testAnInlineEditKeepsTheDestination() {
        let model = HUDModel()
        model.mode = .transcript(
            text: "One line.",
            delivery: .pasted,
            elapsed: "0:02",
            destination: "Mail"
        )

        model.updateTranscriptText("One line, edited.")

        XCTAssertEqual(
            model.mode,
            .transcript(
                text: "One line, edited.",
                delivery: .pasted,
                elapsed: "0:02",
                destination: "Mail"
            )
        )
    }

    /// A copy is acknowledged once, never twice with two verdicts.
    ///
    /// The owner's report: after Copy the header said COPIED and the check badge
    /// still said Review. Both describe the selected version, so the card was
    /// speaking two answers at once. The check is not erased from the version —
    /// the warning is still there for the tooltip — it is only not drawn beside
    /// the acknowledgement of the same version.
    @MainActor
    func testACopiedVersionDoesNotAlsoAskForReview() {
        var card = warnedCard()
        XCTAssertEqual(card.warning, Self.warning, "the fixture has no warning to contradict")

        let preview = HUDHeader.title(for: card, delivery: .pasted, destination: "Mail")
        XCTAssertEqual(preview, "PREVIEW", "an offered version does not claim a delivery")
        XCTAssertTrue(
            HUDView.showsCheckBadge(card),
            "the check is not drawn for an offered version with a warning"
        )

        card.phase = .copied(versionID: 1)

        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "COPIED",
            "the header does not acknowledge the Copy"
        )
        XCTAssertEqual(
            card.warning,
            Self.warning,
            "the Copy erased the mechanical warning from the version"
        )
        XCTAssertFalse(
            HUDView.showsCheckBadge(card),
            "the badge says Review beside a header that says COPIED"
        )

        card.phase = .applied(versionID: 1)
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REWRITTEN",
            "the header does not acknowledge the Paste of a generated version"
        )
        XCTAssertFalse(
            HUDView.showsCheckBadge(card),
            "the badge says Review beside a header that says REWRITTEN"
        )
    }

    /// A Copy of the original shows neither a delivery contradiction nor a check:
    /// the original is not a version the mechanical rules run on.
    @MainActor
    func testACopiedOriginalDoesNotAskForReview() {
        var card = warnedCard()
        card.select(versionID: 0)
        card.phase = .copied(versionID: 0)

        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "COPIED"
        )
        XCTAssertFalse(
            HUDView.showsCheckBadge(card),
            "the original has no model version for the check to describe"
        )
    }

    /// A click that copies nothing leaves the check exactly where it was.
    ///
    /// `copySelected` refuses a click drawn against a different version, and the
    /// refusal must not read as a delivery: the phase stays offered, the header
    /// keeps the preview title, and the warning is still shown.
    @MainActor
    func testACopyThatDidNothingKeepsTheReview() {
        let card = warnedCard()

        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PREVIEW"
        )
        XCTAssertTrue(HUDView.showsCheckBadge(card))
    }

    /// Copying, then moving to another version, brings the check back.
    ///
    /// `select` drops the delivery state, so the header stops saying COPIED and
    /// the new version's warning is the current one again.
    @MainActor
    func testMovingTheSelectionAfterCopyBringsTheReviewBack() {
        var card = warnedCard()
        card.phase = .copied(versionID: 1)
        XCTAssertFalse(HUDView.showsCheckBadge(card))

        XCTAssertTrue(card.select(versionID: 2), "the second version could not be selected")

        XCTAssertEqual(card.phase, .offered, "the Copy was not dropped with the selection")
        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PREVIEW",
            "the header still acknowledges a version that is no longer on screen"
        )
        XCTAssertTrue(
            HUDView.showsCheckBadge(card),
            "the badge did not return with the new version's warning"
        )
    }

    /// A delivery recorded for another version never suppresses the check for
    /// the version that is actually on screen.
    @MainActor
    func testADeliveryForAnotherVersionLeavesTheReviewAlone() {
        var card = warnedCard()
        card.phase = .copied(versionID: 1)
        XCTAssertTrue(card.select(versionID: 2))
        card.phase = .copied(versionID: 1)

        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "PREVIEW",
            "the header names a delivery that belongs to a hidden version"
        )
        XCTAssertTrue(
            HUDView.showsCheckBadge(card),
            "another version's delivery hid this version's check"
        )
    }

    /// A failed request names itself, and the version the person was reading is
    /// still selected and still deliverable.
    ///
    /// The pending-fix report: a failed card said PREVIEW and drew the check
    /// badge, so the header's two marks described a version and never the
    /// request that did not finish. The failure now has its own title, its own
    /// glyph, and no check.
    @MainActor
    func testAFailedRewriteIsNamedAndItsVersionStaysDeliverable() {
        var card = warnedCard()
        card.phase = .failed
        card.note = RewriteCard.failureNote

        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REWRITE FAILED",
            "the failed card still reads as a version preview"
        )
        XCTAssertEqual(
            HUDHeader.accessibilityLabel(for: card, delivery: .pasted, destination: "Mail"),
            "Rewrite failed"
        )
        XCTAssertFalse(
            HUDView.showsCheckBadge(card),
            "the failure header drew the check as a second verdict"
        )
        XCTAssertTrue(card.canDeliverSelected, "the failure locked the selected version")
        XCTAssertEqual(card.selectedVersionID, 1, "the failure moved the selection")
        XCTAssertEqual(card.selectedVersion.text, "One sentence, tightened.")
        XCTAssertEqual(card.warning, Self.warning, "the failure erased the version's warning")
    }

    /// A failure that arrived before any version existed still names itself.
    @MainActor
    func testAFailedRewriteOnTheOriginalStillNamesTheFailure() {
        var card = warnedCard()
        card.select(versionID: 0)
        card.phase = .failed

        XCTAssertEqual(
            HUDHeader.title(for: card, delivery: .pasted, destination: "Mail"),
            "REWRITE FAILED"
        )
        XCTAssertFalse(HUDView.showsCheckBadge(card))
    }

    /// A generated version with a mechanical warning, selected, in the offered
    /// phase: the state a Copy click starts from.
    private func warnedCard() -> RewriteCard {
        let professional = RewriteStyle.builtIns[2]
        let versions = [
            RewriteVersion.original(text: "One sentence."),
            RewriteVersion(
                id: 1,
                origin: .style(RewriteStyle.concise.id),
                title: RewriteStyle.concise.title,
                text: "One sentence, tightened.",
                ordinal: 1,
                warning: Self.warning
            ),
            RewriteVersion(
                id: 2,
                origin: .style(professional.id),
                title: professional.title,
                text: "One sentence, professionally.",
                ordinal: 1,
                warning: "A negation was dropped."
            ),
        ]
        return RewriteCard(
            original: "One sentence.",
            choices: RewriteStyle.builtIns,
            versions: versions,
            selectedVersionID: 1
        )
    }

    private static let warning = "A number changed: 12 to 13."

    @MainActor
    func testTheDocumentationRenderNamesMail() {
        let model = HUDPreview.makeModel(state: .transcript)

        guard case .transcript(_, let delivery, _, let destination) = model.mode else {
            return XCTFail("the transcript render is not a transcript card")
        }
        XCTAssertEqual(delivery, .pasted)
        XCTAssertEqual(destination, "Mail")
    }
}
