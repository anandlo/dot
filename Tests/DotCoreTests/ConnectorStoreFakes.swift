import Foundation

@testable import DotCore

/// A reminders store that records instead of touching EventKit.
final class FakeReminderStore: ReminderStore, @unchecked Sendable {
    let recorder = ReminderRecorder()
    private let status: ConnectorPermissionStatus

    init(status: ConnectorPermissionStatus = .granted) {
        self.status = status
    }

    func permission() async -> ConnectorPermission {
        ConnectorPermission(
            status: status,
            service: "Reminders",
            remedy: status == .denied
                ? "Allow Dot in System Settings, Privacy and Security, Reminders."
                : nil,
            settingsURL: ConnectorPermission.Pane.reminders.url
        )
    }

    func requestAccess() async -> ConnectorPermission {
        await permission()
    }

    func lists() async throws -> [String] {
        ["Home", "Work"]
    }

    func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        await recorder.recordCreate(draft)
        return ReminderItem(
            id: "new-id",
            title: draft.title,
            listName: draft.listName ?? "Home",
            due: draft.due,
            notes: draft.notes ?? "",
            isCompleted: false
        )
    }

    func items(_ scope: ReminderScope) async throws -> [ReminderItem] {
        await recorder.recordScope(scope)
        return [
            ReminderItem(
                id: "r1",
                title: "Pay rent",
                listName: "Home",
                due: Date(timeIntervalSince1970: 1_794_562_200),
                notes: "",
                isCompleted: false
            ),
        ]
    }

    func complete(id: String) async throws {
        await recorder.recordComplete(id)
    }
}

/// What a fake reminder store was asked to do.
actor ReminderRecorder {
    private(set) var drafts: [ReminderDraft] = []
    private(set) var scopes: [ReminderScope] = []
    private(set) var completed: [String] = []

    func recordCreate(_ draft: ReminderDraft) { drafts.append(draft) }
    func recordScope(_ scope: ReminderScope) { scopes.append(scope) }
    func recordComplete(_ id: String) { completed.append(id) }
}

/// A calendar store that records instead of touching EventKit.
final class FakeCalendarStore: CalendarStore, @unchecked Sendable {
    let recorder = CalendarRecorder()

    func permission() async -> ConnectorPermission {
        ConnectorPermission(status: .granted, service: "Calendar")
    }

    func requestAccess() async -> ConnectorPermission {
        await permission()
    }

    func calendars() async throws -> [String] {
        ["Home"]
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarItem] {
        await recorder.recordRange(start, end)
        return [
            CalendarItem(
                id: "e1",
                title: "Standup",
                start: start.addingTimeInterval(9 * 3_600),
                end: start.addingTimeInterval(9.5 * 3_600),
                calendarName: "Work",
                location: "Zoom",
                isAllDay: false
            ),
        ]
    }

    func create(_ draft: EventDraft) async throws -> CalendarItem {
        await recorder.recordCreate(draft)
        return CalendarItem(
            id: "e2",
            title: draft.title,
            start: draft.start,
            end: draft.end,
            calendarName: draft.calendarName ?? "Home",
            location: draft.location ?? "",
            isAllDay: false
        )
    }
}

/// What a fake calendar store was asked to do.
actor CalendarRecorder {
    private(set) var ranges: [(Date, Date)] = []
    private(set) var drafts: [EventDraft] = []

    func recordRange(_ start: Date, _ end: Date) { ranges.append((start, end)) }
    func recordCreate(_ draft: EventDraft) { drafts.append(draft) }
}

/// A contacts directory a test fills with people.
final class FakeContactsDirectory: ContactsDirectory, @unchecked Sendable {
    private let people: [ContactMatch]
    private let status: ConnectorPermissionStatus

    init(people: [ContactMatch], status: ConnectorPermissionStatus = .granted) {
        self.people = people
        self.status = status
    }

    func permission() async -> ConnectorPermission {
        ConnectorPermission(status: status, service: "Contacts")
    }

    func requestAccess() async -> ConnectorPermission {
        await permission()
    }

    func find(name: String, limit: Int) async throws -> [ContactMatch] {
        people.filter { $0.name.localizedCaseInsensitiveContains(name) }
    }
}

/// A script runner that records programs and returns prepared outcomes.
actor FakeScriptRunner: ScriptRunning {
    private(set) var programs: [AppleScriptProgram] = []
    private var outcomes: [ScriptOutcome]

    init(outcomes: [ScriptOutcome] = [.ok("ok")]) {
        self.outcomes = outcomes
    }

    func run(_ program: AppleScriptProgram, timeout: Duration) async -> ScriptOutcome {
        programs.append(program)
        guard !outcomes.isEmpty else { return .ok("") }
        return outcomes.removeFirst()
    }
}
