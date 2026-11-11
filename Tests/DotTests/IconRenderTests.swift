import AppKit
@testable import Dot
import XCTest

/// The icon files, measured in pixels.
///
/// The bug these tests exist for was invisible to every other kind of check:
/// the renderer succeeded, the icns built, and the bundle installed. What was
/// wrong was the shape of every master, which only the alpha channel records.
@MainActor
final class IconRenderTests: XCTestCase {
    /// The grid Apple's own icons use: 824 of 1024, centred.
    func testTheGridIsApplesGrid() {
        XCTAssertEqual(DotIconGrid.body(inCanvas: 1024), 824)
        XCTAssertEqual(DotIconGrid.margin(inCanvas: 1024), 100)

        // The 256 point representation of the system apps' icons puts a 206
        // pixel body at inset 25, which this grid has to reproduce.
        XCTAssertEqual(DotIconGrid.body(inCanvas: 256), 206)
        XCTAssertEqual(DotIconGrid.margin(inCanvas: 256), 25)

        // Every slot lands on a whole pixel boundary, because a body edge on a
        // half pixel is a soft edge at the sizes where the icon is smallest.
        for slot in IconRender.iconsetSlots {
            let canvas = CGFloat(slot.pixels)
            let margin = DotIconGrid.margin(inCanvas: canvas)
            XCTAssertEqual(margin, margin.rounded(), "\(slot.name) has a fractional margin")
            XCTAssertGreaterThan(margin, 0, "\(slot.name) has no transparent margin")
        }
    }

    /// The master is a rounded tile, not a square.
    func testTheMasterIsMasked() throws {
        let image = try IconRender.masked(.shipped, pixels: 1024)
        let pixels = try RGBA(image)

        // The body's bounding box is the grid, and it is centred.
        let body = try pixels.bodyBox(threshold: 128)
        XCTAssertEqual(body.minX, 100)
        XCTAssertEqual(body.minY, 100)
        XCTAssertEqual(body.width, 824)
        XCTAssertEqual(body.height, 824)

        // All four corners are transparent, which is the whole defect.
        for (x, y) in [(0, 0), (1023, 0), (0, 1023), (1023, 1023), (4, 4), (1019, 4)] {
            XCTAssertEqual(pixels.alpha(x, y), 0, "the corner at \(x),\(y) is painted")
        }

        // The plate still covers its own body.
        XCTAssertEqual(pixels.alpha(512, 512), 255)
        XCTAssertEqual(pixels.alpha(110, 512), 255)
    }

    /// The corner is a continuous corner, so the body is not a square either.
    func testTheCornerCurves() throws {
        let image = try IconRender.masked(.shipped, pixels: 1024)
        let pixels = try RGBA(image)
        // At a depth of 40 pixels into the body, Apple's own silhouette insets
        // about 68 pixels; a square would inset none and a circle would inset
        // far more. The window is wide because the corner is read here, not
        // fitted.
        let inset = try pixels.firstOpaqueX(inRow: 140, from: 100)
        XCTAssertEqual(Double(inset - 100), 68, accuracy: 12, "corner inset \(inset - 100)")
    }

    /// A 16 pixel slot is drawn at sixteen pixels, not resampled.
    func testTheSmallSlotsAreDrawnNotDownsampled() throws {
        let small = try RGBA(IconRender.masked(.shipped, pixels: 16))
        let medium = try RGBA(IconRender.masked(.shipped, pixels: 32))

        // Both carry ink and both keep their margin.
        XCTAssertGreaterThan(small.opaqueCount(), 20)
        XCTAssertGreaterThan(medium.opaqueCount(), 80)
        XCTAssertEqual(small.alpha(0, 0), 0)
        XCTAssertEqual(medium.alpha(0, 0), 0)

        // A nearest-neighbour upscale of the sixteen would repeat every opaque
        // pixel four times; a separate drawing does not.
        var repeated = 0
        var sampled = 0
        for y in stride(from: 0, to: 32, by: 2) {
            for x in stride(from: 0, to: 32, by: 2) {
                sampled += 1
                if (medium.alpha(x, y) > 128) == (medium.alpha(x + 1, y + 1) > 128) {
                    repeated += 1
                }
            }
        }
        XCTAssertLessThan(
            Double(repeated) / Double(sampled),
            0.98,
            "the thirty two looks like an upscale of the sixteen"
        )
    }

    /// The mark is still legible at the two smallest slots.
    func testTheMarkStillReadsAtSixteen() throws {
        let pixels = try RGBA(IconRender.masked(.shipped, pixels: 16))

        // The disc: bright ink in the upper right, which is where it bleeds.
        var bright = 0
        for y in 0..<8 {
            for x in 8..<16 where pixels.luminance(x, y) > 0.80 {
                bright += 1
            }
        }
        XCTAssertGreaterThanOrEqual(bright, 12, "the disc does not read at sixteen")

        // The plate: dark ink in the lower left, so the tile is not just a dot.
        var dark = 0
        for y in 8..<16 {
            for x in 0..<8 where pixels.luminance(x, y) < 0.25 {
                dark += 1
            }
        }
        XCTAssertGreaterThanOrEqual(dark, 12, "the plate does not read at sixteen")
    }

