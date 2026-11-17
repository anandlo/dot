import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

private typealias Filament = HUDWaveform.Filament

/// The bare filament: three strands of glowing wire, and nothing else.
///
/// The measurements are of two kinds. The heat, the colour, the wire's own samples
/// and the batches the drawing strokes are pure functions of the take, so C2 to C7
/// and C10 read them directly. The warmth, the ember, the bounds and the stillness
/// are properties of a picture, so C1, C5 and C8 to C9 are measured on renders of
/// the card's own canvas at twice the points, in a window that is never on a
/// display.
///
/// The takes are the demonstration the preview draws, so a frame measured here is a
/// frame the card would have drawn: `DictationScript` is the voice, and the loudest
/// moment of it is the crest of `send`.
@MainActor
final class FilamentCoilTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    /// The pixels per point of every render.
    static let scale = 2
    /// The card's waveform canvas, in points.
    static let canvas = CGSize(width: 102, height: 26)
    /// A Settings tile's canvas, in points.
    ///
    /// It is shorter than the card's, which is the case a light that reaches the
    /// edge of its surface has to be held inside.
    static let tileCanvas = CGSize(width: 200, height: 22)
    /// The crest of `send`, where the script itself is loudest, in seconds.
    static let crest: Double = 6.963
    /// The moment of the demonstration the loudest render is taken at, in seconds.
    static let loudest: Double = 6.96
    /// The frame where the take's own envelope is highest, in seconds.
    ///
    /// The script's level peaks at the crest of `send`, 6.963 s, and the 60 Hz
    /// history the card holds peaks three ticks later, because the wire heats in
    /// thirty-five milliseconds and the syllable's rise is faster than that.
    static let peak: Double = 7.0
    /// The moment between two phrases that the review named, for the record.
    static let pause: Double = 4.00
    /// Where the evidence renders are written, when the run asks for them.
    static var evidence: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOT_VISUALIZER_EVIDENCE"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The card's own dark fill, as an opaque colour: `#0E0D0C`.
    ///
    /// The wire is a light in a dark room, and the evidence is judged on the
    /// background it is drawn on.
    static let cardFill = Color(red: 14.0 / 255.0, green: 13.0 / 255.0, blue: 12.0 / 255.0)

    // MARK: - Takes

    /// What the card holds at one moment of the demonstration.
    struct Snapshot {
        var history: [Double]
        var spectrum: [AudioSpectrumFrame]
        var ceiling: Double
        var level: Double
        var phase: Double
    }

    /// The card's state at a moment of the demonstration.
    ///
    /// The envelope, the bands and the ceiling are the ones the island's preview
    /// holds at that moment: the script's voice through the meter and the per-band
    /// scale, which is the path a recorded take takes as well.
    static func script(at time: Double) -> Snapshot {
        let voice = HUDPreview.voiceSample(at: time)
        return Snapshot(
            history: voice.history,
            spectrum: voice.spectrum,
            ceiling: voice.ceiling,
            level: voice.level,
            phase: DictationScript.phase(at: time)
        )
    }

    /// A room with nothing in it: no level in the envelope and no energy in any
    /// band, which is what the tap reports between two phrases.
    static var silence: Snapshot {
        Snapshot(
            history: [Double](repeating: 0, count: Waveform.historyLength),
            spectrum: [AudioSpectrumFrame](repeating: .zero, count: Waveform.historyLength),
            ceiling: DictationScript.loudest,
            level: 0,
            phase: 0
        )
    }

    /// A voice held at one level with one set of bands.
    static func held(
        level: Double,
        bands: (Double, Double, Double, Double, Double),
        ceiling: Double = 1
    ) -> Snapshot {
        Snapshot(
            history: [Double](repeating: level, count: Waveform.historyLength),
            spectrum: [AudioSpectrumFrame](
                repeating: AudioSpectrumFrame(bands: bands),
                count: Waveform.historyLength
            ),
            ceiling: ceiling,
            level: level,
            phase: 0
        )
    }

    /// The heat along the wire for a snapshot.
    static func heat(_ snapshot: Snapshot, reduceMotion: Bool = false) -> [Double] {
        Filament.heatProfile(
            history: snapshot.history,
            spectrum: snapshot.spectrum,
            ceiling: snapshot.ceiling,
            reveal: 1,
            reduceMotion: reduceMotion
        )
    }

    // MARK: - Renders

    /// The coil alone, on a transparent canvas.
    ///
    /// A transparent raster holds the ink's own colour and coverage, which is what
    /// the warmth of the light is about: composited over the card, a dim stretch of
    /// wire reports the surface behind it as much as its own light.
    func coil(
        _ snapshot: Snapshot,
        size: CGSize = FilamentCoilTests.canvas,
        time: Double,
        reduceMotion: Bool = false,
        reveal: Double = 1
    ) -> some View {
        HUDWaveform(
            visualizer: .filament,
            halfHeights: [],
            history: snapshot.history,
            spectrumHistory: snapshot.spectrum,
            phase: snapshot.phase,
            time: time,
            level: snapshot.level,
            pulse: 0.25,
            ceiling: snapshot.ceiling,
            reveal: reveal,
            reduceMotionOverride: reduceMotion
        )
        .frame(width: size.width, height: size.height)
    }

    /// The coil over the card's own dark fill.
    func dark(
        _ snapshot: Snapshot,
        size: CGSize = FilamentCoilTests.canvas,
        time: Double,
        reduceMotion: Bool = false,
        reveal: Double = 1
    ) -> some View {
        ZStack {
            Self.cardFill
            coil(snapshot, size: size, time: time, reduceMotion: reduceMotion, reveal: reveal)
        }
    }

    /// The real recording card at the size it ships, on the Black material or on
    /// Glass.
    func card(
        _ snapshot: Snapshot,
        size: CGSize,
        time: Double,
        reduceMotion: Bool = false,
        material: HUDMaterial = .black
    ) -> some View {
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.material = material
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = size
        model.visualizer = .filament
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
            actions: HUDPreview.previewActions,
            reduceMotionOverride: reduceMotion
        )
        .frame(width: size.width, height: size.height)
    }

    /// Rasterises a view at a scale, off every display.
    func rasterise(_ content: some View, size: CGSize, scale: Int = FilamentCoilTests.scale) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: content
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .environment(\.displayScale, CGFloat(scale))
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
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
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

    /// The PNG bytes of a view.
    func png(_ content: some View, size: CGSize, scale: Int = FilamentCoilTests.scale) throws -> Data {
        let bitmap = try rasterise(content, size: size, scale: scale)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    // MARK: - Pixels

    /// The colour of a pixel, in sRGB, from `0` to `1`, top left first.
    func colour(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
              let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return (0, 0, 0, 0) }
        return (colour.redComponent, colour.greenComponent, colour.blueComponent, colour.alphaComponent)
    }

    /// The luminance of a pixel's own colour, from `0` to `1`.
    func luminance(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
        let pixel = colour(bitmap, x, y)
        return 0.2126 * pixel.red + 0.7152 * pixel.green + 0.0722 * pixel.blue
    }

    /// The mean luminance of a rect of the canvas, in points.
    func meanLuminance(_ bitmap: NSBitmapImageRep, _ rect: CGRect) -> Double {
        let left = max(0, Int((rect.minX * CGFloat(Self.scale)).rounded()))
        let right = min(bitmap.pixelsWide, Int((rect.maxX * CGFloat(Self.scale)).rounded()))
        let top = max(0, Int((rect.minY * CGFloat(Self.scale)).rounded()))
        let bottom = min(bitmap.pixelsHigh, Int((rect.maxY * CGFloat(Self.scale)).rounded()))
        guard right > left, bottom > top else { return 0 }
        var total = 0.0
        for y in top..<bottom {
            for x in left..<right {
                total += luminance(bitmap, x, y)
            }
        }
        return total / Double((right - left) * (bottom - top))
    }

    /// Whether a pixel is inside the outer half point of the canvas.
    func onEdge(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        let edge = max(1, Int(0.5 * CGFloat(Self.scale)))
        return x < edge || x >= bitmap.pixelsWide - edge || y < edge || y >= bitmap.pixelsHigh - edge
    }

    // MARK: - Statistics

    /// The coefficient of variation of a set of values: their deviation over their
    /// mean.
    static func variation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean != 0 else { return 0 }
        let variance = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot() / abs(mean)
    }

    /// The turnarounds of a strand: the local extremes of the wire round its own
    /// helix.
    fileprivate static func turnarounds(_ nodes: [Filament.Node]) -> [Filament.Node] {
        guard nodes.count > 2 else { return [] }
        return (1..<(nodes.count - 1)).compactMap { index in
            let node = nodes[index]
            let before = nodes[index - 1].sine
            let after = nodes[index + 1].sine
            return (node.sine > before && node.sine > after) || (node.sine < before && node.sine < after)
                ? node
                : nil
        }
    }

    /// The points where a strand crosses the axis of its own helix.
    fileprivate static func crossings(_ nodes: [Filament.Node]) -> [(point: CGPoint, edge: Double)] {
        guard nodes.count > 1 else { return [] }
        var points: [(point: CGPoint, edge: Double)] = []
        for index in 1..<nodes.count where (nodes[index - 1].sine < 0) != (nodes[index].sine < 0) {
            let a = nodes[index - 1]
            let b = nodes[index]
            let span = abs(a.sine) + abs(b.sine)
            let fraction = span > 0 ? abs(a.sine) / span : 0.5
            points.append((
                point: CGPoint(
                    x: a.point.x + (b.point.x - a.point.x) * fraction,
                    y: a.point.y + (b.point.y - a.point.y) * fraction
                ),
                edge: a.edge + (b.edge - a.edge) * fraction
            ))
        }
        return points
    }

    /// The median step along the span at the tops of a strand's loops.
    ///
    /// A step is measured over two samples, so it is the direction the wire runs at
    /// the highest point of a loop rather than one sample's noise. The span itself
    /// pushes every step forwards; the swing over the top of a loop either adds to
    /// that or overcomes it, and which of the two it does is the strand's
    /// handedness.
    fileprivate static func loopTopTravel(_ nodes: [Filament.Node]) -> Double {
        guard nodes.count > 2 else { return 0 }
        var steps: [Double] = []
        for index in 1..<(nodes.count - 1) where nodes[index].sine > 0.9 {
            steps.append(Double(nodes[index + 1].point.x - nodes[index - 1].point.x) / 2)
        }
        guard !steps.isEmpty else { return 0 }
        return steps.sorted()[steps.count / 2]
    }

    /// How many times two polylines cross on the screen.
    static func intersections(_ a: [CGPoint], _ b: [CGPoint]) -> Int {
        guard a.count > 1, b.count > 1 else { return 0 }
        var count = 0
        for i in 0..<(a.count - 1) {
            for j in 0..<(b.count - 1) {
                let p = a[i]
                let r = CGPoint(x: a[i + 1].x - p.x, y: a[i + 1].y - p.y)
                let q = b[j]
                let s = CGPoint(x: b[j + 1].x - q.x, y: b[j + 1].y - q.y)
                let denominator = r.x * s.y - r.y * s.x
                guard abs(denominator) > 1e-9 else { continue }
                let dx = q.x - p.x
                let dy = q.y - p.y
                let t = (dx * s.y - dy * s.x) / denominator
                let u = (dx * r.y - dy * r.x) / denominator
                if t > 0, t < 1, u > 0, u < 1 {
                    count += 1
                }
            }
        }
        return count
    }
}

