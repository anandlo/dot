import AppKit
import SwiftUI
import XCTest
@testable import Dot

/// The edges of a scrolling surface: a Settings page uses AppKit's responsive
/// scrolling and stops at its first and last line with no elastic overscroll,
/// and so do the island's transcript and every configured SwiftUI scroll view.
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
        XCTAssertEqual(scroll.verticalScrollElasticity, .none, "an overflowing page must stop at its edges, not rubber-band")

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

    /// The island's transcript body stops at its first and last line.
    func testTheIslandTranscriptStopsAtItsEdges() throws {
        let window = OffscreenWindow(size: size)
        defer { window.close() }
        let long = (0..<80).map { "Line \($0) of a long take." }.joined(separator: " ")
        let host = NSHostingView(rootView: HUDInlineTranscriptView(
            text: long,
            isEditing: false,
            usesSystemInk: false,
            onBeginEditing: {},
            onEndEditing: {},
            onUpdateText: { _ in }
        ).frame(width: 400, height: 120))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        XCTAssertGreaterThan(maxOffset(scroll), 0, "the body does not overflow, so the test proves nothing")
        XCTAssertEqual(scroll.verticalScrollElasticity, .none, "the island transcript rubber-bands")
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
    }

    /// Words arriving in the island follow the end only for a reader already
    /// there; a reader who scrolled back is not pulled down.
    func testTheIslandTranscriptKeepsAReaderWhoScrolledBack() throws {
        let window = OffscreenWindow(size: size)
        defer { window.close() }
        func body(_ text: String) -> some View {
            HUDInlineTranscriptView(
                text: text,
                isEditing: false,
                usesSystemInk: false,
                onBeginEditing: {},
                onEndEditing: {},
                onUpdateText: { _ in }
            ).frame(width: 400, height: 120)
        }
        // The card opens on the first word and grows as the take is read.
        let host = NSHostingView(rootView: AnyView(body("Line")))
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        settle()
        var text = (0..<80).map { "Line \($0) of a long take." }.joined(separator: " ")
        host.rootView = AnyView(body(text))
        settle()
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        XCTAssertGreaterThan(maxOffset(scroll), 40, "the body does not overflow, so the test proves nothing")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5, "the take's first overflow left the first word")

        text += " More words arrive while the reader is at the top."
        host.rootView = AnyView(body(text))
        settle()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5, "new words pulled a reader away from the top")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxOffset(scroll)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = maxOffset(scroll)
        text += (0..<20).map { " Tail \($0) keeps coming." }.joined()
        host.rootView = AnyView(body(text))
        settle()
        XCTAssertGreaterThan(maxOffset(scroll), before, "the appended words did not lengthen the body")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, maxOffset(scroll), accuracy: 2, "a reader at the end did not follow new words")
    }

    /// The first change to a card that opened on a long text leaves a reader
    /// who has already scrolled where they are.
    func testTheFirstChangeKeepsAReaderWhoHasMoved() throws {
        let window = OffscreenWindow(size: size)
        defer { window.close() }
        func body(_ text: String) -> some View {
            HUDInlineTranscriptView(
                text: text,
                isEditing: false,
                usesSystemInk: false,
                onBeginEditing: {},
                onEndEditing: {},
                onUpdateText: { _ in }
            ).frame(width: 400, height: 120)
        }
        var text = (0..<80).map { "Line \($0) of a long take." }.joined(separator: " ")
        let host = NSHostingView(rootView: AnyView(body(text)))
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        settle()
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        let middle = (maxOffset(scroll) / 2).rounded()
        XCTAssertGreaterThan(middle, 40, "the body does not overflow, so the test proves nothing")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: middle))
        scroll.reflectScrolledClipView(scroll.contentView)

        text += " A last word."
        host.rootView = AnyView(body(text))
        settle()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, middle, accuracy: 0.5, "the first change moved a reader who had scrolled")
    }

    /// The first words to arrive in a card that opened on a long text follow
    /// the end for a reader already there.
    func testTheFirstAppendFollowsAReaderAtTheEnd() throws {
        var text = (0..<80).map { "Line \($0) of a long take." }.joined(separator: " ")
        let island = try IslandHarness(text: text, size: size)
        defer { island.close() }
        let scroll = island.scroll
        XCTAssertGreaterThan(maxOffset(scroll), 40, "the body does not overflow, so the test proves nothing")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxOffset(scroll)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = maxOffset(scroll)

        text += (0..<20).map { " Tail \($0) keeps coming." }.joined()
        island.show(text: text)
        XCTAssertGreaterThan(maxOffset(scroll), before, "the appended words did not lengthen the body")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, maxOffset(scroll), accuracy: 2, "the first append left a reader at the end behind")
    }

    /// A transcript that fits has not been scrolled, so the append that first
    /// makes it overflow leaves the reader on the first word.
    func testTheFirstOverflowKeepsTheReaderOnTheFirstWord() throws {
        let island = try IslandHarness(text: "Line one of a short take.", size: size)
        defer { island.close() }
        let scroll = island.scroll
        XCTAssertLessThanOrEqual(maxOffset(scroll), 0.5, "the short take already overflows, so the test proves nothing")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        print("ISLAND-FIT origin \(scroll.contentView.bounds.origin.y) doc \(scroll.documentView?.frame.height ?? -1) clip \(scroll.contentView.bounds.height)")
        let text = (0..<80).map { "Line \($0) of a long take." }.joined(separator: " ")
        island.show(text: text)
        print("ISLAND-OVER origin \(scroll.contentView.bounds.origin.y) max \(maxOffset(scroll))")
        XCTAssertGreaterThan(maxOffset(scroll), 40, "the long take does not overflow, so the test proves nothing")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5, "the first overflow sent an unscrolled reader to the end")
    }

    /// A narrower card lengthens the text. A reader at the end stays there,
    /// whether or not the ink changes in the same update.
    func testNarrowingTheCardKeepsAReaderAtTheEnd() throws {
        for changesInk in [false, true] {
            let text = (0..<80).map { "Line \($0) of a long take." }.joined(separator: " ")
            let island = try IslandHarness(text: text, size: size)
            defer { island.close() }
            let scroll = island.scroll
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maxOffset(scroll)))
            scroll.reflectScrolledClipView(scroll.contentView)
            let before = maxOffset(scroll)
            XCTAssertGreaterThan(before, 40, "the body does not overflow, so the test proves nothing")

            island.show(text: text, width: 300, systemInk: changesInk)
            print("ISLAND-NARROW end \(before) -> \(scroll.contentView.bounds.origin.y) of \(maxOffset(scroll)) (ink change: \(changesInk))")
            XCTAssertGreaterThan(maxOffset(scroll), before + 20, "the narrower card did not lengthen the body (ink change: \(changesInk))")
            XCTAssertEqual(scroll.contentView.bounds.origin.y, maxOffset(scroll), accuracy: 2, "narrowing the card left a reader at the end behind (ink change: \(changesInk))")
        }
    }

    /// A reader in the middle keeps reading the same words when the card
    /// narrows, and is not sent to either end.
    func testNarrowingTheCardLeavesAReaderInTheMiddle() throws {
        let text = (0..<80).map { "Line \($0) of a long take." }.joined(separator: " ")
        let island = try IslandHarness(text: text, size: size)
        defer { island.close() }
        let scroll = island.scroll
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        func visibleCharacters() -> ClosedRange<Int> {
            let bounds = scroll.contentView.bounds
            let first = textView.characterIndexForInsertion(at: NSPoint(x: 8, y: bounds.minY + 4))
            let last = textView.characterIndexForInsertion(at: NSPoint(x: bounds.width - 8, y: bounds.maxY - 4))
            return first...max(first, last)
        }
        let middle = (maxOffset(scroll) / 2).rounded()
        XCTAssertGreaterThan(middle, 40, "the body does not overflow, so the test proves nothing")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: middle))
        scroll.reflectScrolledClipView(scroll.contentView)
        let reading = visibleCharacters().lowerBound

        island.show(text: text, width: 300)
        let origin = scroll.contentView.bounds.origin.y
        let visible = visibleCharacters()
        print("ISLAND-NARROW middle \(middle) -> \(origin) of \(maxOffset(scroll)), reading \(reading), visible \(visible)")
        XCTAssertGreaterThan(origin, 2, "narrowing the card sent a reader in the middle to the start")
        XCTAssertLessThan(origin, maxOffset(scroll) - 2, "narrowing the card sent a reader in the middle to the end")
        XCTAssertTrue(visible.contains(reading), "narrowing the card scrolled away the words a reader in the middle was reading")
    }

    /// A SwiftUI `ScrollView` carrying the configurator, as the island's live
    /// text, rewrite draft, History and Palette do, stops at its edges even
    /// though SwiftUI built its scroll view.
    func testTheConfiguratorHoldsASwiftUIScrollViewAtItsEdges() throws {
        let window = OffscreenWindow(size: size)
        defer { window.close() }
        let host = NSHostingView(rootView: ScrollView(.vertical) {
            rows(60).background(DotScrollViewConfigurator(surface: "test"))
        }.frame(width: 400, height: 300))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        XCTAssertGreaterThan(maxOffset(scroll), 0, "the content does not overflow, so the test proves nothing")
        XCTAssertEqual(scroll.verticalScrollElasticity, .none, "a configured SwiftUI scroll view rubber-bands")
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
    }

    private func scrollViews(in root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }
}

