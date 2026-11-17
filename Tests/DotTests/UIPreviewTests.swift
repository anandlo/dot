import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// Drives the offscreen renderer for the light windows.
///
/// The test is skipped unless `DOT_RENDER_UI_DIR` points at a directory: it
/// writes files, so it is a developer tool rather than part of the normal
/// suite.
@MainActor
final class UIPreviewTests: XCTestCase {
    /// The app's typeface, registered before the first window is drawn.
    ///
    /// The packaged app is covered by `ATSApplicationFontsPath`; a test bundle
    /// is not. Without this every PNG here would be the fallback, which looks
    /// plausible and is a different product: the renders exist to be looked at,
    /// so they have to be drawn in the face the app ships.
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    func testWelcomeAndAboutRenderToPNGs() throws {
        guard let value = DotMigration.environment("RENDER_UI_DIR"),
              !value.isEmpty
        else {
            throw XCTSkip("Set DOT_RENDER_UI_DIR to render the light windows.")
        }

        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try UIPreview.renderWelcomeAndAbout(to: directory)

        let expected: [(name: String, size: CGSize)] = [
            ("welcome.png", CGSize(width: 720, height: 560)),
            ("welcome-dark.png", CGSize(width: 720, height: 560)),
            ("welcome-connected.png", CGSize(width: 720, height: 560)),
            ("welcome-provider.png", CGSize(width: 720, height: 560)),
            ("welcome-provider-dark.png", CGSize(width: 720, height: 560)),
            ("welcome-tour-hold.png", CGSize(width: 720, height: 560)),
            ("welcome-tour-speak.png", CGSize(width: 720, height: 560)),
            ("welcome-tour-paste.png", CGSize(width: 720, height: 560)),
            ("welcome-tour-hold-dark.png", CGSize(width: 720, height: 560)),
            ("welcome-tour-speak-dark.png", CGSize(width: 720, height: 560)),
            ("welcome-tour-paste-dark.png", CGSize(width: 720, height: 560)),
            ("welcome-tour-hold-early.png", CGSize(width: 720, height: 560)),
            ("welcome-connected-dark.png", CGSize(width: 720, height: 560)),
        ]
        for entry in expected {
            let url = directory.appendingPathComponent(entry.name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(entry.name) was not written"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try XCTUnwrap(attributes[.size] as? Int)
            XCTAssertGreaterThan(size, 10_240, "\(entry.name) is smaller than 10 KB")

            let data = try Data(contentsOf: url)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "\(entry.name) is not a PNG")
            XCTAssertEqual(bitmap.pixelsWide, Int(entry.size.width) * 2, "\(entry.name) width")
            XCTAssertEqual(bitmap.pixelsHigh, Int(entry.size.height) * 2, "\(entry.name) height")
        }
    }

    /// Two moments of the tour must not render the same card.
    ///
    /// The tour is an animation; a screenshot of it proves nothing on its own,
    /// so this compares two captured frames of the same step. If the stage ever
    /// stops reading the clock, the two files become identical and this fails.
    func testTheTourDrawsADifferentFrameAtADifferentMoment() throws {
        guard let value = DotMigration.environment("RENDER_UI_DIR"),
              !value.isEmpty
        else {
            throw XCTSkip("Set DOT_RENDER_UI_DIR to render the tour.")
        }

        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try UIPreview.renderWelcomeAndAbout(to: directory)

        let early = try Data(
            contentsOf: directory.appendingPathComponent("welcome-tour-hold-early.png")
        )
        let later = try Data(
            contentsOf: directory.appendingPathComponent("welcome-tour-hold.png")
        )
        XCTAssertNotEqual(
            early,
            later,
            "the tour drew the same frame at two different moments of the loop"
        )
    }