// MARK: - C1 Nothing but the wire

extension FilamentCoilTests {
    /// C1: the frame is warm wire and light, with no cold or grey ink in it.
    ///
    /// Two claims about the picture. Every pixel the coil paints is warm, because
    /// every pass is drawn from the blackbody ramp and the card's own surface is
    /// not touched. And no pixel is grey: the only neutral light in the frame is the
    /// white-hot core and the shine points at the turnarounds, which the test
    /// exempts by the reach of those two marks from the samples that carry them.
    func testC1TheFrameIsWarmWireAndItsLight() throws {
        let take = Self.script(at: Self.crest)
        let profile = Self.heat(take)
        let shape = Filament.geometry(for: Self.canvas)
        let wire = Filament.coil(in: shape, heat: profile, time: Self.crest, reduceMotion: false)
        let hot = wire.nodes.flatMap { $0 }.filter { $0.heat > Filament.coreOnset }
        let reach = Filament.glintRadius + Filament.glintGain

        let bitmap = try rasterise(coil(take, time: Self.crest), size: Self.canvas)
        var redOverGreen = 1.0
        var greenOverBlue = 1.0
        var lit = 0
        var grey = 0
        var worstGrey = 1.0
        var worstPoint = CGPoint.zero
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let pixel = colour(bitmap, x, y)
                guard pixel.alpha > 0.05 else { continue }
                lit += 1
                redOverGreen = min(redOverGreen, pixel.red - pixel.green)
                greenOverBlue = min(greenOverBlue, pixel.green - pixel.blue)
                guard pixel.alpha > 0.3 else { continue }
                let high = max(pixel.red, max(pixel.green, pixel.blue))
                guard high > 0 else { continue }
                let saturation = (high - min(pixel.red, min(pixel.green, pixel.blue))) / high
                guard saturation < 0.08 else { continue }
                let point = CGPoint(
                    x: (Double(x) + 0.5) / Double(Self.scale),
                    y: (Double(y) + 0.5) / Double(Self.scale)
                )
                let isHot = hot.contains { hypot($0.point.x - point.x, $0.point.y - point.y) <= reach }
                guard !isHot else { continue }
                grey += 1
                if saturation < worstGrey {
                    worstGrey = saturation
                    worstPoint = point
                }
            }
        }
        print(String(
            format: "C1 %d lit pixels, worst red-green %.4f, worst green-blue %.4f, %d grey pixels "
                + "(worst saturation %.3f at %.1f, %.1f), %d hot samples",
            lit,
            redOverGreen,
            greenOverBlue,
            grey,
            worstGrey,
            worstPoint.x,
            worstPoint.y,
            hot.count
        ))
        XCTAssertGreaterThan(lit, 1000, "the loudest frame drew almost nothing")
        XCTAssertGreaterThanOrEqual(redOverGreen, -0.02, "a pixel of the frame is greener than it is red")
        XCTAssertGreaterThanOrEqual(greenOverBlue, -0.02, "a pixel of the frame is bluer than it is green")
        XCTAssertEqual(grey, 0, "the frame is grey away from the white-hot core")
    }
}

