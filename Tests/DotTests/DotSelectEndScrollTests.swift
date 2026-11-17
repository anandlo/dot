import AppKit
@testable import Dot
import XCTest

/// The ends of a list, placed against a real scroll view.
///
/// The model tests pin the arithmetic and the behaviour tests open the shipped
/// panel; these cases hold the seam between them: a card that is measured, an
/// end that arrives before or after that measurement, and the one shot that
/// places it.
@MainActor
final class DotSelectEndScrollTests: XCTestCase {
    /// A card shaped like the list's: a flipped document of its own height with
    /// the reporting view at its foot, inside a viewport the test names.
    private struct Card {
        let window: NSWindow
        let scroll: NSScrollView
        let reporter: DotSelectScrollReportingView
        let model: DotSelectScrollModel
    }

    /// Builds a card that has already been measured.
    private func makeCard(content: CGFloat, viewport: CGFloat = 310) -> Card {
        _ = NSApplication.shared
        let window = OffscreenWindow(
            size: CGSize(width: 240, height: viewport),
            styleMask: [.borderless]
        )
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: viewport))
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        window.contentView = scroll

        let document = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 240, height: content))
        let reporter = DotSelectScrollReportingView(
            frame: NSRect(x: 0, y: max(0, content - 1), width: 240, height: 0)
        )
        document.addSubview(reporter)
        scroll.documentView = document
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()

        let model = DotSelectScrollModel()
        reporter.model = model
        model.reporter = reporter
        reporter.publish()
        return Card(window: window, scroll: scroll, reporter: reporter, model: model)
    }

    private func close(_ card: Card) {
        card.window.contentView = nil
        card.window.close()
    }

    /// An end asked for before the card has a document waits for one, and is
    /// placed from the document the card finally has.
    func testAnEndWaitsForTheCardToBeMeasured() {
        _ = NSApplication.shared
        let window = OffscreenWindow(size: CGSize(width: 240, height: 310), styleMask: [.borderless])
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 310))
        scroll.hasVerticalScroller = false
        window.contentView = scroll
        defer {
            window.contentView = nil
            window.close()
        }

        let document = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 240, height: 0))
        let reporter = DotSelectScrollReportingView(frame: .zero)
        document.addSubview(reporter)
        scroll.documentView = document
        scroll.tile()

        let model = DotSelectScrollModel()
        reporter.model = model
        model.reporter = reporter

        model.requestEnd(.bottom)
        XCTAssertEqual(
            model.pendingEnd,
            .bottom,
            "the card took an end it had no document to measure"
        )
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)

        document.frame.size.height = 848
        reporter.publish()

        XCTAssertNil(model.pendingEnd, "the end was never placed")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 538, accuracy: 0.5)
    }

    /// An end that arrives after the card was measured is placed by the
    /// reporter the model holds: no layout and no bounds change wake it.
    func testAnEndThatArrivesLateIsPlaced() {
        let card = makeCard(content: 848)
        defer { close(card) }

        XCTAssertEqual(card.model.contentHeight, 848)
        XCTAssertEqual(card.scroll.contentView.bounds.origin.y, 0)

        card.model.requestEnd(.bottom)

        XCTAssertEqual(card.scroll.contentView.bounds.origin.y, 538, accuracy: 0.5)
        XCTAssertNil(card.model.pendingEnd, "the request is taken once")
    }

    /// The placement is one shot: a wheel that moves the list afterwards is not
    /// pulled back to the end.
    func testAnEndIsPlacedOnceAndTheListMovesAfterwards() {
        let card = makeCard(content: 848)
        defer { close(card) }

        card.model.requestEnd(.bottom)
        XCTAssertEqual(card.scroll.contentView.bounds.origin.y, 538, accuracy: 0.5)

        let clip = card.scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: 400))
        card.scroll.reflectScrolledClipView(clip)
        card.reporter.publish()

        XCTAssertEqual(
            clip.bounds.origin.y,
            400,
            accuracy: 0.5,
            "the list was pulled back to the end"
        )
        XCTAssertEqual(card.model.offset, 400, accuracy: 0.5, "the card did not measure the wheel")
    }

    /// An end placed on a card that has just been measured is final: the next
    /// measurement and the next layout pass find the list where they left it.
    func testAnEndIsNotMovedByTheNextMeasurement() {
        let card = makeCard(content: 848)
        defer { close(card) }

        card.model.requestEnd(.bottom)
        XCTAssertEqual(card.scroll.contentView.bounds.origin.y, 538, accuracy: 0.5)

        card.reporter.publish()
        card.scroll.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            card.scroll.contentView.bounds.origin.y,
            538,
            accuracy: 0.5,
            "the list moved after the end was placed"
        )
        XCTAssertEqual(card.model.offset, 538, accuracy: 0.5)
    }

    /// An end the card was asked for while it had nothing to measure is not
    /// placed once it has a document: a cancel is the whole answer.
    func testACancelledEndIsNeverPlaced() {
        let card = makeCard(content: 0)
        defer { close(card) }

        card.model.requestEnd(.bottom)
        XCTAssertEqual(card.model.pendingEnd, .bottom, "the card took an end it could not place")
        card.model.cancelPendingEnd()

        card.scroll.documentView?.frame.size.height = 848
        card.reporter.publish()

        XCTAssertEqual(card.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        XCTAssertNil(card.model.pendingEnd)
    }

    /// A list shorter than its card has one offset at both ends, so neither
    /// moves it.
    func testAShortListHasOneOffsetAtBothEnds() {
        let card = makeCard(content: 120, viewport: 120)
        defer { close(card) }

        card.model.requestEnd(.bottom)
        XCTAssertEqual(card.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)

        card.model.requestEnd(.top)
        XCTAssertEqual(card.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        XCTAssertNil(card.model.pendingEnd)
    }
}

/// A document view that counts from its top, as the list's does.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
