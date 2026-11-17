import AppKit
import Combine
@testable import Dot
import QuartzCore
import SwiftUI
import XCTest

/// The numbers the list draws with, without a screen.
///
/// The wheel, the fades and the bar are a model each: these cases pin the rules
/// the card is drawn from, so a change in the drawing cannot quietly move them.
@MainActor
final class DotSelectScrollModelTests: XCTestCase {
    // MARK: - The pointer and the list

    func testAHoverFromTheSamePlaceIsIgnored() {
        var gate = DotSelectHoverGate()
        XCTAssertTrue(gate.accept(at: CGPoint(x: 100, y: 200)), "the first arrival counts")
        XCTAssertFalse(
            gate.accept(at: CGPoint(x: 100, y: 200)),
            "a row that arrived under a pointer that has not moved is not a hover"
        )
    }

    func testAHoverFromANewPlaceCounts() {
        var gate = DotSelectHoverGate()
        XCTAssertTrue(gate.accept(at: CGPoint(x: 100, y: 200)))
        XCTAssertTrue(gate.accept(at: CGPoint(x: 100, y: 228)), "the pointer moved one row")
        XCTAssertFalse(gate.accept(at: CGPoint(x: 100, y: 228)))
    }

    /// The highlight the pointer moves never scrolls the list.
    func testAPointerHighlightIsNotAScrollTarget() {
        let session = DotSelectSession(
            titles: ["A", "B", "C", "D"],
            selected: 0,
            registrar: DotSelectMonitorRegistrar(add: { _, _ in nil }, remove: { _ in }),
            observers: DotSelectObserverRegistrar(add: { _, _ in nil }, remove: { _ in }),
            panelNumber: { 0 }
        )
        var events: [DotSelectSession.Event] = []
        session.start { events.append($0) }
        session.hover(2)
        XCTAssertEqual(events.last, .highlightChanged(2, scrolls: false))
        _ = session.handleKey(Self.down())
        XCTAssertEqual(events.last, .highlightChanged(3, scrolls: true), "a key scrolls the list")
    }

    // MARK: - Fades and the bar

    func testAListThatFitsShowsNoFadeAndNoBar() {
        let scroll = DotSelectScrollModel()
        scroll.moved(offset: 0, contentHeight: 120, viewportHeight: 120)
        XCTAssertFalse(scroll.showsTopFade)
        XCTAssertFalse(scroll.showsBottomFade)
        XCTAssertNil(scroll.thumb, "a list that fits has nothing to scroll")
    }

    func testTheTopFadeNeedsMoreThanItsOwnHeightHidden() {
        let scroll = DotSelectScrollModel()
        scroll.moved(offset: 1, contentHeight: 900, viewportHeight: 300)
        XCTAssertFalse(scroll.showsTopFade, "a point of overscroll is not content above")
        scroll.moved(offset: 100, contentHeight: 900, viewportHeight: 300)
        XCTAssertTrue(scroll.showsTopFade)
        XCTAssertTrue(scroll.showsBottomFade)
        scroll.moved(offset: 600, contentHeight: 900, viewportHeight: 300)
        XCTAssertFalse(scroll.showsBottomFade, "the end of the list is not a cut edge")
    }

    /// The bar is measured against the track the card keeps for it, not the
    /// card: the track is six points short at each end, so a quarter of a list
    /// in view is a quarter of the track and the first row's bar starts six
    /// points down rather than on the card's corner.
    func testTheBarIsTheShareOfTheTrackInView() {
        let scroll = DotSelectScrollModel()
        let track = 300 - 2 * DotSelectListMetrics.scrollerTrackInset
        scroll.moved(offset: 0, contentHeight: 1200, viewportHeight: 300)
        let top = scroll.thumb
        XCTAssertEqual(top?.height, track / 4, "a quarter of the list is in view")
        XCTAssertEqual(top?.offset, DotSelectListMetrics.scrollerTrackInset, "the bar starts inside the track")

        scroll.moved(offset: 900, contentHeight: 1200, viewportHeight: 300)
        XCTAssertEqual(
            scroll.thumb?.offset,
            DotSelectListMetrics.scrollerTrackInset + track * 3 / 4,
            "the bar reaches the foot of the track"
        )
    }

