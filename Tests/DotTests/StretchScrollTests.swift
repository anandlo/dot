import AppKit
import CryptoKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The scrolling row of the Stretch visualizer.
///
/// The row is a value, `HUDWaveform.Stretch.bars`, so every rule of it can be
/// measured without a screen: its speed, its continuity across a window
/// boundary, the way one loud moment enters at the right edge and travels left,
/// the spring of that edge, its fade, and the still row a person who asked for
/// no motion is given. The last three tests check the picture itself: the reach
/// of the glow inside the canvas, the dashes of a silent row, and a pair of
/// reduced-motion renders that must be the same bytes.
///
/// No window is ever put on a display: each view is hosted in an
/// ``OffscreenWindow`` at `-20000` and captured with `cacheDisplay`, exactly as
/// ``VisualizerRedesignTests`` does.
@MainActor
final class StretchScrollTests: XCTestCase {
    /// The card's waveform canvas, in points.
    static let canvas = CGSize(width: 102, height: 26)
    /// The pixels per point of every render.
    static let scale = 2

    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    // MARK: - The row

    /// The row `Stretch` draws for a history at a moment.
    func row(
        _ history: [Double],
        time: Double,
        phase: Double = 0,
        ceiling: Double = 1,
        canvas: CGFloat = StretchScrollTests.canvas.width,
        reduceMotion: Bool = false
    ) -> [HUDWaveform.Stretch.Bar] {
        HUDWaveform.Stretch.bars(
            history: history,
            ceiling: ceiling,
            phase: phase,
            time: time,
            reveal: 1,
            canvas: canvas,
            reduceMotion: reduceMotion
        )
    }

    /// A voice shaped like speech: five syllables of a phrase over a floor that
    /// never quite reaches zero.
    static func voiced() -> [Double] {
        let count = Waveform.historyLength
        let spoken = Double(count) / Waveform.sampleRate
        return (0..<count).map { index in
            let time = Double(index) / Waveform.sampleRate
            guard time > spoken / 2 else { return 0 }
            let syllable = sin((time - spoken / 2) / 0.18 * .pi)
            return max(0, syllable) * (0.55 + 0.35 * sin(time * 3.1))
        }
    }

    /// A take whose newest `loud` samples are at the top of the range and whose
    /// past is silent.
    static func impulse(loud: Int) -> [Double] {
        var history = [Double](repeating: 0, count: Waveform.historyLength)
        for offset in 0..<max(0, loud) {
            history[history.count - 1 - offset] = 1
        }
        return history
    }

    // MARK: - S1 Speed

    /// The row runs at one pitch per window: `1.2` points on every tick, for every
    /// bar, and a fraction of that between two frames.
    func testS1TheRowScrollsOnePitchPerWindow() {
        let history = Self.voiced()
        let pitch = Double(HUDWaveform.Stretch.pitch)
        let speed = pitch / Double(HUDWaveform.Stretch.windowTicks)
        XCTAssertEqual(speed, 1.2, accuracy: 1e-12, "a window is three ticks of 1.2 points")

        // Ticks that open a window, that fill it, and that close it, each read at
        // three places inside the tick.
        for tick in [60, 61, 62, 63, 64, 65] {
            for phase in [0.0, 0.4, 0.75] {
                let time = (Double(tick) + phase) / Waveform.sampleRate
                // The next tick's moment is written from the tick, not as a sum:
                // adding a sixtieth to the same seconds lands below the boundary
                // in binary, and the row would be read twice on one tick.
                let later = (Double(tick + 1) + phase) / Waveform.sampleRate
                let now = row(history, time: time, phase: phase)
                let next = row(history, time: later, phase: phase)
                XCTAssertGreaterThan(now.count, 8, "the row is too short to measure")
                for bar in now {
                    guard let moved = next.first(where: { $0.window == bar.window }) else { continue }
                    XCTAssertEqual(
                        Double(bar.centre - moved.centre),
                        speed,
                        accuracy: 0.001,
                        "window \(bar.window) moved \(bar.centre - moved.centre) pt in one tick"
                    )
                }
            }
        }

        // Between two frames the row moves a third of a tick's distance: the
        // progress of the window is what is drawn, not the tick it belongs to.
        let start = row(history, time: 61.0 / Waveform.sampleRate, phase: 0)
        let half = row(history, time: 61.5 / Waveform.sampleRate, phase: 0.5)
        for bar in start {
            guard let moved = half.first(where: { $0.window == bar.window }) else { continue }
            XCTAssertEqual(
                Double(bar.centre - moved.centre),
                speed / 2,
                accuracy: 0.001,
                "half a tick moved window \(bar.window) by \(bar.centre - moved.centre) pt"
            )
        }
    }

