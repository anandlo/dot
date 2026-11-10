import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders the brand assets and the design studies without showing anything.
///
/// Two modes, each with one job:
///
/// - `--render-icon <dir>` writes the app icon at every size an `.icns` needs,
///   plus the menu bar glyph at 18 and 36. This is the installed-asset path;
///   `scripts/render-icon.sh` runs it and hands the result to `iconutil`.
/// - `--render-study <dir>` writes the review sheets. Nothing here is ever
///   installed: a sheet is evidence for a decision, not an asset.
/// - `--render-differentiation <dir> [--competitors <dir>]` writes the sheet
///   that places four dot geometries beside the category's real App Store
///   artwork.
///
/// Both render at scale 1 so one point is one pixel: a 16 point icon is a
/// sixteen pixel master, not a downscale of the 1024.
@MainActor
enum BrandRender {
    /// The argument that renders the installable assets.
    static let argument = "--render-icon"
    /// The argument that renders the review sheets.
    static let studyArgument = "--render-study"
    /// The argument that renders the differentiation sheet.
    static let differentiationArgument = "--render-differentiation"
    /// The argument that renders the menu bar glyph comparison.
    static let menuGlyphArgument = "--render-menuglyph"
    /// The flag that points either sheet at the downloaded category artwork.
    static let competitorsFlag = "--competitors"
    /// The flag that picks a direction for either mode.
    static let directionFlag = "--direction"

    /// What a run was asked to do.
    struct Request {
        enum Mode {
            case assets
            case study
            case differentiation
            case menuGlyph
        }

        /// What the assets are drawn from.
        ///
        /// A studied direction is a plate with its own dot; the dials are the
        /// dot geometries drawn on Porcelain's plate. An explicit `--direction`
        /// always means the former, so the study tooling can still ask for any
        /// of the four plates while the installed mark is a dial.
        enum Mark {
            case dial(DotMarkDial)
            case direction(DotMarkDirection)
        }

        let mode: Mode
        let directory: URL
        let mark: Mark
        /// The directory holding the category's artwork, if one was given.
        var competitors: URL?
    }

    /// The sizes the `.icns` slots need, as point sizes with their scale.
    ///
    /// Ten slots: 16, 32, 32, 64, 128, 256, 256, 512, 512, 1024. The pairs
    /// exist because a slot is named for a point size and carries one or two
    /// pixels per point.
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

    /// The sizes `AppIcon-<n>.png` is written at, matching the old generator.
    static let flatSizes = [1024, 512, 256, 128, 64, 32, 16]

    // MARK: - Arguments

    /// The work the command line asked for, if any.
    static func request(
        arguments: [String] = CommandLine.arguments
    ) -> Request? {
        if let index = arguments.firstIndex(of: argument), index + 1 < arguments.count {
            return makeRequest(mode: .assets, path: arguments[index + 1], arguments: arguments)
        }
        if let index = arguments.firstIndex(of: studyArgument), index + 1 < arguments.count {
            return makeRequest(mode: .study, path: arguments[index + 1], arguments: arguments)
        }
        if let index = arguments.firstIndex(of: differentiationArgument), index + 1 < arguments.count {
            return makeRequest(
                mode: .differentiation,
                path: arguments[index + 1],
                arguments: arguments
            )
        }
        if let index = arguments.firstIndex(of: menuGlyphArgument), index + 1 < arguments.count {
            return makeRequest(
                mode: .menuGlyph,
                path: arguments[index + 1],
                arguments: arguments
            )
        }
        return nil
    }

