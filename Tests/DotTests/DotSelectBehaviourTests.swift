import AppKit
import Combine
@testable import Dot
import QuartzCore
import SwiftUI
import XCTest

/// The open list against a real window: where it lands, and what ends it.
///
/// The placement tests prove the arithmetic and the session tests prove the
/// monitors; neither of them has a window. These tests host the shipped trigger
/// in a window shaped like the settings page, press it, and read the panel the
/// app actually put on the screen.
@MainActor
final class DotSelectBehaviourTests: XCTestCase {
    private static var openWindows: [NSWindow] = []
    private static var originalSessionFactory: (([String], Int?, @escaping () -> Int) -> DotSelectSession)?

    private var window: NSWindow?
    private var model: SelectPageModel?
    private let monitors = CountingMonitors()

    /// Closes whatever the previous test left open.
    ///
    /// XCTest makes a fresh instance for every test, and the list controller is
    /// one object for the whole app, so the window, the panel and the session
    /// factory are cleaned here rather than in a tear-down the actor cannot
    /// reach.
    private func closeEverythingFromTheLastTest() {
        DotSelectListController.shared.close()
        if let original = Self.originalSessionFactory {
            DotSelectListController.shared.makeSession = original
            Self.originalSessionFactory = nil
        }
        for window in Self.openWindows {
            window.orderOut(nil)
            window.close()
        }
        Self.openWindows.removeAll()
        for panel in NSApp.windows.compactMap({ $0 as? DotSelectPanel }) {
            panel.orderOut(nil)
            panel.close()
        }
        OffscreenScreen.restore()
    }

    // MARK: - Where the list lands

