import XCTest

/// The Appearance page names its two lower sections after what they set.
///
/// The copy lives in a view that needs a window to draw, so the guard reads the
/// source: the section titles are literals, and the old ones may not come back.
final class SettingsAppearanceSectionTests: XCTestCase {
    /// The package root, found from this file.
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func settingsSource() throws -> String {
        try String(
            contentsOf: Self.root.appendingPathComponent("Sources/Dot/SettingsView.swift"),
            encoding: .utf8
        )
    }

    func testTheTwoLowerSectionsAreNamedForWhatTheySet() throws {
        let source = try settingsSource()
        XCTAssertTrue(source.contains("SettingsSection(\"Island surface\")"), "the material section lost its name")
        XCTAssertTrue(source.contains("SettingsSection(\"Voice visualizer\")"), "the visualizer section lost its name")
        XCTAssertFalse(source.contains("Recording card material"), "the material section kept its old name")
        XCTAssertFalse(source.contains("SettingsSection(\"Waveform\")"), "the visualizer section kept its old name")
    }

    /// The visualizer tile announces what it is: the style's name and the word
    /// visualizer, which is what the section calls it too.
    func testTheVisualizerTileIsAnnouncedAsAVisualizer() throws {
        let source = try settingsSource()
        XCTAssertTrue(source.contains("\"\\(visualizer.title) visualizer\""))
        XCTAssertFalse(source.contains("\"\\(visualizer.title) waveform\""))
    }
}
