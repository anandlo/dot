import AppKit
@testable import Dot
import DotCore
import XCTest

/// The launch card and the buttons the card is allowed to draw.
@MainActor
final class HUDReadyTests: XCTestCase {
    func testOnlyWiredActionsAreDrawn() {
        var actions = HUDActions()
        actions.copy = {}
        actions.settings = {}

        XCTAssertEqual(
            HUDAction.available([.copy, .paste, .history, .settings, .close], in: actions),
            [.copy, .settings]
        )
        XCTAssertTrue(HUDAction.available([.stop, .cancel, .history], in: actions).isEmpty)
        XCTAssertFalse(HUDAction.paste.isAvailable(in: actions))
        XCTAssertTrue(HUDAction.close.isAvailable(in: HUDActions(close: {})))
    }

    func testTheTranscriptHeaderDropsHistoryWhenItHasNoClosure() {
        var actions = HUDActions()
        actions.copy = {}
        actions.paste = {}
        actions.settings = {}
        actions.close = {}

        let available = HUDAction.available(
            [.copy, .paste, .history, .settings, .close],
            in: actions
        )
        XCTAssertEqual(available, [.copy, .paste, .settings, .close])
        XCTAssertFalse(available.contains(.history))
    }

    func testTheLaunchCardNeverTakesOverAnActiveState() {
        XCTAssertTrue(HUD.canShowReady(over: .message(text: "", symbol: "info.circle"), visible: false))
        XCTAssertTrue(HUD.canShowReady(over: .ready(shortcut: "⌥⌘D"), visible: true))
        XCTAssertFalse(HUD.canShowReady(over: .recording(elapsed: "0:01"), visible: true))
        XCTAssertFalse(HUD.canShowReady(over: .working, visible: true))
        XCTAssertFalse(
            HUD.canShowReady(
                over: .transcript(text: "Done.", delivery: .copied, elapsed: "0:03"),
                visible: true
            )
        )
        XCTAssertFalse(
            HUD.canShowReady(over: .message(text: "Kept.", symbol: "info.circle"), visible: true)
        )
    }

    func testTheLaunchCardRendersAtItsCompactSize() throws {
        let image = try HUDPreview.render(state: .ready, showsShadow: false)
        let inset = Int(HUD.shadowPadding * 2)

        XCTAssertEqual(image.pixelsWide, Int(HUDState.readyWidth) * 2 + inset * 2)
        XCTAssertEqual(image.pixelsHigh, Int(HUDState.readyHeight) * 2 + inset * 2)

        for (x, y) in [
            (0, 0),
            (image.pixelsWide - 1, 0),
            (0, image.pixelsHigh - 1),
            (image.pixelsWide - 1, image.pixelsHigh - 1),
        ] {
            let color = try XCTUnwrap(image.colorAt(x: x, y: y))
            XCTAssertEqual(color.alphaComponent, 0, accuracy: 0.001, "corner (\(x), \(y)) is not transparent")
        }

        let middle = try XCTUnwrap(
            image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)
        )
        XCTAssertGreaterThan(middle.alphaComponent, 0.9)
    }

    func testTheLaunchStateIsInTheRenderSet() {
        XCTAssertTrue(HUDPreview.State.allCases.contains(.ready))
        XCTAssertEqual(HUDPreview.State.ready.rawValue, "ready")
    }
}
