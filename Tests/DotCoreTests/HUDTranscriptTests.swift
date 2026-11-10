import CoreGraphics
import XCTest

@testable import DotCore

/// The height of the transcript body, and the point at which it scrolls.
final class HUDTranscriptTests: XCTestCase {
    func testAShortTranscriptFitsWithoutScrolling() {
        // One line of the transcript and the padding around it.
        let content: CGFloat = 22 + 26

        XCTAssertEqual(HUDTranscript.bodyHeight(contentHeight: content), content)
        XCTAssertFalse(HUDTranscript.scrolls(contentHeight: content))
        XCTAssertFalse(HUDTranscript.scrolls(contentHeight: HUDTranscript.minBodyHeight))
    }

    func testABodyThatExactlyFitsDoesNotScroll() {
        XCTAssertEqual(HUDTranscript.bodyHeight(contentHeight: 180), 180)
        XCTAssertFalse(HUDTranscript.scrolls(contentHeight: 180))
        XCTAssertTrue(HUDTranscript.scrolls(contentHeight: 180.5))
    }

    func testALongTranscriptIsClampedAndScrolls() {
        XCTAssertEqual(HUDTranscript.bodyHeight(contentHeight: 400), HUDTranscript.maxBodyHeight)
        XCTAssertEqual(HUDTranscript.bodyHeight(contentHeight: 181), 180)
        XCTAssertTrue(HUDTranscript.scrolls(contentHeight: 400))

        // The limit is what the request asked for: a card that stays around two
        // hundred points tall with its header.
        XCTAssertEqual(HUDState.headerHeight + HUDTranscript.maxBodyHeight, 224, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(HUDTranscript.maxBodyHeight, 170)
        XCTAssertLessThanOrEqual(HUDTranscript.maxBodyHeight, 200)
    }

    func testTheBodyNeverCollapsesBelowOneLine() {
        XCTAssertEqual(HUDTranscript.bodyHeight(contentHeight: 0), HUDTranscript.minBodyHeight)
        XCTAssertEqual(HUDTranscript.bodyHeight(contentHeight: -40), HUDTranscript.minBodyHeight)
        XCTAssertEqual(HUDTranscript.bodyHeight(contentHeight: .nan), HUDTranscript.minBodyHeight)
        XCTAssertEqual(HUDTranscript.bodyHeight(contentHeight: .infinity), HUDTranscript.maxBodyHeight)
        XCTAssertFalse(HUDTranscript.scrolls(contentHeight: .nan))
    }

    func testTheCardGrowsWithTheTextAndThenStops() {
        let one = HUDState.transcriptCard(bodyHeight: HUDTranscript.bodyHeight(contentHeight: 48))
        let three = HUDState.transcriptCard(bodyHeight: HUDTranscript.bodyHeight(contentHeight: 92))
        let long = HUDState.transcriptCard(bodyHeight: HUDTranscript.bodyHeight(contentHeight: 4_000))

        XCTAssertLessThan(one.height, three.height)
        XCTAssertEqual(long.height, HUDState.headerHeight + HUDTranscript.maxBodyHeight)
        XCTAssertEqual(three.height, HUDState.headerHeight + 92)
    }
}
