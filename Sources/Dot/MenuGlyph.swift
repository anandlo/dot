import AppKit

/// The mark in the menu bar: the app icon, drawn small.
///
/// A rounded plate in the icon's graphite with the icon's porcelain disc cutting
/// its top right corner.
///
/// The drawing is deliberately not a template image. The identity of the mark is
/// the contrast between the plate and the disc, and a single-ink drawing of it
/// loses the disc: it reads as a camera, or as a keyhole, or as a plain
/// rectangle. Two tones — graphite on a light bar, porcelain on a dark one —
/// keep the shape legible in either appearance.
///
/// While recording, the plate widens by a fraction of a point across a
/// pre-rendered loop of ``frameCount`` frames per tone, so a frame is a lookup
/// rather than a drawing pass.
@MainActor
enum MenuGlyph {
    /// The glyph's box, in points: the height the menu bar gives an item.
    static let side: CGFloat = 22
    /// The plate's side inside that box, in points.
    ///
    /// The system's own items ink between twelve and sixteen points of the bar,
    /// so fifteen sits inside that range. A plate that filled the whole box is
    /// visibly larger than everything beside it.
    private static let plateInk: CGFloat = 15
    /// How far the plate widens at the top of a breath, in points.
    private static let breathInk: CGFloat = 0.45
    /// The disc's place on the plate: the icon's own centre, past the corner.
    private static var dotCentre: CGPoint { DotSignalMark.discCentre }
    /// The disc's diameter as a fraction of the plate: the icon's own cut.
    private static var dotScale: CGFloat { DotSignalMark.discScale }
    /// The plate's corner radius as a fraction of its side.
    private static var cornerScale: CGFloat { DotSignalMark.cornerScale }

    /// The icon's plate, and its disc.
    private static let graphite = NSColor(srgbRed: 0.098, green: 0.090, blue: 0.078, alpha: 1)
    private static let porcelain = NSColor(srgbRed: 0.953, green: 0.929, blue: 0.894, alpha: 1)

    /// The frames of one breath, per amplitude and per menu bar tone.
    private static var cache: [FrameKey: [NSImage]] = [:]

    /// What one frame set is drawn for.
    private struct FrameKey: Hashable {
        /// The breath's amplitude, rounded so lookups hit.
        let amplitude: CGFloat
        /// Whether the menu bar is dark, which decides the two tones.
        let dark: Bool
    }
    /// How many frames the breath is cut into.
    private static let frameCount = 24

    /// The frame at a point in the loop.
    ///
    /// - Parameters:
    ///   - phase: any real number; only the fractional part is used.
    ///   - amplitude: how far the plate breathes, from `0` (still) to `1`.
    /// - Returns: a template image the status item can show.
    static func image(phase: Double, amplitude: CGFloat = 1, dark: Bool = false) -> NSImage {
        let key = FrameKey(amplitude: (amplitude * 100).rounded() / 100, dark: dark)
        let frames = cache[key] ?? render(amplitude: key.amplitude, dark: dark)
        cache[key] = frames
        let wrapped = phase - phase.rounded(.down)
        return frames[Int(wrapped * Double(frameCount)) % frameCount]
    }

    /// The whole breath at one amplitude, rendered once.
    static func render(amplitude: CGFloat, dark: Bool = false) -> [NSImage] {
        (0..<frameCount).map { index in
            draw(phase: Double(index) / Double(frameCount), amplitude: amplitude, dark: dark)
        }
    }

    /// One frame by index.
    ///
    /// - Parameters:
    ///   - index: the frame, wrapped into the breath.
    ///   - amplitude: how far the cut-out moves.
    /// - Returns: a template image the status item can show.
    static func frame(index: Int, amplitude: CGFloat = 1, dark: Bool = false) -> NSImage {
        let key = FrameKey(amplitude: (amplitude * 100).rounded() / 100, dark: dark)
        let frames = cache[key] ?? render(amplitude: key.amplitude, dark: dark)
        cache[key] = frames
        return frames[((index % frameCount) + frameCount) % frameCount]
    }

    // MARK: - Drawing

    /// Draws one frame into a bitmap the status bar can ink.
    private static func draw(phase: Double, amplitude: CGFloat, dark: Bool) -> NSImage {
        let scale: CGFloat = 2
        let pixels = Int(side * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: side, height: side)) }

        // The point size is set **before** the context is made. A context takes
        // the scale it finds when it is created: made first, with a rep still
        // measuring one point per pixel, it maps a point to a pixel and every
        // shape is drawn at half the size the image then reports. That is why a
        // twenty two point glyph sat in the menu bar at ten, however large the
        // numbers in this file became.
        rep.size = NSSize(width: side, height: side)
        guard let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return NSImage(size: NSSize(width: side, height: side)) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // One breath: the plate widens and settles by a fraction of a point.
        let breath = cos(phase * 2 * .pi)
        let ink = plateInk + breathInk * breath * amplitude
        let inset = (side - ink) / 2
        let plate = NSRect(x: inset, y: inset, width: ink, height: ink)
        let platePath = NSBezierPath(
            roundedRect: plate,
            xRadius: plate.width * cornerScale,
            yRadius: plate.width * cornerScale
        )
        let plateColor = dark ? porcelain : graphite
        let dotColor = dark ? graphite : porcelain

        plateColor.setFill()
        platePath.fill()

        // The disc is filled inside the plate, so the part of it that runs past
        // the corner is cut away by the plate's own shape - the icon's cut.
        NSGraphicsContext.saveGraphicsState()
        platePath.addClip()
        let radius = plate.width * dotScale / 2
        // The icon's centre is measured from the top left; this context draws
        // upward, so the vertical term is mirrored.
        let centre = CGPoint(
            x: plate.minX + plate.width * dotCentre.x,
            y: plate.minY + plate.height * (1 - dotCentre.y)
        )
        dotColor.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}
