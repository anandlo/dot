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

    func testTheHeightStopsAtTheCapAndThenScrolls() {
        let size = DotSelectPlacement.size(
            triggerWidth: 220,
            widestRow: 100,
            rowHeights: Array(repeating: 28, count: 20)
        )
        XCTAssertEqual(size.height, DotSelectPlacement.maxHeight)
        XCTAssertEqual(DotSelectPlacement.maxHeight, 320)
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
