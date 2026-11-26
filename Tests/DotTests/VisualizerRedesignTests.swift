import AppKit
import AVFoundation
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The three rebuilt visualisers and the Settings preview pace.
///
/// Every measurement here is drawn from a real analysis path: a level is pushed
/// through ``VoiceMeter`` and its bands through ``SpectrumScale`` and the card's
/// 60 Hz smoothing, and the visualiser is drawn from the result. Nothing is a
/// picture of a formula.
///
/// The takes are generated in memory, so the suite runs in a clean checkout. The
/// evidence renders write files, so they are skipped unless
/// `DOT_VISUALIZER_EVIDENCE` names a directory; a real recording is used for one
/// canvas when `DOT_VISUALIZER_AUDIO` names a directory of them.
///
/// No window is ever put on a display: each view is hosted in an
/// ``OffscreenWindow`` at `-20000` and captured with `cacheDisplay`.
@MainActor
final class VisualizerRedesignTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    /// Where the evidence renders are written, when the run asks for them.
    static var evidence: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOT_VISUALIZER_EVIDENCE"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The pixels per point of every render.
    static let scale = 2
    /// How far one bar of the stretch row may be from its reflection.
    ///
    /// One level of an eight-bit channel is `1 / 255`, and a bar's height is
    /// compared in levels of that channel: two bars whose arithmetic is a mirror
    /// of each other are equal to within the level the picture can show.
    static let mirrorTolerance = 1.0 / 255.0
    /// The card's waveform canvas, in points.
    static let canvas = CGSize(width: 102, height: 26)
    /// The canvas the ribbons and the ripples are written against, in points.
    static let wideCanvas = CGSize(width: 132, height: 26)
    /// A Settings tile's waveform canvas, in points.
    static let tileCanvas = CGSize(width: 200, height: 22)
    /// The eight moments a contact sheet is drawn at.
    static let moments: [Double] = (0..<8).map { 0.75 + 0.25 * Double($0) }
    /// Eight moments that all fall inside a burst of the generated takes.
    ///
    /// A picture of a breath is a picture of the floor, which is the right
    /// picture for the silence test and the wrong one for counting ribbons. The
    /// moments start after three seconds because a take has no history before
    /// it has been running: the card's ring holds three seconds, and a picture
    /// drawn from an empty one is a picture of the floor.
    static let bursts: [Double] = (0..<8).map { 3.10 + 0.30 * Double($0) }

    // MARK: - Takes

    /// One take, tick by tick, as the card would have received it.
    struct Take {
        let name: String
        let ticks: [Snapshot]

        func at(_ time: Double) -> Snapshot {
            let index = min(ticks.count - 1, max(0, Int((time * Waveform.sampleRate).rounded())))
            return ticks[index]
        }
    }

    /// What one 60 Hz tick of the card holds.
    struct Snapshot {
        var history: [Double]
        var spectrum: [AudioSpectrumFrame]
        var ceiling: Double
        var level: Double
        var phase: Double
    }

    /// A take generated in memory and measured the way a microphone's is.
    ///
    /// The envelope is a burst train at the pace of speech, with one breath in
    /// it; the bands follow the same level, as a voice's do. `silence` is the
    /// same path with no level at all, which is what the tap reports when the
    /// room is quiet.
    static func syntheticTake(_ name: String) -> Take {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        var spectrum = SpectrumPipeline()
        let seconds = 6.0
        let ticks = Int(seconds * Waveform.sampleRate)
        var snapshots: [Snapshot] = []
        snapshots.reserveCapacity(ticks)
        for tick in 0..<ticks {
            let time = Double(tick) / Waveform.sampleRate
            let level = syntheticLevel(name, at: time)
            meter.push(decibels: -58 + level * 50, now: time)
            let bands = AudioSpectrumFrame(bands: (
                min(1, level * 0.92),
                min(1, level * 0.80),
                min(1, level * 0.70),
                min(1, level * 0.76),
                min(1, level * 0.58)
            ))
            spectrum.advance(target: bands, dt: 1.0 / Waveform.sampleRate)
            snapshots.append(Snapshot(
                history: meter.orderedHistory,
                spectrum: spectrum.ring,
                ceiling: meter.ceiling,
                level: meter.level,
                phase: meter.phase
            ))
        }
        return Take(name: name, ticks: snapshots)
    }

    /// The level of a generated take at a moment, from `0` to `1`.
    static func syntheticLevel(_ name: String, at time: Double) -> Double {
        guard name != "silence" else { return 0 }
        let loudness = name == "energetic" ? 1.0 : 0.6
        // Nine bursts of 0.22 s every 0.30 s, with a 0.32 s breath after the
        // fifth: a phrase, a pause, and a second phrase.
        var position = time.truncatingRemainder(dividingBy: 0.30)
        let breath = time > 1.66 && time < 1.98
        if breath { position = 0.25 }
        let burst = position < 0.22 ? sin(Double.pi * position / 0.22) : 0
        let swell = 0.72 + 0.28 * sin(2 * Double.pi * 1.7 * time)
        return min(1, loudness * burst * swell)
    }

    /// A take read from a real speech file, for the evidence renders.
    static func audioTake(_ name: String) throws -> Take {
        guard let directory = ProcessInfo.processInfo.environment["DOT_VISUALIZER_AUDIO"] else {
            throw XCTSkip("DOT_VISUALIZER_AUDIO is not set")
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name)-48k.wav")
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: buffer)
        let mono = UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength))
        let samples = Array(mono)

        let blockSize = 1024
        var blocks: [AudioSpectrumFrame.Measure] = []
        var start = 0
        while start + blockSize <= samples.count {
            blocks.append(AudioSpectrumFrame.measure(mono: Array(samples[start..<(start + blockSize)]), sampleRate: 48_000))
            start += blockSize
        }
        XCTAssertFalse(blocks.isEmpty, "\(name) had no audio")

        let meter = VoiceMeter()
        meter.setCalibration(nil)
        var spectrum = SpectrumPipeline()
        let seconds = Double(samples.count) / 48_000
        let tickCount = Int((seconds * Waveform.sampleRate).rounded(.down))
        let blockSeconds = Double(blockSize) / 48_000
        var ticks: [Snapshot] = []
        ticks.reserveCapacity(tickCount)
        for tick in 0..<tickCount {
            let time = Double(tick) / Waveform.sampleRate
            let block = blocks[min(blocks.count - 1, Int(time / blockSeconds))]
            meter.push(decibels: AudioLevel.decibels(block.level), now: time)
            spectrum.advance(target: block.frame, dt: 1.0 / Waveform.sampleRate)
            ticks.append(Snapshot(
                history: meter.orderedHistory,
                spectrum: spectrum.ring,
                ceiling: meter.ceiling,
                level: meter.level,
                phase: meter.phase
            ))
        }
        return Take(name: name, ticks: ticks)
    }

    /// The card's 60 Hz spectrum path, mirrored from `HUD.advanceSpectrum`.
    ///
    /// The per-voice window, the 14 ms attack / 30 ms release smoothing and the
    /// 60 Hz ring, so a render is drawn from the numbers the card would hold.
    @MainActor
    struct SpectrumPipeline {
        var scale = SpectrumScale()
        var smoothed = AudioSpectrumFrame.zero
        var clock: Double = 0
        var ring: [AudioSpectrumFrame] = []

        mutating func advance(target: AudioSpectrumFrame, dt: Double) {
            if ring.isEmpty {
                ring = Array(repeating: AudioSpectrumFrame.zero, count: Waveform.historyLength)
            }
            let scaled = scale.normalise(target, dt: dt)
            func step(_ current: Double, _ next: Double) -> Double {
                let tau = next > current ? 0.014 : 0.03
                return current + (next - current) * (1 - exp(-max(0, dt) / tau))
            }
            smoothed = AudioSpectrumFrame(bands: (
                step(smoothed.bands.0, scaled.bands.0),
                step(smoothed.bands.1, scaled.bands.1),
                step(smoothed.bands.2, scaled.bands.2),
                step(smoothed.bands.3, scaled.bands.3),
                step(smoothed.bands.4, scaled.bands.4)
            ))
            clock += dt * Waveform.sampleRate
            while clock >= 1 {
                clock -= 1
                ring.removeFirst()
                ring.append(smoothed)
            }
        }
    }

    // MARK: - Renders

    /// The surface a render is drawn on: the card's own black material.
    struct Pane<Content: View>: View {
        @ViewBuilder var content: Content

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [HUDTheme.surfaceTop.opacity(0.95), HUDTheme.surfaceBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                content
            }
        }
    }

    /// Rasterises a view at twice the points, off every display.
    func rasterise(_ content: some View, size: CGSize) throws -> NSBitmapImageRep {
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

    /// Rasterises a view and writes it into the evidence directory.
    @discardableResult
    func render(_ content: some View, size: CGSize, named name: String) throws -> NSBitmapImageRep {
        let bitmap = try rasterise(content, size: size)
        guard let directory = Self.evidence else { return bitmap }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return bitmap
    }

    /// The waveform canvas on the card's surface.
    func waveform(
        _ snapshot: Snapshot,
        _ visualizer: HUDVisualizer,
        phase: Double? = nil
    ) -> some View {
        Pane {
            HUDWaveform(
                visualizer: visualizer,
                halfHeights: [],
                history: snapshot.history,
                spectrumHistory: snapshot.spectrum,
                phase: phase ?? snapshot.phase,
                time: 1.75,
                level: snapshot.level,
                pulse: 0.25,
                ceiling: snapshot.ceiling,
                reveal: 1
            )
            .frame(width: Self.canvas.width, height: Self.canvas.height)
        }
    }

    /// The waveform alone on a transparent canvas.
    ///
    /// The bitmap then holds the ink's own colour and its coverage, which is
    /// what a colour rule is about: composited over the card's surface, a dim
    /// ribbon reports the surface's hue as much as its own.
    func plain(
        _ snapshot: Snapshot,
        _ visualizer: HUDVisualizer,
        phase: Double? = nil,
        time: Double = 1.75,
        reduceMotion: Bool = false,
        size: CGSize = VisualizerRedesignTests.canvas
    ) -> some View {
        HUDWaveform(
            visualizer: visualizer,
            halfHeights: [],
            history: snapshot.history,
            spectrumHistory: snapshot.spectrum,
            phase: phase ?? snapshot.phase,
            time: time,
            level: snapshot.level,
            pulse: 0.25,
            ceiling: snapshot.ceiling,
            reveal: 1,
            reduceMotionOverride: reduceMotion
        )
        .frame(width: size.width, height: size.height)
    }

    /// A waveform of `size` inset by `margin` in a larger transparent raster.
    ///
    /// The margin is where the ink that leaves the canvas lands, so a render can
    /// be asked whether a style painted outside the surface it was handed.
    func inset(
        _ snapshot: Snapshot,
        _ visualizer: HUDVisualizer,
        size: CGSize,
        margin: CGFloat,
        time: Double = 1.75,
        reduceMotion: Bool = false
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            plain(snapshot, visualizer, time: time, reduceMotion: reduceMotion, size: size)
                .offset(x: margin, y: margin)
        }
        .frame(width: size.width + margin * 2, height: size.height + margin * 2)
    }

    /// The real recording card at the size it ships.
    func card(
        _ snapshot: Snapshot,
        _ visualizer: HUDVisualizer,
        time: Double = 1.75,
        reduceMotion: Bool = false
    ) -> some View {
        let size = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.material = .black
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = size
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
            actions: HUDPreview.previewActions,
            reduceMotionOverride: reduceMotion
        )
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Pixels

    /// The colour of a pixel, in sRGB, from `0` to `1`.
    ///
    /// `colorAt` returns the unpremultiplied colour, so a half-covered pixel
    /// reports the ink's own colour rather than a blend with black, and the
    /// alpha is what every measurement of coverage below reads.
    func colour(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
              let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return (0, 0, 0, 0) }
        return (colour.redComponent, colour.greenComponent, colour.blueComponent, colour.alphaComponent)
    }

    /// The file-name stem of a visualizer's evidence renders.
    static func slug(_ visualizer: HUDVisualizer) -> String {
        visualizer.title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The vertical half extent of the ink inside a canvas, the width of the
    /// ink, and the worst alpha painted outside the canvas.
    ///
    /// The bitmap is of a canvas of `size` inset by `margin` in a larger raster,
    /// so the ink that leaves the canvas lands in the margin and is measured
    /// rather than being lost to the crop.
    func extent(
        _ bitmap: NSBitmapImageRep,
        canvas size: CGSize,
        margin: CGFloat
    ) -> (half: Double, width: Double, outside: Double) {
        let canvasRect = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        let centreRow = (Double(margin) + Double(size.height) / 2) * Double(Self.scale)
        var half = 0.0
        var outside = 0.0
        var left = Double.infinity
        var right = -Double.infinity
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let point = CGPoint(
                    x: (Double(x) + 0.5) / Double(Self.scale),
                    y: (Double(y) + 0.5) / Double(Self.scale)
                )
                let alpha = colour(bitmap, x, y).alpha
                guard canvasRect.contains(point) else {
                    outside = max(outside, alpha)
                    continue
                }
                guard alpha > 0.02 else { continue }
                half = max(half, abs(Double(y) + 0.5 - centreRow) / Double(Self.scale))
                left = min(left, point.x - margin)
                right = max(right, point.x - margin)
            }
        }
        return (half, right >= left ? right - left : 0, outside)
    }
}

