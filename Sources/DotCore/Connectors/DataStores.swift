import Foundation

/// One reminder, as a tool result and as a completion target.
public struct ReminderItem: Sendable, Equatable {
    /// The EventKit identifier, which `reminders_complete` takes.
    public let id: String
    /// What the reminder says.
    public let title: String
    /// The list it lives in.
    public let listName: String
    /// When it is due, when it has a due date.
    public let due: Date?
    /// Its notes, when it has any.
    public let notes: String
    /// Whether it is already done.
    public let isCompleted: Bool

    /// Creates a reminder value.
    public init(
        id: String,
        title: String,
        listName: String,
        due: Date?,
        notes: String,
        isCompleted: Bool
    ) {
        self.id = id
        self.title = title
        self.listName = listName
        self.due = due
        self.notes = notes
        self.isCompleted = isCompleted
    }
}

/// A reminder to create.
public struct ReminderDraft: Sendable, Equatable {
    /// What the reminder should say.
    public let title: String
    /// Any notes.
    public let notes: String?
    /// When it is due.
    public let due: Date?
    /// The list to put it in. The default list when nil.
    public let listName: String?

    /// Creates a draft.
    public init(title: String, notes: String?, due: Date?, listName: String?) {
        self.title = title
        self.notes = notes
        self.due = due
        self.listName = listName
    }
}

/// Which reminders a listing asks for.
public struct ReminderScope: Sendable, Equatable {
    /// The windows a listing can cover.
    public enum Window: String, Sendable, CaseIterable {
        case today
        case tomorrow
        case week
        case overdue
    }

    /// The window.
    public let window: Window
    /// One list, when the person named one.
    public let listName: String?
    /// The most items to return.
    public let limit: Int

    /// Creates a scope.
    public init(window: Window, listName: String?, limit: Int) {
        self.window = window
        self.listName = listName
        self.limit = limit
    }
}

/// Reminders, as the connector needs them.
///
/// The protocol exists so the tool logic, its validation and its summaries can
/// be tested without EventKit and without touching a real reminder.
public protocol ReminderStore: Sendable {
    /// The current EventKit authorization.
    func permission() async -> ConnectorPermission
    /// Requests full access, prompting once.
    func requestAccess() async -> ConnectorPermission
    /// The person's lists.
    func lists() async throws -> [String]
    /// Creates a reminder.
    func create(_ draft: ReminderDraft) async throws -> ReminderItem
    /// Reads the reminders in a window.
    func items(_ scope: ReminderScope) async throws -> [ReminderItem]
    /// Marks a reminder done.
    func complete(id: String) async throws
}

/// One calendar event.
public struct CalendarItem: Sendable, Equatable {
    /// The EventKit identifier.
    public let id: String
    /// The title.
    public let title: String
    /// When it starts.
    public let start: Date
    /// When it ends.
    public let end: Date
    /// The calendar it lives in.
    public let calendarName: String
    /// Where it is, when the event says.
    public let location: String
    /// Whether it is an all-day event.
    public let isAllDay: Bool

    /// Creates an event value.
    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        calendarName: String,
        location: String,
        isAllDay: Bool
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendarName = calendarName
        self.location = location
        self.isAllDay = isAllDay
    }
}

/// An event to create.
public struct EventDraft: Sendable, Equatable {
    /// The title.
    public let title: String
    /// When it starts.
    public let start: Date
    /// When it ends.
    public let end: Date
    /// Where it is.
    public let location: String?
    /// Notes.
    public let notes: String?
    /// The calendar to use.
    public let calendarName: String?

    /// Creates a draft.
    public init(
        title: String,
        start: Date,
        end: Date,
        location: String?,
        notes: String?,
        calendarName: String?
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.calendarName = calendarName
    }
}

/// Calendar events, as the connector needs them.
public protocol CalendarStore: Sendable {
    /// The current EventKit authorization.
    func permission() async -> ConnectorPermission
    /// Requests full access, prompting once.
    func requestAccess() async -> ConnectorPermission
    /// Reads events in a range.
    func events(from start: Date, to end: Date) async throws -> [CalendarItem]
    /// Creates an event.
    func create(_ draft: EventDraft) async throws -> CalendarItem
    /// The calendars a person has.
    func calendars() async throws -> [String]
}

/// A person, as Contacts knows them.
public struct ContactMatch: Sendable, Equatable, Identifiable {
    /// The contact identifier, for a stable list identity.
    public let id: String
    /// The display name.
    public let name: String
    /// Phone numbers and message handles.
    public let handles: [String]
    /// Email addresses.
    public let emails: [String]

    /// Creates a match.
    public init(id: String, name: String, handles: [String], emails: [String]) {
        self.id = id
        self.name = name
        self.handles = handles
        self.emails = emails
    }
}

/// Contacts, as the connector needs them.
///
/// Read only, by design: Dot resolves a name so another tool can act on it. It
/// never writes to the address book.
public protocol ContactsDirectory: Sendable {
    /// The current Contacts authorization.
    func permission() async -> ConnectorPermission
    /// Requests access, prompting once.
    func requestAccess() async -> ConnectorPermission
    /// Finds people whose name contains the query.
    func find(name: String, limit: Int) async throws -> [ContactMatch]
}
