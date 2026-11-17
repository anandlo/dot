import AppKit
import CoreGraphics
import SwiftUI
import XCTest

@testable import Dot

/// Where the open list lands, and how big it is.
///
/// The placement is the part of a menu that cannot be seen in a screenshot: a
/// list four points below the trigger and one off the bottom of the screen look
/// the same in a PNG. The cases here are the ones a screen can produce.
@MainActor
final class DotSelectPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: Below and above

    func testTheCardHangsBelowTheTriggerWhenTheScreenHasRoom() {
        let anchor = CGRect(x: 500, y: 600, width: 220, height: 29)
        let size = CGSize(width: 220, height: 120)
        let frame = DotSelectPlacement.frame(anchor: anchor, size: size, visibleFrame: screen)

        XCTAssertEqual(frame.minX, anchor.minX, accuracy: 0.001, "the left edges are aligned")
        XCTAssertEqual(
            frame.maxY,
            anchor.minY - DotSelectPlacement.gap,
            accuracy: 0.001,
            "the top edge sits one gap below the trigger"
        )
        XCTAssertEqual(frame.width, 220)
        XCTAssertEqual(frame.height, 120)
        XCTAssertTrue(DotSelectPlacement.opensBelow(anchor: anchor, size: size, visibleFrame: screen))
    }

    func testTheCardOpensAboveTheTriggerWhenThereIsNoRoomBelow() {
        let anchor = CGRect(x: 500, y: 60, width: 220, height: 29)
        let size = CGSize(width: 220, height: 120)
        let frame = DotSelectPlacement.frame(anchor: anchor, size: size, visibleFrame: screen)

        XCTAssertEqual(
            frame.minY,
            anchor.maxY + DotSelectPlacement.gap,
            accuracy: 0.001,
            "the bottom edge sits one gap above the trigger"
        )
        XCTAssertEqual(frame.minX, anchor.minX, accuracy: 0.001)
        XCTAssertFalse(DotSelectPlacement.opensBelow(anchor: anchor, size: size, visibleFrame: screen))
    }

    func testACardThatFitsOnNeitherSideStaysOnTheScreen() {
        let anchor = CGRect(x: 500, y: 200, width: 220, height: 29)
        let size = CGSize(width: 220, height: 500)
        let frame = DotSelectPlacement.frame(anchor: anchor, size: size, visibleFrame: screen)

        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    // MARK: Width and height

    func testTheTriggerWidthIsTheCardWidthWhenTheRowsAreNarrower() {
        let size = DotSelectPlacement.size(
            triggerWidth: 220,
            widestRow: 180,
            rowHeights: [28, 28]
        )
        XCTAssertEqual(size.width, 220)
    }

    func testAWiderRowWidensTheCardByItsOwnInset() {
        let size = DotSelectPlacement.size(
            triggerWidth: 220,
            widestRow: 300,
            rowHeights: [28]
        )
        XCTAssertEqual(size.width, 300 + 2 * DotSelectPlacement.inset)
    }

    func testTheWidthStopsAtTheCap() {
        let size = DotSelectPlacement.size(
            triggerWidth: 220,
            widestRow: 600,
            rowHeights: [28]
        )
        XCTAssertEqual(size.width, DotSelectPlacement.maxWidth)
        XCTAssertEqual(DotSelectPlacement.maxWidth, 360)
    }

    /// A list taller than the cap stops on whole rows and the title line of the
    /// next one: a card cut at its last whole row reads as the end of the list,
    /// and a card cut through the middle of the next row's letters reads as a
    /// drawing mistake. The hint is the height of that row's title line, so the
    /// word is legible and nothing below it is drawn.
    func testTheHeightStopsOnWholeRowsAndTheNextRowsTitle() {
        let size = DotSelectPlacement.size(
            triggerWidth: 220,
            widestRow: 100,
            rowHeights: Array(repeating: 28, count: 20)
        )
        let whole = 10 * DotSelectPlacement.rowHeight
        let expected = whole + DotSelectPlacement.hint + 2 * DotSelectPlacement.inset
        XCTAssertEqual(size.height, expected)
        XCTAssertEqual(size.height, 310)
        XCTAssertLessThanOrEqual(size.height, DotSelectPlacement.maxHeight)
        XCTAssertEqual(DotSelectPlacement.hint, 22, "the hint is one title line, not half a row")
        XCTAssertEqual(DotSelectPlacement.maxHeight, 320)
    }

    /// The cap holds with the mixed rows a settings page produces: a title-only
    /// row is 28 points, a row with a subtitle 40, and the card never grows past
    /// its maximum whatever the mix.
    func testTheCapHoldsForMixedRows() {
        let mixes: [[CGFloat]] = [
            Array(repeating: 28, count: 20),
            Array(repeating: 40, count: 20),
            (0..<20).map { $0.isMultiple(of: 3) ? 40 : 28 },
            [40, 28, 28, 40, 40, 28, 40, 28, 28, 40, 40, 28, 28, 40, 28, 40, 28, 28, 40, 40],
        ]
        for rows in mixes {
            let size = DotSelectPlacement.size(triggerWidth: 220, widestRow: 100, rowHeights: rows)
            XCTAssertLessThanOrEqual(size.height, DotSelectPlacement.maxHeight, "a \(rows.count) row list is too tall")
            XCTAssertGreaterThan(size.height, 2 * DotSelectPlacement.inset + DotSelectPlacement.hint)
            let whole = size.height - DotSelectPlacement.hint - 2 * DotSelectPlacement.inset
            XCTAssertEqual(whole, whole.rounded(), "the card stops on a whole row")
        }
    }

    /// The next row is cut below its title and above its detail, so the title is
    /// whole and the detail line is absent rather than sliced.
    func testTheHintCoversATitleLineAndNoMore() {
        XCTAssertEqual(DotSelectPlacement.hint, 22, "the title line, and not the detail line under it")
        XCTAssertLessThan(DotSelectPlacement.hint, DotSelectPlacement.rowHeight)
        XCTAssertGreaterThan(DotSelectPlacement.hint, DotSelectPlacement.rowHeight / 2)
    }

    /// A list that fits is exactly its rows and the inset, with no hint.
    func testAShortListShowsNoHalfRow() {
        let rowHeights: [CGFloat] = [28, 40, 28]
        XCTAssertEqual(
            DotSelectPlacement.size(triggerWidth: 220, widestRow: 100, rowHeights: rowHeights).height,
            96 + 2 * DotSelectPlacement.inset
        )
    }

    func testTheHeightIsTheRowsPlusTheInset() {
        let size = DotSelectPlacement.size(
            triggerWidth: 220,
            widestRow: 100,
            rowHeights: [28, 40, 28]
        )
        XCTAssertEqual(size.height, 96 + 2 * DotSelectPlacement.inset)
    }

    func testARowWithADetailLineIsTaller() {
        XCTAssertEqual(DotSelectPlacement.rowHeight(detail: nil), 28)
        XCTAssertEqual(DotSelectPlacement.rowHeight(detail: "Requires API key"), 40)
    }

    // MARK: Where the list opens

    /// The offset a list opens on for each kind of row a selection can name: the
    /// first row flush with the top, the last flush with the foot, and a middle
    /// row centred in the card.
    func testARowOpensWhereItsPlaceInTheListAllows() {
        let fifteen = Array(repeating: DotSelectPlacement.rowHeight, count: 15)
        let viewport: CGFloat = 310

        XCTAssertEqual(
            DotSelectPlacement.openOffset(rowHeights: fifteen, selected: 0, viewport: viewport),
            0,
            "the first row did not open flush with the top"
        )
        XCTAssertEqual(
            DotSelectPlacement.openOffset(rowHeights: fifteen, selected: 7, viewport: viewport),
            59,
            accuracy: 0.001,
            "a middle row is not centred in the card"
        )
        XCTAssertEqual(
            DotSelectPlacement.openOffset(rowHeights: fifteen, selected: 14, viewport: viewport),
            118,
            accuracy: 0.001,
            "the last row did not open flush with the foot"
        )
    }

    /// The speech provider list: eight rows that all carry a detail, so the card
    /// holds seven of them and the list travels eighteen points. A row far enough
    /// down to be centred would need more travel than the list has, so it opens
    /// at the foot.
    func testAnEightRowListWithDetailsOpensItsLastRowsAtTheFoot() {
        let heights = Array(repeating: DotSelectPlacement.rowDetailHeight, count: 8)
        let viewport: CGFloat = 310

        XCTAssertEqual(
            DotSelectPlacement.openOffset(rowHeights: heights, selected: 0, viewport: viewport),
            0
        )
        XCTAssertEqual(
            DotSelectPlacement.openOffset(rowHeights: heights, selected: 4, viewport: viewport),
            18,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DotSelectPlacement.openOffset(rowHeights: heights, selected: 7, viewport: viewport),
            18,
            accuracy: 0.001,
            "the last row did not open flush with the foot"
        )
    }

    /// A selection that names no row, an empty list and a card that has not been
    /// measured all open at the top: there is no row to show.
    func testAnOffsetNeedsARowAndAViewport() {
        let three = Array(repeating: DotSelectPlacement.rowHeight, count: 3)
        XCTAssertEqual(DotSelectPlacement.openOffset(rowHeights: three, selected: nil, viewport: 310), 0)
        XCTAssertEqual(DotSelectPlacement.openOffset(rowHeights: three, selected: 9, viewport: 310), 0)
        XCTAssertEqual(DotSelectPlacement.openOffset(rowHeights: [], selected: 0, viewport: 310), 0)
        XCTAssertEqual(DotSelectPlacement.openOffset(rowHeights: three, selected: 2, viewport: 0), 0)
    }

    /// A list shorter than its card has no travel: every row opens at zero.
    func testAListThatFitsOpensAtTheTopWhicheverRowIsChosen() {
        let three = Array(repeating: DotSelectPlacement.rowHeight, count: 3)
        let viewport = 3 * DotSelectPlacement.rowHeight + 2 * DotSelectPlacement.inset
        for row in 0..<3 {
            XCTAssertEqual(
                DotSelectPlacement.openOffset(rowHeights: three, selected: row, viewport: viewport),
                0,
                "a list that fits was asked to scroll for row \(row)"
            )
        }
    }

    /// Whatever the selection, the offset is inside the document: the list is
    /// never asked to travel further than it can.
    func testTheOffsetStaysInsideTheList() {
        for count in [1, 2, 8, 15, 60] {
            for detail in [false, true] {
                let heights = Array(
                    repeating: DotSelectPlacement.rowHeight(detail: detail ? "detail" : nil),
                    count: count
                )
                let content = heights.reduce(0, +) + 2 * DotSelectPlacement.inset
                let limit = max(0, content - 310)
                for row in 0..<count {
                    let offset = DotSelectPlacement.openOffset(
                        rowHeights: heights,
                        selected: row,
                        viewport: 310
                    )
                    XCTAssertGreaterThanOrEqual(offset, 0, "\(count) rows, row \(row) is above the top")
                    XCTAssertLessThanOrEqual(offset, limit, "\(count) rows, row \(row) is past the foot")
                }
            }
        }
    }

    // MARK: The drawn width

    /// One width for every picker a row does not size itself.
    func testATriggerWithoutAWidthDrawsTheSettingsColumn() {
        let hosting = NSHostingView(
            rootView: DotSelect(
                label: "Recording mode",
                options: [
                    DotSelectOption(value: "toggle", title: "Press to start, press to stop"),
                ],
                selection: .constant("toggle"),
                width: nil
            )
        )
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, 240, accuracy: 0.5)
        XCTAssertEqual(DotSelectMetrics.settingsColumn, 240)
    }

    func testATriggerWithAWidthDrawsThatWidth() {
        let hosting = NSHostingView(
            rootView: DotSelect(
                label: "Service",
                options: [DotSelectOption(value: "openai", title: "OpenAI")],
                selection: .constant("openai"),
                width: 220
            )
        )
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, 220, accuracy: 0.5)
    }

    // MARK: Measuring a row

    func testAWiderTitleMakesAWiderRow() {
        let short = DotSelectListMetrics.widestRow([DotSelectRow(title: "Ava")])
        let long = DotSelectListMetrics.widestRow([
            DotSelectRow(title: "Daniel", detail: "Enhanced. British English."),
        ])
        XCTAssertGreaterThan(long, short)
    }

    /// A card measured to the longest word, not to a font's guess at it.
    func testTheMeasuredRowHoldsItsColumnsAndItsLongestTitle() {
        let title = "Press to start, press to stop"
        let measured = DotSelectListMetrics.widestRow([DotSelectRow(title: title)])
        let appKit = (title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12.5)]
        ).width
        XCTAssertGreaterThan(
            measured,
            appKit
                + DotSelectListMetrics.checkColumn
                + DotSelectListMetrics.checkGap
                + 2 * DotSelectListMetrics.rowPadding
        )
    }

    /// The check column and its gap belong to every row, so a list without
    /// symbols does not let the checkmark touch the title.
    func testTheCheckColumnAndItsGapAreReservedWithoutSymbols() {
        XCTAssertGreaterThanOrEqual(DotSelectListMetrics.checkColumn, 14)
        XCTAssertGreaterThanOrEqual(DotSelectListMetrics.checkGap, 6)
    }

    /// One symbol anywhere gives the whole list a symbol column, so its titles
    /// start at one place.
    func testAListReservesItsSymbolColumnWhenAnyRowCarriesASymbol() {
        XCTAssertFalse(
            DotSelectListMetrics.reservesSymbolColumn([
                DotSelectRow(title: "Ava"),
                DotSelectRow(title: "Daniel"),
            ])
        )
        XCTAssertTrue(
            DotSelectListMetrics.reservesSymbolColumn([
                DotSelectRow(title: "Ava"),
                DotSelectRow(title: "OpenAI", symbol: "cloud"),
            ])
        )
        let mixed = DotSelectListMetrics.widestRow([
            DotSelectRow(title: "Ava"),
            DotSelectRow(title: "OpenAI", symbol: "cloud"),
        ])
        let plain = DotSelectListMetrics.widestRow([
            DotSelectRow(title: "Ava"),
            DotSelectRow(title: "OpenAI"),
        ])
        XCTAssertGreaterThan(
            mixed,
            plain,
            "the reserved symbol column widens a mixed list by its own width"
        )
    }
}
