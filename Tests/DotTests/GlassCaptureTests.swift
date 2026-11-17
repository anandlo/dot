import AppKit
import DotCore
import SwiftUI
import XCTest
@testable import Dot

/// The recording card's glass, judged on the window server's own picture.
///
/// A material is composited by the window server, not by the app's drawing code,
/// so every test here hosts the real card in a window off every display and
/// reads the pixels the compositor produced. Nothing is ever drawn on the
/// owner's screen: the window is borderless, transparent, at the offscreen
/// origin, and ordered out before the test ends.
@MainActor
final class GlassSurfaceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    // MARK: - The canvas

    /// The card's own size, in points.
    private static let cardSize = CGSize(
        width: HUDState.recordingWidth,
        height: HUDState.recordingHeight
    )
    /// The window the card is hosted in, in points, with room around it.
    private static let cardCanvas = CGSize(width: 400, height: 160)
    /// The window the material tile is hosted in, in points.
    private static let tileCanvas = CGSize(width: 300, height: 100)

    /// The card's rect inside its canvas, in points.
    private static var cardRect: CGRect {
        centred(cardSize, in: cardCanvas)
    }

    /// The tile's rect inside its canvas, in points.
    private static var tileRect: CGRect {
        centred(HUDSwatch.tileSize, in: tileCanvas)
    }

    /// A rect of the given size at the centre of a canvas.
    private static func centred(_ size: CGSize, in canvas: CGSize) -> CGRect {
        CGRect(
            x: (canvas.width - size.width) / 2,
            y: (canvas.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - The material

    /// The Glass card is the system material, and it changes what is behind it.
    ///
    /// On macOS 26 and later the card is Liquid Glass, which the window server
    /// draws: the test proves it is there by comparing the server's picture of
    /// the card with its picture of the same backdrop without one. The material
    /// refracts the backdrop under the card, so those pixels differ; the pixels
    /// outside the card's shape must be untouched, or the fill is drawing a
    /// shadow or a border the shape never asked for.
    func testTheGlassCardIsTheSystemMaterial() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Liquid Glass is not available before macOS 26")
        }
        let bare = try capture(backdrop: .colour, overlay: EmptyView(), requiresContent: false)
        let picture = try capture(backdrop: .colour, overlay: recordingCard(.glass))
        let box = try XCTUnwrap(
            WindowCapture.changedBounds(picture, bare),
            "the card changed no pixel of the backdrop"
        )
        let scaleX = CGFloat(picture.width) / Self.cardCanvas.width
        let scaleY = CGFloat(picture.height) / Self.cardCanvas.height
        print(String(
            format: "GLASS card over a colour backdrop: capture %dx%d at %.3fx%.3f, "
                + "changed box (%d, %d, %d, %d) pt (%.1f, %.1f, %.1f, %.1f), MAD inside %.3f",
            picture.width, picture.height, scaleX, scaleY,
            box.x, box.y, box.width, box.height,
            CGFloat(box.x) / scaleX, CGFloat(box.y) / scaleY,
            CGFloat(box.width) / scaleX, CGFloat(box.height) / scaleY,
            WindowCapture.mad(picture, bare, rect: box)
        ))
        XCTAssertEqual(
            CGFloat(box.width),
            Self.cardSize.width * scaleX,
            accuracy: 8,
            "the glass covers \(box.width) px where the card is \(Self.cardSize.width * scaleX) px wide"
        )
        XCTAssertEqual(
            CGFloat(box.height),
            Self.cardSize.height * scaleY,
            accuracy: 8,
            "the glass covers \(box.height) px where the card is \(Self.cardSize.height * scaleY) px tall"
        )
        XCTAssertEqual(
            box.midX,
            picture.width / 2,
            accuracy: 8,
            "the card is not centred in its canvas"
        )
        XCTAssertGreaterThan(
            WindowCapture.mad(picture, bare, rect: box),
            10,
            "the card's own pixels differ from the backdrop by only "
                + "\(WindowCapture.mad(picture, bare, rect: box)) of 255, so the material is not "
                + "being composited"
        )
        let outside = outsideMAD(picture, bare, box: box)
        XCTAssertLessThan(
            outside,
            0.01,
            "the material changed pixels outside the card's shape by \(outside) of 255"
        )
    }

    /// The path a Mac without Liquid Glass takes still draws the fill it had.
    ///
    /// The flag is the test's own switch: on a system with the material, it
    /// selects the pre-26 fill so the picture that ships to an older Mac is
    /// still drawn by this suite. That fill is the smoky tint and the specular
    /// sheen, without the behind-window sampler, which has no desktop to read in
    /// an offscreen window.
    func testTheFallbackGlassStillDrawsTheTintAndTheSpecular() throws {
        XCTAssertFalse(
            HUDSurface.drawsSystemGlass(.glass, useSystemGlass: false),
            "the flag did not select the fallback fill"
        )
        XCTAssertFalse(HUDSurface.drawsSystemGlass(.black), "the Black material is never system glass")
        if #available(macOS 26.0, *) {
            XCTAssertTrue(
                HUDSurface.drawsSystemGlass(.glass),
                "the Glass material is not the system material on a system that has it"
            )
        }

        let fallback = HUDSurface(
            material: .glass,
            samplesDesktop: false,
            useSystemGlass: false
        )
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)

        let bare = try capture(backdrop: .colour, overlay: EmptyView(), requiresContent: false)
        let picture = try capture(backdrop: .colour, overlay: fallback)
        let box = try XCTUnwrap(
            WindowCapture.changedBounds(picture, bare),
            "the fallback fill changed no pixel of the backdrop"
        )
        let inside = WindowCapture.mad(picture, bare, rect: box)
        print(String(
            format: "GLASS fallback fill over a colour backdrop: MAD inside the pill %.3f, box (%d, %d, %d, %d)",
            inside, box.x, box.y, box.width, box.height
        ))
        XCTAssertGreaterThan(
            inside,
            10,
            "the fallback fill barely changed the backdrop (\(inside) of 255), so the tint and the "
                + "specular are not drawn"
        )
        XCTAssertLessThan(
            outsideMAD(picture, bare, box: box),
            0.01,
            "the fallback fill drew outside the card's shape"
        )

        // The two paths are not the same picture: a flag that changed nothing
        // would leave the fallback indistinguishable from the material.
        if #available(macOS 26.0, *) {
            let material = try capture(backdrop: .colour, overlay: recordingCard(.glass))
            let difference = WindowCapture.mad(material, picture, rect: box)
            print(String(format: "GLASS material against fallback: MAD inside the pill %.3f", difference))
            XCTAssertGreaterThan(
                difference,
                1,
                "the fallback and the system material drew the same pixels, so the flag is inert"
            )
        }
    }

    /// The fallback fill still has its three layers and its own rim.
    ///
    /// A render can prove the tint and the specular, but not the blur: in an
    /// offscreen window a behind-window material has no desktop to sample, so a
    /// picture cannot tell a missing blur from a blur over nothing. The source
    /// is read for the layer instead, which is the only evidence the blur is
    /// still there for the Mac it ships to.
    func testTheFallbackFillKeepsItsLayers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Dot/HUDTheme.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)"),
            "the fallback fill lost its behind-window blur"
        )
        XCTAssertTrue(
            source.contains("Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.32)"),
            "the fallback fill lost its smoky tint"
        )
        XCTAssertTrue(
            source.contains("Color.white.opacity(0.26)"),
            "the fallback fill lost its specular sheen"
        )
        XCTAssertTrue(
            source.contains("0.06, green: 0.07, blue: 0.09).opacity(0.42)"),
            "the fallback fill lost the bottom of its smoky tint"
        )
        XCTAssertTrue(
            source.contains("1.25"),
            "the fallback fill lost the 1.25 point rim it draws"
        )
    }

    /// The Black card is the opaque matte fill it always was.
    ///
    /// The flag is ignored for Black, because an opaque card has nothing to
    /// refract: two renders with the flag at either setting have to be the same
    /// picture, and that picture is the fill's own dark gradient rather than a
    /// grey the material might have produced.
    func testTheBlackCardIsTheOpaqueFillItAlwaysWas() throws {
        let plain = HUDSurface(material: .black)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        let flagged = HUDSurface(material: .black, useSystemGlass: false)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        let first = try capture(backdrop: .colour, overlay: plain)
        let second = try capture(backdrop: .colour, overlay: flagged)
        let bare = try capture(backdrop: .colour, overlay: EmptyView(), requiresContent: false)
        let box = try XCTUnwrap(
            WindowCapture.changedBounds(first, bare),
            "the Black card changed no pixel of the backdrop"
        )
        let difference = WindowCapture.mad(first, second, rect: box)
        let middle = first.pixel(box.midX, box.midY)
        let top = first.pixel(box.midX, box.y + 6)
        let bottom = first.pixel(box.midX, box.y + box.height - 6)
        print(String(
            format: "GLASS black card: flag difference %.4f, middle (%.1f, %.1f, %.1f), "
                + "top (%.1f, %.1f, %.1f), bottom (%.1f, %.1f, %.1f)",
            difference,
            middle.0, middle.1, middle.2,
            top.0, top.1, top.2,
            bottom.0, bottom.1, bottom.2
        ))
        XCTAssertEqual(
            difference,
            0,
            accuracy: 0.001,
            "the system-glass flag changed the Black card by \(difference) of 255"
        )
        // The fill is the gradient from 0.06 to 0.02, so its middle is about ten
        // levels above black and its top is lighter than its bottom.
        XCTAssertEqual(middle.0, 10, accuracy: 5, "the Black fill's red channel is not the gradient's")
        XCTAssertEqual(middle.1, 10, accuracy: 5, "the Black fill's green channel is not the gradient's")
        XCTAssertEqual(middle.2, 12, accuracy: 5, "the Black fill's blue channel is not the gradient's")
        XCTAssertGreaterThan(
            top.0 - bottom.0,
            4,
            "the Black fill is not the top-to-bottom gradient it was: \(top.0) against \(bottom.0)"
        )
        XCTAssertGreaterThan(
            top.2 - bottom.2,
            4,
            "the Black fill's blue is not the top-to-bottom gradient it was: \(top.2) against \(bottom.2)"
        )
    }

    /// The black card's clock is the ink it always was.
    ///
    /// The measured clock ink belongs to the glass material only: on the black
    /// card ``HUDTheme/clockInk(_:)`` has to be ``HUDTheme/ink2`` itself, or a
    /// decision about the glass would change a render the black card already
    /// shipped. The glass card's clock is the same hue at the measured opacity,
    /// not at the secondary ink's.
    func testTheBlackCardsClockInkIsUnchanged() throws {
        let black = components(HUDTheme.clockInk(.black))
        let secondary = components(HUDTheme.ink2)
        let glass = components(HUDTheme.clockInk(.glass))
        print(String(
            format: "GLASS clock ink: black (%.3f, %.3f, %.3f, %.3f), ink2 (%.3f, %.3f, %.3f, %.3f), "
                + "glass (%.3f, %.3f, %.3f, %.3f)",
            black.0, black.1, black.2, black.3,
            secondary.0, secondary.1, secondary.2, secondary.3,
            glass.0, glass.1, glass.2, glass.3
        ))
        XCTAssertEqual(black.0, secondary.0, accuracy: 0.002, "the black clock's red is not ink2's")
        XCTAssertEqual(black.1, secondary.1, accuracy: 0.002, "the black clock's green is not ink2's")
        XCTAssertEqual(black.2, secondary.2, accuracy: 0.002, "the black clock's blue is not ink2's")
        XCTAssertEqual(black.3, secondary.3, accuracy: 0.002, "the black clock's opacity is not ink2's")
        XCTAssertEqual(glass.0, secondary.0, accuracy: 0.002, "the glass clock is a different hue")
        XCTAssertEqual(
            glass.3,
            HUDTheme.clockInkOpacity,
            accuracy: 0.002,
            "the glass clock is not drawn at the measured opacity"
        )
        XCTAssertGreaterThan(
            glass.3,
            secondary.3,
            "the glass clock was not raised above the secondary ink"
        )
    }

    /// One colour as red, green, blue and alpha, in sRGB.
    private func components(_ colour: Color) -> (Double, Double, Double, Double) {
        guard let resolved = NSColor(colour).usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
        return (
            Double(resolved.redComponent),
            Double(resolved.greenComponent),
            Double(resolved.blueComponent),
            Double(resolved.alphaComponent)
        )
    }

    /// The transcript header's status ink reads on the white page.
    ///
    /// The status label and its leading glyph are the card's quietest mark, and
    /// the glass material leaves them on the backdrop: at the delivery's own
    /// silver the label read 1.70 to 1 on the white page, under the 3 to 1 a small
    /// caps label needs. The glass card draws it in the card's own ink at
    /// ``HUDTheme/statusInkOpacity``, which measures 3.06; the floor below sits
    /// 0.2 under that. The black card keeps the delivery's silver. The box is the
    /// ink found in the header's left side, measured rather than assumed, because
    /// the label is a string whose width only the font knows.
    func testTheStatusLabelReadsOnAWhitePage() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Liquid Glass is not available before macOS 26")
        }
        let model = HUDPreview.makeModel(state: .transcript)
        let size = model.cardSize
        let canvas = CGSize(width: size.width + 160, height: size.height + 160)
        let view = HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions
        )
        .frame(width: size.width, height: size.height)
        let picture = try capture(backdrop: .solid(0.92), overlay: view, size: canvas)
        let card = WindowCapture.Rect.points(
            Self.centred(size, in: canvas),
            scaleX: CGFloat(picture.width) / canvas.width,
            scaleY: CGFloat(picture.height) / canvas.height
        )
        let scale = Double(picture.width) / Double(canvas.width)
        let left = card.x + Int((8 * scale).rounded())
        let right = card.x + Int((250 * scale).rounded())
        let top = card.y + Int((4 * scale).rounded())
        let bottom = card.y + Int((40 * scale).rounded())
        var luminances: [Double] = []
        for y in top ..< bottom {
            for x in left ..< right {
                luminances.append(WindowCapture.luminance(picture.pixel(x, y)))
            }
        }
        luminances.sort()
        let surface = luminances[luminances.count / 2]
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min
        for y in top ..< bottom {
            for x in left ..< right where abs(WindowCapture.luminance(picture.pixel(x, y)) - surface) > 0.03 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        XCTAssertLessThanOrEqual(minX, maxX, "the header's status label was not found")
        let pad = Int((4 * scale).rounded())
        let box = WindowCapture.Rect(
            x: minX - pad,
            y: minY - pad,
            width: maxX - minX + 2 * pad,
            height: maxY - minY + 2 * pad
        )
        let status = WindowCapture.glyphContrast(picture, box: box)
        print(String(
            format: "GLASS status label over white: %.3f:1 (background %.4f, ink %.4f), box "
                + "(%d, %d, %d, %d)",
            status.ratio, status.background, status.ink, box.x, box.y, box.width, box.height
        ))
        XCTAssertGreaterThanOrEqual(
            status.ratio,
            2.85,
            "the status label reads at \(status.ratio):1 over a white page, under the 3.06 the "
                + "measured status ink was measured at"
        )
    }

    /// The Settings tile draws its own backdrop and its own glass.
    ///
    /// A Settings page has no desktop behind it, so the Glass tile cannot use a
    /// behind-window material. On macOS 26 it draws a still backdrop of its own
    /// and the system material over it; the tile has to show both, which the
    /// test proves by the spread of its own pixels and by their difference from
    /// the page it sits on.
    func testTheSettingsTileDrawsItsOwnBackdropAndGlass() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Liquid Glass is not available before macOS 26")
        }
        let page = try capture(
            backdrop: .page,
            overlay: EmptyView(),
            size: Self.tileCanvas,
            requiresContent: false
        )
        let picture = try capture(
            backdrop: .page,
            overlay: HUDSwatch(material: .glass),
            size: Self.tileCanvas
        )
        let box = try XCTUnwrap(
            WindowCapture.changedBounds(picture, page),
            "the tile changed no pixel of the page"
        )
        let scaleX = CGFloat(picture.width) / Self.tileCanvas.width
        let scaleY = CGFloat(picture.height) / Self.tileCanvas.height
        let inside = WindowCapture.mad(picture, page, rect: box)

        let inset = 8
        var low = Double.infinity
        var high = -Double.infinity
        for y in (box.y + inset) ..< (box.y + box.height - inset) {
            for x in (box.x + inset) ..< (box.x + box.width - inset) {
                let luma = WindowCapture.luminance(picture.pixel(x, y))
                low = min(low, luma)
                high = max(high, luma)
            }
        }
        print(String(
            format: "GLASS settings tile: box (%d, %d, %d, %d) at %.3fx%.3f, "
                + "MAD against the page %.3f, luma range %.4f to %.4f",
            box.x, box.y, box.width, box.height, scaleX, scaleY, inside, low, high
        ))
        XCTAssertEqual(
            CGFloat(box.width),
            HUDSwatch.tileSize.width * scaleX,
            accuracy: 8,
            "the tile covers \(box.width) px where it is \(HUDSwatch.tileSize.width * scaleX) px wide"
        )
        XCTAssertEqual(
            CGFloat(box.height),
            HUDSwatch.tileSize.height * scaleY,
            accuracy: 8,
            "the tile covers \(box.height) px where it is \(HUDSwatch.tileSize.height * scaleY) px tall"
        )
        XCTAssertGreaterThan(
            inside,
            10,
            "the tile barely differs from the page (\(inside) of 255): the glass is not drawn"
        )
        XCTAssertGreaterThan(
            high - low,
            0.15,
            "the tile's own pixels span only \(high - low) of luma, so the vivid backdrop is not "
                + "under the glass"
        )
    }

    // MARK: - The ink over the material

    /// The card's ink reads over the material on the backdrops that used to beat it.
    ///
    /// The material lifts a bright backdrop toward white, so ink over it loses the
    /// contrast the card needs: the table in ``HUDTheme/glassScrimOpacity`` is the
    /// scan that chose the 0.30 scrim this card draws over the material. With it,
    /// measured through this suite's own captures, the REC label reads 3.20 to 1
    /// over a white page and 3.64 to 1 over the colour bands, and the clock, drawn
    /// at ``HUDTheme/clockInkOpacity``, 3.06 and 3.93. The floors below sit 0.2
    /// under those measurements, and the material still refracts: the card's
    /// interior differs by 50.4 levels of 255 between the two backdrops.
    func testTheInkReadsOverTheMaterialOnABrightPage() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Liquid Glass is not available before macOS 26")
        }
        let white = try capture(backdrop: .solid(0.92), overlay: recordingCard(.glass))
        let colour = try capture(backdrop: .colour, overlay: recordingCard(.glass))
        let box = cardBox(white)
        let whiteContrast = labelContrast(white, box: box).2
        let colourContrast = labelContrast(colour, box: box).2
        let whiteClock = clockContrast(white, box: box).2
        let colourClock = clockContrast(colour, box: box).2
        let interior = WindowCapture.Rect(
            x: box.x + 4,
            y: box.y + 4,
            width: box.width - 8,
            height: box.height - 8
        )
        let refraction = WindowCapture.mad(white, colour, rect: interior)
        print(String(
            format: "GLASS ink over the material: REC %.3f:1 over white, %.3f:1 over colour bands, "
                + "clock %.3f:1 and %.3f:1, interior MAD white against colour %.3f",
            whiteContrast, colourContrast, whiteClock, colourClock, refraction
        ))
        XCTAssertGreaterThanOrEqual(
            whiteContrast,
            3.0,
            "the REC label reads at \(whiteContrast):1 over a white page, under the 3.20 the "
                + "0.30 scrim was measured at"
        )
        XCTAssertGreaterThanOrEqual(
            colourContrast,
            3.4,
            "the REC label reads at \(colourContrast):1 over the colour bands, under the 3.64 "
                + "the 0.30 scrim was measured at"
        )
        XCTAssertGreaterThanOrEqual(
            whiteClock,
            2.85,
            "the clock reads at \(whiteClock):1 over a white page, under the 3.06 the measured "
                + "clock ink was measured at"
        )
        XCTAssertGreaterThanOrEqual(
            colourClock,
            3.7,
            "the clock reads at \(colourClock):1 over the colour bands, under the 3.93 the "
                + "measured clock ink was measured at"
        )
        XCTAssertGreaterThan(
            refraction,
            10,
            "the card's interior differs by only \(refraction) of 255 between a white page and "
                + "the colour bands, so the material is not refracting"
        )
    }

    /// The contrast the clock's figures read at.
    ///
    /// The box is the one the glass sweep measured the clock in: it starts after
    /// the label's box and the gap that follows it, 0.206 to 0.291 of the card's
    /// width, in the same vertical band as the label's box. The figures and the
    /// glass between them are the box's own population, so the median is the
    /// surface behind them and the brightest pixels are their strokes.
    ///
    /// - Parameters:
    ///   - picture: the capture of the card.
    ///   - box: the card's own rect in the picture.
    /// - Returns: the glass's luminance, the ink's, and their contrast ratio.
    private func clockContrast(
        _ picture: WindowCapture.Pixels,
        box: WindowCapture.Rect
    ) -> (Double, Double, Double) {
        let x0 = box.x + Int(Double(box.width) * 0.206)
        let x1 = box.x + Int(Double(box.width) * 0.291)
        let y0 = box.y + Int(Double(box.height) * 0.32)
        let y1 = box.y + Int(Double(box.height) * 0.68)
        let measured = WindowCapture.glyphContrast(
            picture,
            box: WindowCapture.Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        )
        return (measured.background, measured.ink, measured.ratio)
    }

    /// The card's rect in a capture, at the capture's own scale.
    private func cardBox(_ picture: WindowCapture.Pixels) -> WindowCapture.Rect {
        WindowCapture.Rect.points(
            Self.cardRect,
            scaleX: CGFloat(picture.width) / Self.cardCanvas.width,
            scaleY: CGFloat(picture.height) / Self.cardCanvas.height
        )
    }

    // MARK: - Evidence

    /// Writes the pictures a reviewer reads the material from.
    ///
    /// The captures are the window server's, at the display's own scale, so they
    /// show the refraction a `cacheDisplay` render cannot. The test is skipped
    /// unless `DOT_GLASS_CAPTURE_DIR` names a directory, because it is evidence
    /// rather than an assertion.
    func testTheGlassIsCapturedWhenAsked() throws {
        guard let value = DotMigration.environment("GLASS_CAPTURE_DIR"), !value.isEmpty else {
            throw XCTSkip("Set DOT_GLASS_CAPTURE_DIR to capture the glass.")
        }
        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [
            (name: String, width: Int, height: Int, bytes: Int, mad: Double, label: (Double, Double, Double))
        ] = []
        let backdrops: [(name: String, backdrop: GlassBackdrop)] = [
            ("card-over-white", .solid(0.92)),
            ("card-over-mid", .solid(0.5)),
            ("card-over-dark", .solid(0.12)),
            ("card-over-colour", .colour),
        ]
        for entry in backdrops {
            let bare = try capture(
                backdrop: entry.backdrop,
                overlay: EmptyView(),
                requiresContent: false
            )
            let picture = try capture(backdrop: entry.backdrop, overlay: recordingCard(.glass))
            let url = directory.appendingPathComponent("\(entry.name).png")
            XCTAssertTrue(WindowCapture.write(picture, to: url), "\(entry.name).png was not written")
            let bytes = fileSize(of: url)
            let box = WindowCapture.Rect.points(
                Self.cardRect,
                scaleX: CGFloat(picture.width) / Self.cardCanvas.width,
                scaleY: CGFloat(picture.height) / Self.cardCanvas.height
            )
            written.append((
                entry.name,
                picture.width,
                picture.height,
                bytes,
                WindowCapture.mad(picture, bare, rect: box),
                labelContrast(picture, box: box)
            ))
        }

        for material in [HUDMaterial.glass, .black] {
            let name = material == .glass ? "tile-glass" : "tile-black"
            let picture = try capture(
                backdrop: .page,
                overlay: HUDSwatch(material: material),
                size: Self.tileCanvas
            )
            let url = directory.appendingPathComponent("\(name).png")
            XCTAssertTrue(WindowCapture.write(picture, to: url), "\(name).png was not written")
            written.append((name, picture.width, picture.height, fileSize(of: url), 0, (0, 0, 0)))
        }

        print("GLASS evidence in \(directory.path)")
        for entry in written where entry.label.1 > 0 {
            print(String(
                format: "  %@ %dx%d %d bytes, MAD inside the pill %.3f, "
                    + "REC contrast %.2f:1 (glass luma %.4f, ink luma %.4f)",
                entry.name, entry.width, entry.height, entry.bytes, entry.mad,
                entry.label.2, entry.label.0, entry.label.1
            ))
            XCTAssertGreaterThan(
                entry.label.1,
                entry.label.0,
                "\(entry.name): the REC label is not lighter than the glass behind it"
            )
        }
        for entry in written where entry.label.1 == 0 {
            print(String(
                format: "  %@ %dx%d %d bytes", entry.name, entry.width, entry.height, entry.bytes
            ))
        }
    }

    /// The contrast the card's label has against the glass behind it.
    ///
    /// The region is the middle of the card's left third, which holds the three
    /// letters of the label and the glass between and around them: the median
    /// luminance there is the glass the label sits on and the brightest pixels
    /// are its strokes. WCAG takes those two, and the ratio is what the label
    /// reads at rather than what the ink's own colour would read at on a
    /// backdrop it is not drawn on.
    ///
    /// - Parameters:
    ///   - picture: the capture of the card.
    ///   - box: the card's own rect in the picture.
    /// - Returns: the glass's luminance, the ink's, and their contrast ratio.
    private func labelContrast(
        _ picture: WindowCapture.Pixels,
        box: WindowCapture.Rect
    ) -> (Double, Double, Double) {
        let x0 = box.x + Int(Double(box.width) * 0.12)
        let x1 = box.x + Int(Double(box.width) * 0.23)
        let y0 = box.y + Int(Double(box.height) * 0.32)
        let y1 = box.y + Int(Double(box.height) * 0.68)
        let glyphBox = WindowCapture.Rect(
            x: x0,
            y: y0,
            width: x1 - x0,
            height: y1 - y0
        )
        let measured = WindowCapture.glyphContrast(picture, box: glyphBox)
        return (measured.background, measured.ink, measured.ratio)
    }

    // MARK: - Measuring

    /// The largest mean difference outside the card, over four bands around it.
    ///
    /// Four bands rather than one: a fill that drew a glow, a border or a shadow
    /// would change pixels on one side of the card, and a test that looked at
    /// the top band alone would not see it.
    private func outsideMAD(
        _ first: WindowCapture.Pixels,
        _ second: WindowCapture.Pixels,
        box: WindowCapture.Rect
    ) -> Double {
        let margin = 2
        let bands = [
            WindowCapture.Rect(x: 0, y: 0, width: first.width, height: max(1, box.y - margin)),
            WindowCapture.Rect(
                x: 0,
                y: box.y + box.height + margin,
                width: first.width,
                height: max(1, first.height - box.y - box.height - margin)
            ),
            WindowCapture.Rect(x: 0, y: box.y, width: max(1, box.x - margin), height: box.height),
            WindowCapture.Rect(
                x: box.x + box.width + margin,
                y: box.y,
                width: max(1, first.width - box.x - box.width - margin),
                height: box.height
            ),
        ]
        return bands.map { WindowCapture.mad(first, second, rect: $0) }.max() ?? 0
    }

    /// A file's size in bytes, or zero when it cannot be read.
    private func fileSize(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    // MARK: - Building the card

    /// The recording card, exactly as the island draws it.
    ///
    /// The model comes from the renderer's own recording state, so the clock,
    /// the label, the waveform and the two buttons are the ones the app draws
    /// rather than a stand-in for them.
    private func recordingCard(_ material: HUDMaterial) -> some View {
        let model = HUDPreview.makeModel(state: .recording)
        model.material = material
        return HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions
        )
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
    }

    /// A picture of a canvas with an overlay drawn over a backdrop.
    ///
    /// - Parameters:
    ///   - backdrop: what fills the canvas.
    ///   - overlay: what is drawn over it, at the canvas's centre.
    ///   - size: the canvas, in points; the card canvas when nil.
    ///   - requiresContent: whether a picture of one colour is a failed capture.
    ///     A bare flat backdrop is one colour on purpose, so the baseline
    ///     pictures pass false and only the pictures that must show something do.
    /// - Returns: the window server's picture.
    private func capture<Overlay: View>(
        backdrop: GlassBackdrop,
        overlay: Overlay,
        size: CGSize? = nil,
        requiresContent: Bool = true
    ) throws -> WindowCapture.Pixels {
        let size = size ?? Self.cardCanvas
        let view = ZStack {
            backdrop
            overlay
        }
        .frame(width: size.width, height: size.height)

        let window = WindowCapture.show(view, size: size)
        defer { WindowCapture.hide(window) }
        let picture = try XCTUnwrap(
            WindowCapture.capture(window),
            "the window server returned no picture of the window"
        )
        try WindowCapture.requireUsableCapture(picture, requiresContent: requiresContent)
        return picture
    }
}

