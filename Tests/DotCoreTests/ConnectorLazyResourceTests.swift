import Foundation
import XCTest

@testable import DotCore

/// A framework object that is built on first use and dropped when idle.
///
/// Every connector adapter relies on this: a dictation-only session must not
/// open `eventd` or `contactsd`, and one reminder read must not keep either
/// connection open all day.
final class ConnectorLazyResourceTests: XCTestCase {
    func testAValueIsNotBuiltUntilItIsNeeded() async {
        let counter = BuildCounter()
        let resource = LazyResource<Int>(idle: .seconds(60)) {
            counter.increment()
            return 1
        }
        XCTAssertFalse(resource.isLoaded)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(resource.acquire(), 1)
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(resource.isLoaded)
    }

    func testTheValueIsBuiltOnceForRepeatedUse() async {
        let counter = BuildCounter()
        let resource = LazyResource<Int>(idle: .seconds(60)) {
            counter.increment()
            return 2
        }
        _ = resource.acquire()
        _ = resource.acquire()
        _ = resource.acquire()
        XCTAssertEqual(counter.count, 1)
    }

    func testTheValueIsReleasedAfterItHasBeenIdle() async throws {
        let counter = BuildCounter()
        let disposal = BuildCounter()
        let resource = LazyResource<Int>(
            idle: .milliseconds(40),
            make: {
                counter.increment()
                return 3
            },
            dispose: { _ in disposal.increment() }
        )
        XCTAssertEqual(resource.acquire(), 3)
        try await waitUntilReleased(resource)
        XCTAssertFalse(resource.isLoaded, "An idle resource must be dropped")
        XCTAssertEqual(disposal.count, 1)
        XCTAssertEqual(resource.acquire(), 3)
        XCTAssertEqual(counter.count, 2, "A dropped resource is built again on the next use")
    }

    func testUseKeepsTheValueAliveAcrossTheIdleWindow() async throws {
        let counter = BuildCounter()
        let resource = LazyResource<Int>(idle: .milliseconds(80)) {
            counter.increment()
            return 4
        }
        _ = resource.acquire()
        try await Task.sleep(for: .milliseconds(40))
        _ = resource.acquire()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(resource.isLoaded, "A resource used again inside the window must survive")
        XCTAssertEqual(counter.count, 1)
    }

    /// Waits for the release task, rather than assuming a machine is idle.
    private func waitUntilReleased(_ resource: LazyResource<Int>) async throws {
        for _ in 0..<100 {
            if !resource.isLoaded { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testReleaseDropsImmediately() {
        let disposal = BuildCounter()
        let resource = LazyResource<Int>(idle: .seconds(60), make: { 5 }, dispose: { _ in disposal.increment() })
        _ = resource.acquire()
        resource.release()
        XCTAssertFalse(resource.isLoaded)
        XCTAssertEqual(disposal.count, 1)
    }
}

/// Counts builds and disposals from the detached tasks that schedule them.
private final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}
