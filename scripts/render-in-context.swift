// Composite the chosen mark against the real icons on this Mac, at real size.
//
//     swiftc -O -parse-as-library \
//         scripts/render-in-context.swift Sources/Dot/DotMark.swift \
//         -o /tmp/render-in-context
//     /tmp/render-in-context --out /tmp/composite --direction porcelain
//
// `scripts/render-mark-in-context.sh` does both steps and also renders the icon
// set to a scratch directory first.
//
// Why this exists: a study sheet shows four directions beside each other, which
// answers "which argument is best". It does not answer "does the winner sit well
// next to real icons", and that is a different question with a different answer,
// because the neighbours are not neutral. So this draws the mark in the Dock it
// would actually live in, using the icons IconServices resolves for this machine
// rather than anything redrawn here, at the sizes the Dock uses, at 2x so a
// retina display shows it 1:1.
//
// Three things are compared, and each answers a question a sheet cannot:
//
//   - the Dock strips: the mark flanked at 128 and 64 points, dark and light.
//   - the master row: how much of the 1024 canvas the art occupies, against
//     Apple's own 824/1024 body grid, with the grid drawn on every tile.
//   - the 16 px row: whether the material survives the size where it is only a
//     dot against a plate.
//
// The mark itself is drawn by `DotPlate` from `Sources/Dot/DotMark.swift`. There
// is no second drawing of it here, so the composite cannot drift from the icon.
//
// Nothing in this file writes to `Resources/`.

import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Appearance

/// The two Dock appearances, which are the two things the mark has to survive.
enum DockAppearance: String {
    case dark
    case light

    var name: String { rawValue }

    /// The desktop behind the Dock, as a vertical gradient.
    var backdrop: [NSColor] {
        switch self {
        case .dark: [Sheet.color(0x2E2E36), Sheet.color(0x14141A)]
        case .light: [Sheet.color(0xEAE7E3), Sheet.color(0xC8C3BC)]
        }
    }

    /// The Dock's own translucent fill.
    var dockFill: NSColor {
        switch self {
        case .dark: NSColor(white: 0.36, alpha: 0.52)
        case .light: NSColor(white: 0.90, alpha: 0.72)
        }
    }

    /// The sheen that reads as the glass face of the Dock.
    var dockSheen: NSColor {
        switch self {
        case .dark: NSColor(white: 1, alpha: 0.085)
        case .light: NSColor(white: 1, alpha: 0.42)
        }
    }

    /// The hairline that separates the Dock from the desktop.
    var dockStroke: NSColor {
        switch self {
        case .dark: NSColor(white: 1, alpha: 0.13)
        case .light: NSColor(white: 0, alpha: 0.10)
        }
    }
}

// MARK: - The neighbours

/// One real application on this machine, used as a neighbour in the strip.
struct Neighbour {
    let name: String
    let path: String

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// The apps left and right of the mark.
///
/// Ordered the way a Dock usually is: the system apps first, then the
/// third-party ones. They are listed explicitly rather than discovered so the
/// strip is the same on every machine that has these apps; anything missing is
/// dropped and the two sides are rebalanced, which keeps the mark in the middle.
enum Neighbours {
    static let left: [Neighbour] = [
        Neighbour(name: "Finder", path: "/System/Library/CoreServices/Finder.app"),
        Neighbour(name: "Safari", path: "/Applications/Safari.app"),
        Neighbour(name: "Mail", path: "/System/Applications/Mail.app"),
        Neighbour(name: "Messages", path: "/System/Applications/Messages.app"),
        Neighbour(name: "Photos", path: "/System/Applications/Photos.app"),
        Neighbour(name: "Music", path: "/System/Applications/Music.app"),
    ]

    static let right: [Neighbour] = [
        Neighbour(name: "Notes", path: "/System/Applications/Notes.app"),
        Neighbour(name: "Calendar", path: "/System/Applications/Calendar.app"),
        Neighbour(name: "Preview", path: "/System/Applications/Preview.app"),
        Neighbour(name: "System Settings", path: "/System/Applications/System Settings.app"),
        Neighbour(name: "Spotify", path: "/Applications/Spotify.app"),
        Neighbour(name: "Google Chrome", path: "/Applications/Google Chrome.app"),
    ]

