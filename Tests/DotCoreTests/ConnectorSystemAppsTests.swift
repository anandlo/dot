import Foundation
import XCTest

@testable import DotCore

/// System, apps and shortcuts.
///
/// These are the connectors with no permission of their own, which makes their
/// argument checks the only barrier: a URL scheme, an application name, a
/// shortcut that must exist in the library before it runs.
final class ConnectorSystemAppsTests: XCTestCase {
    private func bridge(_ runner: FakeScriptRunner, service: String = "System Events") -> AppleScriptBridge {
        AppleScriptBridge(runner: runner, automation: AutomationPermission(service: service))
    }

    func testVolumeIsASetVolumeScript() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("")])
        let system = SystemConnector(bridge: bridge(runner), shortcuts: FakeShortcutRunner())
        let call = try validatedCall(system, name: "system_setVolume", arguments: ["level": .number(40)])
        let outcome = await system.invoke(call)
        XCTAssertFalse(outcome.isError)
        let programs = await runner.programs
        XCTAssertEqual(programs.first?.source, "set volume output volume 40")
        XCTAssertNil(programs.first?.target)
    }

    func testDarkModeGoesThroughSystemEvents() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("true")])
        let system = SystemConnector(bridge: bridge(runner), shortcuts: FakeShortcutRunner())
        let call = try validatedCall(system, name: "system_setDarkMode", arguments: ["on": .bool(true)])
        let outcome = await system.invoke(call)
        XCTAssertFalse(outcome.isError)
        let programs = await runner.programs
        XCTAssertEqual(programs.first?.target, .systemEvents)
        XCTAssertTrue(programs.first?.source.contains("set dark mode to true") == true)
    }

    func testFocusRunsAShortcutThatExists() async throws {
        let shortcuts = FakeShortcutRunner(library: ["Focus on", "Morning"])
        let system = SystemConnector(bridge: bridge(FakeScriptRunner()), shortcuts: shortcuts)
        let call = try validatedCall(system, name: "system_focus", arguments: ["shortcut": .string("Focus on")])
        let outcome = await system.invoke(call)
        XCTAssertFalse(outcome.isError)
        let runs = await shortcuts.runs
        XCTAssertEqual(runs.first?.name, "Focus on")
        XCTAssertNil(runs.first?.input)
    }

    func testFocusRefusesAShortcutThatIsNotThere() async throws {
        let shortcuts = FakeShortcutRunner(library: ["Focus on"])
        let system = SystemConnector(bridge: bridge(FakeScriptRunner()), shortcuts: shortcuts)
        let call = try validatedCall(system, name: "system_focus", arguments: ["shortcut": .string("Focus off")])
        let outcome = await system.invoke(call)
        XCTAssertTrue(outcome.isError)
        let runs = await shortcuts.runs
        XCTAssertTrue(runs.isEmpty)
    }

    func testFocusRefusesAnOptionName() async throws {
        let shortcuts = FakeShortcutRunner(library: ["--run"])
        let system = SystemConnector(bridge: bridge(FakeScriptRunner()), shortcuts: shortcuts)
        let call = try validatedCall(system, name: "system_focus", arguments: ["shortcut": .string("--run")])
        let outcome = await system.invoke(call)
        XCTAssertTrue(outcome.isError)
        let runs = await shortcuts.runs
        XCTAssertTrue(runs.isEmpty)
    }

    func testSystemNeedsNoPreGrantedPermission() async {
        let system = SystemConnector(bridge: bridge(FakeScriptRunner()), shortcuts: FakeShortcutRunner())
        let permission = await system.permission()
        XCTAssertTrue(permission.allowsTools)
    }

    func testAnAppIsOpenedByName() async throws {
        let launcher = FakeAppLauncher()
        let apps = AppsConnector(launcher: launcher, files: FakeFileOperating(existing: []))
        let call = try validatedCall(apps, name: "apps_open", arguments: ["app": .string("Slack")])
        let outcome = await apps.invoke(call)
        XCTAssertFalse(outcome.isError)
        let opened = await launcher.recorder.opened
        XCTAssertEqual(opened, ["app:Slack"])
    }

    func testOnlyTheSchemesAPersonTypesAreOpened() async throws {
        let launcher = FakeAppLauncher()
        let apps = AppsConnector(launcher: launcher, files: FakeFileOperating(existing: []))
        for url in ["https://example.com/a", "mailto:a@b.com", "tel:+15551234567"] {
            let call = try validatedCall(apps, name: "apps_openURL", arguments: ["url": .string(url)])
            let outcome = await apps.invoke(call)
            XCTAssertFalse(outcome.isError, "\(url) should open")
        }
        for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,x", "shortcuts://run-shortcut?name=x"] {
            let call = try validatedCall(apps, name: "apps_openURL", arguments: ["url": .string(url)])
            let outcome = await apps.invoke(call)
            XCTAssertTrue(outcome.isError, "\(url) should be refused")
        }
        let opened = await launcher.recorder.opened
        XCTAssertEqual(opened.count, 3)
    }

    func testALinkWithCredentialsIsRefused() async throws {
        let launcher = FakeAppLauncher()
        let apps = AppsConnector(launcher: launcher, files: FakeFileOperating(existing: []))
        let call = try validatedCall(apps, name: "apps_openURL", arguments: [
            "url": .string("https://user:pass@example.com/"),
        ])
        let outcome = await apps.invoke(call)
        XCTAssertTrue(outcome.isError)
    }

    func testOpeningAFileUsesThePathGuard() async throws {
        let launcher = FakeAppLauncher()
        let fileOperations = FakeFileOperating(existing: [])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-apps-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let safety = PathSafety(home: root, protected: [])
        let apps = AppsConnector(launcher: launcher, files: fileOperations, safety: safety)
        let call = try validatedCall(apps, name: "apps_openFile", arguments: ["path": .string("/System/Applications/Mail.app")])
        let outcome = await apps.invoke(call)
        XCTAssertTrue(outcome.isError)
        let count = await fileOperations.recorder.count
        XCTAssertEqual(count, 0)
    }

    func testRunningAppsAreListedWithTheFrontmostFirst() async throws {
        let apps = AppsConnector(launcher: FakeAppLauncher(), files: FakeFileOperating(existing: []))
        let call = try validatedCall(apps, name: "apps_running")
        let outcome = await apps.invoke(call)
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("Safari"))
        XCTAssertTrue(outcome.text.contains("frontmost"))
        XCTAssertLessThan(
            try XCTUnwrap(outcome.text.range(of: "Safari")?.lowerBound),
            try XCTUnwrap(outcome.text.range(of: "Slack")?.lowerBound)
        )
    }

    func testAShortcutMustExistBeforeItRuns() async throws {
        let shortcuts = FakeShortcutRunner(library: ["Morning"])
        let connector = ShortcutsConnector(shortcuts: shortcuts)
        let call = try validatedCall(connector, name: "shortcuts_run", arguments: ["name": .string("Evening")])
        let outcome = await connector.invoke(call)
        XCTAssertTrue(outcome.isError)
        let runs = await shortcuts.runs
        XCTAssertTrue(runs.isEmpty)
    }

    func testAShortcutPassesItsInput() async throws {
        let shortcuts = FakeShortcutRunner(library: ["Speak Text"])
        let connector = ShortcutsConnector(shortcuts: shortcuts)
        let call = try validatedCall(connector, name: "shortcuts_run", arguments: [
            "name": .string("Speak Text"),
            "input": .string("hello"),
        ])
        let outcome = await connector.invoke(call)
        XCTAssertFalse(outcome.isError)
        let runs = await shortcuts.runs
        XCTAssertEqual(runs.first?.name, "Speak Text")
        XCTAssertEqual(runs.first?.input, "hello")
    }

    func testTheShortcutListIsFormatted() async throws {
        let connector = ShortcutsConnector(shortcuts: FakeShortcutRunner(library: ["Morning", "Focus"]))
        let call = try validatedCall(connector, name: "shortcuts_list")
        let outcome = await connector.invoke(call)
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("2 shortcuts"))
    }

    func testTheShortcutRunToolIsExternal() {
        let connector = ShortcutsConnector(shortcuts: FakeShortcutRunner())
        XCTAssertEqual(connector.tool(named: "shortcuts_run")?.risk, .external)
        XCTAssertEqual(connector.tool(named: "shortcuts_list")?.risk, .read)
    }
}
