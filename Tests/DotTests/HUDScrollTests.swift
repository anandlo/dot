import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The scroll container of the transcript, and the focus it must not take.
///
/// The island is a nonactivating panel that can never become key, because a
/// dictation must never move the keyboard focus out of the application the user
/// is typing in. The transcript scrolls inside that panel, and these tests prove
/// that a wheel over it moves the text while the key window, the first responder
/// and the frontmost application stay exactly where they were.
@MainActor
final class HUDScrollTests: XCTestCase {
    private let longText = HUDPreview.longTranscript
    private let shortText = "A transcript that fits in one line of the card."

    // MARK: - The wheel

    func testTheWheelScrollsTheTranscriptAndTakesNoFocus() throws {
        // The synthetic wheel is applied on the next drawing pass, and a
        // sleeping display never runs one: measured here, the test failed with
        // the offset untouched until the display was woken, then passed in
        // 0.15 s. Skipping says that out loud instead of failing a suite for a
        // property of the machine.
        try XCTSkipIf(
            CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            "The display is asleep, so SwiftUI never applies the wheel event."
        )
        let fixture = try makeTranscriptPanel(text: longText)
        defer { fixture.panel.orderOut(nil) }

        // The panel cannot become key, which is what makes the rest safe: no
        // click and no wheel can move the keyboard focus into Dot.
        XCTAssertFalse(fixture.panel.canBecomeKey)
        XCTAssertFalse(fixture.panel.canBecomeMain)
        XCTAssertTrue(fixture.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(fixture.panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(fixture.host.acceptsFirstMouse(for: nil))

        let keyWindowBefore = NSApp.keyWindow
        let responderBefore = fixture.panel.firstResponder
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let activeBefore = NSApp.isActive
        let bottom = maxOffset(of: fixture.scrollView)
        XCTAssertGreaterThan(bottom, 0, "the long transcript does not scroll at all")
        XCTAssertEqual(
            fixture.scrollView.contentView.bounds.origin.y,
            bottom,
            accuracy: 0.5,
            "the card did not start at the newest words"
        )

        // The wheel event carries no window of its own: AppKit reads its
        // location as a screen point and compares it with the window's frame, so
        // the panel is moved onto the origin for the dispatch — transparent, so
        // nothing is drawn — and put back afterwards.
        let originalFrame = fixture.panel.frame
        fixture.panel.alphaValue = 0
        fixture.panel.setFrame(NSRect(origin: .zero, size: originalFrame.size), display: false)
        defer {
            fixture.panel.setFrame(originalFrame, display: false)
            fixture.panel.alphaValue = 1
        }

        let point = NSPoint(x: 280, y: 90)
        let event = try wheelEvent(at: point, points: 60)
        fixture.panel.sendEvent(event)
        // SwiftUI applies the wheel on its next pass, so the offset is read
        // until it moves rather than once.
        waitUntil { self.offset(of: fixture.scrollView) < bottom - 1 }

        let scrolled = fixture.scrollView.contentView.bounds.origin.y
        XCTAssertEqual(scrolled, bottom - 60, accuracy: 1, "the wheel did not move the text")

        // The whole point of the exercise: the wheel moved the text and nothing
        // else moved.
        XCTAssertFalse(fixture.panel.isKeyWindow, "the scroll made the panel key")
        XCTAssertFalse(fixture.panel.canBecomeKey, "the panel can now become key")
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore, "the scroll changed the key window")
        XCTAssertTrue(
            fixture.panel.firstResponder === responderBefore,
            "the scroll changed the first responder"
        )
        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            frontmostBefore,
            "the scroll changed the frontmost application"
        )
        XCTAssertEqual(NSApp.isActive, activeBefore, "the scroll activated Dot")
    }

    // MARK: - The container

    func testTheTranscriptGrowsToItsLimitAndThenScrolls() throws {
        let long = try makeTranscriptPanel(text: longText)
        defer { long.panel.orderOut(nil) }

        // The body is what the request asked for: a card of roughly two hundred
        // points that stops growing and scrolls, so the island never stretches
        // down the screen.
        let longSize = HUD.transcriptSize(text: longText)
        XCTAssertEqual(longSize.height, 225, accuracy: 0.5)
        XCTAssertTrue(
            HUDTranscript.scrolls(contentHeight: HUD.transcriptContentHeight(text: longText))
        )
        XCTAssertGreaterThanOrEqual(longSize.height, 200)
        XCTAssertLessThanOrEqual(longSize.height, 240)
        XCTAssertTrue(long.scrollView.hasVerticalScroller)

        let document = try XCTUnwrap(long.scrollView.documentView)
        let clip = long.scrollView.contentView
        XCTAssertGreaterThan(
            document.frame.height,
            clip.bounds.height,
            "the long transcript is not taller than its viewport"
        )

        // The newest words are what the card opens on, and the oldest are one
        // scroll away.
        XCTAssertEqual(clip.bounds.origin.y, maxOffset(of: long.scrollView), accuracy: 0.5)
        clip.scroll(to: .zero)
        long.scrollView.reflectScrolledClipView(clip)
        XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 0.5)
        clip.scroll(to: NSPoint(x: 0, y: maxOffset(of: long.scrollView)))
        long.scrollView.reflectScrolledClipView(clip)
        XCTAssertEqual(
            clip.bounds.origin.y,
            maxOffset(of: long.scrollView),
            accuracy: 0.5
        )