    /// The two sides, truncated to the shorter one so the mark is centred.
    static func balanced() -> (left: [Neighbour], right: [Neighbour]) {
        let leftPresent = left.filter(\.exists)
        let rightPresent = right.filter(\.exists)
        let count = min(leftPresent.count, rightPresent.count)
        return (Array(leftPresent.prefix(count)), Array(rightPresent.prefix(count)))
    }
}

// MARK: - Rasterising

/// Rasterises the icons the system resolves for this machine.
///
/// `NSWorkspace.icon(forFile:)` goes through IconServices, which is what fills a
/// Dock: the result carries every representation the app actually ships — 16
/// through 2048 on this OS — plus the baked corner, the baked margin and the
/// baked shadow. That is the point: nothing here is a drawing of Safari.
///
/// On macOS 26 and later a system app's `.icns` carries only 16 and 128 point
/// slots; the large art lives behind IconServices. `iconutil -c iconset` on
/// `/System/Applications/Music.app/Contents/Resources/AppIcon.icns` therefore
/// yields four files, not ten, and no 1024 master. Asking IconServices for the
/// same app at 1024 returns art that matches the extractable 256 slot to within
/// antialiasing, so the master used below is the app's own master.
@MainActor
enum Raster {
    /// An app's icon at exactly `pixels` square, through IconServices.
    static func appIcon(_ path: String, pixels: Int) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = transparentContext(pixels)
        else { return nil }
        context.interpolationQuality = .high
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.current = previous
        _ = space
        return context.makeImage()
    }

