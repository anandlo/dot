import AppKit
import DotCore
import XCTest

@testable import Dot

/// The open list, drawn offscreen beside its trigger.
///
/// The list is a window, so it cannot be captured from a hosting view; the
/// preview draws the shipped trigger view and the shipped card view in the
/// places the panel would put them. The captures are proof that both halves
/// draw, in both appearances.
@MainActor
final class DotSelectRenderTests: XCTestCase {
    private let names = [
        "select-open-service.png",
        "select-open-service-dark.png",
        "select-open-recording-mode.png",
        "select-open-recording-mode-dark.png",
    ]

    func testTheOpenListsRenderToPNGs() throws {
        guard let value = DotMigration.environment("RENDER_UI_DIR"),
              !value.isEmpty
        else {
            throw XCTSkip("Set DOT_RENDER_UI_DIR to render the open lists.")
        }

        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try UIPreview.renderSelectLists(to: directory)

        let size = UIPreview.selectPreviewSize
        for name in names {
            let url = directory.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name) was not written")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = try XCTUnwrap(attributes[.size] as? Int)
            XCTAssertGreaterThan(bytes, 10_240, "\(name) is smaller than 10 KB")

            let data = try Data(contentsOf: url)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "\(name) is not a PNG")
            XCTAssertEqual(bitmap.pixelsWide, Int(size.width) * 2, "\(name) width")
            XCTAssertEqual(bitmap.pixelsHigh, Int(size.height) * 2, "\(name) height")
        }
    }
}
