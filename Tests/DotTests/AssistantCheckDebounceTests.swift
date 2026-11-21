import DotCore
import XCTest

@testable import Dot

/// The wait between an edit and the models request it causes.
///
/// An address is typed a character at a time, and the record changes with every
/// character. These tests prove the row sends one check for a burst, and that a
/// newer edit or a page that goes away drops the pending one.
///
/// Every one of them runs on ``ManualClock``: a debounce timed against the wall
/// clock measures the run's load as much as the row's pause, and on a loaded
/// runner the check ran before a twenty-millisecond sleep had returned.
@MainActor
final class AssistantCheckDebounceTests: XCTestCase {
    func testABurstOfEditsBecomesOneCheck() async {
        var checks = 0
        let clock = ManualClock()
        let debounce = AssistantCheckDebounce(delay: .milliseconds(40), clock: clock)
        for _ in 0 ..< 5 {
            debounce.schedule { checks += 1 }
        }
        // The check lands one debounce after the last edit. The count is
        // watched for on the clock, so the assertion below is about the burst
        // rather than about the scheduler.
        let ran = await advance(clock, until: { checks >= 1 }, within: .seconds(2))
        XCTAssertTrue(ran, "the burst never sent a check")
        // Three debounces of quiet: if the row ran one check per edit, the four
        // edits the first check did not stand for would land inside this span.
        await advance(clock, by: .milliseconds(120))
        XCTAssertEqual(checks, 1, "a keystroke sent a request of its own")
    }

    func testTheNewestEditIsTheOneThatRuns() async {
        var ran: [String] = []
        let clock = ManualClock()
        let debounce = AssistantCheckDebounce(delay: .milliseconds(40), clock: clock)
        debounce.schedule { ran.append("https://one.example/v1") }
        debounce.schedule { ran.append("https://two.example/v1") }
        let asleep = await clock.waitUntilWaiting(1)
        XCTAssertTrue(asleep, "the newest edit never started its pause")
        let landed = await advance(clock, until: { !ran.isEmpty }, within: .seconds(2))
        XCTAssertTrue(landed, "the newest edit never ran")
        // Three debounces of quiet, so an older edit that was not dropped lands too.
        await advance(clock, by: .milliseconds(120))
        XCTAssertEqual(ran, ["https://two.example/v1"])
    }

    func testCancelDropsThePendingCheck() async {
        var checks = 0
        let clock = ManualClock()
        let debounce = AssistantCheckDebounce(delay: .milliseconds(40), clock: clock)
        debounce.schedule { checks += 1 }
        debounce.cancel()
        await advance(clock, by: .milliseconds(160))
        XCTAssertEqual(checks, 0, "a cancelled page still asked the service")
    }

    func testNothingRunsBeforeTheDelay() async {
        var checks = 0
        let clock = ManualClock()
        let debounce = AssistantCheckDebounce(delay: .milliseconds(80), clock: clock)
        debounce.schedule { checks += 1 }
        let asleep = await clock.waitUntilWaiting(1)
        XCTAssertTrue(asleep, "the check never started its pause")
        await advance(clock, by: .milliseconds(79))
        // The clock releases a due sleep inside `advance`, so a sleep still
        // held here has not woken, whatever the scheduler does next.
        XCTAssertEqual(clock.waiting, 1, "the check did not wait for the typing to stop")
        XCTAssertEqual(checks, 0, "the check did not wait for the typing to stop")
        await advance(clock, by: .milliseconds(1))
        // The clock stays at the deadline: only the main actor is given turns,
        // because a resumed sleep can need more than one to reach the check.
        let ran = await settle(until: { checks >= 1 })
        XCTAssertTrue(ran, "the check did not run at the deadline")
        XCTAssertEqual(checks, 1, "the deadline did not run the check exactly once")
    }

    /// The shipped pause is long enough to swallow a typed word and short
    /// enough that a pasted address is checked while the person is still
    /// looking at the row.
    func testTheShippedDelayIsAPauseRatherThanAKeystroke() {
        XCTAssertGreaterThanOrEqual(AssistantCheckDebounce.defaultDelay, .milliseconds(400))
        XCTAssertLessThanOrEqual(AssistantCheckDebounce.defaultDelay, .milliseconds(1_200))
    }

    /// Moves the clock forward in steps, letting everything it wakes run.
    ///
    /// - Parameters:
    ///   - clock: the clock the debounce sleeps on.
    ///   - duration: how far to move it.
    ///   - step: the largest step, so a resumed check runs before the next one.
    private func advance(
        _ clock: ManualClock,
        by duration: Duration,
        step: Duration = .milliseconds(1)
    ) async {
        var moved = Duration.zero
        while moved < duration {
            let next = min(step, duration - moved)
            await clock.advance(by: next)
            moved += next
        }
    }

