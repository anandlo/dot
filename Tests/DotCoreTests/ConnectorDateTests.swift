import Foundation
import XCTest

@testable import DotCore

/// Dates the model writes.
///
/// A model cannot send a `Date`. It sends text, and "Friday at 9" means nine
/// o'clock where the person is. One parser decides for every tool, and it
/// refuses anything that is not a date rather than guessing.
final class ConnectorDateTests: XCTestCase {
    private func components(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    func testALocalDateTimeIsReadInTheLocalZone() throws {
        let date = try XCTUnwrap(ToolDate.parse("2026-11-13T09:30"))
        let parts = components(date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 11)
        XCTAssertEqual(parts.day, 13)
        XCTAssertEqual(parts.hour, 9)
        XCTAssertEqual(parts.minute, 30)
    }

    func testASecondsPrecisionDateTimeIsRead() throws {
        let date = try XCTUnwrap(ToolDate.parse("2026-11-13T09:30:15"))
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        XCTAssertEqual(parts.hour, 9)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertEqual(parts.second, 15)
    }

    func testAZonedDateTimeIsRead() throws {
        let date = try XCTUnwrap(ToolDate.parse("2026-11-13T09:30:00Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_794_562_200, accuracy: 1)
    }

    func testADateWithoutATimeIsMidnightLocal() throws {
        let date = try XCTUnwrap(ToolDate.parse("2026-11-13"))
        let parts = components(date)
        XCTAssertEqual(parts.hour, 0)
        XCTAssertEqual(parts.minute, 0)
    }

    func testTextThatIsNotADateIsRefused() {
        XCTAssertNil(ToolDate.parse("Friday"))
        XCTAssertNil(ToolDate.parse("next week"))
        XCTAssertNil(ToolDate.parse(""))
        XCTAssertNil(ToolDate.parse("2026-13-01"))
        XCTAssertNil(ToolDate.parse("2026-11-13T09:30:00Z and more"))
        XCTAssertNil(ToolDate.parse(String(repeating: "9", count: 60)))
    }

    func testAYearOutsideTheWindowIsRefused() {
        XCTAssertNil(ToolDate.parse("1800-01-01"))
        XCTAssertNil(ToolDate.parse("2999-01-01"))
    }

    func testDescribingADateIsStable() throws {
        let date = try XCTUnwrap(ToolDate.parse("2026-11-13T09:05"))
        let described = ToolDate.describe(date)
        XCTAssertTrue(described.contains("09:05"))
        XCTAssertFalse(ToolDate.describeDay(date).contains(":"), "A day has no time")
    }
}
