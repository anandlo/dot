import AVFoundation
import XCTest

import DotCore
@testable import Dot

/// A device list is a question to the audio server, and the app may not ask it on
/// the thread a person is waiting on.
///
/// The cache starts filling itself on its own queue from the moment it exists, and
/// a reader only ever takes the last answer: the discovery runs on the queue, and
/// a menu refresh or a settings read never waits for it.
final class MicrophoneCatalogCacheTests: XCTestCase {
    @MainActor
    func testTheFirstReadRunsTheDiscoveryOffTheCallersThread() async {
        let cache = CatalogCache()
        await waitUntilLoaded(cache)

        XCTAssertGreaterThan(
            cache.readCount,
            0,
            "the cache never ran a discovery, so the thread it ran on says nothing"
        )
        XCTAssertFalse(
            cache.didReadOnMainThread,
            "the discovery ran on the thread that read the cache"
        )
    }

    @MainActor
    func testASecondReadDoesNotRunAnotherDiscovery() async {
        let cache = CatalogCache()
        await waitUntilLoaded(cache)
        _ = cache.snapshot()
        _ = cache.snapshot()
        XCTAssertEqual(
            cache.readCount,
            1,
            "a read after the first filled the cache ran the discovery again"
        )
    }

    /// The launch path's menu refresh and the settings device read do not wait
    /// for a first load that is still running.
    @MainActor
    func testTheMenuRefreshAndTheSettingsReadNeverWaitForTheFirstLoad() async {
        // A discovery as slow as an audio server that is busy.
        let slow = CatalogCache(discovery: {
            Thread.sleep(forTimeInterval: 0.5)
            return CatalogCache.Snapshot(
                devices: [MicrophoneDevice(uid: "desk-mic", name: "Desk mic")],
                defaultInputUID: "desk-mic"
            )
        })
        let previous = MicrophoneCatalog.cache
        MicrophoneCatalog.cache = slow
        defer { MicrophoneCatalog.cache = previous }

        let announced = expectation(description: "the first load was announced")
        announced.assertForOverFulfill = true
        let token = NotificationCenter.default.addObserver(
            forName: MicrophoneCatalog.didLoadNotification,
            object: slow,
            queue: .main
        ) { _ in announced.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        // What the menu refresh asks for.
        let menu = elapsed { _ = MicrophoneCatalog.devices() }
        // What the settings window asks for when it shows the device picker.
        let settings = elapsed { _ = MicrophoneCatalog.recordingDeviceUID(configured: nil) }
        print("BENCH catalog menuRead=\(Int(menu))ms settingsRead=\(Int(settings))ms with a 500 ms discovery")

        XCTAssertLessThanOrEqual(menu, 16, "the menu refresh waited \(Int(menu)) ms for the device list")
        XCTAssertLessThanOrEqual(settings, 16, "the settings read waited \(Int(settings)) ms for the device list")
        XCTAssertTrue(
            MicrophoneCatalog.devices().isEmpty,
            "the picker must offer the system default row alone until the list is known"
        )

        await fulfillment(of: [announced], timeout: 5)

        let loaded = slow.snapshot()
        XCTAssertTrue(loaded.isLoaded, "the load was announced before the cache was filled")
        XCTAssertEqual(loaded.devices.map(\.uid), ["desk-mic"])
        XCTAssertEqual(slow.readCount, 1, "the first load ran more than once")
        XCTAssertEqual(
            MicrophoneCatalog.recordingDeviceUID(configured: nil),
            "desk-mic",
            "the reader did not see the devices the announcement was for"
        )
    }

    @MainActor
    private func elapsed(_ work: () -> Void) -> Double {
        let before = CACurrentMediaTime()
        work()
        return (CACurrentMediaTime() - before) * 1000
    }

    @MainActor
    private func waitUntilLoaded(_ cache: CatalogCache, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cache.snapshot().isLoaded, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(cache.snapshot().isLoaded, "the cache never finished its first load")
    }
}
