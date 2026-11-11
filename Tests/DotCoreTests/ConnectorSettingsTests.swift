import Foundation
import XCTest

@testable import DotCore

/// What the Connectors page stores, and how it survives a hand-edited file.
///
/// The settings live in the same JSON file as everything else Dot knows, so one
/// bad value must never reset the page. Every enum decodes through `try?` and
/// falls back to its own default, and an id this build does not know is kept
/// rather than deleted.
final class ConnectorSettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> ConnectorSettings {
        try JSONDecoder().decode(ConnectorSettings.self, from: Data(json.utf8))
    }

    func testTheShippedDefaultEnablesOnlyPromptlessConnectors() {
        let settings = ConnectorSettings.default
        XCTAssertEqual(Set(settings.enabled), [.files, .apps, .system])
        XCTAssertTrue(settings.policies.isEmpty)
    }

    func testAnEmptyObjectLoadsTheDefault() throws {
        let settings = try decode("{}")
        XCTAssertEqual(Set(settings.enabled), [.files, .apps, .system])
    }

    func testAnExplicitEmptyListMeansEverythingIsOff() throws {
        let settings = try decode(#"{"enabled":[]}"#)
        XCTAssertTrue(settings.enabled.isEmpty)
    }

    func testAnUnknownConnectorIdSurvives() throws {
        let settings = try decode(#"{"enabled":["files","future-connector"]}"#)
        XCTAssertEqual(settings.enabled, ["files", ConnectorID("future-connector")])
    }

    func testADuplicateIdIsCollapsed() throws {
        let settings = try decode(#"{"enabled":["files","files","apps"]}"#)
        XCTAssertEqual(settings.enabled, ["files", "apps"])
    }

    func testAnUnknownPolicyDropsThatOneOverride() throws {
        let settings = try decode(#"{"policies":{"a":"sometimes","b":"never"}}"#)
        XCTAssertNil(settings.policies["a"])
        XCTAssertEqual(settings.policies["b"], .never)
    }

    func testAPreReleaseDottedPolicyKeyIsRead() throws {
        let settings = try decode(#"{"policies":{"reminders.create":"never"}}"#)
        XCTAssertEqual(settings.policies["reminders_create"], .never)
    }

    func testTheUnderscoreKeyWinsOverTheDottedAlias() throws {
        let settings = try decode(#"{"policies":{"reminders.create":"never","reminders_create":"ask"}}"#)
        XCTAssertEqual(settings.policies["reminders_create"], .ask)
    }

    func testAnEnabledValueOfTheWrongTypeFallsBackToTheDefault() throws {
        let settings = try decode(#"{"enabled":"files"}"#)
        XCTAssertEqual(Set(settings.enabled), [.files, .apps, .system])
    }

    func testSettingsRoundTrip() throws {
        var settings = ConnectorSettings(enabled: [.calendar], policies: ["calendar_create": .never])
        settings.setEnabled(true, for: .notes)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ConnectorSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testSwitchingAConnectorOffForgetsItsOverrides() {
        var settings = ConnectorSettings(
            enabled: [.reminders],
            policies: ["reminders_create": .never, "calendar_create": .ask]
        )
        settings.setEnabled(false, for: .reminders)
        XCTAssertNil(settings.policies["reminders_create"])
        XCTAssertEqual(settings.policies["calendar_create"], .ask, "Another connector's override must survive")
    }

    func testSwitchingAConnectorOnDoesNotDuplicateIt() {
        var settings = ConnectorSettings(enabled: [.files])
        settings.setEnabled(true, for: .files)
        XCTAssertEqual(settings.enabled, [.files])
    }

    func testThePolicyTableReadsTheStoredOverrides() {
        let settings = ConnectorSettings(policies: ["notes_create": .never])
        XCTAssertEqual(settings.policyTable.override(forTool: "notes_create"), .never)
        XCTAssertEqual(
            settings.policyTable.policy(for: makeTool(name: "notes_create", risk: .write)),
            .never
        )
    }
}