    /// One plate at one pixel size, masked to the system corner, with alpha.
    static func plate(direction: DotMarkDirection, pixels: Int) -> CGImage? {
        let edge = CGFloat(pixels)
        let renderer = ImageRenderer(
            content: DotPlate(direction: direction, size: edge)
                .clipShape(DotSquircle())
                .frame(width: edge, height: edge)
        )
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// The margin the system puts around an app icon before it draws it.
    ///
    /// Measured, not assumed: a throwaway bundle in `/tmp` was given this mark's
    /// own `.icns` and then asked for its icon through `NSWorkspace`, which goes
    /// through the same IconServices that fills the Dock. Every size comes back
    /// inset by `floor(slot * 100 / 1024)` pixels a side — 1 px at 16, 6 at 64,
    /// 12 at 128, 25 at 256 and 100 at 1024. That is the same 824/1024 body
    /// Apple's own icons sit on, and it is applied to a full-bleed master and to
    /// an already-inset one alike, so an icon is never drawn at the size of its
    /// canvas.
    static func systemMargin(_ slot: Int) -> Int { slot * 100 / 1024 }

    /// The body the system draws for a slot.
    static func systemBody(_ slot: Int) -> Int { slot - systemMargin(slot) * 2 }

    /// The mark in a slot, with its shadow.
    ///
    /// `inset` draws the plate at the body the system will use, inside a canvas
    /// of the full slot, which is what the Dock ends up showing. Without it the
    /// plate fills the slot, which is what the master file contains before
    /// macOS touches it.
    ///
    /// `canvas` is normally larger than the slot because the shadow has to go
    /// somewhere: a shadow clipped at the icon's own edge is a black ring. Apple
    /// bakes that shadow into the margin of its own master, so Apple's icons are
    /// drawn slot-exact and this one is drawn padded. The two end up with the
    /// same visual shadow, by different means.
    static func mark(
        direction: DotMarkDirection,
        slot: Int,
        inset: Bool,
        canvas: Int? = nil,
        shadow: Bool
    ) -> CGImage? {
        let canvasPixels = canvas ?? slot
        let body = max(1, inset ? systemBody(slot) : slot)
        guard let plate = plate(direction: direction, pixels: body),
              let context = transparentContext(canvasPixels)
        else { return nil }
        if shadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -CGFloat(body) * DotShadow.offset),
                blur: CGFloat(body) * DotShadow.blur,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: DotShadow.alpha)
            )
        }
        let image = NSImage(cgImage: plate, size: NSSize(width: body, height: body))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(
            in: NSRect(
                x: (canvasPixels - body) / 2,
                y: (canvasPixels - body) / 2,
                width: body,
                height: body
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.current = previous
        return context.makeImage()
    }

    private static func transparentContext(_ pixels: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixels,
                  height: pixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context
    }

    /// The fraction of the canvas the art occupies, measured from the alpha.
    ///
    /// The same measurement for every tile, so the number under a tile is read
    /// off the file and not typed in. The threshold is high because the shadow
    /// is a separate claim from the body: an icon that insets to the 824 grid
    /// reports 0.805 whether or not it also carries a drop shadow, and a plate
    /// measured on a canvas with no alpha channel at all reports 1.0.
    static func bodyFraction(_ image: CGImage) -> CGFloat? {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast else {
            return 1
        }
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel == 4 else { return 1 }
        let row = image.bytesPerRow
        let threshold: UInt8 = 250
        var minX = image.width
        var maxX = -1
        for y in 0..<image.height {
            let base = y * row
            for x in 0..<image.width where bytes[base + x * bytesPerPixel + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
        }
        guard maxX >= minX else { return nil }
        return CGFloat(maxX - minX + 1) / CGFloat(image.width)
    }
}

// MARK: - The sheet

/// A drawing surface in points, rendered at `scale`.
///
/// One context for the whole sheet keeps every icon on the same grid: a point
/// is a point everywhere, and the only resampling that happens is the one the
/// system did when it resolved the icon.
@MainActor
final class Sheet {
    let width: CGFloat
    let height: CGFloat
    let scale: CGFloat
    private let context: CGContext

    init(width: CGFloat, height: CGFloat, scale: CGFloat) throws {
        self.width = width
        self.height = height
        self.scale = scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int((width * scale).rounded()),
                  height: Int((height * scale).rounded()),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw RenderError.couldNotCreateContext }
        self.context = context
        context.interpolationQuality = .high
        // Flip into a top-left origin measured in points, so every layout
        // number below reads the way it looks. The translate is in device
        // pixels, because it happens before the scale: a translate of `height`
        // would only move the origin half way up a 2x canvas.
        context.translateBy(x: 0, y: height * scale)
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(Sheet.color(0xF5F4F2).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: Primitives

    nonisolated static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Runs `body` with AppKit drawing aimed at the sheet.
    func drawing(_ body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.current = previous
    }

    func fill(_ path: NSBezierPath, _ fill: NSColor) {
        fill.setFill()
        path.fill()
    }

    func stroke(_ path: NSBezierPath, _ stroke: NSColor, width: CGFloat) {
        stroke.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    func verticalGradient(_ colors: [NSColor], in rect: CGRect) {
        guard let gradient = NSGradient(colors: colors) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        gradient.draw(
            from: NSPoint(x: rect.midX, y: rect.minY),
            to: NSPoint(x: rect.midX, y: rect.maxY),
            options: []
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws an image into `rect`, which is expressed in points at 2x, so an
    /// image of `rect.width * scale` pixels lands 1:1.
    func image(_ image: CGImage, in rect: CGRect, nearest: Bool = false) {
        let cell = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let hints: [NSImageRep.HintKey: Any] = [
            .interpolation: (nearest ? NSImageInterpolation.none : NSImageInterpolation.high).rawValue
        ]
        cell.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: hints
        )
    }

    // MARK: Type

    enum Style {
        static let title = NSFont.systemFont(ofSize: 30, weight: .semibold)
        static let subtitle = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        static let label = NSFont.systemFont(ofSize: 11, weight: .semibold)
        static let caption = NSFont.systemFont(ofSize: 12, weight: .regular)
        static let captionStrong = NSFont.systemFont(ofSize: 12, weight: .semibold)
        static let mono = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    }

    static let ink = color(0x14141A)
    static let inkSoft = color(0x5C5C66)
    static let inkFaint = color(0x8A8A94)
    static let measure = color(0x0E7A8C)

    @discardableResult
    func text(
        _ string: String,
        at point: CGPoint,
        font: NSFont,
        color: NSColor,
        tracking: CGFloat = 0
    ) -> CGFloat {
        let attributed = NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: tracking,
            ]
        )
        attributed.draw(at: point)
        return attributed.size().height
    }

    /// Draws a paragraph inside `rect`, wrapping on words.
    ///
    /// `draw(at:)` lays a string out on one line however long it is, which is
    /// fine for a label and wrong for a caption: an over-long caption runs
    /// straight across the next column and reads as damage.
    func paragraph(_ string: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 1.5
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
        )
        attributed.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )
    }

    static func measuredHeight(_ string: String, font: NSFont, width: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let box = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        return ceil(box.height)
    }

    // MARK: Output

    func write(to url: URL) throws {
        guard let image = context.makeImage() else { throw RenderError.couldNotRender }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw RenderError.couldNotEncode }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 1]] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw RenderError.couldNotEncode }
    }

    enum RenderError: Error, CustomStringConvertible {
        case couldNotRender
        case couldNotEncode
        case couldNotCreateContext
        case missingMaster(String)

        var description: String {
            switch self {
            case .couldNotRender: "the sheet could not be rendered"
            case .couldNotEncode: "the sheet could not be encoded as PNG"
            case .couldNotCreateContext: "the sheet context could not be created"
            case .missingMaster(let path): "no AppIcon-1024.png at \(path)"
            }
        }
    }
}