    /// The card hangs four points under the trigger, left edges aligned, and the
    /// window the app ordered on screen is the card plus its shadow.
    func testTheListOpensDirectlyUnderItsTrigger() throws {
        let fixture = try makeFixture()
        let trigger = try XCTUnwrap(fixture.trigger("Setting 01"))
        let anchor = fixture.screenFrame(of: trigger)

        try fixture.open("Setting 01")

        let card = try XCTUnwrap(fixture.cardFrame())
        let panel = try XCTUnwrap(DotSelectListController.shared.panel)
        let expected = DotSelectPlacement.frame(
            anchor: anchor,
            size: card.size,
            visibleFrame: visibleFrame()
        )
        XCTAssertEqual(card.minX, expected.minX, accuracy: 0.5, "the left edges follow the trigger")
        XCTAssertEqual(card.minY, expected.minY, accuracy: 0.5, "the card is placed by its trigger")
        XCTAssertEqual(
            fixture.openedCardFrame,
            expected,
            "the card the controller placed is the card it drew"
        )
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.canBecomeKey, "the list must never take the keyboard focus")
        XCTAssertEqual(panel.parent, window, "the list belongs to the window that opened it")
    }

    /// A trigger half way down a scrolled page: the list belongs under the
    /// trigger as it is now, not where it was before the page moved.
    func testRegressionListOpensUnderATriggerOnAScrolledPage() throws {
        let fixture = try makeFixture()
        fixture.scrollPage(by: 240)

        let trigger = try XCTUnwrap(fixture.trigger("Setting 01"))
        let anchor = fixture.screenFrame(of: trigger)
        try fixture.open("Setting 01")

        let card = try XCTUnwrap(fixture.cardFrame())
        XCTAssertEqual(
            card.maxY,
            anchor.minY - DotSelectPlacement.gap,
            accuracy: 0.5,
            "the list was placed from a frame recorded before the page scrolled"
        )
        XCTAssertEqual(card.minX, anchor.minX, accuracy: 0.5)
    }

    func testTheListFlipsAboveWhenTheTriggerSitsNearTheBottom() throws {
        let fixture = try makeFixture(rows: 3, options: 8, height: 220, atScreenBottom: true)
        let trigger = try XCTUnwrap(fixture.trigger("Setting 01"))
        let anchor = fixture.screenFrame(of: trigger)

        try fixture.open("Setting 01")

        let card = try XCTUnwrap(fixture.cardFrame())
        XCTAssertEqual(
            card.minY,
            anchor.maxY + DotSelectPlacement.gap,
            accuracy: 0.5,
            "the card did not open above a trigger that has no room below it"
        )
        XCTAssertGreaterThanOrEqual(card.minY, visibleFrame().minY)
    }

    func testRegressionCardStaysInsideTheScreenAtTheTrailingEdge() throws {
        let fixture = try makeFixture(
            rows: 3,
            options: 2,
            longOptions: true,
            trailing: true,
            windowWidth: 420
        )
        let trigger = try XCTUnwrap(fixture.trigger("Setting 01"))
        let anchor = fixture.screenFrame(of: trigger)
        try fixture.open("Setting 01")

        let card = try XCTUnwrap(fixture.cardFrame())
        XCTAssertGreaterThan(card.width, anchor.width, "this case needs a card wider than its trigger")
        XCTAssertLessThanOrEqual(
            card.maxX,
            visibleFrame().maxX,
            "the card runs off the right of the screen"
        )
        XCTAssertGreaterThanOrEqual(card.minX, visibleFrame().minX)
    }

    /// A window dragged to another display takes its list with it, and a list
    /// opened there is placed against that display's edges.
    func testTheListBelongsToTheDisplayItsWindowMovedTo() throws {
        let fixture = try makeFixture()
        let first = OffscreenScreen.frame
        let second = NSRect(
            x: first.maxX,
            y: first.minY,
            width: first.width,
            height: first.height
        )
        OffscreenScreen.install(screens: [first, second])

        let origin = fixture.window.frame.origin
        fixture.moveWindow(by: CGSize(
            width: second.minX + 300 - origin.x,
            height: second.minY - origin.y
        ))
        fixture.settle(0.1)

        let trigger = try XCTUnwrap(fixture.trigger("Setting 02"))
        let anchor = fixture.screenFrame(of: trigger)
        XCTAssertTrue(
            second.contains(CGPoint(x: anchor.midX, y: anchor.midY)),
            "the trigger did not move to the other display"
        )
        try fixture.open("Setting 02")

        let card = try XCTUnwrap(fixture.cardFrame())
        XCTAssertTrue(
            second.contains(card),
            "the list was drawn on the display the window came from"
        )
        XCTAssertEqual(card.maxY, anchor.minY - DotSelectPlacement.gap, accuracy: 0.5)
    }

    /// SwiftUI lays the page out again while the list is open, and a clip view
    /// that changed size has not scrolled: the trigger is where it was, so the
    /// list stays.
    func testARelayoutOfThePageDoesNotCloseTheList() throws {
        let fixture = try makeFixture(rows: 3, options: 4)
        try fixture.open("Setting 01")
        let clip = try XCTUnwrap(fixture.pageScrollView?.contentView)
        let size = clip.bounds.size
        let origin = clip.bounds.origin

        clip.setBoundsSize(NSSize(width: size.width, height: size.height - 12))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        fixture.settle(0.05)

        XCTAssertTrue(DotSelectListController.shared.isShowing, "a layout pass closed the list")
        XCTAssertEqual(clip.bounds.origin, origin, "the page scrolled")
        clip.setBoundsSize(size)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        fixture.settle(0.05)
        XCTAssertTrue(DotSelectListController.shared.isShowing)
    }

    /// The row that was chosen holds before the card goes, and the person may
    /// open another list in that moment: the close belongs to the list that
    /// chose the row and must not shut the one opened after it.
    func testChoosingARowDoesNotCloseTheListOpenedAfterIt() throws {
        let fixture = try makeFixture(rows: 3, options: 4)
        try fixture.open("Setting 01")
        let session = try XCTUnwrap(DotSelectListController.shared.session)
        XCTAssertNil(session.handleKey(Self.key(code: 36, characters: "\r")), "return chooses the row")

        // Before the held row has gone, another trigger is opened.
        try fixture.open("Setting 03")
        fixture.settle(0.4)

        XCTAssertTrue(DotSelectListController.shared.isShowing, "the close of the first list shut the second")
        let panel = try XCTUnwrap(DotSelectListController.shared.panel)
        XCTAssertTrue(panel.isVisible, "the second list's window is not visible")
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01, "the second list was left faded out")
        XCTAssertEqual(fixture.visiblePanelCount, 1)
        DotSelectListController.shared.close()
    }

    // MARK: - What ends the list

    func testEscapeClosesTheList() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")
        let session = try XCTUnwrap(DotSelectListController.shared.session)

        XCTAssertNil(session.handleKey(Self.key(code: 53, characters: "\u{1B}")), "the list uses escape")
        fixture.settle(0.05)

        XCTAssertFalse(DotSelectListController.shared.isShowing)
        XCTAssertEqual(fixture.visiblePanelCount, 0)
        XCTAssertEqual(fixture.childCount, 0)
    }

    func testAClickOutsideTheListClosesItAndIsStillDelivered() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")
        let session = try XCTUnwrap(DotSelectListController.shared.session)
        let click = try XCTUnwrap(Self.click(in: fixture.window.windowNumber))

        XCTAssertNotNil(session.handleMouse(click), "the click belongs to the window behind")
        fixture.settle(0.05)

        XCTAssertFalse(DotSelectListController.shared.isShowing)
        XCTAssertEqual(fixture.visiblePanelCount, 0)
    }

    /// The sidebar click that swaps the page rebuilds every row, so the trigger
    /// that owns the list is gone.
    func testSwitchingThePageClosesTheList() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")

        model?.page = 1
        fixture.settle(0.1)

        XCTAssertFalse(DotSelectListController.shared.isShowing)
        XCTAssertEqual(fixture.visiblePanelCount, 0)
        XCTAssertEqual(fixture.childCount, 0)
    }

    /// A formatting row disappears when its app is removed, or when the service
    /// behind it changes; it must not leave its list behind.
    func testARowThatDisappearsClosesItsList() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")

        model?.rows.removeAll { $0.id == "Setting 01" }
        fixture.settle(0.1)

        XCTAssertFalse(DotSelectListController.shared.isShowing)
        XCTAssertEqual(fixture.visiblePanelCount, 0)
    }

    /// One list at a time: opening a second closes the first, its monitors and
    /// all, and the one window moves to the trigger that opened it.
    func testOpeningAnotherListClosesTheOneAlreadyOpen() throws {
        let fixture = try makeFixture()
        let counting = installCountingMonitors()
        try fixture.open("Setting 01")
        let first = try XCTUnwrap(DotSelectListController.shared.session)

        try fixture.open("Setting 04")

        let second = try XCTUnwrap(DotSelectListController.shared.session)
        XCTAssertFalse(first === second, "the second list kept the first list's session")
        XCTAssertEqual(first.monitorsRemoved, first.monitorsAdded)
        XCTAssertEqual(counting.removed, DotSelectSession.watchCount)
        XCTAssertEqual(fixture.visiblePanelCount, 1, "two lists are on the screen")
        XCTAssertEqual(fixture.childCount, 1)

        let trigger = try XCTUnwrap(fixture.trigger("Setting 04"))
        let anchor = fixture.screenFrame(of: trigger)
        let card = try XCTUnwrap(fixture.cardFrame())
        XCTAssertEqual(card.maxY, anchor.minY - DotSelectPlacement.gap, accuracy: 0.5)
        XCTAssertEqual(card.minX, anchor.minX, accuracy: 0.5)
    }

    // MARK: - The window around the list

    func testMovingTheWindowClosesTheList() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")

        fixture.moveWindow(by: CGSize(width: 40, height: 30))
        fixture.settle(0.1)

        XCTAssertFalse(
            DotSelectListController.shared.isShowing,
            "the list was left hanging over the place the window used to be"
        )
        XCTAssertEqual(fixture.visiblePanelCount, 0)
    }

    func testRegressionListClosesWhenItsWindowIsResized() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")

        fixture.resizeWindow(height: 380)
        fixture.settle(0.15)

        XCTAssertFalse(
            DotSelectListController.shared.isShowing,
            "the list stayed where the trigger was before the window changed height"
        )
        XCTAssertEqual(fixture.visiblePanelCount, 0)
        XCTAssertEqual(fixture.childCount, 0)
    }

    func testRegressionListClosesWhenThePageScrollsUnderIt() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")

        fixture.scrollPage(by: 120)
        fixture.settle(0.1)

        XCTAssertFalse(
            DotSelectListController.shared.isShowing,
            "the trigger scrolled away and the list stayed behind"
        )
        XCTAssertEqual(fixture.visiblePanelCount, 0)
    }

    func testRegressionListClosesWithItsWindow() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")

        window?.close()
        window = nil
        fixture.settle(0.1)

        XCTAssertFalse(DotSelectListController.shared.isShowing, "the list outlived its window")
        XCTAssertNil(DotSelectListController.shared.session, "the monitors outlived the list")
        XCTAssertEqual(fixture.visiblePanelCount, 0)
    }

    func testRegressionAppDeactivationClosesTheList() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        fixture.settle(0.1)

        XCTAssertFalse(DotSelectListController.shared.isShowing)
        XCTAssertEqual(fixture.visiblePanelCount, 0)
    }


    /// A wheel over the page ends the list and still scrolls the page; a wheel
    /// over the list belongs to the list.
    func testRegressionScrollingThePageClosesTheList() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 0)
        try fixture.open("Setting 01")
        let session = try XCTUnwrap(DotSelectListController.shared.session)
        let wheel = try XCTUnwrap(Self.wheel())
        XCTAssertEqual(wheel.windowNumber, 0, "a wheel that names no window is the page's")

        XCTAssertNotNil(session.handleScroll(wheel), "the page must still receive the wheel")
        fixture.settle(0.05)

        XCTAssertFalse(DotSelectListController.shared.isShowing)
        XCTAssertEqual(fixture.visiblePanelCount, 0)
        XCTAssertEqual(fixture.childCount, 0)
    }

    func testRegressionScrollingTheListDoesNotCloseIt() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 0)
        try fixture.open("Setting 01")
        let session = try XCTUnwrap(DotSelectListController.shared.session)
        let panel = try XCTUnwrap(DotSelectListController.shared.panel)

        XCTAssertFalse(
            session.shouldCloseForScroll(windowNumber: panel.windowNumber),
            "a wheel over the list belongs to the list"
        )
        XCTAssertFalse(DotSelectListController.shared.isShowing == false)
        fixture.settle(0.05)

        XCTAssertTrue(DotSelectListController.shared.isShowing)
        XCTAssertEqual(fixture.childCount, 1)
    }

    func testRegressionRemovingTheTriggerClosesTheList() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")

        model?.rows.removeAll { $0.id == "Setting 01" }
        fixture.settle(0.15)

        XCTAssertFalse(DotSelectListController.shared.isShowing)
        XCTAssertEqual(fixture.childCount, 0)
        XCTAssertNil(DotSelectListController.shared.session, "the monitors outlived the trigger")
    }

    /// A window that went to the Dock closes its list, and so does one that
    /// moved to another display.
    func testRegressionMinimisingOrMovingToAnotherScreenClosesTheList() throws {
        let fixture = try makeFixture()
        try fixture.open("Setting 01")
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: fixture.window)
        fixture.settle(0.1)
        XCTAssertFalse(DotSelectListController.shared.isShowing, "the list survived the Dock")

        try fixture.open("Setting 02")
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: fixture.window)
        fixture.settle(0.1)
        XCTAssertFalse(DotSelectListController.shared.isShowing, "the list stayed on the old display")
        XCTAssertEqual(fixture.childCount, 0)
    }

    // MARK: - Nothing left behind

    func testRegressionClosingTheListRemovesItsWindowAndItsMonitors() throws {
        let fixture = try makeFixture()
        _ = installCountingMonitors()
        try fixture.open("Setting 01")
        XCTAssertEqual(fixture.childCount, 1)

        let session = try XCTUnwrap(DotSelectListController.shared.session)
        DotSelectListController.shared.close()

        XCTAssertEqual(session.monitorsAdded, session.monitorsRemoved)
        XCTAssertNil(DotSelectListController.shared.session)
        XCTAssertEqual(fixture.childCount, 0, "the panel is still a child of the window")
        XCTAssertEqual(fixture.visiblePanelCount, 0, "a list is still on the screen")
        XCTAssertLessThanOrEqual(fixture.panelCount, 1, "the open made another window")
    }

    /// A list opened and dismissed twice in a row installs the same monitors it
    /// removes, and leaves no list on the screen.
    func testTwoQuickOpenAndCloseCyclesLeakNothing() throws {
        let fixture = try makeFixture()
        let counting = installCountingMonitors()

        for _ in 0..<2 {
            try fixture.open("Setting 01")
            DotSelectListController.shared.close()
        }
        fixture.settle(0.1)

        XCTAssertEqual(counting.added, counting.removed)
        XCTAssertEqual(counting.added, 2 * DotSelectSession.watchCount, "two sessions' worth")
        XCTAssertEqual(fixture.visiblePanelCount, 0)
        XCTAssertEqual(fixture.childCount, 0)
    }

    /// Every open used to build a window of its own, and a window that is only
    /// ordered out stays in the app's window list: five opens left five.
    func testRegressionOpeningAListDoesNotAccumulateWindows() throws {
        let fixture = try makeFixture()

        for _ in 0..<5 {
            try fixture.open("Setting 01")
            DotSelectListController.shared.close()
        }
        fixture.settle(0.1)

        XCTAssertLessThanOrEqual(
            fixture.panelCount,
            1,
            "each open left its own window in the app's window list"
        )
        XCTAssertEqual(fixture.visiblePanelCount, 0)
        XCTAssertEqual(fixture.childCount, 0)
    }

    // MARK: - A long list

    func testTheSelectedRowIsScrolledIntoView() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 24)
        try fixture.open("Setting 01")
        fixture.settle(0.2)

        let scroll = try XCTUnwrap(fixture.listScrollView)
        let offset = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(offset, 0, "a list of thirty rows opened at its first row")

        let row = DotSelectPlacement.rowHeight(detail: nil)
        let centre = CGFloat(24) * row + row / 2 + DotSelectPlacement.inset
        XCTAssertEqual(
            offset + scroll.contentView.bounds.height / 2,
            centre,
            accuracy: row,
            "the selected row is not the one in the middle of the list"
        )
    }

    func testTheArrowKeysMoveTheHighlightAndTheListWithIt() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 0)
        try fixture.open("Setting 01")
        let session = try XCTUnwrap(DotSelectListController.shared.session)
        let scroll = try XCTUnwrap(fixture.listScrollView)

        for _ in 0..<14 {
            XCTAssertNil(session.handleKey(Self.key(code: 125, characters: "\u{F701}")))
        }
        fixture.settle(0.2)

        XCTAssertEqual(session.keyboard.highlight, 14)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "the highlight went off the list")
    }

    func testTypingLettersFindsARowByItsFirstLetter() throws {
        let names = ["Ava", "Chelsea", "Daniel", "George", "Rachel", "Sofia", "Tom"]
        let fixture = try makeFixture(rows: 3, options: names.count, titles: names, selected: 0)
        try fixture.open("Setting 01")
        let session = try XCTUnwrap(DotSelectListController.shared.session)

        XCTAssertNil(session.handleKey(Self.key(code: 15, characters: "r", timestamp: 0)))
        XCTAssertEqual(session.keyboard.highlight, 4, "typing r did not find Rachel")
        XCTAssertNil(session.handleKey(Self.key(code: 2, characters: "d", timestamp: 0.2)))
        XCTAssertEqual(session.keyboard.highlight, 4, "rd matches no row and leaves the highlight")
        XCTAssertNil(session.handleKey(Self.key(code: 2, characters: "d", timestamp: 2)))
        XCTAssertEqual(session.keyboard.highlight, 2, "a new search for d did not find Daniel")
    }

    func testReturnCommitsTheHighlightedRowAndClosesTheList() throws {
        let fixture = try makeFixture(rows: 3, options: 4, selected: 0)
        try fixture.open("Setting 01")
        let session = try XCTUnwrap(DotSelectListController.shared.session)
        _ = session.handleKey(Self.key(code: 125, characters: "\u{F701}"))

        XCTAssertNil(session.handleKey(Self.key(code: 36, characters: "\r")))
        fixture.waitUntilClosed()

        XCTAssertEqual(model?.selection["Setting 01"], "Choice 1")
        XCTAssertFalse(DotSelectListController.shared.isShowing, "the list was never released")
        XCTAssertEqual(fixture.visiblePanelCount, 0)
    }

    // MARK: - Width

    func testATriggerNarrowerThanItsRowsGrowsTheListToTheCap() throws {
        let fixture = try makeFixture(rows: 2, options: 2, narrowOptions: true)
        let trigger = try XCTUnwrap(fixture.trigger("Setting 01"))
        let anchor = fixture.screenFrame(of: trigger)

        try fixture.open("Setting 01")

        let card = try XCTUnwrap(fixture.cardFrame())
        XCTAssertEqual(anchor.width, 120, "this case needs a narrow trigger")
        XCTAssertEqual(card.width, DotSelectPlacement.maxWidth, "the list stopped at the cap")
        XCTAssertEqual(DotSelectPlacement.maxWidth, 360)
        XCTAssertEqual(card.minX, anchor.minX, "a wider card still starts at its trigger")
    }


    // MARK: - The list's own scrolling

    /// A window at the top of a long list shows the fade at the bottom only;
    /// scrolled to the middle it shows both; at the end, the top one only.
    func testTheScrollFadesFollowWhatIsBeyondEachEdge() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 0)
        try fixture.open("Setting 01")
        let scroll = try XCTUnwrap(DotSelectListController.shared.model?.scroll)
        XCTAssertFalse(scroll.showsTopFade, "the list opens at its first row")
        XCTAssertTrue(scroll.showsBottomFade)

        fixture.scrollList(to: 200)
        XCTAssertTrue(scroll.showsTopFade)
        XCTAssertTrue(scroll.showsBottomFade)

        fixture.scrollList(to: 10_000)
        XCTAssertTrue(scroll.showsTopFade)
        XCTAssertFalse(scroll.showsBottomFade, "the last row is at the bottom of the list")
    }

    /// The bar at the trailing edge is there while the list moves and gone once
    /// it rests; a list that fits has none at all.
    func testTheScrollerAppearsOnlyWhileTheListMoves() throws {
        let short = try makeFixture(rows: 3, options: 3, selected: 0)
        try short.open("Setting 01")
        XCTAssertNil(DotSelectListController.shared.model?.scroll.thumb, "a list that fits scrolls nothing")
        short.settle(0.8)
        XCTAssertFalse(DotSelectListController.shared.model?.scroll.isScrolling ?? true)

        let long = try makeFixture(rows: 3, options: 30, selected: 0)
        try long.open("Setting 01")
        long.scrollList(to: 300)
        XCTAssertTrue(DotSelectListController.shared.model?.scroll.isScrolling ?? false)
        XCTAssertNotNil(DotSelectListController.shared.model?.scroll.thumb)
        long.settle(0.9)
        XCTAssertFalse(DotSelectListController.shared.model?.scroll.isScrolling ?? true, "the bar stays")
    }

    /// Closing drops the scroll model the card was drawn from, whatever it had
    /// measured and not yet published: a list that is gone must not wake SwiftUI
    /// for a card that no longer exists, and the countdown that takes the
    /// scroller away must not outlive it either.
    func testClosingTheListStopsTheScrollModelItWasDrawnFrom() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 0)
        try fixture.open("Setting 01")
        let scroll = try XCTUnwrap(DotSelectListController.shared.model?.scroll)
        let view = try XCTUnwrap(fixture.listScrollView)
        view.contentView.scroll(to: NSPoint(x: 0, y: 120))
        view.reflectScrolledClipView(view.contentView)
        XCTAssertTrue(scroll.isScrolling, "this case needs a list that has just moved")

        var published = 0
        let watch = scroll.objectWillChange.sink { _ in
            MainActor.assumeIsolated { published += 1 }
        }
        defer { watch.cancel() }

        DotSelectListController.shared.close()
        XCTAssertFalse(scroll.isScrolling, "a list that is closed is not moving")

        fixture.settle(0.9)
        XCTAssertEqual(published, 0, "a closed card wakes nothing")
        XCTAssertFalse(scroll.isScrolling, "the countdown left with the close")
    }

    /// The selected row is centred on open without an animation, and the ends of
    /// the list are never behind a fade.
    ///
    /// A list asked for its first or last row stops inside the card's own
    /// padding, which is the nearest it can come to the edge. The first row is
    /// measured by its offset, which can only be at the top. The last row is
    /// measured by its frame: `NSScrollView`'s bounds can land a fraction of a
    /// point past the document's arithmetic bottom, so comparing offsets with a
    /// derived maximum turns a rounding difference into a failure. The row's
    /// frame against the visible rect is the claim itself — the last row is
    /// wholly above the fade, inside the card's padding.
    func testTheSelectedRowIsShownAwayFromTheFadesOnOpen() throws {
        let first = try makeFixture(rows: 3, options: 30, selected: 0)
        try first.open("Setting 01")
        first.settle(0.2)
        XCTAssertLessThanOrEqual(
            first.listOffset,
            DotSelectPlacement.inset,
            "the first row opened behind a fade"
        )

        let last = try makeFixture(rows: 3, options: 30, selected: 29)
        try last.open("Setting 01")
        last.settle(0.2)
        let scroll = try XCTUnwrap(last.listScrollView)
        let visible = scroll.contentView.bounds
        let rowHeight = DotSelectPlacement.rowHeight(detail: nil)
        let lastRow = CGRect(
            x: 0,
            y: DotSelectPlacement.inset + 29 * rowHeight,
            width: visible.width,
            height: rowHeight
        )
        XCTAssertGreaterThanOrEqual(
            lastRow.minY,
            visible.minY,
            "the last row opened above the top of the list"
        )
        XCTAssertLessThanOrEqual(
            lastRow.maxY,
            visible.maxY,
            "the last row opened behind the bottom fade: row \(lastRow) in \(visible)"
        )
        XCTAssertFalse(DotSelectListController.shared.model?.scroll.showsBottomFade ?? true)
    }

    /// The last row opens at the foot of the list: the document's end less the
    /// viewport is the offset the card places, so the row is wholly inside the
    /// card and only the card's own inset is below it.
    func testTheLastRowOpensAtTheFootOfTheList() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 29)
        try fixture.open("Setting 01")
        fixture.settle(0.3)
        let scroll = try XCTUnwrap(fixture.listScrollView)
        let content = try XCTUnwrap(scroll.documentView).frame.height
        let viewport = scroll.contentView.bounds.height

        XCTAssertEqual(
            fixture.listOffset,
            content - viewport,
            accuracy: 0.5,
            "the list stopped \(content - viewport - fixture.listOffset) points short of its foot"
        )
        XCTAssertFalse(
            DotSelectListController.shared.model?.scroll.showsBottomFade ?? true,
            "the last row opened behind the bottom fade"
        )
    }

    /// The first row opens flush with the top: the list is at zero, not at the
    /// card's inset.
    func testTheFirstRowOpensFlushWithTheTopOfTheList() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 0)
        try fixture.open("Setting 01")
        fixture.settle(0.3)

        XCTAssertEqual(fixture.listOffset, 0, accuracy: 0.5, "the list opened under its own inset")
        XCTAssertFalse(
            DotSelectListController.shared.model?.scroll.showsTopFade ?? true,
            "the first row opened behind the top fade"
        )
    }

    /// The list is drawn at the row it opens on: the offset is placed before the
    /// card's first frame, and the opening animation does not move it.
    ///
    /// The offsets are worked out here from the row heights and the card, not
    /// read back from the code under test. Fifteen rows without details travel
    /// 118 points; eight rows that all carry a detail travel 18, which is the
    /// speech provider list in the app.
    func testTheListOpensAlreadyShowingTheSelectedRow() throws {
        let cases: [(name: String, rows: Int, detail: Bool, selected: Int, travel: CGFloat)] = [
            ("first of fifteen", 15, false, 0, 118),
            ("middle of fifteen", 15, false, 7, 118),
            ("last of fifteen", 15, false, 14, 118),
            ("first of eight with details", 8, true, 0, 18),
            ("middle of eight with details", 8, true, 4, 18),
            ("last of eight with details", 8, true, 7, 18),
        ]
        for item in cases {
            let fixture = try makeFixture(
                rows: 3,
                options: item.rows,
                selected: item.selected,
                detail: item.detail
            )
            let scroll = try openAndRead(fixture, "Setting 01")
            let viewport = scroll.contentView.bounds.height
            let content = try XCTUnwrap(scroll.documentView).frame.height
            XCTAssertEqual(
                content - viewport,
                item.travel,
                accuracy: 0.5,
                "\(item.name): this case needs the travel the brief names"
            )
            let expected = Self.openingOffset(
                rows: item.rows,
                detail: item.detail,
                selected: item.selected,
                viewport: viewport
            )
            for (index, reading) in offsetReadings(scroll, in: fixture).enumerated() {
                XCTAssertEqual(
                    reading,
                    expected,
                    accuracy: 0.5,
                    "\(item.name): reading \(index) is \(reading), not the \(expected) the row needs"
                )
            }
        }
    }

    /// A reused panel does not open where the last list left it: a list scrolled
    /// to its foot is closed, and the next open on its first row is at the top.
    func testAReopenedListLosesTheOffsetTheLastOneWasLeftAt() throws {
        let fixture = try makeFixture(rows: 3, options: 15, selected: 0)
        _ = try openAndRead(fixture, "Setting 01")
        fixture.scrollList(to: 10_000)
        XCTAssertGreaterThan(fixture.listOffset, 100, "this case needs a list at its foot")

        DotSelectListController.shared.close()
        fixture.settle(0.05)
        XCTAssertFalse(DotSelectListController.shared.isShowing, "the list did not close")

        let reopened = try openAndRead(fixture, "Setting 01")
        XCTAssertEqual(
            reopened.contentView.bounds.origin.y,
            0,
            accuracy: 0.5,
            "the list opened where the last one was left"
        )
    }

    /// The row a list opens on is inside the card and clear of both fades in the
    /// frame the card is first drawn in.
    func testTheSelectedRowIsClearOfTheFadesOnTheFirstFrame() throws {
        let fixture = try makeFixture(rows: 3, options: 15, selected: 7)
        let scroll = try openAndRead(fixture, "Setting 01")
        let visible = scroll.contentView.bounds
        let height = DotSelectPlacement.rowHeight(detail: nil)
        let row = CGRect(
            x: 0,
            y: DotSelectPlacement.inset + 7 * height,
            width: visible.width,
            height: height
        )
        let above = row.minY - visible.minY
        let below = visible.maxY - row.maxY

        XCTAssertGreaterThanOrEqual(above, DotSelectListMetrics.fade, "the row opened behind the top fade")
        XCTAssertGreaterThanOrEqual(below, DotSelectListMetrics.fade, "the row opened behind the bottom fade")
        XCTAssertGreaterThanOrEqual(above, 12, "the row opened inside the top fade band")
        XCTAssertGreaterThanOrEqual(below, 12, "the row opened inside the bottom fade band")
    }

    /// A click while the card is still growing lands on the row drawn under the
    /// pointer.
    ///
    /// The card is drawn at 0.97 of its size at the first frame, so a row's drawn
    /// edges are up to nine points above the frames SwiftUI hit-tests. A press two
    /// points inside the drawn edge of row 12 must choose row 12, and two points
    /// inside the drawn bottom edge of row 11 must choose row 11, at the first
    /// frame and at the fifth of a second the growth is a third of the way
    /// through. A list opening above its trigger grows from its bottom edge, so
    /// the same check is made on row 4, whose edge is far from that fixed edge.
    /// The growth's clock is stopped before each press, so the press is made
    /// against the frame it is measured on.
    func testAClickDuringTheOpenLandsOnTheRowItIsDrawnOver() throws {
        let cases: [(above: Bool, time: TimeInterval, row: Int, edge: String, expected: String)] = [
            (false, 0.00, 12, "top", "Voice 12"),
            (false, 0.00, 11, "bottom", "Voice 11"),
            (false, 0.05, 12, "top", "Voice 12"),
            (false, 0.05, 11, "bottom", "Voice 11"),
            (true, 0.00, 4, "top", "Rachel"),
            (true, 0.00, 4, "bottom", "Rachel"),
            (true, 0.05, 4, "top", "Rachel"),
            (true, 0.05, 4, "bottom", "Rachel"),
        ]
        for item in cases {
            let fixture = try makeFixture(rows: 3, options: 15, selected: 7, atScreenBottom: item.above)
            let scroll = try openAndRead(fixture, "Setting 01")
            let panel = try XCTUnwrap(DotSelectListController.shared.panel)
            let layer = try XCTUnwrap(panel.contentView?.layer, "the card has no layer")
            // The growth is a real animation. Its clock is stopped at once, before
            // the run loop can finish it, and its own time is set to the frame the
            // case names: waiting for a tick would sample whatever the machine's
            // load allowed, and a slow one lands after the growth has ended.
            layer.speed = 0
            CATransaction.flush()
            let growth = try XCTUnwrap(
                layer.animation(forKey: "openingScale") as? CABasicAnimation,
                "the card is not growing"
            )
            // The animation is re-added with a known start so the stopped clock
            // can be put on the frame the case names, whatever begin time Core
            // Animation filled in. The copy the layer hands out is immutable.
            let frozen = try XCTUnwrap(
                growth.mutableCopy() as? CABasicAnimation,
                "the growth could not be copied"
            )
            frozen.beginTime = 0
            layer.removeAnimation(forKey: "openingScale")
            layer.timeOffset = item.time
            layer.add(frozen, forKey: "openingScale")
            CATransaction.flush()
            defer {
                layer.speed = 1
                layer.timeOffset = 0
            }
            let frame: ClosedRange<CGFloat> = item.time > 0 ? 0.980...0.995 : 0.960...0.975

            let scale = try XCTUnwrap(
                layer.presentation()?.sublayerTransform.m11,
                "the card is not presenting a transform"
            )
            XCTAssertTrue(frame.contains(scale), "the growth was stopped at \(scale), not in \(frame)")
            let origin = try XCTUnwrap(panel.growthOrigin, "the open recorded no growth")
            let contentHeight = try XCTUnwrap(panel.contentView).bounds.height
            // The edge the growth leaves still is the card's top when it hangs
            // below its trigger and its bottom when it opens above it.
            XCTAssertEqual(
                origin.y,
                item.above ? contentHeight : 0,
                accuracy: 0.5,
                "the card did not grow from the edge it hangs from"
            )
            let rowHeight = DotSelectPlacement.rowHeight(detail: nil)
            // The edge the two cases share is the top of row 12, which is also
            // the bottom of row 11.
            let boundary = item.edge == "top" ? item.row : item.row + 1
            let edge = panel.shadowInset
                + DotSelectPlacement.inset
                + CGFloat(boundary) * rowHeight
                - scroll.contentView.bounds.origin.y
            let drawn = origin.y + (edge - origin.y) * scale
            let top = item.edge == "top" ? drawn + 2 : drawn - 2
            try click(panel, atTop: CGPoint(x: 60, y: top))

            fixture.settle(0.12)
            let chosen = model?.selection["Setting 01"]
            print(String(
                format: "SELECTCLICK %@ row %d %@ t%.2f scale %.4f drawnEdge %.1f press %.1f chose %@",
                item.above ? "above" : "below",
                item.row,
                item.edge,
                item.time,
                scale,
                drawn,
                top,
                chosen ?? "nothing"
            ))
            XCTAssertEqual(
                chosen,
                item.expected,
                "at \(item.time) s, \(item.above ? "above" : "below"): a press 2 pt inside the drawn \(item.edge) edge of row \(item.row)"
            )
            DotSelectListController.shared.close()
        }
    }

    /// A list whose card was never built has nothing to place against: it says so
    /// once and opens at the top.
    func testAListStillMissingAfterATurnIsReportedOnce() throws {
        _ = NSApplication.shared
        OffscreenScreen.install()
        var lines: [String] = []
        let previous = DotSelectLog.write
        DotSelectLog.write = { lines.append($0) }
        DotSelectLog.reportedMissingList = false
        defer {
            DotSelectLog.write = previous
            DotSelectLog.reportedMissingList = false
            OffscreenScreen.restore()
        }

        // A card whose content was never built: an empty container, so the open
        // has no scroll view to place against, now or on the next turn.
        let hosting = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 310))
        let model = DotSelectListModel(highlight: 3)
        let heights = Array(repeating: DotSelectPlacement.rowHeight, count: 15)

        for _ in 0..<2 {
            DotSelectPanel.placeOpeningWhenBuilt(
                in: hosting,
                scroll: model.scroll,
                rowHeights: heights,
                selected: 3
            )
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(DotSelectLog.missingList, "select.open.noscroll")
        XCTAssertEqual(lines, [DotSelectLog.missingList], "the missing list was reported \(lines.count) times")
        XCTAssertEqual(model.scroll.offset, 0, "a list with no scroll view was given an offset")
    }

    /// A card that arrives a turn after the open is placed when it arrives, and is
    /// not reported as missing.
    func testACardThatArrivesOnTheNextTurnIsPlaced() throws {
        var lines: [String] = []
        let previous = DotSelectLog.write
        DotSelectLog.write = { lines.append($0) }
        DotSelectLog.reportedMissingList = false
        defer {
            DotSelectLog.write = previous
            DotSelectLog.reportedMissingList = false
        }

        let hosting = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 310))
        let model = DotSelectListModel(highlight: 7)
        let heights = Array(repeating: DotSelectPlacement.rowHeight, count: 15)
        DotSelectPanel.placeOpeningWhenBuilt(
            in: hosting,
            scroll: model.scroll,
            rowHeights: heights,
            selected: 7
        )
        // The card arrives after the first look, before the retry.
        let scroll = Self.makeListScroll(content: 428, viewport: 310)
        hosting.addSubview(scroll)

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, model.scroll.offset == 0 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertTrue(lines.isEmpty, "a card that arrived was reported missing")
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y,
            59,
            accuracy: 0.5,
            "the list was not placed when its card arrived"
        )
        XCTAssertEqual(model.scroll.offset, 59, accuracy: 0.5)
    }

    /// A retry left by an open the controller has replaced must not move the
    /// list that replaced it.
    ///
    /// The old open's first look finds no scroll view and leaves a retry; before
    /// that turn the panel is re-presented, the new list is measured and placed
    /// at its own row, and the old retry must be dropped by the open's identity
    /// rather than scrolling the new list to the old row.
    func testASupersededRetryDoesNotMoveTheNextList() throws {
        let hosting = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 310))
        let first = DotSelectListModel(highlight: 10)
        let second = DotSelectListModel(highlight: 7)
        let heights = Array(repeating: DotSelectPlacement.rowHeight, count: 15)
        var open = 1
        var checks = 0

        DotSelectPanel.placeOpeningWhenBuilt(
            in: hosting,
            scroll: first.scroll,
            rowHeights: heights,
            selected: 10,
            isCurrent: {
                checks += 1
                return open == 1
            }
        )
        // The second open replaces the first before the retry turn. Its card is
        // built and placed at its own row, 59 for row 7 of this list; the first
        // open's row 10 would place it at 118.
        open = 2
        let scroll = Self.makeListScroll(content: 428, viewport: 310)
        hosting.addSubview(scroll)
        DotSelectPanel.placeOpening(in: hosting, scroll: second.scroll, rowHeights: heights, selected: 7)

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, checks == 0 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(checks, 1, "the retry did not run")
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y,
            59,
            accuracy: 0.5,
            "the superseded retry moved the new list to the old row"
        )
        XCTAssertEqual(second.scroll.offset, 59, accuracy: 0.5)
    }

    /// A list whose card never arrived, closed before the retry turn, leaves
    /// nothing behind: the close is a newer generation, so the retry neither
    /// reports the missing card nor touches the list it left.
    func testAClosedOpenDropsItsRetry() throws {
        var lines: [String] = []
        let previous = DotSelectLog.write
        DotSelectLog.write = { lines.append($0) }
        DotSelectLog.reportedMissingList = false
        defer {
            DotSelectLog.write = previous
            DotSelectLog.reportedMissingList = false
        }

        let fixture = try makeFixture(rows: 3, options: 15, selected: 7)
        DotSelectPanel.skipsFirstPlacement = true
        DotSelectPanel.retriesPastTheCheck = 0
        defer {
            DotSelectPanel.skipsFirstPlacement = false
            DotSelectPanel.retriesPastTheCheck = 0
        }
        let scroll = try openAndRead(fixture, "Setting 01")
        let model = try XCTUnwrap(DotSelectListController.shared.model)
        let before = scroll.contentView.bounds.origin.y
        DotSelectListController.shared.close()

        // Turn the run loop so the retry would run if the close had not dropped it.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, lines.isEmpty {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertTrue(lines.isEmpty, "a closed open reported its missing card: \(lines)")
        XCTAssertEqual(
            DotSelectPanel.retriesPastTheCheck,
            0,
            "the closed open's retry got past the generation check"
        )
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y,
            before,
            "a closed open moved the list it left"
        )
        XCTAssertEqual(model.scroll.offset, 0, "a closed open wrote an offset to the list it left")
    }

    /// A card that is closed while it is still growing, and opened again at once, is
    /// not drawn through the growth it left behind.
    ///
    /// The reopen is checked with Reduce Motion on, where no growth is started, and
    /// off, where the new growth starts from its first frame. Either way a press at
    /// the centre of row 12 must choose row 12.
    func testAReopenedListDoesNotInheritTheLastGrowth() throws {
        for reduceMotion in [false, true] {
            let fixture = try makeFixture(rows: 3, options: 15, selected: 7)
            _ = try openAndRead(fixture, "Setting 01")
            fixture.settle(0.05)
            DotSelectListController.shared.close()

            DotMotion.reducesMotionOverride = reduceMotion
            defer { DotMotion.reducesMotionOverride = nil }
            let scroll = try openAndRead(fixture, "Setting 01")
            let panel = try XCTUnwrap(DotSelectListController.shared.panel)
            let layer = try XCTUnwrap(panel.contentView?.layer, "the card has no layer")
            CATransaction.flush()
            let presented = (layer.presentation() ?? layer).sublayerTransform
            if reduceMotion {
                XCTAssertTrue(
                    CATransform3DIsIdentity(presented),
                    "the reopened card is drawn through the growth it left behind (\(presented.m11))"
                )
                XCTAssertNil(layer.animation(forKey: "openingScale"), "the last growth is still on the layer")
                XCTAssertNil(panel.growthOrigin, "a growth that was never started recorded an origin")
            } else {
                XCTAssertNotNil(panel.growthOrigin, "the reopened card did not grow")
                XCTAssertLessThan(
                    presented.m11,
                    1,
                    "the reopened card did not start its growth from its first frame"
                )
            }

            let rowHeight = DotSelectPlacement.rowHeight(detail: nil)
            let centre = panel.shadowInset
                + DotSelectPlacement.inset
                + 12 * rowHeight
                + rowHeight / 2
                - scroll.contentView.bounds.origin.y
            try click(panel, atTop: drawn(CGPoint(x: 60, y: centre), in: panel))
            fixture.settle(0.12)
            XCTAssertEqual(
                model?.selection["Setting 01"],
                "Voice 12",
                "reduce motion \(reduceMotion): the press did not land on the row it was made over"
            )
            DotSelectListController.shared.close()
        }
    }

    /// A pointer resting over a row is read once: when the growth ends, or at
    /// the open itself under Reduce Motion, where there is no growth to wait for.
    /// A hover that arrives during the growth moves nothing.
    func testHoverIsReadOnceWhenTheGrowthEnds() throws {
        // The pointer rests over row 9 and does not move again. The point is
        // worked out from the list the panel is drawing at the moment of the
        // read, because under Reduce Motion the read happens inside the open,
        // before the test can hold the panel.
        let previous = DotSelectPanel.pointerLocation
        DotSelectPanel.pointerLocation = {
            guard let panel = DotSelectListController.shared.panel,
                  let content = panel.contentView,
                  let scroll = DotSelectListController.shared.model?.scroll.reporter?.listScrollView
            else { return .zero }
            let rowHeight = DotSelectPlacement.rowHeight(detail: nil)
            let centre = panel.shadowInset
                + DotSelectPlacement.inset
                + 9 * rowHeight
                + rowHeight / 2
                - scroll.contentView.bounds.origin.y
            return panel.convertPoint(toScreen: NSPoint(x: 60, y: content.bounds.height - centre))
        }
        defer { DotSelectPanel.pointerLocation = previous }

        for reduceMotion in [false, true] {
            DotMotion.reducesMotionOverride = reduceMotion
            defer { DotMotion.reducesMotionOverride = nil }
            let fixture = try makeFixture(rows: 3, options: 15, selected: 0)
            _ = try openAndRead(fixture, "Setting 01")
            let session = try XCTUnwrap(DotSelectListController.shared.session)
            let model = try XCTUnwrap(DotSelectListController.shared.model)

            if reduceMotion {
                XCTAssertEqual(
                    model.highlight,
                    9,
                    "Reduce Motion: the row under the pointer was not read at the open"
                )
            } else {
                XCTAssertNotEqual(model.highlight, 9, "the row under the pointer was highlighted at once")
                fixture.settle(0.05)
                session.hover(9)
                XCTAssertNotEqual(model.highlight, 9, "a hover during the growth moved the highlight")
                XCTAssertNotEqual(session.keyboard.highlight, 9, "a hover during the growth moved the keyboard")

                let deadline = Date().addingTimeInterval(0.4)
                while Date() < deadline, model.highlight != 9 {
                    fixture.settle(0.02)
                }
                XCTAssertEqual(model.highlight, 9, "the row under the pointer never highlighted")
            }
            DotSelectListController.shared.close()
        }
    }

    /// A key that reaches an end stops there, and the wheel owns the list again
    /// afterwards: the end is a placement, not a position the list is pinned to.
    func testTheKeysStopAtTheEndsAndTheWheelMovesFreelyAfterwards() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 0)
        try fixture.open("Setting 01")
        fixture.settle(0.2)
        let session = try XCTUnwrap(DotSelectListController.shared.session)
        let scroll = try XCTUnwrap(fixture.listScrollView)
        let foot = try XCTUnwrap(scroll.documentView).frame.height - scroll.contentView.bounds.height

        for _ in 0..<29 {
            XCTAssertNil(session.handleKey(Self.key(code: 125, characters: "\u{F701}")))
        }
        fixture.settle(0.2)
        XCTAssertEqual(session.keyboard.highlight, 29)
        XCTAssertEqual(
            fixture.listOffset,
            foot,
            accuracy: 0.5,
            "the last row is not at the foot of the list"
        )

        fixture.scrollList(to: foot - 84)
        fixture.settle(0.3)
        XCTAssertEqual(
            fixture.listOffset,
            foot - 84,
            accuracy: 0.5,
            "the list was pulled back to the end a key asked for"
        )

        for _ in 0..<29 {
            XCTAssertNil(session.handleKey(Self.key(code: 126, characters: "\u{F700}")))
        }
        fixture.settle(0.2)
        XCTAssertEqual(session.keyboard.highlight, 0)
        XCTAssertEqual(fixture.listOffset, 0, accuracy: 0.5, "the first row is not at the top of the list")

        fixture.scrollList(to: 120)
        fixture.settle(0.3)
        XCTAssertEqual(fixture.listOffset, 120, accuracy: 0.5, "the list was pulled back to the top")
    }

    /// A key pressed while the list is still opening moves it from the row it
    /// opened on: the list is already at the foot, and the keys take it to the
    /// row the reader asked for without anything pulling it back.
    func testAKeyPressedWhileTheListOpensMovesItFromTheRowItOpenedOn() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 29)
        let trigger = try XCTUnwrap(fixture.trigger("Setting 01"))
        XCTAssertTrue(trigger.accessibilityPerformPress())
        let scroll = try XCTUnwrap(fixture.listScrollView)
        let foot = try XCTUnwrap(scroll.documentView).frame.height - scroll.contentView.bounds.height
        XCTAssertEqual(
            scroll.contentView.bounds.origin.y,
            foot,
            accuracy: 0.5,
            "the list did not open at the row it was opened on"
        )
        let session = try XCTUnwrap(DotSelectListController.shared.session)

        for _ in 0..<11 {
            XCTAssertNil(session.handleKey(Self.key(code: 126, characters: "\u{F700}")))
        }
        fixture.settle(0.05)
        fixture.settle(0.4)

        XCTAssertEqual(session.keyboard.highlight, 18)
        XCTAssertLessThan(
            fixture.listOffset,
            foot - 100,
            "the list stayed at the foot instead of the row the reader asked for"
        )
        XCTAssertNil(DotSelectListController.shared.model?.scroll.pendingEnd)
    }

    /// A row in the middle is still centred by SwiftUI: only the ends are the
    /// card's own arithmetic.
    func testAMiddleSelectionIsStillCentred() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 15)
        try fixture.open("Setting 01")
        fixture.settle(0.3)
        let scroll = try XCTUnwrap(fixture.listScrollView)
        let row = DotSelectPlacement.rowHeight(detail: nil)
        let centre = DotSelectPlacement.inset + 15 * row + row / 2

        XCTAssertEqual(
            fixture.listOffset + scroll.contentView.bounds.height / 2,
            centre,
            accuracy: row / 2,
            "the middle row is not the one in the middle of the list"
        )
    }

    /// A list shorter than its card has nowhere to scroll: neither end moves it,
    /// and every row stays on the card.
    func testAShortListStaysStillAtBothEnds() throws {
        let fixture = try makeFixture(rows: 3, options: 3, selected: 0)
        try fixture.open("Setting 01")
        fixture.settle(0.3)
        let session = try XCTUnwrap(DotSelectListController.shared.session)
        let scroll = try XCTUnwrap(fixture.listScrollView)
        let content = try XCTUnwrap(scroll.documentView).frame.height
        let visible = scroll.contentView.bounds

        XCTAssertEqual(content, visible.height, accuracy: 0.5, "this case needs a list that fits")
        XCTAssertEqual(fixture.listOffset, 0, accuracy: 0.5)

        for _ in 0..<2 {
            XCTAssertNil(session.handleKey(Self.key(code: 125, characters: "\u{F701}")))
        }
        fixture.settle(0.3)
        XCTAssertEqual(session.keyboard.highlight, 2)
        XCTAssertEqual(fixture.listOffset, 0, accuracy: 0.5, "a list that fits was scrolled to its foot")

        let row = DotSelectPlacement.rowHeight(detail: nil)
        let lastRow = CGRect(
            x: 0,
            y: DotSelectPlacement.inset + 2 * row,
            width: visible.width,
            height: row
        )
        XCTAssertLessThanOrEqual(
            lastRow.maxY,
            visible.maxY,
            "the last row of a list that fits runs past the card"
        )
    }

    func testTheListNeverScrollsSideways() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 0, narrowOptions: true)
        try fixture.open("Setting 01")
        let scroll = try XCTUnwrap(fixture.listScrollView)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertLessThanOrEqual(
            scroll.documentView?.frame.width ?? .infinity,
            scroll.contentView.bounds.width + 0.5,
            "the rows are wider than the card"
        )
    }

    /// A row is chosen by a click, and the click is not eaten by the pressed state.
    func testAClickOnARowChoosesIt() throws {
        let fixture = try makeFixture(rows: 3, options: 4, selected: 0)
        try fixture.open("Setting 01")
        let panel = try XCTUnwrap(DotSelectListController.shared.panel)
        let card = try XCTUnwrap(fixture.cardFrame())
        // The panel has been moved off every display by now, so the point is
        // taken from the card's place inside the window, which never moved.
        let cardInPanel = CGRect(
            x: panel.shadowInset,
            y: panel.shadowInset,
            width: card.width,
            height: card.height
        )
        let row = DotSelectPlacement.rowHeight(detail: nil)
        let point = NSPoint(
            x: cardInPanel.midX,
            y: cardInPanel.maxY - DotSelectPlacement.inset - row * 2 - row / 2
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
            panel.sendEvent(event)
        }
        fixture.waitUntilClosed()

        XCTAssertEqual(model?.selection["Setting 01"], "Choice 2", "the click did not choose the row")
        XCTAssertFalse(DotSelectListController.shared.isShowing, "the list was never released")
        XCTAssertEqual(fixture.visiblePanelCount, 0, "the list stayed open after a choice")
    }

    // MARK: - VoiceOver and appearance

    func testTheTriggerReadsAsAPopUpButtonAndOpensOnPress() throws {
        let fixture = try makeFixture()
        let trigger = try XCTUnwrap(fixture.trigger("Setting 02"))

        XCTAssertEqual(trigger.accessibilityRole(), .popUpButton)
        XCTAssertEqual(trigger.accessibilityLabel(), "Setting 02")
        XCTAssertEqual(trigger.accessibilityValue() as? String, "Choice 0")
        XCTAssertTrue(trigger.isAccessibilityEnabled())

        XCTAssertTrue(trigger.accessibilityPerformPress(), "VoiceOver's press did not open the list")
        fixture.settle(0.1)
        XCTAssertTrue(DotSelectListController.shared.isShowing)
        XCTAssertFalse(DotSelectListController.shared.panel?.canBecomeKey ?? true)
    }

    func testTheListDrawsInBothAppearancesAndAtIncreasedContrast() throws {
        let card = DotSelectListCard(
            rows: [
                DotSelectRow(title: "OpenAI", detail: "Connected"),
                DotSelectRow(title: "AssemblyAI", symbol: "waveform"),
            ],
            selectedIndex: 0,
            highlight: 1,
            size: CGSize(width: 240, height: 78),
            onHighlight: { _ in },
            onChoose: { _ in }
        )
        let appearances: [NSAppearance.Name] = [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]
        var luminance: [CGFloat] = []
        for name in appearances {
            let rep = try XCTUnwrap(
                Self.render(AnyView(card), appearance: NSAppearance(named: name)),
                "\(name.rawValue) did not draw"
            )
            XCTAssertGreaterThan(Self.inkShare(rep), 0.02, "\(name.rawValue) drew an empty card")
            luminance.append(Self.meanLuminance(rep))
        }
        XCTAssertGreaterThan(luminance[0], luminance[3] + 0.2, "dark and light draw the same card")
        XCTAssertGreaterThan(luminance[2], luminance[3] + 0.2, "increased contrast ignores dark mode")
    }

    // MARK: - Helpers

    /// Swaps in a factory whose monitors are real but counted, so a test can
    /// prove a session installed nothing it did not remove.
    @discardableResult
    private func installCountingMonitors() -> CountingMonitors {
        if Self.originalSessionFactory == nil {
            Self.originalSessionFactory = DotSelectListController.shared.makeSession
        }
        monitors.reset()
        let monitors = self.monitors
        DotSelectListController.shared.makeSession = { titles, selected, number in
            DotSelectSession(
                titles: titles,
                selected: selected,
                registrar: monitors.registrar,
                observers: monitors.observers,
                panelNumber: number
            )
        }
        return monitors
    }

    private func visibleFrame() -> NSRect {
        OffscreenScreen.frame
    }

    /// The point the card draws a point of its own geometry at.
    ///
    /// At rest there is no growth and the point is unchanged.
    private func drawn(_ point: CGPoint, in panel: DotSelectPanel) -> CGPoint {
        guard let origin = panel.growthOrigin else { return point }
        let scale = panel.contentView?.layer
            .flatMap { ($0.presentation() ?? $0).sublayerTransform.m11 } ?? 1
        return CGPoint(
            x: origin.x + (point.x - origin.x) * scale,
            y: origin.y + (point.y - origin.y) * scale
        )
    }

    /// A scroll view shaped like the list's: a flipped document of its own height
    /// inside a viewport.
    private static func makeListScroll(content: CGFloat, viewport: CGFloat) -> NSScrollView {
        let window = OffscreenWindow(size: CGSize(width: 240, height: viewport), styleMask: [.borderless])
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: viewport))
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        window.contentView = scroll
        scroll.documentView = FlippedListDocument(
            frame: NSRect(x: 0, y: 0, width: 240, height: content)
        )
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        Self.openWindows.append(window)
        return scroll
    }

    /// Sends a click at a point counted from the top left of the panel's content,
    /// which is the way the drawing is measured.
    private func click(_ panel: DotSelectPanel, atTop point: CGPoint) throws {
        let content = try XCTUnwrap(panel.contentView)
        let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
            panel.sendEvent(event)
        }
    }

    /// Opens a trigger and hands back the list as it was drawn, before the run
    /// loop turns: the frame a person sees the moment the card appears.
    private func openAndRead(
        _ fixture: SelectWindowFixture,
        _ label: String
    ) throws -> NSScrollView {
        let trigger = try XCTUnwrap(fixture.trigger(label))
        XCTAssertTrue(trigger.accessibilityPerformPress(), "\(label) did not open")
        let panel = try XCTUnwrap(DotSelectListController.shared.panel)
        // The list is never drawn on a display the Mac owns.
        panel.setFrameOrigin(OffscreenWindow.origin)
        // The list the panel is drawing now. After a second open the panel's
        // tree still holds the scroll view the last one drew, so the list is
        // named by the scroll model rather than found by a search.
        let content = try XCTUnwrap(panel.contentView)
        return try XCTUnwrap(
            DotSelectListController.shared.model?.scroll.reporter?.listScrollView
                ?? SelectWindowFixture.scrollView(in: content),
            "the list did not exist when the open returned"
        )
    }

    /// The list's offset as it was drawn, then after bounded waits at 0.05, 0.14
    /// and 0.30 seconds from the open.
    private func offsetReadings(
        _ scroll: NSScrollView,
        in fixture: SelectWindowFixture
    ) -> [CGFloat] {
        var readings = [scroll.contentView.bounds.origin.y]
        var waited: TimeInterval = 0
        for moment in [0.05, 0.14, 0.30] {
            fixture.settle(moment - waited)
            waited = moment
            readings.append(scroll.contentView.bounds.origin.y)
        }
        return readings
    }

    /// The offset a list opens on, worked out from the row heights and the card:
    /// the row's own top edge less half the viewport, held inside the two ends.
    private static func openingOffset(
        rows: Int,
        detail: Bool,
        selected: Int,
        viewport: CGFloat
    ) -> CGFloat {
        let height = DotSelectPlacement.rowHeight(detail: detail ? "Requires API key" : nil)
        let content = CGFloat(rows) * height + 2 * DotSelectPlacement.inset
        let limit = max(0, content - viewport)
        let top = CGFloat(selected) * height + DotSelectPlacement.inset
        return min(max(top + height / 2 - viewport / 2, 0), limit)
    }

    private func makeFixture(
        rows: Int = 24,
        options: Int = 4,
        titles: [String]? = nil,
        selected: Int = 0,
        height: CGFloat = 600,
        narrowOptions: Bool = false,
        longOptions: Bool = false,
        detail: Bool = false,
        atScreenBottom: Bool = false,
        trailing: Bool = false,
        windowWidth: CGFloat = 820
    ) throws -> SelectWindowFixture {
        _ = NSApplication.shared
        closeEverythingFromTheLastTest()
        OffscreenScreen.install()
        let titles = titles ?? (options == 4
            ? ["Choice 0", "Choice 1", "Choice 2", "Choice 3"]
            : Self.titles(count: options))
        let model = SelectPageModel(
            rows: (1...rows).map { index in
                SelectPageModel.Row(
                    id: String(format: "Setting %02d", index),
                    options: narrowOptions || longOptions
                        ? [Self.longTitle, "AssemblyAI"]
                        : titles,
                    selected: selected,
                    width: narrowOptions ? 120 : nil,
                    detail: detail
                )
            }
        )
        let window = OffscreenWindow(size: CGSize(width: windowWidth, height: height), styleMask: [.titled, .resizable])
        let host = NSHostingView(
            rootView: SelectPageFixture(model: model, trailing: trailing, width: windowWidth)
        )
        host.frame = NSRect(origin: .zero, size: window.frame.size)
        window.contentView = host
        // The window sits at the corner of the display the controller is handed,
        // which is where the placement math can see a screen at all; the window
        // is on no display the Mac owns.
        window.setFrameOrigin(OffscreenWindow.origin)
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        self.window = window
        self.model = model
        Self.openWindows.append(window)
        let fixture = SelectWindowFixture(window: window, host: host, model: model)
        fixture.settle(0.05)
        // The trigger is moved to the edge it has to be tested against rather
        // than the page being built differently: the arithmetic that matters is
        // the distance from the trigger to the edge of the display.
        if let trigger = fixture.trigger("Setting 01") {
            let frame = fixture.screenFrame(of: trigger)
            let screen = OffscreenScreen.frame
            if atScreenBottom {
                fixture.moveWindow(by: CGSize(width: 0, height: screen.minY + 8 - frame.minY))
            }
            if trailing {
                fixture.moveWindow(by: CGSize(width: screen.maxX - 100 - frame.minX, height: 0))
            }
        }
        return fixture
    }

    private static func titles(count: Int) -> [String] {
        let names = ["Ava", "Chelsea", "Daniel", "George", "Rachel", "Sofia", "Tom", "Uma"]
        return (0..<count).map { index in
            index < names.count ? names[index] : "Voice \(index)"
        }
    }

    private static let longTitle =
        "Speechmatics enhanced multilingual batch transcription service"

    private static func key(
        code: UInt16,
        characters: String,
        timestamp: TimeInterval = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    private static func wheel() -> NSEvent? {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0)
            .flatMap { NSEvent(cgEvent: $0) }
    }

    private static func click(in windowNumber: Int) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    /// The card's pixels at two pixels per point.
    ///
    /// A rep AppKit makes for the cache display comes back at the display's own
    /// scale, which is one pixel per point on a display that is not Retina, so
    /// the bitmap is made here at the scale the ink share is measured on.
    private static func render(_ view: AnyView, appearance: NSAppearance?) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 78)
        host.appearance = appearance
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width) * 2,
            pixelsHigh: Int(bounds.height) * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// The share of pixels that differ from the corner pixel: a blank card has
    /// none, and a card with a border, a highlight and two lines of text has
    /// more than a couple of percent.
    private static func inkShare(_ rep: NSBitmapImageRep) -> Double {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3 else { return 0 }
        let stride = rep.bytesPerRow
        let corner = (0, 0)
        let base = luminance(data, stride, rep.samplesPerPixel, corner.0, corner.1)
        var different = 0
        var total = 0
        for y in Swift.stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in Swift.stride(from: 0, to: rep.pixelsWide, by: 2) {
                total += 1
                if abs(luminance(data, stride, rep.samplesPerPixel, x, y) - base) > 0.04 {
                    different += 1
                }
            }
        }
        return total == 0 ? 0 : Double(different) / Double(total)
    }

    private static func meanLuminance(_ rep: NSBitmapImageRep) -> CGFloat {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3 else { return 0 }
        var total: CGFloat = 0
        var count = 0
        for y in Swift.stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in Swift.stride(from: 0, to: rep.pixelsWide, by: 4) {
                total += luminance(data, rep.bytesPerRow, rep.samplesPerPixel, x, y)
                count += 1
            }
        }
        return count == 0 ? 0 : total / CGFloat(count)
    }

    private static func luminance(
        _ data: UnsafeMutablePointer<UInt8>,
        _ stride: Int,
        _ samples: Int,
        _ x: Int,
        _ y: Int
    ) -> CGFloat {
        let offset = y * stride + x * samples
        return (CGFloat(data[offset]) * 0.21
            + CGFloat(data[offset + 1]) * 0.72
            + CGFloat(data[offset + 2]) * 0.07) / 255
    }
}

