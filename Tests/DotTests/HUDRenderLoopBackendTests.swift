import AppKit
@testable import Dot
import XCTest

/// Backend choice and link lifetime, proved with a recorded display link. No
/// window is ordered front and no real display is involved.
@MainActor
final class HUDRenderLoopBackendTests: XCTestCase {
    func testBackendSelection() {
        XCTAssertEqual(
            HUDRenderLoop.chooseBackend(offscreen: true, hasScreen: true),
            .timer
        )
        XCTAssertEqual(
            HUDRenderLoop.chooseBackend(offscreen: false, hasScreen: false),
            .timer
        )
        XCTAssertEqual(
            HUDRenderLoop.chooseBackend(offscreen: false, hasScreen: true),
            .displayLink
        )

        let loop = HUDRenderLoop()
        let link = FakeRenderLink()
        loop.linkFactory = { _, _, _ in link }
        loop.start(on: NSView(), screenID: nil, offscreen: false) { _ in }
        XCTAssertEqual(loop.activeBackend, .timer)
        XCTAssertFalse(link.wasAdded)
        loop.stop()

        let offscreenLoop = HUDRenderLoop()
        let offscreenLink = FakeRenderLink()
        offscreenLoop.linkFactory = { _, _, _ in offscreenLink }
        offscreenLoop.start(on: NSView(), screenID: 1, offscreen: true) { _ in }
        XCTAssertEqual(offscreenLoop.activeBackend, .timer)
        XCTAssertFalse(offscreenLink.wasAdded)
        offscreenLoop.stop()
    }

    func testOnScreenLinkUsesTheViewAndRequestsSixtyFrames() {
        let loop = HUDRenderLoop()
        let link = FakeRenderLink()
        let view = NSView()
        loop.linkFactory = { _, _, _ in link }

        loop.start(on: view, screenID: 11, offscreen: false) { _ in }
        defer { loop.stop() }

        XCTAssertEqual(loop.activeBackend, .displayLink)
        XCTAssertTrue(link.wasAdded)
        XCTAssertEqual(link.preferredFrameRateRange.minimum, 60)
        XCTAssertEqual(link.preferredFrameRateRange.maximum, 60)
        XCTAssertEqual(link.preferredFrameRateRange.preferred, 60)
        XCTAssertTrue(loop.isRunning)
    }

    func testMovingToAnotherScreenInvalidatesAndRecreatesTheLink() {
        let loop = HUDRenderLoop()
        let first = FakeRenderLink()
        let second = FakeRenderLink()
        var links = [first, second]
        loop.linkFactory = { _, _, _ in links.removeFirst() }
        let view = NSView()

        loop.start(on: view, screenID: 1, offscreen: false) { _ in }
        loop.refresh(on: view, screenID: 1)
        XCTAssertEqual(first.invalidations, 0, "a same-screen refresh recreated the link")

        loop.refresh(on: view, screenID: 2)
        XCTAssertEqual(first.invalidations, 1)
        XCTAssertTrue(second.wasAdded)
        loop.stop()
        XCTAssertEqual(second.invalidations, 1)
    }

    func testWatchdogFallbackSwitchesToTheTimerAndStopsTheLink() {
        let loop = HUDRenderLoop()
        let link = FakeRenderLink()
        loop.linkFactory = { _, _, _ in link }
        var ticks = 0
        loop.start(on: NSView(), screenID: 1, offscreen: false) { _ in ticks += 1 }

        loop.fallbackToTimer()

        XCTAssertEqual(loop.activeBackend, .timer)
        XCTAssertEqual(link.invalidations, 1)
        XCTAssertTrue(loop.isRunning)
        loop.stop()
    }

    func testHidingTheHUDInvalidatesTheLinkItWasGiven() {
        let hud = HUD(offscreen: true)
        hud.showRecording(elapsed: "0:00")
        hud.debugRenderLoop.stop()

        let link = FakeRenderLink()
        hud.debugRenderLoop.linkFactory = { _, _, _ in link }
        hud.debugRenderLoop.start(on: NSView(), screenID: 1, offscreen: false) { _ in }
        hud.hide()

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(link.invalidations, 1)
        XCTAssertEqual(hud.debugRenderLoop.activeBackend, .timer)
    }
}

/// Records what the loop asked AppKit's display link to do.
final class FakeRenderLink: HUDRenderLinking {
    var targetTimestamp: CFTimeInterval = 0
    var preferredFrameRateRange = CAFrameRateRange(minimum: 0, maximum: 0, preferred: 0)
    private(set) var wasAdded = false
    private(set) var invalidations = 0

    func add(to runLoop: RunLoop, forMode: RunLoop.Mode) {
        wasAdded = true
    }

    func invalidate() {
        invalidations += 1
    }
}
