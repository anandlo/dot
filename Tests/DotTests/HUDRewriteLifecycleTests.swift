import AppKit
import DotCore
import XCTest

@testable import Dot

/// The rewrite layer cannot outlive the card that showed it.
///
/// The HUD is built with `offscreen: true`, so the panel is never placed on a
/// display; the tests only check the two callbacks the app uses to reset the
/// runner.
@MainActor
final class HUDRewriteLifecycleTests: XCTestCase {
    func testReplacingTheTranscriptEndsTheLayer() {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }

        var ended = 0
        hud.onTranscriptEnded = { ended += 1 }
        hud.showTranscript(text: "A transcript.", delivery: .pasted, elapsed: "0:03")
        hud.showMessage(text: "Something else.", symbol: "info.circle")
        XCTAssertGreaterThanOrEqual(ended, 1, "the old layer was never ended")
    }

    func testANewTranscriptEndsTheOldLayerEvenWhenBothAreTranscripts() {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }

        hud.showTranscript(text: "The first take.", delivery: .pasted, elapsed: "0:03")
        var ended = 0
        hud.onTranscriptEnded = { ended += 1 }
        hud.showTranscript(text: "A second take.", delivery: .pasted, elapsed: "0:04")
        XCTAssertGreaterThanOrEqual(ended, 1, "the previous layer was never ended")
    }

    func testHidingTheCardEndsTheLayer() {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)

        let hidden = expectation(description: "the card hid")
        hud.onHide = { hidden.fulfill() }
        hud.showTranscript(text: "A transcript.", delivery: .pasted, elapsed: "0:03")
        hud.hide()
        wait(for: [hidden], timeout: 2)
    }
}