    func testSettingsRenderToPNGs() throws {
        guard let value = DotMigration.environment("RENDER_UI_DIR"),
              !value.isEmpty
        else {
            throw XCTSkip("Set DOT_RENDER_UI_DIR to render the settings window.")
        }

        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try UIPreview.renderSettings(to: directory)

        var names = [
            "settings-general.png",
            "settings-provider.png",
            "settings-provider-custom.png",
            "settings-shortcuts.png",
            "settings-appearance.png",
            "settings-about.png",
            "settings-general-dark.png",
            "settings-provider-dark.png",
            "settings-shortcuts-dark.png",
            "settings-appearance-dark.png",
            "settings-about-dark.png",
            "settings-provider-stored-endpoint.png",
            "settings-provider-azure.png",
            "settings-provider-connected.png",
            "settings-provider-connected-dark.png",
            "settings-about-update-current.png",
            "settings-about-update-available.png",
            "settings-about-update-unreachable.png",
            "settings-assistant-tall.png",
            "settings-assistant-dark-tall.png",
            "settings-assistant-no-key-tall.png",
            "settings-assistant-no-key-dark-tall.png",
            "settings-assistant-custom-unfinished-tall.png",
            "settings-assistant-custom-unfinished-dark-tall.png",
            "settings-assistant-checking-tall.png",
            "settings-assistant-checking-dark-tall.png",
            "settings-assistant-connected-tall.png",
            "settings-assistant-connected-dark-tall.png",
            "settings-assistant-unreachable-tall.png",
            "settings-assistant-unreachable-dark-tall.png",
            "settings-assistant-xiaomi-tall.png",
            "settings-assistant-xiaomi-dark-tall.png",
            "settings-assistant-xiaomi-token-plan-tall.png",
            "settings-assistant-xiaomi-token-plan-dark-tall.png",
            "settings-assistant-opencode-go-tall.png",
            "settings-assistant-opencode-go-dark-tall.png",
            "settings-assistant-rewrite-tall.png",
            "settings-assistant-rewrite-dark-tall.png",
            "settings-assistant-off-tall.png",
            "settings-assistant-off-dark-tall.png",
            "settings-assistant-rewrite-concise-tall.png",
            "settings-assistant-rewrite-concise-dark-tall.png",
            "settings-assistant-rewrite-custom-tall.png",
            "settings-assistant-rewrite-custom-dark-tall.png",
            "settings-assistant-rewrite-deleted-tall.png",
            "settings-assistant-rewrite-deleted-dark-tall.png",
            "settings-assistant-rewrite-empty-tall.png",
            "settings-assistant-rewrite-empty-dark-tall.png",
        ]
        // Every engine has a page, and each page is drawn in both appearances.
        for preset in ProviderPreset.all {
            names.append("settings-provider-\(preset.id).png")
            names.append("settings-provider-\(preset.id)-dark.png")
        }
        // Each page again, tall enough to hold every card it has.
        let tall = ["general", "provider", "shortcuts", "appearance", "about"]
        for page in tall {
            names.append("settings-\(page)-tall.png")
            names.append("settings-\(page)-dark-tall.png")
        }
        for name in names {
            let url = directory.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(name) was not written"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try XCTUnwrap(attributes[.size] as? Int)
            XCTAssertGreaterThan(size, 10_240, "\(name) is smaller than 10 KB")

            let data = try Data(contentsOf: url)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "\(name) is not a PNG")
            XCTAssertEqual(bitmap.pixelsWide, 1640, "\(name) width")
            let isTall = name.contains("-tall")
                || name.contains("settings-about-update")
                || name.contains("settings-provider-connected")
            // 1180 points at the render's two-times scale. The styles card is
            // the tallest card on the page, and every assistant render is drawn
            // in a window that holds all of it: a render cut at the fold cannot
            // show the field the card is about.
            let expectedHeight = isTall ? 2360 : 1200
            XCTAssertEqual(bitmap.pixelsHigh, expectedHeight, "\(name) height")
        }

        // A page with nothing set up is one card: the service, its key and the
        // status. Model and Rewrite are settings for a service that cannot be
        // used yet, so nothing may be drawn below the Service card.
        let notSetUp = try lastInkRow(in: directory.appendingPathComponent("settings-assistant-no-key-tall.png"))
        XCTAssertLessThan(
            notSetUp,
            1_000,
            "the not-set-up page drew a card below the Service card, which is where Model and Rewrite would be"
        )
        let sharedKey = try lastInkRow(in: directory.appendingPathComponent("settings-assistant-tall.png"))
        XCTAssertLessThan(sharedKey, 1_000, "a stored speech key is not a set-up assistant")
        // The reported record: a custom endpoint with no address. Its card names
        // the service, so it is one card of setup rows and nothing below it.
        let custom = try lastInkRow(
            in: directory.appendingPathComponent("settings-assistant-custom-unfinished-tall.png")
        )
        XCTAssertLessThan(
            custom,
            1_000,
            "the unfinished custom endpoint drew a ready section below its setup card"
        )
        let connected = try lastInkRow(in: directory.appendingPathComponent("settings-assistant-connected-tall.png"))
        XCTAssertGreaterThan(
            connected,
            1_600,
            "a set-up page draws its Model and Styles sections"
        )

        // The master switch is the only card on a page with rewriting off.
        let off = try lastInkRow(in: directory.appendingPathComponent("settings-assistant-off-tall.png"))
        XCTAssertLessThan(off, 400, "a page with rewriting off drew a card below its switch")