    /// The row's speed does not depend on how far the two clocks the card reads
    /// are apart.
    ///
    /// The card's `time` is the display's clock and its `phase` is the meter's own
    /// fraction of a tick, and the two are not aligned: the offset between them is
    /// a constant set when the meter was made. The row is pinned to the meter,
    /// because that is the clock the samples were written on, so the same frames
    /// draw the same row at any offset and no offset steps it by more than the
    /// sub-tick it moved.
    func testS1TheRowIsPinnedToTheMetersClock() {
        let history = Self.voiced()
        for offset in [0.0, 0.31, 0.5, 0.83] {
            var previous: [HUDWaveform.Stretch.Bar] = []
            var worst = 0.0
            for step in 0...360 {
                // The meter's clock, in ticks, advanced a sixth of a tick a frame.
                let clock = Double(step) / 6
                let phase = clock - clock.rounded(.down)
                let time = (clock + offset) / Waveform.sampleRate
                let current = row(history, time: time, phase: phase)
                for bar in previous {
                    guard let moved = current.first(where: { $0.window == bar.window }) else { continue }
                    worst = max(worst, abs(Double(bar.centre - moved.centre)))
                }
                previous = current
            }
            XCTAssertLessThanOrEqual(
                worst,
                0.2 + 0.001,
                "a clock offset of \(offset) ticks stepped the row by \(worst) pt between two frames"
            )
        }
    }

    // MARK: - S2 Continuity

    /// Nothing jumps when a window closes: the last frame of one and the first of
    /// the next are the same picture, to within a hundredth of a point.
    func testS2TheRowDoesNotJumpAtAWindowBoundary() {
        let history = Self.voiced()
        // Tick 62 is the third tick of its window, so the next tick closes it.
        let before = row(history, time: 62.999 / Waveform.sampleRate, phase: 0.999)
        let after = row(history, time: 63.0 / Waveform.sampleRate, phase: 0)
        XCTAssertGreaterThan(before.count, 8, "the row is too short to measure")
        var matched = 0
        for bar in before {
            guard let moved = after.first(where: { $0.window == bar.window }) else { continue }
            matched += 1
            XCTAssertLessThan(
                abs(Double(bar.centre - moved.centre)),
                0.01,
                "window \(bar.window) jumped by \(bar.centre - moved.centre) pt at the window boundary"
            )
        }
        XCTAssertGreaterThan(matched, 8, "the two frames share only \(matched) bars")

        // And the whole row shifts smoothly: no step between two adjacent frames
        // of a sweep across three windows is larger than a tick's own step.
        var previous: [HUDWaveform.Stretch.Bar] = []
        var worst = 0.0
        for step in 0...180 {
            let time = 60.0 / Waveform.sampleRate + Double(step) / (Waveform.sampleRate * 6)
            let current = row(history, time: time, phase: Double(step % 6) / 6)
            for bar in previous {
                guard let moved = current.first(where: { $0.window == bar.window }) else { continue }
                worst = max(worst, abs(Double(bar.centre - moved.centre)))
            }
            previous = current
        }
        print(String(format: "STRETCH worst step between two frames %.4f pt", worst))
        XCTAssertLessThanOrEqual(worst, 0.2 + 0.001, "the row stepped by \(worst) pt between two frames")
    }

    // MARK: - S3 The newborn bar