        // A pointer over the text lands inside the scroll view, so a wheel there
        // is the transcript's and not the card's.
        let inside = try XCTUnwrap(long.host.hitTest(NSPoint(x: 280, y: 90)))
        XCTAssertTrue(
            inside === long.scrollView || inside.isDescendant(of: long.scrollView)
                || long.scrollView.isDescendant(of: inside),
            "the pointer over the text does not hit the scroll view"
        )
    }

    func testAShortTranscriptDoesNotScroll() throws {
        let short = try makeTranscriptPanel(text: shortText)
        defer { short.panel.orderOut(nil) }

        let content = HUD.transcriptContentHeight(text: shortText)
        XCTAssertFalse(HUDTranscript.scrolls(contentHeight: content))

        let size = HUD.transcriptSize(text: shortText)
        XCTAssertLessThan(size.height, HUD.transcriptSize(text: longText).height)
        XCTAssertFalse(
            (short.scrollView.documentView?.frame.height ?? 0) > short.scrollView.contentView.bounds.height,
            "a one-line transcript scrolls"
        )
        // A body that fits is pinned to its own bottom and never scrolls: the
        // offset can only be the few points by which the text is shorter than
        // the body, never a scrolled position.
        let offset = short.scrollView.contentView.bounds.origin.y
        XCTAssertLessThanOrEqual(offset, 0)
        XCTAssertGreaterThan(offset, -5)
    }

    // MARK: - The dwell

    func testThePointerOverTheCardSuspendsTheDwell() throws {
        _ = NSApplication.shared

        let hud = HUD(offscreen: true)
        hud.dwell = 0.6
        defer {
            hud.hide()
            spin(for: 0.5)
        }

        hud.showTranscript(text: shortText, delivery: .pasted, elapsed: "0:03")
        XCTAssertTrue(hud.isVisible)
        XCTAssertEqual(try XCTUnwrap(hud.debugDwellRemaining), 0.6, accuracy: 0.05)

        // Part of the dwell is spent before the pointer arrives.
        spin(for: 0.25)
        let beforeReading = try XCTUnwrap(hud.debugDwellRemaining)
        XCTAssertLessThan(beforeReading, 0.5)

        // Reading the card spends none of it, and does not give the card a
        // fresh six tenths either.
        hud.debugPointer(inside: true)
        spin(for: 1.0)
        XCTAssertTrue(hud.isVisible, "the card was dismissed while it was being read")
        XCTAssertTrue(hud.debugDwellPaused)
        let afterReading = try XCTUnwrap(hud.debugDwellRemaining)
        XCTAssertEqual(afterReading, beforeReading, accuracy: 0.05, "reading reset the countdown")
        XCTAssertLessThan(afterReading, 0.5, "reading gave the card a second life")

        // The pointer leaves, and what was left is what the card gets.
        hud.debugPointer(inside: false)
        spin(for: 1.0)
        XCTAssertFalse(hud.isVisible, "the countdown did not resume when the pointer left")
    }

    // MARK: - Fixtures

    /// A panel with the transcript card in it, off every screen.
    private func makeTranscriptPanel(
        text: String
    ) throws -> (panel: HUDPanel, host: HUDHostingView, scrollView: NSScrollView) {
        _ = NSApplication.shared

        let size = HUD.transcriptSize(text: text)
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.cardSize = size
        model.mode = .transcript(text: text, delivery: .pasted, elapsed: "4:18")

        let root = AnyView(
            HUDView(
                model: model,
                showsShadow: false,
                animated: false,
                actions: HUDActions()
            )
            .frame(width: size.width, height: size.height)
        )

        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true

        let host = HUDHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        panel.setFrame(
            NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            display: false
        )
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(
            firstScrollView(in: host),
            "the transcript is not in a scroll view"
        )
        return (panel, host, scrollView)
    }

    /// How far the transcript is scrolled.
    private func offset(of scrollView: NSScrollView) -> CGFloat {
        scrollView.contentView.bounds.origin.y
    }

    /// Spins the run loop until `condition` holds, or the deadline passes.
    ///
    /// - Parameters:
    ///   - timeout: how long to wait, in seconds.
    ///   - condition: what has to become true.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// The farthest the transcript can be scrolled.
    private func maxOffset(of scrollView: NSScrollView) -> CGFloat {
        let document = scrollView.documentView?.frame.height ?? 0
        return max(0, document - scrollView.contentView.bounds.height)
    }

    /// A wheel event at a point in the window, the way a trackpad produces one.
    private func wheelEvent(at point: NSPoint, points: Int32) throws -> NSEvent {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: points,
                wheel2: 0,
                wheel3: 0
            )
        )
        event.location = CGPoint(x: point.x, y: screenHeight - point.y)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    /// Runs the main run loop, so the HUD's frame timer can fire.
    private func spin(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.01))
            )
        }
    }
}
