import AppKit
@testable import Dot
import XCTest

/// The HUD's frame clock, without a screen or a running application.
@MainActor
final class HUDRenderLoopTests: XCTestCase {
    func testTheRenderLoopTicksOnTheMainRunLoop() {
        let loop = HUDRenderLoop()
        var ticks = 0

        loop.start { ticks += 1 }
        defer { loop.stop() }

        spin(for: 0.12)

        XCTAssertTrue(loop.isRunning)
        XCTAssertGreaterThan(ticks, 0, "the loop did not tick")
    }

    func testStoppingTheRenderLoopStopsTheTicks() {
        let loop = HUDRenderLoop()
        var ticks = 0

        loop.start { ticks += 1 }
        spin(for: 0.08)
        loop.stop()
        let stopped = ticks
        spin(for: 0.08)

        XCTAssertFalse(loop.isRunning)
        XCTAssertEqual(ticks, stopped, "the loop ticked after it was stopped")
    }

    /// The regression test for the invisible island: `showReady` must drive
    /// the real model through the real loop, with no display involved.
    func testShowReadyBecomesVisibleWithoutAScreen() {
        _ = NSApplication.shared

        let hud = HUD(offscreen: true)
        hud.readyDwell = 0
        defer {
            hud.hide()
            spin(for: 0.4)
        }

        hud.showReady(shortcut: "⌥⌘D")
        var elapsed = 0.0
        while hud.debugPresence < 0.5 && elapsed < 1.0 {
            spin(for: 0.05)
            elapsed += 0.05
        }

        XCTAssertTrue(hud.isVisible, "the HUD state is not visible")
        XCTAssertTrue(hud.debugPanelVisible, "the panel was ordered front but is not visible")
        XCTAssertGreaterThan(hud.debugTickCount, 0, "the render loop did not deliver a frame")
        XCTAssertGreaterThan(hud.debugPresence, 0.5, "the card stayed transparent")
        XCTAssertGreaterThan(hud.debugContent, 0.5, "the content stayed transparent")
    }

    /// The fallback must show the card even when no frame ever runs.
    func testTheVisibilityFallbackShowsTheCardWhenTheLoopIsDead() {
        _ = NSApplication.shared

        let hud = HUD(offscreen: true)
        hud.readyDwell = 0
        defer {
            hud.hide()
            spin(for: 0.4)
        }

        hud.showReady(shortcut: "⌥⌘D")
        hud.debugStopRenderLoop()
        spin(for: 0.2)

        XCTAssertEqual(hud.debugTickCount, 0, "a frame ran before the fallback")
        XCTAssertEqual(hud.debugFallbackCount, 1, "the visibility fallback did not run")
        XCTAssertEqual(hud.debugPresence, 1, accuracy: 0.001, "the fallback left the card transparent")
        XCTAssertEqual(hud.debugContent, 1, accuracy: 0.001, "the fallback left the content transparent")
    }

    /// Runs the main run loop, so the loop's `.common` timer can fire.
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
