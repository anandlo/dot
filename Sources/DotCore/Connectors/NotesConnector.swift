import Foundation

/// Notes, through its AppleScript dictionary.
public struct NotesConnector: Connector {
    public let id: ConnectorID = .notes
    public let displayName = "Notes"
    public let symbol = "note.text"
    public let detail = "Create a note, add to one, or search your note titles."
    private let bridge: AppleScriptBridge

    /// Creates the connector.
    ///
    /// - Parameter bridge: the script runner for Notes.
    public init(bridge: AppleScriptBridge) {
        self.bridge = bridge
    }

    public func tools() -> [ConnectorTool] {
        [createTool, appendTool, searchTool]
    }

    private var createTool: ConnectorTool {
        ConnectorTool(
            name: "notes_create",
            title: "Create a note",
            description: "Create a note with a title and text in a folder.",
            risk: .write,
            schema: ToolSchema([
                .init(name: "title", description: "The note title.", field: .string(maxLength: 200)),
                .init(name: "body", description: "The note text.", field: .string(maxLength: 3_000)),
                .init(
                    name: "folder",
                    description: "The folder to put it in.",
                    field: .string(maxLength: 80),
                    isRequired: false
                ),
            ]),
            confirmation: { arguments in
                "Create the note \"\(arguments.string("title") ?? "")\"?"
            }
        )
    }

    private var appendTool: ConnectorTool {
        ConnectorTool(
            name: "notes_append",
            title: "Add to a note",
            description: "Add text to the end of the first note with that title.",
            risk: .write,
            schema: ToolSchema([
                .init(name: "title", description: "The note title.", field: .string(maxLength: 200)),
                .init(name: "body", description: "The text to add.", field: .string(maxLength: 3_000)),
            ]),
            confirmation: { arguments in
                "Add to the note \"\(arguments.string("title") ?? "")\"?"
            }
        )
    }

    private var searchTool: ConnectorTool {
        ConnectorTool(
            name: "notes_search",
            title: "Search notes",
            description: "Find notes whose title contains the words.",
            risk: .read,
            schema: ToolSchema([
                .init(name: "query", description: "The words to look for.", field: .string(maxLength: 100)),
                .init(
                    name: "limit",
                    description: "The most notes to return, 1 to 30.",
                    field: .integer(1...30),
                    isRequired: false
                ),
            ]),
            confirmation: { _ in "Search your notes." }
        )
    }
}

extension NotesConnector {
    public func permission() async -> ConnectorPermission {
        await bridge.permission()
    }

    public func requestAccess() async -> ConnectorPermission {
        await bridge.requestAccess(probe: NotesScripts.probe(), timeout: .seconds(30))
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        switch call.name {
        case "notes_create":
            return await create(call)
        case "notes_append":
            return await append(call)
        case "notes_search":
            return await search(call)
        default:
            return .failure("Notes has no tool called '\(call.name)'.")
        }
    }

    private func create(_ call: ConnectorCall) async -> ConnectorOutcome {
        let program = NotesScripts.create(
            title: call.arguments.string("title") ?? "",
            body: call.arguments.string("body") ?? "",
            folder: call.arguments.string("folder") ?? "Notes"
        )
        let outcome = await bridge.run(program, timeout: call.tool.timeout)
        switch outcome {
        case .ok:
            return .ok("Created the note.")
        case .failed:
            return .failure(bridge.failureText(outcome))
        }
    }

    private func append(_ call: ConnectorCall) async -> ConnectorOutcome {
        let program = NotesScripts.append(
            title: call.arguments.string("title") ?? "",
            body: call.arguments.string("body") ?? ""
        )
        let outcome = await bridge.run(program, timeout: call.tool.timeout)
        switch outcome {
        case .ok("missing"):
            return .failure("There is no note with that title.")
        case .ok:
            return .ok("Added the text to the note.")
        case .failed:
            return .failure(bridge.failureText(outcome))
        }
    }

    private func search(_ call: ConnectorCall) async -> ConnectorOutcome {
        let program = NotesScripts.search(
            query: call.arguments.string("query") ?? "",
            limit: call.arguments.int("limit") ?? 10
        )
        let outcome = await bridge.run(program, timeout: call.tool.timeout)
        switch outcome {
        case .ok(let text):
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            return .ok(ResultText.list(heading: "note", items: lines, empty: "No note matched."))
        case .failed:
            return .failure(bridge.failureText(outcome))
        }
    }
}