// MARK: - Layout

/// The sizes and spacings the sheet is built from, all in points.
///
/// They are the Dock's own proportions scaled up: the gutter between two icons
/// is close to a seventh of an icon, the Dock's own padding to a quarter, and
/// the corner radius to a third of the strip's height.
enum Metrics {
    static let width: CGFloat = 2240
    static let margin: CGFloat = 44
    static var content: CGFloat { width - margin * 2 }
    static let scale: CGFloat = 2

    static let stripSizes: [CGFloat] = [128, 64]
    static let appearances: [DockAppearance] = [.dark, .light]

    static func gutter(icon: CGFloat) -> CGFloat { (icon * 0.14).rounded() }
    static func padding(icon: CGFloat) -> CGFloat { (icon * 0.28).rounded() }
    static func bandPadding(icon: CGFloat) -> CGFloat { (icon * 0.26).rounded() }

    static let masterEdge: CGFloat = 512
    static let masterGap: CGFloat = 24
    /// Apple's body inset: the 100 px margin of a 1024 canvas.
    static let guideInset: CGFloat = 100.0 / 1024.0

    static let tinyNative: CGFloat = 8
    static let tinyEnlarged: CGFloat = 128
}

// MARK: - The run

@main
@MainActor
enum RenderInContext {
    static func main() {
        do {
            let request = try Request(arguments: CommandLine.arguments)
            try run(request)
        } catch Request.ArgumentError.help {
            print(Request.usage)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render-in-context: \(error)\n".utf8))
            exit(1)
        }
    }

    struct Request {
        let output: URL
        let direction: DotMarkDirection
        let masters: URL?

        static let usage = """
        usage: render-in-context [--out <dir>] [--direction <name>] [--masters <dir>]

          --out        where the composite is written (default: the working directory)
          --direction  ink, lacquer, porcelain or ember (default: DotMark.chosen)
          --masters    a directory holding AppIcon-1024.png from scripts/render-icon.sh
        """

        init(arguments: [String]) throws {
            var output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            var direction: DotMarkDirection?
            var masters: URL?
            var index = 1
            while index < arguments.count {
                let flag = arguments[index]
                switch flag {
                case "--out", "--direction", "--masters":
                    guard index + 1 < arguments.count else { throw ArgumentError.missingValue(flag) }
                    let value = arguments[index + 1]
                    switch flag {
                    case "--out":
                        output = URL(fileURLWithPath: value, isDirectory: true)
                    case "--masters":
                        masters = URL(fileURLWithPath: value, isDirectory: true)
                    default:
                        guard let named = DotMarkDirection(rawValue: value.lowercased()) else {
                            throw ArgumentError.unknownDirection(value)
                        }
                        direction = named
                    }
                    index += 2
                case "-h", "--help":
                    throw ArgumentError.help
                default:
                    throw ArgumentError.unknownArgument(flag)
                }
            }
            self.output = output
            self.direction = direction ?? DotMark.chosen ?? DotMark.fallback
            self.masters = masters
        }

        enum ArgumentError: Error, CustomStringConvertible {
            case missingValue(String)
            case unknownDirection(String)
            case unknownArgument(String)
            case help

            var description: String {
                switch self {
                case .missingValue(let flag): "\(flag) needs a value"
                case .unknownDirection(let name): "no direction called \(name)"
                case .unknownArgument(let argument): "unknown argument \(argument)"
                case .help: "help"
                }
            }
        }
    }

