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

    func testAClickInsideTheListLeavesItOpen() {
        let stub = MonitorStub()
        let controller = makeController(stub)
        let session = open(controller)

        XCTAssertNotNil(stub.sendMouse(click(window: 42)))
        XCTAssertEqual(stub.removed, 0)
        XCTAssertEqual(session.monitorsAdded, 4)
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
        XCTAssertEqual(stub.added, 4)

        open(controller)
        XCTAssertEqual(first.monitorsRemoved, first.monitorsAdded)
        XCTAssertEqual(stub.added, 8)
        XCTAssertEqual(stub.removed, 4)
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
        XCTAssertEqual(stub.removed, 4)
        session.stop()
        XCTAssertEqual(stub.removed, 4, "a second stop removes nothing")
        controller.close()
        XCTAssertEqual(stub.removed, 4)
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
        XCTAssertEqual(stub.added, 4, "keys, clicks and the two window answers")
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
    private var observers: [NSNotification.Name: () -> Void] = [:]

    var registrar: DotSelectMonitorRegistrar {
        DotSelectMonitorRegistrar(
            add: { mask, handler in
                self.added += 1
                if mask.contains(.keyDown) {
                    self.keyHandler = handler
                } else {
                    self.mouseHandler = handler
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

    func notify(_ name: NSNotification.Name) {
        observers[name]?()
    }
}