// MARK: - Stretch

extension VisualizerRedesignTests {
    /// A silent row is a fine dashed hairline: one point tall, two points wide,
    /// and still something to look at.
    func testStretchSilenceStaysOnTheHairline() throws {
        let margin: CGFloat = 24
        let outer = CGSize(width: Self.canvas.width + margin * 2, height: Self.canvas.height + margin * 2)
        let bitmap = try rasterise(
            inset(Self.syntheticTake("silence").at(1.0), .stretch, size: Self.canvas, margin: margin),
            size: outer
        )
        let measured = extent(bitmap, canvas: Self.canvas, margin: margin)
        print(String(format: "STRETCH silence half extent %.2f pt, outside %.4f", measured.half, measured.outside))
        // The tallest thing a silent row draws is half of its one point dash, and
        // the raster's own row is the rest of the bound.
        XCTAssertLessThanOrEqual(
            measured.half,
            1.5,
            "a resting dash stood \(measured.half) pt off the centre line"
        )
        XCTAssertLessThan(measured.outside, 0.01, "the resting row painted \(measured.outside) outside its canvas")
        XCTAssertGreaterThan(litPixels(bitmap), 0, "the resting row drew nothing at all")
    }

    /// A loud row reaches most of the canvas's height and paints nothing outside
    /// it, on the card's canvas and on a tile's.
    ///
    /// The take carries a full spectrum as well as a full envelope, so the picture
    /// is the one a loud moment of a real voice draws rather than the floor of a
    /// take that never got loud.
    func testStretchLoudRowFillsItsCanvas() throws {
        let margin: CGFloat = 24
        for size in [Self.canvas, Self.tileCanvas] {
            let outer = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
            let bitmap = try rasterise(
                inset(Self.constantSnapshot(level: 1, bands: 1), .stretch, size: size, margin: margin),
                size: outer
            )
            let measured = extent(bitmap, canvas: size, margin: margin)
            print(String(
                format: "STRETCH loud half extent %.2f pt of %.2f, outside %.4f",
                measured.half,
                Double(size.height) / 2,
                measured.outside
            ))
            XCTAssertGreaterThanOrEqual(
                measured.half,
                Double(size.height) / 2 - 3.5,
                "the loud row reached \(measured.half) pt of \(Double(size.height) / 2)"
            )
            XCTAssertLessThan(measured.outside, 0.01, "the loud row painted \(measured.outside) outside its canvas")
        }
    }

