import DotCore
import XCTest

@testable import Dot

/// The assistant's shortcut as the app wires it: the collision table and the
/// menu item that shows it.
@MainActor
final class AssistantShortcutTests: XCTestCase {
    func testEveryRoleIsBlockedByTheOtherThree() {
        let config = DotConfig.default
        let roles: [AppDelegate.ShortcutRole] = [.record, .paste, .palette, .assistant]
        for role in roles {
            let others = AppDelegate.otherHotkeys(than: role, config: config)
            XCTAssertEqual(others.count, 3, "\(role) must be blocked by the other three")
            XCTAssertFalse(
                others.contains { $0 == config.assistantHotkey } && role == .assistant,
                "the assistant must not block itself"
            )
        }
        XCTAssertEqual(
            AppDelegate.otherHotkeys(than: .assistant, config: config),
            [config.hotkey, config.pasteHotkey, config.paletteHotkey]
        )
        XCTAssertEqual(
            AppDelegate.otherHotkeys(than: .record, config: config),
            [config.pasteHotkey, config.paletteHotkey, config.assistantHotkey]
        )
    }

    func testTheAssistantRecorderRefusesEveryOtherShortcut() {
        let config = DotConfig.default
        let inUse = AppDelegate.otherHotkeys(than: .assistant, config: config)
        for used in inUse {
            switch HotkeyValidator.validate(
                keyCode: used.keyCode,
                modifiers: used.modifiers,
                inUse: inUse
            ) {
            case .success:
                XCTFail("\(used.label) is taken by another role")
            case .failure(let rejection):
                guard case .alreadyUsed = rejection else {
                    return XCTFail("expected alreadyUsed, got \(rejection)")
                }
            }
        }
    }

    func testTheMenuOffersTheAssistantBesideTheRecorder() {
        var state = MenuState()
        state.recordShortcut = MenuShortcuts.shortcut(for: DotConfig.default.hotkey)
        state.assistantShortcut = MenuShortcuts.shortcut(for: DotConfig.default.assistantHotkey)
        let items = MenuBuilder.items(for: state)

        let record = items.firstIndex { $0.action == .toggleRecording }
        let assistant = items.firstIndex { $0.action == .askAssistant }
        XCTAssertNotNil(record)
        XCTAssertNotNil(assistant)
        XCTAssertEqual(assistant, record.map { $0 + 1 }, "the assistant sits under the recorder")
        let item = assistant.map { items[$0] }
        XCTAssertEqual(item?.title, "Ask the assistant")
        XCTAssertEqual(item?.shortcut, state.assistantShortcut)
        XCTAssertEqual(item?.shortcut?.display, DotConfig.default.assistantHotkey.label)
        XCTAssertEqual(item?.isEnabled, true)
    }

    func testTheMenuShowsNoShortcutWhenTheLabelCannotBeRead() {
        let state = MenuState()
        let item = MenuBuilder.items(for: state).first { $0.action == .askAssistant }
        XCTAssertNil(item?.shortcut, "an unset state draws no shortcut and no wrong one")
    }

    func testTheMenuGreysTheAssistantWhenNothingIsSetUp() {
        var state = MenuState()
        state.assistantUsable = false
        let item = MenuBuilder.items(for: state).first { $0.action == .askAssistant }
        XCTAssertEqual(item?.isEnabled, false, "the item says the key does nothing yet")
        XCTAssertEqual(item?.title, "Ask the assistant", "and stays where the person learned it")
    }
}
