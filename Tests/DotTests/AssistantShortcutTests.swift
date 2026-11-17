import DotCore
import XCTest

@testable import Dot

/// The assistant's shortcut as the app still wires it: the collision table, and
/// the menu that no longer shows it.
@MainActor
final class AssistantShortcutTests: XCTestCase {
    /// Only the three active shortcuts block each other.
    ///
    /// The assistant's saved chord is not registered, so it must not refuse a
    /// new dictation shortcut: otherwise the combination would be unusable in
    /// Dot for a feature Dot no longer has.
    func testTheActiveRolesAreBlockedByEachOtherAndNotByTheAssistant() {
        let config = DotConfig.default
        let active: [AppDelegate.ShortcutRole] = [.record, .paste, .palette]
        for role in active {
            let others = AppDelegate.otherHotkeys(than: role, config: config)
            XCTAssertEqual(others.count, 2, "\(role) must be blocked by the other two")
            XCTAssertFalse(
                others.contains(config.assistantHotkey),
                "\(role) is still blocked by the retired assistant chord"
            )
        }
        XCTAssertEqual(
            AppDelegate.otherHotkeys(than: .assistant, config: config),
            [config.hotkey, config.pasteHotkey, config.paletteHotkey],
            "the retired role may still record any chord, including one of the three"
        )
        XCTAssertEqual(
            AppDelegate.otherHotkeys(than: .record, config: config),
            [config.pasteHotkey, config.paletteHotkey]
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

    /// The product has no spoken assistant, so the menu offers no item that
    /// starts one, whatever the configuration says.
    ///
    /// The action, the state's shortcut and the recorded hotkey stay in place:
    /// removing the item must not remove the key a person already recorded, and
    /// the runtime can stop honouring it on its own.
    func testTheMenuOffersNoAssistantItem() {
        var state = MenuState()
        state.assistantShortcut = MenuShortcuts.shortcut(for: DotConfig.default.assistantHotkey)
        state.assistantUsable = true
        let items = MenuBuilder.items(for: state)

        XCTAssertNil(
            items.first { $0.action == .askAssistant },
            "the menu still offers the assistant"
        )
        XCTAssertFalse(
            flatten(items).contains { $0.title == "Ask the assistant" },
            "the assistant's item is still somewhere in the menu"
        )
        XCTAssertEqual(items.first?.action, .toggleRecording, "the recorder is still the first item")
    }

    /// A state that used to enable or disable the item no longer changes the
    /// menu at all: the item is simply not there.
    func testTheAssistantStateDoesNotChangeTheMenu() {
        var ready = MenuState()
        ready.assistantUsable = true
        ready.assistantShortcut = MenuShortcuts.shortcut(for: DotConfig.default.assistantHotkey)

        var unfinished = MenuState()
        unfinished.assistantUsable = false

        XCTAssertEqual(MenuBuilder.items(for: ready), MenuBuilder.items(for: unfinished))
    }

    /// The saved assistant chord is preserved and no longer blocks anything.
    func testTheAssistantKeyIsPreservedAndDoesNotBlockTheActiveShortcuts() {
        let config = DotConfig.default
        XCTAssertEqual(config.assistantHotkey, Hotkey.defaultAssistant)
        for role in [AppDelegate.ShortcutRole.record, .paste, .palette] {
            XCTAssertFalse(
                AppDelegate.otherHotkeys(than: role, config: config)
                    .contains(config.assistantHotkey),
                "the retired assistant chord still blocks \(role)"
            )
        }
    }

    /// The menu tree, flattened so a title cannot hide in a submenu.
    private func flatten(_ items: [MenuItem]) -> [MenuItem] {
        items.flatMap { [$0] + flatten($0.children) }
    }
}
