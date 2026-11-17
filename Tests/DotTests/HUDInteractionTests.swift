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

        let panel = OffscreenHUDPanel(size: CGSize(width: 316, height: 54))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = HUDHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 316, height: 54)
        panel.contentView = host

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

        let panel = OffscreenHUDPanel(size: CGSize(width: HUDState.transcriptWidth, height: 120))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = HUDHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: HUDState.transcriptWidth, height: 120)
        panel.contentView = host

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

    /// The version arrows are new controls on a panel that can never become
    /// key. They have to answer the first click exactly like the header buttons.
    func testTheVersionArrowsReceiveTheFirstClick() throws {
        _ = NSApplication.shared

        let next = expectation(description: "the next-version arrow ran")
        var card = RewriteCard(
            original: "A transcript with three versions to review.",
            choices: RewriteStyle.builtIns
        )
        card.append(id: 1, style: .concise, text: "A transcript with three versions.", warning: nil)
        card.append(id: 2, style: .prompt, text: "## Goal\nReview three versions.", warning: nil)
        card.select(versionID: 0)

        let size = HUD.transcriptSize(text: card.original, rewrite: card)
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.cardSize = size
        model.mode = .transcript(
            text: card.original,
            delivery: .pasted,
            elapsed: "0:04"
        )
        model.rewrite = card

        var actions = HUDActions()
        actions.copyVersion = { _ in }
        actions.pasteVersion = { _ in }
        actions.selectOriginal = {}
        actions.previousVersion = {}
        actions.nextVersion = { next.fulfill() }
        actions.rerunRewrite = {}

        let root = AnyView(
            HUDView(
                model: model,
                showsShadow: false,
                animated: false,
                actions: actions
            )
            .frame(width: size.width, height: size.height)
        )

        let panel = OffscreenHUDPanel(size: size)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = HUDHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        // The trailing arrow is the last control in the 24 point version row:
        // its centre is 10 points inside the card's 16 point trailing padding,
        // and the row sits 13 points (card padding) + 12 points (half a chip)
        // above the card's bottom edge.
        let point = NSPoint(x: size.width - HUDTheme.padding - 10, y: 25)
        XCTAssertNotNil(
            host.hitTest(point),
            "the hosting view did not hit-test the next-version arrow"
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

        wait(for: [next], timeout: 2)
    }

    /// The header's Copy button delivers the version on screen, not the
    /// transcript, and it is wired through the version-aware closure.
    func testTheHeaderCopyButtonDeliversTheSelectedVersion() throws {
        _ = NSApplication.shared

        let copied = expectation(description: "the version copy ran")
        var delivered: String?
        var card = RewriteCard(
            original: "The original words of the transcript.",
            choices: RewriteStyle.builtIns
        )
        card.append(id: 1, style: .concise, text: "The original words.", warning: nil)

        let size = CGSize(width: HUDState.transcriptWidth, height: 120)
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.cardSize = size
        model.mode = .transcript(
            text: card.original,
            delivery: .pasted,
            elapsed: "0:05"
        )
        model.rewrite = card

        var actions = HUDActions()
        actions.copy = { XCTFail("the plain transcript copy ran") }
        actions.paste = {}
        actions.copyVersion = { text in
            delivered = text
            copied.fulfill()
        }
        actions.pasteVersion = { _ in }
        actions.settings = {}
        actions.close = {}

        let root = AnyView(
            HUDView(
                model: model,
                showsShadow: false,
                animated: false,
                actions: actions
            )
            .frame(width: size.width, height: size.height)
        )

        let panel = OffscreenHUDPanel(size: size)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = HUDHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        // Copy is the first of the four trailing controls, centred 22 points
        // below the top of the 44 point header.
        let point = NSPoint(x: 448, y: 98)
        XCTAssertNotNil(host.hitTest(point), "the hosting view did not hit-test Copy")
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
        XCTAssertEqual(delivered, "The original words.")
    }

    /// The pinned Original chip and the rerun control are also first-click
    /// targets on the nonactivating panel.
    func testTheOriginalChipAndRerunReceiveTheFirstClick() throws {
        _ = NSApplication.shared

        let selectedOriginal = expectation(description: "the original chip ran")
        let rerun = expectation(description: "the rerun control ran")
        var card = RewriteCard(
            original: "The original words of the transcript.",
            choices: RewriteStyle.builtIns
        )
        card.append(id: 1, style: .concise, text: "The original words.", warning: nil)

        let size = HUD.transcriptSize(text: card.original, rewrite: card)
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.cardSize = size
        model.mode = .transcript(text: card.original, delivery: .pasted, elapsed: "0:04")
        model.rewrite = card

        var actions = HUDActions()
        actions.copyVersion = { _ in }
        actions.pasteVersion = { _ in }
        actions.selectOriginal = { selectedOriginal.fulfill() }
        actions.previousVersion = {}
        actions.nextVersion = {}
        actions.rerunRewrite = { rerun.fulfill() }

        let root = AnyView(
            HUDView(
                model: model,
                showsShadow: false,
                animated: false,
                actions: actions
            )
            .frame(width: size.width, height: size.height)
        )

        let panel = OffscreenHUDPanel(size: size)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = HUDHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        func click(_ point: NSPoint) throws {
            XCTAssertNotNil(host.hitTest(point), "nothing at \(point)")
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
        }

        let originalX = HUDTheme.padding
            + HUDRewriteLayout.versionArrowWidth
            + HUDRewriteLayout.chipGap
            + RewriteChipMetrics.chipWidth("Original") / 2
        try click(NSPoint(x: originalX, y: 25))
        wait(for: [selectedOriginal], timeout: 2)

        // The rerun control is the last control when it is shown.
        let rerunX = size.width - HUDTheme.padding - 10
        try click(NSPoint(x: rerunX, y: 25))
        wait(for: [rerun], timeout: 2)
    }
}
