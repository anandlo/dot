import AppKit
import CryptoKit
import DotCore
import SwiftUI
import XCTest
@testable import Dot

/// The visualizer's lit ink on the card's two materials, and the pictures the
/// lift is judged and proved on.
///
/// The glass the card draws is a light surface: over the bright page it measures
/// 0.2386 of luminance behind the visualizer's canvas, and the amber the styles
/// are drawn with was measured on a card whose material was 0.1413. That is a
/// light ink on a light surface, which is the pair a contrast ratio cannot carry.
/// ``HUDTheme/visualizerGlassLift`` mixes each style's lit ink toward the card's
/// ink on the glass material, and there is one thing it must never touch: the
/// black card. Its renders are compared byte for byte between the tree that ships
/// the lift and the tree that does not, so the ten frames below are written here
/// rather than in the styles' own suites.
///
/// Three tests. The first holds the scope of the lift: a canvas on the black
/// material draws the same pixels whatever the token says, the same canvas on the
/// glass material does not, and the exempt filament is unchanged on both. The
/// other two write the pictures the proof is read on: ten black card frames, one
/// per style at the two judged moments, and the recording card over the reference
/// photograph's blue wave for each of the three styles the glass suite measures.
///
/// Every frame is drawn at twice the points off every display, so nothing appears
/// on screen and a frame is the same bytes on every run.
@MainActor
final class VisualizerLiftTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    // MARK: - The measurements

    /// Where the frames are written, when the run asks for them.
    static var evidence: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOT_VISUALIZER_EVIDENCE"] else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The pixels per point of every frame.
    static let scale = 2

    /// The visualizer's canvas, in points.
    static let canvas = CGSize(width: 102, height: 26)

    /// The recording card's size, in points.
    static let cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)

    /// The two moments a frame is written at: the first phrase and the loudest one.
    static let moments: [Double] = [1.50, 6.96]

    /// The three styles the glass suite holds to a criterion.
    static let measured: [HUDVisualizer] = [.stretch, .filament, .haloEdge]

    // MARK: - The scope of the lift

    /// The lift reaches the glass material and nothing else.
    ///
    /// The black card's ink is the ink every style was drawn for, so a canvas on
    /// the black material is the same picture at a lift of zero and at a lift of
    /// one: the token cannot repaint the card's default material however it is
    /// re-measured. The same canvas on the glass material must move, or the token
    /// is a number nothing reads, and the filament must not move on either
    /// material, because its blackbody colour is the design.
    func testTheLiftIsGlassOnly() throws {
        let frame = VisualizerRedesignTests.previewSnapshot(at: Self.moments[1])
        for visualizer in [HUDVisualizer.stretch, .haloEdge] {
            let black = try hash(canvas(frame, visualizer, material: .black, lift: 0))
            let blackLifted = try hash(canvas(frame, visualizer, material: .black, lift: 1))
            XCTAssertEqual(
                black,
                blackLifted,
                "\(visualizer) drew a different black canvas at a lift of one"
            )
            let glass = try hash(canvas(frame, visualizer, material: .glass, lift: 0))
            let glassLifted = try hash(canvas(frame, visualizer, material: .glass, lift: 1))
            XCTAssertNotEqual(
                glass,
                glassLifted,
                "\(visualizer) drew the same glass canvas at a lift of zero and one"
            )
            print("LIFT \(visualizer): black \(black), glass \(glass) at 0, \(glassLifted) at 1")
        }
        let filament = try hash(canvas(frame, .filament, material: .glass, lift: 0))
        let filamentLifted = try hash(canvas(frame, .filament, material: .glass, lift: 1))
        XCTAssertEqual(filament, filamentLifted, "the lift reached the filament's blackbody colour")
        print("LIFT filament: \(filament) on the glass material at every lift")
    }

    // MARK: - The black card

    /// The ten black card frames the byte-identical proof is read on.
    ///
    /// Every style at the two judged moments, drawn through the real recording
    /// card on the black material at twice the points. The SHA-256 of each file is
    /// printed beside it, so the picture this tree draws is compared with the
    /// picture the tree before the lift draws as bytes rather than by eye.
    func testBlackCardFrames() throws {
        let directory = try evidenceDirectory()
        for visualizer in HUDVisualizer.allCases {
            for moment in Self.moments {
                let frame = VisualizerRedesignTests.previewSnapshot(at: moment)
                let name = String(format: "black-%@-t%.2f.png", slug(visualizer), moment)
                let bitmap = try rasterise(
                    card(frame, visualizer, time: moment, material: .black),
                    size: Self.cardSize
                )
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                print(String(
                    format: "BLACKFRAME %@ %dx%d px sha256 %@",
                    name,
                    bitmap.pixelsWide,
                    bitmap.pixelsHigh,
                    Self.hash(data)
                ))
            }
        }
    }

    // MARK: - The card on the wave

    /// The recording card over the reference photograph's blue wave, one frame per
    /// style, at the loudest moment of the script.
    ///
    /// The backdrop is the one `GlassSweepTests` calls B1: a 560 by 460 crop of the
    /// reference photograph's blue wave, filled into the canvas the card sits in.
    /// The frame is a window-server capture rather than a `cacheDisplay` render,
    /// because the material is the server's and only a capture contains it. The
    /// voice is the script's loudest moment, the same one the styles' own glass
    /// suites measure.
    func testTheCardOverTheWave() throws {
        let directory = try evidenceDirectory()
        let reference = try referenceImage()
        let room = CGSize(
            width: Self.cardSize.width + 2 * Self.margin,
            height: Self.cardSize.height + 2 * Self.margin
        )
        for visualizer in Self.measured {
            let frame = VisualizerRedesignTests.previewSnapshot(at: Self.moments[1])
            let crop = try XCTUnwrap(reference.cropping(to: Self.waveCrop))
            let view = ZStack {
                Group {
                    Image(decorative: crop, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
                .frame(width: room.width, height: room.height)
                .clipped()
                card(frame, visualizer, time: Self.moments[1], material: .glass)
            }
            .frame(width: room.width, height: room.height)
            let window = WindowCapture.show(view, size: room)
            defer { WindowCapture.hide(window) }
            let picture = try XCTUnwrap(
                WindowCapture.capture(window),
                "the window server returned no picture of the window"
            )
            if picture.isBlank {
                throw XCTSkip(
                    "the window server returned a blank picture, which is what a process without "
                        + "the screen recording right is handed"
                )
            }
            let name = String(format: "wave-%@-t%.2f.png", slug(visualizer), Self.moments[1])
            let url = directory.appendingPathComponent(name)
            XCTAssertTrue(WindowCapture.write(picture, to: url), "\(name) was not written")
            let bytes = (try? Data(contentsOf: url)) ?? Data()
            print(String(
                format: "WAVE %@ %dx%d px at %.2fx sha256 %@",
                name,
                picture.width,
                picture.height,
                Double(picture.width) / Double(room.width),
                Self.hash(bytes)
            ))
        }
    }

    // MARK: - The views

    /// One visualizer canvas on one material, at one lift.
    private func canvas(
        _ snapshot: VisualizerRedesignTests.Snapshot,
        _ visualizer: HUDVisualizer,
        material: HUDMaterial,
        lift: Double
    ) -> some View {
        HUDWaveform(
            visualizer: visualizer,
            halfHeights: [],
            history: snapshot.history,
            spectrumHistory: snapshot.spectrum,
            phase: snapshot.phase,
            time: Self.moments[1],
            level: snapshot.level,
            pulse: 0.25,
            ceiling: snapshot.ceiling,
            reveal: 1,
            material: material,
            glassLift: lift
        )
        .frame(width: Self.canvas.width, height: Self.canvas.height)
    }

    /// The real recording card at the size it ships, on one material.
    private func card(
        _ snapshot: VisualizerRedesignTests.Snapshot,
        _ visualizer: HUDVisualizer,
        time: Double,
        material: HUDMaterial
    ) -> some View {
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.material = material
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = Self.cardSize
        model.visualizer = visualizer
        model.history = snapshot.history
        model.spectrumHistory = snapshot.spectrum
        model.ceiling = snapshot.ceiling
        model.level = snapshot.level
        model.phase = snapshot.phase
        model.time = time
        model.pulse = 0.25
        model.reveal = 1
        return HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions
        )
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
    }

    // MARK: - The renders

    /// Rasterises a view at twice the points, off every display.
    private func rasterise(_ content: some View, size: CGSize) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: content
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .environment(\.displayScale, CGFloat(Self.scale))
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * Self.scale,
            pixelsHigh: Int(size.height) * Self.scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the render could not be allocated")
        bitmap.size = size
        if let data = bitmap.bitmapData {
            memset(data, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        window.contentView = nil
        window.orderOut(nil)
        return bitmap
    }

    /// The SHA-256 of one view's PNG, so two renders can be compared as files.
    private func hash(_ content: some View) throws -> String {
        let bitmap = try rasterise(content, size: Self.canvas)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return Self.hash(data)
    }

    /// The SHA-256 of some bytes.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The backdrop

    /// The margin the backdrop keeps around the card, in points.
    static let margin: CGFloat = 60

    /// The crop of the reference photograph's blue wave that
    /// `GlassSweepTests` draws its first backdrop from.
    static let waveCrop = CGRect(x: 0, y: 520, width: 560, height: 460)

    /// The reference photograph.
    static let referenceURL = URL(fileURLWithPath: "/tmp/dot-ref-glass.png")

    /// The reference photograph, read as pixels.
    private func referenceImage() throws -> CGImage {
        guard let image = NSImage(contentsOf: Self.referenceURL) else {
            throw XCTSkip("the reference photograph is not at \(Self.referenceURL.path)")
        }
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else {
            throw XCTSkip("the reference photograph could not be read as pixels")
        }
        return cgImage
    }

    /// The directory the frames are written to, or a skip.
    private func evidenceDirectory() throws -> URL {
        guard let directory = Self.evidence else {
            throw XCTSkip("DOT_VISUALIZER_EVIDENCE is not set")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The file-name stem of a visualizer.
    private func slug(_ visualizer: HUDVisualizer) -> String {
        visualizer.title.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