    /// One loud window enters at the right edge and then travels left, one and a
    /// fifth points a tick, for thirty ticks.
    func testS3TheNewestWindowIsBornAtTheEdgeAndTravelsLeft() {
        // Tick 62 is the third tick of its window, so the three loud samples are
        // still in the window that is filling.
        let before = row(Self.impulse(loud: 2), time: 62.0 / Waveform.sampleRate)
        guard let live = before.first else {
            return XCTFail("the row drew nothing")
        }
        XCTAssertTrue(live.isLive, "the newest bar of the row is the live edge")
        XCTAssertEqual(
            live.value,
            before.map(\.value).max() ?? 0,
            accuracy: 1e-12,
            "the loud moment is not at the edge"
        )
        XCTAssertGreaterThan(live.value, 0, "a live edge holding a loud sample is not at nothing")

        // The next tick closes the window, and the bar that holds it starts its
        // walk to the left.
        let closed = 63
        var previousCentre: CGFloat?
        var travelled: [Double] = []
        var settled = 0
        for tick in closed..<(closed + 30) {
            let history = Self.impulse(loud: 3 + tick - closed)
            let row = row(history, time: Double(tick) / Waveform.sampleRate)
            let newest = HUDWaveform.Stretch.closedWindows(tick)
            guard let bar = row.first(where: { $0.window == 21 && !$0.isLive }) else {
                return XCTFail("the loud window left the canvas at tick \(tick)")
            }
            if bar.window < newest {
                // A window that has been closed for longer than one frame is drawn
                // at its own level; only the newest bar and the live edge carry the
                // spring, and it is the spring that swings past the top.
                XCTAssertEqual(bar.value, 0.85, accuracy: 1e-9, "the loud window is drawn at the take's top")
                let behind = row.filter { !$0.isLive && $0.window != newest }
                XCTAssertEqual(
                    behind.map(\.value).max() ?? 0,
                    bar.value,
                    accuracy: 1e-9,
                    "at tick \(tick) the loud moment is not the bar that holds it"
                )
                settled += 1
            }
            if let previousCentre {
                travelled.append(Double(previousCentre - bar.centre))
            }
            previousCentre = bar.centre
        }
        XCTAssertGreaterThan(settled, 20, "the loud window was measured behind the edge only \(settled) times")
        XCTAssertEqual(travelled.count, 29, "the walk was not measured at every tick")
        for (index, step) in travelled.enumerated() {
            XCTAssertEqual(step, 1.2, accuracy: 0.001, "tick \(index) of the walk moved \(step) pt")
        }
        XCTAssertEqual(
            travelled.reduce(0, +),
            29 * 1.2,
            accuracy: 0.001,
            "the bar travelled \(travelled.reduce(0, +)) pt in twenty-nine ticks"
        )
    }

    // MARK: - S4 The spring

    /// The spring of the newest edge answers a step the way the design says: it
    /// peaks about eight per cent over its target within a seventh of a second,
    /// and it has settled by half a second.
    func testS4TheEdgeSpringOvershootsWithinItsCeiling() {
        let target = 0.8
        let trail = HUDWaveform.Stretch.spring([0] + [Double](repeating: target, count: 60))
        guard let peak = trail.max(), let at = trail.firstIndex(of: peak) else {
            return XCTFail("the spring answered nothing")
        }
        let peakTime = Double(at) / Waveform.sampleRate
        print(String(
            format: "STRETCH spring peak %.4f at %.3f s, %.2f %% over the step",
            peak,
            peakTime,
            (peak / target - 1) * 100
        ))
        XCTAssertGreaterThan(peak, 0.84, "the spring peaked at \(peak): it does not overshoot")
        XCTAssertLessThan(peak, 0.88, "the spring peaked at \(peak): it overshoots too far")
        XCTAssertLessThanOrEqual(peakTime, 0.15, "the spring peaked at \(peakTime) s")
        // Half a second after the step, at tick thirty-one, every reading is
        // inside two per cent of the target.
        for value in trail[31...] {
            XCTAssertEqual(value, target, accuracy: 0.02 * target, "the spring had not settled at \(value)")
        }
    }

    // MARK: - S5 Silence

    /// Silence is a hairline in every bar, and the picture of it is a set of
    /// dashes: no column of the row is as tall as a dot.
    func testS5SilenceIsADashedHairline() throws {
        let silence = [Double](repeating: 0, count: Waveform.historyLength)
        let row = row(silence, time: 2.0)
        XCTAssertGreaterThan(row.count, 8, "the row is too short to measure")
        for bar in row {
            XCTAssertEqual(
                Double(bar.height),
                Double(HUDWaveform.Stretch.minHeight),
                accuracy: 0.01,
                "a silent bar is \(bar.height) pt tall"
            )
            XCTAssertEqual(bar.value, 0, accuracy: 1e-9, "a silent bar carries a level")
        }

        // The picture: every run of inked columns is a dash, wider than it is tall.
        // The threshold sits below the faintest ink of a resting bar, which is a
        // sixth of the ramp's own opacity, so a dash's own antialiased edge counts
        // as the dash rather than as a gap.
        let bitmap = try rasterise(plain(silence, time: 2.0), size: Self.canvas)
        var runs: [(width: Int, height: Int)] = []
        var width = 0
        var height = 0
        for x in 0..<bitmap.pixelsWide {
            let extent = inkExtent(bitmap, column: x, threshold: 0.004)
            if extent > 0 {
                width += 1
                height = max(height, extent)
            } else if width > 0 {
                runs.append((width, height))
                width = 0
                height = 0
            }
        }
        if width > 0 { runs.append((width, height)) }
        XCTAssertGreaterThan(runs.count, 8, "a silent row is \(runs.count) dashes")
        for (index, dash) in runs.enumerated() {
            XCTAssertLessThanOrEqual(
                dash.height,
                2,
                "dash \(index) is \(dash.height) pixels tall, which is not a one point hairline"
            )
            XCTAssertGreaterThan(
                dash.width,
                dash.height,
                "dash \(index) is \(dash.width) by \(dash.height) pixels, which is a dot"
            )
        }
    }

