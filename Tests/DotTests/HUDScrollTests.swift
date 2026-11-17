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
    /// The app's typeface, registered before the first view is built.
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

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
        // The card opens on the first word, which is the decision `HUDView`
        // records in `makeNSView`: the body used to open at its end and sliced
        // the first line of every long transcript against the top edge. The
        // reading is taken after the dispatched scroll has run, so it is the
        // settled position and not one pass of a race: the clip sits 13 points
        // into a 550.5 point document inside a 180 point viewport.
        XCTAssertLessThanOrEqual(
            fixture.scrollView.contentView.bounds.origin.y,
            HUDTheme.transcriptLineHeight,
            "the card did not open on the first word"
        )
        XCTAssertLessThan(
            fixture.scrollView.contentView.bounds.origin.y,
            bottom - 1,
            "the card opened at the end of the text, so the first word is cut"
        )

        // The wheel event carries no window of its own: AppKit reads its
        // location as a screen point and compares it with the window's frame, so
        // the point is taken inside the panel's own frame, which is off every
        // display: nothing is drawn and no window is ever on the Mac.
        let origin = fixture.panel.frame.origin
        let point = NSPoint(x: origin.x + 280, y: origin.y + 90)
        // SwiftUI applies the wheel on a later pass of the run loop, so the
        // offset is polled for rather than read once. The panel is asked to
        // lay out and display inside the wait, so a pass that the machine is
        // slow to schedule is still taken, and a wheel that the window server
        // dropped before the panel was ever drawn is sent again — a second
        // flick of the wheel is what a person would do, and the card either
        // scrolls or it does not.
        var applied = false
        for _ in 1...3 {
            fixture.panel.sendEvent(try wheelEvent(at: point, points: 60))
            applied = waitUntil {
                fixture.panel.displayIfNeeded()
                fixture.host.layoutSubtreeIfNeeded()
                return self.offset(of: fixture.scrollView) < bottom - 1
            }
            if applied { break }
        }
        XCTAssertTrue(applied, "the wheel was not applied to the transcript")

        let scrolled = fixture.scrollView.contentView.bounds.origin.y
        XCTAssertLessThan(scrolled, bottom - 10, "the wheel did not move the text")

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

        // The card opens on the first word, and the newest words are one scroll
        // away. The opening position is read after the dispatched scroll has
        // run: it is the behaviour `HUDView.makeNSView` states, and the older
        // assertion here was written for the end-opening body it replaced.
        XCTAssertLessThanOrEqual(
            clip.bounds.origin.y,
            HUDTheme.transcriptLineHeight,
            "the card did not open on the first word"
        )
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

        // Part of the dwell is spent before the pointer arrives. The amount is
        // handed to the card rather than waited for: the countdown spends the
        // real time between two frames, and a machine running the suite in
        // parallel can withhold frames for longer than the whole dwell and then
        // deliver one frame that spends all of it. `debugAdvanceDwell` goes
        // through the same `updateDwell` the frame loop calls, so the arithmetic
        // under test is the one the app runs.
        hud.debugAdvanceDwell(by: 0.25)
        let beforeReading = try XCTUnwrap(hud.debugDwellRemaining)
        XCTAssertLessThan(beforeReading, 0.5)

        // Reading the card spends none of it, and does not give the card a
        // fresh six tenths either.
        hud.debugPointer(inside: true)
        hud.debugAdvanceDwell(by: 1.0)
        XCTAssertTrue(hud.isVisible, "the card was dismissed while it was being read")
        XCTAssertTrue(hud.debugDwellPaused)
        let afterReading = try XCTUnwrap(hud.debugDwellRemaining)
        XCTAssertEqual(afterReading, beforeReading, accuracy: 0.05, "reading reset the countdown")
        XCTAssertLessThan(afterReading, 0.5, "reading gave the card a second life")

        // The pointer leaves, and what was left is what the card gets.
        hud.debugPointer(inside: false)
        hud.debugAdvanceDwell(by: 1.0)
        XCTAssertFalse(hud.isVisible, "the countdown did not resume when the pointer left")
    }

    // MARK: - The style rail

    /// Two fingers sideways over the chips, while Dot is not the active app.
    ///
    /// The island is a nonactivating panel over the application the person is
    /// dictating into, so AppKit never hands its windows a scroll: the chips'
    /// `ScrollView` would stay still for every swipe. The card applies the event
    /// itself in that case, and this proves the rail really moves — and that it
    /// moves nothing else.
    func testTheBackgroundWheelScrollsTheStyleRailAndTakesNoFocus() throws {
        var moves = 0
        var actions = HUDActions()
        actions.previousVersion = { moves += 1 }
        actions.nextVersion = { moves += 1 }
        let fixture = makeRailHUD(actions: actions)
        defer {
            fixture.hud.hide()
            spin(for: 0.4)
        }

        let panel = fixture.hud.debugPanel
        let windowsBefore = windowsOnScreen()
        XCTAssertFalse(panel.canBecomeKey, "the island became able to take the keyboard")
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow !== panel)

        let rail = try XCTUnwrap(
            HUD.chipRowScrollView(in: fixture.hud.debugRootView),
            "the card's style rail was not found"
        )
        let clip = rail.contentView
        let document = try XCTUnwrap(rail.documentView)
        XCTAssertGreaterThan(
            document.frame.width,
            clip.bounds.width + 1,
            "the card's styles fit its rail, so there is nothing to scroll"
        )
        let maximum = document.frame.width - clip.bounds.width
        // The rail is read once the card's appearance has stopped moving it,
        // and the appearance is what moves it. The card arrives by scaling and
        // offsetting itself, SwiftUI applies those transforms to the views it
        // hosts as frame transforms, and AppKit answers each one by re-deriving
        // the clip's bounds: the rail's origin lands a fraction of a point past
        // its first style and moves again on the next frame. The springs that
        // drive the transform are advanced by the island's frame loop, so on a
        // loaded machine a fixed wait can be a handful of frames and the
        // reading is taken mid-movement: in the full suite this read 0.9998
        // points while the card was still arriving, where its resting position
        // is within half a point of zero. The wait is therefore the springs'
        // own rest state, not a duration. Every position below is the distance
        // from that rest position, so the wheel's travel is what is asserted
        // and not the resting offset.
        XCTAssertTrue(
            waitForRailToRest(fixture.hud, rail),
            "the card's appearance never came to rest, so the rail's opening position is unknown"
        )
        let opened = clip.bounds.origin.x
        XCTAssertEqual(opened, 0, accuracy: 0.5, "the rail did not open on its first style")

        let point = CGPoint(x: fixture.band.midX, y: fixture.band.midY)

        // Fingers left reveal the styles on the right, so the rail's origin
        // grows by the points the gesture carried.
        fixture.hud.debugHandleScrollEvent(try horizontalWheel(points: -60, at: point), at: point)
        XCTAssertEqual(
            clip.bounds.origin.x - opened,
            60,
            accuracy: 1,
            "the background wheel did not move the rail"
        )
        // The card keeps the position through its next layout: a rail that
        // snapped back would look still whatever the offset said.
        settle(fixture.hud, for: 0.15)
        XCTAssertEqual(
            clip.bounds.origin.x - opened,
            60,
            accuracy: 2,
            "the rail did not keep the position the wheel gave it"
        )
        fixture.hud.debugHandleScrollEvent(try horizontalWheel(points: -60, at: point), at: point)
        XCTAssertEqual(clip.bounds.origin.x - opened, 120, accuracy: 1, "the second flick did not continue")
        fixture.hud.debugHandleScrollEvent(try horizontalWheel(points: 60, at: point), at: point)
        XCTAssertEqual(clip.bounds.origin.x - opened, 60, accuracy: 1, "the opposite flick did not come back")

        // Neither end goes past itself, however far the gesture goes.
        for _ in 0 ..< 6 {
            fixture.hud.debugHandleScrollEvent(try horizontalWheel(points: -400, at: point), at: point)
        }
        XCTAssertLessThanOrEqual(
            clip.bounds.origin.x,
            maximum + 0.5,
            "the rail scrolled past the last style"
        )
        XCTAssertEqual(
            clip.bounds.origin.x,
            maximum,
            accuracy: 1,
            "the rail did not come to rest at its last style"
        )
        for _ in 0 ..< 6 {
            fixture.hud.debugHandleScrollEvent(try horizontalWheel(points: 400, at: point), at: point)
        }
        XCTAssertEqual(clip.bounds.origin.x, 0, accuracy: 0.5, "the rail scrolled past its first style")

        // A sideways gesture over the rail is the rail's, not the versions': the
        // card must not turn a swipe into a previous/next move.
        XCTAssertEqual(moves, 0, "scrolling the chips paged the versions")

        // And nothing else moved: no keyboard, no window on a display.
        XCTAssertFalse(panel.isKeyWindow, "the scroll made the panel key")
        XCTAssertTrue(NSApp.keyWindow !== panel, "the scroll gave Dot the keyboard")
        XCTAssertEqual(windowsOnScreen(), windowsBefore, "the scroll put a window on a display")
        XCTAssertTrue(windowsOnScreen().isEmpty, "the test opened a window on a display")
    }

    /// The first style is where the rail rests, not where its opening caught it.
    ///
    /// The card's appearance scales it, and the rail's clip position is derived
    /// under that transform, so a reading taken while the card is still arriving
    /// moves by up to a point. This proves the opening position is a resting
    /// position: the rail is on its first style once the appearance has stopped,
    /// and the frames after that do not move it.
    func testTheStyleRailRestsOnItsFirstStyleAfterTheCardAppears() throws {
        let fixture = makeRailHUD()
        defer {
            fixture.hud.hide()
            spin(for: 0.4)
        }

        let rail = try XCTUnwrap(
            HUD.chipRowScrollView(in: fixture.hud.debugRootView),
            "the card's style rail was not found"
        )
        let clip = rail.contentView
        XCTAssertTrue(
            waitForRailToRest(fixture.hud, rail),
            "the card's appearance never came to rest, so the rail's opening position is unknown"
        )
        let rested = clip.bounds.origin.x
        XCTAssertEqual(rested, 0, accuracy: 0.5, "the rail rested away from its first style")

        // The card's frame loop keeps running while the card is up. A rest
        // position that its later frames moved would mean the rail had opened
        // on a transient of its appearance rather than on its first style.
        spin(for: 0.5)
        fixture.hud.debugRootView.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            clip.bounds.origin.x,
            rested,
            accuracy: 0.5,
            "the rail drifted after the card's appearance came to rest"
        )
    }

    /// A wheel of half a point is the person's, and the card keeps it.
    ///
    /// The card corrects the residue its appearance leaves in the rail's clip.
    /// A wheel that moved the rail is not that residue, however little it
    /// moved: the correction is turned off for the card, so a nudge smaller
    /// than the residue's reach is not swallowed by it. The wheel here is sent
    /// while the card is still arriving, and the rail is read once it has
    /// rested.
    func testASmallWheelBeforeTheCardRestsSurvivesTheOpeningCorrection() throws {
        try WindowCapture.requireFullMotion()
        let card = overflowingCard()
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        hud.showTranscript(text: card.original, delivery: .copied, elapsed: "0:04")
        hud.setRewrite(card)
        hud.debugPointer(inside: true)
        defer {
            hud.hide()
            spin(for: 0.4)
        }

        let rail = try XCTUnwrap(waitForRail(hud), "the card's style rail was not found")
        let clip = rail.contentView
        XCTAssertFalse(
            hud.debugAppearanceAtRest,
            "the card arrived before the wheel, so the wheel did not meet the appearance"
        )
        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: hud.debugPanel.frame,
            cardSize: HUD.transcriptSize(text: card.original, rewrite: card),
            topInset: HUD.shadowPadding
        )
        let band = HUD.rewriteChipRowFrame(cardFrame: cardFrame, card: card)
        let point = CGPoint(x: band.midX, y: band.midY)
        // The rail is at its opening position, so the wheel's own travel is the
        // whole of the displacement it is given.
        clip.scroll(to: .zero)
        rail.reflectScrolledClipView(clip)
        let halfPoint = DeliveredScrollEvent(
            window: hud.debugPanel,
            windowNumber: hud.debugPanel.windowNumber,
            location: hud.debugPanel.convertPoint(fromScreen: point),
            deltaX: -0.5,
            deltaY: 0,
            phase: .began,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        hud.debugHandleScrollEvent(halfPoint, at: point)
        XCTAssertEqual(
            clip.bounds.origin.x,
            0.5,
            accuracy: 1e-6,
            "the half-point wheel did not move the rail"
        )

        XCTAssertTrue(
            waitForRailToRest(hud, rail),
            "the card's appearance never came to rest, so the wheel's survival is unknown"
        )
        XCTAssertGreaterThan(
            clip.bounds.origin.x,
            0.25,
            "the opening correction swallowed the wheel's half point"
        )
        XCTAssertLessThanOrEqual(
            clip.bounds.origin.x,
            1.5,
            "the wheel left the residue window before the correction could be tested"
        )
    }

    /// A version chosen while the card is arriving keeps the rail where it is.
    ///
    /// A version that carries a style opens the row on that style, so the card
    /// leaves the rail alone for it. This runs the action the next-version
    /// arrow runs while the appearance is still arriving — the rail placed a
    /// fraction of a point into its content, inside the window the opening
    /// residue occupies — and proves the correction does not pull it back.
    func testAVersionSelectionDuringTheEntranceSurvivesTheOpeningCorrection() throws {
        try WindowCapture.requireFullMotion()
        var moves = 0
        var card = overflowingCard()
        card.append(id: 1, style: card.choices[4], text: "A shorter version of the words.", warning: nil)
        card.select(versionID: 0)
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        var actions = HUDActions()
        actions.nextVersion = {
            moves += 1
            var next = card
            next.select(versionID: 1)
            hud.setRewrite(next)
        }
        hud.actions = actions
        hud.showTranscript(text: card.original, delivery: .copied, elapsed: "0:04")
        hud.setRewrite(card)
        hud.debugPointer(inside: true)
        defer {
            hud.hide()
            spin(for: 0.4)
        }

        // The appearance is moved by hand to the middle of its entrance, and no
        // run-loop turn is let in between: the moment this test is about is a
        // state of the card, and a machine that delivers the whole arrival in one
        // turn steps over it. 0.200 s of the HUD's own clock is the card half way
        // out of the notch, with both springs still moving.
        for _ in 0 ..< 200 { hud.debugAdvanceAppearance(by: 0.001) }
        XCTAssertLessThan(
            hud.debugPresence,
            0.99,
            "the premise: the card is already \(hud.debugPresence) present at 0.200 s"
        )
        XCTAssertLessThan(
            hud.debugContent,
            0.99,
            "the premise: the card's content is already \(hud.debugContent) settled at 0.200 s"
        )
        XCTAssertFalse(
            hud.debugAppearanceAtRest,
            "the card arrived before the version was chosen, so the choice did not meet the appearance"
        )
        hud.actions.nextVersion?()
        XCTAssertEqual(moves, 1, "the next-version action did not run")

        // The row the action asked for is laid out on the run-loop turns that
        // follow, and the card scrolls it to the style the chosen version
        // carries. That reveal is also the last thing that moves the rail, so
        // the placement is repeated until it holds: the placement lands inside
        // the window the opening correction is defined over, which is where the
        // appearance's residue leaves a rail placed near the start, and it has
        // held once two turns read inside that window. Bounded: a rail that
        // never holds its position is reported rather than read.
        let rail = try XCTUnwrap(waitForRail(hud), "the card's style rail was not found")
        let clip = rail.contentView
        var held = 0
        for _ in 0 ..< 6 where held < 2 {
            clip.scroll(to: NSPoint(x: 0.5, y: 0))
            rail.reflectScrolledClipView(clip)
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            hud.debugRootView.layoutSubtreeIfNeeded()
            held = abs(clip.bounds.origin.x) <= 1.5 ? held + 1 : 0
        }
        XCTAssertEqual(
            held,
            2,
            "the rail would not hold the position it was placed at: it read \(clip.bounds.origin.x)"
        )
        XCTAssertFalse(
            hud.debugAppearanceAtRest,
            "the card settled before the rail was placed, so the choice did not meet the appearance"
        )

        XCTAssertTrue(
            waitForRailToRest(hud, rail),
            "the card's appearance never came to rest, so the rail's position is unknown"
        )
        XCTAssertGreaterThan(
            clip.bounds.origin.x,
            0.25,
            "the opening correction pulled the rail off the version the action selected"
        )
        XCTAssertLessThanOrEqual(
            clip.bounds.origin.x,
            1.5,
            "the rail left the residue window before the correction could be tested"
        )
    }

    /// The next-version arrow clicked while the card is arriving keeps its place.
    ///
    /// The appearance scales and offsets the card, so the arrow is not where its
    /// settled geometry puts it. This aims at the control's rect under the
    /// transform that is on screen at the moment of the click, clicks it while
    /// the springs are still moving, and proves the style it revealed is still
    /// on the rail once the appearance has stopped.
    func testAnEarlyArrowClickSurvivesTheOpeningCorrection() throws {
        try WindowCapture.requireFullMotion()
        var moves = 0
        var card = overflowingCard()
        card.append(id: 1, style: card.choices[4], text: "A shorter version of the words.", warning: nil)
        // The card opens on the original: the trailing control is then the
        // next-version arrow, not the rerun button.
        card.select(versionID: 0)
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        var actions = HUDActions()
        actions.nextVersion = {
            moves += 1
            var next = card
            next.select(versionID: 1)
            hud.setRewrite(next)
        }
        hud.actions = actions
        hud.showTranscript(text: card.original, delivery: .copied, elapsed: "0:04")
        hud.setRewrite(card)
        hud.debugPointer(inside: true)
        defer {
            hud.hide()
            spin(for: 0.4)
        }

        let rail = try XCTUnwrap(waitForRail(hud), "the card's style rail was not found")
        let clip = rail.contentView
        assertTheRevealedStyleSitsPastTheThreshold(
            choices: card.choices,
            index: 4,
            viewportWidth: clip.bounds.width
        )
        // A card at the very start of its appearance is still transparent, so
        // the click is made once it is visibly arriving.
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                hud.debugPresence > 0.5 && hud.debugContent > 0.5
            },
            "the card never became visible"
        )
        XCTAssertFalse(
            hud.debugAppearanceAtRest,
            "the card arrived before the click, so the click did not meet the appearance"
        )
        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: hud.debugPanel.frame,
            cardSize: HUD.transcriptSize(text: card.original, rewrite: card),
            topInset: HUD.shadowPadding
        )
        // The next-version arrow's place on the settled card, then the same
        // point through the scale and offset the card is drawn with now.
        let settled = hud.debugPanel.convertPoint(fromScreen: CGPoint(
            x: cardFrame.maxX - HUDTheme.padding - HUDRewriteLayout.versionArrowWidth / 2,
            y: cardFrame.minY + HUDState.verticalPadding + HUDRewriteLayout.chipHeight / 2
        ))
        let center = hud.debugPanel.convertPoint(fromScreen: CGPoint(
            x: cardFrame.midX,
            y: cardFrame.midY
        ))
        let presence = CGFloat(hud.debugPresence)
        let content = CGFloat(hud.debugContent)
        // The card's appearance is the two scale and offset pairs HUDView
        // draws: the content's 0.99…1 scale and 6 pt offset, then the card's
        // 0.94…1 scale and 10 pt offset, both about the card's centre.
        let innerScale = 0.99 + 0.01 * content
        let outerScale = 0.94 + 0.06 * presence
        let point = CGPoint(
            x: center.x + (settled.x - center.x) * innerScale * outerScale,
            y: center.y
                + ((settled.y - center.y) * innerScale - (1 - content) * 6) * outerScale
                + (1 - presence) * 10
        )
        // The card takes the mouse while the pointer is over it; the pointer
        // here is the test's own, so the window is told the same.
        hud.debugPanel.ignoresMouseEvents = false
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: hud.debugPanel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            hud.debugPanel.sendEvent(event)
        }
        XCTAssertEqual(moves, 1, "the early next-version arrow did not run")

        XCTAssertTrue(
            waitForRailToSettle(hud, rail),
            "the rail never stopped moving, so its resting position is unknown"
        )
        XCTAssertGreaterThan(
            clip.bounds.origin.x,
            50,
            "the opening correction pulled the rail back from the style the early arrow revealed"
        )
    }

    /// A version arrow's reveal survives the opening correction.
    ///
    /// The card corrects the rail's opening position once its appearance has
    /// stopped, and that correction must never undo a style the person reached.
    /// The click is made after the card has arrived because the appearance
    /// scales and offsets the views it hosts, so a click aimed at the settled
    /// geometry cannot reach a control while the card is still moving. This
    /// proves the arrow runs, the rail moves to the style it selected, and the
    /// correction does not pull the rail back from it.
    func testAVersionArrowClickSurvivesTheOpeningCorrection() throws {
        var moves = 0
        var card = overflowingCard()
        card.append(id: 1, style: card.choices[4], text: "A shorter version of the words.", warning: nil)
        // The card opens on the original: the trailing control is then the
        // next-version arrow, not the rerun button.
        card.select(versionID: 0)
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        var actions = HUDActions()
        actions.nextVersion = {
            moves += 1
            var next = card
            next.select(versionID: 1)
            hud.setRewrite(next)
        }
        hud.actions = actions
        hud.showTranscript(text: card.original, delivery: .copied, elapsed: "0:04")
        hud.setRewrite(card)
        hud.debugPointer(inside: true)
        defer {
            hud.hide()
            spin(for: 0.4)
        }

        let rail = try XCTUnwrap(waitForRail(hud), "the card's style rail was not found")
        XCTAssertTrue(
            waitForRailToRest(hud, rail),
            "the card's appearance never came to rest, so the arrow cannot be clicked"
        )
        let clip = rail.contentView
        assertTheRevealedStyleSitsPastTheThreshold(
            choices: card.choices,
            index: 4,
            viewportWidth: clip.bounds.width
        )
        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: hud.debugPanel.frame,
            cardSize: HUD.transcriptSize(text: card.original, rewrite: card),
            topInset: HUD.shadowPadding
        )
        // The next-version arrow is the row's trailing control, one gap inside
        // the card's trailing padding.
        let point = hud.debugPanel.convertPoint(fromScreen: CGPoint(
            x: cardFrame.maxX - HUDTheme.padding - HUDRewriteLayout.versionArrowWidth / 2,
            y: cardFrame.minY + HUDState.verticalPadding + HUDRewriteLayout.chipHeight / 2
        ))
        // The card takes the mouse while the pointer is over it; the pointer
        // here is the test's own, so the window is told the same.
        hud.debugPanel.ignoresMouseEvents = false
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: hud.debugPanel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            hud.debugPanel.sendEvent(event)
        }
        XCTAssertEqual(moves, 1, "the next-version arrow did not run")

        XCTAssertTrue(
            waitForRailToSettle(hud, rail),
            "the rail never stopped moving, so its resting position is unknown"
        )
        XCTAssertGreaterThan(
            clip.bounds.origin.x,
            50,
            "the opening correction pulled the rail back from the style the arrow revealed"
        )
    }

    /// A rail wheel is applied by the card, and the local monitor stops the
    /// delivered event before any view receives it.
    ///
    /// The card owns every rail gesture: it moves the row itself and returns
    /// nil from the local monitor, so a native view can never apply the same
    /// wheel a second time. The probe view sits over the card and counts what
    /// reaches it, which is how the test sees the swallow instead of trusting
    /// a return value.
    func testTheLocalMonitorStopsADeliveredRailWheelBeforeAnyViewAppliesIt() throws {
        let fixture = makeRailHUD()
        defer {
            fixture.hud.hide()
            spin(for: 0.4)
        }
        let hud = fixture.hud
        let panel = hud.debugPanel
        let host = hud.debugRootView
        let rail = try XCTUnwrap(
            HUD.chipRowScrollView(in: host),
            "the card's style rail was not found"
        )
        let clip = rail.contentView
        let point = CGPoint(x: fixture.band.midX, y: fixture.band.midY)
        let windowPoint = panel.convertPoint(fromScreen: point)

        // NSHostingView does not accept test subviews above its SwiftUI
        // content, so the hosting view moves into a plain container and the
        // probe becomes its sibling. Nothing the card draws changes.
        let container = NSView(frame: host.frame)
        panel.contentView = container
        host.frame = container.bounds
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let probe = ScrollDeliveryProbe(frame: container.bounds)
        container.addSubview(probe)
        defer { probe.removeFromSuperview() }
        container.layoutSubtreeIfNeeded()
        let before = clip.bounds.origin.x

        let delivered = DeliveredScrollEvent(
            window: panel,
            windowNumber: panel.windowNumber,
            location: windowPoint,
            deltaX: 0,
            deltaY: -30,
            phase: .began,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        XCTAssertTrue(delivered.window === panel, "the event was not associated with the panel")
        NSApp.sendEvent(delivered)

        XCTAssertEqual(
            clip.bounds.origin.x,
            before + 30,
            accuracy: 0.5,
            "the swallowed wheel was not applied exactly once"
        )
        XCTAssertEqual(
            probe.scrollCount,
            0,
            "the swallowed wheel still reached a native view"
        )

        // A wheel the card does not own passes the monitor. The probe proves
        // the dispatch path: without the swallow above, it would have seen the
        // rail event too.
        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: panel.frame,
            cardSize: HUD.transcriptSize(text: fixture.card.original, rewrite: fixture.card),
            topInset: HUD.shadowPadding
        )
        let bodyFrame = HUD.transcriptBodyFrame(cardFrame: cardFrame, card: fixture.card)
        let bodyPoint = CGPoint(x: bodyFrame.midX, y: bodyFrame.midY)
        let passed = DeliveredScrollEvent(
            window: panel,
            windowNumber: panel.windowNumber,
            location: panel.convertPoint(fromScreen: bodyPoint),
            deltaX: 0,
            deltaY: -10,
            phase: .began,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        NSApp.sendEvent(passed)
        XCTAssertEqual(
            probe.scrollCount,
            1,
            "the monitor swallowed a wheel the card does not own"
        )
    }

    /// The wheel over a long transcript in a background island.
    ///
    /// The body is a scroll view of its own, and a body that cannot be scrolled
    /// is a body whose end cannot be read. The vertical gesture belongs to it;
    /// the horizontal one is still the versions' swipe.
    func testTheBackgroundWheelScrollsTheTranscriptBody() throws {
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        defer {
            hud.hide()
            spin(for: 0.4)
        }
        hud.showTranscript(text: longText, delivery: .copied, elapsed: "4:18")
        hud.debugPointer(inside: true)
        settle(hud)

        let body = try XCTUnwrap(
            HUD.transcriptScrollView(in: hud.debugRootView),
            "the long transcript is not in a scrollable body"
        )
        let clip = body.contentView
        let maximum = max(0, (body.documentView?.frame.height ?? 0) - clip.bounds.height)
        XCTAssertGreaterThan(maximum, 40, "the transcript is not longer than its body")

        // Start in the middle so both directions have room, then let the wheel
        // go back and forth over the words.
        clip.scroll(to: NSPoint(x: 0, y: maximum / 2))
        body.reflectScrolledClipView(clip)
        let middle = clip.bounds.origin.y

        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: hud.debugPanel.frame,
            cardSize: HUD.transcriptSize(text: longText),
            topInset: HUD.shadowPadding
        )
        let bodyFrame = HUD.transcriptBodyFrame(cardFrame: cardFrame, card: nil)
        let point = CGPoint(x: bodyFrame.midX, y: bodyFrame.midY)

        hud.debugHandleScrollEvent(try verticalWheel(points: 30, at: point), at: point)
        XCTAssertEqual(
            clip.bounds.origin.y,
            max(0, middle - 30),
            accuracy: 1,
            "the wheel did not go back to the earlier words"
        )
        hud.debugHandleScrollEvent(try verticalWheel(points: -30, at: point), at: point)
        XCTAssertEqual(clip.bounds.origin.y, middle, accuracy: 1, "the wheel did not come forward again")
        XCTAssertFalse(hud.debugPanel.isKeyWindow, "the scroll made the panel key")
        XCTAssertTrue(NSApp.keyWindow !== hud.debugPanel, "the scroll gave Dot the keyboard")
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

        let panel = OffscreenHUDPanel(size: size)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true

        let host = HUDHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        for _ in 0 ..< 4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }

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
    /// The deadline is long on purpose. The HUD's clock only moves on frames
    /// the run loop delivers, and a machine running the test bundle in parallel
    /// can go a second or more without giving this process a turn. A short
    /// window measures the machine's load rather than the behaviour under test;
    /// the condition itself is what the test is about, so it is polled for
    /// until it holds.
    ///
    /// - Parameters:
    ///   - timeout: how long to wait, in seconds.
    ///   - condition: what has to become true.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5,
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

    /// A sideways wheel at a point: the two-finger swipe of a trackpad, with
    /// precise point deltas and no window of its own, which is what the global
    /// monitor sees while another application is frontmost.
    private func horizontalWheel(points: Int32, at point: NSPoint) throws -> NSEvent {
        try scrollWheel(wheel1: 0, wheel2: points, at: point)
    }

    /// A vertical wheel at a point, with precise point deltas.
    private func verticalWheel(points: Int32, at point: NSPoint) throws -> NSEvent {
        try scrollWheel(wheel1: points, wheel2: 0, at: point)
    }

    private func scrollWheel(wheel1: Int32, wheel2: Int32, at point: NSPoint) throws -> NSEvent {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: wheel2 == 0 ? 1 : 2,
                wheel1: wheel1,
                wheel2: wheel2,
                wheel3: 0
            )
        )
        event.location = CGPoint(x: point.x, y: screenHeight - point.y)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    /// The windows of this process that sit on a display.
    ///
    /// Every fixture here is ordered front off every screen, so the set stays
    /// empty: it is how a test says the island was never drawn on the Mac.
    private func windowsOnScreen() -> Set<Int> {
        Set(
            NSApp.windows
                .filter { window in
                    guard window.isVisible, !window.frame.isEmpty else { return false }
                    return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
                }
                .map(\.windowNumber)
        )
    }

    /// An island with a card whose styles outgrow its rail, off every screen.
    ///
    /// The card is the island's own — the panel, the hosting view, the model
    /// that the wheel is applied through — not a replica of them.
    private func makeRailHUD(
        actions: HUDActions = HUDActions()
    ) -> (hud: HUD, card: RewriteCard, band: CGRect) {
        _ = NSApplication.shared
        let card = overflowingCard()
        let hud = HUD(offscreen: true)
        hud.dwell = 60
        hud.actions = actions
        hud.showTranscript(text: card.original, delivery: .copied, elapsed: "0:04")
        hud.setRewrite(card)
        hud.debugPointer(inside: true)
        settle(hud)

        let cardFrame = HUDPlacement.cardFrame(
            panelFrame: hud.debugPanel.frame,
            cardSize: HUD.transcriptSize(text: card.original, rewrite: card),
            topInset: HUD.shadowPadding
        )
        let band = HUD.rewriteChipRowFrame(cardFrame: cardFrame, card: card)
        XCTAssertFalse(band.isEmpty, "the card drew no band for its chips")
        return (hud, card, band)
    }

    /// The card's words, and more styles than the card can show at once.
    private func overflowingCard() -> RewriteCard {
        let custom = (0 ..< 6).map { index in
            RewriteStyle(
                CustomRewriteStyle(
                    id: "custom-\(index)",
                    title: String(repeating: "W", count: CustomRewriteStyle.maximumTitleLength),
                    instruction: "Rewrite."
                )
            )
        }
        return RewriteCard(
            original: "A transcript with enough words to fill the body of the card and give every style something to work on.",
            choices: RewriteStyle.builtIns + custom
        )
    }

    /// Lays the island's card out, off every screen.
    private func settle(_ hud: HUD, for seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            hud.debugRootView.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
        hud.debugRootView.layoutSubtreeIfNeeded()
    }

    /// Waits for the card's style rail to be drawn and wider than its clip.
    ///
    /// A click needs the card's layout, which is not the same thing as its
    /// appearance: the row exists as soon as SwiftUI has laid the card out, and
    /// this waits on that rather than on the animation the appearance runs.
    ///
    /// - Parameters:
    ///   - hud: the island the card is drawn in.
    ///   - seconds: the deadline.
    /// - Returns: the rail, or `nil` when the card never drew one.
    private func waitForRail(_ hud: HUD, within seconds: TimeInterval = 2) -> NSScrollView? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            hud.debugRootView.layoutSubtreeIfNeeded()
            if let rail = HUD.chipRowScrollView(in: hud.debugRootView),
               let document = rail.documentView,
               document.frame.width > rail.contentView.bounds.width + 1 {
                return rail
            }
            RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.02))
            )
        } while Date() < deadline
        return nil
    }

    /// Waits for the card's appearance to stop moving the rail, and lays it out.
    ///
    /// The card arrives by scaling and offsetting itself, SwiftUI hands those
    /// transforms to the views it hosts as frame transforms, and AppKit
    /// re-derives the clip's bounds under each one: what the clip's origin
    /// reads is the appearance's position, not the rail's. The two springs that
    /// drive it are advanced by the island's frame loop, so their rest is a
    /// state and not a duration — a busy machine delivers fewer frames, and a
    /// fixed wait reads the rail mid-movement.
    ///
    /// The rail is settled when the springs rest and its clip, its document and
    /// the hosting view keep the same geometry through several layout passes,
    /// which is the last transform having been answered.
    ///
    /// - Parameters:
    ///   - hud: the island the card is drawn in.
    ///   - rail: the card's style rail.
    ///   - seconds: the deadline. A card that never comes to rest is reported
    ///     rather than read mid-movement.
    /// - Returns: whether the card came to rest within the deadline.
    @discardableResult
    private func waitForRailToRest(
        _ hud: HUD,
        _ rail: NSScrollView,
        within seconds: TimeInterval = 4
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var previous = RailRestGeometry()
        var still = 0
        repeat {
            hud.debugRootView.layoutSubtreeIfNeeded()
            let geometry = RailRestGeometry(hud: hud, rail: rail)
            if hud.debugAppearanceAtRest, geometry == previous {
                still += 1
                if still >= 3 { return true }
            } else {
                still = 0
            }
            previous = geometry
            RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.02))
            )
        } while Date() < deadline
        return false
    }

    /// Waits for the rail to stop moving after an arrow asked it to reveal a
    /// style.
    ///
    /// ``waitForRailToRest(_:_:within:)`` answers a different question: whether
    /// the card's appearance has stopped transforming the views it hosts. A
    /// reveal is a scroll the card runs *after* that, over 0.18 s, and it starts
    /// on the SwiftUI update that follows the click, so a wait that only counts
    /// layout passes can return before the reveal's first frame and read the
    /// rail where it started. Measured here, that read was 0.0, 3.5, 10.5 and
    /// 14.5 points across runs while the rail came to rest at 174.5.
    ///
    /// This waits for the rail itself: the clip's origin has to hold still for
    /// longer than the reveal's animation, so what it returns is the position
    /// the rail came to rest at and not one frame of the scroll on its way
    /// there. A rail that never moves is still reported as at rest, which is
    /// what lets the assertion after it name a reveal that did not happen.
    ///
    /// - Parameters:
    ///   - hud: the island the card is drawn in.
    ///   - rail: the card's style rail.
    ///   - seconds: the deadline.
    /// - Returns: whether the rail came to rest within the deadline.
    @discardableResult
    private func waitForRailToSettle(
        _ hud: HUD,
        _ rail: NSScrollView,
        within seconds: TimeInterval = 4
    ) -> Bool {
        // Longer than the 0.18 s ease-out the reveal scrolls with, so a rail
        // still travelling can never be mistaken for one that has stopped.
        let stillness: TimeInterval = 0.3
        let deadline = Date().addingTimeInterval(seconds)
        var origin = rail.contentView.bounds.origin
        var stillSince = Date()
        repeat {
            hud.debugRootView.layoutSubtreeIfNeeded()
            let current = rail.contentView.bounds.origin
            if current != origin {
                origin = current
                stillSince = Date()
            } else if hud.debugAppearanceAtRest,
                      Date().timeIntervalSince(stillSince) >= stillness {
                return true
            }
            RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.02))
            )
        } while Date() < deadline
        return false
    }

    /// Asserts the style an arrow reveals sits far enough along the rail that
    /// revealing it must move the rail by more than the 50 points the arrow
    /// tests require.
    ///
    /// Those tests only see a reveal if the row both outgrows its viewport and
    /// keeps the revealed style well past the middle of it. A narrower face or
    /// a shorter label can quietly turn the reveal into a no-op, and the tests
    /// would then be asserting on a rail that never had anywhere to go. The
    /// numbers come from the metrics the row itself lays out with, so this is
    /// the same arithmetic the card does and not a second opinion about it.
    ///
    /// - Parameters:
    ///   - choices: the styles on the card, in the row's order.
    ///   - index: the style the arrow reveals.
    ///   - viewportWidth: the width the styles are clipped to.
    private func assertTheRevealedStyleSitsPastTheThreshold(
        choices: [RewriteStyle],
        index: Int,
        viewportWidth: CGFloat
    ) {
        let leading = RewriteChipMetrics.rowWidth(choices.prefix(index).map(\.title))
            + HUDRewriteLayout.chipGap
        let centre = leading + RewriteChipMetrics.chipWidth(choices[index].title) / 2
        XCTAssertGreaterThan(
            centre - viewportWidth / 2,
            50,
            "the style the arrow reveals sits \(centre - viewportWidth / 2) points along the rail, "
                + "so revealing it cannot move the rail the 50 points this test asserts"
        )
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

/// Counts the scroll wheels a view is asked to apply.
private final class ScrollDeliveryProbe: NSView {
    private(set) var scrollCount = 0

    override func scrollWheel(with event: NSEvent) {
        scrollCount += 1
    }
}

/// A wheel that carries the panel it was delivered to.
///
/// A scroll `NSEvent` cannot be given a window from the outside, and a local
/// monitor only sees the events this application dispatches. The subclass
/// supplies the window and the event-time location that `NSApp.sendEvent`
/// would have supplied on a real delivery, so the production monitor can be
/// exercised without a visible window or a real gesture.
private final class DeliveredScrollEvent: NSEvent {
    private let fakeWindow: NSWindow?
    private let fakeWindowNumber: Int
    private let fakeLocation: CGPoint
    private let fakeDeltaX: CGFloat
    private let fakeDeltaY: CGFloat
    private let fakePhase: NSEvent.Phase
    private let fakeTimestamp: TimeInterval

    init(
        window: NSWindow,
        windowNumber: Int,
        location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        timestamp: TimeInterval
    ) {
        fakeWindow = window
        fakeWindowNumber = windowNumber
        fakeLocation = location
        fakeDeltaX = deltaX
        fakeDeltaY = deltaY
        fakePhase = phase
        fakeTimestamp = timestamp
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("unused")
    }

    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { fakeWindow }
    override var windowNumber: Int { fakeWindowNumber }
    override var locationInWindow: NSPoint { fakeLocation }
    override var scrollingDeltaX: CGFloat { fakeDeltaX }
    override var scrollingDeltaY: CGFloat { fakeDeltaY }
    override var deltaX: CGFloat { fakeDeltaX }
    override var deltaY: CGFloat { fakeDeltaY }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { fakePhase }
    override var momentumPhase: NSEvent.Phase { [] }
    override var isDirectionInvertedFromDevice: Bool { false }
    override var timestamp: TimeInterval { fakeTimestamp }
}

/// The geometry a style rail keeps when nothing is moving it.
///
/// The clip's position and the sizes that decide it are read together: a
/// scroll view whose clip, document or host is still changing size has not
/// finished the layout pass that the position belongs to.
private struct RailRestGeometry: Equatable {
    var origin = CGPoint.zero
    var clipSize = CGSize.zero
    var documentSize = CGSize.zero
    var hostSize = CGSize.zero

    init() {}

    @MainActor
    init(hud: HUD, rail: NSScrollView) {
        origin = rail.contentView.bounds.origin
        clipSize = rail.contentView.bounds.size
        documentSize = rail.documentView?.frame.size ?? .zero
        hostSize = hud.debugRootView.frame.size
    }
}
