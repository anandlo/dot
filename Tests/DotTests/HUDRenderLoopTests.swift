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

        XCTAssertTrue(waitUntil { ticks > 0 }, "no frame arrived before the deadline")

        XCTAssertTrue(loop.isRunning)
        XCTAssertGreaterThan(ticks, 0, "the loop did not tick")
    }

    func testStoppingTheRenderLoopStopsTheTicks() {
        let loop = HUDRenderLoop()
        var ticks = 0

        loop.start { ticks += 1 }
        XCTAssertTrue(waitUntil { ticks > 0 }, "the loop never ran, so stopping it proves nothing")
        loop.stop()
        let stopped = ticks
        spin(for: 0.2)

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
        XCTAssertTrue(
            waitUntil { hud.debugTickCount > 0 && hud.debugPresence >= 0.5 },
            "the frame that would make the card visible never arrived"
        )

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
        XCTAssertTrue(
            waitUntil { hud.debugFallbackCount == 1 },
            "the visibility fallback never ran"
        )

        XCTAssertEqual(hud.debugTickCount, 0, "a frame ran before the fallback")
        XCTAssertEqual(hud.debugFallbackCount, 1, "the visibility fallback did not run")
        XCTAssertEqual(hud.debugPresence, 1, accuracy: 0.001, "the fallback left the card transparent")
        XCTAssertEqual(hud.debugContent, 1, accuracy: 0.001, "the fallback left the content transparent")
    }

    /// Spins the main run loop in default mode so timers can fire.
    private func spin(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.02))
            )
        }
    }

    /// Spins the run loop until `condition` holds, or the deadline passes.
    ///
    /// The deadline is long on purpose. Every wait in this file is for a timer
    /// the run loop has to deliver, and a machine running the test bundle in
    /// parallel can starve this process for a second or more. A short window
    /// then measures the machine's load rather than the behaviour under test.
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
}