    /// The row scrolls: the same voice, a sixtieth of a second later, is one and a
    /// fifth points further left.
    func testStretchScrollsBetweenTwoFrames() throws {
        let snapshot = Self.syntheticTake("calm").at(3.10)
        let first = try rasterise(
            plain(snapshot, .stretch, phase: 0, time: 3.10),
            size: Self.canvas
        )
        let second = try rasterise(
            plain(snapshot, .stretch, phase: 0, time: 3.10 + 1.0 / Waveform.sampleRate),
            size: Self.canvas
        )
        let difference = meanAlphaDifference(first, second)
        print(String(format: "STRETCH scroll mean alpha difference %.4f", difference))
        XCTAssertGreaterThan(difference, 0.002, "the row did not move (\(difference))")
        XCTAssertLessThan(difference, 0.35, "the row flashed by \(difference)")
    }

    /// A row drawn without motion is the same picture whatever the clock says.
    func testStretchReduceMotionIgnoresTheClock() throws {
        let snapshot = Self.syntheticTake("calm").at(3.10)
        let first = try rasterise(plain(snapshot, .stretch, time: 0, reduceMotion: true), size: Self.canvas)
        let second = try rasterise(plain(snapshot, .stretch, time: 5, reduceMotion: true), size: Self.canvas)
        XCTAssertGreaterThan(litPixels(first), 0, "the reduced-motion row drew nothing")
        XCTAssertEqual(worstAlphaDifference(first, second), 0, "the reduced-motion row moved between two clocks")
    }
}

// MARK: - Silk

extension VisualizerRedesignTests {
    /// A take that never drops, for the loud end of the range.
    ///
    /// A constant signal is the worst case the design is written against: a real
    /// voice has gaps, and a ribbon that only stays inside its canvas because
    /// the person stopped talking is not a ribbon that stays inside its canvas.
    static func constantSnapshot(level: Double, ceiling: Double = 1, bands: Double = 0) -> Snapshot {
        Snapshot(
            history: Array(repeating: level, count: Waveform.historyLength),
            spectrum: Array(
                repeating: AudioSpectrumFrame(bands: (bands, bands, bands, bands, bands)),
                count: Waveform.historyLength
            ),
            ceiling: ceiling,
            level: level,
            phase: 0
        )
    }

