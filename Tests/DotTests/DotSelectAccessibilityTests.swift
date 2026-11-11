import AppKit
import XCTest

@testable import Dot

/// The trigger's accessibility element.
///
/// The trigger is a drawing, not a platform control, so the one `NSView` behind
/// it carries the role VoiceOver reads: a pop-up button with the label of the
/// setting and the title of the current row.
@MainActor
final class DotSelectAccessibilityTests: XCTestCase {
    func testTheTriggerReadsAsAPopUpButtonWithItsLabelAndValue() {
        var opened = false
        let view = DotSelectAccessibilityView()
        view.apply(label: "Service", value: "OpenAI", isEnabled: true) {
            opened = true
        }

        XCTAssertEqual(view.accessibilityRole(), .popUpButton)
        XCTAssertEqual(view.accessibilityLabel(), "Service")
        XCTAssertEqual(view.accessibilityValue() as? String, "OpenAI")
        XCTAssertTrue(view.isAccessibilityEnabled())
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertTrue(opened)
    }

    func testADisabledTriggerDoesNotPress() {
        var opened = false
        let view = DotSelectAccessibilityView()
        view.apply(label: "Model", value: "No model", isEnabled: false) {
            opened = true
        }

        XCTAssertFalse(view.isAccessibilityEnabled())
        XCTAssertFalse(view.accessibilityPerformPress(), "a disabled pop-up cannot be pressed")
        XCTAssertFalse(opened)
        XCTAssertNil(view.hitTest(.zero), "the element never takes a click")
    }
}
