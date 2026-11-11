import Foundation

/// Calendar, through EventKit.
public struct CalendarConnector: Connector {
    public let id: ConnectorID = .calendar
    public let displayName = "Calendar"
    public let symbol = "calendar"
    public let detail = "Read what is coming up, and create an event."
    private let store: any CalendarStore

    /// Creates the connector.
    ///
    /// - Parameter store: the EventKit adapter.
    public init(store: any CalendarStore) {
        self.store = store
    }

    public func tools() -> [ConnectorTool] {
        [eventsTool, createTool]
    }

    private var eventsTool: ConnectorTool {
        ConnectorTool(
            name: "calendar_events",
            title: "Read calendar",
            description: "List calendar events for today, tomorrow or the next seven days.",
            risk: .read,
            schema: ToolSchema([
                .init(
                    name: "range",
                    description: "The window to read.",
                    field: .choice(["today", "tomorrow", "week"])
                ),
                .init(
                    name: "limit",
                    description: "The most events to return, 1 to 50.",
                    field: .integer(1...50),
                    isRequired: false
                ),
            ]),
            confirmation: { _ in "Read your calendar." }
        )
    }

    private var createTool: ConnectorTool {
        ConnectorTool(
            name: "calendar_create",
            title: "Create an event",
            description: """
            Create a calendar event. The start is ISO 8601 in local time, for \
            example 2026-11-13T09:00. Events are never deleted by the assistant.
            """,
            risk: .write,
            schema: ToolSchema([
                .init(name: "title", description: "The event title.", field: .string(maxLength: 200)),
                .init(
                    name: "start",
                    description: "When it starts, as ISO 8601 local time.",
                    field: .string(maxLength: 40)
                ),
                .init(
                    name: "minutes",
                    description: "How long it lasts, 5 to 1440 minutes.",
                    field: .integer(5...1_440),
                    isRequired: false
                ),
                .init(
                    name: "location",
                    description: "Where it is.",
                    field: .string(maxLength: 200),
                    isRequired: false
                ),
                .init(
                    name: "notes",
                    description: "Any details.",
                    field: .string(maxLength: 1_000),
                    isRequired: false
                ),
                .init(
                    name: "calendar",
                    description: "The calendar to add it to.",
                    field: .string(maxLength: 80),
                    isRequired: false
                ),
            ]),
            confirmation: { arguments in
                var sentence = "Create the event \"\(arguments.string("title") ?? "")\""
                if let start = arguments.string("start") { sentence += " on \(start)" }
                let minutes = arguments.int("minutes") ?? 30
                sentence += " for \(minutes) minutes"
                if let location = arguments.string("location") { sentence += " at \(location)" }
                return sentence + "?"
            }
        )
    }
}

extension CalendarConnector {
    public func permission() async -> ConnectorPermission {
        await store.permission()
    }

    public func requestAccess() async -> ConnectorPermission {
        await store.requestAccess()
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        do {
            switch call.name {
            case "calendar_events":
                return .ok(try await events(call.arguments))
            case "calendar_create":
                return .ok(try await create(call.arguments))
            default:
                return .failure("Calendar has no tool called '\(call.name)'.")
            }
        } catch let error as StoreError {
            return .failure(error.message)
        } catch {
            return .failure("The calendar could not be read.")
        }
    }

    private func events(_ arguments: ValidatedArguments) async throws -> String {
        let range = arguments.string("range") ?? "today"
        let today = ToolDate.startOfDay(Date())
        let from: Date
        let days: Int
        switch range {
        case "tomorrow":
            from = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
            days = 1
        case "week":
            from = today
            days = 7
        default:
            from = today
            days = 1
        }
        let to = Calendar.current.date(byAdding: .day, value: days, to: from) ?? from
        let items = try await store.events(from: from, to: to)
        let limit = arguments.int("limit") ?? 20
        let lines = items.prefix(limit).map { item in
            ResultText.line([
                item.isAllDay ? "all day" : nil,
                item.start.formattedRange(to: item.end),
                item.title,
                item.calendarName,
                item.location.isEmpty ? nil : item.location,
            ])
        }
        return ResultText.list(heading: "event", items: Array(lines), empty: "Nothing on the calendar.")
    }

    private func create(_ arguments: ValidatedArguments) async throws -> String {
        guard let startText = arguments.string("start"), let start = ToolDate.parse(startText) else {
            throw StoreError("The start must be ISO 8601, for example 2026-11-13T09:00.")
        }
        let minutes = arguments.int("minutes") ?? 30
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        let draft = EventDraft(
            title: arguments.string("title") ?? "",
            start: start,
            end: end,
            location: arguments.string("location"),
            notes: arguments.string("notes"),
            calendarName: arguments.string("calendar")
        )
        let item = try await store.create(draft)
        return ResultText.line([
            "Created \(item.title)",
            item.start.formattedRange(to: item.end),
            item.calendarName,
        ])
    }
}

extension Date {
    /// Formats this instant and another as one range, in the person's zone.
    ///
    /// - Parameter end: the end of the range.
    /// - Returns: "09:00-09:30" on the same day, with the second day named when
    ///   they differ.
    func formattedRange(to end: Date) -> String {
        let calendar = Calendar.current
        let startTime = formatted(date: .omitted, time: .shortened)
        let endTime = end.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(self, inSameDayAs: end) {
            return "\(ToolDate.describeDay(self)), \(startTime)-\(endTime)"
        }
        return "\(ToolDate.describe(self)) to \(ToolDate.describe(end))"
    }
}
