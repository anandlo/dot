import AppKit
import DotCore
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders the app icon and the menu bar glyph without showing anything.
///
/// The drawings are code (``DotMark`` and ``DotMarkDial``), so this is the only
/// way an icon file is ever made: there is no hand-edited PNG in the tree.
/// `scripts/render-icon.sh` runs this, hands the iconset to `iconutil` and the
/// Icon Composer document to `actool`, and no window is ever created.
///
/// Every master is drawn at scale 1, so one point is one pixel: a 16 point tile
/// is a sixteen pixel drawing of the vector, not a downscale of the 1024.
///
/// Three kinds of file come out of it:
///
/// - the iconset, whose every slot is masked to ``DotIconGrid`` and carries a
///   transparent margin, which is what macOS 14 and 15 need in order to show a
///   rounded icon instead of a square;
/// - the Icon Composer document, whose layers are unmasked and full bleed,
///   because macOS 26 shapes and lights the icon itself;
/// - the site's marks, both masked and full bleed, since a favicon is drawn on
///   nothing and an iOS touch icon is masked by iOS.
@MainActor
enum IconRender {
    /// The argument that renders the installable assets and exits.
    static let argument = "--render-icon"
    /// The environment variable that does the same, named without the product
    /// prefix that ``DotMigration/environment(_:in:)`` adds. That reader accepts
    /// the pre-rename spelling of the prefix as well.
    static let environmentKey = "RENDER_ICON"
    /// The flag that draws one of the studied plates instead of the shipped mark.
    static let directionFlag = "--direction"

    /// The mark a render draws.
    ///
    /// The shipped mark is a dial on Porcelain's plate. An explicit
    /// `--direction` asks for one of the four studied plates instead, which is
    /// how the script can still render a direction that was reviewed.
    enum Mark {
        case dial(DotMarkDial)
        case direction(DotMarkDirection)

        /// The mark the app ships.
        static var shipped: Mark { .dial(DotMark.chosenDial ?? .control) }
    }

    /// The ten slots an `.icns` needs, as the file name and its pixel size.
    ///
    /// The pairs exist because a slot is named for a point size and carries one
    /// or two pixels per point. Every slot is drawn at its own pixel size, so no
    /// slot is a resample of another: the 1024 is not the source of the 16.
    static let iconsetSlots: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    /// One file the renderer writes into the site's asset directory.
    struct SiteAsset {
        /// The file name the site asks for.
        let name: String
        /// Its edge in pixels.
        let pixels: Int
        /// Whether the grid's corner is baked in and the margin transparent.
        ///
        /// A favicon and a rounded mark sit on a page, so they carry the corner.
        /// A touch icon does not: iOS masks it, and a mask on a mask shows a
        /// double corner. The social card is full bleed because a card crops to
        /// its own frame.
        let masked: Bool
    }

    /// The site's marks. The paths are the ones `index.html` and the README
    /// already ask for, so this list is the contract with the site.
    static let siteAssets: [SiteAsset] = [
        SiteAsset(name: "icon.png", pixels: 1024, masked: false),
        SiteAsset(name: "icon-180.png", pixels: 180, masked: false),
        SiteAsset(name: "icon-rounded.png", pixels: 1024, masked: true),
        SiteAsset(name: "icon-512.png", pixels: 512, masked: true),
        SiteAsset(name: "icon-32.png", pixels: 32, masked: true),
    ]

    /// The directory the render was asked for, if any.
    static func requestedDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> URL? {
        if let index = arguments.firstIndex(of: argument), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let value = DotMigration.environment(Self.environmentKey, in: environment) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return nil
    }

    /// The mark the command line asked for.
    ///
    /// A name that is not a studied direction is not a failure: the shipped mark
    /// is drawn, because installing an icon from a name nobody reviewed is the
    /// one thing this path must not do silently.
    static func requestedMark(arguments: [String] = CommandLine.arguments) -> Mark {
        guard let index = arguments.firstIndex(of: directionFlag),
              index + 1 < arguments.count,
              let direction = DotMarkDirection(rawValue: arguments[index + 1].lowercased())
        else { return .shipped }
        return .direction(direction)
    }

    // MARK: - Rendering