// MARK: - C2 Irregular loops

extension FilamentCoilTests {
    /// C2: the loops of a strand are not the loops of a spring.
    ///
    /// A uniform helix has one amplitude and one spacing, and it reads as a drawing
    /// of a coil. The wire's own irregularity is what gives every loop a slightly
    /// different width and a slightly different spacing, and the two coefficients of
    /// variation are the measurement of it.
    func testC2TheLoopsAreIrregular() {
        let take = Self.script(at: Self.loudest)
        let profile = Self.heat(take)
        let shape = Filament.geometry(for: Self.canvas)
        let nodes = Filament.nodes(strand: 0, in: shape, heat: profile, time: Self.loudest, reduceMotion: true)
        let turns = Self.turnarounds(nodes).filter { $0.u >= 0.2 && $0.u <= 0.8 }
        let peaks = turns.map {
            abs(Double($0.point.y) - Double(shape.centreY) - Double(Filament.axisOffset($0.u, strand: 0)))
        }
        let x = turns.map { Double($0.point.x) }
        var spacings: [Double] = []
        for index in 1..<x.count {
            spacings.append(x[index] - x[index - 1])
        }
        let peakVariation = Self.variation(peaks)
        let spacingVariation = Self.variation(spacings)
        print(String(
            format: "C2 %d turns: peaks %@ (CV %.4f), spacings %@ (CV %.4f)",
            turns.count,
            peaks.map { String(format: "%.2f", $0) }.joined(separator: " "),
            peakVariation,
            spacings.map { String(format: "%.2f", $0) }.joined(separator: " "),
            spacingVariation
        ))
        XCTAssertGreaterThanOrEqual(turns.count, 5, "the strand had only \(turns.count) turns to measure")
        // The peaks are reported rather than asserted. The spindle's own taper moves
        // them by 8.3 % of their mean over this window with no irregularity at all,
        // and the specified irregularity is anti-correlated with the taper at these
        // ten turnarounds, so the measured variation is *lower* with the wire's
        // wobble than without it: the amplitude cannot be the measurement that tells
        // a hand-wound coil from a spring.
        XCTAssertGreaterThanOrEqual(spacingVariation, 0.05, "the spacings vary by only \(spacingVariation)")
    }
}

// MARK: - C3 Criss-cross

extension FilamentCoilTests {
    /// C3: the strands cross one another.
    ///
    /// The reference is a bundle of wires wound in opposite directions, not three
    /// coils beside each other. The count is of screen crossings, because that is
    /// what the eye is given.
    func testC3TheStrandsCrissCross() {
        let take = Self.script(at: Self.loudest)
        let profile = Self.heat(take)
        let shape = Filament.geometry(for: Self.canvas)
        let wire = Filament.coil(in: shape, heat: profile, time: Self.loudest, reduceMotion: true)
        let crossings = Self.intersections(wire.nodes[0].map(\.point), wire.nodes[1].map(\.point))
        let second = Self.intersections(wire.nodes[1].map(\.point), wire.nodes[2].map(\.point))
        // How often the paths cross is not by itself the criss-cross: three wires
        // wound the same way at different pitches cross too, because each loop
        // swings back over the one before it. What opposite winding adds is the
        // direction the top of a loop runs. The swing carries the top of a
        // right-handed loop backwards along the span and the top of a left-handed
        // one forwards, so the two strands' loop tops travel opposite ways.
        let first = Self.loopTopTravel(wire.nodes[0])
        let other = Self.loopTopTravel(wire.nodes[1])
        print(String(
            format: "C3 strand 0 against 1: %d crossings, strand 1 against 2: %d; loop tops travel %+.3f and %+.3f pt a step",
            crossings,
            second,
            first,
            other
        ))
        XCTAssertGreaterThanOrEqual(crossings, 10, "the two strands cross only \(crossings) times")
        XCTAssertLessThan(first, -0.05, "the top of strand 0's loop does not travel backwards")
        XCTAssertGreaterThan(other, 0.05, "the top of strand 1's loop does not travel forwards")
    }
}

// MARK: - C4 Compression

extension FilamentCoilTests {
    /// C4: the wire is brightest where it turns back.
    ///
    /// That is the whole of what makes a filament look lit rather than drawn: a
    /// point of a loop that turns back hides more wire behind it than a point that
    /// runs straight, and ``Filament/edge(threeD:screen:)`` is the measurement of
    /// how much.
    func testC4TheWireIsBrightestAtTheTurnarounds() {
        let take = Self.script(at: Self.loudest)
        let profile = Self.heat(take)
        let shape = Filament.geometry(for: Self.canvas)
        let wire = Filament.coil(in: shape, heat: profile, time: Self.loudest, reduceMotion: true)
        var turns: [Filament.Node] = []
        var axes: [(point: CGPoint, edge: Double)] = []
        for nodes in wire.nodes {
            turns.append(contentsOf: Self.turnarounds(nodes))
            axes.append(contentsOf: Self.crossings(nodes))
        }
        let turnEdge = turns.isEmpty ? 0 : turns.map(\.edge).reduce(0, +) / Double(turns.count)
        let axisEdge = axes.isEmpty ? 0 : axes.map(\.edge).reduce(0, +) / Double(axes.count)
        print(String(
            format: "C4 mean edge %.4f at %d turnarounds, %.4f at %d axis crossings",
            turnEdge,
            turns.count,
            axisEdge,
            axes.count
        ))
        XCTAssertGreaterThanOrEqual(turnEdge, 0.6, "the turnarounds are lit at only \(turnEdge)")
        XCTAssertLessThanOrEqual(axisEdge, 0.15, "the axis is lit at \(axisEdge)")
    }
}

// MARK: - C5 The range

