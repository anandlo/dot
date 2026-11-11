import Foundation

/// The system controls macOS offers without a private framework.
///
/// Volume and mute need nothing at all. Dark mode needs Automation for System
/// Events. Focus has no public API, so it is reached by running a shortcut the
/// person already has, which is why that tool lives here and delegates to the
/// Shortcuts runner.
///
/// Brightness is deliberately absent: the only way to set it is the private
/// `DisplayServices` framework, and a toggle that silently stops working after
/// an OS update is worse than no toggle.
public struct SystemConnector: Connector {
    public let id: ConnectorID = .system
    public let displayName = "System"
    public let symbol = "gearshape"
    public let detail = "Volume, mute, dark mode, and Focus through one of your shortcuts."
    private let bridge: AppleScriptBridge
    private let shortcuts: any ShortcutRunning

    /// Creates the connector.
    ///
    /// - Parameters:
    ///   - bridge: the script runner for System Events and `set volume`.
    ///   - shortcuts: the runner used for Focus, which has no API of its own.
    public init(bridge: AppleScriptBridge, shortcuts: any ShortcutRunning) {
        self.bridge = bridge
        self.shortcuts = shortcuts
    }

    public func tools() -> [ConnectorTool] {
        [volumeTool, muteTool, darkModeTool, focusTool]
    }

    private var volumeTool: ConnectorTool {
        ConnectorTool(
            name: "system_setVolume",
            title: "Set the volume",
            description: "Set the output volume from 0 to 100.",
            risk: .write,
            schema: ToolSchema([
                .init(name: "level", description: "The volume, 0 to 100.", field: .integer(0...100)),
            ]),
            confirmation: { arguments in
                "Set the volume to \(arguments.int("level") ?? 0)%?"
            }
        )
    }

    private var muteTool: ConnectorTool {
        ConnectorTool(
            name: "system_mute",
            title: "Mute or unmute",
            description: "Mute or unmute the output.",
            risk: .write,
            schema: ToolSchema([
                .init(name: "muted", description: "Whether to mute.", field: .boolean),
            ]),
            confirmation: { arguments in
                (arguments.bool("muted") ?? true) ? "Mute the sound?" : "Unmute the sound?"
            }
        )
    }

    private var darkModeTool: ConnectorTool {
        ConnectorTool(
            name: "system_setDarkMode",
            title: "Switch dark mode",
            description: "Turn dark appearance on or off.",
            risk: .write,
            schema: ToolSchema([
                .init(name: "on", description: "Whether dark mode should be on.", field: .boolean),
            ]),
            confirmation: { arguments in
                (arguments.bool("on") ?? true) ? "Turn on dark mode?" : "Turn off dark mode?"
            }
        )
    }

    private var focusTool: ConnectorTool {
        ConnectorTool(
            name: "system_focus",
            title: "Run a Focus shortcut",
            description: """
            Turn a Focus on or off by running a shortcut the person built for it. \
            macOS has no public API for Focus, so the shortcut is the only path. \
            Call shortcuts_list first and use a name from it.
            """,
            risk: .external,
            schema: ToolSchema([
                .init(name: "shortcut", description: "The shortcut's exact name.", field: .string(maxLength: 200)),
            ]),
            timeout: .seconds(60),
            confirmation: { arguments in
                "Run the shortcut \"\(arguments.string("shortcut") ?? "")\"?"
            }
        )
    }

    public func permission() async -> ConnectorPermission {
        // Volume and mute need nothing; dark mode asks for Automation the first
        // time it runs, and the failure says so. Reporting the connector as
        // unavailable would hide a working volume slider.
        ConnectorPermission(
            status: .granted,
            service: "System",
            remedy: nil,
            settingsURL: ConnectorPermission.Pane.automation.url
        )
    }

    public func requestAccess() async -> ConnectorPermission {
        await permission()
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        switch call.name {
        case "system_setVolume":
            let level = call.arguments.int("level") ?? 50
            let outcome = await bridge.run(SystemScripts.volume(level), timeout: call.tool.timeout)
            return Self.result(outcome, success: "Volume set to \(level)%.", bridge: bridge)
        case "system_mute":
            let muted = call.arguments.bool("muted") ?? true
            let outcome = await bridge.run(SystemScripts.muted(muted), timeout: call.tool.timeout)
            return Self.result(outcome, success: muted ? "Muted." : "Unmuted.", bridge: bridge)
        case "system_setDarkMode":
            let on = call.arguments.bool("on") ?? true
            let outcome = await bridge.run(SystemScripts.darkMode(on), timeout: call.tool.timeout)
            return Self.result(outcome, success: "Dark mode is \(on ? "on" : "off").", bridge: bridge)
        case "system_focus":
            return await focus(call)
        default:
            return .failure("System has no tool called '\(call.name)'.")
        }
    }

    private func focus(_ call: ConnectorCall) async -> ConnectorOutcome {
        let name = call.arguments.string("shortcut") ?? ""
        guard ShortcutCommand.validName(name) else {
            return .failure("That is not a shortcut name.")
        }
        do {
            let library = try await shortcuts.list()
            guard library.contains(name) else {
                return .failure("There is no shortcut called \"\(name)\" in the library.")
            }
            let output = try await shortcuts.run(name: name, input: nil)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .ok(trimmed.isEmpty ? "Ran \(name)." : "Ran \(name):\n\(trimmed)")
        } catch let error as StoreError {
            return .failure(error.message)
        } catch {
            return .failure("The shortcut could not be run.")
        }
    }

    /// Maps a script outcome to a result, keeping the permission sentence.
    private static func result(
        _ outcome: ScriptOutcome,
        success: String,
        bridge: AppleScriptBridge
    ) -> ConnectorOutcome {
        switch outcome {
        case .ok:
            .ok(success)
        case .failed:
            .failure(bridge.failureText(outcome))
        }
    }
}