    /// The furthest a row carrying ink sits from the canvas's centre row, in
    /// points.
    ///
    /// The canvas is an even number of points tall, so its centre is the line
    /// between two pixel rows and a distance is measured from that line.
    func halfExtent(_ bitmap: NSBitmapImageRep, threshold: Double = 0.02) -> Double {
        let centre = Double(bitmap.pixelsHigh) / 2
        var furthest = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where colour(bitmap, x, y).alpha > threshold {
                furthest = max(furthest, abs(Double(y) + 0.5 - centre))
                break
            }
        }
        return furthest / Double(Self.scale)
    }

    /// The height of everything the canvas paints, in points, from the topmost
    /// row that carries ink to the bottommost.
    func inkHeight(_ bitmap: NSBitmapImageRep, threshold: Double = 0.02) -> Double {
        var top = bitmap.pixelsHigh
        var bottom = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where colour(bitmap, x, y).alpha > threshold {
                top = min(top, y)
                bottom = max(bottom, y)
                break
            }
        }
        guard bottom >= top else { return 0 }
        return Double(bottom - top + 1) / Double(Self.scale)
    }

    /// How many pixels carry ink.
    func litPixels(_ bitmap: NSBitmapImageRep, threshold: Double = 0.02) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where colour(bitmap, x, y).alpha > threshold {
                count += 1
            }
        }
        return count
    }

    /// The mean absolute difference of the alpha channels of two renders of the
    /// same size.
    func meanAlphaDifference(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Double {
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else {
            return .infinity
        }
        var total = 0.0
        var count = 0
        for y in 0..<first.pixelsHigh {
            for x in 0..<first.pixelsWide {
                total += abs(colour(first, x, y).alpha - colour(second, x, y).alpha)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// The worst absolute difference of the alpha channels of two renders.
    func worstAlphaDifference(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Double {
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else {
            return .infinity
        }
        var worst = 0.0
        for y in 0..<first.pixelsHigh {
            for x in 0..<first.pixelsWide {
                worst = max(worst, abs(colour(first, x, y).alpha - colour(second, x, y).alpha))
            }
        }
        return worst
    }

    /// The leftmost and rightmost pixel columns that carry ink, in points.
    func inkColumns(_ bitmap: NSBitmapImageRep, threshold: Double = 0.02) -> (min: Double, max: Double)? {
        var left = bitmap.pixelsWide
        var right = -1
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where colour(bitmap, x, y).alpha > threshold {
                left = min(left, x)
                right = max(right, x)
                break
            }
        }
        guard right >= left else { return nil }
        return (Double(left) / Double(Self.scale), Double(right + 1) / Double(Self.scale))
    }

    /// Silence is a set of hairlines against the centre line, never nothing and
    /// never a shape that fills the canvas.
    func testSilkSilenceStaysOnTheCentreLine() throws {
        let snapshot = Self.syntheticTake("silence").at(1.0)
        let bitmap = try rasterise(plain(snapshot, .silk, size: Self.wideCanvas), size: Self.wideCanvas)
        let half = halfExtent(bitmap)
        print(String(format: "SILK half extent at silence %.2f pt", half))
        XCTAssertLessThanOrEqual(half, 1.2, "silence drew \(half) pt off the centre line")
        XCTAssertGreaterThan(litPixels(bitmap), 0, "silence drew nothing at all")
    }

    /// A loud take fills the canvas the ribbons are written against.
    func testSilkLoudTakeFillsTheCanvas() throws {
        let reach = Double(HUDWaveform.Silk.reach(forHeight: Self.wideCanvas.height))
        let bitmap = try rasterise(
            plain(Self.constantSnapshot(level: 1), .silk, size: Self.wideCanvas),
            size: Self.wideCanvas
        )
        let height = inkHeight(bitmap)
        let half = halfExtent(bitmap)
        print(String(format: "SILK loud ink height %.2f pt, half extent %.2f pt of a reach of %.2f", height, half, reach))
        XCTAssertGreaterThanOrEqual(half, 0.75 * reach, "the loud ribbons reached \(half) pt of a reach of \(reach) pt")
        XCTAssertLessThanOrEqual(half, Double(Self.wideCanvas.height) / 2, "the loud ribbons left the canvas")
    }

    /// The ribbons flow: two moments half a second apart are different pictures,
    /// and neither is a flash of the other.
    func testSilkFlowsBetweenTwoMoments() throws {
        let snapshot = Self.constantSnapshot(level: 1)
        let first = try rasterise(plain(snapshot, .silk, time: 0, size: Self.wideCanvas), size: Self.wideCanvas)
        let second = try rasterise(plain(snapshot, .silk, time: 0.5, size: Self.wideCanvas), size: Self.wideCanvas)
        let difference = meanAlphaDifference(first, second)
        print(String(format: "SILK motion mean alpha difference %.4f", difference))
        XCTAssertGreaterThan(difference, 0.01, "the ribbons moved by only \(difference)")
        XCTAssertLessThan(difference, 0.35, "the ribbons flashed by \(difference)")
    }

    /// A picture drawn without motion is the same picture whatever the clock
    /// says.
    func testSilkReduceMotionIgnoresTheClock() throws {
        let snapshot = Self.syntheticTake("calm").at(3.10)
        let first = try rasterise(
            plain(snapshot, .silk, time: 0, reduceMotion: true, size: Self.wideCanvas),
            size: Self.wideCanvas
        )
        let second = try rasterise(
            plain(snapshot, .silk, time: 5, reduceMotion: true, size: Self.wideCanvas),
            size: Self.wideCanvas
        )
        XCTAssertGreaterThan(litPixels(first), 0, "the reduced-motion ribbons drew nothing")
        XCTAssertEqual(worstAlphaDifference(first, second), 0, "the reduced-motion ribbons moved between two clocks")
    }

    /// Nothing at all is painted outside the canvas the ribbons are handed.
    func testSilkDrawsNothingOutsideItsCanvas() throws {
        let margin: CGFloat = 24
        let outer = CGSize(
            width: Self.wideCanvas.width + margin * 2,
            height: Self.wideCanvas.height + margin * 2
        )
        let bitmap = try rasterise(
            plain(Self.constantSnapshot(level: 1), .silk, size: Self.wideCanvas),
            size: outer
        )
        let canvas = CGRect(
            x: margin,
            y: margin,
            width: Self.wideCanvas.width,
            height: Self.wideCanvas.height
        )
        var worst = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let point = CGPoint(
                    x: (Double(x) + 0.5) / Double(Self.scale),
                    y: (Double(y) + 0.5) / Double(Self.scale)
                )
                guard !canvas.contains(point) else { continue }
                worst = max(worst, colour(bitmap, x, y).alpha)
            }
        }
        XCTAssertLessThan(worst, 0.01, "the ribbons painted \(worst) outside their canvas")
    }

    /// The ribbons are different colours, so the layers read as ribbons rather
    /// than as one wash.
    func testSilkRibbonsCarryDistinctHues() throws {
        let bitmap = try rasterise(
            plain(Self.constantSnapshot(level: 1), .silk, size: Self.wideCanvas),
            size: Self.wideCanvas
        )
        let column = bitmap.pixelsWide / 2
        var low = Double.infinity
        var high = -Double.infinity
        for y in 0..<bitmap.pixelsHigh {
            let pixel = colour(bitmap, column, y)
            guard pixel.alpha > 0.5 else { continue }
            low = min(low, pixel.red - pixel.blue)
            high = max(high, pixel.red - pixel.blue)
        }
        print(String(format: "SILK centre column red-blue range %.3f", high - low))
        XCTAssertGreaterThan(high - low, 0.08, "the centre column carried one hue")
    }
}

// MARK: - Halo

extension VisualizerRedesignTests {
    /// The near half of every ring is drawn over the core and the far half
    /// under it, and a particle's depth is what puts it in one or the other.
    func testHaloFrontParticlesOccludeTheCore() {
        let order = HUDWaveform.Halo.layerOrder
        guard let core = order.firstIndex(of: .core) else {
            return XCTFail("the core is not in the halo's draw order")
        }
        for ring in 0..<HUDWaveform.Halo.ringCount {
            guard let back = order.firstIndex(of: .ringBack(ring)),
                  let front = order.firstIndex(of: .ringFront(ring))
            else {
                return XCTFail("ring \(ring) is not in the halo's draw order")
            }
            XCTAssertLessThan(back, core, "ring \(ring)'s far half is drawn over the core")
            XCTAssertGreaterThan(front, core, "ring \(ring)'s near half is drawn under the core")
        }
        print("HALO draw order \(order)")

        // The two halves are the two hemispheres of one circle: the pole that
        // leans toward the viewer is in front of the core and the pole opposite
        // it is behind, one diameter apart on the screen.
        let orientation = HUDWaveform.Halo.orientation(
            ring: 0,
            time: 1.75,
            energy: 1,
            width: Self.canvas.width,
            height: Self.canvas.height
        )
        let near = HUDWaveform.Halo.point(orientation: orientation, theta: .pi / 2, centre: .zero)
        let far = HUDWaveform.Halo.point(orientation: orientation, theta: 3 * .pi / 2, centre: .zero)
        print(String(
            format: "HALO near pole %.2f pt below the centre at depth %.2f, far pole at depth %.2f",
            near.point.y,
            near.depth,
            far.depth
        ))
        XCTAssertGreaterThan(near.depth, 0, "the near pole of a ring is behind the core")
        XCTAssertLessThan(far.depth, 0, "the far pole of a ring is in front of the core")
        XCTAssertGreaterThan(near.point.y, 0, "the near pole does not stand below the centre")
        XCTAssertEqual(near.point.y, -far.point.y, accuracy: 1e-9, "the two poles are not one diameter")
    }

    /// The rings grow with the voice: a silent halo is a much narrower picture
    /// than a loud one.
    func testHaloRingsGrowWithTheVoice() throws {
        let quiet = try rasterise(
            plain(Self.syntheticTake("silence").at(1.0), .haloEdge, size: Self.wideCanvas),
            size: Self.wideCanvas
        )
        let loud = try rasterise(
            plain(Self.constantSnapshot(level: 1, ceiling: 0.85), .haloEdge, size: Self.wideCanvas),
            size: Self.wideCanvas
        )
        let quietWidth = inkColumns(quiet).map { $0.max - $0.min } ?? 0
        let loudWidth = inkColumns(loud).map { $0.max - $0.min } ?? 0
        print(String(format: "HALO width at silence %.2f pt, at full voice %.2f pt", quietWidth, loudWidth))
        XCTAssertGreaterThan(loudWidth, 0, "the loud halo drew nothing")
        XCTAssertLessThan(quietWidth / loudWidth, 0.75, "the silent rings keep \(quietWidth / loudWidth) of the loud width")
    }

    /// A silent halo draws its core and its rings inside the canvas, and the
    /// room it keeps is the fit's own room: a ring at rest tumbles open as wide
    /// as the widest tilt the canvas holds, so silence is not a smaller picture
    /// than a syllable but one drawn at the open end of its tumble.
    func testHaloSilenceStaysInsideItsCanvas() throws {
        let margin: CGFloat = 24
        let outer = CGSize(width: Self.canvas.width + margin * 2, height: Self.canvas.height + margin * 2)
        let bitmap = try rasterise(
            inset(Self.syntheticTake("silence").at(1.0), .haloEdge, size: Self.canvas, margin: margin),
            size: outer
        )
        let measured = extent(bitmap, canvas: Self.canvas, margin: margin)
        let bound = HUDWaveform.Halo.extentLimit(height: Self.canvas.height)
            + HUDWaveform.Halo.maximumParticleRadius
        print(String(
            format: "HALO silence half extent %.2f pt of %.2f, width %.2f pt, outside %.4f",
            measured.half,
            bound,
            measured.width,
            measured.outside
        ))
        XCTAssertLessThanOrEqual(measured.half, Double(bound), "the resting halo stood \(measured.half) pt off the centre line")
        XCTAssertLessThan(measured.outside, 0.01, "the resting halo painted \(measured.outside) outside its canvas")
        XCTAssertGreaterThan(litPixels(bitmap), 0, "the resting halo drew nothing at all")
    }

    /// A loud halo reaches the height its own rings are drawn at and paints
    /// nothing outside the canvas, on the card's canvas and on a tile's.
    ///
    /// The height is the model's rather than a constant: the widest ring's
    /// projected half extent at the moment drawn, which the fit solves for. The
    /// ink may stand a particle's radius beyond it, or the sun's glow may reach
    /// further, so the bound is the further of the two: the glow is drawn to
    /// ``HUDWaveform/Halo/glowReach`` radii of the elastic core radius at that tick,
    /// and its own ink is gone by then. What keeps that from being a licence to
    /// clip is ``HaloMotionTests/testHaloRingsFitTheCanvas``: the loudest frame's
    /// outermost half point must carry no ink at all.
    func testHaloLoudRingsFillTheirCanvas() throws {
        let margin: CGFloat = 24
        let snapshot = Self.constantSnapshot(level: 1, ceiling: 0.85)
        for size in [Self.canvas, Self.tileCanvas] {
            let outer = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
            let bitmap = try rasterise(
                inset(snapshot, .haloEdge, size: size, margin: margin),
                size: outer
            )
            let measured = extent(bitmap, canvas: size, margin: margin)
            var ringExtent = 0.0
            for ring in 0..<HUDWaveform.Halo.ringCount {
                let energy = HUDWaveform.Halo.ringEnergy(ring, history: snapshot.history)
                let orientation = HUDWaveform.Halo.orientation(
                    ring: ring,
                    time: 1.75,
                    energy: energy,
                    width: size.width,
                    height: size.height
                )
                let radius = Double(orientation.radius)
                let node = orientation.node
                let room = pow(sin(node), 2) + pow(cos(orientation.inclination) * cos(node), 2)
                ringExtent = max(ringExtent, radius * room.squareRoot())
            }
            let reach = Double(HUDWaveform.Halo.maximumParticleRadius)
            let coreRadius = Double(HUDWaveform.Halo.elasticCoreRadius(
                history: snapshot.history,
                time: 1.75
            ))
            let glow = Double(HUDWaveform.Halo.glowReach) * coreRadius
            let bound = max(ringExtent + reach, glow)
            print(String(
                format: "HALO loud half extent %.2f pt of %.2f, ring extent %.2f pt, "
                    + "glow reach %.2f pt, bound %.2f pt, width %.2f pt, outside %.4f",
                measured.half,
                Double(size.height) / 2,
                ringExtent,
                glow,
                bound,
                measured.width,
                measured.outside
            ))
            XCTAssertGreaterThanOrEqual(
                measured.half,
                ringExtent,
                "the loud halo reached \(measured.half) pt of the \(ringExtent) pt its rings stand at"
            )
            XCTAssertLessThanOrEqual(
                measured.half,
                bound,
                "the loud halo painted \(measured.half - bound) pt beyond its rings and its glow"
            )
            XCTAssertLessThan(measured.outside, 0.01, "the loud halo painted \(measured.outside) outside its canvas")
        }
    }

    /// The rings turn: two moments half a second apart are different pictures.
    func testHaloOrbitsBetweenTwoMoments() throws {
        let snapshot = Self.constantSnapshot(level: 1, ceiling: 0.85)
        let first = try rasterise(plain(snapshot, .haloEdge, time: 0.75), size: Self.canvas)
        let second = try rasterise(plain(snapshot, .haloEdge, time: 1.25), size: Self.canvas)
        let difference = meanAlphaDifference(first, second)
        print(String(format: "HALO orbit mean alpha difference %.4f", difference))
        XCTAssertGreaterThan(difference, 0.002, "the rings turned by only \(difference)")
        XCTAssertLessThan(difference, 0.35, "the rings flashed by \(difference)")
    }

    /// A halo drawn without motion is the same picture whatever the clock says.
    func testHaloReduceMotionIgnoresTheClock() throws {
        let snapshot = Self.syntheticTake("calm").at(3.10)
        let first = try rasterise(plain(snapshot, .haloEdge, time: 0, reduceMotion: true), size: Self.canvas)
        let second = try rasterise(plain(snapshot, .haloEdge, time: 5, reduceMotion: true), size: Self.canvas)
        XCTAssertGreaterThan(litPixels(first), 0, "the reduced-motion halo drew nothing")
        XCTAssertEqual(worstAlphaDifference(first, second), 0, "the reduced-motion halo moved between two clocks")
    }
}

// MARK: - The material tile

extension VisualizerRedesignTests {
    /// The material tile is the real card, not a redrawn one.
    ///
    /// The guard is on the source, because the drift it prevents is a second
    /// drawing of the card appearing in Settings: a tile with a backdrop of its
    /// own is a sixth material rather than a preview of the two the app ships.
    func testMaterialTileIsTheRealCard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/Dot/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settings.contains("HUDSurface(material: material"), "the tile draws the card's surface")
        XCTAssertTrue(settings.contains("LiveDot("), "the tile draws the card's live dot")
        XCTAssertTrue(settings.contains("HUDActionButton(action: .stop)"), "the tile draws the card's stop button")
        XCTAssertTrue(settings.contains("HUDActionButton(action: .cancel)"), "the tile draws the card's cancel button")
        XCTAssertTrue(
            settings.contains("history: VisualizerTile.history(at: VisualizerTile.stillTime)"),
            "the tile draws the card's waveform from the demonstration's own envelope"
        )
        XCTAssertTrue(
            settings.contains("spectrumHistory: VisualizerTile.spectrum(at: VisualizerTile.stillTime)"),
            "the tile draws the card's waveform from the demonstration's own bands"
        )
        XCTAssertFalse(settings.contains("bars:"), "the tile hands the waveform a row of its own")
        XCTAssertFalse(settings.contains("stretchRow"), "the tile keeps a frozen row of its own")
        XCTAssertTrue(settings.contains("HUDState.recordingWidth"), "the tile lays the card out at its real size")
        XCTAssertFalse(settings.contains("ultraThinMaterial"), "the tile's fake frost is gone")
        XCTAssertFalse(settings.contains("HUDSwatchWaveform"), "the tile's drawn bars are gone")
    }

    /// The material tile draws the card's row, from the demonstration it already
    /// draws.
    ///
    /// The tile used to hand the waveform a frozen twenty-one bar row of its own,
    /// while the card's row is a measurement of the same dictation on the same
    /// clock. The row is now the view's own arithmetic over the envelope and the
    /// bands the tile draws, which is the row the visualizer tile draws and the
    /// row the card draws: one picture of one voice.
    func testTheMaterialTileDrawsTheCardsStretchRow() {
        let moment = VisualizerTile.stillTime
        let row = HUDWaveform.Stretch.bars(
            history: VisualizerTile.history(at: moment),
            phase: DictationScript.phase(at: moment),
            time: moment,
            reveal: 1,
            canvas: Self.canvas.width,
            reduceMotion: false
        )
        print("TILE stretch row \(row.count) bars " + row.map { String(format: "%.3f", $0.value) }.joined(separator: " "))
        XCTAssertGreaterThan(row.count, 8, "the tile draws a row of the card's density")
        XCTAssertEqual(row.filter(\.isLive).count, 1, "the tile draws one live edge, as the card does")

        // A row of real measurements: a tile frozen in the breath before the
        // first syllable would be a picture of silence at the loudest one, and a
        // flat row is what a single level drawn across the tile looks like.
        XCTAssertFalse(
            VisualizerTile.history(at: moment).isEmpty,
            "the tile has no history, so the row carries no sound"
        )
        let heights = Set(row.map { Int(($0.value * 20).rounded()) })
        XCTAssertGreaterThanOrEqual(heights.count, 4, "the tile's row has fewer than four heights in it")
        XCTAssertGreaterThan(row.map(\.value).max() ?? 0, 0.4, "the tile's row is a picture of a quiet moment")
        // The bars stand one pitch apart and hold consecutive windows of the
        // voice, which is the card's grid rather than a row of the tile's own
        // spacing.
        let closed = HUDWaveform.Stretch.closedWindows(HUDWaveform.Stretch.newestSample(
            at: moment,
            phase: DictationScript.phase(at: moment)
        ))
        let settled = row.filter { !$0.isLive }
        XCTAssertEqual(settled.count, row.count - 1, "the tile draws one live edge and the rest behind it")
        for (rank, bar) in settled.enumerated() {
            XCTAssertEqual(bar.window, closed - rank, "bar \(rank) does not hold window \(closed - rank)")
            guard rank > 0 else { continue }
            XCTAssertEqual(
                Double(settled[rank - 1].centre - bar.centre),
                Double(HUDWaveform.Stretch.pitch),
                accuracy: 0.001,
                "bar \(rank) is not one pitch behind the bar in front of it"
            )
        }
    }
}

