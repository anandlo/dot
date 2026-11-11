import Foundation
import XCTest

@testable import DotCore

/// The byte budget a tool result is cut to.
///
/// A search or a shortcut can return more text than the rest of the conversation
/// put together. Cutting it is what keeps the turn fast and the instructions in
/// the model's attention; the tests pin that the cut is inside the budget, never
/// splits a character, and says how much was dropped.
final class ConnectorResultBudgetTests: XCTestCase {
    func testShortTextIsUnchanged() {
        let fitted = ToolResultBudget(bytes: 100).fit("hello")
        XCTAssertEqual(fitted.text, "hello")
        XCTAssertFalse(fitted.wasTruncated)
        XCTAssertEqual(fitted.originalByteCount, 5)
    }

    func testTextAtTheBudgetIsUnchanged() {
        let text = String(repeating: "a", count: 100)
        let fitted = ToolResultBudget(bytes: 100).fit(text)
        XCTAssertEqual(fitted.text, text)
        XCTAssertFalse(fitted.wasTruncated)
    }

    func testLongTextFitsAndSaysHowMuchThereWas() {
        let text = String(repeating: "a", count: 5_000)
        let fitted = ToolResultBudget(bytes: 500).fit(text)
        XCTAssertLessThanOrEqual(fitted.text.utf8.count, 500)
        XCTAssertTrue(fitted.wasTruncated)
        XCTAssertTrue(fitted.text.contains("[truncated, 5000 bytes total]"))
        XCTAssertEqual(fitted.originalByteCount, 5_000)
    }

    func testTheCutNeverSplitsACharacter() {
        let text = String(repeating: "\u{1F600}", count: 500)
        let fitted = ToolResultBudget(bytes: 300).fit(text)
        XCTAssertLessThanOrEqual(fitted.text.utf8.count, 300)
        // A split character would make this decode produce the replacement
        // character, and the model would read mojibake.
        XCTAssertFalse(fitted.text.contains("\u{FFFD}"))
        XCTAssertEqual(String(decoding: Array(fitted.text.utf8), as: UTF8.self), fitted.text)
    }

    func testALineBoundaryIsPreferredWhenItIsClose() {
        let line = String(repeating: "x", count: 49) + "\n"
        let text = String(repeating: line, count: 20)
        let fitted = ToolResultBudget(bytes: 300).fit(text)
        let body = fitted.text.components(separatedBy: "\n[truncated").first ?? fitted.text
        XCTAssertTrue(body.hasSuffix("\n"), "The cut should land after a whole line, not mid-word")
        XCTAssertFalse(body.contains(String(repeating: "x", count: 50)), "A partial line was kept")
    }

    func testTheBudgetHasAFloor() {
        // A budget so small that the note would not fit still produces a
        // usable result rather than an empty string.
        let fitted = ToolResultBudget(bytes: 1).fit(String(repeating: "a", count: 1_000))
        XCTAssertFalse(fitted.text.isEmpty)
        XCTAssertTrue(fitted.wasTruncated)
    }

    func testAnEmptyResultStaysEmpty() {
        let fitted = ToolResultBudget(bytes: 100).fit("")
        XCTAssertEqual(fitted.text, "")
        XCTAssertFalse(fitted.wasTruncated)
    }
}