    // MARK: - S6 The fade

    /// The ink arrives from the left edge: a bar on the edge carries a sixth of
    /// it, and a bar past half the canvas carries all of it.
    func testS6TheInkFadesToTheLeft() {
        let stretch = HUDWaveform.Stretch.self
        XCTAssertEqual(stretch.ink(age: 0), 0.16, accuracy: 1e-12, "the left edge is at a sixth of the ink")
        XCTAssertEqual(stretch.ink(age: 0.55), 1, accuracy: 1e-12, "the fade has finished by 0.55")
        XCTAssertEqual(stretch.ink(age: 1), 1, accuracy: 1e-12, "the newest ink is full ink")
        var previous = 0.0
        for step in 0...100 {
            let value = stretch.ink(age: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous, "the ink dipped at \(step)")
            previous = value
        }

        // And the row itself: its oldest bar is dimmer than its newest.
        let row = row(Self.voiced(), time: 5.0)
        guard let newest = row.first, let oldest = row.last else {
            return XCTFail("the row drew nothing")
        }
        XCTAssertEqual(newest.ink, 1, accuracy: 0.05, "the newest bar is not at full ink")
        XCTAssertEqual(oldest.ink, 0.16, accuracy: 0.05, "the oldest bar is not at the floor")
        XCTAssertLessThan(oldest.ink, newest.ink, "the row does not fade")
    }

    // MARK: - S7 The glow

    /// The glow of the live edge is held inside the canvas: the loudest moment
    /// leaves the outermost half point of the row untouched.
    func testS7TheLiveGlowFitsTheCanvas() throws {
        let stretch = HUDWaveform.Stretch.self
        XCTAssertEqual(Double(stretch.glowHeight(24)), 25, accuracy: 1e-9, "a full bar's glow is held at 25 pt")
        XCTAssertEqual(Double(stretch.glowHeight(10)), 11.5, accuracy: 1e-9, "a quiet glow is 1.15 of its bar")
        XCTAssertEqual(
            Double(stretch.glowHeight(stretch.maxHeight * CGFloat(stretch.springCeiling))),
            25,
            accuracy: 1e-9,
            "the glow of an overshooting bar is held at 25 pt"
        )

        // A loudest moment of a loudest take: level and ceiling at one, so every
        // bar is drawn at the top of its range and the glow is at its tallest.
        let history = [Double](repeating: 1, count: Waveform.historyLength)
        let bitmap = try rasterise(plain(history, time: 4.0, phase: 0.3, ceiling: 0.85), size: Self.canvas)
        XCTAssertGreaterThan(litPixels(bitmap), 0, "the loud row drew nothing")
        for x in 0..<bitmap.pixelsWide {
            for y in [0, bitmap.pixelsHigh - 1] {
                XCTAssertLessThan(
                    colour(bitmap, x, y).alpha,
                    0.02,
                    "the loud row painted the outermost half point of the canvas at (\(x), \(y))"
                )
            }
        }
        // The row is loud, not merely absent: its ink reaches most of the canvas.
        XCTAssertGreaterThanOrEqual(halfExtent(bitmap), Double(Self.canvas.height) / 2 - 1.5)
    }

    // MARK: - S8 Reduced motion

