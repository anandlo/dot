import AppKit
import DotCore
import XCTest

/// Proves that the menu's AppKit target/action wiring is live.
///
/// The menu is data first (`MenuBuilder.items(for:)`) and an `NSMenu` second. A
/// test that calls `MenuActionTarget.performAction(_:)` directly only exercises
/// the handler; it cannot catch a missing `@objc`, the wrong selector, a nil target,
/// or a target that died because nothing retained it. These tests send the
/// selector stored on the item through AppKit instead, which is the path a menu
/// tracking session uses when the user picks an item.
@MainActor
final class MenuActionTests: XCTestCase {
    func testEveryActionItemCarriesTheSameLiveTarget() {
        let target = MenuActionTarget()
        let menu = MenuBuilder.build(state: makeState(), target: target)
        let items = menu.allActionItems

        XCTAssertFalse(items.isEmpty, "the menu has no action items")
        for item in items {
            guard let action = item.action else {
                XCTFail("\(item.title) has an action item without a selector")
                continue
            }
            XCTAssertNotEqual(
                NSStringFromSelector(action),
                "performSelector:",
                "\(item.title) points at NSObject's perform(_:) instead of the target's action method"
            )
            XCTAssertTrue(item.target === target, "\(item.title) points at another target")
            XCTAssertTrue(
                target.responds(to: action),
                "the target does not respond to \(item.title)'s action"
            )
        }
    }

    func testSendActionDispatchesTopLevelActions() {
        let target = MenuActionTarget()
        var received: [MenuAction] = []
        target.handler = { received.append($0) }
        let menu = MenuBuilder.build(state: makeState(), target: target)

        let expected: [(title: String, action: MenuAction)] = [
            ("Start recording", .toggleRecording),
            ("Paste last transcript", .pasteLast),
            ("Copy last transcript", .copyLast),
            ("Auto-paste", .toggleAutoPaste),
            ("Launch at login", .toggleLaunchAtLogin),
            ("Settings…", .openSettings),
            ("Open log in Finder", .openLog),
            ("Check for updates…", .checkForUpdates),
            ("About Dot", .showAbout),
            ("Quit Dot", .quit),
        ]

        for entry in expected {
            guard let item = menu.items.first(where: { $0.title == entry.title }) else {
                XCTFail("the menu has no \(entry.title) item")
                continue
            }
            guard let action = item.action else {
                XCTFail("\(entry.title) has no action")
                continue
            }
            XCTAssertTrue(
                NSApplication.shared.sendAction(action, to: item.target, from: item),
                "AppKit did not send \(entry.title)'s action"
            )
        }

        XCTAssertEqual(received, expected.map(\.action))
    }

    func testPerformActionForItemDispatchesThroughTheMenu() {
        // NSMenu sends actions through the application object; without an
        // NSApplication instance this call silently does nothing.
        _ = NSApplication.shared

        let target = MenuActionTarget()
        var received: MenuAction?
        target.handler = { received = $0 }
        let menu = MenuBuilder.build(state: makeState(), target: target)
        guard let index = menu.items.firstIndex(where: { $0.title == "Paste last transcript" }) else {
            return XCTFail("the Paste Last Transcript item is missing")
        }

        menu.performActionForItem(at: index)

        XCTAssertEqual(received, .pasteLast)
    }

    func testSendActionCarriesTheHistoryPayloadFromASubmenu() {
        let target = MenuActionTarget()
        var received: MenuAction?
        target.handler = { received = $0 }
        let menu = MenuBuilder.build(state: makeState(), target: target)
        guard let recent = menu.items.first(where: { $0.title == "Recent transcripts" }),
              let submenu = recent.submenu,
              let transcript = submenu.items.first(where: { $0.title == "The meeting is at four." }),
              let action = transcript.action
        else {
            return XCTFail("the history submenu is not wired")
        }

        XCTAssertTrue(
            NSApplication.shared.sendAction(action, to: transcript.target, from: transcript)
        )
        XCTAssertEqual(received, .copyHistory("The meeting is at four."))
    }

    func testControllerStyleOwnershipKeepsTheTargetAliveForTheMenu() {
        var menu: NSMenu?
        weak var weakTarget: MenuActionTarget?

        autoreleasepool {
            var owner: MenuOwner? = MenuOwner(state: makeState())
            weakTarget = owner?.target
            menu = owner?.menu

            XCTAssertNotNil(weakTarget)
            XCTAssertFalse(menu?.allActionItems.isEmpty ?? true)
            for item in menu?.allActionItems ?? [] {
                XCTAssertTrue(item.target === owner?.target, "\(item.title) lost its target")
            }

            owner = nil
        }

        withExtendedLifetime(menu) {
            XCTAssertNil(
                weakTarget,
                "the menu does not own its target; StatusItemController's strong reference does"
            )
        }
    }

    private func makeState() -> MenuState {
        MenuState(
            history: ["The meeting is at four."],
            providers: [
                MenuProvider(
                    presetID: "custom",
                    providerID: ProviderIdentifier.xiaomi,
                    displayName: "api.xiaomimimo.com",
                    needsKey: true,
                    hasKey: false
                ),
            ],
            selectedPresetID: "custom"
        )
    }
}

/// Mirrors the ownership `StatusItemController` provides: it owns the target for
/// as long as the menu is in use. `StatusItemController` itself cannot be
/// instantiated in a test without creating a status bar item.
private final class MenuOwner {
    let target = MenuActionTarget()
    let menu: NSMenu

    init(state: MenuState) {
        menu = MenuBuilder.build(state: state, target: target)
    }
}

private extension NSMenu {
    /// The items the builder gave an action, including submenu leaves.
    ///
    /// AppKit assigns its own `submenuAction:` selector to items that only open
    /// a submenu, so those parents are not part of the builder's action wiring.
    var allActionItems: [NSMenuItem] {
        items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu {
                return submenu.allActionItems
            }
            return item.action == nil ? [] : [item]
        }
    }
}
