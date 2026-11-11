import EventKit
import Foundation
import DotCore

/// Calendar, through EventKit.
///
/// The same lazy shape as reminders: a static permission check, and an event
/// store that is created on first use and dropped after two idle minutes.
final class EventKitCalendarStore: CalendarStore, @unchecked Sendable {
    private let stores: LazyResource<EventKitStoreBox>

    /// Creates the store.
    ///
    /// - Parameter idle: how long the event store may sit unused.
    init(idle: Duration = .seconds(120)) {
        stores = LazyResource(idle: idle) { EventKitStoreBox() }
    }

    func permission() async -> ConnectorPermission {
        EventKitPermission.current(for: .event)
    }

    func requestAccess() async -> ConnectorPermission {
        let box = stores.acquire()
        _ = try? await box.store.requestFullAccessToEvents()
        return EventKitPermission.current(for: .event)
    }

    func calendars() async throws -> [String] {
        let box = stores.acquire()
        return box.store.calendars(for: .event).map(\.title).sorted()
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarItem] {
        let box = stores.acquire()
        let predicate = box.store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = box.store.events(matching: predicate)
        return events
            .map { event in
                CalendarItem(
                    id: event.eventIdentifier ?? "",
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    calendarName: event.calendar?.title ?? "",
                    location: event.location ?? "",
                    isAllDay: event.isAllDay
                )
            }
            .sorted { $0.start < $1.start }
    }

    func create(_ draft: EventDraft) async throws -> CalendarItem {
        let box = stores.acquire()
        let event = EKEvent(eventStore: box.store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.location = draft.location
        event.notes = draft.notes
        event.calendar = calendar(named: draft.calendarName, in: box.store)
        guard event.calendar != nil else {
            throw StoreError("There is no calendar to add the event to.")
        }
        do {
            try box.store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw EventKitPermission.storeError(error)
        }
        return CalendarItem(
            id: event.eventIdentifier ?? "",
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            calendarName: event.calendar?.title ?? "",
            location: event.location ?? "",
            isAllDay: event.isAllDay
        )
    }

    /// The named calendar, or the default for new events.
    private func calendar(named name: String?, in store: EKEventStore) -> EKCalendar? {
        guard let name else { return store.defaultCalendarForNewEvents }
        return store.calendars(for: .event).first { $0.title == name }
            ?? store.defaultCalendarForNewEvents
    }
}
