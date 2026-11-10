import AppKit
@testable import Dot
import DotCore
import SwiftUI
import XCTest

/// Proves the island's buttons are clickable in the nonactivating panel.
///
/// The panel is ordered front off-screen and the click is sent straight to
/// the window, so nothing is shown on the user's display. This is the
/// regression test for the first-click problem: AppKit normally eats the
/// first click in an inactive window to activate it, and this panel can never
/// become key.
@MainActor
final class HUDInteractionTests: XCTestCase {
    func testTheFirstClickReachesASwiftUIButton() throws {
        _ = NSApplication.shared

        let clicked = expectation(description: "the stop button's action ran")
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        model.mode = .recording(elapsed: "0:07")

        var actions = HUDActions()
        actions.stop = { clicked.fulfill() }
        actions.cancel = {}

        let root = AnyView(
            HUDView(
                model: model,
                showsShadow: false,
                animated: false,
                actions: actions
            )
            .frame(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        )

        let panel = HUDPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 316, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = HUDHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 316, height: 54)
        panel.contentView = host

        panel.setFrame(NSRect(x: -10_000, y: -10_000, width: 316, height: 54), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
        XCTAssertNotNil(
            host.hitTest(NSPoint(x: 260, y: 27)),
            "the hosting view did not hit-test the stop button"
        )

        // The stop button is the first of the two controls at the trailing
        // edge of the 316 x 54 recording pill.
        let point = NSPoint(x: 260, y: 27)
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
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            panel.sendEvent(event)
        }

        wait(for: [clicked], timeout: 2)
    }

    func testTheTranscriptControlsReceiveTheFirstClick() throws {
        _ = NSApplication.shared

        let copied = expectation(description: "the copy button's action ran")
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.cardSize = CGSize(width: HUDState.transcriptWidth, height: 120)
        model.mode = .transcript(
            text: "A transcript that is long enough to lay out two lines in the card.",
            delivery: .pasted,
            elapsed: "0:07"
        )

        var actions = HUDActions()
        actions.copy = { copied.fulfill() }
        actions.paste = {}
        actions.settings = {}
        actions.close = {}

        let root = AnyView(
            HUDView(
                model: model,
                showsShadow: false,
                animated: false,
                actions: actions
            )
            .frame(width: HUDState.transcriptWidth, height: 120)
        )

        let panel = HUDPanel(
            contentRect: NSRect(
                x: -10_000,
                y: -10_000,
                width: HUDState.transcriptWidth,
                height: 120
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = HUDHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: HUDState.transcriptWidth, height: 120)
        panel.contentView = host

        panel.setFrame(
            NSRect(x: -10_000, y: -10_000, width: HUDState.transcriptWidth, height: 120),
            display: false
        )
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        // The transcript's actions end at the trailing padding. History has no
        // closure in the app, so it is not drawn; Copy is the first of the
        // four remaining controls, centred 22 points below the top of the
        // 44-point header.
        let point = NSPoint(x: 448, y: 98)
        XCTAssertNotNil(
            host.hitTest(point),
            "the hosting view did not hit-test the transcript controls"
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
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            panel.sendEvent(event)
        }

        wait(for: [copied], timeout: 2)
    }
}
