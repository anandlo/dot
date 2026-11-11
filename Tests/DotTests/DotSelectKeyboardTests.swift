import AppKit
import XCTest

@testable import Dot

/// The keyboard of an open list.
///
/// The list never becomes the key window, so this model is the only thing
/// standing between a key press and the window behind the list. Each rule the
/// owner can feel - the ends hold, the selection opens under the highlight, a
/// typed prefix jumps and then forgets - is a case here.
final class DotSelectKeyboardTests: XCTestCase {
    private let titles = ["Ava", "Daniel", "George", "Rachel"]

    func testTheSelectedRowOpensHighlighted() {
        let model = DotSelectKeyboardModel(titles: titles, selected: 2)
        XCTAssertEqual(model.highlight, 2)
        XCTAssertEqual(model.commitIndex, 2)
    }

    func testAListWithNoSelectionOpensOnTheFirstRow() {
        let model = DotSelectKeyboardModel(titles: titles, selected: nil)
        XCTAssertEqual(model.highlight, 0)
    }

    func testDownMovesOneRowAndStopsAtTheLast() {
        var model = DotSelectKeyboardModel(titles: titles, selected: 0)
        model.move(by: 1)
        XCTAssertEqual(model.highlight, 1)
        model.move(by: 1)
        model.move(by: 1)
        XCTAssertEqual(model.highlight, 3)
        model.move(by: 1)
        XCTAssertEqual(model.highlight, 3, "the list does not wrap")
    }

    func testUpMovesOneRowAndStopsAtTheFirst() {
        var model = DotSelectKeyboardModel(titles: titles, selected: 2)
        model.move(by: -1)
        XCTAssertEqual(model.highlight, 1)
        model.move(by: -1)
        model.move(by: -1)
        XCTAssertEqual(model.highlight, 0)
        model.move(by: -1)
        XCTAssertEqual(model.highlight, 0, "the list does not wrap")
    }

    func testAnEmptyListHasNothingToCommit() {
        var model = DotSelectKeyboardModel(titles: [], selected: nil)
        model.move(by: 1)
        XCTAssertNil(model.highlight)
        XCTAssertNil(model.commitIndex)
    }

    func testTypingJumpsToTheFirstRowWithThePrefix() {
        var model = DotSelectKeyboardModel(titles: titles, selected: 0)
        XCTAssertTrue(model.type("r", at: 0))
        XCTAssertEqual(model.highlight, 3)
        XCTAssertEqual(model.prefix, "r")
    }

    func testASecondLetterNarrowsThePrefixAndResetsTheClock() {
        var model = DotSelectKeyboardModel(titles: ["Ava", "Daniel", "George", "Rachel"], selected: 0)
        model.type("d", at: 10)
        XCTAssertEqual(model.prefix, "d")
        XCTAssertEqual(model.highlight, 1)
        model.type("a", at: 10.5)
        XCTAssertEqual(model.prefix, "da")
        XCTAssertEqual(model.highlight, 1)
        XCTAssertEqual(model.prefixAt, 10.5)
    }

    func testAPrefixIsForgottenAfterOneSecond() {
        var model = DotSelectKeyboardModel(titles: ["Ava", "Daniel", "George", "Rachel"], selected: 3)
        model.type("a", at: 0)
        XCTAssertEqual(model.highlight, 0)
        model.type("g", at: 0.5)
        XCTAssertEqual(model.prefix, "ag", "half a second is one search")
        XCTAssertEqual(model.highlight, 0, "no row starts with both letters")
        model.type("g", at: 2)
        XCTAssertEqual(model.prefix, "g", "two seconds later is a new search")
        XCTAssertEqual(model.highlight, 2)
        XCTAssertEqual(DotSelectKeyboardModel.typeReset, 1)
    }

    func testAPrefixThatMatchesNothingLeavesTheHighlightAlone() {
        var model = DotSelectKeyboardModel(titles: titles, selected: 2)
        XCTAssertFalse(model.type("z", at: 0))
        XCTAssertEqual(model.highlight, 2)
    }

    func testThePointerCanMoveTheHighlight() {
        var model = DotSelectKeyboardModel(titles: titles, selected: 0)
        model.highlightRow(3)
        XCTAssertEqual(model.highlight, 3)
        model.highlightRow(9)
        XCTAssertEqual(model.highlight, 3, "a row that is not there is ignored")
    }
}