/// An island transcript card in an offscreen window, re-rendered with new
/// text, width or ink the way SwiftUI updates it while the card is open.
@MainActor
private final class IslandHarness {
    private let window: OffscreenWindow
    private let host: NSHostingView<AnyView>
    let scroll: NSScrollView

    init(text: String, size: CGSize) throws {
        window = OffscreenWindow(size: size)
        host = NSHostingView(rootView: Self.body(text: text, width: 400, systemInk: false))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        Self.settle(host)
        var stack: [NSView] = [host]
        var found: NSScrollView?
        while found == nil, let view = stack.popLast() {
            found = view as? NSScrollView
            stack.append(contentsOf: view.subviews)
        }
        scroll = try XCTUnwrap(found)
    }

    func show(text: String, width: CGFloat = 400, systemInk: Bool = false) {
        host.rootView = Self.body(text: text, width: width, systemInk: systemInk)
        Self.settle(host)
    }

    func close() { window.close() }

    private static func body(text: String, width: CGFloat, systemInk: Bool) -> AnyView {
        AnyView(HUDInlineTranscriptView(
            text: text,
            isEditing: false,
            usesSystemInk: systemInk,
            onBeginEditing: {},
            onEndEditing: {},
            onUpdateText: { _ in }
        ).frame(width: width, height: 120))
    }

    private static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}

private final class OverscrollingClipView: NSClipView {
    override var isFlipped: Bool { true }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
}
