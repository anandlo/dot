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
                "The mouse button needs this permission to be heard."
            )
        }
    }

    func testBoth() {
        for button in [MouseTriggerButton.back, .middle] {
            XCTAssertEqual(
                SettingsView.accessibilityReason(autoPaste: true, mouseButton: button),
                "Pasting and the mouse button need this permission."
            )
        }
    }
}
