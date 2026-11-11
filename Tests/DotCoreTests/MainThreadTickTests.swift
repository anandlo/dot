import Foundation
import XCTest

@testable import DotCore

/// The tick that keeps a per-frame job off the task allocator.
///
/// The key watcher and the recording clock tick sixty and thirty times a
/// second. Wrapping each tick in a `Task` allocated one task per tick, for work
/// that was already on the main thread.
final class MainThreadTickTests: XCTestCase {
    /// A value two threads can look at without racing.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @MainActor
    func testATickOnTheMainThreadRunsBeforeTheCallReturns() {
        let ran = Box()
        MainThreadTick.run { ran.set() }
        XCTAssertTrue(ran.isSet, "a tick that is already on the main thread must run in place")
    }

    func testATickFromAnotherThreadIsHandedToTheMainQueue() {
        let ran = Box()
        let ticked = expectation(description: "the tick ran")
        DispatchQueue.global(qos: .userInitiated).async {
            MainThreadTick.run {
                XCTAssertTrue(Thread.isMainThread)
                ran.set()
                ticked.fulfill()
            }
        }

        wait(for: [ticked], timeout: 5)
        XCTAssertTrue(ran.isSet)
    }
}