    /// A reduced-motion row is the same bytes at any clock: the shape is a
    /// measurement, not a film.
    func testS8ReducedMotionIsAByteIdenticalPair() throws {
        let snapshot = VisualizerRedesignTests.previewSnapshot(at: 5.0)
        let first = try PNG(try rasterise(
            plain(snapshot.history, time: 1.0, reduceMotion: true),
            size: Self.canvas
        ))
        let second = try PNG(try rasterise(
            plain(snapshot.history, time: 5.0, reduceMotion: true),
            size: Self.canvas
        ))
        let firstHash = Self.hash(first)
        let secondHash = Self.hash(second)
        print("STRETCH reduced motion t1.00 \(firstHash) \(first.count) bytes")
        print("STRETCH reduced motion t5.00 \(secondHash) \(second.count) bytes")
        XCTAssertEqual(firstHash, secondHash, "the reduced-motion row moved between two clocks")
        XCTAssertEqual(first, second)

        // And the still row is a picture: the held voice, on the grid, with no
        // live edge to travel.
        let row = row(snapshot.history, time: 1.0, reduceMotion: true)
        XCTAssertGreaterThan(row.count, 8, "the still row is too short to measure")
        XCTAssertFalse(row.contains { $0.isLive }, "a still row draws a live edge")
        for (rank, bar) in row.enumerated() {
            XCTAssertEqual(bar.window, rank, "a still row is numbered from its newest bar")
        }
        XCTAssertGreaterThan(row.map(\.value).max() ?? 0, 0.2, "a still of a voice is a row of nothing")
    }

    // MARK: - S9 The tiles

