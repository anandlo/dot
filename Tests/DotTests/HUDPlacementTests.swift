import CoreGraphics
@testable import Dot
import XCTest

/// The panel's placement is pure geometry, so it is tested without a display.
@MainActor
final class HUDPlacementTests: XCTestCase {
    private let panel = CGSize(width: 640, height: 340)

    func testThePanelIsCentredUnderTheTopOfABuiltInDisplay() {
        // The built-in display this bug was reported on: 1470 x 956, with a
        // 59-point menu bar and a 33-point Dock in the visible frame.
        let visible = CGRect(x: 0, y: 59, width: 1470, height: 864)

        let frame = HUDPlacement.frame(
            visibleFrame: visible,
            panelSize: panel,
            topInset: 10
        )

        XCTAssertEqual(frame.origin.x, 415, accuracy: 0.001)
        XCTAssertEqual(frame.width, 640, accuracy: 0.001)
        XCTAssertEqual(frame.height, 340, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, visible.maxY - 10, accuracy: 0.001)
        XCTAssertTrue(visible.contains(frame), "the panel is outside the visible frame")
        XCTAssertEqual(
            HUDPlacement.origin(visibleFrame: visible, panelSize: panel, topInset: 10),
            frame.origin
        )
    }

    func testAnOversizedPanelAndTopInsetAreClampedIntoTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 59, width: 500, height: 220)

        let frame = HUDPlacement.frame(
            visibleFrame: visible,
            panelSize: panel,
            topInset: 10_000
        )

        XCTAssertEqual(frame.width, 500, accuracy: 0.001)
        XCTAssertEqual(frame.height, 220, accuracy: 0.001)
        XCTAssertEqual(frame.origin.x, visible.minX, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, visible.minY, accuracy: 0.001)
        XCTAssertTrue(visible.contains(frame), "the clamped panel is outside the visible frame")
    }

    func testAnAbsentOrOffScreenFrameNeverProducesNaN() {
        let frame = HUDPlacement.frame(
            visibleFrame: .zero,
            panelSize: panel,
            topInset: 10
        )
        XCTAssertEqual(frame.origin.x, 0)
        XCTAssertEqual(frame.origin.y, 0)
        XCTAssertEqual(frame.width, 640)
        XCTAssertEqual(frame.height, 340)

        let inverted = CGRect(x: 1470, y: 956, width: -1470, height: -864)
        let standardised = HUDPlacement.frame(
            visibleFrame: inverted,
            panelSize: panel,
            topInset: 10
        )
        XCTAssertEqual(standardised.size, panel)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1470, height: 956).contains(standardised))
    }

    func testASecondScreenWithANegativeOriginWorks() {
        let visible = CGRect(x: -1920, y: 59, width: 1920, height: 800)

        let frame = HUDPlacement.frame(
            visibleFrame: visible,
            panelSize: panel,
            topInset: 10
        )

        XCTAssertEqual(frame.origin.x, -1280, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, visible.maxY - 10, accuracy: 0.001)
        XCTAssertTrue(visible.contains(frame), "the panel is outside the second screen")
    }

    func testTheCardIsTheTopCentreOfThePanel() {
        // The panel the HUD places on the built-in display, with the shadow
        // margin around a 560 x 225 transcript card.
        let panelFrame = CGRect(x: 415, y: 583, width: 640, height: 340)
        let card = CGSize(width: 560, height: 225)

        let frame = HUDPlacement.cardFrame(
            panelFrame: panelFrame,
            cardSize: card,
            topInset: 28
        )

        XCTAssertEqual(frame.midX, panelFrame.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, panelFrame.maxY - 28, accuracy: 0.001)
        XCTAssertEqual(frame.size, card)
        XCTAssertTrue(panelFrame.contains(frame))

        // The margin around the card is not the card: a pointer there is not
        // reading the transcript.
        XCTAssertFalse(frame.contains(CGPoint(x: panelFrame.midX, y: panelFrame.maxY - 10)))
        XCTAssertTrue(frame.contains(CGPoint(x: panelFrame.midX, y: frame.midY)))
    }

    func testACardFrameThatIsNotANumberNeverProducesNaN() {
        let frame = HUDPlacement.cardFrame(
            panelFrame: CGRect(x: 0, y: 0, width: 640, height: 340),
            cardSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity),
            topInset: CGFloat.nan
        )

        XCTAssertEqual(frame.origin.x, 320, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 340, accuracy: 0.001)
        XCTAssertEqual(frame.width, 0)
        XCTAssertEqual(frame.height, 0)
        XCTAssertFalse(frame.contains(CGPoint(x: 320, y: 339)))
    }

    func testTheMouseScreenWinsAndAnAbsentMouseFallsBack() {
        let frames = [
            CGRect(x: 0, y: 59, width: 1470, height: 864),
            CGRect(x: -1920, y: 59, width: 1920, height: 800),
        ]

        XCTAssertEqual(
            HUDPlacement.screenIndex(containing: CGPoint(x: -500, y: 500), frames: frames, fallback: 0),
            1
        )
        XCTAssertEqual(
            HUDPlacement.screenIndex(containing: CGPoint(x: 700, y: 500), frames: frames, fallback: 1),
            0
        )
        XCTAssertEqual(
            HUDPlacement.screenIndex(containing: CGPoint(x: 9000, y: 9000), frames: frames, fallback: 1),
            1
        )
        XCTAssertEqual(
            HUDPlacement.screenIndex(containing: CGPoint(x: 9000, y: 9000), frames: frames, fallback: nil),
            0
        )
        XCTAssertNil(HUDPlacement.screenIndex(containing: .zero, frames: [], fallback: nil))
    }
}
