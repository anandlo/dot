import XCTest

@testable import DotCore

/// The bounded wait for a task that was cancelled.
///
/// These tests use tasks instead of a provider: a delayed fake settles when it
/// says it does, so the ordering between the abandoned live request and the
/// tail is checkable without a microphone, a window or a network.
final class TaskCompletionTests: XCTestCase {
    /// A value shared by the fake task and the test.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        var isRaised: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }

        func raise() {
            lock.lock()
            raised = true
            lock.unlock()
        }
    }

    func testATaskThatFinishesInsideTheBoundIsAwaited() async {
        let flag = Flag()
        let task = Task {
            // The fake finishes after a short delay, like a cancelled upload
            // that still has to close its socket.
            try? await Task.sleep(for: .milliseconds(40))
            flag.raise()
        }

        let finished = await TaskCompletion.wait(for: task, upTo: .seconds(2))

        XCTAssertTrue(finished)
        XCTAssertTrue(flag.isRaised, "the wait returned before the task settled")
    }

    func testATaskThatOutlastsTheBoundDoesNotHoldTheCaller() async {
        let flag = Flag()
        let task = Task {
            // Ignores cancellation for longer than the bound: the wait still
            // has to return, because the bound is the caller's deadline.
            try? await Task.sleep(for: .seconds(1))
            flag.raise()
        }
        let started = ContinuousClock.now

        let finished = await TaskCompletion.wait(for: task, upTo: .milliseconds(50))
        let elapsed = ContinuousClock.now - started

        XCTAssertFalse(finished)
        XCTAssertFalse(flag.isRaised, "the task settled before the deadline")
        XCTAssertLessThan(elapsed, .milliseconds(500), "the caller waited for the task instead of the bound")

        // The test's fake is cancelled and joined so it does not outlive the
        // suite by a second.
        task.cancel()
        _ = await task.value
    }

    func testACancelledTaskIsStillAwaitedForOrdering() async {
        // A cancelled task that keeps working briefly still settles before the
        // tail runs: this is the ordering the recovery depends on.
        let flag = Flag()
        let task = Task {
            let deadline = ContinuousClock.now + .milliseconds(40)
            while ContinuousClock.now < deadline {
                await Task.yield()
            }
            flag.raise()
        }
        task.cancel()

        let finished = await TaskCompletion.wait(for: task, upTo: .seconds(2))

        XCTAssertTrue(finished)
        XCTAssertTrue(flag.isRaised)
    }
}