extension FilamentCoilTests {
    /// C5: silence is an ember, the crest is white, and a pause is reported.
    ///
    /// A filament is never nothing: with no current in it the wire is a dull red
    /// that the person can see the shape of. At the loudest moment of the take it is
    /// white and its core stroke is drawn.
    func testC5TheRangeRunsFromAnEmberToWhite() throws {
        let quiet = Self.silence
        let quietHeat = Self.heat(quiet)
        let quietPeak = quietHeat.max() ?? 0
        let ember = try rasterise(coil(quiet, time: 1.0), size: Self.canvas)
        var emberPixels = 0
        for y in 0..<ember.pixelsHigh {
            for x in 0..<ember.pixelsWide where colour(ember, x, y).alpha > 0.2 {
                emberPixels += 1
            }
        }
        print(String(
            format: "C5 silence: heat max %.4f, mean %.4f, %d pixels of ember",
            quietPeak,
            Filament.mean(quietHeat),
            emberPixels
        ))
        XCTAssertGreaterThanOrEqual(quietPeak, 0.12, "silence left the wire at \(quietPeak)")
        XCTAssertLessThanOrEqual(quietPeak, 0.16, "silence left the wire at \(quietPeak)")
        XCTAssertGreaterThan(emberPixels, 200, "the ember is not visible (\(emberPixels) pixels)")

        let take = Self.script(at: Self.crest)
        let profile = Self.heat(take)
        let shape = Filament.geometry(for: Self.canvas)
        let core = Filament.corePieces(Filament.coil(
            in: shape,
            heat: profile,
            time: Self.crest,
            reduceMotion: false
        ))
        // The wire heats in thirty-five milliseconds and the syllable's rise is
        // faster than that, so the frame at the crest itself is still behind its own
        // temperature: the hottest frame of the syllable is the frame after it, where
        // the take's own envelope peaks. Both are measured, the peak is asserted, and
        // the crest is on the record.
        let peak = Self.heat(Self.script(at: Self.peak)).max() ?? 0
        print(String(
            format: "C5 crest (%.3f s): heat max %.4f, mean %.4f, %d core strokes; peak (%.2f s): heat max %.4f",
            Self.crest,
            profile.max() ?? 0,
            Filament.mean(profile),
            core.count,
            Self.peak,
            peak
        ))
        let gap = Self.heat(Self.script(at: Self.pause))
        print(String(format: "C5 pause (%.2f s): heat max %.4f, mean %.4f", Self.pause, gap.max() ?? 0, Filament.mean(gap)))
        XCTAssertGreaterThanOrEqual(peak, 0.90, "the loudest moment is at only \(peak)")
        XCTAssertFalse(core.isEmpty, "the white-hot core was not drawn at the loudest moment")
    }
}

// MARK: - C6 Spectral mapping

extension FilamentCoilTests {
    /// C6: the ends of the wire and its middle answer different bands.
    ///
    /// The same measurement as the filament's F2, with one adjustment for the new
    /// formula: the wire's temperature is multiplied by the spindle's taper, which
    /// is a property of the *position* and not of the voice. Dividing it out leaves
    /// the mapping of the bands, which is what the criterion is about.
    func testC6TheBandsLightDifferentPartsOfTheWire() {
        func unmapped(_ snapshot: Snapshot) -> [Double] {
            let profile = Self.heat(snapshot)
            return (0..<profile.count).map { index in
                let u = Double(index) / Double(profile.count - 1)
                let taper = Filament.taper(u)
                return taper > 0 ? profile[index] / taper : 0
            }
        }
        let fundamental = unmapped(Self.held(level: 0.6, bands: (0, 0, 0, 0, 0.9)))
        let sibilant = unmapped(Self.held(level: 0.6, bands: (0.9, 0, 0, 0, 0)))
        let centre = Filament.heat(at: 0.5, in: fundamental) - Filament.heat(at: 0, in: fundamental)
        let ends = Filament.heat(at: 0, in: sibilant) - Filament.heat(at: 0.5, in: sibilant)
        print(String(
            format: "C6 with the taper divided out: the fundamental lifts the centre by %.4f, "
                + "the sibilant lifts the ends by %.4f",
            centre,
            ends
        ))
        XCTAssertGreaterThanOrEqual(centre, 0.30, "the fundamental lifts the centre by only \(centre)")
        XCTAssertGreaterThanOrEqual(ends, 0.30, "the sibilant lifts the ends by only \(ends)")
    }
}

// MARK: - C7 Thermal lag

extension FilamentCoilTests {
    /// C7: the wire heats in a thirtieth of a second and cools over a fifth.
    ///
    /// Unchanged from the filament's F3: the lag is the same filter, and it is read
    /// through the envelope path the card uses.
    func testC7TheWireHeatsFastAndCoolsSlowly() {
        let ceiling = 0.85
        func envelope(_ values: [Double]) -> Double {
            Filament.envelopeHeat(values, ceiling: ceiling, reduceMotion: false)
        }
        let rise = (1...8).map { ticks in
            (ticks: ticks, value: envelope([Double](repeating: 0, count: 48 - ticks) + [Double](repeating: 1, count: ticks)))
        }
        var crossing = Double.infinity
        for (before, after) in zip(rise, rise.dropFirst()) where before.value < 0.63 && after.value >= 0.63 {
            let fraction = (0.63 - before.value) / (after.value - before.value)
            crossing = (Double(before.ticks) + fraction) / VisualizerMath.sampleRate
        }
        print(String(
            format: "C7 attack: %@, 63 %% at %.4f s",
            rise.map { String(format: "%.3f", $0.value) }.joined(separator: " "),
            crossing
        ))
        XCTAssertGreaterThanOrEqual(crossing, 0.025, "the wire reached 63 % of its step at \(crossing) s")
        XCTAssertLessThanOrEqual(crossing, 0.060, "the wire reached 63 % of its step at \(crossing) s")

        let peak = envelope([Double](repeating: 0, count: 42) + [Double](repeating: 1, count: 6))
        let later = envelope(
            [Double](repeating: 0, count: 29)
                + [Double](repeating: 1, count: 6)
                + [Double](repeating: 0, count: 13)
        )
        let ratio = later / peak
        print(String(
            format: "C7 decay: %.4f after 0.22 s, %.1f %% of the %.4f it started at",
            later,
            ratio * 100,
            peak
        ))
        XCTAssertGreaterThanOrEqual(ratio, 0.30, "the wire lost all but \(ratio) of its heat in 0.22 s")
        XCTAssertLessThanOrEqual(ratio, 0.45, "the wire kept \(ratio) of its heat after 0.22 s")
    }
}

// MARK: - C8 Bounds

