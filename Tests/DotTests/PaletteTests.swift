import AppKit
import DotCore
@testable import Dot
import XCTest

/// The palette's panel and model.
///
/// The controller runs without activating the app (`PaletteController(activates:)`),
/// so the suite never takes focus away from whatever the person running it is
/// doing. What is left to prove is the behaviour: a summoned palette lists the
/// history, a query filters it, the arrows wrap, Return inserts, Shift-Return
/// copies, and Escape dismisses.
@MainActor
final class PaletteTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private var entries: [HistoryStore.Entry] {
        [
            HistoryStore.Entry(text: "Ship the palette on Thursday.", addedAt: now.addingTimeInterval(-7_200)),
            HistoryStore.Entry(text: "Water the fig tree tomorrow.", addedAt: now.addingTimeInterval(-90)),
            HistoryStore.Entry(text: "The retry loop stops after three attempts.", addedAt: now),
        ]
    }

    private func model() -> PaletteModel {
        PaletteModel(now: { [now] in now })
    }

    // MARK: - The model

    func testThePaletteListsTheHistoryNewestFirst() {
        let model = model()
        model.present(entries: entries)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.rows.first?.text, entries[0].text)
        XCTAssertEqual(model.rows.first?.age, "2h ago")
        XCTAssertEqual(model.selectedRow?.text, entries[0].text)
    }

    func testTheQueryFiltersAndSelectsTheBestMatch() {
        let model = model()
        model.present(entries: entries)
        model.query = "fig"
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.selectedRow?.text, entries[1].text)

        model.query = "zebra"
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.selectedRow, "an empty list has nothing selected")
    }

    func testAQueryThatMatchesNothingLeavesThePaletteEmptyRatherThanStale() {
        let model = model()
        model.present(entries: entries)
        model.query = "ship"
        XCTAssertEqual(model.rows.count, 1)
        model.query = ""
        XCTAssertEqual(model.rows.count, 3, "clearing the search shows the history again")
    }

    func testTheSelectionWrapsWithTheArrows() {
        let model = model()
        model.present(entries: entries)
        model.move(by: -1)
        XCTAssertEqual(model.selectedRow?.text, entries[2].text, "up from the first row wraps to the last")
        model.move(by: 1)
        XCTAssertEqual(model.selectedRow?.text, entries[0].text, "down from the last row wraps to the first")
    }

    func testASecondSummonStartsWithAnEmptySearch() {
        let model = model()
        model.present(entries: entries)
        model.query = "fig"
        model.present(entries: entries)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.rows.count, 3)
    }

    func testAnEmptyHistoryDrawsAnEmptyPalette() {
        let model = model()
        model.present(entries: [])
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.selectedRow)
        XCTAssertEqual(model.selection, 0)
    }

    func testAnEntryWithoutADateHasNoAge() {
        let model = model()
        model.present(entries: [HistoryStore.Entry(text: "older words")])
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertNil(model.rows.first?.age)
    }

    func testTheRowIsOnePreviewLine() {
        let model = model()
        model.present(entries: [HistoryStore.Entry(text: "One.\n\nTwo.", addedAt: now)])
        XCTAssertEqual(model.rows.first?.preview, "One. Two.")
    }

    // MARK: - The panel

    func testEscapeDismissesThePalette() {
        _ = NSApplication.shared
        let controller = PaletteController(activates: false)
        controller.show(entries: entries, insert: { _ in }, copy: { _ in })
        XCTAssertTrue(controller.isVisible)

        XCTAssertEqual(controller.perform(.escape), .dismiss)
        XCTAssertFalse(controller.isVisible)
    }

    func testReturnInsertsTheSelectedTranscriptAndCloses() {
        _ = NSApplication.shared
        let controller = PaletteController(activates: false)
        var inserted: [String] = []
        controller.show(entries: entries, insert: { inserted.append($0) }, copy: { _ in })

        XCTAssertEqual(controller.perform(.returnKey), .insert)
        XCTAssertEqual(inserted, [entries[0].text])
        XCTAssertFalse(controller.isVisible, "the palette leaves before the paste is posted")
    }

    func testShiftReturnCopiesWithoutInserting() {
        _ = NSApplication.shared
        let controller = PaletteController(activates: false)
        var inserted: [String] = []
        var copied: [String] = []
        controller.show(
            entries: entries,
            insert: { inserted.append($0) },
            copy: { copied.append($0) }
        )
        controller.perform(.down)
        XCTAssertEqual(controller.perform(.shiftReturn), .copyOnly)
        XCTAssertEqual(copied, [entries[1].text])
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertFalse(controller.isVisible)
    }

    func testReturnInAnEmptyPaletteDoesNothing() {
        _ = NSApplication.shared
        let controller = PaletteController(activates: false)
        var inserted: [String] = []
        controller.show(entries: [], insert: { inserted.append($0) }, copy: { _ in })

        XCTAssertEqual(controller.perform(.returnKey), .ignore)
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertTrue(controller.isVisible, "an empty palette is not dismissed by Return")
        controller.dismiss(restoringFocus: false)
    }

    func testTheArrowsMoveTheSelectionThroughThePanel() {
        _ = NSApplication.shared
        let controller = PaletteController(activates: false)
        controller.show(entries: entries, insert: { _ in }, copy: { _ in })
        XCTAssertEqual(controller.debugSelectedText, entries[0].text)

        controller.perform(.down)
        XCTAssertEqual(controller.debugSelectedText, entries[1].text)
        controller.perform(.up)
        controller.perform(.up)
        XCTAssertEqual(controller.debugSelectedText, entries[2].text, "up from the first row wraps")
        controller.dismiss(restoringFocus: false)
    }

    func testThePanelIsNonActivatingAndCanTakeTheKeyboard() {
        _ = NSApplication.shared
        let controller = PaletteController(activates: false)
        controller.show(entries: entries, insert: { _ in }, copy: { _ in })
        let panel = try? XCTUnwrap(NSApp.windows.first { $0 is PalettePanel })
        XCTAssertNotNil(panel)
        XCTAssertEqual(panel?.styleMask.contains(.nonactivatingPanel), true)
        XCTAssertEqual((panel as? PalettePanel)?.canBecomeKey, true)
        XCTAssertEqual((panel as? PalettePanel)?.canBecomeMain, false)
        controller.dismiss(restoringFocus: false)
    }

    func testAKeyThePaletteDoesNotUseIsLeftForTheField() {
        _ = NSApplication.shared
        let controller = PaletteController(activates: false)
        controller.show(entries: entries, insert: { _ in }, copy: { _ in })

        // A plain character is not consumed: it has to reach the search field.
        let typing = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )
        XCTAssertEqual(typing.map(controller.handle), false)
        controller.dismiss(restoringFocus: false)
    }
}