/// The backdrops the glass is measured over.
///
/// The colour one is twelve saturated bands rather than a photograph: a material
/// that refracts or blurs has to have something under it that changes from pixel
/// to pixel, and a band is a change the test can rely on.
enum GlassBackdrop: View {
    case solid(Double)
    case colour
    case page

    var body: some View {
        switch self {
        case .solid(let luma):
            Color(red: luma, green: luma, blue: luma)
        case .colour:
            colour
        case .page:
            Color(nsColor: .windowBackgroundColor)
        }
    }

    /// Twelve saturated bands across the canvas.
    ///
    /// Internal so the glass sweep measures the same bands this suite does.
    var colour: some View {
        HStack(spacing: 0) {
            ForEach(Self.bands.indices, id: \.self) { index in
                Self.bands[index]
            }
        }
    }

    private static let bands: [Color] = [
        Color(red: 0.95, green: 0.20, blue: 0.15),
        Color(red: 0.98, green: 0.55, blue: 0.10),
        Color(red: 0.98, green: 0.90, blue: 0.15),
        Color(red: 0.25, green: 0.85, blue: 0.30),
        Color(red: 0.10, green: 0.70, blue: 0.85),
        Color(red: 0.15, green: 0.25, blue: 0.95),
        Color(red: 0.70, green: 0.20, blue: 0.95),
        Color(red: 0.95, green: 0.95, blue: 0.98),
        Color(red: 0.10, green: 0.12, blue: 0.15),
        Color(red: 0.85, green: 0.15, blue: 0.55),
        Color(red: 0.20, green: 0.95, blue: 0.75),
        Color(red: 0.55, green: 0.45, blue: 0.25),
    ]
}
