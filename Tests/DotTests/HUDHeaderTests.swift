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
