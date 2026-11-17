import AppKit
@testable import Dot
import SwiftUI
import XCTest

/// The bar at the trailing edge of a list.
///
/// The bar is drawn over the scrolling content, and where it lands is a fact
/// about the drawing rather than about the model: the numbers it is given are
/// the same whether it hangs from the top of the card or from its middle. These
/// tests read the pixels back at the three positions the list can be in and
/// assert where the bar is: always inside the track, six points short of each
/// end of the card, and three short of its trailing edge.
@MainActor
final class DotSelectScrollerTests: XCTestCase {
    /// The bar hangs from the top of its track when the list opens.
    func testTheBarStartsAtTheTopOfItsTrack() throws {
        let page = try CapturePage(scheme: .light)
        defer { page.close() }
        let shot = try page.openList()
        let inset = DotSelectListMetrics.scrollerTrackInset

        let span = try XCTUnwrap(shot.scrollerSpan(), "no bar is drawn at the top of the list")
        let thumb = try XCTUnwrap(page.thumb, "the model has no bar to draw")
        XCTAssertEqual(span.top, thumb.offset, accuracy: 2, "the bar does not start at the top of the track")
        XCTAssertEqual(span.bottom, thumb.offset + thumb.height, accuracy: 2)
        XCTAssertGreaterThanOrEqual(span.top, inset - 1.5, "the bar is drawn on the card's corner")
        XCTAssertLessThanOrEqual(
            span.bottom,
            shot.cardHeightInPoints - inset + 1.5,
            "the bar runs past the foot of its track"
        )
    }

    /// Half way down, the bar is half way down its track.
    func testTheBarFollowsTheListInTheMiddle() throws {
        let page = try CapturePage(scheme: .light)
        defer { page.close() }
        _ = try page.openList()
        page.scrollList(to: 805)
        let shot = try page.capture()
        let inset = DotSelectListMetrics.scrollerTrackInset

        let span = try XCTUnwrap(shot.scrollerSpan(), "no bar is drawn in the middle of the list")
        let thumb = try XCTUnwrap(page.thumb, "the model has no bar to draw")
        XCTAssertEqual(span.top, thumb.offset, accuracy: 2, "the bar is not where the list is scrolled to")
        XCTAssertEqual(span.bottom, thumb.offset + thumb.height, accuracy: 2)
        XCTAssertGreaterThan(span.top, inset - 1.5, "the bar starts on the card's top corner")
        XCTAssertLessThan(span.bottom, shot.cardHeightInPoints - inset + 1.5, "the bar touches the foot")
    }

    /// At the foot of the list the bar's own foot is the foot of its track,
    /// six points short of the card's.
    func testTheBarEndsAtTheFootOfItsTrack() throws {
        let page = try CapturePage(scheme: .dark)
        defer { page.close() }
        _ = try page.openList()
        page.scrollList(to: 10_000)
        let shot = try page.capture()
        let inset = DotSelectListMetrics.scrollerTrackInset

        let span = try XCTUnwrap(shot.scrollerSpan(), "no bar is drawn at the foot of the list")
        let thumb = try XCTUnwrap(page.thumb, "the model has no bar to draw")
        XCTAssertEqual(span.top, thumb.offset, accuracy: 2, "the bar is not at the foot of the list")
        XCTAssertEqual(
            span.bottom,
            shot.cardHeightInPoints - inset,
            accuracy: 2,
            "the bar leaves the card at its foot"
        )
        XCTAssertGreaterThanOrEqual(span.top, inset - 1.5, "the bar is drawn on the card's corner")
        XCTAssertLessThanOrEqual(span.bottom, shot.cardHeightInPoints - inset + 1.5)
    }

    /// A list that fits draws neither a track nor a bar, because there is
    /// nothing to scroll and nothing to promise.
    func testAShortListDrawsNoBar() throws {
        let page = try CapturePage(scheme: .light, rows: 3)
        defer { page.close() }
        let shot = try page.openList()

        XCTAssertNil(page.thumb, "a list that fits has nothing to scroll")
        XCTAssertNil(shot.scrollerSpan(), "a bar is drawn on a list that fits")
        XCTAssertNil(shot.trackSpan(), "a track is drawn on a list that fits")
    }

    /// The cue outlives the movement: once the list has rested, the track still
    /// runs the whole card and the bar is still on it. A long list that draws
    /// nothing at its edge cannot be told from a list that has ended — the cut
    /// row at the foot sometimes lands on a row boundary and reads as the end.
    func testTheTrackAndBarStayAfterTheListRests() throws {
        let page = try CapturePage(scheme: .light)
        defer { page.close() }
        _ = try page.openList()
        page.wait(1.3)
        let shot = try page.capture()
        let inset = DotSelectListMetrics.scrollerTrackInset

        XCTAssertFalse(page.fades.scrolling, "the list has not rested")
        let track = try XCTUnwrap(shot.trackSpan(), "the overflow is invisible once the list rests")
        XCTAssertEqual(track.top, inset, accuracy: 2, "the track does not start inside the card")
        XCTAssertEqual(
            track.bottom,
            shot.cardHeightInPoints - inset,
            accuracy: 2,
            "the track does not reach the foot of the card"
        )
        let bar = try XCTUnwrap(shot.scrollerSpan(), "the bar left with the movement")
        XCTAssertGreaterThanOrEqual(bar.top, inset - 1.5)
        XCTAssertLessThanOrEqual(bar.bottom, shot.cardHeightInPoints - inset + 1.5)
    }

    /// The same cue in the dark appearance: the track and the bar are drawn on
    /// the dark card too, at rest.
    func testTheTrackAndBarStayAfterTheListRestsInTheDark() throws {
        let page = try CapturePage(scheme: .dark)
        defer { page.close() }
        _ = try page.openList()
        page.wait(1.3)
        let shot = try page.capture()
        let inset = DotSelectListMetrics.scrollerTrackInset

        XCTAssertFalse(page.fades.scrolling, "the list has not rested")
        let track = try XCTUnwrap(shot.trackSpan(), "the overflow is invisible on the dark card at rest")
        XCTAssertEqual(track.top, inset, accuracy: 2)
        XCTAssertEqual(track.bottom, shot.cardHeightInPoints - inset, accuracy: 2)
        XCTAssertNotNil(shot.scrollerSpan(), "the bar is not drawn on the dark card at rest")
    }
}
