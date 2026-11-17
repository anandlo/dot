import DotCore
import XCTest

@testable import Dot

/// The wait between an edit and the models request it causes.
///
/// An address is typed a character at a time, and the record changes with every
/// character. These tests prove the row sends one check for a burst, and that a
/// newer edit or a page that goes away drops the pending one.
@MainActor
final class AssistantCheckDebounceTests: XCTestCase {
    func testABurstOfEditsBecomesOneCheck() async {
        var checks = 0
        let debounce = AssistantCheckDebounce(delay: .milliseconds(40))
        for _ in 0 ..< 5 {
            debounce.schedule { checks += 1 }
        }
        // The check lands one debounce after the last edit, and the suite shares
        // the main actor: a fixed sleep here measured the run's load as much as
        // the row's delay. The count is watched for instead, so the assertion
        // below is about the burst rather than about the scheduler.
        let ran = await waitFor(until: { checks >= 1 }, within: .seconds(2))
        XCTAssertTrue(ran, "the burst never sent a check")
        // Three debounces of quiet: if the row ran one check per edit, the four
        // edits the first check did not stand for would land inside this span.
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(checks, 1, "a keystroke sent a request of its own")
    }

    func testTheNewestEditIsTheOneThatRuns() async {
        var value = ""
        let debounce = AssistantCheckDebounce(delay: .milliseconds(40))
        debounce.schedule { value = "https://one.example/v1" }
        debounce.schedule { value = "https://two.example/v1" }
        try? await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(value, "https://two.example/v1")
    }

    func testCancelDropsThePendingCheck() async {
        var checks = 0
        let debounce = AssistantCheckDebounce(delay: .milliseconds(40))
        debounce.schedule { checks += 1 }
        debounce.cancel()
        try? await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(checks, 0, "a cancelled page still asked the service")
    }

    func testNothingRunsBeforeTheDelay() async {
        var checks = 0
        let debounce = AssistantCheckDebounce(delay: .milliseconds(80))
        debounce.schedule { checks += 1 }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(checks, 0, "the check did not wait for the typing to stop")
        try? await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(checks, 1)
    }

    /// The shipped pause is long enough to swallow a typed word and short
    /// enough that a pasted address is checked while the person is still
    /// looking at the row.
    func testTheShippedDelayIsAPauseRatherThanAKeystroke() {
        XCTAssertGreaterThanOrEqual(AssistantCheckDebounce.defaultDelay, .milliseconds(400))
        XCTAssertLessThanOrEqual(AssistantCheckDebounce.defaultDelay, .milliseconds(1_200))
    }

    /// Waits for a state to hold, or gives up after `limit`.
    ///
    /// - Parameters:
    ///   - predicate: the state the test is waiting for.
    ///   - limit: how long to watch for it.
    ///   - step: how long to wait between looks.
    /// - Returns: whether the state held before the limit.
    private func waitFor(
        until predicate: @MainActor () -> Bool,
        within limit: Duration,
        every step: Duration = .milliseconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: step)
        }
        return predicate()
    }
}
