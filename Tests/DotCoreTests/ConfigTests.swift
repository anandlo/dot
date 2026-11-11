import XCTest

@testable import DotCore

final class ConfigTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaults() {
        let config = DotConfig.default
        XCTAssertEqual(config.provider, "openai")
        XCTAssertEqual(config.hotkey, Hotkey.defaultRecord)
        XCTAssertEqual(config.hotkey.label, "⌥⌘D")
        XCTAssertEqual(config.hotkey.keyCode, 2) // kVK_ANSI_D
        XCTAssertEqual(config.hotkey.modifiers, HotkeyModifiers.mask(.option, .command))
        XCTAssertEqual(config.pasteHotkey.label, "⌥⌘V")
        XCTAssertTrue(config.autoPaste)
        XCTAssertEqual(config.hudDwellSeconds, HUDDwell.defaultSeconds)
        XCTAssertEqual(config.hudDwellRevision, HUDDwell.revision)
        XCTAssertEqual(config.maxSegmentSeconds, 30)
        XCTAssertNil(config.microphoneDeviceUID)
        XCTAssertFalse(config.logTranscripts)
        XCTAssertEqual(config.hudMaterial, .glass)
        XCTAssertEqual(config.appearance, .system)
        XCTAssertEqual(config.hudVisualizer, .stretch)
    }

    func testTheDefaultShortcutDoesNotClashWithScrawl() {
        // Scrawl records with ⌥⇧S; Dot uses ⌥⌘D.
        XCTAssertNotEqual(
            Hotkey.defaultRecord,
            Hotkey(keyCode: 1, modifiers: HotkeyModifiers.mask(.option, .shift), label: "⌥⇧S")
        )
    }

    func testNoProviderHasAModelHardcodedInTheSource() {
        // Models are discovered dynamically from API keys rather than being hardcoded.
        XCTAssertNil(DotConfig.default.settings(for: "retired-provider").model)
        XCTAssertNil(DotConfig.default.settings(for: "openai").model)
        XCTAssertNil(DotConfig.default.settings(for: "xiaomi").model)
        XCTAssertNil(DotConfig.default.settings(for: "apple").model)
    }

    func testTheConfigHasTheShapeTheSpecDescribes() throws {
        var config = DotConfig.default
        config.provider = "openai"
        config.providers["openai"] = ProviderConfig(
            model: "whisper-1",
            baseURL: "https://api.openai.com/v1"
        )
        let url = directory.appendingPathComponent("config.json")
        try config.save(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(payload["provider"] as? String, "openai")
        XCTAssertNotNil(payload["providers"])
        XCTAssertNotNil(payload["hotkey"])
        XCTAssertNotNil(payload["autoPaste"])
        XCTAssertNotNil(payload["hudDwellSeconds"])
        XCTAssertEqual(payload["hudDwellRevision"] as? Int, HUDDwell.revision)
        XCTAssertEqual(payload["maxSegmentSeconds"] as? Int, 30)
        XCTAssertEqual(payload["appearance"] as? String, "system")

        let providers = try XCTUnwrap(payload["providers"] as? [String: Any])
        let openai = try XCTUnwrap(providers["openai"] as? [String: Any])
        XCTAssertEqual(openai["baseURL"] as? String, "https://api.openai.com/v1")
        XCTAssertEqual(openai["model"] as? String, "whisper-1")
        // The provider that needs no settings has an empty object.
        let apple = try XCTUnwrap(providers["apple"] as? [String: Any])
        XCTAssertTrue(apple.isEmpty)
    }

    func testTheAuthStyleRoundTripsAndIsAbsentByDefault() throws {
        var config = DotConfig.default
        config.providers["openai"] = ProviderConfig(
            model: "whisper-1",
            baseURL: "http://127.0.0.1:8765/v1",
            authStyle: .apiKey
        )
        let url = directory.appendingPathComponent("config.json")
        try config.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"authStyle\" : \"api-key\""), text)

        let loaded = DotConfig.load(from: url)
        XCTAssertEqual(loaded.settings(for: "openai").authStyle, .apiKey)

        // A configuration that never chose one writes no field at all, so the
        // file a fresh install produces is unchanged.
        var plain = DotConfig.default
        plain.providers["openai"] = ProviderConfig(model: "whisper-1", baseURL: "https://api.openai.com/v1")
        let plainURL = directory.appendingPathComponent("plain.json")
        try plain.save(to: plainURL)
        let plainText = try String(contentsOf: plainURL, encoding: .utf8)
        XCTAssertFalse(plainText.contains("authStyle"), plainText)
        XCTAssertEqual(DotConfig.load(from: plainURL).settings(for: "openai").authStyle, nil)
    }

    func testRoundTrip() throws {
        var config = DotConfig.default
        config.hotkey = Hotkey(keyCode: 37, modifiers: HotkeyModifiers.mask(.control, .shift), label: "⌃⇧J")
        config.pasteHotkey = Hotkey(keyCode: 38, modifiers: HotkeyModifiers.mask(.command), label: "⌘'")
        config.autoPaste = false
        config.hudDwellSeconds = 7
        config.maxSegmentSeconds = 15
        config.provider = "openai"
        config.providers["openai"] = ProviderConfig(model: "whisper-1", baseURL: "http://127.0.0.1:1234/v1")
        config.microphoneDeviceUID = "device-1234"
        config.logTranscripts = true
        config.hudMaterial = .black
        config.appearance = .dark
        config.hudVisualizer = .filament

        let url = directory.appendingPathComponent("config.json")
        try config.save(to: url)
        let loaded = DotConfig.load(from: url)
        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.appearance, .dark)
        XCTAssertEqual(loaded.hudVisualizer, .filament)
    }

    func testVisualizerRoundTrip() throws {
        for visualizer in HUDVisualizer.allCases {
            var config = DotConfig.default
            config.hudVisualizer = visualizer
            let url = directory.appendingPathComponent("vis-\(visualizer.rawValue).json")
            try config.save(to: url)
            let loaded = DotConfig.load(from: url)
            XCTAssertEqual(loaded.hudVisualizer, visualizer)
        }
    }

    func testAMissingFileGivesTheDefaults() {
        let url = directory.appendingPathComponent("missing.json")
        XCTAssertEqual(DotConfig.load(from: url), .default)
    }

    func testABrokenFileGivesTheDefaults() throws {
        let url = directory.appendingPathComponent("config.json")
        try "{ this is not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(DotConfig.load(from: url), .default)
    }

    func testAPartialFileKeepsTheOtherDefaults() throws {
        let url = directory.appendingPathComponent("config.json")
        try #"{"autoPaste": false}"#.write(to: url, atomically: true, encoding: .utf8)
        let loaded = DotConfig.load(from: url)
        XCTAssertFalse(loaded.autoPaste)
        XCTAssertEqual(loaded.hotkey, Hotkey.defaultRecord)
        XCTAssertEqual(loaded.maxSegmentSeconds, 30)
        XCTAssertEqual(loaded.provider, "openai")
        XCTAssertEqual(loaded.appearance, .system)
    }

    func testAMissingAppearanceFallsBackToSystem() throws {
        let url = directory.appendingPathComponent("config.json")
        try #"{"provider": "openai", "appearance": null}"#.write(to: url, atomically: true, encoding: .utf8)
        let loaded = DotConfig.load(from: url)
        XCTAssertEqual(loaded.provider, "openai")
        XCTAssertEqual(loaded.appearance, .system)
    }

    func testTheAppearanceIsWrittenAsItsName() throws {
        var config = DotConfig.default
        config.appearance = .light
        let url = directory.appendingPathComponent("config.json")
        try config.save(to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(payload["appearance"] as? String, "light")
    }

    func testTheSettingsOfAnUnknownProviderAreEmpty() {
        let settings = DotConfig.default.settings(for: "does-not-exist")
        XCTAssertEqual(settings, ProviderConfig())
    }

    func testAConfigurationThatNamesARetiredProviderIsNotWritten() {
        // The file is the record of what the next launch builds, so an id
        // nothing can build must never reach it, not even by accident.
        var config = DotConfig.default
        config.provider = ProviderIdentifier.bridge
        let url = directory.appendingPathComponent("config.json")

        XCTAssertThrowsError(try config.save(to: url)) { error in
            XCTAssertEqual(error as? ConfigError, .retiredProvider(ProviderIdentifier.bridge))
            XCTAssertEqual(
                (error as? ConfigError)?.errorDescription,
                "The configuration cannot be saved: there is no provider called 'bridge'."
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "a refused save writes nothing"
        )
    }

    func testEveryProviderTheConfigurationCanSelectIsOneDotShips() {
        for id in ProviderRegistry.builtInIDs {
            var config = DotConfig.default
            config.provider = id
            XCTAssertNoThrow(try config.save(to: directory.appendingPathComponent("\(id).json")), id)
        }
    }

    func testHotkeyEncodingAndDecoding() throws {
        let hotkey = Hotkey(keyCode: 2, modifiers: HotkeyModifiers.mask(.option, .command), label: "⌥⌘D")
        let data = try JSONEncoder().encode(hotkey)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: data)
        XCTAssertEqual(decoded, hotkey)
        XCTAssertEqual(decoded.keyCode, 2)
        XCTAssertEqual(decoded.modifiers, 2048 | 256)
        XCTAssertEqual(decoded.label, "⌥⌘D")
    }

    func testTheANSIAliasIsKeptWhenThereIsOne() throws {
        let hotkey = Hotkey(
            keyCode: 2,
            modifiers: HotkeyModifiers.mask(.option, .command),
            label: "⌥⌘D",
            ansiKeyCode: 2
        )
        let data = try JSONEncoder().encode(hotkey)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: data)
        XCTAssertEqual(decoded.ansiKeyCode, 2)
    }

    func testLabelsAreBuiltFromTheModifiers() {
        XCTAssertEqual(
            Hotkey.makeLabel(keyCode: 2, modifiers: HotkeyModifiers.mask(.option, .command)),
            "⌥⌘D"
        )
        XCTAssertEqual(
            Hotkey.makeLabel(keyCode: 9, modifiers: HotkeyModifiers.mask(.control, .shift), typed: "v"),
            "⌃⇧V"
        )
        XCTAssertEqual(
            Hotkey.makeLabel(keyCode: 105, modifiers: 0),
            "F12"
        )
    }

    func testTheANSICodesAreTheUSLayout() {
        XCTAssertEqual(HotkeyValidator.ansiKeyCode(forCharacter: "a"), 0)
        XCTAssertEqual(HotkeyValidator.ansiKeyCode(forCharacter: "d"), 2)
        XCTAssertEqual(HotkeyValidator.ansiKeyCode(forCharacter: "z"), 6)
        XCTAssertEqual(HotkeyValidator.ansiKeyCode(forCharacter: "1"), 18)
        XCTAssertNil(HotkeyValidator.ansiKeyCode(forCharacter: "€"))
    }

    func testAModifierIsRequired() {
        switch HotkeyValidator.validate(keyCode: 2, modifiers: 0, typed: "d") {
        case .success:
            XCTFail("a bare key must be refused")
        case .failure(let rejection):
            guard case .noModifier = rejection else {
                return XCTFail("expected noModifier, got \(rejection)")
            }
        }
    }

    func testAFunctionKeyMayStandAlone() {
        switch HotkeyValidator.validate(keyCode: 105, modifiers: 0) {
        case .success(let hotkey):
            XCTAssertEqual(hotkey.keyCode, 105)
        case .failure(let rejection):
            XCTFail("a function key may stand alone: \(rejection)")
        }
    }

    func testASystemShortcutIsRefused() {
        switch HotkeyValidator.validate(keyCode: 12, modifiers: HotkeyModifiers.mask(.command), typed: "q") {
        case .success:
            XCTFail("⌘Q belongs to the system")
        case .failure(let rejection):
            guard case .systemOwned = rejection else {
                return XCTFail("expected systemOwned, got \(rejection)")
            }
        }
    }

    func testAShortcutDotAlreadyUsesIsRefused() {
        let used = [Hotkey.defaultPaste]
        switch HotkeyValidator.validate(
            keyCode: 9,
            modifiers: HotkeyModifiers.mask(.option, .command),
            typed: "v",
            inUse: used
        ) {
        case .success:
            XCTFail("the paste shortcut is taken")
        case .failure(let rejection):
            guard case .alreadyUsed = rejection else {
                return XCTFail("expected alreadyUsed, got \(rejection)")
            }
        }
    }

    func testTheDefaultShortcutIsAccepted() {
        switch HotkeyValidator.validate(
            keyCode: 2,
            modifiers: HotkeyModifiers.mask(.option, .command),
            typed: "d"
        ) {
        case .success(let hotkey):
            XCTAssertEqual(hotkey.label, "⌥⌘D")
        case .failure(let rejection):
            XCTFail("the default shortcut must be accepted: \(rejection)")
        }
    }
}

