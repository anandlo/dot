import Foundation

/// The person's Shortcuts library.
///
/// This is the escape hatch for everything macOS has no API for: Focus, window
/// layouts, a home scene, a script of their own. It is also the connector with
/// the least knowable effect, because a shortcut can do anything the Shortcuts
/// app can. That is why it is `external` and asks every time, and why the name
/// is checked against the library before it runs: a model cannot pass an option
/// or invent one.
public struct ShortcutsConnector: Connector {
    public let id: ConnectorID = .shortcuts
    public let displayName = "Shortcuts"
    public let symbol = "bolt"
    public let detail = "Run a shortcut you already have. This is how Focus and other system actions work."
    private let shortcuts: any ShortcutRunning

    /// Creates the connector.
    ///
    /// - Parameter shortcuts: the `shortcuts` CLI adapter.
    public init(shortcuts: any ShortcutRunning) {
        self.shortcuts = shortcuts
    }

    public func tools() -> [ConnectorTool] {
        [listTool, runTool]
    }

    private var listTool: ConnectorTool {
        ConnectorTool(
            name: "shortcuts_list",
            title: "List shortcuts",
            description: "List the names of the shortcuts in the person's library.",
            risk: .read,
            schema: ToolSchema([]),
            confirmation: { _ in "List your shortcuts." }
        )
    }

    private var runTool: ConnectorTool {
        ConnectorTool(
            name: "shortcuts_run",
            title: "Run a shortcut",
            description: """
            Run one shortcut by exact name. Call shortcuts_list first and use a \
            name from it. The shortcut can do whatever it was built to do.
            """,
            risk: .external,
            schema: ToolSchema([
                .init(name: "name", description: "The shortcut's exact name.", field: .string(maxLength: 200)),
                .init(
                    name: "input",
                    description: "Text to pass to the shortcut.",
                    field: .string(maxLength: 2_000),
                    isRequired: false
                ),
            ]),
            timeout: .seconds(60),
            confirmation: { arguments in
                "Run the shortcut \"\(arguments.string("name") ?? "")\"?"
            }
        )
    }

    public func permission() async -> ConnectorPermission {
        .notNeeded(service: "Shortcuts")
    }

    public func requestAccess() async -> ConnectorPermission {
        .notNeeded(service: "Shortcuts")
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        do {
            switch call.name {
            case "shortcuts_list":
                let names = try await shortcuts.list()
                return .ok(ResultText.list(heading: "shortcut", items: names, empty: "There are no shortcuts."))
            case "shortcuts_run":
                return try await run(call)
            default:
                return .failure("Shortcuts has no tool called '\(call.name)'.")
            }
        } catch let error as StoreError {
            return .failure(error.message)
        } catch {
            return .failure("The shortcut could not be run.")
        }
    }

    private func run(_ call: ConnectorCall) async throws -> ConnectorOutcome {
        let name = call.arguments.string("name") ?? ""
        guard ShortcutCommand.validName(name) else {
            throw StoreError("That is not a shortcut name.")
        }
        let library = try await shortcuts.list()
        guard library.contains(name) else {
            throw StoreError("There is no shortcut called \"\(name)\" in the library.")
        }
        let output = try await shortcuts.run(name: name, input: call.arguments.string("input"))
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .ok(trimmed.isEmpty ? "The shortcut ran." : "The shortcut returned:\n\(trimmed)")
    }
}