// MARK: - The preview's pace

extension VisualizerRedesignTests {
    /// What the drawn envelope does, measured the way the audit measured it.
    struct Pace {
        var dominant: Double
        var step: Double
        var stepPerSecond: Double
        var drawn: [Double]
    }

    /// Runs a level function through the preview's meter and measures the result.
    static func pace(level: (Double) -> Double, duration: Double) -> Pace {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        var drawn: [Double] = []
        let ticks = Int((duration * Waveform.sampleRate).rounded())
        for tick in 0..<ticks {
            let time = Double(tick) / Waveform.sampleRate
            meter.push(decibels: -58 + level(time) * 50, now: time)
            drawn.append(meter.shape)
        }
        return measure(drawn)
    }

    /// The dominant modulation and the mean step of a drawn envelope.
    ///
    /// The periodogram runs from 0.5 to 4 Hz with a Hann window, so the ends of
    /// the loop do not leak a low-frequency peak into the answer.
    static func measure(_ drawn: [Double]) -> Pace {
        let mean = drawn.reduce(0, +) / Double(max(1, drawn.count))
        let centred = drawn.map { $0 - mean }
        var best = 0.0
        var bestPower = -1.0
        let rate = Waveform.sampleRate
        var frequency = 0.5
        while frequency <= 4.0 {
            var real = 0.0
            var imaginary = 0.0
            for (index, value) in centred.enumerated() {
                let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(max(1, centred.count - 1)))
                let phase = 2 * Double.pi * frequency * Double(index) / rate
                real += value * window * cos(phase)
                imaginary += value * window * sin(phase)
            }
            let power = real * real + imaginary * imaginary
            if power > bestPower {
                bestPower = power
                best = frequency
            }
            frequency += 0.01
        }
        var step = 0.0
        for index in 1..<drawn.count {
            step += abs(drawn[index] - drawn[index - 1])
        }
        step /= Double(max(1, drawn.count - 1))
        return Pace(dominant: best, step: step, stepPerSecond: step * rate, drawn: drawn)
    }

    /// The preview draws a dictation, not the tour's sentence.
    ///
    /// The demonstration the island's preview and the Settings tiles draw is
    /// ``DictationScript``: five phrases, thirty three syllables, twenty six
    /// words. The tour's seven word line is still drawn by the tour, and the two
    /// are not the same signal, so a preview that went back to the tour's
    /// schedule would be drawing a sentence at a tempo no one dictates at.
    func testThePreviewDrawsTheDictationScript() {
        XCTAssertEqual(DictationScript.syllables.count, 33)
        XCTAssertEqual(DictationScript.wordCount, 26)
        XCTAssertGreaterThan(DictationScript.syllables.count, DictationScript.wordCount)
        let groups = Dictionary(grouping: DictationScript.syllables, by: \.wordIndex)
        for word in 0..<DictationScript.wordCount {
            XCTAssertGreaterThanOrEqual(groups[word]?.count ?? 0, 1, "word \(word) is never said")
        }
        XCTAssertEqual(Set(DictationScript.syllables.map(\.phrase)).count, 5, "five phrases")

        XCTAssertEqual(HUD.previewDismissDelay, DictationScript.loop)
        XCTAssertEqual(HUD.previewOffset, 0.4)
        XCTAssertEqual(VisualizerTile.loop, DictationScript.loop)
        XCTAssertEqual(VisualizerTile.stillTime, DictationScript.stillTime)
        // The preview's clock is the script's: half a loop in, the phase is half
        // a loop in.
        XCTAssertEqual(
            HUD.previewPhase(now: 20 + DictationScript.loop / 2, startedAt: 20),
            HUD.previewOffset + DictationScript.loop / 2,
            accuracy: 1e-9
        )
    }

    /// The drawn envelope is made of phrases and syllables, and not of a
    /// tremolo.
    ///
    /// This is the measurement behind the change. The old preview drew nine
    /// syllables over four and a half seconds and multiplied the level by four
    /// sine waves at up to nine hertz for its bands, so the eye read the fast
    /// half. The dictation is thirty three syllables over eleven seconds at a
    /// hundred and forty words a minute, and what dominates the drawn trace is
    /// the phrase rhythm, about one cycle a second, with the syllables inside it.
    func testTheDrawnPreviewMovesAtTheSyllableRate() {
        let preview = Self.pace(level: { DictationScript.level(at: $0) }, duration: DictationScript.loop)
        let reference = Self.measure(Self.syntheticTake("calm").ticks.map { $0.level })
        let crests = Self.crests(in: preview.drawn)
        print(String(
            format: "PREVIEW pace %.2f Hz step %.3f per frame %.2f per s, %d crests over %.2f s, %d syllables (generated calm take %.2f Hz, %.2f per s)",
            preview.dominant,
            preview.step,
            preview.stepPerSecond,
            crests,
            DictationScript.loop,
            DictationScript.syllables.count,
            reference.dominant,
            reference.stepPerSecond
        ))
        // The phrases: five of them over eleven seconds of speech, which is what
        // a periodogram of the whole loop finds first. Anything faster than this
        // is the syllable rhythm, and the meter's own release is what keeps the
        // drawn trace from showing the tremolo the old preview had.
        XCTAssertLessThanOrEqual(preview.dominant, 2.0, "the demonstration modulates at \(preview.dominant) Hz")
        XCTAssertLessThanOrEqual(preview.step, 0.06, "a frame steps by \(preview.step)")
        // Every syllable of the script is a crest in the drawing. The two
        // closest pairs of a word merge under the meter's release, so the count
        // is allowed to be a few short of thirty three and never more.
        XCTAssertTrue((26...33).contains(crests), "the drawn trace has \(crests) crests for 33 syllables")
    }

    /// How many crests a drawn envelope has.
    ///
    /// A crest is a sample higher than the four either side of it and above a
    /// fifth of the range: the meter's release leaves a small ripple on a
    /// sustained vowel, and those are not syllables.
    static func crests(in drawn: [Double]) -> Int {
        guard drawn.count > 8 else { return 0 }
        var count = 0
        for index in 4..<(drawn.count - 4) {
            let value = drawn[index]
            guard value > 0.2 else { continue }
            let neighbours = drawn[(index - 4)...(index - 1)] + drawn[(index + 1)...(index + 4)]
            if neighbours.allSatisfy({ $0 < value }) {
                count += 1
            }
        }
        return count
    }

    /// The dismissal, the preview's clock and the tile are one measurement.
    func testThePreviewDismissalIsOneLoop() {
        XCTAssertEqual(DictationScript.resting, 0.6)
        XCTAssertEqual(
            HUD.previewDismissDelay,
            DictationScript.duration + DictationScript.resting,
            accuracy: 1e-9
        )
        XCTAssertEqual(VisualizerTile.loop, HUD.previewDismissDelay, "the tile and the island draw one loop")
        XCTAssertGreaterThan(VisualizerTile.stillTime, DictationScript.leadIn)
        XCTAssertLessThan(VisualizerTile.stillTime, DictationScript.duration)
    }
}

