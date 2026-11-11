import EventKit
import Foundation
import DotCore

/// Reminders, through EventKit.
///
/// Nothing is built until the first call: the permission check is a static
/// EventKit call that opens no connection, and the event store is created by
/// ``LazyResource`` on the first create or read, then released after two idle
/// minutes.
final class EventKitReminderStore: ReminderStore, @unchecked Sendable {
    private let stores: LazyResource<EventKitStoreBox>

    /// Creates the store.
    ///
    /// - Parameter idle: how long the event store may sit unused before it is
    ///   dropped.
    init(idle: Duration = .seconds(120)) {
        stores = LazyResource(idle: idle) { EventKitStoreBox() }
    }

    func permission() async -> ConnectorPermission {
        EventKitPermission.current(for: .reminder)
    }

    func requestAccess() async -> ConnectorPermission {
        let box = stores.acquire()
        _ = try? await box.store.requestFullAccessToReminders()
        return EventKitPermission.current(for: .reminder)
    }

    func lists() async throws -> [String] {
        let box = stores.acquire()
        return box.store.calendars(for: .reminder).map(\.title).sorted()
    }

    func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        let box = stores.acquire()
        let reminder = EKReminder(eventStore: box.store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = calendar(named: draft.listName, in: box.store)
        if let due = draft.due {
            var components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            components.timeZone = .current
            reminder.dueDateComponents = components
        }
        do {
            try box.store.save(reminder, commit: true)
        } catch {
            throw EventKitPermission.storeError(error)
        }
        return Self.item(reminder)
    }

    func items(_ scope: ReminderScope) async throws -> [ReminderItem] {
        let box = stores.acquire()
        let range = ReminderWindow.range(for: scope.window)
        let calendars = calendar(named: scope.listName, in: box.store).map { [$0] }
        let predicate = box.store.predicateForIncompleteReminders(
            withDueDateStarting: range.start,
            ending: range.end,
            calendars: calendars
        )
        let items = await withCheckedContinuation { (continuation: CheckedContinuation<[ReminderItem], Never>) in
            box.store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.item))
            }
        }
        return Array(items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(scope.limit))
    }

    func complete(id: String) async throws {
        let box = stores.acquire()
        guard let reminder = box.store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw StoreError("There is no reminder with that id any more.")
        }
        reminder.isCompleted = true
        do {
            try box.store.save(reminder, commit: true)
        } catch {
            throw EventKitPermission.storeError(error)
        }
    }

    /// The list to use: the named one, or EventKit's default.
    private func calendar(named name: String?, in store: EKEventStore) -> EKCalendar? {
        guard let name else { return store.defaultCalendarForNewReminders() }
        return store.calendars(for: .reminder).first { $0.title == name }
            ?? store.defaultCalendarForNewReminders()
    }

    /// Maps an EventKit reminder to the value type the tools use.
    private static func item(_ reminder: EKReminder) -> ReminderItem {
        ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            listName: reminder.calendar?.title ?? "",
            due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
            notes: reminder.notes ?? "",
            isCompleted: reminder.isCompleted
        )
    }
}
