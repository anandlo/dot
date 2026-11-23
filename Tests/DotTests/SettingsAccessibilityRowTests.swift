import XCTest

@testable import Dot
@testable import DotCore

/// The single Accessibility row that the Settings page shows.
final class SettingsAccessibilityRowTests: XCTestCase {
    func testNeitherNeedReturnsNil() {
        XCTAssertNil(SettingsView.accessibilityReason(autoPaste: false, mouseButton: .off))
    }

    func testAutoPasteOnly() {
        XCTAssertEqual(
            SettingsView.accessibilityReason(autoPaste: true, mouseButton: .off),
            "Pasting into another app needs this permission."
        )
    }

    func testMouseOnly() {
        for button in [MouseTriggerButton.back, .middle] {
            XCTAssertEqual(
                SettingsView.accessibilityReason(autoPaste: false, mouseButton: button),
                "Recording with a mouse button needs this permission."
            )
        }
    }

    func testBoth() {
        for button in [MouseTriggerButton.back, .middle] {
            XCTAssertEqual(
                SettingsView.accessibilityReason(autoPaste: true, mouseButton: button),
                "Pasting and recording with a mouse button need this permission."
            )
        }
    }
}