        // Every style draws its own prompt editor under its switch: the agent
        // prompt one with the rules its template asks for, and the others with
        // their own instruction.
        let promptCard = try lastInkRow(
            in: directory.appendingPathComponent("settings-assistant-rewrite-tall.png")
        )
        XCTAssertGreaterThan(
            promptCard,
            1_500,
            "the agent prompt card did not draw its prompt editor"
        )
        let conciseCard = try lastInkRow(
            in: directory.appendingPathComponent("settings-assistant-rewrite-concise-tall.png")
        )
        XCTAssertGreaterThan(
            conciseCard,
            1_400,
            "the concise style drew no prompt editor"
        )
        let customCard = try lastInkRow(
            in: directory.appendingPathComponent("settings-assistant-rewrite-custom-tall.png")
        )
        XCTAssertGreaterThan(
            customCard,
            1_300,
            "the custom style drew neither its name row nor its instruction field"
        )
        // The removed styles are gone from the row, and the card keeps the row
        // that puts them back.
        let deletedCard = try lastInkRow(
            in: directory.appendingPathComponent("settings-assistant-rewrite-deleted-tall.png")
        )
        XCTAssertGreaterThan(
            deletedCard,
            1_100,
            "the card with two styles removed drew neither a style nor the restore row"
        )
        let emptyCard = try lastInkRow(
            in: directory.appendingPathComponent("settings-assistant-rewrite-empty-tall.png")
        )
        XCTAssertGreaterThan(
            emptyCard,
            500,
            "the card with every style removed drew neither its message nor the restore row"
        )
    }

    /// The rewrite card, whose chip row is sized against the face's width.
    ///
    /// The chips are the one part of the interface whose width the typeface
    /// decides: a face a few percent wider pushes the row past the card's edge
    /// and the last style can only be reached by scrolling. The card is drawn
    /// through the same offscreen renderer as the island, in both appearances,
    /// so the row can be looked at rather than inferred from a measurement.
    func testTheRewriteCardRendersItsChipRow() throws {
        guard let value = DotMigration.environment("RENDER_UI_DIR"),
              !value.isEmpty
        else {
            throw XCTSkip("Set DOT_RENDER_UI_DIR to render the rewrite card.")
        }

        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(state: HUDPreview.State, name: String)] = [
            (.rewriteLongLabels, "hud-rewrite-chips"),
            (.rewriteTwoVersions, "hud-rewrite-versions"),
            (.rewriteRunning, "hud-rewrite-running"),
        ]
        for entry in states {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let suffix = scheme == .dark ? "-dark" : ""
                let image = try HUDPreview.render(state: entry.state, scheme: scheme)
                let data = try XCTUnwrap(
                    image.representation(using: .png, properties: [:]),
                    "the rewrite card could not be encoded"
                )
                try data.write(
                    to: directory.appendingPathComponent("\(entry.name)\(suffix).png"),
                    options: .atomic
                )
                XCTAssertGreaterThan(data.count, 10_240, "\(entry.name)\(suffix).png is too small")
            }
        }
    }

    /// The last row of a settings render that carries anything but the page's
    /// own background.
    ///
    /// The background is sampled beside the card on every row, so the page's
    /// gradient never reads as ink. The value is the bottom of the last card:
    /// a page of one card ends under the status row, a configured page ends
    /// under the Rewrite section.
    ///
    /// - Parameter url: the render.
    /// - Returns: the row, in device pixels.
    private func lastInkRow(in url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "\(url.lastPathComponent) is not a PNG")
        // The card's content spans these columns at two times scale, and the
        // page's background is clear beside the card's trailing edge.
        let contentLeft = 486
        let contentRight = 1_551
        let backgroundColumn = 1_600
        func colour(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            else { return (0, 0, 0) }
            return (
                Int(colour.redComponent * 255),
                Int(colour.greenComponent * 255),
                Int(colour.blueComponent * 255)
            )
        }
        func distance(_ first: (Int, Int, Int), _ second: (Int, Int, Int)) -> Int {
            max(abs(first.0 - second.0), max(abs(first.1 - second.1), abs(first.2 - second.2)))
        }
        var last: Int?
        for y in 120 ..< (bitmap.pixelsHigh - 20) {
            let background = colour(backgroundColumn, y)
            let ink = stride(from: contentLeft, through: contentRight, by: 8).contains { x in
                distance(colour(x, y), background) > 10
            }
            if ink { last = y }
        }
        return try XCTUnwrap(last, "\(url.lastPathComponent) is blank")
    }

    /// The island, in the states the transcript change touches.
    ///
    /// The card is dark in both appearances; the scheme is what the system draws
    /// the scroller and the rest of its chrome in, so both are rendered.
    func testIslandRendersToPNGs() throws {
        guard let value = DotMigration.environment("RENDER_UI_DIR"),
              !value.isEmpty
        else {
            throw XCTSkip("Set DOT_RENDER_UI_DIR to render the island.")
        }

        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try UIPreview.renderHUDStates(to: directory)

        let inset = Int(HUD.shadowPadding * 2)
        let long = HUD.transcriptSize(text: HUDPreview.longTranscript)
        let short = HUD.transcriptSize(text: HUDPreview.transcript)
        let transcribing = CGSize(
            width: HUDState.recordingWidth,
            height: HUDState.recordingHeight
        )
        let expected: [(name: String, size: CGSize)] = [
            ("hud-live.png", HUDState.liveCard.size),
            ("hud-live-dark.png", HUDState.liveCard.size),
            ("hud-transcript.png", short),
            ("hud-transcript-dark.png", short),
            ("hud-transcript-long.png", long),
            ("hud-transcript-long-dark.png", long),
            ("hud-transcribing.png", transcribing),
            ("hud-transcribing-dark.png", transcribing),
        ]
        for entry in expected {
            let url = directory.appendingPathComponent(entry.name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(entry.name) was not written"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try XCTUnwrap(attributes[.size] as? Int)
            XCTAssertGreaterThan(size, 10_240, "\(entry.name) is smaller than 10 KB")

            let data = try Data(contentsOf: url)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "\(entry.name) is not a PNG")
            XCTAssertEqual(
                bitmap.pixelsWide,
                Int(entry.size.width) * 2 + inset * 2,
                "\(entry.name) width"
            )
            XCTAssertEqual(
                bitmap.pixelsHigh,
                Int(entry.size.height) * 2 + inset * 2,
                "\(entry.name) height"
            )
        }
    }

    /// The menu bar mark is the plate, and it moves.
    ///
    /// Two things are easy to lose here: the glyph drifting back into a bitmap
    /// of the dot, and the breath becoming a still image. The first is what the
    /// sheet is for; the second is what the two phases prove.
    func testTheMenuGlyphRendersItsPlateAndMoves() throws {
        guard let value = DotMigration.environment("RENDER_UI_DIR"),
              !value.isEmpty
        else {
            throw XCTSkip("Set DOT_RENDER_UI_DIR to render the menu bar mark.")
        }

        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try UIPreview.renderMenuGlyph(to: directory)

        let url = directory.appendingPathComponent("menu-glyph.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "menu-glyph.png")
        let data = try Data(contentsOf: url)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "not a PNG")
        XCTAssertEqual(bitmap.pixelsWide, Int(UIPreview.menuGlyphSize.width) * 2)
        XCTAssertEqual(bitmap.pixelsHigh, Int(UIPreview.menuGlyphSize.height) * 2)

        let still = try XCTUnwrap(MenuGlyph.image(phase: 0).tiffRepresentation)
        let breathed = try XCTUnwrap(MenuGlyph.image(phase: 0.5).tiffRepresentation)
        XCTAssertNotEqual(still, breathed, "the glyph drew the same frame twice")
    }

    /// The palette, in the four states it can be summoned in.
    ///
    /// It had no render at all: the one surface a person opens mid-sentence was
    /// the only window nobody had looked at.
    func testPaletteRendersToPNGs() throws {
        guard let value = DotMigration.environment("RENDER_UI_DIR"),
              !value.isEmpty
        else {
            throw XCTSkip("Set DOT_RENDER_UI_DIR to render the palette.")
        }

        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try UIPreview.renderPalette(to: directory)

        let names = [
            "palette.png",
            "palette-search.png",
            "palette-empty.png",
            "palette-no-matches.png",
            "palette-dark.png",
        ]
        let size = PaletteController.panelSize
        for name in names {
            let url = directory.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(name) was not written"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = try XCTUnwrap(attributes[.size] as? Int)
            XCTAssertGreaterThan(bytes, 10_240, "\(name) is smaller than 10 KB")

            let data = try Data(contentsOf: url)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "\(name) is not a PNG")
            XCTAssertEqual(bitmap.pixelsWide, Int(size.width) * 2, "\(name) width")
            XCTAssertEqual(bitmap.pixelsHigh, Int(size.height) * 2, "\(name) height")
        }
    }

    func testHistoryRenderToPNGs() throws {
        guard let value = DotMigration.environment("RENDER_UI_DIR"),
              !value.isEmpty
        else {
            throw XCTSkip("Set DOT_RENDER_UI_DIR to render the history window.")
        }

        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try UIPreview.renderHistory(to: directory)

        let names = [
            "history.png",
            "history-empty.png",
            "history-search.png",
            "history-no-matches.png",
            "history-dark.png",
        ]
        for name in names {
            let url = directory.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(name) was not written"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try XCTUnwrap(attributes[.size] as? Int)
            XCTAssertGreaterThan(size, 10_240, "\(name) is smaller than 10 KB")

            let data = try Data(contentsOf: url)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "\(name) is not a PNG")
            XCTAssertEqual(bitmap.pixelsWide, 1240, "\(name) width")
            XCTAssertEqual(bitmap.pixelsHigh, 1120, "\(name) height")
        }
    }
}
