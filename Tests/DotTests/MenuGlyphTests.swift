import AppKit
@testable import Dot
import XCTest

/// The menu bar mark, measured in pixels.
///
/// Every number the status bar reports can be correct while the drawing is
/// half size: the image can say twenty two points and hold a plate that fills
/// ten. That is exactly what happened, and no assertion about `image.size` or
/// `button.frame` could see it. These tests rasterise the glyph and look at the
/// ink, because ink is the only honest measure of a mark's size.
@MainActor
final class MenuGlyphTests: XCTestCase {
    /// The plate's side in device pixels: fifteen points at two.
    private static let platePixels = Int(15 * 2)

    func testThePlateIsTheSizeTheMenuBarExpects() throws {
        let ink = try inkBounds(of: MenuGlyph.image(phase: 0.2, amplitude: 0))

        // The system's own items ink twelve to sixteen points of the bar. The
        // glyph that shipped at twenty two filled the box and was reported as
        // the largest thing up there; the one before that drew at ten and was
        // reported as tiny. Both are the same measurement away from this.
        XCTAssertEqual(
            Double(ink.height),
            Double(Self.platePixels),
            accuracy: 1,
            "the plate is \(ink.height) pixels tall, expected \(Self.platePixels)"
        )
        XCTAssertEqual(
            Double(ink.width),
            Double(Self.platePixels),
            accuracy: 1,
            "the plate is \(ink.width) pixels wide, expected \(Self.platePixels)"
        )
    }

    func testThePlateIsSolid() throws {
        let bitmap = try rasterise(MenuGlyph.image(phase: 0.2, amplitude: 0))
        let point = platePoint(x: 0.22, y: 0.78)
        XCTAssertGreaterThan(
            bitmap.colorAt(x: point.x, y: point.y)?.alphaComponent ?? 0,
            0.9,
            "the plate has a hole in it"
        )
    }

    /// The mark is two tones, which is the whole reason it is not a template:
    /// one ink made the dot a hole, and a hole is what was reported.
    func testTheDotIsTheOtherTone() throws {
        let lightBar = try rasterise(MenuGlyph.image(phase: 0.2, amplitude: 0, dark: false))
        let darkBar = try rasterise(MenuGlyph.image(phase: 0.2, amplitude: 0, dark: true))
        let disc = platePoint(x: 0.745, y: 0.255)
        let plate = platePoint(x: 0.22, y: 0.78)

        let lightDisc = try luminance(lightBar, at: disc)
        let lightPlate = try luminance(lightBar, at: plate)
        XCTAssertGreaterThan(lightDisc, 0.85, "the dot is not porcelain: \(lightDisc)")
        XCTAssertLessThan(lightPlate, 0.15, "the plate is not graphite: \(lightPlate)")

        let darkDisc = try luminance(darkBar, at: disc)
        let darkPlate = try luminance(darkBar, at: plate)
        XCTAssertLessThan(darkDisc, 0.15, "the dot does not invert: \(darkDisc)")
        XCTAssertGreaterThan(darkPlate, 0.85, "the plate does not invert: \(darkPlate)")
    }

    private func luminance(_ bitmap: NSBitmapImageRep, at point: (x: Int, y: Int)) throws -> Double {
        let colour = try XCTUnwrap(bitmap.colorAt(x: point.x, y: point.y))
        XCTAssertGreaterThan(colour.alphaComponent, 0.9, "nothing is drawn there")
        let rgb = try XCTUnwrap(colour.usingColorSpace(.deviceRGB))
        return 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
    }

    func testTheCornersAreRounded() throws {
        let bitmap = try rasterise(MenuGlyph.image(phase: 0.2, amplitude: 0))
        let corner = platePoint(x: 0.02, y: 0.02)
        let edge = platePoint(x: 0.5, y: 0.02)
        XCTAssertLessThan(
            bitmap.colorAt(x: corner.x, y: corner.y)?.alphaComponent ?? 1,
            0.2,
            "the plate is a filled square, not a rounded one"
        )
        XCTAssertGreaterThan(
            bitmap.colorAt(x: edge.x, y: edge.y)?.alphaComponent ?? 0,
            0.9,
            "the plate has no ink along its top edge"
        )
    }

    // MARK: - Measuring

    /// A point inside the plate, as a fraction of the plate measured from its
    /// top left corner - the icon's own coordinates - converted to the glyph's
    /// pixel grid. `colorAt` reads rows from the top, which matches.
    private func platePoint(x: Double, y: Double) -> (x: Int, y: Int) {
        let side = Double(MenuGlyph.side) * 2
        let inset = (side - Double(Self.platePixels)) / 2
        return (
            Int(inset + Double(Self.platePixels) * x),
            Int(inset + Double(Self.platePixels) * y)
        )
    }

    private func rasterise(_ image: NSImage) throws -> NSBitmapImageRep {
        let side = Double(MenuGlyph.side) * 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(side),
            pixelsHigh: Int(side),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: MenuGlyph.side, height: MenuGlyph.side)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: MenuGlyph.side, height: MenuGlyph.side))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func inkBounds(of image: NSImage) throws -> (width: Int, height: Int) {
        let bitmap = try rasterise(image)
        var minX = bitmap.pixelsWide
        var maxX = -1
        var minY = bitmap.pixelsHigh
        var maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return (0, 0) }
        return (maxX - minX + 1, maxY - minY + 1)
    }
}