// MARK: - Evidence

extension VisualizerRedesignTests {
    /// Writes the cards, the canvases, the motion strips and the preview frames
    /// for a design review.
    ///
    /// Skipped unless `DOT_VISUALIZER_EVIDENCE` names a directory. The takes are
    /// generated in memory, so the renders need no speech file; a real recording
    /// is used for the speech canvas when `DOT_VISUALIZER_AUDIO` names one.
    func testEvidenceRenders() throws {
        guard let directory = Self.evidence else {
            throw XCTSkip("DOT_VISUALIZER_EVIDENCE is not set")
        }
        let cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        let silence = Self.syntheticTake("silence").at(1.0)
        let loud = Self.constantSnapshot(level: 1, ceiling: 0.85)
        let rebuilt: [HUDVisualizer] = [.stretch, .filament, .haloEdge]

        for name in ["calm", "energetic"] {
            let take = Self.syntheticTake(name)
            for visualizer in rebuilt {
                for moment in Self.moments {
                    try render(
                        card(take.at(moment), visualizer, time: moment),
                        size: cardSize,
                        named: String(format: "%@-card-%@-t%.2f.png", Self.slug(visualizer), name, moment)
                    )
                }
            }
        }
        // Every style on one sheet, at one moment. The moment is a moment of the
        // demonstration the preview draws, so the sheet is one picture per style
        // rather than a second name for a frame of a contact sheet.
        let calm = Self.syntheticTake("calm")
        for visualizer in HUDVisualizer.allCases {
            try render(
                card(Self.previewSnapshot(at: 1.5), visualizer, time: 1.5),
                size: cardSize,
                named: "all-\(Self.slug(visualizer))-t1.50.png"
            )
        }

        let speech = (try? Self.audioTake("calm"))?.at(1.5) ?? calm.at(1.5)
        for visualizer in rebuilt {
            try render(
                card(silence, visualizer, time: 1.0),
                size: cardSize,
                named: "\(Self.slug(visualizer))-card-silence.png"
            )
            try render(
                card(loud, visualizer, time: 1.5),
                size: cardSize,
                named: "\(Self.slug(visualizer))-card-loud.png"
            )
            let cases: [(String, Snapshot)] = [
                ("silence", silence),
                ("speech", speech),
                ("loud", loud),
            ]
            for entry in cases {
                try render(
                    plain(entry.1, visualizer, time: 1.5),
                    size: Self.canvas,
                    named: "\(Self.slug(visualizer))-canvas-\(entry.0).png"
                )
            }
            // Ten frames a thirtieth of a second apart, stacked into one strip.
            try strip(calm, visualizer, size: Self.canvas, named: "\(Self.slug(visualizer))-strip.png")
        }
        // The Settings page the tiles live on.
        try UIPreview.renderSettings(to: directory)
        // The preview's own frames, spread over its loop and starting after the
        // lead-in: the first second of the script is the room before the first
        // syllable, and a still of it would be a still of silence.
        for step in 0..<8 {
            let time = DictationScript.loop * (Double(step) + 1) / 9
            let snapshot = Self.previewSnapshot(at: time)
            try render(
                card(snapshot, .filament, time: time),
                size: cardSize,
                named: String(format: "preview-t%.2f.png", time)
            )
        }
    }

