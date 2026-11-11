import EventKit
import Foundation
import DotCore

/// Holds one `EKEventStore`, which is not `Sendable` in the SDK but is
/// documented as safe to use from several threads.
///
/// The box exists so the store can live inside ``LazyResource``, which only
/// holds `Sendable` values. Nothing else about EventKit is shared: each call
/// takes the store, does one operation, and returns value types.
final class EventKitStoreBox: @unchecked Sendable {
    let store = EKEventStore()
}

/// Maps EventKit's authorization to Dot's.
enum EventKitPermission {
    /// Reads the current status without prompting.
    ///
    /// - Parameter entity: reminders or events.
    /// - Returns: the permission, with the pane that fixes a refusal.
    static func current(for entity: EKEntityType) -> ConnectorPermission {
        let status = EKEventStore.authorizationStatus(for: entity)
        let service = entity == .reminder ? "Reminders" : "Calendar"
        let pane: ConnectorPermission.Pane = entity == .reminder ? .reminders : .calendars
        switch status {
        case .fullAccess:
            return ConnectorPermission(status: .granted, service: service, settingsURL: pane.url)
        case .writeOnly:
            // A write-only grant covers create but not read. The create tools
            // work; a read tool answers with the failure the store reports, and
            // the person can widen the grant from the same pane.
            return ConnectorPermission(status: .granted, service: service, settingsURL: pane.url)
        case .denied:
            return .from(granted: false, denied: true, service: service, pane: pane)
        case .restricted:
            return ConnectorPermission(
                status: .restricted,
                service: service,
                remedy: "Access is controlled by a profile on this Mac.",
                settingsURL: pane.url
            )
        default:
            return .from(granted: false, denied: false, service: service, pane: pane)
        }
    }

    /// Translates an EventKit error into a sentence.
    ///
    /// - Parameter error: the error EventKit threw.
    /// - Returns: the store error a tool result can show.
    static func storeError(_ error: Error) -> StoreError {
        let code = (error as NSError).code
        switch code {
        case EKError.eventStoreNotAuthorized.rawValue:
            return StoreError("Dot does not have permission. Allow it in System Settings, Privacy and Security.")
        case EKError.noCalendar.rawValue:
            return StoreError("There is no calendar for that.")
        default:
            return StoreError("The calendar store refused the request.")
        }
    }
}

/// The date window one reminder listing covers.
enum ReminderWindow {
    /// The range a scope means, in the person's time zone.
    ///
    /// - Parameter window: today, tomorrow, this week or overdue.
    /// - Returns: the start and end of the range.
    static func range(for window: ReminderScope.Window) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch window {
        case .today:
            return (today, calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        case .tomorrow:
            let start = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            return (start, calendar.date(byAdding: .day, value: 2, to: today) ?? start)
        case .week:
            return (today, calendar.date(byAdding: .day, value: 7, to: today) ?? today)
        case .overdue:
            let start = calendar.date(byAdding: .day, value: -365, to: today) ?? today
            return (start, Date())
        }
    }
}
