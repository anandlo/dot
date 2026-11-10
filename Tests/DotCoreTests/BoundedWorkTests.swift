import XCTest

@testable import DotCore

/// The bounded runner that keeps a Keychain read off the main actor.
final class BoundedWorkTests: XCTestCase {
    func testWorkThatFinishesInTimeReturnsItsValue() async {
        let outcome = await BoundedWork.run(within: .seconds(5)) { 41 }
        XCTAssertEqual(outcome.value, 41)
        if case .timedOut = outcome {
            XCTFail("the work finished long before the deadline")
        }
    }

    func testWorkThatOutlastsTheDeadlineTimesOut() async {
        let started = Date()
        let outcome = await BoundedWork.run(within: .milliseconds(50)) {
            Thread.sleep(forTimeInterval: 1)
            return 1
        }
        let elapsed = Date().timeIntervalSince(started)

        if case .finished = outcome {
            XCTFail("the deadline had already passed")
        }
        XCTAssertNil(outcome.value)
        XCTAssertLessThan(elapsed, 0.9, "the caller must not wait for the abandoned work")
    }

    func testTheCallerIsResumedExactlyOnce() async {
        // A late answer after the deadline must be dropped, not resumed twice:
        // a double resume would crash the process. Ten slow calls in a row are
        // enough to catch a regression.
        for _ in 0..<10 {
            let outcome = await BoundedWork.run(within: .milliseconds(10)) {
                Thread.sleep(forTimeInterval: 0.2)
                return 7
            }
            XCTAssertNil(outcome.value)
        }
    }

    func testTheTimeoutIsClampedToASafeRange() {
        XCTAssertEqual(BoundedWork.nanoseconds(of: .zero), 0)
        XCTAssertEqual(BoundedWork.nanoseconds(of: .milliseconds(250)), 250_000_000)
        XCTAssertEqual(BoundedWork.nanoseconds(of: .seconds(2)), 2_000_000_000)
        XCTAssertEqual(
            BoundedWork.nanoseconds(of: .seconds(100_000)),
            BoundedWork.nanoseconds(of: BoundedWork.maximumTimeout),
            "an absurd timeout is clamped instead of overflowing"
        )
    }
}
