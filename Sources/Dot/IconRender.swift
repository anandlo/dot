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
/// `scripts/render-icon.sh` runs this and hands the iconset to `iconutil`, and
/// no window is ever created.
///
/// Every master is drawn at scale 1, so one point is one pixel: a 16 point tile
/// is a sixteen pixel master, not a downscale of the 1024.
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
    /// slot is a resample of another.
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

    /// The sizes `AppIcon-<n>.png` is written at.
    static let flatSizes = [1024, 512, 256, 128, 64, 32, 16]

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

    /// Writes the icon masters and the menu bar glyph into `directory`.
    static func renderAll(to directory: URL, mark: Mark = .shipped) throws {
        try writeAssets(to: directory) { size in
            switch mark {
            case .dial(let dial):
                try plate(dial: dial, size: size)
            case .direction(let direction):
                try plate(direction: direction, size: size)
            }
        }
        try writeMenuGlyph(to: directory)
    }

    /// Draws the masters for one mark at every size the `.icns` and the flat
    /// copies need, then writes the iconset.
    private static func writeAssets(
        to directory: URL,
        master: (CGFloat) throws -> CGImage
    ) throws {
        let fileManager = FileManager.default
        let iconset = directory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

        for size in flatSizes {
            let image = try master(CGFloat(size))
            try writeOpaque(image, to: directory.appendingPathComponent("AppIcon-\(size).png"))
        }

        // The iconset is what `iconutil` reads. A repeated name is drawn once:
        // two slots that name the same file would be two writers of one path.
        var written = Set<String>()
        for slot in iconsetSlots where written.insert(slot.name).inserted {
            let image = try master(CGFloat(slot.pixels))
            try writeOpaque(image, to: iconset.appendingPathComponent(slot.name))
        }
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

    /// One view as a bitmap at scale 1.
    private static func bitmap<V: View>(_ view: V, size: CGSize, opaque: Bool = true) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.isOpaque = opaque
        guard let image = renderer.cgImage else { throw RenderError.couldNotRender }
        return image
    }

    // MARK: - Encoding

    /// Writes a PNG with no alpha channel at all.
    ///
    /// An icon master that carries an alpha channel is a transparency
    /// declaration whatever its values are, and macOS masks the icon itself.
    /// The context here has no alpha component, so the file says "opaque"
    /// rather than "transparent everywhere but painted", and `sips -g hasAlpha`
    /// reports `no`.
    static func writeOpaque(_ image: CGImage, to url: URL) throws {
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
        // ever leaves one bare. Black keeps that failure invisible instead of
        // turning it into a white fringe.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flat = context.makeImage() else {
            throw RenderError.couldNotRender
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw RenderError.couldNotEncode
        }
        CGImageDestinationAddImage(destination, flat, nil)
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
