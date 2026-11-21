@testable import Dot
import XCTest

/// The shipped frame summary is checked against known numbers.
@MainActor
final class HUDFrameStatisticsTests: XCTestCase {
    func testPercentilesAndCountsOfKnownIntervals() {
        let stats = HUDFrameStatistics()
        stats.start(backend: "displayLink")
        for value in [10.0, 20, 30, 40, 50] {
            stats.record(intervalMS: value, durationMS: value / 10)
        }
        stats.recordLiveMain(ms: 0.25)
        stats.recordLiveMain(ms: 0.10)

        let summary = stats.current()
        XCTAssertEqual(summary.backend, "displayLink")
        XCTAssertEqual(summary.frames, 5)
        XCTAssertEqual(summary.intervalP50, 30)
        XCTAssertEqual(summary.intervalP95, 50)
        XCTAssertEqual(summary.intervalP99, 50)
        XCTAssertEqual(summary.intervalMax, 50)
        XCTAssertEqual(summary.over25ms, 3)
        XCTAssertEqual(summary.over33ms, 2)
        XCTAssertEqual(summary.tickP95, 5)
        XCTAssertEqual(summary.tickMax, 5)
        XCTAssertEqual(summary.liveMainMax, 0.25)

        XCTAssertEqual(stats.finish(), summary)
        XCTAssertNil(stats.finish(), "one recording logged more than one summary")
    }

    func testTheRingKeepsTheNewestThreeThousandSixHundredFrames() {
        let stats = HUDFrameStatistics()
        stats.start(backend: "timer")
        for index in 0..<3_605 {
            stats.record(intervalMS: Double(index), durationMS: 1)
        }

        let summary = stats.current()
        XCTAssertEqual(summary.frames, 3_600)
        XCTAssertEqual(summary.intervalMax, 3_604)
        XCTAssertEqual(summary.intervalP50, 1_804)
    }
}
