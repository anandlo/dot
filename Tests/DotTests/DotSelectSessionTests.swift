import AppKit
import XCTest

@testable import Dot

/// The monitors an open list installs, and that none of them outlive it.
///
/// A local event monitor that is not removed keeps every key press in the app
/// for as long as the process lives, and it is invisible in a screenshot. The
/// stub counts what the controller installed against what it removed on each of
/// the ways a list can close.
@MainActor
final class DotSelectSessionTests: XCTestCase {
    private let titles = ["Ava", "Daniel", "George", "Rachel"]

    // MARK: Every close path

    func testEscapeClosesTheListAndRemovesEveryMonitor() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        XCTAssertNil(stub.sendKey(key(keyCode: 53, characters: "\u{1B}")), "escape is used")
        assertBalanced(stub, session)
        XCTAssertNil(controller.session)
    }

    func testAnOutsideClickClosesTheListAndRemovesEveryMonitor() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        XCTAssertNotNil(stub.sendMouse(click(window: 7)), "the click is handed on")
        assertBalanced(stub, session)
        XCTAssertNil(controller.session)
    }

    /// The click monitor answers a click, and only a click: the wheel monitor
    /// installed after it must not take its place.
    func testAClickOnThePageClosesTheListAndIsHandedOn() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        let click = click(window: 7)
        XCTAssertTrue(stub.sendMouse(click) === click, "the click belongs to the window behind")
        XCTAssertEqual(session.monitorsRemoved, session.monitorsAdded)
        XCTAssertNil(controller.session)
    }

    /// A wheel over the page closes the list and is then delivered, so one
    /// gesture both ends the list and scrolls the page.
    func testAWheelOverThePageClosesTheListAndIsHandedOn() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        let wheel = scroll(window: 7)
        XCTAssertTrue(stub.sendScroll(wheel) === wheel, "the page keeps the wheel")
        XCTAssertEqual(session.monitorsRemoved, session.monitorsAdded)
        XCTAssertNil(controller.session)
    }

    /// A wheel over the list is a newer target than an end the list has not
    /// placed, and it is delivered to the list.
    ///
    /// A synthetic wheel carries no window number, so the list is opened with
    /// the number the event has.
    func testAWheelOverTheListReportsTheListScrolled() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = controller.beginSession(
            titles: titles,
            selected: 0,
            panelNumber: { 0 },
            onSelect: { _ in },
            onClose: {}
        )
        var reported = 0
        session.onListScroll = { reported += 1 }

        let wheel = scroll(window: 0)
        XCTAssertTrue(stub.sendScroll(wheel) === wheel, "the list keeps its own wheel")
        XCTAssertEqual(reported, 1, "the list never learned it was scrolled")
        XCTAssertNotNil(controller.session, "a wheel over the list does not close it")
    }

    /// A wheel is the list's only when it names the list.
    ///
    /// A synthetic wheel carries no window number, so the decision itself is
    /// what is asked here; how the window server fills the number is AppKit's
    /// part.
    func testAWheelIsTheListsOnlyWhenItNamesTheList() {
        let controller = makeController(MonitorStub())
        let session = open(controller)

        XCTAssertFalse(
            session.shouldCloseForScroll(windowNumber: 42),
            "a wheel over the list belongs to the list"
        )
        XCTAssertTrue(
            session.shouldCloseForScroll(windowNumber: 7),
            "a wheel over the page ends the list"
        )
    }

    /// The click that closed the list on its trigger must not open it again.
    func testAClickOnTheTriggerThatClosedTheListDoesNotOpenItAgain() {
        let anchor = NSRect(x: 100, y: 100, width: 200, height: 29)

        XCTAssertTrue(DotSelectListController.suppressesNextOpening(
            dismissal: .outsideClick,
            click: CGPoint(x: 150, y: 110),
            anchor: anchor
        ), "a click inside the trigger reopens it")
        XCTAssertFalse(DotSelectListController.suppressesNextOpening(
            dismissal: .outsideClick,
            click: CGPoint(x: 500, y: 110),
            anchor: anchor
        ), "a click elsewhere on the page is not a press of the trigger")
        XCTAssertFalse(DotSelectListController.suppressesNextOpening(
            dismissal: .scrolled,
            click: CGPoint(x: 150, y: 110),
            anchor: anchor
        ), "a wheel is not a click")
    }

    func testAClickInsideTheListLeavesItOpen() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        XCTAssertNotNil(stub.sendMouse(click(window: 42)))
        XCTAssertEqual(stub.removed, 0)
        XCTAssertEqual(session.monitorsAdded, DotSelectSession.watchCount)
        XCTAssertNotNil(controller.session)
    }

    func testTheParentResigningKeyRemovesEveryMonitor() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        stub.notify(NSWindow.didResignKeyNotification)
        assertBalanced(stub, session)
        XCTAssertNil(controller.session)
    }

    func testMovingToAnotherSpaceRemovesEveryMonitor() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        stub.notify(NSWorkspace.activeSpaceDidChangeNotification)
        assertBalanced(stub, session)
        XCTAssertNil(controller.session)
    }

    func testACommitChoosesTheRowAndRemovesEveryMonitor() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        var chosen: Int?
        let session = open(controller, selected: 1, onSelect: { chosen = $0 })

        XCTAssertNil(stub.sendKey(key(keyCode: 36, characters: "\r")))
        XCTAssertEqual(chosen, 1)
        assertBalanced(stub, session)
        XCTAssertNil(controller.session)
    }

    func testSpaceCommitsTheHighlightedRow() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        var chosen: Int?
        open(controller, selected: 2, onSelect: { chosen = $0 })

        XCTAssertNil(stub.sendKey(key(keyCode: 49, characters: " ")))
        XCTAssertEqual(chosen, 2)
        XCTAssertEqual(stub.removed, stub.added)
    }

    /// A second list closes the first, monitors and all.
    func testBeginningASecondListRemovesTheFirstListsMonitors() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let first = open(controller)
        XCTAssertEqual(stub.added, DotSelectSession.watchCount)

        open(controller)
        XCTAssertEqual(first.monitorsRemoved, first.monitorsAdded)
        XCTAssertEqual(stub.added, 2 * DotSelectSession.watchCount)
        XCTAssertEqual(stub.removed, DotSelectSession.watchCount)
    }

    /// The list has no window while it is closed.
    func testNoPanelExistsWhileTheListIsClosed() {
        let controller = DotSelectListController()
        XCTAssertFalse(controller.isShowing)
        XCTAssertNil(controller.panel)
        controller.close()
        XCTAssertNil(controller.panel)
        XCTAssertNil(controller.session)
    }

    func testStoppingTwiceRemovesNothingTwice() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        session.stop()
        XCTAssertEqual(stub.removed, DotSelectSession.watchCount)
        session.stop()
        XCTAssertEqual(stub.removed, DotSelectSession.watchCount, "a second stop removes nothing")
        controller.close()
        XCTAssertEqual(stub.removed, DotSelectSession.watchCount)
    }

    // MARK: Keys and rows

    func testTheArrowKeysMoveTheHighlightWithoutWrapping() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        _ = stub.sendKey(specialKey(0xF701, keyCode: 125))
        XCTAssertEqual(session.keyboard.highlight, 1)
        for _ in 0..<4 {
            _ = stub.sendKey(specialKey(0xF701, keyCode: 125))
        }
        XCTAssertEqual(session.keyboard.highlight, 3, "the last row holds")
        _ = stub.sendKey(specialKey(0xF700, keyCode: 126))
        XCTAssertEqual(session.keyboard.highlight, 2)
    }

    func testATypedLetterJumpsAndIsSwallowed() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        XCTAssertNil(stub.sendKey(key(keyCode: 5, characters: "r", timestamp: 0)))
        XCTAssertEqual(session.keyboard.highlight, 3)
    }

    /// A command shortcut belongs to the app, not to the list.
    func testACommandShortcutIsHandedOn() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        open(controller)

        let event = key(keyCode: 13, characters: "w", modifiers: .command)
        XCTAssertTrue(stub.sendKey(event) === event)
    }

    func testAHoveredRowBecomesTheCommittedRow() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        session.hover(2)
        XCTAssertEqual(session.keyboard.highlight, 2)
        XCTAssertEqual(session.keyboard.commitIndex, 2)
    }

    // MARK: Helpers

    private func assertBalanced(_ stub: MonitorStub, _ session: DotSelectSession) {
        XCTAssertEqual(stub.added, DotSelectSession.watchCount, "keys, clicks and the window answers")
        XCTAssertEqual(stub.removed, stub.added)
        XCTAssertEqual(session.monitorsAdded, session.monitorsRemoved)
    }

    private func makeController(_ stub: MonitorStub) -> DotSelectListController {
        let controller = DotSelectListController()
        controller.makeSession = stub.sessionFactory()
        return controller
    }

    @discardableResult
    private func open(
        _ controller: DotSelectListController,
        selected: Int? = 0,
        onSelect: @escaping (Int) -> Void = { _ in }
    ) -> DotSelectSession {
        controller.beginSession(
            titles: titles,
            selected: selected,
            panelNumber: { 42 },
            onSelect: onSelect,
            onClose: {}
        )
    }

    private func key(
        keyCode: UInt16,
        characters: String,
        timestamp: TimeInterval = 0,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: 42,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func specialKey(_ scalar: UInt32, keyCode: UInt16) -> NSEvent {
        key(keyCode: keyCode, characters: String(Unicode.Scalar(scalar)!))
    }

    private func scroll(window: Int) -> NSEvent {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -20,
            wheel2: 0,
            wheel3: 0
        )!
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        return NSEvent(cgEvent: event)!
    }

    private func click(window: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

/// A registrar that counts what it was asked to watch, and lets a test send.
@MainActor
private final class MonitorStub {
    private(set) var added = 0
    private(set) var removed = 0
    private var keyHandler: ((NSEvent) -> NSEvent?)?
    private var mouseHandler: ((NSEvent) -> NSEvent?)?
    private var scrollHandler: ((NSEvent) -> NSEvent?)?
    private var observers: [NSNotification.Name: () -> Void] = [:]

    var registrar: DotSelectMonitorRegistrar {
        DotSelectMonitorRegistrar(
            add: { mask, handler in
                self.added += 1
                // One handler per kind of event: a wheel and a click are two
                // monitors, and the second must not take the first's place or
                // a click test would be answered by the wheel path.
                if mask.contains(.keyDown) {
                    self.keyHandler = handler
                } else if mask.contains(.leftMouseDown) {
                    self.mouseHandler = handler
                } else if mask.contains(.scrollWheel) {
                    self.scrollHandler = handler
                }
                return NSObject()
            },
            remove: { _ in
                self.removed += 1
            }
        )
    }

    var observerRegistrar: DotSelectObserverRegistrar {
        DotSelectObserverRegistrar(
            add: { name, handler in
                self.added += 1
                self.observers[name] = handler
                return NSObject()
            },
            remove: { _ in
                self.removed += 1
            }
        )
    }

    func sessionFactory() -> ([String], Int?, @escaping () -> Int) -> DotSelectSession {
        { titles, selected, number in
            DotSelectSession(
                titles: titles,
                selected: selected,
                registrar: self.registrar,
                observers: self.observerRegistrar,
                panelNumber: number
            )
        }
    }

    func sendKey(_ event: NSEvent) -> NSEvent? {
        guard let keyHandler else { return event }
        return keyHandler(event)
    }

    func sendMouse(_ event: NSEvent) -> NSEvent? {
        guard let mouseHandler else { return event }
        return mouseHandler(event)
    }

    func sendScroll(_ event: NSEvent) -> NSEvent? {
        guard let scrollHandler else { return event }
        return scrollHandler(event)
    }

    func notify(_ name: NSNotification.Name) {
        observers[name]?()
    }
}
