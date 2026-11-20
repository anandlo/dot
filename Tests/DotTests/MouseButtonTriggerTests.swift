import CoreGraphics
import XCTest

@testable import Dot
@testable import DotCore

/// The trigger's two promises: it answers only the button it was given, and a
/// tap macOS could not build waits for the grant instead of giving up.
final class MouseButtonTriggerTests: XCTestCase {
    private func decide(
        _ type: CGEventType,
        button: Int64,
        _ configured: MouseTriggerButton
    ) -> MouseButtonTrigger.Decision {
        MouseButtonTrigger.decision(for: type, eventButton: button, configured: configured)
    }

    func testTheAssignedButtonIsAPressAndARelease() {
        XCTAssertEqual(decide(.otherMouseDown, button: 3, .back), .press)
        XCTAssertEqual(decide(.otherMouseUp, button: 3, .back), .release)
        XCTAssertEqual(decide(.otherMouseDown, button: 2, .middle), .press)
        XCTAssertEqual(decide(.otherMouseUp, button: 4, .forward), .release)
    }

    /// Every button Dot was not given keeps doing what it did: Back still goes
    /// back while Forward is the one that records.
    func testEveryOtherButtonPassesThrough() {
        XCTAssertEqual(decide(.otherMouseDown, button: 4, .back), .pass)
        XCTAssertEqual(decide(.otherMouseUp, button: 2, .back), .pass)
        XCTAssertEqual(decide(.otherMouseDown, button: 3, .off), .pass)
        XCTAssertEqual(decide(.otherMouseUp, button: 3, .off), .pass)
    }

    /// A drag with the assigned button, or any primary click, is not an edge.
    func testOtherEventTypesPassThrough() {
        XCTAssertEqual(decide(.otherMouseDragged, button: 3, .back), .pass)
        XCTAssertEqual(decide(.leftMouseDown, button: 0, .back), .pass)
        XCTAssertEqual(decide(.rightMouseUp, button: 1, .back), .pass)
    }

    /// macOS turns a tap off when it answers too slowly or input is being
    /// protected; the tap has to turn itself back on, or a release is lost and
    /// the take never ends.
    func testADisabledTapIsReenabled() {
        XCTAssertEqual(decide(.tapDisabledByTimeout, button: 0, .back), .reenable)
        XCTAssertEqual(decide(.tapDisabledByUserInput, button: 0, .forward), .reenable)
    }

    @MainActor
    func testAFailedTapWaitsForThePermissionUntilStopped() {
        let trigger = MouseButtonTrigger()
        trigger.createTap = { _ in nil }
        XCTAssertFalse(trigger.start(button: .forward))
        XCTAssertTrue(trigger.isWaitingForPermission)
        trigger.stop()
        XCTAssertFalse(trigger.isWaitingForPermission)
    }

    @MainActor
    func testOffNeverWaits() {
        let trigger = MouseButtonTrigger()
        trigger.createTap = { _ in nil }
        XCTAssertTrue(trigger.start(button: .off))
        XCTAssertFalse(trigger.isWaitingForPermission)
    }
}