    /// Moves the clock forward until a state holds, or gives up after `limit`.
    ///
    /// - Parameters:
    ///   - clock: the clock the debounce sleeps on.
    ///   - predicate: the state the test is waiting for.
    ///   - limit: how much time on the clock to watch for it.
    ///   - step: how far to move the clock between looks.
    /// - Returns: whether the state held before the limit.
    private func advance(
        _ clock: ManualClock,
        until predicate: @MainActor () -> Bool,
        within limit: Duration,
        every step: Duration = .milliseconds(5)
    ) async -> Bool {
        var moved = Duration.zero
        while moved < limit {
            if predicate() { return true }
            await clock.advance(by: step)
            moved += step
        }
        // A woken task can still be on its way to the main actor when the
        // clock budget runs out; give it wall-clock time without moving the clock.
        return await poll(until: predicate, within: .seconds(2))
    }

    /// Waits, without moving the test clock, until a state holds.
    ///
    /// - Parameters:
    ///   - predicate: the state the test is waiting for.
    ///   - limit: the wall-clock time to allow before giving up.
    /// - Returns: whether the state held within the limit.
    private func settle(
        until predicate: @MainActor () -> Bool,
        within limit: Duration = .seconds(2)
    ) async -> Bool {
        await poll(until: predicate, within: limit)
    }
}

/// A clock a test moves by hand.
///
/// A sleep on it suspends until the test advances the clock past the deadline,
/// so what a test proves is the order of the row's moves rather than how fast
/// the machine delivered them. It is `@unchecked Sendable` because its state is
/// behind a lock: `Clock` is read from whichever task is sleeping, and the
/// sleeps here are resumed from the test's own.
final class ManualClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration

    /// A moment on this clock, measured from the zero the test starts at.
    struct Instant: InstantProtocol {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    /// What a sleep found when it reached the clock.
    private enum Verdict {
        case cancelled
        case due
        case waiting
    }

    let minimumResolution: Swift.Duration = .nanoseconds(1)

    private let lock = NSLock()
    private var offset: Swift.Duration = .zero
    private var waiters: [UUID: (deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = [:]

    var now: Instant {
        lock.withLock { Instant(offset: offset) }
    }

    /// The sleeps that are suspended on the clock.
    var waiting: Int {
        lock.withLock { waiters.count }
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let verdict: Verdict = lock.withLock {
                    if Task.isCancelled { return .cancelled }
                    if offset >= deadline.offset { return .due }
                    waiters[id] = (deadline, continuation)
                    return .waiting
                }
                switch verdict {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .due: continuation.resume()
                case .waiting: break
                }
            }
        } onCancel: {
            let cancelled = lock.withLock { waiters.removeValue(forKey: id) }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward, waking every sleep whose deadline has come.
    ///
    /// - Parameter duration: how far to move it.
    func advance(by duration: Swift.Duration) async {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            offset += duration
            let ready = waiters.filter { $0.value.deadline.offset <= offset }
            for key in ready.keys {
                waiters.removeValue(forKey: key)
            }
            return ready.values.map(\.continuation)
        }
        for continuation in due {
            continuation.resume()
        }
        await Task.yield()
    }

    /// Waits until `count` sleeps are suspended on the clock.
    ///
    /// - Parameters:
    ///   - count: how many sleeps the test expects.
    ///   - limit: the wall-clock time to allow before giving up.
    /// - Returns: whether that many sleeps were suspended within the limit.
    @MainActor
    func waitUntilWaiting(_ count: Int = 1, within limit: Swift.Duration = .seconds(2)) async -> Bool {
        await poll(until: { self.waiting >= count }, within: limit)
    }
}

/// Looks for a state until it holds or a wall-clock limit passes.
///
/// A few yields cover the usual case of a task one turn away. After that the
/// main actor sleeps between looks, so a busy runner can schedule the task
/// being waited for instead of losing its core to the loop.
///
/// - Parameters:
///   - predicate: the state to wait for.
///   - limit: the wall-clock time to allow.
/// - Returns: whether the state held within the limit.
@MainActor
private func poll(until predicate: @MainActor () -> Bool, within limit: Duration) async -> Bool {
    let deadline = ContinuousClock.now + limit
    var looks = 0
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        looks += 1
        if looks <= 20 {
            await Task.yield()
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    return predicate()
}
