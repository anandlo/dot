import AppKit
import SwiftUI
import XCTest
@testable import Dot

/// The edges of a Settings page scroll the way a native macOS view does: the
/// page can use AppKit's responsive scrolling, and nothing in Dot moves the
/// offset while the elastic overscroll is still in flight.
@MainActor
final class PageScrollEdgeTests: XCTestCase {
    private let size = NSSize(width: 500, height: 400)

    private func rows(_ count: Int) -> AnyView {
        AnyView(
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    Text("Row \(index)").frame(maxWidth: .infinity, minHeight: 30)
                }
            }
        )
    }

    private func mounted(rows count: Int) -> (DotPageScrollHostView, OffscreenWindow) {
        let window = OffscreenWindow(size: size)
        let host = DotPageScrollHostView(rootView: rows(count))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func maxOffset(_ scroll: NSScrollView) -> CGFloat {
        max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
    }

    func testThePageCanUseResponsiveScrolling() throws {
        let (host, _) = mounted(rows: 60)
        let scroll = host.scrollView
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertTrue(type(of: scroll).isCompatibleWithResponsiveScrolling, "the scroll view opts out")
        XCTAssertTrue(type(of: scroll.contentView).isCompatibleWithResponsiveScrolling, "the clip view opts out")
        XCTAssertTrue(
            type(of: document).isCompatibleWithResponsiveScrolling,
            "the document \(type(of: document)) forces the legacy scrolling path"
        )
        XCTAssertTrue(host.hostingView.isDescendant(of: document), "the page content is not inside the document")
    }

    func testTheDocumentIsTheHeightOfThePage() {
        let (host, _) = mounted(rows: 60)
        let scroll = host.scrollView
        XCTAssertEqual(scroll.documentView?.frame.height ?? 0, 1_800, accuracy: 0.5)
        XCTAssertEqual(host.hostingView.frame.height, 1_800, accuracy: 0.5)
        XCTAssertEqual(scroll.verticalScrollElasticity, .allowed, "an overflowing page must rubber-band")

        let (short, _) = mounted(rows: 5)
        XCTAssertEqual(short.scrollView.verticalScrollElasticity, .none, "a page that fits must not bounce")
    }

    /// AppKit's own clip view constrains any programmatic origin, while the
    /// elastic gesture moves past the edges internally. A clip view that keeps
    /// whatever origin it is given stands in for that rebound in flight, so any
    /// origin Dot writes shows up as a change.
    func testAnElasticOverscrollIsNeverMovedByDot() throws {
        let (host, _) = mounted(rows: 60)
        let scroll = host.scrollView
        let document = try XCTUnwrap(scroll.documentView)
        let clip = OverscrollingClipView(frame: scroll.contentView.frame)
        scroll.contentView = clip
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        let limit = maxOffset(scroll)
        XCTAssertGreaterThan(limit, 0)
        XCTAssertFalse(scroll.isLiveScrolling)

        for overscroll in [limit + 40, CGFloat(-40)] {
            clip.setBoundsOrigin(NSPoint(x: 0, y: overscroll))
            XCTAssertEqual(clip.bounds.origin.y, overscroll, accuracy: 0.01, "the stand-in did not overscroll")
            scroll.updateScrollMetrics()
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            scroll.layout()
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            XCTAssertEqual(
                clip.bounds.origin.y,
                overscroll,
                accuracy: 0.01,
                "the rebound from \(overscroll) was cut short by a programmatic scroll"
            )
        }
    }

    func testShrinkingContentLeavesAValidOffset() {
        let (host, _) = mounted(rows: 60)
        let scroll = host.scrollView
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxOffset(scroll)))
        scroll.reflectScrolledClipView(scroll.contentView)

        host.hostingView.rootView = rows(20)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(scroll.documentView?.frame.height ?? 0, 600, accuracy: 0.5)
        XCTAssertLessThanOrEqual(
            scroll.contentView.bounds.origin.y,
            maxOffset(scroll) + 0.5,
            "the offset was left past the end of the shorter page"
        )
    }
}

private final class OverscrollingClipView: NSClipView {
    override var isFlipped: Bool { true }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
}
