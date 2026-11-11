import XCTest

@testable import DotCore

/// The assistant's shortcut, and the identifiers the Carbon manager registers.
///
/// The combination is a default like the other three: `⌥⌘A`, the recorder's
/// modifier pair on the first letter of the verb. The identifier is the fifth,
/// because a value outside ``GlobalHotkeyManager/identifiers`` is a key nothing
/// answers.
final class HotkeyTests: XCTestCase {
    func testTheAssistantShortcutIsTheShippedCombination() {
        let hotkey = Hotkey.defaultAssistant
        XCTAssertEqual(hotkey.keyCode, 0, "kVK_ANSI_A")
        XCTAssertEqual(hotkey.modifiers, HotkeyModifiers.mask(.option, .command))
        XCTAssertEqual(hotkey.ansiKeyCode, 0)
        XCTAssertEqual(
            hotkey.label,
            Hotkey.makeLabel(keyCode: 0, modifiers: HotkeyModifiers.mask(.option, .command)),
            "the label is derived, never written by hand"
        )
        XCTAssertEqual(hotkey.spelledOut, "Option Command A")
    }

    func testTheAssistantIdentifierIsRegistered() {
        XCTAssertEqual(GlobalHotkeyManager.assistantIdentifier, 5)
        XCTAssertTrue(GlobalHotkeyManager.identifiers.contains(GlobalHotkeyManager.assistantIdentifier))
        XCTAssertEqual(GlobalHotkeyManager.identifiers.count, 5)
    }

    func testTheFourShortcutsAreAllDifferent() {
        let all: Set<Hotkey> = [
            Hotkey.defaultRecord,
            Hotkey.defaultPaste,
            Hotkey.defaultPalette,
            Hotkey.defaultAssistant,
        ]
        XCTAssertEqual(all.count, 4)
    }

    func testTheAssistantShortcutIsAccepted() {
        switch HotkeyValidator.validate(
            keyCode: 0,
            modifiers: HotkeyModifiers.mask(.option, .command),
            typed: "a",
            ansiKeyCode: 0
        ) {
        case .success(let hotkey):
            XCTAssertEqual(hotkey.label, Hotkey.defaultAssistant.label)
        case .failure(let rejection):
            XCTFail("the assistant shortcut must be accepted: \(rejection)")
        }
    }

    func testTheAssistantCombinationIsRefusedWhenItIsInUse() {
        switch HotkeyValidator.validate(
            keyCode: 0,
            modifiers: HotkeyModifiers.mask(.option, .command),
            typed: "a",
            inUse: [Hotkey.defaultAssistant]
        ) {
        case .success:
            XCTFail("the assistant shortcut is taken")
        case .failure(let rejection):
            guard case .alreadyUsed = rejection else {
                return XCTFail("expected alreadyUsed, got \(rejection)")
            }
        }
    }
}