extension ConfigTests {
    /// One key Dot cannot read must not reset the file.
    ///
    /// The configuration is written by hand as often as by the app, and a
    /// spelling no build knows used to throw out of the decoder: the endpoints,
    /// the shortcuts and the microphone book all came back as the shipped
    /// defaults, and the next save wrote them over the person's file.
    func testOneBadEnumDoesNotResetTheWholeFile() throws {
        let url = directory.appendingPathComponent("config.json")
        try #"""
        {
          "provider": "deepgram",
          "autoPaste": false,
          "hudDwellSeconds": 9,
          "hudMaterial": "velvet",
          "appearance": "sepia",
          "hudVisualizer": "zigzag",
          "recordingMode": "somersault",
          "providers": {
            "deepgram": { "baseURL": "https://api.deepgram.com/v1", "authStyle": "Bearer" }
          }
        }
        """#.write(to: url, atomically: true, encoding: .utf8)

        let config = DotConfig.load(from: url)
        XCTAssertEqual(config.provider, "deepgram", "the selected provider survived")
        XCTAssertFalse(config.autoPaste, "an unrelated setting survived")
        XCTAssertEqual(config.hudDwellSeconds, 9)
        XCTAssertEqual(config.hudMaterial, .glass, "the bad value fell back on its own")
        XCTAssertEqual(config.appearance, .system)
        XCTAssertEqual(config.hudVisualizer, .stretch)
        XCTAssertEqual(config.recordingMode, .toggle)
        XCTAssertEqual(
            config.settings(for: "deepgram").authStyle,
            nil,
            "a header style no build knows loads as the documented default"
        )
        XCTAssertEqual(
            config.settings(for: "deepgram").baseURL,
            "https://api.deepgram.com/v1",
            "the endpoint survived the bad enum beside it"
        )
    }
}