    private static func makeRequest(
        mode: Request.Mode,
        path: String,
        arguments: [String]
    ) -> Request? {
        var name: String?
        if let index = arguments.firstIndex(of: directionFlag), index + 1 < arguments.count {
            name = arguments[index + 1]
        }
        // An explicit `--direction` asks for one of the four plates. Without
        // one, the assets are the mark the app ships, which is a dial.
        let mark: Request.Mark
        if let name, let direction = DotMark.direction(named: name) {
            mark = .direction(direction)
        } else {
            mark = .dial(DotMark.chosenDial ?? .control)
        }
        var competitors: URL?
        if let index = arguments.firstIndex(of: competitorsFlag), index + 1 < arguments.count {
            competitors = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return Request(
            mode: mode,
            directory: URL(fileURLWithPath: path, isDirectory: true),
            mark: mark,
            competitors: competitors
        )
    }

    /// What the run should say on the command line.
    static func describe(_ request: Request) -> String {
        switch (request.mode, request.mark) {
        case (.assets, .dial(let dial)):
            "Dot: rendering the \(dial.name) mark's assets into \(request.directory.path)"
        case (.assets, .direction(let direction)):
            "Dot: rendering \(direction.name) assets into \(request.directory.path)"
        case (.study, _):
            "Dot: rendering the mark study into \(request.directory.path)"
        case (.differentiation, _):
            "Dot: rendering the differentiation sheet into \(request.directory.path)"
        case (.menuGlyph, _):
            "Dot: rendering the menu bar glyph comparison into \(request.directory.path)"
        }
    }

    // MARK: - Assets

    /// Writes the icon masters and the menu bar glyph.
    static func renderAssets(direction: DotMarkDirection, to directory: URL) throws {
        try writeAssets(to: directory) { size in
            try plate(direction: direction, size: size)
        }
        try writeMenuGlyph(to: directory)
    }

    /// Writes the icon masters for one dial, and the menu bar glyph.
    static func renderAssets(dial: DotMarkDial, to directory: URL) throws {
        try writeAssets(to: directory) { size in
            try plate(dial: dial, size: size)
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

        // The iconset is what `iconutil` reads. Every slot is drawn at its own
        // pixel size, so no slot is a resample of another.
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
        // Drawn at 36 rather than a 18 point drawing in a 36 point frame:
        // the @2x slot is the same glyph at twice the pixels, and a view that
        // was laid out at 18 would be centred in a box twice its size.
        try writeTemplate(
            DotMenuGlyph(size: 36, kind: .shipped),
            size: 36,
            to: directory.appendingPathComponent("MenuGlyph@2x.png")
        )
    }

    // MARK: - Menu glyph comparison

    /// Writes the sheet the menu bar glyph is chosen from.
    static func renderMenuGlyphComparison(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var glyphs: [DotMenuGlyph.Kind: NSImage] = [:]
        var doubles: [DotMenuGlyph.Kind: NSImage] = [:]
        var extents: [DotMenuGlyph.Kind: CGSize] = [:]
        for kind in DotMenuGlyphComparison.candidates {
            let single = try glyph(kind, size: 18)
            glyphs[kind] = try image(single)
            doubles[kind] = try image(try glyph(kind, size: 36))
            extents[kind] = inkExtent(of: single)
        }

        try writeSheet(
            DotMenuGlyphComparison(glyphs: glyphs, doubles: doubles, extents: extents),
            size: DotMenuGlyphComparison.size,
            to: directory.appendingPathComponent("dot-mark-menuglyph-clipped.png")
        )
    }

    /// The bounding box of the ink in a template render, in points.
    ///
    /// The sheet quotes this so a candidate's weight is a measurement rather
    /// than an adjective: the box is read back from the same bitmap that is
    /// installed, not recomputed from the shape's parameters.
    private static func inkExtent(of image: CGImage) -> CGSize {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              let space = image.colorSpace
        else { return .zero }
        let width = image.width
        let height = image.height
        let components = space.model == .rgb ? 4 : 1
        var left = width
        var right = -1
        var top = height
        var bottom = -1
        for y in 0..<height {
            for x in 0..<width {
                // An alpha-first render would put coverage in component 0;
                // ImageRenderer's bitmaps are RGBA, so alpha is the last one.
                let offset = (y * image.bytesPerRow) + x * components
                guard offset + components <= CFDataGetLength(data) else { continue }
                let alpha = bytes[offset + components - 1]
                guard alpha > 0 else { continue }
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return .zero }
        return CGSize(width: CGFloat(right - left + 1), height: CGFloat(bottom - top + 1))
    }

    // MARK: - Study

    /// Writes every sheet the decision needs.
    static func renderStudy(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for direction in DotMarkDirection.allCases {
            try writeSheet(
                try detailSheet(for: direction),
                size: DotMarkDetailSheet.size,
                to: directory.appendingPathComponent("dot-mark-\(direction.rawValue).png")
            )
        }

        try writeSheet(
            try overviewSheet(),
            size: DotMarkOverviewSheet.size,
            to: directory.appendingPathComponent("dot-mark-contact-sheet.png")
        )

        try writeSheet(
            try menuGlyphSheet(),
            size: DotMenuGlyphSheet.size,
            to: directory.appendingPathComponent("dot-mark-menuglyph.png")
        )
    }

    // MARK: - Differentiation

    /// The category's own artwork, in the order the sheet's row uses.
    ///
    /// Aqua Voice first because it is the icon this mark currently duplicates,
    /// and the other three after ours. The files are what
    /// `scripts/render-mark-differentiation.sh` downloads.
    private static let castFiles = [
        ("Aqua Voice", "aquavoice"),
        ("Wispr Flow", "wisprflow"),
        ("superwhisper", "superwhisper"),
        ("Monologue", "monologue"),
    ]

    /// Writes the sheet that places four dot geometries in the category.
    ///
    /// The category art is never drawn here: it is loaded from the directory
    /// `--competitors` names, and a missing icon is reported and skipped rather
    /// than replaced. A stand-in would answer the one question this sheet exists
    /// to ask with a shape we invented.
    static func renderDifferentiation(to directory: URL, competitors: URL?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let cast = loadCast(from: competitors)
        let ourSlot = min(2, cast.count)

        var rows: [DotMarkDifferenceSheet.Row] = []
        for (index, dial) in DotMarkDial.studied.enumerated() {
            rows.append(
                try differentiationRow(
                    dial: dial,
                    number: String(format: "%02d", index + 1),
                    cast: cast,
                    ourSlot: ourSlot
                )
            )
        }

        let sheet = DotMarkDifferenceSheet(
            cast: cast,
            control: try differentiationRow(
                dial: .control,
                number: nil,
                cast: cast,
                ourSlot: ourSlot
            ),
            rows: rows,
            ourSlot: ourSlot
        )

        try writeSheet(
            sheet,
            size: DotMarkDifferenceSheet.size,
            to: directory.appendingPathComponent("dot-mark-differentiation-sheet.png")
        )

        // The masters are written at their own 1024 pixels as well, so a
        // direction can be inspected at 1:1 without re-rendering it.
        for dial in DotMarkDial.studied {
            try writeOpaque(
                try plate(dial: dial, size: 1024),
                to: directory.appendingPathComponent("dot-mark-dial-\(dial.rawValue)-1024.png")
            )
        }
    }

    /// One direction's row: masters, the small strip, and the category strip.
    private static func differentiationRow(
        dial: DotMarkDial,
        number: String?,
        cast: [DotMarkDifferenceSheet.Cast],
        ourSlot: Int
    ) throws -> DotMarkDifferenceSheet.Row {
        // Rendered at the master's own 1024 pixels and only scaled down for the
        // sheet: the panel is a view of the master, not a 440 pixel redraw.
        let master = NSImage(
            cgImage: try presentation(dial: dial, size: 1024),
            size: NSSize(
                width: DotMarkDifferenceSheet.masterBox,
                height: DotMarkDifferenceSheet.masterBox
            )
        )
        var slots = cast.map(\.image)
        // One tile, used on both grounds: the ground is the sheet's, and the
        // only thing that changes between the two strips is what it sits on.
        slots.insert(try image(masked(dial: dial, size: DotMarkDifferenceSheet.tileSize)), at: ourSlot)
        return DotMarkDifferenceSheet.Row(
            dial: dial,
            number: number,
            masterLight: master,
            masterDark: master,
            strip: [
                try image(masked(dial: dial, size: 16)),
                try image(masked(dial: dial, size: 32)),
                try image(masked(dial: dial, size: 64)),
            ],
            categoryLight: slots,
            categoryDark: slots
        )
    }

    private static func loadCast(from directory: URL?) -> [DotMarkDifferenceSheet.Cast] {
        var cast: [DotMarkDifferenceSheet.Cast] = []
        guard let directory else {
            warn("no --competitors directory: the sheet will have no category rows")
            return cast
        }
        for (name, file) in castFiles {
            let url = directory.appendingPathComponent("\(file).png")
            guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
                warn("no artwork for \(name) at \(url.path): the row will show the rest")
                continue
            }
            cast.append(DotMarkDifferenceSheet.Cast(name: name, image: image))
        }
        return cast
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("Dot: \(message)\n".utf8))
    }

    // MARK: - Sheet content

    private static let overviewIconEdge: CGFloat = 268

    private static func overviewSheet() throws -> DotMarkOverviewSheet {
        var rows: [DotMarkOverviewSheet.Row] = []
        for (index, direction) in DotMarkDirection.allCases.enumerated() {
            rows.append(
                DotMarkOverviewSheet.Row(
                    direction: direction,
                    index: index + 1,
                    light: try image(presentation(direction: direction, size: overviewIconEdge)),
                    dark: try image(presentation(direction: direction, size: overviewIconEdge)),
                    small: [
                        try image(masked(direction: direction, size: 64)),
                        try image(masked(direction: direction, size: 32)),
                        try image(masked(direction: direction, size: 16)),
                    ],
                    edge: try image(seatCrop(direction: direction, size: 1024, width: 200, height: 120))
                )
            )
        }
        return DotMarkOverviewSheet(rows: rows, iconEdge: overviewIconEdge)
    }

    private static func detailSheet(for direction: DotMarkDirection) throws -> DotMarkDetailSheet {
        DotMarkDetailSheet(
            direction: direction,
            light: try image(presentation(direction: direction, size: 380)),
            dark: try image(presentation(direction: direction, size: 380)),
            strip: [
                try image(masked(direction: direction, size: 16)),
                try image(masked(direction: direction, size: 32)),
                try image(masked(direction: direction, size: 64)),
            ],
            edge: try image(crop(direction: direction, size: 1024, width: 430, height: 205)),
            seat: try image(seatCrop(direction: direction, size: 1024, width: 430, height: 205))
        )
    }

    private static func menuGlyphSheet() throws -> DotMenuGlyphSheet {
        var glyphs: [DotMenuGlyph.Kind: NSImage] = [:]
        var doubles: [DotMenuGlyph.Kind: NSImage] = [:]
        for kind in DotMenuGlyph.Kind.legacy {
            glyphs[kind] = try image(glyph(kind, size: 18))
            doubles[kind] = try image(glyph(kind, size: 36))
        }
        return DotMenuGlyphSheet(glyphs: glyphs, doubles: doubles)
    }

    /// A crop of the master anchored on the dot's rim.
    ///
    /// This is the one place a material cannot hide: the transition from the
    /// dot to the plate at one to one, which is what a person sees in the Dock
    /// and what a screenshot of a rendered "effect" always flatters.
    private static func crop(
        direction: DotMarkDirection,
        size: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) throws -> CGImage {
        let master = try plate(direction: direction, size: size)
        let centre = CGPoint(
            x: size / 2 + size * direction.diameter / 2,
            y: size * direction.centre
        )
        let rect = CGRect(
            x: centre.x - width / 2,
            y: centre.y - height / 2,
            width: width,
            height: height
        ).integral
        guard let cropped = master.cropping(to: rect) else {
            throw RenderError.couldNotRender
        }
        return cropped
    }

    /// A crop of the dot's lower edge, at one to one.
    ///
    /// The seat is where a drawing admits whether it was lit or assembled: a
    /// rim occlusion, a crisp decal contact, a cast shadow and an emitter all
    /// look different here and identical at icon size.
    private static func seatCrop(
        direction: DotMarkDirection,
        size: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) throws -> CGImage {
        let master = try plate(direction: direction, size: size)
        let centre = CGPoint(
            x: size / 2,
            y: size * direction.centre + size * direction.diameter / 2
        )
        let rect = CGRect(
            x: centre.x - width / 2,
            y: centre.y - height / 2,
            width: width,
            height: height
        ).integral
        guard let cropped = master.cropping(to: rect) else {
            throw RenderError.couldNotRender
        }
        return cropped
    }

    private static func image(_ cgImage: CGImage) throws -> NSImage {
        NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
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

    /// One dial masked to the system corner, at exactly `size` pixels.
    static func masked(dial: DotMarkDial, size: CGFloat) throws -> CGImage {
        try bitmap(
            DotMarkDialTile(dial: dial, size: size).clipShape(DotSquircle()),
            size: CGSize(width: size, height: size),
            opaque: false
        )
    }

    /// One dial with its Dock shadow, as a bitmap.
    static func presentation(dial: DotMarkDial, size: CGFloat) throws -> CGImage {
        let padded = DotIconPresentation.paddedSize(for: size)
        return try bitmap(
            DotMarkDialPresentation(dial: dial, size: size),
            size: CGSize(width: padded, height: padded),
            opaque: false
        )
    }

    /// One plate masked to the system corner, at exactly `size` pixels.
    ///
    /// The strips and the small sizes use this: an icon in a Dock is masked,
    /// so a square swatch would be showing a different mark.
    static func masked(direction: DotMarkDirection, size: CGFloat) throws -> CGImage {
        try bitmap(
            DotPlate(direction: direction, size: size).clipShape(DotSquircle()),
            size: CGSize(width: size, height: size),
            opaque: false
        )
    }

    /// One masked plate with its shadow, as a bitmap.
    ///
    /// Rendered with alpha, not opaque: the padding around the plate carries
    /// the shadow and has to let the sheet's ground through. An opaque render
    /// would fill that padding with black and put a dark band around every
    /// icon on the sheet.
    static func presentation(direction: DotMarkDirection, size: CGFloat) throws -> CGImage {
        let padded = DotIconPresentation.paddedSize(for: size)
        return try bitmap(
            DotIconPresentation(direction: direction, size: size),
            size: CGSize(width: padded, height: padded),
            opaque: false
        )
    }

    /// One menu bar glyph, as a bitmap.
    ///
    /// Rendered with alpha: a template is a shape, and an opaque render would
    /// turn the sheet's template-mode images into solid squares.
    static func glyph(_ kind: DotMenuGlyph.Kind, size: CGFloat) throws -> CGImage {
        try bitmap(
            DotMenuGlyph(size: size, kind: kind),
            size: CGSize(width: size, height: size),
            opaque: false
        )
    }

    private static func bitmap<V: View>(_ view: V, size: CGSize, opaque: Bool = true) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.isOpaque = opaque
        guard let image = renderer.cgImage else { throw RenderError.couldNotRender }
        return image
    }

    private static func writeSheet<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { throw RenderError.couldNotRender }
        try writeOpaque(image, to: url)
    }

    // MARK: - Encoding

    /// Writes a PNG with no alpha channel at all.
    ///
    /// An icon master that carries an alpha channel is a transparency
    /// declaration whatever its values are, and macOS masks the icon itself.
    /// The context here has no alpha component, so the file says "opaque"
    /// rather than "transparent everywhere but painted", and `sips -g
    /// hasAlpha` reports `no`.
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
        // The plate covers every pixel, so the ground only matters if a
        // render ever leaves one bare. Black keeps that failure invisible
        // instead of turning it into a white fringe.
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
        let box = CGSize(width: size, height: size)
        let renderer = ImageRenderer(content: view.frame(width: size, height: size))
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { throw RenderError.couldNotRender }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.couldNotEncode
        }
        _ = box
        try data.write(to: url, options: .atomic)
    }

    /// The render could not be made.
    enum RenderError: Error {
        case couldNotRender
        case couldNotEncode
        case couldNotCreateContext
    }
}