/// The page the tests press: a window with a sidebar and a scrolling column of
/// real triggers, laid out the way the settings page lays them out.
struct SelectPageFixture: View {
    @ObservedObject var model: SelectPageModel
    var trailing = false
    var width: CGFloat = 820

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Settings").font(.system(size: 12, weight: .semibold))
                ForEach(0..<3, id: \.self) { page in
                    Button("Page \(page)") { model.page = page }
                }
                Spacer()
            }
            .frame(width: min(180, width / 3))
            .padding(12)
            Rectangle().fill(Color.gray).frame(width: 1)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }

    private var page: some View {
        VStack(spacing: 0) {
            Text("Page \(model.page)")
                .frame(height: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(model.rows) { row in
                        HStack(spacing: 12) {
                            if trailing {
                                Spacer(minLength: 0)
                            } else {
                                Text(row.id).frame(width: 140, alignment: .leading)
                            }
                            DotSelect(
                                label: row.id,
                                options: row.options.map {
                                    DotSelectOption(
                                        value: $0,
                                        title: $0,
                                        detail: row.detail ? "Requires API key" : nil
                                    )
                                },
                                selection: model.binding(for: row.id),
                                width: row.width
                            )
                        }
                        .frame(height: 29)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .id(model.page)
    }
}

@MainActor
final class SelectPageModel: ObservableObject {
    struct Row: Identifiable {
        let id: String
        var options: [String]
        var selected: Int
        var width: CGFloat?
        /// Whether every option carries a second line, as the provider pickers do.
        var detail = false
    }

    @Published var rows: [Row]
    @Published var page = 0
    @Published var selection: [String: String] = [:]

    init(rows: [Row]) {
        self.rows = rows
        for row in rows {
            selection[row.id] = row.options.indices.contains(row.selected)
                ? row.options[row.selected]
                : row.options.first
        }
    }

    func binding(for id: String) -> Binding<String?> {
        Binding(
            get: { self.selection[id] },
            set: { self.selection[id] = $0 }
        )
    }
}

/// A document view that counts from its top, as the list's does.
private final class FlippedListDocument: NSView {
    override var isFlipped: Bool { true }
}

/// A window holding the fixture, with the lookups a test needs.
@MainActor
final class SelectWindowFixture {
    let window: NSWindow
    let host: NSHostingView<SelectPageFixture>
    let model: SelectPageModel

    init(window: NSWindow, host: NSHostingView<SelectPageFixture>, model: SelectPageModel) {
        self.window = window
        self.host = host
        self.model = model
    }

    /// The windows the app holds for a list: never more than one, because the
    /// controller re-hosts one panel rather than building a window per open.
    var panelCount: Int {
        NSApp.windows.filter { $0 is DotSelectPanel }.count
    }

    /// The lists on the screen. A hidden panel is the window a list will be
    /// drawn in next time; a visible one is a list that was left behind.
    var visiblePanelCount: Int {
        NSApp.windows.filter { $0 is DotSelectPanel && $0.isVisible }.count
    }

    var childCount: Int {
        window.childWindows?.count ?? 0
    }

    var listOffset: CGFloat {
        listScrollView?.contentView.bounds.origin.y ?? -1
    }

    func scrollList(to offset: CGFloat) {
        guard let scroll = waitForList() else {
            XCTFail("the list's scroll view never appeared")
            return
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.displayIfNeeded()
        settle(0.05)
    }

    /// The page's own scroll view: the thing a wheel over the page moves.
    var pageScrollView: NSScrollView? {
        Self.scrollView(in: host)
    }

    var listScrollView: NSScrollView? {
        DotSelectListController.shared.panel.flatMap { panel in
            panel.contentView.flatMap { Self.scrollView(in: $0) }
        }
    }

    /// Waits for the panel's list to exist, up to a second.
    ///
    /// Installing the panel's SwiftUI content is a run-loop turn of its own, and
    /// a loaded machine can take longer than a fixed settle. A test that reads
    /// the list before it exists measures an empty window: the scroll is a
    /// no-op and the fades still describe the top of the list. Waiting for the
    /// view removes that race without weakening any measurement.
    @discardableResult
    func waitForList(timeout: TimeInterval = 1) -> NSScrollView? {
        let deadline = Date().addingTimeInterval(timeout)
        while listScrollView == nil, Date() < deadline {
            settle(0.02)
        }
        return listScrollView
    }

    func trigger(_ label: String) -> DotSelectAccessibilityView? {
        Self.find(label: label, in: host)
    }

    /// The frame the controller gave the card when it opened, kept because the
    /// panel is moved off every display immediately afterwards so no test ever
    /// draws a window on the Mac it is running on.
    private(set) var openedCardFrame: CGRect?

    func open(_ label: String) throws {
        guard let trigger = trigger(label) else {
            throw XCTSkip("the trigger for \(label) is not in the hierarchy")
        }
        XCTAssertTrue(trigger.accessibilityPerformPress(), "\(label) did not open")
        if let panel = DotSelectListController.shared.panel {
            openedCardFrame = panel.frame.insetBy(
                dx: DotSelectPlacement.shadowInset,
                dy: DotSelectPlacement.shadowInset
            )
            panel.setFrameOrigin(OffscreenWindow.origin)
        }
        settle(0.2)
        waitForList()
    }

    func cardFrame() -> CGRect? {
        openedCardFrame
    }

    func screenFrame(of view: NSView) -> CGRect {
        window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    func scrollPage(by distance: CGFloat) {
        guard let scroll = Self.scrollView(in: host) else { return }
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + distance))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func resizeWindow(height: CGFloat) {
        var frame = window.frame
        frame.size.height = height
        frame.origin.y = window.frame.maxY - height
        window.setFrame(frame, display: true)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func moveWindow(by delta: CGSize) {
        var frame = window.frame
        frame.origin.x += delta.width
        frame.origin.y += delta.height
        window.setFrame(frame, display: true)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Runs the run loop so the work a panel schedules can finish.
    func settle(_ seconds: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Waits for the list to be gone, up to two seconds.
    ///
    /// A chosen row closes after the row has held and the card has faded, and
    /// that close is scheduled on the main actor, so a loaded machine lands it
    /// after a fixed settle: the row is chosen, the window is still there, and
    /// a test that read the window list at that moment called a list on its way
    /// out a list that stayed open. Waiting on the controller and the window it
    /// owns asks what the test means - is the list gone? - rather than
    /// measuring the main queue. The wait is bounded, so a list that really
    /// stayed open still fails the assertions that follow.
    func waitUntilClosed(timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while DotSelectListController.shared.isShowing || visiblePanelCount > 0,
              Date() < deadline {
            settle(0.02)
        }
    }

    static func find(label: String, in view: NSView) -> DotSelectAccessibilityView? {
        if let element = view as? DotSelectAccessibilityView, element.accessibilityLabel() == label {
            return element
        }
        for sub in view.subviews {
            if let found = find(label: label, in: sub) { return found }
        }
        return nil
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }
}

/// The live monitors and observers, counted.
@MainActor
final class CountingMonitors {
    private(set) var added = 0
    private(set) var removed = 0

    func reset() {
        added = 0
        removed = 0
    }

    var registrar: DotSelectMonitorRegistrar {
        DotSelectMonitorRegistrar(
            add: { mask, handler in
                self.added += 1
                return NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
            },
            remove: { token in
                self.removed += 1
                NSEvent.removeMonitor(token)
            }
        )
    }

    var observers: DotSelectObserverRegistrar {
        DotSelectObserverRegistrar(
            add: { name, handler in
                self.added += 1
                return NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { _ in
                    MainActor.assumeIsolated { handler() }
                }
            },
            remove: { token in
                self.removed += 1
                if let token = token as? NSObjectProtocol {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        )
    }
}