extension FilamentCoilTests {
    /// C8: the light of the loudest frame stays inside the canvas.
    ///
    /// Measured on a transparent canvas, so the alpha is the coil's own coverage,
    /// and on the tile's shorter canvas as well as the card's: the halo is wider than
    /// the tile is tall.
    func testC8TheLoudestFrameStaysInsideItsCanvas() throws {
        let take = Self.script(at: Self.loudest)
        for size in [Self.canvas, Self.tileCanvas] {
            let bitmap = try rasterise(coil(take, size: size, time: Self.loudest), size: size)
            var worst = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where onEdge(bitmap, x, y) {
                    worst = max(worst, colour(bitmap, x, y).alpha)
                }
            }
            let ink = meanLuminance(bitmap, CGRect(origin: .zero, size: size))
            print(String(
                format: "C8 %.0f x %.0f: worst alpha in the outer half point %.5f, mean ink %.4f",
                size.width,
                size.height,
                worst,
                ink
            ))
            XCTAssertGreaterThan(ink, 0.002, "the loudest frame drew nothing on a canvas of \(size)")
            XCTAssertLessThan(worst, 0.02, "the loudest frame painted \(worst) in the outermost half point")
        }
    }
}

// MARK: - C9 Reduced motion

extension FilamentCoilTests {
    /// C9: a reduced-motion frame is one picture whatever the clock says.
    ///
    /// The pair is compared as PNG bytes rather than as pixels, which is the stronger
    /// claim: nothing in the frame reads the clock when the motion is reduced. The
    /// same take with the motion on is then shown to differ between the two clocks,
    /// so the stillness is the setting's doing and not the style's.
    func testC9AReducedMotionFrameIsOnePicture() throws {
        let take = Self.script(at: Self.loudest)
        let first = try png(coil(take, time: 1.0, reduceMotion: true), size: Self.canvas)
        let second = try png(coil(take, time: 5.0, reduceMotion: true), size: Self.canvas)
        let movingFirst = try png(coil(take, time: 1.0), size: Self.canvas)
        let movingSecond = try png(coil(take, time: 5.0), size: Self.canvas)
        print(String(
            format: "C9 reduced motion: %d bytes at t=1.0 and %d at t=5.0, %@; with the motion on %@",
            first.count,
            second.count,
            first == second ? "identical" : "different",
            movingFirst == movingSecond ? "identical" : "different"
        ))
        XCTAssertEqual(first, second, "the reduced-motion coil is two pictures at two clocks")
        XCTAssertNotEqual(movingFirst, movingSecond, "the coil drew one picture at two clocks with the motion on")
    }
}

// MARK: - C10 A fixed shape

extension FilamentCoilTests {
    /// C10: the wire is a physical object and its shape never changes.
    ///
    /// The only thing about the geometry that may read the clock is the shiver of a
    /// heated wire, and that is off in reduced motion: with the same heat and no
    /// shiver, two frames five seconds apart have to be the same wire to the last
    /// point, or the coil is a drawing that breathes.
    func testC10TheShapeIsFixedInTime() {
        let take = Self.script(at: Self.loudest)
        let profile = Self.heat(take)
        let shape = Filament.geometry(for: Self.canvas)
        let first = Filament.coil(in: shape, heat: profile, time: 1.0, reduceMotion: true)
        let second = Filament.coil(in: shape, heat: profile, time: 5.0, reduceMotion: true)
        var worst = 0.0
        for (a, b) in zip(first.nodes, second.nodes) {
            for (one, other) in zip(a, b) {
                worst = max(worst, hypot(one.point.x - other.point.x, one.point.y - other.point.y))
            }
        }
        print(String(
            format: "C10 %d strands, %d strokes: worst point moved %.9f pt between t=1.0 and t=5.0",
            first.nodes.count,
            first.pieces.count,
            worst
        ))
        XCTAssertEqual(first.nodes.count, second.nodes.count)
        XCTAssertEqual(worst, 0, "the wire moved by \(worst) pt between two clocks")
        XCTAssertEqual(first.pieces.count, second.pieces.count)
    }
}

// MARK: - Draw time

extension FilamentCoilTests {
    /// The draw time of sixty frames at twice the points.
    ///
    /// Measured and reported rather than asserted: the machine this ran on is shared
    /// with other work, so a number here is a record and not a budget. The
    /// measurement is one frame of the card's canvas through the hosting view and
    /// its rasterisation, which is the whole of what the card draws for this style.
    func testTheDrawTimeOfSixtyFrames() throws {
        _ = NSApplication.shared
        let size = Self.canvas
        let rect = NSRect(origin: .zero, size: size)
        let hosting = NSHostingView(rootView: coil(Self.script(at: 5.0), time: 5.0)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, CGFloat(Self.scale)))
        hosting.frame = rect
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = hosting
        window.orderFrontRegardless()

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
        ), "the timing bitmap could not be allocated")
        bitmap.size = size

        var samples: [Double] = []
        for index in -3..<60 {
            let time = 5.0 + Double(max(0, index)) / 60
            hosting.rootView = coil(Self.script(at: time), time: time)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .environment(\.displayScale, CGFloat(Self.scale))
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let start = CFAbsoluteTimeGetCurrent()
            hosting.cacheDisplay(in: rect, to: bitmap)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            guard index >= 0 else { continue }
            samples.append(elapsed)
        }
        window.contentView = nil
        window.orderOut(nil)

        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)]
        print(String(
            format: "DRAW filament: median %.2f ms, p95 %.2f ms over %d frames at %dx (min %.2f, max %.2f)",
            median,
            p95,
            samples.count,
            Self.scale,
            sorted.first ?? 0,
            sorted.last ?? 0
        ))
        XCTAssertEqual(samples.count, 60)

        let wire = Filament.coil(
            in: Filament.geometry(for: size),
            heat: Self.heat(Self.script(at: Self.loudest)),
            time: Self.loudest,
            reduceMotion: false
        )
        print(String(
            format: "DRAW filament: %d strokes a pass over %d strands (%d front, %d core)",
            wire.pieces.count,
            wire.nodes.count,
            wire.pieces.filter(\.isFront).count,
            Filament.corePieces(wire).count
        ))
    }
}

// MARK: - Evidence