    /// Writes every icon master, the Icon Composer document and the menu bar
    /// glyph into `directory`.
    static func renderAll(to directory: URL, mark: Mark = .shipped) throws {
        let fileManager = FileManager.default
        let iconset = directory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

        // A repeated slot name is drawn once: two slots that name the same file
        // would be two writers of one path.
        var written = Set<String>()
        for slot in iconsetSlots where written.insert(slot.name).inserted {
            let image = try masked(mark, pixels: CGFloat(slot.pixels))
            try writeAlpha(image, to: iconset.appendingPathComponent(slot.name))
        }

        // The in-app tile stays full bleed. ``DotSignalMark`` draws it under its
        // own rounded clip, so an already-masked file would put a second margin
        // inside that frame and shrink the mark.
        try writeOpaque(
            try fullBleed(mark, pixels: DotIconGrid.reference),
            to: directory.appendingPathComponent("AppIcon-1024.png")
        )

        try writeSiteAssets(
            to: directory.appendingPathComponent("site", isDirectory: true),
            mark: mark
        )
        try writeIconComposer(to: directory, mark: mark)
        try writeMenuGlyph(to: directory)
    }

    /// Writes the site's marks into `directory`, one drawing per size.
    static func writeSiteAssets(to directory: URL, mark: Mark = .shipped) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for asset in siteAssets {
            let target = directory.appendingPathComponent(asset.name)
            let pixels = CGFloat(asset.pixels)
            if asset.masked {
                try writeAlpha(masked(mark, pixels: pixels), to: target)
            } else {
                try writeOpaque(fullBleed(mark, pixels: pixels), to: target)
            }
        }
    }

    /// Writes `AppIcon.icon` into `directory`.
    ///
    /// The shipped mark is layered: the plate, the disc's seat and the disc, so
    /// each silhouette is its own and the system can light the disc without
    /// drawing a rim around its shadow. A studied direction is one flat drawing,
    /// so it becomes the document's single background layer.
    static func writeIconComposer(to directory: URL, mark: Mark = .shipped) throws {
        let reference = DotIconGrid.reference
        let canvas = CGSize(width: reference, height: reference)
        let plateLayer: CGImage
        let seatLayer: CGImage?
        let discLayer: CGImage?
        switch mark {
        case .dial(let dial):
            plateLayer = try bitmap(
                DotPlateSurface(direction: .porcelain, size: reference),
                size: canvas,
                opaque: true
            )
            seatLayer = try seat(dial: dial, pixels: reference)
            discLayer = try disc(dial: dial, pixels: reference)
        case .direction(let direction):
            plateLayer = try fullBleed(.direction(direction), pixels: reference)
            seatLayer = nil
            discLayer = nil
        }
        try AppIconPackage.write(
            to: directory.appendingPathComponent(AppIconPackage.directoryName, isDirectory: true),
            plate: plateLayer,
            seat: seatLayer,
            disc: discLayer
        )
    }

    /// Writes the menu bar glyph: black on transparent, at 18 and 36.
    static func writeMenuGlyph(to directory: URL) throws {
        try writeTemplate(
            DotMenuGlyph(size: 18, kind: .shipped),
            size: 18,
            to: directory.appendingPathComponent("MenuGlyph.png")
        )
        // Drawn at 36 rather than an 18 point drawing in a 36 point frame: the
        // @2x slot is the same glyph at twice the pixels, and a view that was
        // laid out at 18 would be centred in a box twice its size.
        try writeTemplate(
            DotMenuGlyph(size: 36, kind: .shipped),
            size: 36,
            to: directory.appendingPathComponent("MenuGlyph@2x.png")
        )
    }

    // MARK: - Drawing

    /// One mark at one canvas size, masked to the grid.
    ///
    /// The artwork is drawn at the body's edge and the margin around it is left
    /// transparent, so the file says "rounded icon" to a macOS that will not
    /// round it. At 16 and 32 pixels that leaves a twelve and a twenty six pixel
    /// body: the drawing is made at that size, not sampled down to it.
    static func masked(_ mark: Mark, pixels: CGFloat) throws -> CGImage {
        let body = DotIconGrid.body(inCanvas: pixels)
        let image = try bitmap(
            DotIconMaster(size: pixels) { artwork(mark, size: body) },
            size: CGSize(width: pixels, height: pixels),
            opaque: false
        )
        return image
    }

    /// One mark at one size, filling the canvas.
    ///
    /// This is the shape the study sheets and the in-app tile use, and the shape
    /// iOS masks for itself. It is not an app icon on macOS 14 or 15: a bundle
    /// that ships this ships a square.
    static func fullBleed(_ mark: Mark, pixels: CGFloat) throws -> CGImage {
        try bitmap(
            artwork(mark, size: pixels),
            size: CGSize(width: pixels, height: pixels),
            opaque: true
        )
    }

    /// One dial's seat at one canvas size: its cast shadow and rim, on nothing.
    static func seat(dial: DotMarkDial, pixels: CGFloat) throws -> CGImage {
        try bitmap(
            DotMarkDialTile(dial: dial, size: pixels, parts: [.seat]),
            size: CGSize(width: pixels, height: pixels),
            opaque: false
        )
    }

    /// One dial's disc at one canvas size, on nothing.
    static func disc(dial: DotMarkDial, pixels: CGFloat) throws -> CGImage {
        try bitmap(
            DotMarkDialTile(dial: dial, size: pixels, parts: [.disc]),
            size: CGSize(width: pixels, height: pixels),
            opaque: false
        )
    }

    /// One plate at one size, as a bitmap.
    static func plate(direction: DotMarkDirection, size: CGFloat) throws -> CGImage {
        try bitmap(DotPlate(direction: direction, size: size), size: CGSize(width: size, height: size))
    }

    /// One dial's plate at one size, as a bitmap.
    static func plate(dial: DotMarkDial, size: CGFloat) throws -> CGImage {
        try bitmap(
            DotMarkDialTile(dial: dial, size: size),
            size: CGSize(width: size, height: size)
        )
    }

    /// The mark's artwork, filling a square of `size` points.
    @ViewBuilder
    private static func artwork(_ mark: Mark, size: CGFloat) -> some View {
        switch mark {
        case .dial(let dial):
            DotMarkDialTile(dial: dial, size: size)
        case .direction(let direction):
            DotPlate(direction: direction, size: size)
        }
    }

    /// One view as a bitmap at scale 1.
    private static func bitmap<V: View>(_ view: V, size: CGSize, opaque: Bool = true) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.isOpaque = opaque
        guard let image = renderer.cgImage else { throw RenderError.couldNotRender }
        return image
    }

    // MARK: - Encoding

    /// Writes a PNG that keeps its alpha channel.
    ///
    /// An icon master has to declare its own shape: a transparent margin is how
    /// a file tells macOS 14 and 15 that the icon is a rounded tile rather than
    /// a square. `sips -g hasAlpha` reports `yes` for every file this writes.
    nonisolated static func writeAlpha(_ image: CGImage, to url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw RenderError.couldNotCreateContext
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.clear(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else { throw RenderError.couldNotRender }
        try encode(flattened, to: url)
    }

    /// Writes a PNG with no alpha channel at all.
    ///
    /// A full-bleed master is opaque on purpose: nothing in it is meant to be
    /// seen through, and macOS 26 masks the lifted layer itself. The context
    /// here has no alpha component, so the file says "opaque" rather than
    /// "transparent everywhere but painted", and `sips -g hasAlpha` reports
    /// `no`.
    nonisolated static func writeOpaque(_ image: CGImage, to url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else {
            throw RenderError.couldNotCreateContext
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // The plate covers every pixel, so the ground only matters if a render
        // ever leaves one bare.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flat = context.makeImage() else {
            throw RenderError.couldNotRender
        }
        try encode(flat, to: url)
    }

    /// Writes one bitmap as a PNG.
    nonisolated private static func encode(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw RenderError.couldNotEncode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.couldNotEncode
        }
    }

    /// Writes a template glyph: black ink on a transparent ground.
    private static func writeTemplate<V: View>(_ view: V, size: CGFloat, to url: URL) throws {
        let image = try bitmap(view, size: CGSize(width: size, height: size), opaque: false)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.couldNotEncode
        }
        try data.write(to: url, options: .atomic)
    }

    /// The render could not be made.
    enum RenderError: Error {
        case couldNotRender
        case couldNotEncode
        case couldNotCreateContext
    }
}
