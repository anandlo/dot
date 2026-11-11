import Foundation
import XCTest

@testable import DotCore

/// Reminders and Calendar: what a tool does with the bytes a model sends.
///
/// The stores are fakes, so nothing here touches EventKit, and the tests can
/// assert both the result and the draft the store was asked to save.
final class ConnectorRemindersCalendarTests: XCTestCase {
    func testCreatingAReminderParsesTheDueDate() async throws {
        let store = FakeReminderStore()
        let connector = RemindersConnector(store: store)
        let call = try validatedCall(connector, name: "reminders_create", arguments: [
            "title": "Send the deck",
            "due": .string("2026-11-13T09:00"),
            "list": .string("Work"),
        ])
        let outcome = await connector.invoke(call)
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("Created Send the deck"))
        let drafts = await store.recorder.drafts
        XCTAssertEqual(drafts.count, 1)
        let due = try XCTUnwrap(drafts.first?.due)
        let parts = Calendar.current.dateComponents([.hour, .minute], from: due)
        XCTAssertEqual(parts.hour, 9)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertEqual(drafts.first?.listName, "Work")
    }

    func testCreatingAReminderWithABadDateHasNoSideEffect() async throws {
        let store = FakeReminderStore()
        let connector = RemindersConnector(store: store)
        let call = try validatedCall(connector, name: "reminders_create", arguments: [
            "title": "Send the deck",
            "due": .string("Friday"),
        ])
        let outcome = await connector.invoke(call)
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("ISO 8601"))
        let drafts = await store.recorder.drafts
        XCTAssertTrue(drafts.isEmpty, "A date the tool cannot read must not reach the store")
    }

    func testListingPassesTheWindowAndFormatsTheItems() async throws {
        let store = FakeReminderStore()
        let connector = RemindersConnector(store: store)
        let call = try validatedCall(connector, name: "reminders_list", arguments: [
            "when": .string("week"),
            "limit": .number(5),
        ])
        let outcome = await connector.invoke(call)
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("Pay rent"))
        XCTAssertTrue(outcome.text.contains("id r1"))
        let scopes = await store.recorder.scopes
        XCTAssertEqual(scopes.first?.window, .week)
        XCTAssertEqual(scopes.first?.limit, 5)
    }

    func testCompletingUsesTheId() async throws {
        let store = FakeReminderStore()
        let connector = RemindersConnector(store: store)
        let call = try validatedCall(connector, name: "reminders_complete", arguments: ["id": .string("r1")])
        let outcome = await connector.invoke(call)
        XCTAssertFalse(outcome.isError)
        let completed = await store.recorder.completed
        XCTAssertEqual(completed, ["r1"])
    }

    func testCreatingAnEventComputesTheEnd() async throws {
        let store = FakeCalendarStore()
        let connector = CalendarConnector(store: store)
        let call = try validatedCall(connector, name: "calendar_create", arguments: [
            "title": "Plan the week",
            "start": .string("2026-11-16T10:00"),
            "minutes": .number(45),
        ])
        let outcome = await connector.invoke(call)
        XCTAssertFalse(outcome.isError)
        let drafts = await store.recorder.drafts
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.end.timeIntervalSince(draft.start), 45 * 60, accuracy: 1)
    }

    func testTheDayWindowForTomorrowStartsTomorrow() async throws {
        let store = FakeCalendarStore()
        let connector = CalendarConnector(store: store)
        let call = try validatedCall(connector, name: "calendar_events", arguments: ["range": .string("tomorrow")])
        _ = await connector.invoke(call)
        let ranges = await store.recorder.ranges
        let range = try XCTUnwrap(ranges.first)
        let startDay = Calendar.current.startOfDay(for: range.0)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: ToolDate.startOfDay(Date())) ?? Date()
        XCTAssertTrue(Calendar.current.isDate(startDay, inSameDayAs: tomorrow))
    }

    func testAnEventWithABadStartHasNoSideEffect() async throws {
        let store = FakeCalendarStore()
        let connector = CalendarConnector(store: store)
        let call = try validatedCall(connector, name: "calendar_create", arguments: [
            "title": "Plan the week",
            "start": .string("tomorrow morning"),
        ])
        let outcome = await connector.invoke(call)
        XCTAssertTrue(outcome.isError)
        let drafts = await store.recorder.drafts
        XCTAssertTrue(drafts.isEmpty)
    }

    func testAPermissionRefusalIsReportedWithTheFix() async {
        let connector = RemindersConnector(store: FakeReminderStore(status: .denied))
        let permission = await connector.permission()
        XCTAssertEqual(permission.status, .denied)
        XCTAssertEqual(permission.settingsURL, ConnectorPermission.Pane.reminders.url)
        XCTAssertTrue(permission.remedy?.contains("System Settings") == true)
    }
}