    /// However long or short the list, the bar is never drawn outside the track
    /// and never shorter than a fingerhold.
    func testTheBarStaysInsideItsTrackAtEveryPosition() {
        let scroll = DotSelectScrollModel()
        let viewport: CGFloat = 300
        let inset = DotSelectListMetrics.scrollerTrackInset
        scroll.moved(offset: 0, contentHeight: 10_000, viewportHeight: viewport)

        for offset in [0, 1, 60, 1_200, 2_000, 9_700] as [CGFloat] {
            scroll.moved(offset: offset, contentHeight: 10_000, viewportHeight: viewport)
            let thumb = scroll.thumb
            XCTAssertNotNil(thumb)
            guard let thumb else { continue }
            XCTAssertGreaterThanOrEqual(thumb.offset, inset, "the bar crosses the top of the track at \(offset)")
            XCTAssertLessThanOrEqual(
                thumb.offset + thumb.height,
                viewport - inset,
                "the bar crosses the foot of the track at \(offset)"
            )
            XCTAssertGreaterThanOrEqual(thumb.height, 24, "the bar is shorter than a fingerhold")
        }
    }

    func testAShortBarKeepsAFingerholdHeight() {
        let scroll = DotSelectScrollModel()
        scroll.moved(offset: 0, contentHeight: 10_000, viewportHeight: 300)
        XCTAssertEqual(scroll.thumb?.height, 24)
    }

    func testTheBarLeavesAfterTheListRests() {
        let scroll = DotSelectScrollModel()
        scroll.moved(offset: 0, contentHeight: 900, viewportHeight: 300)
        XCTAssertTrue(scroll.isScrolling, "the list arriving is a movement")
        scroll.moved(offset: 20, contentHeight: 900, viewportHeight: 300)
        XCTAssertTrue(scroll.isScrolling)
        let rested = expectation(description: "the bar leaves")
        DispatchQueue.main.asyncAfter(deadline: .now() + DotSelectScrollModel.linger + 0.2) {
            MainActor.assumeIsolated {
                XCTAssertFalse(scroll.isScrolling)
                rested.fulfill()
            }
        }
        wait(for: [rested], timeout: 3)
    }

    // MARK: - When SwiftUI is told

    /// The list is measured from inside a layout pass, so the change SwiftUI is
    /// told about is held until that pass is over: a publication from inside the
    /// update is the one SwiftUI reports as "Publishing changes from within view
    /// updates". What was measured stays readable at once, and every measurement
    /// taken before the run loop turns arrives as one change, not one per pass.
    func testAMeasurementIsPublishedAfterThePassThatTookIt() async {
        let scroll = DotSelectScrollModel()
        var published = 0
        let watch = scroll.objectWillChange.sink { _ in
            MainActor.assumeIsolated { published += 1 }
        }
        defer { watch.cancel() }

        scroll.moved(offset: 0, contentHeight: 900, viewportHeight: 300)
        XCTAssertEqual(published, 0, "the pass that measured the list is not interrupted")
        XCTAssertEqual(scroll.contentHeight, 900, "what was measured is readable in that pass")
        XCTAssertEqual(scroll.viewportHeight, 300)
        XCTAssertTrue(scroll.isScrolling)

        await nextTurn()
        XCTAssertEqual(published, 1, "the change reaches SwiftUI once the pass is over")

        scroll.moved(offset: 40, contentHeight: 900, viewportHeight: 300)
        scroll.moved(offset: 80, contentHeight: 900, viewportHeight: 300)
        XCTAssertEqual(scroll.offset, 80, "the last measurement is the one read")
        XCTAssertEqual(published, 1, "a second measurement does not publish on top of the first")
        await nextTurn()
        XCTAssertEqual(published, 2, "both measurements in one pass redraw once")
    }

