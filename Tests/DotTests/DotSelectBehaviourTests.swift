import AppKit
import Combine
@testable import Dot
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

    /// A key pressed while the list is still opening is where the reader is:
    /// the end the opening asked for does not jump the list back when it ends.
    func testAKeyPressedWhileTheListOpensDropsTheEndItWasWaitingFor() throws {
        let fixture = try makeFixture(rows: 3, options: 30, selected: 29)
        let trigger = try XCTUnwrap(fixture.trigger("Setting 01"))
        XCTAssertTrue(trigger.accessibilityPerformPress())
        let session = try XCTUnwrap(DotSelectListController.shared.session)

        for _ in 0..<11 {
            XCTAssertNil(session.handleKey(Self.key(code: 126, characters: "\u{F700}")))
        }
        fixture.settle(0.05)
        fixture.settle(0.4)

        let scroll = try XCTUnwrap(fixture.listScrollView)
        let foot = try XCTUnwrap(scroll.documentView).frame.height - scroll.contentView.bounds.height
        XCTAssertEqual(session.keyboard.highlight, 18)
        XCTAssertLessThan(
            fixture.listOffset,
            foot - 100,
            "the list jumped to the end the opening asked for"
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

    private func makeFixture(
        rows: Int = 24,
        options: Int = 4,
        titles: [String]? = nil,
        selected: Int = 0,
        height: CGFloat = 600,
        narrowOptions: Bool = false,
        longOptions: Bool = false,
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
                    width: narrowOptions ? 120 : nil
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

    private static func render(_ view: AnyView, appearance: NSAppearance?) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 78)
        host.appearance = appearance
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
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
                                options: row.options.map { DotSelectOption(value: $0, title: $0) },
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
