import AppKit
@testable import Dot
import DotCore
import XCTest

@MainActor
final class SmokeTests: XCTestCase {
    func testTheHudRendersWithTransparentCorners() throws {
        // The installed app is built from this module; the renderer draws the
        // same HUDView that runs on screen. Without its shadow, every pixel
        // outside the rounded rectangle must be fully transparent: it is the
        // guarantee that no second surface can leave a grey edge around the
        // card.
        let bare = try HUDPreview.render(state: .recording, showsShadow: false)
        let inset = Int(HUD.shadowPadding * 2)
        XCTAssertGreaterThan(bare.pixelsWide, inset * 2)
        XCTAssertGreaterThan(bare.pixelsHigh, inset * 2)

        for (x, y) in [(0, 0), (bare.pixelsWide - 1, 0), (0, bare.pixelsHigh - 1), (bare.pixelsWide - 1, bare.pixelsHigh - 1)] {
            let color = try XCTUnwrap(bare.colorAt(x: x, y: y))
            XCTAssertEqual(color.alphaComponent, 0, accuracy: 0.001, "corner (\(x), \(y)) is not transparent")
        }

        // The corner of the card's own bounding box is outside the rounded
        // rectangle, so it is transparent too.
        let corner = try XCTUnwrap(bare.colorAt(x: inset, y: inset))
        XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.001)

        // The middle of the card is opaque.
        let middle = try XCTUnwrap(bare.colorAt(x: bare.pixelsWide / 2, y: bare.pixelsHigh / 2))
        XCTAssertGreaterThan(middle.alphaComponent, 0.9)

