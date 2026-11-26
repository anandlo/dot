import AppKit
import XCTest
@testable import Dot

/// Every display frame the main thread misses is counted and logged, during
/// scroll tracking too, and the log cannot be flooded.
@MainActor
final class FrameDropMonitorTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        FrameDropMonitor.shared.debugReset()
        DotScrollInteraction.debugReset()
    }

    override func tearDown() async throws {
        FrameDropMonitor.shared.debugReset()
        DotScrollInteraction.debugReset()
        try await super.tearDown()
    }

    func testAGapCountsTheFramesItMissed() {
        let frame60 = 1.0 / 60
        XCTAssertNil(FrameDropMonitor.hitch(previous: 1, current: 1 + frame60, frameDuration: frame60))
        XCTAssertNil(FrameDropMonitor.hitch(previous: 1, current: 1 + frame60 * 1.4, frameDuration: frame60))
        XCTAssertEqual(FrameDropMonitor.hitch(previous: 1, current: 1 + frame60 * 2, frameDuration: frame60)?.dropped, 1)
        XCTAssertEqual(FrameDropMonitor.hitch(previous: 1, current: 1 + frame60 * 5, frameDuration: frame60)?.dropped, 4)
        let frame120 = 1.0 / 120
        let hitch = FrameDropMonitor.hitch(previous: 2, current: 2 + 0.1, frameDuration: frame120)
        XCTAssertEqual(hitch?.dropped, 11)
        XCTAssertEqual(hitch?.gapMS ?? 0, 100, accuracy: 0.01)
        XCTAssertNil(FrameDropMonitor.hitch(previous: 2, current: 2, frameDuration: frame60))
        XCTAssertNil(FrameDropMonitor.hitch(previous: 2, current: 3, frameDuration: 0))
    }

    func testEveryHitchIsCountedButTheLogHasABudget() {
        let monitor = FrameDropMonitor.shared
        let hitch = FrameDropMonitor.Hitch(dropped: 2, gapMS: 50, frameMS: 16.7)
        let count = FrameDropMonitor.linesPerMinute + 60
        for index in 0..<count {
            monitor.record(hitch, at: 1_000 + Double(index) * 0.01)
        }
        XCTAssertEqual(monitor.totalHitches, count)
        XCTAssertEqual(monitor.totalDroppedFrames, count * 2)
        XCTAssertEqual(monitor.debugLinesInWindow, FrameDropMonitor.linesPerMinute)
        XCTAssertEqual(monitor.debugSuppressedHitches, 60)

        monitor.record(hitch, at: 1_000 + 61)
        XCTAssertEqual(monitor.debugLinesInWindow, 1, "a new minute did not reopen the budget")
        XCTAssertEqual(monitor.debugSuppressedHitches, 0)
    }

    func testADropNamesTheAnimationsThatWereRunning() {
        let monitor = FrameDropMonitor.shared
        XCTAssertEqual(monitor.sourceLabel, "idle")
        monitor.begin("swatch")
        monitor.begin("swatch")
        monitor.setHUDActive(true)
        DotScrollInteraction.beginLiveScroll()
        XCTAssertEqual(monitor.sourceLabel, "hud,scroll,swatch")
        monitor.end("swatch")
        XCTAssertEqual(monitor.sourceLabel, "hud,scroll,swatch", "one of two swatches is still running")
        monitor.end("swatch")
        DotScrollInteraction.endLiveScroll()
        monitor.setHUDActive(false)
        XCTAssertEqual(monitor.sourceLabel, "idle")
    }

    /// Runs the main run loop in the mode AppKit uses while a scroll tracks.
    private func runTracking(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
    }

    private func blockMainThread(milliseconds: UInt32) {
        usleep(milliseconds * 1_000)
    }

    func testABlockedMainThreadIsCountedFromTheDisplayLink() throws {
        try XCTSkipIf(NSScreen.main == nil, "no display to link to")
        let monitor = FrameDropMonitor.shared
        monitor.start()
        monitor.setHUDActive(true)
        XCTAssertTrue(monitor.debugIsLinked, "the monitor did not link while the HUD was rendering")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertGreaterThan(monitor.debugCallbacks, 5, "the display link is not firing")
        let before = monitor.totalDroppedFrames
        blockMainThread(milliseconds: 120)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertGreaterThanOrEqual(
            monitor.totalDroppedFrames - before,
            5,
            "a 120 ms main-thread block was not counted as missed frames"
        )
        monitor.setHUDActive(false)
        if !NSApplication.shared.isActive {
            XCTAssertFalse(monitor.debugIsLinked, "the link kept running with nothing on screen")
        }
    }

    func testDropsAreCountedWhileAScrollIsTracking() throws {
        try XCTSkipIf(NSScreen.main == nil, "no display to link to")
        let monitor = FrameDropMonitor.shared
        monitor.start()
        monitor.setHUDActive(true)
        runTracking(0.25)
        let callbacks = monitor.debugCallbacks
        runTracking(0.25)
        XCTAssertGreaterThan(monitor.debugCallbacks - callbacks, 3, "the link stops while a scroll is tracking")
        let before = monitor.totalDroppedFrames
        blockMainThread(milliseconds: 120)
        runTracking(0.15)
        XCTAssertGreaterThanOrEqual(monitor.totalDroppedFrames - before, 5)
    }

    func testAGestureTraceMeasuresBothEdges() {
        var trace = ScrollGestureTrace(surface: "settings", now: 10)
        trace.record(originY: 0, maxY: 400, now: 10.016)
        trace.record(originY: -28.4, maxY: 400, now: 10.032)
        trace.record(originY: 200, maxY: 400, now: 10.120)
        trace.record(originY: 431.25, maxY: 400, now: 10.136)
        XCTAssertEqual(trace.updates, 4)
        XCTAssertEqual(trace.topOverscroll, 28.4, accuracy: 0.001)
        XCTAssertEqual(trace.bottomOverscroll, 31.25, accuracy: 0.001)
        XCTAssertEqual(trace.maxGapMS, 88, accuracy: 0.01)
        let fields = trace.fields(now: 10.2, elastic: true)
        guard case .string("settings") = fields["surface"],
              case .int(4) = fields["updates"],
              case .bool(true) = fields["elastic"],
              case .double(let ms) = fields["ms"] else {
            return XCTFail("the gesture line is missing fields: \(fields)")
        }
        XCTAssertEqual(ms, 200, accuracy: 0.5)
    }
}