    /// A closed list wakes nothing: the change it had not sent and the countdown
    /// that would have taken its scroller away are both dropped, so a card that
    /// is gone neither redraws nor clears a flag a later open is reading.
    func testAClosedListDropsThePublicationAndTheCountdown() async {
        let scroll = DotSelectScrollModel()
        var published = 0
        let watch = scroll.objectWillChange.sink { _ in
            MainActor.assumeIsolated { published += 1 }
        }
        defer { watch.cancel() }

        scroll.moved(offset: 0, contentHeight: 900, viewportHeight: 300)
        XCTAssertTrue(scroll.isScrolling)
        scroll.stop()
        XCTAssertFalse(scroll.isScrolling, "a list that is closed is not moving")

        try? await Task.sleep(for: .seconds(DotSelectScrollModel.linger + 0.2))
        XCTAssertEqual(published, 0, "nothing redraws a card that is closed")
        XCTAssertFalse(scroll.isScrolling, "the countdown does not outlive the close")
    }

    /// Runs the run loop past the change a measurement published.
    private func nextTurn() async {
        let turned = expectation(description: "the run loop turned")
        DispatchQueue.main.async { turned.fulfill() }
        await fulfillment(of: [turned], timeout: 1)
    }

    /// The change is sent by hand rather than by a `@Published` write, so the
    /// view that draws the fades and the bar has to be told all the same: a
    /// model SwiftUI stopped watching would keep the numbers it was born with.
    func testAScrollRedrawsTheViewThatWatchesIt() async {
        let scroll = DotSelectScrollModel()
        let probe = BodyProbe()
        let host = NSHostingView(rootView: ScrollProbe(scroll: scroll, probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        host.layoutSubtreeIfNeeded()
        let before = probe.bodies

        scroll.moved(offset: 0, contentHeight: 900, viewportHeight: 300)
        await nextTurn()
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(probe.bodies, before, "the card never learned the list moved")
    }

    // MARK: - The ends of the list

    /// A request for an end is kept until the card can place it, and is taken
    /// once: the wheel that follows moves the list without being pulled back.
    func testAnEndRequestIsTakenOnce() {
        let scroll = DotSelectScrollModel()
        XCTAssertNil(scroll.pendingEnd)

        scroll.requestEnd(.bottom)
        XCTAssertEqual(scroll.pendingEnd, .bottom, "the card never learned which end to show")
        XCTAssertEqual(scroll.takePendingEnd(), .bottom)
        XCTAssertNil(scroll.pendingEnd)
        XCTAssertNil(scroll.takePendingEnd(), "a request taken once is not taken again")
    }

    /// The offset of an end is arithmetic on the document and the viewport, and
    /// a list shorter than its card has one offset, zero, at both ends.
    func testTheEndsOffsetIsTheDocumentLessTheViewport() {
        let scroll = DotSelectScrollModel()
        XCTAssertEqual(scroll.offset(showing: .top), 0)
        XCTAssertEqual(scroll.offset(showing: .bottom), 0, "an unmeasured list has nowhere to scroll")

        scroll.moved(offset: 0, contentHeight: 848, viewportHeight: 310)
        XCTAssertEqual(scroll.offset(showing: .top), 0)
        XCTAssertEqual(scroll.offset(showing: .bottom), 538)

        scroll.moved(offset: 0, contentHeight: 120, viewportHeight: 120)
        XCTAssertEqual(scroll.offset(showing: .bottom), 0, "a list that fits has no foot to reach")
    }

    /// An end asked for before the list was measured is kept whole until the
    /// reporter that places it takes it: a measurement in between describes the
    /// card, and does not consume the request.
    func testAnEndWaitsForTheReporterThatMeasuresTheList() {
        let scroll = DotSelectScrollModel()
        scroll.requestEnd(.bottom)
        XCTAssertEqual(scroll.pendingEnd, .bottom, "the card never learned which end to show")

        scroll.moved(offset: 0, contentHeight: 848, viewportHeight: 310)
        XCTAssertEqual(
            scroll.pendingEnd,
            .bottom,
            "a measurement took the end the reporter was going to place"
        )
        XCTAssertEqual(scroll.takePendingEnd(), .bottom)
        XCTAssertNil(scroll.pendingEnd)
    }

    /// A newer target drops the end the card was waiting to place: a middle
    /// row, or a wheel, is where the reader is now.
    func testANewerTargetDropsTheEndItWasWaitingFor() {
        let scroll = DotSelectScrollModel()
        scroll.requestEnd(.bottom)
        scroll.cancelPendingEnd()
        XCTAssertNil(scroll.pendingEnd, "the end outlived the target that replaced it")
    }

    /// A closed list drops the end it was asked for: nothing is left to apply to
    /// a card that is gone.
    func testAClosedListDropsTheEndItWasAskedFor() {
        let scroll = DotSelectScrollModel()
        scroll.requestEnd(.bottom)
        scroll.stop()
        XCTAssertNil(scroll.pendingEnd)
        scroll.requestEnd(.top)
        XCTAssertNil(scroll.pendingEnd, "a stopped model does not take requests")
    }

    // MARK: - A chosen row

    func testAChosenRowHoldsThenFades() {
        let timeline = DotSelectCommitTimeline(reducesMotion: false)
        XCTAssertEqual(timeline.hold, 0.07, accuracy: 0.001)
        XCTAssertEqual(timeline.fade, 0.09, accuracy: 0.001)
    }

    func testReduceMotionClosesWithoutAHoldOrAFade() {
        let timeline = DotSelectCommitTimeline(reducesMotion: true)
        XCTAssertEqual(timeline.hold, 0)
        XCTAssertEqual(timeline.fade, 0)
    }

    // MARK: - The row

    /// The menu's two washes are tints of the ink, not plates of colour: the
    /// highlighted row is darker than the surface it sits on, and the held row
    /// is darker again, so a press reads as the highlight being pushed in.
    func testThePressedRowIsDarkerThanTheHighlightedRow() throws {
        let row = DotSelectRow(title: "OpenAI", detail: "Connected")
        let plain = try render(DotSelectListRow(
            row: row, isSelected: false, isHighlighted: false, reservesSymbol: false
        ))
        let highlighted = try render(DotSelectListRow(
            row: row, isSelected: false, isHighlighted: true, reservesSymbol: false
        ))
        let pressed = try render(DotSelectListRow(
            row: row, isSelected: false, isHighlighted: true, isPressed: true, reservesSymbol: false
        ))
        XCTAssertLessThan(mean(pressed), mean(highlighted), "the press does not read as a press")
        XCTAssertLessThan(mean(highlighted), mean(plain), "the highlight does not read as a highlight")
        XCTAssertGreaterThan(
            abs(mean(pressed) - mean(highlighted)),
            0.02,
            "a pressed row and a highlighted row look the same"
        )
    }

    /// The row's pixels at two pixels per point.
    ///
    /// A rep AppKit makes for the cache display comes back at the display's own
    /// scale, which is one pixel per point on a display that is not Retina, so
    /// the bitmap is made here at the scale the luminance is read at.
    private func render(_ view: some View) throws -> NSBitmapImageRep {
        let paper = ZStack {
            RoundedRectangle(cornerRadius: 10).fill(DotTheme.paper)
            RoundedRectangle(cornerRadius: 10).fill(DotTheme.cardFill)
            view
        }
        .frame(width: 240, height: 40)
        let host = NSHostingView(rootView: paper)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 240 * 2,
            pixelsHigh: 40 * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the row could not be allocated")
        rep.size = NSSize(width: 240, height: 40)
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func mean(_ rep: NSBitmapImageRep) -> CGFloat {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3 else { return 0 }
        var total: CGFloat = 0
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let offset = y * rep.bytesPerRow + x * rep.samplesPerPixel
                total += (CGFloat(data[offset]) * 0.21
                    + CGFloat(data[offset + 1]) * 0.72
                    + CGFloat(data[offset + 2]) * 0.07) / 255
                count += 1
            }
        }
        return count == 0 ? 0 : total / CGFloat(count)
    }

    private static func down() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125
        )!
    }
}

/// Counts the times SwiftUI evaluates the body that watches a scroll model.
@MainActor
private final class BodyProbe {
    private(set) var bodies = 0

    func record() { bodies += 1 }
}

/// A view that draws from a scroll model and nothing else, so that a redraw can
/// only have come from the model.
private struct ScrollProbe: View {
    @ObservedObject var scroll: DotSelectScrollModel
    let probe: BodyProbe

    var body: some View {
        let _ = probe.record()
        Color.clear
            .frame(height: scroll.thumb?.height ?? 0)
    }
}