    /// Ten frames of one style, a thirtieth of a second apart, stacked into one
    /// picture so the motion can be read as a sequence.
    @discardableResult
    func strip(
        _ take: Take,
        _ visualizer: HUDVisualizer,
        size: CGSize,
        named name: String
    ) throws -> NSBitmapImageRep {
        let count = 10
        let frames = try (0..<count).map { index -> NSBitmapImageRep in
            let time = 1.5 + Double(index) / 30
            return try rasterise(plain(take.at(time), visualizer, time: time, size: size), size: size)
        }
        let strip = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * Self.scale,
            pixelsHigh: Int(size.height) * Self.scale * count,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the strip could not be allocated")
        strip.size = CGSize(width: size.width, height: size.height * CGFloat(count))
        if let data = strip.bitmapData {
            memset(data, 0, strip.bytesPerRow * strip.pixelsHigh)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
        for (index, frame) in frames.enumerated() {
            let rect = NSRect(
                x: 0,
                y: CGFloat(count - 1 - index) * size.height,
                width: size.width,
                height: size.height
            )
            _ = frame.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let directory = Self.evidence else { return strip }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(strip.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return strip
    }

    /// The card's state at a moment of the demonstration the preview draws.
    ///
    /// The preview draws ``DictationScript``, so a still of it is a moment of
    /// that script rather than of the tour's sentence.
    static func previewSnapshot(at time: Double) -> Snapshot {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        var spectrum = SpectrumPipeline()
        var history: [Double] = []
        let ticks = max(1, Int((time * Waveform.sampleRate).rounded()))
        for tick in 0...ticks {
            let moment = Double(tick) / Waveform.sampleRate
            let voice = DictationScript.level(at: moment)
            meter.push(decibels: -58 + voice * 50, now: moment)
            let bands = AudioSpectrumFrame(bands: (
                min(1, voice * 0.92),
                min(1, voice * 0.80),
                min(1, voice * 0.70),
                min(1, voice * 0.76),
                min(1, voice * 0.58)
            ))
            spectrum.advance(target: bands, dt: 1.0 / Waveform.sampleRate)
            history = meter.orderedHistory
        }
        return Snapshot(
            history: history,
            spectrum: spectrum.ring,
            ceiling: meter.ceiling,
            level: meter.level,
            phase: meter.phase
        )
    }

    func testStretchAndSilkExpandDynamicRangeBetweenMediumAndLoudSpeech() {
        let stretch = HUDWaveform.Stretch.self
        let silentBar = stretch.bars(
            history: [Double](repeating: 0, count: Waveform.historyLength),
            phase: 0,
            time: 2.0,
            reveal: 1,
            canvas: Self.wideCanvas.width,
            reduceMotion: true
        ).first
        let mediumBar = stretch.bars(
            history: [Double](repeating: 0.58, count: Waveform.historyLength),
            phase: 0,
            time: 2.0,
            reveal: 1,
            canvas: Self.wideCanvas.width,
            reduceMotion: true
        ).first
        let loudBar = stretch.bars(
            history: [Double](repeating: 0.85, count: Waveform.historyLength),
            phase: 0,
            time: 2.0,
            reveal: 1,
            canvas: Self.wideCanvas.width,
            reduceMotion: true
        ).first
        let fullBar = stretch.bars(
            history: [Double](repeating: 1.0, count: Waveform.historyLength),
            phase: 0,
            time: 2.0,
            reveal: 1,
            canvas: Self.wideCanvas.width,
            reduceMotion: true
        ).first

        XCTAssertEqual(Double(silentBar?.height ?? 0), Double(stretch.minHeight), accuracy: 1e-6)
        XCTAssertEqual(Double(fullBar?.height ?? 0), Double(stretch.maxHeight), accuracy: 1e-6)
        let medHeight = Double(mediumBar?.height ?? 0)
        let loudHeight = Double(loudBar?.height ?? 0)
        XCTAssertGreaterThan(medHeight, Double(stretch.minHeight))
        XCTAssertGreaterThan(loudHeight / medHeight, 1.8)

        let silk = HUDWaveform.Silk.self
        for ribbon in 0..<silk.ribbonCount {
            XCTAssertLessThanOrEqual(
                silk.thicknessShare[ribbon] + silk.centreShare[ribbon],
                1.0 + 1e-9,
                "ribbon \(ribbon) shares overflow canvas reach"
            )
        }
        let reach = silk.reach(forHeight: Self.wideCanvas.height)
        func peakExcursion(energy: Double) -> Double {
            var peak = 0.0
            for index in 0..<silk.sampleCount {
                let u = Double(index) / Double(silk.sampleCount - 1)
                let taper = silk.cachedEdges[index]
                let centre = abs(silk.centreOffset(ribbon: 0, u: u, energy: energy, reach: reach, time: 1.75, taper: taper))
                let half = silk.halfThickness(ribbon: 0, u: u, energy: energy, reach: reach, time: 1.75, taper: taper)
                peak = max(peak, Double(centre + half))
            }
            return peak
        }
        let silkMedium = peakExcursion(energy: 0.58)
        let silkLoud = peakExcursion(energy: 0.85)
        XCTAssertGreaterThan(silkLoud / silkMedium, 1.8)
    }
}