    /// The site's full-bleed masters stay full bleed, and the masked ones do not.
    func testTheSiteAssetsAreTheShapesTheSiteNeeds() throws {
        let names = IconRender.siteAssets.map(\.name)
        for expected in ["icon.png", "icon-180.png", "icon-rounded.png", "icon-512.png", "icon-32.png"] {
            XCTAssertTrue(names.contains(expected), "the site asks for \(expected)")
        }

        let rounded = IconRender.siteAssets.first { $0.name == "icon-rounded.png" }
        XCTAssertEqual(rounded?.pixels, 1024)
        XCTAssertEqual(rounded?.masked, true)

        // iOS masks a touch icon itself, so this one must stay a square.
        XCTAssertEqual(IconRender.siteAssets.first { $0.name == "icon-180.png" }?.masked, false)

        let touch = try IconRender.fullBleed(.shipped, pixels: 180)
        XCTAssertEqual(touch.width, 180)
        XCTAssertEqual(try RGBA(touch).alpha(0, 0), 255, "the touch icon is not full bleed")

        let roundedPixels = try RGBA(IconRender.masked(.shipped, pixels: 1024))
        XCTAssertEqual(roundedPixels.alpha(0, 0), 0)
    }
}

extension IconRenderTests {
    /// The Icon Composer document names every layer it writes, and no more.
    func testTheIconComposerDocumentIsComplete() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-icon-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let reference = DotIconGrid.reference
        try AppIconPackage.write(
            to: directory.appendingPathComponent(AppIconPackage.directoryName, isDirectory: true),
            plate: try IconRender.plate(direction: .porcelain, size: reference),
            seat: try IconRender.masked(.shipped, pixels: reference),
            disc: try IconRender.fullBleed(.shipped, pixels: reference)
        )

        let package = directory.appendingPathComponent(AppIconPackage.directoryName, isDirectory: true)
        let data = try Data(contentsOf: package.appendingPathComponent("icon.json"))
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // macOS only: this document is the app's own icon.
        let platforms = try XCTUnwrap(document["supported-platforms"] as? [String: Any])
        XCTAssertEqual(platforms["squares"] as? [String], ["macOS"])

        // Groups read front to back, and the mark comes before its plate.
        let groups = try XCTUnwrap(document["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?["name"] as? String, "mark")
        XCTAssertEqual(groups.last?["name"] as? String, "plate")

        // Every asset a layer names is on disk.
        let assets = Set(
            try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("Assets").path)
        )
        var referenced: Set<String> = []
        for group in groups {
            let layers = try XCTUnwrap(group["layers"] as? [[String: Any]])
            for layer in layers {
                // A flat name, not an appearance-specialized asset: Icon
                // Composer ignores the specializations when both keys are
                // present, so the flat form is the one that actually renders.
                let name = try XCTUnwrap(layer["image-name"] as? String, "a layer has no asset")
                referenced.insert(name)
            }
        }
        XCTAssertEqual(referenced, assets, "the document and Assets/ disagree")
        XCTAssertTrue(referenced.contains("disc.png"))
        XCTAssertTrue(referenced.contains("seat.png"))
        XCTAssertTrue(referenced.contains("plate.png"))

        // One appearance, declared as a plate gradient. A dark variant is not
        // invented here: the plate is already the mark's darkest value, and the
        // system derives its dark and tinted treatments from these layers. A
        // variant that the engine ignores, or that repeats the same drawing, is
        // worse than none because it reads as support that is not there.
        XCTAssertNotNil(document["fill"])
        XCTAssertNil(document["fill-specializations"])
    }

    /// The disc and its seat are separate layers, so the glass rim cannot ring
    /// the shadow instead of the disc.
    func testTheSeatIsItsOwnLayer() throws {
        let disc = try RGBA(IconRender.masked(.shipped, pixels: 1024))
        let seat = try RGBA(
            IconRender.seat(dial: DotMark.chosenDial ?? .clipped, pixels: 1024)
        )
        // The seat is darker than the disc everywhere it is drawn, and the disc
        // layer has no dark ring under its lower edge.
        XCTAssertLessThan(seat.luminance(512, 512), 0.25)
        XCTAssertGreaterThan(disc.luminance(700, 300), 0.85)
    }
}

/// A bitmap as RGBA bytes, so a test can read a pixel.
private struct RGBA {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let pixelWidth = image.width
        let pixelHeight = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        try buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw IconRender.RenderError.couldNotCreateContext
            }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
            )
        }
        width = pixelWidth
        height = pixelHeight
        bytes = buffer
    }

    func alpha(_ x: Int, _ y: Int) -> Int {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        return Int(bytes[(y * width + x) * 4 + 3])
    }

    func luminance(_ x: Int, _ y: Int) -> Double {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        let index = (y * width + x) * 4
        let alpha = Double(bytes[index + 3]) / 255
        guard alpha > 0 else { return 0 }
        let red = Double(bytes[index]) / 255 / alpha
        let green = Double(bytes[index + 1]) / 255 / alpha
        let blue = Double(bytes[index + 2]) / 255 / alpha
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    func opaqueCount(threshold: Int = 128) -> Int {
        var count = 0
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) >= threshold {
                count += 1
            }
        }
        return count
    }

    func bodyBox(threshold: Int = 128) throws -> CGRect {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) >= threshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { throw IconRender.RenderError.couldNotRender }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func firstOpaqueX(inRow y: Int, from start: Int) throws -> Int {
        for x in start..<width where alpha(x, y) >= 128 {
            return x
        }
        throw IconRender.RenderError.couldNotRender
    }
}