        // With the shadow on, the room around the card may only hold the
        // shadow: black, never the grey of a material view.
        let full = try HUDPreview.render(state: .recording, showsShadow: true)
        for (x, y) in [(0, 0), (full.pixelsWide - 1, 0), (0, full.pixelsHigh - 1), (full.pixelsWide - 1, full.pixelsHigh - 1)] {
            let color = try XCTUnwrap(full.colorAt(x: x, y: y))
            XCTAssertLessThan(color.alphaComponent, 0.03)
        }
        let shadowed = try XCTUnwrap(full.colorAt(x: inset, y: inset))
        if shadowed.alphaComponent > 0.001 {
            XCTAssertLessThan(shadowed.redComponent, 0.02, "the shadow is grey, not black")
            XCTAssertEqual(shadowed.redComponent, shadowed.greenComponent, accuracy: 0.01)
            XCTAssertEqual(shadowed.greenComponent, shadowed.blueComponent, accuracy: 0.01)
        }
    }

    func testEveryMenuSectionIsPresent() {
        let state = MenuState(
            isRecording: false,
            recordShortcut: MenuShortcut(display: "⌥⌘D", key: "d", modifiers: [.option, .command]),
            pasteShortcut: MenuShortcut(display: "⌥⌘V", key: "v", modifiers: [.option, .command]),
            history: ["One transcript"],
            microphones: [MenuMicrophone(id: nil, name: "System default")],
            selectedMicrophoneID: nil,
            languages: MenuBuilder.languages,
            selectedLanguage: "auto",
            providers: [
                MenuProvider(
                    presetID: "custom",
                    providerID: ProviderIdentifier.xiaomi,
                    displayName: "api.xiaomimimo.com",
                    needsKey: true,
                    hasKey: false
                ),
            ],
            selectedPresetID: "custom",
            autoPasteEnabled: true,
            launchAtLogin: false
        )
        let titles = MenuBuilder.items(for: state).map(\.title)
        XCTAssertEqual(titles.first, "Start recording")
        XCTAssertTrue(titles.contains("Paste last transcript"))
        XCTAssertTrue(titles.contains("Copy last transcript"))
        XCTAssertTrue(titles.contains("Recent transcripts"))
        XCTAssertTrue(titles.contains("History…"))
        XCTAssertTrue(titles.contains("Microphone"))
        XCTAssertTrue(titles.contains("Language"))
        XCTAssertTrue(titles.contains("Provider"))
        XCTAssertTrue(titles.contains("Auto-paste"))
        XCTAssertTrue(titles.contains("Launch at login"))
        XCTAssertTrue(titles.contains("Welcome to Dot"))
        XCTAssertTrue(titles.contains("Settings…"))
        XCTAssertTrue(titles.contains("About Dot"))
        XCTAssertEqual(titles.last, "Quit Dot")
    }

    func testHistoryFollowsRecentTranscriptsWithTheDisplayShortcut() {
        var state = MenuState(history: ["One transcript"])
        state.providers = [
            MenuProvider(
                presetID: "custom",
                providerID: ProviderIdentifier.xiaomi,
                displayName: "api.xiaomimimo.com",
                needsKey: true,
                hasKey: false
            ),
        ]
        state.selectedPresetID = "custom"
        let items = MenuBuilder.items(for: state)
        let titles = items.map(\.title)

        guard let recent = titles.firstIndex(of: "Recent transcripts"),
              let history = titles.firstIndex(of: "History…"),
              let microphone = titles.firstIndex(of: "Microphone")
        else {
            return XCTFail("the history items are missing")
        }
        XCTAssertEqual(history, recent + 1, "History… must follow Recent Transcripts")
        XCTAssertLessThan(history, microphone, "History… must sit before the next section")
        XCTAssertTrue(items[history + 1].isSeparator, "History… must close its section")

        XCTAssertEqual(items[history].action, .openHistory)
        XCTAssertTrue(items[history].isEnabled, "History opens its own empty state")
        XCTAssertEqual(
            items[history].shortcut,
            MenuShortcut(display: "⌘Y", key: "y", modifiers: .command)
        )
    }

    func testWelcomeSitsNearAboutAndCarriesItsAction() {
        let items = MenuBuilder.items(for: MenuState())
        let titles = items.map(\.title)

        guard let welcome = titles.firstIndex(of: "Welcome to Dot"),
              let settings = titles.firstIndex(of: "Settings…"),
              let about = titles.firstIndex(of: "About Dot"),
              let quit = titles.firstIndex(of: "Quit Dot")
        else {
            return XCTFail("the welcome item is missing")
        }
        XCTAssertEqual(items[welcome].action, .openWelcome)
        XCTAssertEqual(welcome + 1, settings, "Welcome to Dot opens the bottom section")
        XCTAssertLessThan(welcome, about)
        XCTAssertLessThan(about, quit)
    }

    func testHistoryAndWelcomeDispatchThroughTheMenu() {
        _ = NSApplication.shared

        let target = MenuActionTarget()
        var received: [MenuAction] = []
        target.handler = { received.append($0) }
        let menu = MenuBuilder.build(state: MenuState(), target: target)

        for title in ["History…", "Welcome to Dot"] {
            guard let item = menu.items.first(where: { $0.title == title }),
                  let action = item.action
            else {
                return XCTFail("\(title) has no wired action")
            }
            XCTAssertTrue(
                NSApplication.shared.sendAction(action, to: item.target, from: item),
                "AppKit did not send \(title)'s action"
            )
        }

        XCTAssertEqual(received, [.openHistory, .openWelcome])
    }

    func testTheMenuTurnsIntoRealItems() {
        let state = MenuState(
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
        let target = MenuActionTarget()
        let menu = MenuBuilder.build(state: state, target: target)
        XCTAssertEqual(menu.items.first?.title, "Start recording")
        XCTAssertEqual(menu.items.last?.title, "Quit Dot")
        XCTAssertTrue(menu.items.contains { $0.title == "Recent transcripts" && $0.submenu != nil })
        XCTAssertTrue(menu.items.contains { $0.title == "Provider" && $0.submenu != nil })
    }

    func testPickingAMenuItemDeliversItsAction() {
        let state = MenuState()
        var received: MenuAction?
        let target = MenuActionTarget()
        target.handler = { received = $0 }
        let menu = MenuBuilder.build(state: state, target: target)
        guard let item = menu.items.first(where: { $0.title == "Paste last transcript" }) else {
            return XCTFail("the item is missing")
        }
        target.performAction(item)
        XCTAssertEqual(received, .pasteLast)
    }

    func testTheRecordingItemChangesWithTheState() {
        var state = MenuState()
        XCTAssertEqual(MenuBuilder.items(for: state).first?.title, "Start recording")
        state.isRecording = true
        XCTAssertEqual(MenuBuilder.items(for: state).first?.title, "Stop recording")
    }

    func testTheHostedProviderOffersSetAPIKeyInTheMenu() {
        // This is the same MenuProvider snapshot AppDelegate builds from
        // requiresCredential, with no Keychain read: the OpenAI-compatible
        // provider must advertise its key path in the Provider submenu.
        let state = MenuState(
            providers: [
                MenuProvider(
                    presetID: "openai",
                    providerID: ProviderIdentifier.openAI,
                    displayName: "OpenAI",
                    needsKey: true,
                    hasKey: false
                ),
            ],
            selectedPresetID: "openai"
        )
        guard let providerMenu = MenuBuilder.items(for: state)
            .first(where: { $0.title == "Provider" })
        else {
            return XCTFail("the Provider submenu is missing")
        }

        XCTAssertTrue(providerMenu.children.map(\.title).contains("Set API key…"))
        let setKey = providerMenu.children.first { $0.title == "Set API key…" }
        XCTAssertEqual(setKey?.action, .setAPIKey(ProviderIdentifier.openAI))

        let withKey = MenuBuilder.items(for: MenuState(
            providers: [
                MenuProvider(
                    presetID: "openai",
                    providerID: ProviderIdentifier.openAI,
                    displayName: "OpenAI",
                    needsKey: true,
                    hasKey: true
                ),
            ],
            selectedPresetID: "openai"
        ))
        let replace = withKey
            .first { $0.title == "Provider" }?
            .children
            .first { $0.title == "Replace API key…" }
        XCTAssertEqual(replace?.action, .setAPIKey(ProviderIdentifier.openAI))
    }

    func testTheHistoryKeepsTheNewestAndDropsCopies() {
        var items: [String] = []
        items = HistoryStore.adding("one", to: items)
        items = HistoryStore.adding("two", to: items)
        items = HistoryStore.adding("one", to: items)
        XCTAssertEqual(items, ["one", "two"])
        for index in 0..<(HistoryStore.limit + 5) {
            items = HistoryStore.adding("item \(index)", to: items)
        }
        XCTAssertEqual(items.count, HistoryStore.limit)
        XCTAssertEqual(items.first, "item \(HistoryStore.limit + 4)")
    }
}
