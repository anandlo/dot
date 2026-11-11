import Foundation

/// Reminders, through EventKit.
public struct RemindersConnector: Connector {
    public let id: ConnectorID = .reminders
    public let displayName = "Reminders"
    public let symbol = "checklist"
    public let detail = "Create a reminder, or read what is due."
    private let store: any ReminderStore

    /// Creates the connector.
    ///
    /// - Parameter store: the EventKit adapter, injected so this logic can be
    ///   tested without touching the person's reminders.
    public init(store: any ReminderStore) {
        self.store = store
    }

    public func tools() -> [ConnectorTool] {
        [listTool, createTool, completeTool]
    }

    private var listTool: ConnectorTool {
        ConnectorTool(
            name: "reminders_list",
            title: "Read reminders",
            description: "List reminders that are due today, tomorrow, this week or overdue.",
            risk: .read,
            schema: ToolSchema([
                .init(
                    name: "when",
                    description: "The window to list.",
                    field: .choice(["today", "tomorrow", "week", "overdue"])
                ),
                .init(
                    name: "list",
                    description: "One list to read, when the person named it.",
                    field: .string(maxLength: 80),
                    isRequired: false
                ),
                .init(
                    name: "limit",
                    description: "The most reminders to return, 1 to 50.",
                    field: .integer(1...50),
                    isRequired: false
                ),
            ]),
            confirmation: { _ in "Read your reminders." }
        )
    }

    private var createTool: ConnectorTool {
        ConnectorTool(
            name: "reminders_create",
            title: "Create a reminder",
            description: """
            Create a reminder with an optional due date and list. The due date is \
            ISO 8601 in local time, for example 2026-11-13T09:00.
            """,
            risk: .write,
            schema: ToolSchema([
                .init(name: "title", description: "What to remember.", field: .string(maxLength: 200)),
                .init(
                    name: "due",
                    description: "When it is due, as ISO 8601 local time.",
                    field: .string(maxLength: 40),
                    isRequired: false
                ),
                .init(
                    name: "list",
                    description: "The list to add it to.",
                    field: .string(maxLength: 80),
                    isRequired: false
                ),
                .init(
                    name: "notes",
                    description: "Any details to attach.",
                    field: .string(maxLength: 1_000),
                    isRequired: false
                ),
            ]),
            confirmation: { arguments in
                var sentence = "Add the reminder \"\(arguments.string("title") ?? "")\""
                if let due = arguments.string("due") { sentence += ", due \(due)" }
                if let list = arguments.string("list") { sentence += ", to \(list)" }
                return sentence + "?"
            }
        )
    }

    private var completeTool: ConnectorTool {
        ConnectorTool(
            name: "reminders_complete",
            title: "Complete a reminder",
            description: "Mark one reminder done, using the id from reminders_list.",
            risk: .write,
            schema: ToolSchema([
                .init(name: "id", description: "The reminder id.", field: .string(maxLength: 200)),
            ]),
            confirmation: { _ in "Mark that reminder done?" }
        )
    }
}

extension RemindersConnector {
    public func permission() async -> ConnectorPermission {
        await store.permission()
    }

    public func requestAccess() async -> ConnectorPermission {
        await store.requestAccess()
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        do {
            switch call.name {
            case "reminders_list":
                return .ok(try await list(call.arguments))
            case "reminders_create":
                return .ok(try await create(call.arguments))
            case "reminders_complete":
                try await store.complete(id: call.arguments.string("id") ?? "")
                return .ok("Marked done.")
            default:
                return .failure("Reminders has no tool called '\(call.name)'.")
            }
        } catch let error as StoreError {
            return .failure(error.message)
        } catch {
            return .failure("Reminders could not be read.")
        }
    }

    private func list(_ arguments: ValidatedArguments) async throws -> String {
        let window = ReminderScope.Window(rawValue: arguments.string("when") ?? "today") ?? .today
        let scope = ReminderScope(
            window: window,
            listName: arguments.string("list"),
            limit: arguments.int("limit") ?? 20
        )
        let items = try await store.items(scope)
        let lines = items.map { item in
            ResultText.line([
                item.isCompleted ? "[x] \(item.title)" : item.title,
                item.listName,
                item.due.map { "due \(ToolDate.describe($0))" },
                item.isCompleted ? nil : "id \(item.id)",
            ])
        }
        return ResultText.list(heading: "reminder", items: lines, empty: "No reminders in that window.")
    }

    private func create(_ arguments: ValidatedArguments) async throws -> String {
        var due: Date?
        if let text = arguments.string("due") {
            guard let parsed = ToolDate.parse(text) else {
                throw StoreError("The due date must be ISO 8601, for example 2026-11-13T09:00.")
            }
            due = parsed
        }
        let draft = ReminderDraft(
            title: arguments.string("title") ?? "",
            notes: arguments.string("notes"),
            due: due,
            listName: arguments.string("list")
        )
        let item = try await store.create(draft)
        return ResultText.line([
            "Created \(item.title)",
            item.listName,
            item.due.map { "due \(ToolDate.describe($0))" },
            "id \(item.id)",
        ])
    }
}
