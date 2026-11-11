import XCTest

@testable import DotCore

/// The menu draws its provider rows from the same presets the Settings picker
/// draws.
///
/// These tests exist because the menu once built its rows a second way, from
/// the provider objects themselves: the row that stands for a stored endpoint
/// printed the literal "Custom endpoint" while the picker printed its host, and
/// OpenAI vanished from the menu because the configuration had not filled in
/// its base URL and building the provider failed. One fact, two sources, two
/// answers. The tests pin the single source rather than the two symptoms.
final class MenuProviderRowsTests: XCTestCase {
    // MARK: - The rows

    func testTheMenuOffersExactlyTheRowsThePickerDraws() {
        let config = configuration(provider: ProviderIdentifier.xiaomi)
        let rows = MenuBuilder.providerRows(config: config) { _ in true }
        let presets = ProviderPreset.rows(for: config)

        XCTAssertEqual(rows.map(\.presetID), presets.map(\.id))
        XCTAssertEqual(rows.map(\.displayName), presets.map(\.name))
        XCTAssertEqual(rows.map(\.providerID), presets.map(\.providerID))
    }

    func testAnOwnedEndpointIsNamedByItsHost() {
        let config = configuration(
            provider: ProviderIdentifier.xiaomi,
            baseURL: "https://voice.example.com/v1"
        )
        let rows = MenuBuilder.providerRows(config: config) { _ in true }

        let selected = rows.first { $0.presetID == "custom" }
        XCTAssertEqual(selected?.displayName, "voice.example.com")
        XCTAssertFalse(
            rows.contains { $0.displayName == "Custom endpoint" },
            "the shape of the service is not its name"
        )
    }

    func testAServiceWithNoConfiguredURLStillAppears() {
        var config = configuration(provider: ProviderIdentifier.xiaomi)
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(model: "whisper-1")

        let rows = MenuBuilder.providerRows(config: config) { _ in false }

        XCTAssertTrue(
            rows.contains { $0.displayName == "OpenAI" },
            "a service the app ships disappeared from the menu because its URL is empty"
        )
    }

    func testTheKeyIsLookedUpOncePerProviderAndNeverForApple() {
        let config = configuration(provider: ProviderIdentifier.openAI)
        var asked: [String] = []
        let rows = MenuBuilder.providerRows(config: config) { id in
            asked.append(id)
            return true
        }

        XCTAssertEqual(
            asked.sorted(),
            Set(rows.filter(\.needsKey).map(\.providerID)).sorted(),
            "every row that can need a key asks about it, exactly once"
        )
        XCTAssertFalse(
            asked.contains(ProviderIdentifier.apple),
            "the row that runs on this Mac has no key to look up"
        )
    }

    func testTheRowsCarryTheProviderThatHoldsTheKey() {
        var config = DotConfig.default
        ProviderPreset.groq.apply(to: &config)
        let rows = MenuBuilder.providerRows(config: config) { _ in true }
        let presets = ProviderPreset.rows(for: config)

        for row in rows {
            guard let preset = presets.first(where: { $0.id == row.presetID }) else {
                XCTFail("\(row.presetID) is not a row the picker draws")
                continue
            }
            XCTAssertEqual(row.providerID, preset.providerID)
            XCTAssertEqual(row.needsKey, preset.key != ProviderPreset.KeyRequirement.none)
        }
    }

    // MARK: - The submenu

    func testPickingAServiceCarriesThePresetID() {
        let state = menuState(selected: "groq")
        let items = providerItems(state)

        let groq = items.first { $0.title == "Groq" }
        XCTAssertEqual(groq?.action, .selectPreset("groq"))

        // Groq and OpenAI are both reached through the OpenAI-compatible
        // provider. A pick that carried the provider id could not tell them
        // apart, and would leave the stored endpoint untouched.
        let openAI = items.first { $0.title == "OpenAI" }
        XCTAssertEqual(openAI?.action, .selectPreset("openai"))
    }

    func testTheKeyActionBelongsToTheRowInUse() {
        let items = providerItems(menuState(selected: "groq"))

        let keyRows = items.filter { $0.action?.isKeyAction == true }
        XCTAssertEqual(keyRows.count, 1, "one key action, for the row in use")
        XCTAssertEqual(keyRows.first?.title, "Set API key…")
        XCTAssertEqual(keyRows.first?.action, .setAPIKey(ProviderIdentifier.groq))
    }

    func testTheKeyRowIsSeparatedFromTheServices() {
        let items = providerItems(menuState(selected: "openai"))

        guard let keyIndex = items.firstIndex(where: { $0.action?.isKeyAction == true }),
              keyIndex > 0
        else { return XCTFail("the selected row offers no key action") }

        XCTAssertTrue(
            items[keyIndex - 1].isSeparator,
            "a key action in the same list as the services reads as another service"
        )
    }

    func testARowThatCannotNeedAKeyOffersNoKeyAction() {
        let items = providerItems(menuState(selected: "on-device"))

        XCTAssertFalse(items.contains { $0.action?.isKeyAction == true })
        XCTAssertEqual(items.first { $0.title == "Apple Speech" }?.isOn, true)
    }

    // MARK: - Helpers

    private func configuration(
        provider: String,
        baseURL: String? = nil
    ) -> DotConfig {
        var config = DotConfig.default
        config.provider = provider
        if let baseURL {
            config.providers[provider] = ProviderConfig(baseURL: baseURL)
        }
        return config
    }

    private func menuState(selected presetID: String) -> MenuState {
        var config = DotConfig.default
        ProviderPreset.preset(id: presetID)?.apply(to: &config)
        var state = MenuState()
        state.providers = MenuBuilder.providerRows(config: config) { _ in false }
        state.selectedPresetID = ProviderPreset.presenting(config).id
        return state
    }

    private func providerItems(_ state: MenuState) -> [MenuItem] {
        MenuBuilder.items(for: state)
            .first { $0.title == "Provider" }?
            .children ?? []
    }
}

private extension MenuAction {
    /// Whether the action opens the key prompt.
    var isKeyAction: Bool {
        if case .setAPIKey = self { return true }
        return false
    }
}
