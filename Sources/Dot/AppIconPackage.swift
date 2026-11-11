import CoreGraphics
import Foundation

/// The Icon Composer document, written from the same drawings as the icns.
///
/// macOS 26 does not read a baked corner: it takes an `AppIcon.icon` document
/// and supplies the shape, the lighting, the glass and the drop shadow itself.
/// The document here therefore holds unmasked, full-bleed layers, and the plate
/// is the document's background fill rather than a cut-out.
///
/// Three layers, in the order Icon Composer reads them (front to back):
///
/// 1. `disc`: the cream disc at 1024, on transparency, carrying the system's
///    specular highlight. Its bleed past the corner is cut by the system's own
///    mask, which is the point of supplying it unmasked.
/// 2. `seat`: the disc's cast shadow and the occlusion at its rim, without the
///    glass. This layer exists so the disc above it has its own silhouette: a
///    disc and its shadow in one layer is a single outline, and a specular
///    drawn on that outline rims the shadow instead of the disc, which reads as
///    a hard circle scribed around the mark.
/// 3. `plate`: the plate's material at 1024, full bleed. The fill underneath is
///    the plate's own gradient, so the background carries the plate's colour
///    even where the layer is not drawn, and the layer adds the grain, the
///    light and the floor's fall-off that a two-stop gradient cannot.
///
/// The shadow is off on every group. The mark's own contact darkening is the
/// `seat` layer, and the icon's drop shadow belongs to the system: a group
/// shadow here would be a second seat under a disc that already has one.
///
/// Appearance: the document declares one. The mark's plate is already the
/// darkest value it has, so a dark variant would either repeat this drawing or
/// lose the tile's own edge against a dark desktop, and macOS derives its dark
/// and tinted treatments from these layers itself: the tinted renditions tint
/// the plate and the disc, which is visible in the Icon Composer previews and
/// is the behaviour Apple's own simple icons get.
enum AppIconPackage {
    /// The document's directory name, which is the icon's name in the bundle.
    static let directoryName = "AppIcon.icon"

    /// The plate's own colours, as the sRGB hex the drawing uses.
    struct Plate: Sendable {
        /// The plate's colour at the top of the body.
        let top: UInt32
        /// The plate's colour at its foot.
        let foot: UInt32

        /// Porcelain's plate, the one the app ships.
        static let porcelain = Plate(top: 0x2B2822, foot: 0x191714)
    }

    /// Writes `AppIcon.icon` into `directory`, with its layer images.
    ///
    /// - Parameters:
    ///   - directory: The `.icon` package to write. An existing one is replaced,
    ///     so a removed layer cannot survive in `Assets/`.
    ///   - plate: The background at 1024, full bleed and opaque. For the shipped
    ///     mark this is the plate's material alone; for a studied direction it
    ///     is the whole flat drawing.
    ///   - seat: The disc's seat at 1024 on transparency, or `nil` when the
    ///     background already carries the mark.
    ///   - disc: The disc at 1024 on transparency, or `nil` for the same reason.
    ///   - colours: The plate's gradient.
    static func write(
        to directory: URL,
        plate: CGImage,
        seat: CGImage?,
        disc: CGImage?,
        colours: Plate = .porcelain
    ) throws {
        let fileManager = FileManager.default
        let assets = directory.appendingPathComponent("Assets", isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)

        try IconRender.writeOpaque(plate, to: assets.appendingPathComponent("plate.png"))
        if let seat {
            try IconRender.writeAlpha(seat, to: assets.appendingPathComponent("seat.png"))
        }
        if let disc {
            try IconRender.writeAlpha(disc, to: assets.appendingPathComponent("disc.png"))
        }
        try Data(json(colours, layered: disc != nil && seat != nil).utf8).write(
            to: directory.appendingPathComponent("icon.json"),
            options: .atomic
        )
    }
}

extension AppIconPackage {
    /// The document itself, as the text Icon Composer reads.
    ///
    /// Written as text rather than through a JSON encoder because the document
    /// is small and a reader has to be able to check it against what Icon
    /// Composer writes, key by key.
    static func json(_ colours: Plate, layered: Bool = true) -> String {
        let groups = (layered ? [discGroup, plateGroup] : [plateGroup])
            .joined(separator: ",\n")
        return """
        {
          "fill": \(gradient(colours.top, colours.foot)),
          "groups": [
        \(groups)
          ],
          "supported-platforms": { "squares": ["macOS"] }
        }

        """
    }

    /// The foreground: the disc on the system's glass, seated on its own shadow.
    private static let discGroup = """
            {
              "layers": [
                { "name": "disc", "image-name": "disc.png", "glass": true },
                { "name": "seat", "image-name": "seat.png", "glass": false }
              ],
              "lighting": "individual",
              "name": "mark",
              "shadow": { "kind": "none", "opacity": 0 },
              "specular": true,
              "translucency": { "enabled": false, "value": 0 }
            }
    """

    /// The background: the plate's material.
    private static let plateGroup = """
            {
              "layers": [
                { "name": "plate", "image-name": "plate.png" }
              ],
              "name": "plate",
              "shadow": { "kind": "none", "opacity": 0 },
              "translucency": { "enabled": false, "value": 0 }
            }
    """

    /// One two-stop vertical gradient, as a fill.
    static func gradient(_ top: UInt32, _ foot: UInt32) -> String {
        """
        { "linear-gradient": ["\(colour(top))", "\(colour(foot))"],
          "orientation": { "start": { "x": 0.5, "y": 0 }, "stop": { "x": 0.5, "y": 1 } } }
        """
    }

    /// One sRGB hex as the colour string Icon Composer reads.
    static func colour(_ hex: UInt32) -> String {
        String(
            format: "extended-srgb:%.5f,%.5f,%.5f,1.00000",
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }
}