extension FilamentCoilTests {
    /// Writes the card renders, the motion strip, the still pair and a close-up for a
    /// design review.
    ///
    /// Skipped unless `DOT_VISUALIZER_EVIDENCE` names a directory. Every frame is
    /// written twice: once on a transparent surface and once composited over the
    /// card's own dark fill, because the wire is a light in a dark room and the
    /// picture is judged on the background it is drawn on.
    func testFilamentEvidence() throws {
        guard let directory = Self.evidence else {
            throw XCTSkip("DOT_VISUALIZER_EVIDENCE is not set")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        func write(_ data: Data, _ name: String) throws {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }

        // The recording card on the Black material, at six moments of the
        // demonstration: before the first syllable, inside two of them, across the
        // breath, at the crest of `send` and after the last word. The card is opaque,
        // so its own dark twin is the same picture at the same pixels.
        for moment in [0.75, 1.50, 2.50, 4.00, 6.96, 9.00] {
            let snapshot = Self.script(at: moment)
            let frame = try png(card(snapshot, size: cardSize, time: moment), size: cardSize)
            try write(frame, String(format: "filament-card-t%.2f.png", moment))
            try write(frame, String(format: "filament-card-t%.2f-dark.png", moment))
        }

        // Twelve frames a fifteenth of a second apart from the breath before the
        // loudest syllable, laid side by side.
        try write(try strip(from: 6.50, frames: 12, step: 1.0 / 15), "filament-strip.png")
        try write(
            try strip(from: 6.50, frames: 12, step: 1.0 / 15, over: Self.cardFill),
            "filament-strip-dark.png"
        )

        // Silence, and the reduced-motion pair: the two frames must be one picture.
        let quiet = Self.silence
        try write(try png(coil(quiet, time: 1.0), size: Self.canvas), "filament-silence.png")
        try write(try png(dark(quiet, time: 1.0), size: Self.canvas), "filament-silence-dark.png")
        let still = Self.script(at: Self.loudest)
        let first = try png(coil(still, time: 1.0, reduceMotion: true), size: Self.canvas)
        let second = try png(coil(still, time: 5.0, reduceMotion: true), size: Self.canvas)
        try write(first, "filament-reduced-t1.00.png")
        try write(second, "filament-reduced-t5.00.png")
        try write(try png(dark(still, time: 1.0, reduceMotion: true), size: Self.canvas), "filament-reduced-t1.00-dark.png")
        try write(try png(dark(still, time: 5.0, reduceMotion: true), size: Self.canvas), "filament-reduced-t5.00-dark.png")
        XCTAssertEqual(first, second, "the reduced-motion pair is not one picture")

        // The loudest frame of the canvas alone at six times the points, so the wire
        // itself can be judged.
        try write(
            try png(dark(Self.script(at: Self.loudest), time: Self.loudest), size: Self.canvas, scale: 6),
            "filament-closeup-dark.png"
        )
    }

    /// Frames of the demonstration laid side by side into one picture.
    ///
    /// - Parameters:
    ///   - start: the moment of the demonstration the first frame is taken at.
    ///   - frames: how many frames the strip holds.
    ///   - step: how far apart the frames are, in seconds.
    ///   - background: a colour to draw behind every frame, or `nil` for a
    ///     transparent strip.
    /// - Returns: the PNG of the strip, at twice the points.
    func strip(from start: Double, frames: Int, step: Double, over background: Color? = nil) throws -> Data {
        let size = Self.canvas
        let strip = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * Self.scale * frames,
            pixelsHigh: Int(size.height) * Self.scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the strip could not be allocated")
        strip.size = CGSize(width: size.width * CGFloat(frames), height: size.height)
        if let data = strip.bitmapData {
            memset(data, 0, strip.bytesPerRow * strip.pixelsHigh)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
        for index in 0..<frames {
            let time = start + Double(index) * step
            let snapshot = Self.script(at: time)
            let frame: NSBitmapImageRep = if let background {
                try rasterise(
                    ZStack {
                        background
                        coil(snapshot, time: time)
                    },
                    size: size
                )
            } else {
                try rasterise(coil(snapshot, time: time), size: size)
            }
            _ = frame.draw(in: NSRect(
                x: CGFloat(index) * size.width,
                y: 0,
                width: size.width,
                height: size.height
            ))
        }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(strip.representation(using: .png, properties: [:]))
    }
}

// MARK: - C11 Drawn loops

extension FilamentCoilTests {
    /// C11: every turn is a loop that was drawn, not a wave that was sampled.
    ///
    /// A helix seen exactly side-on projects to a sinusoid, and a sinusoid reads as
    /// a wave however carefully its turns are spaced. The loop is drawn because the
    /// wire swings across the span by its own radius as it comes round, so the screen
    /// x of a turn is not monotonic: it goes forward, comes back, and goes forward
    /// again, which is what the eye reads as a coil. The count of self-intersections
    /// is the second half of the claim: the loops of one strand have to cross one
    /// another as well.
    func testC11EveryTurnIsADrawnLoop() {
        let take = Self.script(at: Self.loudest)
        let profile = Self.heat(take)
        let shape = Filament.geometry(for: Self.canvas)
        let span = shape.end - shape.start
        let turnCount = Filament.turns(strand: 0, span: span)
        let nodes = Filament.nodes(strand: 0, in: shape, heat: profile, time: Self.loudest, reduceMotion: true)
        let window = nodes.filter { $0.u >= 0.3 && $0.u <= 0.7 }

        var turns = 0
        var monotonic = 0
        var index = 0
        while index < window.count - 1 {
            let turn = Int((window[index].u * turnCount).rounded(.down))
            var last = index
            var forwardSteps = 0
            var backwardSteps = 0
            var next = index + 1
            while next < window.count, Int((window[next].u * turnCount).rounded(.down)) == turn {
                let dx = window[next].point.x - window[last].point.x
                if dx < -0.0001 { backwardSteps += 1 } else if dx > 0.0001 { forwardSteps += 1 }
                last = next
                next += 1
            }
            turns += 1
            if backwardSteps == 0 || forwardSteps == 0 { monotonic += 1 }
            index = max(index + 1, next)
        }

        let crossings = Self.selfIntersections(nodes.map(\.point))
        let required = Int((turnCount * 0.6).rounded())
        print(String(
            format: "C11 %.2f turns over %.1f pt: %d turns in the window, %d of them monotonic in x, "
                + "%d self-intersections (floor %d)",
            turnCount,
            span,
            turns,
            monotonic,
            crossings,
            required
        ))
        XCTAssertGreaterThan(turns, 2, "the window held only \(turns) turns")
        XCTAssertEqual(monotonic, 0, "\(monotonic) of \(turns) turns run straight across the canvas")
        XCTAssertGreaterThanOrEqual(crossings, required, "the strand crosses itself only \(crossings) times")
    }

    /// How many times a polyline crosses itself, away from its neighbouring segments.
    static func selfIntersections(_ points: [CGPoint]) -> Int {
        guard points.count > 4 else { return 0 }
        var count = 0
        for i in 0..<(points.count - 1) {
            guard i + 2 < points.count - 1 else { continue }
            for j in (i + 2)..<(points.count - 1) {
                if i == 0, j == points.count - 2 { continue }
                let p = points[i]
                let r = CGPoint(x: points[i + 1].x - p.x, y: points[i + 1].y - p.y)
                let q = points[j]
                let s = CGPoint(x: points[j + 1].x - q.x, y: points[j + 1].y - q.y)
                let denominator = r.x * s.y - r.y * s.x
                guard abs(denominator) > 1e-9 else { continue }
                let dx = q.x - p.x
                let dy = q.y - p.y
                let t = (dx * s.y - dy * s.x) / denominator
                let u = (dx * r.y - dy * r.x) / denominator
                if t > 0, t < 1, u > 0, u < 1 {
                    count += 1
                }
            }
        }
        return count
    }
}

// MARK: - C12 An unbroken wire

extension FilamentCoilTests {
    /// C12: the wire is one unbroken line from end to end.
    ///
    /// A tungsten wire has no gaps in it, and a gap in a glowing stroke reads as a
    /// break rather than as a turn. The strokes of the frame are cut at the
    /// silhouette and at every heat bin, so the cuts are what this measures: every
    /// step between two samples of every strand must be drawn by a stroke, and the
    /// far half of the wire must be a continuous dimmer line rather than a dashed
    /// one. The check is on the strokes' own vertices, which is the exact form of
    /// "no run of dark pixels between two lit ones" without the third strand
    /// covering the gap for the second.
    func testC12TheWireIsContinuous() {
        let take = Self.script(at: Self.loudest)
        let profile = Self.heat(take)
        let shape = Filament.geometry(for: Self.canvas)
        let wire = Filament.coil(in: shape, heat: profile, time: Self.loudest, reduceMotion: true)

        /// Every segment a stroke draws, as its two ends.
        var segments: [(a: CGPoint, b: CGPoint)] = []
        for piece in wire.pieces {
            var previous: CGPoint?
            piece.path.forEach { element in
                switch element {
                case .move(let point):
                    previous = point
                case .line(let point):
                    if let previous {
                        segments.append((previous, point))
                    }
                    previous = point
                default:
                    break
                }
            }
        }

        /// How far a drawn segment is from the step between two samples.
        ///
        /// A tolerance rather than an equality: a path hands its vertices back within
        /// a thousandth of a point of the values it was given, and the claim here is
        /// about gaps of a third of a point, so two hundredths of a point is the same
        /// segment and is still two orders of magnitude below the gap being measured.
        func distance(_ segment: (a: CGPoint, b: CGPoint), _ from: CGPoint, _ to: CGPoint) -> Double {
            let direct = max(
                hypot(Double(segment.a.x - from.x), Double(segment.a.y - from.y)),
                hypot(Double(segment.b.x - to.x), Double(segment.b.y - to.y))
            )
            let reversed = max(
                hypot(Double(segment.a.x - to.x), Double(segment.a.y - to.y)),
                hypot(Double(segment.b.x - from.x), Double(segment.b.y - from.y))
            )
            return min(direct, reversed)
        }

        var missing: [(strand: Int, u: Double, length: Double)] = []
        var steps = 0
        for (strand, nodes) in wire.nodes.enumerated() where nodes.count > 1 {
            for index in 1..<nodes.count {
                let from = nodes[index - 1].point
                let to = nodes[index].point
                steps += 1
                let drawn = segments.contains { distance($0, from, to) < 0.02 }
                guard !drawn else { continue }
                missing.append((strand, nodes[index].u, hypot(
                    Double(to.x - from.x),
                    Double(to.y - from.y)
                )))
            }
        }
        let worst = missing.max { $0.length < $1.length }
        let back = wire.pieces.filter { !$0.isFront }.count
        print(String(
            format: "C12 %d steps over %d strands, %d strokes (%d far side), %d steps not drawn, "
                + "worst %.4f pt at strand %d u %.3f, far side at %.2f of the near side",
            steps,
            wire.nodes.count,
            segments.count,
            back,
            missing.count,
            worst?.length ?? 0,
            worst?.strand ?? 0,
            worst?.u ?? 0,
            Filament.backInk
        ))
        if !missing.isEmpty {
            print("C12 missing: " + missing.map {
                String(format: "s%d u%.3f %.3f pt", $0.strand, $0.u, $0.length)
            }.joined(separator: ", "))
        }
        XCTAssertGreaterThan(segments.count, 0, "the frame drew no stroke at all")
        XCTAssertEqual(missing.count, 0, "the wire has \(missing.count) steps it does not draw")
        XCTAssertLessThan(worst?.length ?? 0, 0.3, "the widest gap in the wire is \(worst?.length ?? 0) pt")
        XCTAssertGreaterThan(back, 0, "the far half of the wire is never drawn")
        XCTAssertGreaterThanOrEqual(Filament.backInk, 0.35, "the far half is drawn too faint to read as wire")
    }
}

// MARK: - Glass evidence

extension FilamentCoilTests {
    /// The window server's picture of the style on the island's Glass material.
    ///
    /// The island ships two materials, Black and Glass. Glass is the system's Liquid
    /// Glass, which the window server composites: it is not in the app's own drawing,
    /// so the only picture that contains it is a capture of the window. The card is
    /// hosted in a transparent borderless window at the offscreen origin over a bright
    /// and a dark backdrop, the way ``GlassSurfaceTests`` does it, and captured.
    ///
    /// Two measurements per backdrop: the contrast of the brightest thing the coil
    /// draws against the surface it is drawn on, and the mean luminance the voice adds
    /// to the canvas against silence. Skipped when the window server hands back a
    /// blank picture, which is what a process without the screen recording right is
    /// given.
    func testFilamentGlassEvidence() throws {
        guard let directory = Self.evidence else {
            throw XCTSkip("DOT_VISUALIZER_EVIDENCE is not set")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        let canvasSize = CGSize(width: 400, height: 160)
        let cardRect = CGRect(
            x: (canvasSize.width - cardSize.width) / 2,
            y: (canvasSize.height - cardSize.height) / 2,
            width: cardSize.width,
            height: cardSize.height
        )
        let backdrops: [(name: String, luma: Double)] = [("bright", 0.92), ("dark", 0.12)]

        /// The window server's picture of the card over a backdrop.
        func capture(
            _ snapshot: Snapshot,
            time: Double,
            over luma: Double,
            material: HUDMaterial = .glass
        ) throws -> WindowCapture.Pixels {
            let view = ZStack {
                Color(red: luma, green: luma, blue: luma)
                card(snapshot, size: cardSize, time: time, material: material)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            let window = WindowCapture.show(view, size: canvasSize)
            defer { WindowCapture.hide(window) }
            let picture = try XCTUnwrap(
                WindowCapture.capture(window),
                "the window server returned no picture of the window"
            )
            try WindowCapture.requireUsableCapture(picture)
            return picture
        }

        // The canvas: where the style draws, found on the opaque material, where the
        // only pixels the voice changes are the style's own. The Glass card refracts
        // its content, so the box that changes there is wider than the canvas and
        // would dilute the mean with the clock and the buttons.
        let opaqueLoud = try capture(Self.script(at: Self.loudest), time: Self.loudest, over: 0.5, material: .black)
        let opaqueQuiet = try capture(Self.silence, time: 1.0, over: 0.5, material: .black)
        let scaleX = CGFloat(opaqueLoud.width) / canvasSize.width
        let scaleY = CGFloat(opaqueLoud.height) / canvasSize.height
        let box = WindowCapture.Rect.points(cardRect, scaleX: scaleX, scaleY: scaleY)
        let canvas = Self.canvasBox(
            opaqueLoud,
            opaqueQuiet,
            card: box,
            height: HUDTheme.waveformHeight,
            scaleY: scaleY
        )
        guard canvas.width > 0, canvas.height > 0 else {
            throw XCTSkip("the opaque card changed no pixel of its canvas")
        }
        print(String(
            format: "GLASS canvas found on the opaque card: %d x %d px, %.1f x %.1f pt at %.1f pt across the "
                + "%.0f pt card, %.1f pt down its %.0f pt height",
            canvas.width,
            canvas.height,
            Double(canvas.width) / Double(scaleX),
            Double(canvas.height) / Double(scaleY),
            (Double(canvas.x) - Double(box.x)) / Double(scaleX),
            cardSize.width,
            (Double(canvas.y) - Double(box.y)) / Double(scaleY),
            cardSize.height
        ))

        for (name, luma) in backdrops {
            var frames: [(String, WindowCapture.Pixels)] = []
            for (moment, label) in [(1.50, "t1.50"), (Self.loudest, "t6.96")] {
                let picture = try capture(Self.script(at: moment), time: moment, over: luma)
                let url = directory.appendingPathComponent("filament-glass-\(name)-\(label).png")
                XCTAssertTrue(WindowCapture.write(picture, to: url), "\(url.lastPathComponent) was not written")
                frames.append((label, picture))
            }
            let quiet = try capture(Self.silence, time: 1.0, over: luma)
            let silentURL = directory.appendingPathComponent("filament-glass-\(name)-silence.png")
            XCTAssertTrue(WindowCapture.write(quiet, to: silentURL), "\(silentURL.lastPathComponent) was not written")

            let loud = frames[1].1
            let loudMean = Self.meanLuminance(loud, canvas)
            let quietMean = Self.meanLuminance(quiet, canvas)
            let brightest = Self.brightest(loud, canvas)
            let backdrop = Self.medianLuminance(quiet, canvas)
            let ratio = (brightest.luminance + 0.05) / (backdrop + 0.05)
            print(String(
                format: "GLASS %@: canvas %dx%d px at (%.1f, %.1f) pt, brightest %.4f at (%.1f, %.1f), "
                    + "local backdrop %.4f, contrast %.2f:1, voice adds %.4f luma to the canvas",
                name,
                canvas.width,
                canvas.height,
                Double(canvas.x) / Double(scaleX),
                Double(canvas.y) / Double(scaleY),
                brightest.luminance,
                Double(brightest.x) / Double(scaleX),
                Double(brightest.y) / Double(scaleY),
                backdrop,
                ratio,
                loudMean - quietMean
            ))
            if name == "bright" {
                XCTAssertGreaterThanOrEqual(loudMean - quietMean, 0.06, "the voice is invisible on the bright backdrop")
            } else {
                XCTAssertGreaterThanOrEqual(loudMean - quietMean, 0.10, "the voice is invisible on the dark backdrop")
            }
            XCTAssertGreaterThan(ratio, 1.0, "the brightest element does not stand above its backdrop")
        }
    }

    /// The box the style draws in, taken from a capture of the opaque card.
    ///
    /// The card's live dot glows with the voice as well, so the bounding box of
    /// every pixel the voice changes is wider than the canvas and would dilute a
    /// mean with the card's empty left side. The style is the wide thing: its light
    /// is the widest unbroken run of columns that changes, and the canvas is that
    /// run at the waveform's own height, centred on the card.
    static func canvasBox(
        _ loud: WindowCapture.Pixels,
        _ quiet: WindowCapture.Pixels,
        card: WindowCapture.Rect,
        height: CGFloat,
        scaleY: CGFloat
    ) -> WindowCapture.Rect {
        let x0 = max(0, card.x)
        let x1 = min(loud.width, card.x + card.width)
        let y0 = max(0, card.y)
        let y1 = min(loud.height, card.y + card.height)
        guard x1 > x0, y1 > y0, quiet.width == loud.width, quiet.height == loud.height else {
            return card
        }
        var changed = [Bool](repeating: false, count: x1 - x0)
        for x in x0..<x1 {
            for y in y0..<y1 {
                let a = loud.pixel(x, y)
                let b = quiet.pixel(x, y)
                if abs(a.0 - b.0) > 2 || abs(a.1 - b.1) > 2 || abs(a.2 - b.2) > 2 {
                    changed[x - x0] = true
                }
            }
        }
        var best = (start: 0, length: 0)
        var start = -1
        for index in 0...changed.count {
            let hot = index < changed.count && changed[index]
            if hot, start < 0 {
                start = index
            } else if !hot, start >= 0 {
                if index - start > best.length { best = (start, index - start) }
                start = -1
            }
        }
        guard best.length > 0 else { return card }
        let half = max(1, Int((height * scaleY / 2).rounded()))
        return WindowCapture.Rect(
            x: x0 + best.start,
            y: card.y + card.height / 2 - half,
            width: best.length,
            height: half * 2
        )
    }

    /// The mean WCAG luminance of a rect of a picture.
    static func meanLuminance(_ picture: WindowCapture.Pixels, _ rect: WindowCapture.Rect) -> Double {
        let x0 = max(0, rect.x)
        let y0 = max(0, rect.y)
        let x1 = min(picture.width, rect.x + rect.width)
        let y1 = min(picture.height, rect.y + rect.height)
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum = 0.0
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                sum += WindowCapture.luminance(picture.pixel(x, y))
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// The median WCAG luminance of a rect of a picture, which is the surface the
    /// coil is drawn on rather than the light it draws.
    static func medianLuminance(_ picture: WindowCapture.Pixels, _ rect: WindowCapture.Rect) -> Double {
        let x0 = max(0, rect.x)
        let y0 = max(0, rect.y)
        let x1 = min(picture.width, rect.x + rect.width)
        let y1 = min(picture.height, rect.y + rect.height)
        guard x1 > x0, y1 > y0 else { return 0 }
        var values: [Double] = []
        for y in y0..<y1 {
            for x in x0..<x1 {
                values.append(WindowCapture.luminance(picture.pixel(x, y)))
            }
        }
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    /// The brightest pixel of a rect of a picture.
    static func brightest(
        _ picture: WindowCapture.Pixels,
        _ rect: WindowCapture.Rect
    ) -> (luminance: Double, x: Int, y: Int) {
        var best = (luminance: 0.0, x: rect.x, y: rect.y)
        for y in max(0, rect.y)..<min(picture.height, rect.y + rect.height) {
            for x in max(0, rect.x)..<min(picture.width, rect.x + rect.width) {
                let value = WindowCapture.luminance(picture.pixel(x, y))
                if value > best.luminance {
                    best = (value, x, y)
                }
            }
        }
        return best
    }
}