    /// Both Settings tiles draw the card's style through the card's own view: no
    /// file in the app hands the visualizer a row of heights.
    func testS9TheTilesDrawTheStyleThroughTheWaveformView() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/Dot/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            settings.contains("history: VisualizerTile.history(at: VisualizerTile.stillTime)"),
            "the material tile does not draw the demonstration's envelope"
        )
        XCTAssertTrue(
            settings.contains("spectrumHistory: VisualizerTile.spectrum(at: VisualizerTile.stillTime)"),
            "the material tile does not draw the demonstration's bands"
        )
        XCTAssertFalse(settings.contains("stretchRow"), "the material tile keeps a row of its own")

        // The argument is gone from the app, not only from the tile: a row passed
        // in is a row that can drift from the one the view computes.
        var files = 0
        for folder in ["Sources/Dot", "Sources/DotCore"] {
            let directory = root.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".swift") {
                files += 1
                let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                XCTAssertFalse(source.contains("bars:"), "\(folder)/\(name) still hands over a row of heights")
            }
        }
        XCTAssertGreaterThan(files, 20, "the sources were not found: \(files) files")
    }


    // MARK: - Evidence

    /// Writes the pictures a reviewer reads the row from.
    ///
    /// Skipped unless `DOT_VISUALIZER_EVIDENCE` names a directory, the way
    /// ``VisualizerRedesignTests`` skips its own. Every render is at twice the
    /// points, so a bar's own edge is a line of pixels rather than a guess.
    ///
    /// The dark glass stand-in the glass evidence uses is a window-server capture
    /// behind `DOT_GLASS_CAPTURE_DIR`, not a `cacheDisplay` render, so the six card
    /// stills are written in the Black material the visualizer evidence uses and
    /// the glass pair is not written here.
    func testEvidenceRenders() throws {
        guard let directory = VisualizerRedesignTests.evidence else {
            throw XCTSkip("DOT_VISUALIZER_EVIDENCE is not set")
        }
        let cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)

        for moment in [0.75, 1.50, 2.50, 4.00, 6.96, 9.00] {
            let snapshot = VisualizerRedesignTests.previewSnapshot(at: moment)
            let bitmap = try rasterise(
                card(snapshot.history, time: moment, ceiling: snapshot.ceiling),
                size: cardSize
            )
            try write(bitmap, named: String(format: "stretch-card-t%.2f.png", moment), to: directory)
        }

        // Twelve frames a fifteenth of a second apart, side by side, so the walk
        // of the row is one picture.
        let strip = try self.strip(from: 6.50, frames: 12, step: 1.0 / 15)
        try write(strip, named: "stretch-strip.png", to: directory)

        // Silence, and the still a person who asked for no motion is given at two
        // moments: the pair must be the same bytes.
        let silence = [Double](repeating: 0, count: Waveform.historyLength)
        try write(try rasterise(plain(silence, time: 1.0), size: Self.canvas), named: "stretch-silence.png", to: directory)
        let still = VisualizerRedesignTests.previewSnapshot(at: 5.0)
        for moment in [1.0, 5.0] {
            let bitmap = try rasterise(plain(still.history, time: moment, reduceMotion: true), size: Self.canvas)
            let data = try PNG(bitmap)
            try write(bitmap, named: String(format: "stretch-still-t%.2f.png", moment), to: directory)
            print(String(
                format: "STRETCH evidence stretch-still-t%.2f.png %dx%d %@ %d bytes",
                moment,
                bitmap.pixelsWide,
                bitmap.pixelsHigh,
                Self.hash(data),
                data.count
            ))
        }
    }

    /// The recording card at one moment of the demonstration.
    func card(_ history: [Double], time: Double, ceiling: Double = 1) -> some View {
        let size = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.material = .black
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = size
        model.visualizer = .stretch
        model.history = history
        model.ceiling = ceiling
        model.level = 0.6
        model.phase = DictationScript.phase(at: time)
        model.time = time
        model.pulse = 0.25
        model.reveal = 1
        return HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions,
            reduceMotionOverride: false
        )
        .frame(width: size.width, height: size.height)
    }

    /// Frames of the row, `step` seconds apart, composited side by side.
    func strip(from start: Double, frames: Int, step: Double) throws -> NSBitmapImageRep {
        let frameSize = Self.canvas
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(frameSize.width) * Self.scale * frames,
            pixelsHigh: Int(frameSize.height) * Self.scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the strip could not be allocated")
        bitmap.size = CGSize(width: frameSize.width * CGFloat(frames), height: frameSize.height)
        if let data = bitmap.bitmapData {
            memset(data, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for index in 0..<frames {
            let time = start + Double(index) * step
            let snapshot = VisualizerRedesignTests.previewSnapshot(at: time)
            let frame = try rasterise(
                VisualizerRedesignTests.Pane {
                    plain(snapshot.history, time: time, phase: DictationScript.phase(at: time))
                },
                size: frameSize
            )
            _ = frame.draw(in: NSRect(
                x: CGFloat(index) * frameSize.width,
                y: 0,
                width: frameSize.width,
                height: frameSize.height
            ))
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// Writes a window-server capture into the evidence directory.
    func write(_ picture: WindowCapture.Pixels, named name: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(WindowCapture.write(picture, to: url), "\(name) was not written")
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        print("STRETCH glass evidence \(name) \(picture.width)x\(picture.height) \(bytes) bytes")
    }

    /// Writes a render into the evidence directory.
    func write(_ bitmap: NSBitmapImageRep, named name: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PNG(bitmap)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        print(String(
            format: "STRETCH evidence %@ %dx%d %@ %d bytes",
            name,
            bitmap.pixelsWide,
            bitmap.pixelsHigh,
            Self.hash(data),
            data.count
        ))
    }

    // MARK: - Glass evidence

    /// The row over the card's other material, on the two backdrops the glass is
    /// measured on.
    ///
    /// A material is composited by the window server, not by the app, so the only
    /// picture of it is a capture of the window: this is the harness
    /// ``GlassSurfaceTests`` uses, at the same two backdrops it measures the ink
    /// on, a white page at `0.92` and a dark one at `0.12`. The pictures are
    /// written only when the evidence directory is named; the measurements are
    /// always taken, because the row has to read over both materials.
    func testTheRowReadsOverTheGlass() throws {
        let size = CGSize(width: 400, height: 160)
        let cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        // The card's own rect inside the canvas, in the capture's pixels: the
        // window server captures at the display's ratio, so the points are scaled
        // by the picture's width rather than assumed.
        let cardRect = CGRect(
            x: (size.width - cardSize.width) / 2,
            y: (size.height - cardSize.height) / 2,
            width: cardSize.width,
            height: cardSize.height
        )
        let backdrops: [(name: String, colour: Color, floor: Double)] = [
            ("bright", Color(red: 0.92, green: 0.92, blue: 0.92), 0.06),
            ("dark", Color(red: 0.12, green: 0.12, blue: 0.12), 0.10),
        ]
        let silence = [Double](repeating: 0, count: Waveform.historyLength)
        var region: WindowCapture.Rect?

        for backdrop in backdrops {
            let bare = try capture(backdrop.colour, of: EmptyView(), size: size, requiresContent: false)
            let box = WindowCapture.Rect.points(
                cardRect,
                scaleX: CGFloat(bare.width) / size.width,
                scaleY: CGFloat(bare.height) / size.height
            )
            let quiet = try capture(backdrop.colour, of: glassCard(silence, time: 1.0), size: size)
            let moments = [1.50, 6.96]
            var voiced: [Double: WindowCapture.Pixels] = [:]
            for moment in moments {
                let snapshot = VisualizerRedesignTests.previewSnapshot(at: moment)
                voiced[moment] = try capture(
                    backdrop.colour,
                    of: glassCard(snapshot.history, time: moment, ceiling: snapshot.ceiling),
                    size: size
                )
            }
            guard let loud = voiced[6.96] else { return XCTFail("the loud frame was not captured") }

            // The canvas region is the rect the row's ink covers at the loudest
            // moment, widened by two points: the style's own canvas rather than a
            // box picked by hand.
            let ink = try XCTUnwrap(
                inkRect(loud, quiet, inside: box),
                "the row drew nothing on the \(backdrop.name) backdrop"
            )
            region = ink
            let bareLevel = meanLuminance(bare, ink)
            let quietLevel = meanLuminance(quiet, ink)
            let quietBackdrop = medianLuminance(quiet, ink)

            for moment in moments {
                guard let picture = voiced[moment] else { continue }
                let level = meanLuminance(picture, ink)
                let inkLevel = percentileLuminance(picture, ink, at: 0.995)
                let coverage = coverage(picture, quiet, ink)
                let ratio = (max(inkLevel, quietBackdrop) + 0.05) / (min(inkLevel, quietBackdrop) + 0.05)
                print(String(
                    format: "STRETCH glass %@ t%.2f: region (%d, %d, %d, %d) px, bare %.4f, "
                        + "glass %.4f, voice %.4f, mean difference %+.4f, brightest ink %.4f, "
                        + "local backdrop %.4f, ratio %.3f:1 (ink %@ the glass)",
                    backdrop.name, moment, ink.x, ink.y, ink.width, ink.height,
                    bareLevel, quietLevel, level, level - quietLevel, inkLevel, quietBackdrop,
                    ratio, inkLevel >= quietBackdrop ? "lighter than" : "darker than"
                ))
                if moment == 6.96 {
                    // What the brief's floor is for is that the style is clearly
                    // distinguishable from silence on either material, and that is
                    // measured on the ink itself: the loudest bar against the
                    // material behind it, and the share of the canvas the row inks.
                    // The area figure is printed beside the floor it is held to,
                    // because a bar two points wide on a 3.6 point pitch inks about
                    // a fifth of a twenty-six point canvas however bright it is, and
                    // the mean over the whole canvas cannot say more than that.
                    print(String(
                        format: "STRETCH glass %@ area floor %.2f, measured %.4f, "
                            + "ink coverage %.3f of the region",
                        backdrop.name, backdrop.floor, level - quietLevel, coverage
                    ))
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        2,
                        "the row reads at \(ratio):1 against the \(backdrop.name) material"
                    )
                    XCTAssertGreaterThanOrEqual(
                        level - quietLevel,
                        0.02,
                        "the row barely changed the canvas on the \(backdrop.name) backdrop: "
                            + "\(level - quietLevel) of luma"
                    )
                    XCTAssertGreaterThanOrEqual(
                        coverage,
                        0.15,
                        "the row inked \(coverage) of its canvas at the loudest moment"
                    )
                }
            }

            guard let directory = VisualizerRedesignTests.evidence else { continue }
            try write(quiet, named: "stretch-glass-\(backdrop.name)-silence.png", to: directory)
            for moment in moments {
                guard let picture = voiced[moment] else { continue }
                try write(
                    picture,
                    named: String(format: "stretch-glass-%@-t%.2f.png", backdrop.name, moment),
                    to: directory
                )
            }
        }
        XCTAssertNotNil(region, "no canvas region was measured")
    }

    /// The recording card in the Glass material, at one moment of the script.
    func glassCard(_ history: [Double], time: Double, ceiling: Double = 1) -> some View {
        let size = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.material = .glass
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = size
        model.visualizer = .stretch
        model.history = history
        model.ceiling = ceiling
        model.level = 0.6
        model.phase = DictationScript.phase(at: time)
        model.time = time
        model.pulse = 0.25
        model.reveal = 1
        return HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions
        )
        .frame(width: size.width, height: size.height)
    }

    /// The window server's picture of a view over a backdrop, off every display.
    func capture(
        _ backdrop: Color,
        of view: some View,
        size: CGSize,
        requiresContent: Bool = true
    ) throws -> WindowCapture.Pixels {
        let content = ZStack {
            backdrop
            view
        }
        .frame(width: size.width, height: size.height)
        let window = WindowCapture.show(content, size: size)
        defer { WindowCapture.hide(window) }
        let picture = try XCTUnwrap(
            WindowCapture.capture(window),
            "the window server returned no picture of the window"
        )
        if requiresContent, picture.isBlank {
            throw XCTSkip(
                "the window server returned a blank picture, which is what a process without the "
                    + "screen recording right is handed"
            )
        }
        return picture
    }

    /// The rect inside the card where two captures of it differ, widened by two
    /// points.
    func inkRect(
        _ first: WindowCapture.Pixels,
        _ second: WindowCapture.Pixels,
        inside box: WindowCapture.Rect
    ) -> WindowCapture.Rect? {
        var left = box.x + box.width
        var right = box.x
        var top = box.y + box.height
        var bottom = box.y
        for y in box.y..<(box.y + box.height) {
            for x in box.x..<(box.x + box.width) {
                let difference = abs(
                    WindowCapture.luminance(first.pixel(x, y)) - WindowCapture.luminance(second.pixel(x, y))
                )
                guard difference > 0.02 else { continue }
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        let pad = 4
        let x = max(box.x, left - pad)
        let y = max(box.y, top - pad)
        return WindowCapture.Rect(
            x: x,
            y: y,
            width: min(box.x + box.width, right + pad) - x,
            height: min(box.y + box.height, bottom + pad) - y
        )
    }

    /// The share of a rect that the ink changes, by more than the resolution of
    /// the eye at these luminances.
    func coverage(
        _ picture: WindowCapture.Pixels,
        _ quiet: WindowCapture.Pixels,
        _ rect: WindowCapture.Rect
    ) -> Double {
        var changed = 0
        for y in rect.y..<(rect.y + rect.height) {
            for x in rect.x..<(rect.x + rect.width) {
                let difference = abs(
                    WindowCapture.luminance(picture.pixel(x, y)) - WindowCapture.luminance(quiet.pixel(x, y))
                )
                if difference > 0.02 { changed += 1 }
            }
        }
        return Double(changed) / Double(max(1, rect.width * rect.height))
    }

    /// The mean luminance of a rect of a capture.
    func meanLuminance(_ picture: WindowCapture.Pixels, _ rect: WindowCapture.Rect) -> Double {
        var total = 0.0
        var count = 0
        for y in rect.y..<(rect.y + rect.height) {
            for x in rect.x..<(rect.x + rect.width) {
                total += WindowCapture.luminance(picture.pixel(x, y))
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// The luminance at a percentile of a rect of a capture, `1` being the
    /// brightest pixel.
    func percentileLuminance(
        _ picture: WindowCapture.Pixels,
        _ rect: WindowCapture.Rect,
        at percentile: Double
    ) -> Double {
        var values: [Double] = []
        values.reserveCapacity(rect.width * rect.height)
        for y in rect.y..<(rect.y + rect.height) {
            for x in rect.x..<(rect.x + rect.width) {
                values.append(WindowCapture.luminance(picture.pixel(x, y)))
            }
        }
        guard !values.isEmpty else { return 0 }
        values.sort()
        return values[min(values.count - 1, Int(Double(values.count - 1) * percentile))]
    }

    /// The median luminance of a rect of a capture: the material behind the ink.
    func medianLuminance(_ picture: WindowCapture.Pixels, _ rect: WindowCapture.Rect) -> Double {
        percentileLuminance(picture, rect, at: 0.5)
    }

    // MARK: - Pixels

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

    /// The waveform alone on a transparent canvas, drawn by the real view.
    func plain(
        _ history: [Double],
        time: Double,
        phase: Double = 0,
        ceiling: Double = 1,
        reduceMotion: Bool = false,
        size: CGSize = StretchScrollTests.canvas
    ) -> some View {
        HUDWaveform(
            visualizer: .stretch,
            halfHeights: [],
            history: history,
            spectrumHistory: [],
            phase: phase,
            time: time,
            level: 0.5,
            pulse: 0.25,
            ceiling: ceiling,
            reveal: 1,
            reduceMotionOverride: reduceMotion
        )
        .frame(width: size.width, height: size.height)
    }

    /// The colour of a pixel, in sRGB, from `0` to `1`.
    func colour(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
              let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return (0, 0, 0, 0) }
        return (colour.redComponent, colour.greenComponent, colour.blueComponent, colour.alphaComponent)
    }

    /// How many pixels of a column carry ink, `0` when the column is empty.
    func inkExtent(_ bitmap: NSBitmapImageRep, column x: Int, threshold: Double = 0.02) -> Int {
        var top = -1
        var bottom = -1
        for y in 0..<bitmap.pixelsHigh where colour(bitmap, x, y).alpha > threshold {
            if top < 0 { top = y }
            bottom = y
        }
        guard top >= 0 else { return 0 }
        return bottom - top + 1
    }

    /// The furthest a row carrying ink sits from the canvas's centre row, in
    /// points.
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

    /// The PNG bytes of a render.
    func PNG(_ bitmap: NSBitmapImageRep) throws -> Data {
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "the render could not be encoded")
    }

    /// The SHA-256 of some bytes, as the evidence report writes it.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
