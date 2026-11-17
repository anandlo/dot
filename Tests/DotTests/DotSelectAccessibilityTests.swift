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

    /// A row reads its own name, and the chosen row says it is chosen.
    ///
    /// The row's button is the element VoiceOver reads; the drawing inside it is
    /// ignored, so the two strings it carries are the two decided here.
    func testARowReadsItsNameAndWhetherItIsChosen() {
        let row = DotSelectRow(title: "Ava", detail: "Connected")

        let plain = DotSelectRowDescription(row: row, isSelected: false)
        XCTAssertEqual(plain.label, "Ava", "the row's detail is not part of its name")
        XCTAssertEqual(plain.value, "", "a row that is not chosen says nothing")

        let chosen = DotSelectRowDescription(row: row, isSelected: true)
        XCTAssertEqual(chosen.label, "Ava")
        XCTAssertEqual(chosen.value, "Selected")
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