    static func run(_ request: Request) throws {
        let sheet = try makeSheet(direction: request.direction, masters: request.masters)
        try FileManager.default.createDirectory(at: request.output, withIntermediateDirectories: true)
        let url = request.output.appendingPathComponent("dot-mark-\(request.direction.rawValue)-in-dock.png")
        try sheet.write(to: url)
        print(
            "Dot: composited \(request.direction.name) into \(url.path) "
                + "(\(Int(sheet.width * sheet.scale))x\(Int(sheet.height * sheet.scale)) px)"
        )
    }

    // MARK: The sheet

    private static func makeSheet(direction: DotMarkDirection, masters: URL?) throws -> Sheet {
        let scale = Metrics.scale
        let width = Metrics.width
        let margin = Metrics.margin
        let content = Metrics.content

        // ---- The Dock strips, with the mark in the middle of every one.

        let sides = Neighbours.balanced()

        func slots(icon: CGFloat) -> [(image: CGImage, spill: CGFloat)] {
            let pixels = Int(icon * scale)
            var items: [(CGImage, CGFloat)] = []
            for neighbour in sides.left {
                guard let image = Raster.appIcon(neighbour.path, pixels: pixels) else { continue }
                items.append((image, 0))
            }
            let spill: CGFloat = pixels >= 48 ? 0.14 : 0
            if let mark = Raster.mark(
                direction: direction,
                slot: pixels,
                inset: true,
                canvas: Int((CGFloat(pixels) * (1 + spill)).rounded()),
                shadow: pixels >= 48
            ) {
                items.append((mark, spill))
            }
            for neighbour in sides.right {
                guard let image = Raster.appIcon(neighbour.path, pixels: pixels) else { continue }
                items.append((image, 0))
            }
            return items.map { (image: $0.0, spill: $0.1) }
        }

        struct Strip {
            let appearance: DockAppearance
            let icon: CGFloat
            let items: [(image: CGImage, spill: CGFloat)]
        }

        var strips: [Strip] = []
        for appearance in Metrics.appearances {
            for icon in Metrics.stripSizes {
                strips.append(Strip(appearance: appearance, icon: icon, items: slots(icon: icon)))
            }
        }


        // ---- The master row: the mark, the proposed inset, Apple's own masters.

        struct MasterTile {
            let image: CGImage
            let title: String
            let detail: String
        }

        var tiles: [MasterTile] = []

        if let masters {
            let url = masters.appendingPathComponent("AppIcon-1024.png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let master = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw Sheet.RenderError.missingMaster(url.path) }
            tiles.append(
                MasterTile(
                    image: master,
                    title: "Dot · \(direction.name) · master",
                    detail: "the file scripts/render-icon.sh writes: 1024 px, plate edge to edge, no margin. macOS insets it to 824 before drawing it, so the guide is where the plate lands."
                )
            )
        }

        for name in ["Music", "Photos"] {
            guard let neighbour = Neighbours.left.first(where: { $0.name == name }),
                  let master = Raster.appIcon(neighbour.path, pixels: 1024)
            else { continue }
            tiles.append(
                MasterTile(
                    image: master,
                    title: "\(neighbour.name) · Apple master",
                    detail: "the app's own 1024, resolved by IconServices"
                )
            )
        }

        // ---- The 16 px row.
        //
        // Two versions of the same four icons. The first is what this renderer
        // draws into the 16 px slot; the second is what the system shows after
        // it insets that slot to a 14 px body. They are not the same picture,
        // and the difference is the whole point of the row.

        func tinyImages(inset: Bool) -> [CGImage] {
            let pixels = Int(Metrics.tinyNative * scale)
            var images: [CGImage] = []
            if let mark = Raster.mark(direction: direction, slot: pixels, inset: inset, shadow: false) {
                images.append(mark)
            }
            for name in ["Photos", "Music"] {
                guard let neighbour = Neighbours.left.first(where: { $0.name == name }),
                      let icon = Raster.appIcon(neighbour.path, pixels: pixels)
                else { continue }
                images.append(icon)
            }
            if let notes = Neighbours.right.first(where: { $0.name == "Notes" }),
               let icon = Raster.appIcon(notes.path, pixels: pixels) {
                images.append(icon)
            }
            return images
        }

        let tinyDrawn = tinyImages(inset: false)
        let tinyShown = tinyImages(inset: true)

        // ---- Measure the tiles so the sheet states its own numbers.

        let fractions = tiles.map { Raster.bodyFraction($0.image) }

        // ---- Lay the sheet out, measuring each block before drawing it.

        var blocks: [(height: CGFloat, draw: @MainActor (Sheet) -> Void)] = []
        var cursor = margin

        do {
            let top = cursor
            let titleHeight = Sheet.measuredHeight("Dot, in the Dock", font: Sheet.Style.title, width: content)
            let lede = "Direction \(direction.name), composited against the icons this Mac actually resolves, at the sizes the Dock uses, drawn at \(Int(scale))× so a retina display shows it 1:1. Every row shows the mark the way macOS presents it: IconServices insets any app icon to a body of \(Raster.systemBody(1024)) of \(1024) px, so a full-bleed master is drawn at Apple's grid and not past it. Nothing is installed: the icon set comes from scripts/render-icon.sh --out, and Resources/ is untouched."
            let ledeHeight = Sheet.measuredHeight(lede, font: Sheet.Style.subtitle, width: content)
            blocks.append((titleHeight + 8 + ledeHeight + 40, { sheet in
                sheet.drawing {
                    sheet.text("Dot, in the Dock", at: CGPoint(x: margin, y: top), font: Sheet.Style.title, color: Sheet.ink)
                    sheet.text(
                        lede,
                        at: CGPoint(x: margin, y: top + titleHeight + 8),
                        font: Sheet.Style.subtitle,
                        color: Sheet.inkSoft
                    )
                }
            }))
            cursor += titleHeight + 8 + ledeHeight + 40
        }

        for strip in strips {
            let top = cursor
            let icon = strip.icon
            let gutter = Metrics.gutter(icon: icon)
            let padding = Metrics.padding(icon: icon)
            let bandPadding = Metrics.bandPadding(icon: icon)
            let stripWidth = CGFloat(strip.items.count) * icon + CGFloat(strip.items.count - 1) * gutter + padding * 2
            let stripHeight = icon + padding * 2
            let bandHeight = stripHeight + bandPadding * 2
            let centre = strip.items.count / 2 + 1
            let label = "DOCK · \(strip.appearance.name.uppercased()) APPEARANCE · ICONS AT \(Int(icon)) PT (\(Int(icon * scale)) PX) · DOT IS \(centre) OF \(strip.items.count), CENTRED · AS macOS DRAWS IT, BODY \(Raster.systemBody(Int(icon * scale))) OF \(Int(icon * scale)) PX"
            let labelHeight = Sheet.measuredHeight(label, font: Sheet.Style.label, width: content)
            let bandTop = top + labelHeight + 12
            let stripLeft = (width - stripWidth) / 2
            let stripTop = bandTop + bandPadding
            let appearance = strip.appearance
            let items = strip.items

            blocks.append((labelHeight + 12 + bandHeight + 30, { sheet in
                sheet.drawing {
                    sheet.text(
                        label,
                        at: CGPoint(x: margin, y: top),
                        font: Sheet.Style.label,
                        color: Sheet.inkFaint,
                        tracking: 0.9
                    )
                    // The desktop behind the Dock: without one, "translucent"
                    // is an assertion. With one, it is visible.
                    sheet.verticalGradient(
                        appearance.backdrop,
                        in: CGRect(x: 0, y: bandTop, width: width, height: bandHeight)
                    )

                    let dock = NSBezierPath(
                        roundedRect: CGRect(x: stripLeft, y: stripTop, width: stripWidth, height: stripHeight),
                        xRadius: stripHeight * 0.30,
                        yRadius: stripHeight * 0.30
                    )
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
                    shadow.shadowBlurRadius = stripHeight * 0.16
                    shadow.shadowOffset = NSSize(width: 0, height: 4)
                    NSGraphicsContext.saveGraphicsState()
                    shadow.set()
                    sheet.fill(dock, appearance.dockFill)
                    NSGraphicsContext.restoreGraphicsState()

                    // Sheen, then the hairline: the two things that make a flat
                    // fill read as glass rather than as a slab.
                    NSGraphicsContext.saveGraphicsState()
                    dock.addClip()
                    sheet.verticalGradient(
                        [appearance.dockSheen, appearance.dockSheen.withAlphaComponent(0)],
                        in: CGRect(x: stripLeft, y: stripTop, width: stripWidth, height: stripHeight * 0.55)
                    )
                    NSGraphicsContext.restoreGraphicsState()
                    sheet.stroke(dock, appearance.dockStroke, width: 0.8)

                    for (index, item) in items.enumerated() {
                        let left = stripLeft + padding + CGFloat(index) * (icon + gutter)
                        // The mark casts a shadow, and a shadow clipped at the
                        // icon's own edge is a black ring, so it is drawn in a
                        // box larger than its slot. Everything else, Apple's
                        // included, is slot-exact.
                        let grow = icon * item.spill
                        sheet.image(
                            item.image,
                            in: CGRect(
                                x: left - grow,
                                y: stripTop + padding - grow,
                                width: icon + grow * 2,
                                height: icon + grow * 2
                            )
                        )
                    }
                }
            }))
            cursor += labelHeight + 12 + bandHeight + 30
        }

        if !tiles.isEmpty {
            let top = cursor
            let label = "MASTERS · 1024 PX, SHOWN 1:1 · THE DASHED GUIDE IS APPLE'S 824 BODY GRID"
            let labelHeight = Sheet.measuredHeight(label, font: Sheet.Style.label, width: content)
            let tileTop = top + labelHeight + 16
            let rowWidth = Metrics.masterEdge * CGFloat(tiles.count) + Metrics.masterGap * CGFloat(tiles.count - 1)
            let leader = (content - rowWidth) / 2
            let captionTop = tileTop + Metrics.masterEdge + 14
            let detailHeight = tiles.map {
                Sheet.measuredHeight($0.detail, font: Sheet.Style.caption, width: Metrics.masterEdge)
            }.max() ?? 16
            let height = labelHeight + 16 + Metrics.masterEdge + 14 + 17 + 17 + detailHeight + 34
            let captured = tiles

            blocks.append((height, { sheet in
                sheet.drawing {
                    sheet.text(
                        label,
                        at: CGPoint(x: margin, y: top),
                        font: Sheet.Style.label,
                        color: Sheet.inkFaint,
                        tracking: 0.9
                    )
                    for (index, tile) in captured.enumerated() {
                        let left = margin + leader + CGFloat(index) * (Metrics.masterEdge + Metrics.masterGap)
                        let cell = CGRect(x: left, y: tileTop, width: Metrics.masterEdge, height: Metrics.masterEdge)
                        // A mid ground, so a black plate and a white one are
                        // judged as weight and not as brightness.
                        sheet.fill(NSBezierPath(rect: cell), Sheet.color(0x77777C))
                        sheet.image(tile.image, in: cell)

                        let guide = NSBezierPath(rect: cell.insetBy(dx: cell.width * Metrics.guideInset, dy: cell.height * Metrics.guideInset))
                        guide.setLineDash([6, 5], count: 2, phase: 0)
                        sheet.stroke(guide, Sheet.color(0x25E0FF, 0.95), width: 1)

                        let body = fractions[index].map {
                            String(format: "body %.1f %% of the canvas", Double($0) * 100)
                        } ?? "body not measurable"
                        var textY = captionTop
                        sheet.text(tile.title, at: CGPoint(x: left, y: textY), font: Sheet.Style.captionStrong, color: Sheet.ink)
                        textY += 17
                        sheet.text(body, at: CGPoint(x: left, y: textY), font: Sheet.Style.mono, color: Sheet.measure)
                        textY += 17
                        sheet.paragraph(
                            tile.detail,
                            in: CGRect(x: left, y: textY, width: Metrics.masterEdge, height: detailHeight + 4),
                            font: Sheet.Style.caption,
                            color: Sheet.inkFaint
                        )
                    }
                }
            }))
            cursor += height
        }

        do {
            let top = cursor
            let label = "16 PX · MENU BAR AND TOOLBAR CONTEXT · DOT, THEN PHOTOS, MUSIC AND NOTES"
            let labelHeight = Sheet.measuredHeight(label, font: Sheet.Style.label, width: content)

            let nativeY = top + labelHeight + 14
            let nativeHeight: CGFloat = 40
            let drawnTitleY = nativeY + nativeHeight + 22
            let drawnY = drawnTitleY + 20
            let shownTitleY = drawnY + Metrics.tinyEnlarged + 24
            let shownY = shownTitleY + 20
            let captionY = shownY + Metrics.tinyEnlarged + 32 + 18
            let height = labelHeight + 14 + nativeHeight + 22 + 20 + Metrics.tinyEnlarged
                + 24 + 20 + Metrics.tinyEnlarged + 32 + 18 + 18 + 34

            // The dot's size at sixteen pixels is a property of the direction, not
            // a phrase: a label that says "five" after a geometry change is how a
            // sheet ends up describing an icon that is not on it.
            let nativeDot = Int(DotGeometry(direction: direction, plate: Metrics.tinyNative).diameter)
            let bodyDot = String(
                format: "%.1f",
                Double(DotGeometry(direction: direction, plate: CGFloat(Raster.systemBody(16))).diameter)
            )
            let drawnTitle = "what scripts/render-icon.sh writes: the plate fills all \(Int(Metrics.tinyNative)) pixels, and the dot was snapped to \(nativeDot)"
            let shownTitle = "what macOS shows: the same slot inset to a \(Raster.systemBody(16)) px body, so the dot comes back at \(bodyDot) pixels of antialiasing"

            blocks.append((height, { sheet in
                sheet.drawing {
                    sheet.text(
                        label,
                        at: CGPoint(x: margin, y: top),
                        font: Sheet.Style.label,
                        color: Sheet.inkFaint,
                        tracking: 0.9
                    )

                    // The real size first. Sixteen device pixels, drawn as
                    // sixteen device pixels, on both appearances.
                    var left = margin
                    for appearance in Metrics.appearances {
                        let chipWidth = CGFloat(tinyShown.count) * Metrics.tinyNative
                            + CGFloat(tinyShown.count - 1) * 4 + 20
                        sheet.fill(
                            NSBezierPath(
                                roundedRect: CGRect(x: left, y: nativeY, width: chipWidth, height: nativeHeight),
                                xRadius: 8,
                                yRadius: 8
                            ),
                            appearance.backdrop[0]
                        )
                        for (index, icon) in tinyShown.enumerated() {
                            let x = left + 10 + CGFloat(index) * (Metrics.tinyNative + 4)
                            sheet.image(
                                icon,
                                in: CGRect(
                                    x: x,
                                    y: nativeY + (nativeHeight - Metrics.tinyNative) / 2,
                                    width: Metrics.tinyNative,
                                    height: Metrics.tinyNative
                                )
                            )
                        }
                        left += chipWidth + 16
                    }

                    // Then both versions of the same row, magnified with
                    // interpolation off, so the pixels can be judged directly.
                    for (title, y, images) in [
                        (drawnTitle, drawnY, tinyDrawn),
                        (shownTitle, shownY, tinyShown),
                    ] {
                        let chipWidth = CGFloat(images.count) * Metrics.tinyEnlarged
                            + CGFloat(images.count - 1) * 16 + 32
                        sheet.fill(
                            NSBezierPath(
                                roundedRect: CGRect(x: margin, y: y, width: chipWidth, height: Metrics.tinyEnlarged + 32),
                                xRadius: 10,
                                yRadius: 10
                            ),
                            Sheet.color(0x2A2A31)
                        )
                        for (index, icon) in images.enumerated() {
                            let x = margin + 16 + CGFloat(index) * (Metrics.tinyEnlarged + 16)
                            sheet.image(
                                icon,
                                in: CGRect(x: x, y: y + 16, width: Metrics.tinyEnlarged, height: Metrics.tinyEnlarged),
                                nearest: true
                            )
                        }
                        sheet.text(
                            title,
                            at: CGPoint(x: margin + chipWidth + 24, y: y + 16),
                            font: Sheet.Style.caption,
                            color: Sheet.inkSoft
                        )
                    }

                    sheet.text(
                        "the two rows are the same four icons at 16× with interpolation off; only the mark differs, because only the mark is ours to draw",
                        at: CGPoint(x: margin, y: captionY),
                        font: Sheet.Style.caption,
                        color: Sheet.inkFaint
                    )
                }
            }))
            cursor += height
        }

        let sheet = try Sheet(width: width, height: cursor + margin, scale: scale)
        for block in blocks {
            block.draw(sheet)
        }
        return sheet
    }
}
