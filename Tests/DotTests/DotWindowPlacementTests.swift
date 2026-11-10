import CoreGraphics
@testable import Dot
import XCTest

/// The light-window geometry is pure, so it is tested without a display.
@MainActor
final class DotWindowPlacementTests: XCTestCase {
    private let welcome = CGSize(width: 720, height: 560)

    func testTheWelcomeIsCentredOnTheBuiltInDisplay() {
        // The display this bug was reported on: 1470 x 956, a 59-point menu
        // bar and a 33-point Dock. A zero-width window would be centred at
        // x = 735; the real 720-point window must sit at x = 375. The light
        // windows use .fullSizeContentView, so the window frame and its
        // content rect share this origin and size.

        let visible = CGRect(x: 0, y: 59, width: 1470, height: 864)

        let frame = DotWindowPlacement.contentFrame(
            contentSize: welcome,
            visibleFrame: visible
        )

        XCTAssertEqual(frame.origin.x, 375, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 211, accuracy: 0.001)
        XCTAssertEqual(frame.size, welcome)
        XCTAssertTrue(visible.contains(frame), "the welcome is outside the visible frame")
    }

    func testTheWindowIsCentredOnASecondScreenWithANegativeOrigin() {
        let visible = CGRect(x: -1920, y: 59, width: 1920, height: 800)

        let frame = DotWindowPlacement.contentFrame(
            contentSize: welcome,
            visibleFrame: visible
        )

        XCTAssertEqual(frame.origin.x, -1320, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 179, accuracy: 0.001)
        XCTAssertEqual(frame.size, welcome)
        XCTAssertTrue(visible.contains(frame), "the welcome is outside the second screen")
    }

    func testAWindowLargerThanTheScreenKeepsItsSizeAndIsPinnedOnScreen() {
        let visible = CGRect(x: 0, y: 59, width: 500, height: 300)

        let frame = DotWindowPlacement.contentFrame(
            contentSize: welcome,
            visibleFrame: visible
        )

        XCTAssertEqual(frame.size, welcome, "the fixed content must not be shrunk")
        XCTAssertEqual(frame.origin.x, visible.minX, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, visible.minY, accuracy: 0.001)
    }

    func testAnAbsentOrInvertedVisibleFrameDoesNotProduceNaN() {
        let absent = DotWindowPlacement.contentFrame(
            contentSize: welcome,
            visibleFrame: .zero
        )
        XCTAssertEqual(absent, CGRect(origin: .zero, size: welcome))

        let inverted = CGRect(x: 1470, y: 956, width: -1470, height: -864)
        let frame = DotWindowPlacement.contentFrame(
            contentSize: welcome,
            visibleFrame: inverted
        )
        XCTAssertEqual(frame.size, welcome)
        XCTAssertTrue(inverted.standardized.contains(frame))
    }

    func testAnOffScreenWindowIsBroughtBackButAMovedOneIsKept() {
        let builtIn = CGRect(x: 0, y: 59, width: 1470, height: 864)
        let external = CGRect(x: -1920, y: 59, width: 1920, height: 800)
        let screens = [builtIn, external]

        XCTAssertTrue(
            DotWindowPlacement.isOnScreen(
                CGRect(x: 375, y: 211, width: 720, height: 560),
                visibleFrames: screens
            ),
            "a centred window is on screen"
        )
        XCTAssertTrue(
            DotWindowPlacement.isOnScreen(
                CGRect(x: 1370, y: 211, width: 720, height: 560),
                visibleFrames: screens
            ),
            "a window moved mostly past the right edge is still grabbable"
        )
        XCTAssertTrue(
            DotWindowPlacement.isOnScreen(
                CGRect(x: -1400, y: 200, width: 720, height: 560),
                visibleFrames: screens
            ),
            "a window moved to the second screen is on screen"
        )
        XCTAssertFalse(
            DotWindowPlacement.isOnScreen(
                CGRect(x: 1460, y: 211, width: 720, height: 560),
                visibleFrames: screens
            ),
            "only ten points of a window is not enough to grab"
        )
        XCTAssertFalse(
            DotWindowPlacement.isOnScreen(
                CGRect(x: 4000, y: 4000, width: 720, height: 560),
                visibleFrames: screens
            ),
            "a window no screen contains is off screen"
        )
        XCTAssertFalse(
            DotWindowPlacement.isOnScreen(
                CGRect(x: 375, y: 211, width: 720, height: 560),
                visibleFrames: []
            ),
            "without a screen the window cannot be on screen"
        )
        XCTAssertFalse(
            DotWindowPlacement.isOnScreen(
                .zero,
                visibleFrames: screens
            ),
            "a zero-sized window is never on screen"
        )
    }

    func testTheVisibleExtentThresholdUsesTheSmallerWindowDimension() {
        let visible = CGRect(x: 0, y: 59, width: 1470, height: 864)

        XCTAssertTrue(
            DotWindowPlacement.isOnScreen(
                CGRect(x: 1440, y: 211, width: 30, height: 560),
                visibleFrames: [visible]
            ),
            "a window narrower than the threshold only needs its own width visible"
        )
        XCTAssertFalse(
            DotWindowPlacement.isOnScreen(
                CGRect(x: 1450, y: 211, width: 30, height: 560),
                visibleFrames: [visible]
            ),
            "twenty visible points of a thirty-point window is not enough"
        )
    }
}
