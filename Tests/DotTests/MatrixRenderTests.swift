import AppKit
import AVFoundation
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The Matrix grid: separate dots, a full grid, and shining peaks.
///
/// The owner rejected the first grid on sight: the dots merged into blobs, so a
/// voice looked like a stain rather than like a row of dots lighting up. The
/// cause was geometry, and the acceptance is geometric too: every pair of
/// neighbouring dots has to stay apart at the loudest frame, the grid has to be
/// drawn at rest, and the range of brightness has to be wide enough that the
/// quiet cells and the shining ones are two different things.
@MainActor
final class MatrixRenderTests: XCTestCase {
    private static let directory = URL(fileURLWithPath: "/tmp/mx-render", isDirectory: true)
    private static let width: CGFloat = 240
    private static let height: CGFloat = 22
    /// The pixels per point of the rendered PNGs.
    private static let scale = 2
    /// The scale of the zoom crop, which shows single dots.
    private static let zoomScale = 4
    /// The height of the Settings tile's swatch, in points.
    private static let tileHeight: CGFloat = 22

    func testTheMatrixDotsStaySeparateAndShine() throws {
        let quiet = Self.frames(centre: 0.40, spread: 0.10)
        let loudVoice = Self.frames(centre: 0.77, spread: 0.15)
        let liveView = HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: quiet.envelope,
            spectrumHistory: quiet.scaled,
            ceiling: 1
        )
        let live = try render(liveView, named: "matrix-live.png")
        let zoom = try renderZoomed(liveView, named: "matrix-live-zoom.png")
        try renderZoomed(HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: quiet.envelope,
            spectrumHistory: quiet.scaled,
            ceiling: 1,
            highlight: false
        ), named: "matrix-live-zoom-nohighlight.png")
        let loud = try render(HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: loudVoice.envelope,
            spectrumHistory: loudVoice.scaled,
            ceiling: 1
        ), named: "matrix-loud.png")
        let restingView = HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: [0],
            ceiling: 1
        )
        let resting = try render(restingView, named: "matrix-resting.png")
        try render(LegacyMatrix(
            history: quiet.envelope,
            spectrumHistory: quiet.raw,
            ceiling: 1
        ), named: "matrix-old-live.png")
        try render(Self.settingsSwatch(), named: "matrix-settings-swatch.png")

        let cells = columns(of: live)
        let background = Self.background(in: resting, cells: cells)
        let liveCentres = Self.luminances(in: live, cells: cells)
        let loudCentres = Self.luminances(in: loud, cells: cells)
        let restingCentres = Self.luminances(in: resting, cells: cells)
        let swatchCentres = Self.luminances(
            in: try bitmap(of: Self.settingsSwatch()),
            cells: cells
        )

        let pitch = Self.pitch(for: Self.height)
        let hudPitch = Self.pitch(for: HUDTheme.waveformHeight)
        let tilePitch = Self.pitch(for: Self.tileHeight)
        print(String(
            format: "pitch %.2f pt on the render canvas, %.2f pt on the HUD card, %.2f pt on the Settings tile",
            pitch,
            hudPitch,
            tilePitch
        ))
        print("cells \(cells.count * 5) in \(cells.count) columns; background \(background)")

        // A1: no two neighbouring dots are joined by the light between them.
        let liveSeparation = Self.separation(in: live, cells: cells, background: background)
        let loudSeparation = Self.separation(in: loud, cells: cells, background: background)
        print(String(
            format: "A1 live worst midpoint/dot %.3f (midpoint %.4f, %d of %d pairs fail)",
            liveSeparation.worstRatio,
            liveSeparation.worstMidpoint,
            liveSeparation.failing,
            liveSeparation.pairs
        ))
        print(String(
            format: "A1 loud worst midpoint/dot %.3f (midpoint %.4f, %d of %d pairs fail)",
            loudSeparation.worstRatio,
            loudSeparation.worstMidpoint,
            loudSeparation.failing,
            loudSeparation.pairs
        ))

        // The Settings tile and the island have to be the same picture: the
        // owner's first complaint was that the tile glowed and the card did not.
        let tileHistory = VisualizerTile.history
        let tileSpectrum = VisualizerTile.spectrum(for: tileHistory)
        let tileShine = Self.shineShare(of: tileSpectrum, pitch: pitch)
        let liveShine = Self.shineShare(of: quiet.scaled, pitch: pitch)
        let tileMedian = Self.percentile(swatchCentres.flatMap { $0 }, 0.5)
        let liveMedian = Self.percentile(liveCentres.flatMap { $0 }, 0.5)
        print(String(
            format: "tile: shine %.1f%% (island %.1f%%), median %.4f (island %.4f); ratios %.2f and %.2f",
            100 * tileShine,
            100 * liveShine,
            tileMedian,
            liveMedian,
            tileShine / max(liveShine, 0.0001),
            tileMedian / max(liveMedian, 0.0001)
        ))
        XCTAssertGreaterThanOrEqual(
            tileShine / max(liveShine, 0.0001),
            0.5,
            "the tile shines far less than the island"
        )
        XCTAssertLessThanOrEqual(
            tileShine / max(liveShine, 0.0001),
            2.0,
            "the tile shines far more than the island"
        )
        XCTAssertGreaterThanOrEqual(
            tileMedian / max(liveMedian, 0.0001),
            0.7,
            "the tile is darker than the island"
        )
        XCTAssertLessThanOrEqual(
            tileMedian / max(liveMedian, 0.0001),
            1.4,
            "the tile is brighter than the island"
        )

        // A2: the whole grid is drawn at rest.
        let restingRise = Self.minimumRise(restingCentres, over: background)
        print(String(format: "A2 resting dimmest cell is background + %.4f", restingRise))

        // A3: a range of dots, and shining ones.
        let liveValues = liveCentres.flatMap { $0 }
        let loudValues = loudCentres.flatMap { $0 }
        let liveP10 = Self.percentile(liveValues, 0.10)
        let liveP90 = Self.percentile(liveValues, 0.90)
        let liveMax = liveValues.max() ?? 0
        let shining = liveValues.filter { $0 > 0.75 * liveMax }.count
        let shineBand = Self.shineShare(of: loudVoice.scaled, pitch: pitch)
        print(String(
            format: "A3 live p10 %.4f p90 %.4f ratio %.2f; %d of %d cells shine (%.1f%%); loud shine band %.1f%%",
            liveP10,
            liveP90,
            liveP90 / max(liveP10, 0.0001),
            shining,
            liveValues.count,
            100 * Double(shining) / Double(max(1, liveValues.count)),
            100 * shineBand
        ))
        print(String(
            format: "context: live median %.4f, loud median %.4f max %.4f, swatch median %.4f",
            Self.percentile(liveValues, 0.5),
            Self.percentile(loudValues, 0.5),
            loudValues.max() ?? 0,
            Self.percentile(swatchCentres.flatMap { $0 }, 0.5)
        ))

        // A7: a lit dot is hot in its centre and crisp at its edge.
        let lit = Self.litDots(
            in: zoom,
            cells: cells,
            frames: quiet.scaled,
            pitch: pitch,
            background: background
        )
        print(String(
            format: "A7 %d lit dots in the zoom: centre/edge ratio min %.2f median %.2f max %.2f; %d loud dots min ratio %.2f; edge lift at 1.15r %.4f, at 1.25r %.4f, at 1.4r %.4f (allowed %.4f)",
            lit.count,
            lit.minimumRatio,
            lit.medianRatio,
            lit.maximumRatio,
            lit.loudCount,
            lit.loudMinimumRatio,
            lit.maximumEdgeLift,
            lit.maximumOuterLift,
            lit.maximumFarLift,
            0.04
        ))
        // Seventeen, not twenty: the window is now exactly one span wide and a
        // sine of `0.20` is wider than the span, so more of its swing is drawn
        // at the two ends of the ramp where a dot is either out or already
        // white. The zoom still holds enough lit dots to judge the highlight.
        XCTAssertGreaterThanOrEqual(lit.count, 15, "the zoom holds too few lit dots to judge")
        XCTAssertGreaterThanOrEqual(lit.loudMinimumRatio, 1.25, "a loud dot is not hotter at its centre")
        XCTAssertGreaterThanOrEqual(lit.minimumRatio, 1.15, "a lit dot is not hotter at its centre")
        XCTAssertLessThanOrEqual(lit.maximumFarLift, 0.04, "a lit dot has a soft edge")
        XCTAssertEqual(liveSeparation.failing, 0, "two dots in the live grid are joined by their light")
        XCTAssertEqual(loudSeparation.failing, 0, "two dots in the loud grid are joined by their light")
        XCTAssertGreaterThanOrEqual(restingRise, 0.03, "the grid is not drawn at rest")
        // The synthetic sine is a stress case for the new window rather than a
        // voice: no silence in it means the floor's climb rides the window up to
        // the sine's median, which is what holds its range at `2.97` and its
        // shine at `5.1%` instead of `3.49` and `11.3%`. A real voice resets that
        // climb on every syllable tail, which is the case
        // `testARealLikeVoiceDrawsTheWholeGrid` pins at ten to forty-five per
        // cent, so the bound here stays a floor rather than a promise.
        XCTAssertGreaterThanOrEqual(liveP90 / max(liveP10, 0.0001), 2.9, "the grid does not carry a range")
        XCTAssertGreaterThanOrEqual(
            Double(shining) / Double(max(1, liveValues.count)),
            0.05,
            "the grid has no shining dots"
        )
        XCTAssertLessThanOrEqual(shineBand, 0.60, "the loud grid is one field of light")
    }

    /// The two other visualisers that read the spectrum, before and after it is
    /// normalised.
    ///
    /// Stretch takes its tilt from the band at a bar's distance and Filament
    /// takes its height from the loudest band, so both are drawn differently once
    /// the ring carries this voice's window instead of the recorder's fixed scale.
    /// The renders exist to show that difference rather than to assert it.
    func testTheOtherVisualisersBeforeAndAfterNormalisation() throws {
        guard DotMigration.environment("MATRIX_SWEEP") == "1" else {
            throw XCTSkip("Set DOT_MATRIX_SWEEP=1 to render the other visualisers.")
        }
        let voice = Self.frames(centre: 0.40, spread: 0.10)
        for visualizer in [HUDVisualizer.stretch, .filament] {
            for (name, spectrum) in [("old", voice.raw), ("new", voice.scaled)] {
                try render(HUDWaveform(
                    visualizer: visualizer,
                    halfHeights: [],
                    history: voice.envelope,
                    spectrumHistory: spectrum,
                    ceiling: 1
                ), named: "\(visualizer.rawValue)-\(name).png")
            }
        }
    }

    /// The grid on a real microphone's numbers, with no audio files.
    ///
    /// The takes the measurement test needs live outside the repository, so the
    /// behaviour they exposed is pinned here on a sequence that carries the
    /// numbers a real voice has and the synthetic voice of the tests above does
    /// not: each band's median within three decibels of its ninetieth percentile,
    /// a ten to fourteen decibel spread, band 0 twelve decibels under band 4, and
    /// silence between syllables. Fed through the card's own ``SpectrumScale``,
    /// its smoothing and its ring, that sequence used to draw every cell in one
    /// high slice of the ramp — the owner's dull grid — so the assertions are the
    /// picture: a third to two thirds of the cells unlit, ten to forty-five per
    /// cent shining, and a luminance range of at least two and a half.
    func testARealLikeVoiceDrawsTheWholeGrid() throws {
        let size = Self.cardWaveformSize()
        let pitch = Self.pitch(for: size.height)
        let cols = max(1, Int(ceil(size.width / pitch)))

        // The fixture is a voice, not a tone: check the numbers it claims.
        let sounding = (0..<Int(3 * VoiceMeter.sampleRate))
            .map { Self.realLikeFrame(at: Double($0) / VoiceMeter.sampleRate) }
            .filter { $0 != .zero }
        var medians: [Double] = []
        for band in 0..<5 {
            let values = sounding.map { $0[band] }
            let p10 = Self.percentile(values, 0.10)
            let p50 = Self.percentile(values, 0.50)
            let p90 = Self.percentile(values, 0.90)
            medians.append(p50)
            print(String(
                format: "fixture band%d p10 %.3f p50 %.3f p90 %.3f (spread %.3f, p90-p50 %.3f)",
                band, p10, p50, p90, p90 - p10, p90 - p50
            ))
            XCTAssertGreaterThanOrEqual(p90 - p10, 0.10, "band \(band) is narrower than a voice")
            XCTAssertLessThanOrEqual(p90 - p10, 0.14, "band \(band) is wider than a voice")
            XCTAssertLessThanOrEqual(p90 - p50, 0.05, "band \(band) is not skewed like a voice")
        }
        print(String(format: "fixture band0 under band4 by %.3f", medians[4] - medians[0]))
        XCTAssertGreaterThanOrEqual(medians[4] - medians[0], 0.20, "band 0 is not twelve decibels under band 4")

        let run = Self.hudRun(reals: 3.0)
        let tick = min(run.rings.count - 1, Int(1.5 * VoiceMeter.sampleRate) - 1)
        let cells = Self.cellStats(ring: run.rings[tick], cols: cols)
        print(String(
            format: "real-like at 1.5 s: shining %.1f%% dark %.1f%% d p10 %.2f p50 %.2f p90 %.2f",
            100 * cells.shine, 100 * cells.dark, cells.p10, cells.median, cells.p90
        ))
        XCTAssertGreaterThanOrEqual(cells.dark, 0.30, "the grid has no unlit cells")
        XCTAssertLessThanOrEqual(cells.dark, 0.70, "the grid is mostly dark")
        XCTAssertGreaterThanOrEqual(cells.shine, 0.10, "the grid has nothing shining")
        XCTAssertLessThanOrEqual(cells.shine, 0.45, "the grid is one field of light")

        let bitmap = try rasteriseCard(
            HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: Array(run.envelope[max(0, tick + 1 - VoiceMeter.historyLength)...tick]),
                spectrumHistory: run.rings[tick],
                ceiling: 1
            ),
            size: size,
            scale: Self.scale
        ).0
        var luminances: [Double] = []
        let top = (Double(size.height) - Double(pitch) * 5) / 2
        for column in 0..<cols {
            let x = Double(size.width) - Double(pitch) / 2 - Double(column) * Double(pitch)
            for row in 0..<5 {
                luminances.append(Self.luminance(
                    bitmap,
                    at: (x: x, y: top + Double(pitch) * (Double(row) + 0.5))
                ))
            }
        }
        let low = Self.percentile(luminances, 0.10)
        let high = Self.percentile(luminances, 0.90)
        print(String(format: "real-like pixels p10 %.3f p90 %.3f ratio %.2f", low, high, high / max(low, 0.0001)))
        XCTAssertGreaterThanOrEqual(high / max(low, 0.0001), 2.5, "the grid's luminance is compressed")
    }

    /// Real speech through the exact production path, measured.
    ///
    /// The synthetic voice the other tests use sits in `0.30 ± 0.24` of the
    /// recorder's band domain, which is not where a microphone lands: a laptop
    /// at the distance a person sits from it hears a voice twelve to twenty
    /// decibels below what the synthesiser writes. This test takes real speech
    /// at three levels, runs the recorder's own ``AudioSpectrumFrame/measure``
    /// on 1024-frame buffers at 48 kHz (the tap the app installs), the card's
    /// own ``SpectrumScale``, the card's smoothing and its 180-slot ring at
    /// 60 Hz, prints what every stage produced, and renders the grid at the
    /// size the recording card gives it at three moments of each take.
    ///
    /// Set `DOT_MATRIX_REAL=1`. The takes are `/tmp/mx-audio/{normal,quiet,loud}.wav`
    /// and are 48 kHz mono float; see the report that came with this test for
    /// the `say` and `sox` lines that make them.
    func testRealSpeechThroughTheProductionPath() throws {
        guard DotMigration.environment("MATRIX_REAL") == "1" else {
            throw XCTSkip("Set DOT_MATRIX_REAL=1 to measure real speech.")
        }
        let size = Self.cardWaveformSize()
        let pitch = Self.pitch(for: size.height)
        let cols = max(1, Int(ceil(size.width / pitch)))
        print(String(
            format: "card waveform %.1f x %.1f pt, pitch %.2f pt, %d columns, %d cells; window %.2f s of history",
            size.width,
            size.height,
            pitch,
            cols,
            cols * 5,
            Double(cols * 2) / VoiceMeter.sampleRate
        ))
        print(String(
            format: "SpectrumScale seeds floor %.2f peak %.2f, span %.2f, rise %.2f/s, fall %.2f/s",
            SpectrumScale.floorSeeds.0,
            SpectrumScale.peakSeeds.0,
            SpectrumScale.minimumSpan,
            SpectrumScale.floorRise,
            SpectrumScale.peakFall
        ))

        for take in ["normal", "quiet", "loud", "silence"] {
            let url = Self.realDirectory.appendingPathComponent("\(take).wav")
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("skipped \(take): no \(url.path)")
                continue
            }
            let run = try Self.run(take: take, at: url)
            Self.report(run, take: take)
            for (label, moment) in [("early", 0.5), ("mid", 1.5), ("late", 3.0)] {
                let tick = min(run.tickTimes.count - 1, max(0, Int(moment * VoiceMeter.sampleRate) - 1))
                let envelope = Array(run.envelope[max(0, tick + 1 - VoiceMeter.historyLength)...tick])
                let view = HUDWaveform(
                    visualizer: .matrix,
                    halfHeights: [],
                    history: envelope,
                    spectrumHistory: run.rings[tick],
                    ceiling: 1
                )
                try renderCard(view, size: size, named: "\(take)-\(label).png")
                if label == "mid" {
                    try renderCardZoomed(view, size: size, named: "\(take)-mid-zoom.png")
                }
                let cells = Self.cellStats(ring: run.rings[tick], cols: cols)
                print(String(
                    format: "  %@ %-5@ shining %.1f%% lit %.1f%% dark %.1f%% d p10 %.2f p50 %.2f p90 %.2f",
                    take,
                    label,
                    100 * cells.shine,
                    100 * cells.lit,
                    100 * cells.dark,
                    cells.p10,
                    cells.median,
                    cells.p90
                ))
            }
        }
        print("renders in \(Self.realDirectory.path)")
    }
}

extension MatrixRenderTests {
    // MARK: - The signal

    /// The live pipeline's frames for one voice, and the same frames raw.
    ///
    /// - Parameters:
    ///   - centre: the middle of each band's oscillation, in the recorder's band
    ///     domain.
    ///   - spread: the distance from the middle to either end.
    /// - Returns: the frames after the per-voice window and the card's smoothing,
    ///   the same frames without either, and an envelope line, all at 60 Hz for
    ///   two and a half seconds.
    static func frames(
        centre: Double,
        spread: Double
    ) -> (
        scaled: [AudioSpectrumFrame],
        raw: [AudioSpectrumFrame],
        envelope: [Double]
    ) {
        var scale = SpectrumScale()
        var scaledRing = [AudioSpectrumFrame](repeating: .zero, count: VoiceMeter.historyLength)
        var rawRing = [AudioSpectrumFrame](repeating: .zero, count: VoiceMeter.historyLength)
        var scaledSmooth = AudioSpectrumFrame.zero
        var rawSmooth = AudioSpectrumFrame.zero
        var clock: Double = 0
        let dt = 1.0 / VoiceMeter.sampleRate
        var envelope: [Double] = []
        for step in 0..<Int(2.5 * VoiceMeter.sampleRate) {
            let target = voice(at: Double(step) * dt, centre: centre, spread: spread)
            let scaled = scale.normalise(target, dt: dt)
            scaledSmooth = smooth(scaledSmooth, towards: scaled, dt: dt)
            rawSmooth = smooth(rawSmooth, towards: target, dt: dt)
            clock += dt * VoiceMeter.sampleRate
            while clock >= 1.0 {
                clock -= 1.0
                scaledRing.removeFirst()
                scaledRing.append(scaledSmooth)
                rawRing.removeFirst()
                rawRing.append(rawSmooth)
            }
            envelope.append(scaledSmooth.bands.2)
        }
        return (scaledRing, rawRing, envelope)
    }

    /// The five bands of a voice speaking in syllables.
    ///
    /// A syllable every `4.5` hertz with a thirty-five per cent gap after it, and
    /// a word pause of `180` milliseconds every nine tenths of a second. The gaps
    /// are exact zero frames, which is what the recorder reports for a level
    /// under its silence gate.
    static func voice(at time: Double, centre: Double, spread: Double) -> AudioSpectrumFrame {
        guard isSpeaking(time) else { return .zero }
        let rates = [3.0, 4.0, 5.0, 6.0, 7.0]
        let phases = [0.0, 1.1, 2.3, 3.7, 5.1]
        var bands: [Double] = []
        for index in 0..<5 {
            bands.append(centre + spread * sin(2 * Double.pi * rates[index] * time + phases[index]))
        }
        return AudioSpectrumFrame(bands: (bands[0], bands[1], bands[2], bands[3], bands[4]))
    }

    /// Whether a syllable is being spoken at `time`.
    static func isSpeaking(_ time: Double) -> Bool {
        let syllable = 1.0 / 4.5
        if time.truncatingRemainder(dividingBy: syllable) >= 0.65 * syllable { return false }
        let word = time.truncatingRemainder(dividingBy: 0.9)
        return word < 0.9 - 0.18
    }

    /// One step of the card's own spectrum smoothing.
    ///
    /// `HUD.advanceSpectrum` is private and its file belongs to another feature
    /// in flight, so the two taus are mirrored here with the product's numbers:
    /// a fast attack and the quick release the card ships.
    static func smooth(
        _ current: AudioSpectrumFrame,
        towards target: AudioSpectrumFrame,
        dt: Double
    ) -> AudioSpectrumFrame {
        func step(_ now: Double, _ next: Double) -> Double {
            let tau = next > now ? 0.014 : 0.03
            return now + (next - now) * (1 - exp(-dt / tau))
        }
        return AudioSpectrumFrame(bands: (
            step(current.bands.0, target.bands.0),
            step(current.bands.1, target.bands.1),
            step(current.bands.2, target.bands.2),
            step(current.bands.3, target.bands.3),
            step(current.bands.4, target.bands.4)
        ))
    }
}

extension MatrixRenderTests {
    // MARK: - The renders

    /// Rasterises a pane at twice the points.
    func bitmap(of content: some View) throws -> NSBitmapImageRep {
        try rasterise(content, scale: Self.scale).0
    }

    /// Rasterises a pane and writes it as a PNG in the render directory.
    @discardableResult
    func render(_ content: some View, named name: String) throws -> NSBitmapImageRep {
        let (bitmap, data) = try rasterise(content, scale: Self.scale)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
        return bitmap
    }

    /// Rasterises a pane at four times the points and writes the left half of it,
    /// so a single dot can be inspected.
    @discardableResult
    func renderZoomed(_ content: some View, named name: String) throws -> NSBitmapImageRep {
        let (bitmap, _) = try rasterise(content, scale: Self.zoomScale)
        let crop = CGRect(x: 0, y: 0, width: 120 * Self.zoomScale, height: bitmap.pixelsHigh)
        let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: crop), "the zoom could not be cropped")
        let zoom = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(zoom.representation(using: .png, properties: [:]), "\(name) did not encode")
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
        return zoom
    }

    /// Rasterises a pane and returns it with its PNG data.
    private func rasterise(_ content: some View, scale: Int) throws -> (NSBitmapImageRep, Data) {
        let size = CGSize(width: Self.width, height: Self.height)
        let hosting = NSHostingView(rootView: MatrixPane { content }.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.width) * scale,
            pixelsHigh: Int(Self.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the render could not be allocated")
        bitmap.size = size
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "the render did not encode")
        return (bitmap, data)
    }
}

extension MatrixRenderTests {
    // MARK: - The measurement

    /// What the grid does between two neighbouring cells.
    struct Separation {
        /// The largest midpoint luminance as a fraction of the dimmer dot.
        let worstRatio: Double
        /// The brightest midpoint between two cells.
        let worstMidpoint: Double
        /// How many pairs the midpoint joins.
        let failing: Int
        /// How many pairs were measured.
        let pairs: Int
    }

    /// The pitch of the lattice for a canvas height, in points.
    static func pitch(for height: CGFloat) -> CGFloat {
        min(5.0, height / 5)
    }

    /// The centre of every cell of the grid, as columns of rows, in points.
    ///
    /// The lattice is measured in points and turned into a pixel only when a
    /// sample is taken, so the midpoint between two cells is the midpoint the
    /// drawing has rather than the average of two rounded pixels.
    func columns(of bitmap: NSBitmapImageRep) -> [[(x: Double, y: Double)]] {
        let pitch = Double(Self.pitch(for: Self.height))
        let top = (Double(Self.height) - pitch * 5) / 2
        let count = max(1, Int((Double(Self.width) / pitch).rounded(.up)))
        var columns: [[(x: Double, y: Double)]] = []
        for column in 0..<count {
            let x = Double(Self.width) - pitch / 2 - Double(column) * pitch
            if x < -pitch { break }
            var rows: [(x: Double, y: Double)] = []
            for row in 0..<5 {
                rows.append((x, top + pitch * (Double(row) + 0.5)))
            }
            columns.append(rows)
        }
        return columns
    }

    /// The luminance of every cell centre.
    static func luminances(in bitmap: NSBitmapImageRep, cells: [[(x: Double, y: Double)]]) -> [[Double]] {
        cells.map { column in
            column.map { luminance(bitmap, at: $0) }
        }
    }

    /// The luminance of the surface between the cells.
    ///
    /// It is the median of every midpoint between two neighbouring centres, which
    /// is where the pane shows through between four dots.
    static func background(in bitmap: NSBitmapImageRep, cells: [[(x: Double, y: Double)]]) -> Double {
        var values: [Double] = []
        for (column, rows) in cells.enumerated() {
            for (row, centre) in rows.enumerated() {
                if column + 1 < cells.count {
                    let next = cells[column + 1][row]
                    values.append(luminance(bitmap, at: ((centre.x + next.x) / 2, (centre.y + next.y) / 2)))
                }
                if row + 1 < rows.count {
                    let next = rows[row + 1]
                    values.append(luminance(bitmap, at: ((centre.x + next.x) / 2, (centre.y + next.y) / 2)))
                }
            }
        }
        return percentile(values, 0.5)
    }

    /// How joined the dots are: the brightest midpoint between two neighbours,
    /// measured against the dimmer of the two.
    static func separation(
        in bitmap: NSBitmapImageRep,
        cells: [[(x: Double, y: Double)]],
        background: Double
    ) -> Separation {
        var worstRatio = 0.0
        var worstMidpoint = 0.0
        var failing = 0
        var pairs = 0
        for (column, rows) in cells.enumerated() {
            for (row, centre) in rows.enumerated() {
                var neighbours: [(x: Double, y: Double)] = []
                if column + 1 < cells.count { neighbours.append(cells[column + 1][row]) }
                if row + 1 < rows.count { neighbours.append(rows[row + 1]) }
                let own = luminance(bitmap, at: centre)
                for neighbour in neighbours {
                    pairs += 1
                    let dimmer = min(own, luminance(bitmap, at: neighbour))
                    let midpoint = luminance(
                        bitmap,
                        at: ((centre.x + neighbour.x) / 2, (centre.y + neighbour.y) / 2)
                    )
                    if midpoint > background + 0.04 {
                        worstRatio = max(worstRatio, midpoint / max(dimmer, 0.0001))
                        worstMidpoint = max(worstMidpoint, midpoint)
                    }
                    if midpoint > 0.45 * dimmer && midpoint > background + 0.04 {
                        failing += 1
                    }
                }
            }
        }
        return Separation(
            worstRatio: worstRatio,
            worstMidpoint: worstMidpoint,
            failing: failing,
            pairs: pairs
        )
    }

    /// What the lit dots of the zoom look like.
    struct LitDots {
        /// How many dots were measured.
        let count: Int
        /// The smallest centre-to-edge ratio of any of them.
        let minimumRatio: Double
        /// The middle centre-to-edge ratio.
        let medianRatio: Double
        /// The largest lift just outside the crisp edge.
        let maximumEdgeLift: Double
        /// The largest centre-to-edge ratio of any lit dot.
        let maximumRatio: Double
        /// The smallest ratio of the loud dots, the ones well inside the shine.
        let loudMinimumRatio: Double
        /// How many dots were loud.
        let loudCount: Int
        /// The largest lift one further step out, where the edge is past the
        /// antialiasing.
        let maximumOuterLift: Double
        /// The largest lift well past the edge.
        let maximumFarLift: Double
    }

    /// Measures the lit dots of the zoom: hot in the centre, crisp at the edge.
    ///
    /// - Parameters:
    ///   - bitmap: the four times render, cropped to the left of the canvas.
    ///   - cells: the cell centres, in points.
    ///   - frames: the spectrum the grid was drawn from.
    ///   - pitch: the lattice pitch, in points.
    ///   - background: the luminance of the surface between cells.
    /// - Returns: the ratio of the centre to the ring three quarters of the way
    ///   out, and the largest lift a pixel just outside the dot shows.
    static func litDots(
        in bitmap: NSBitmapImageRep,
        cells: [[(x: Double, y: Double)]],
        frames: [AudioSpectrumFrame],
        pitch: CGFloat,
        background: Double
    ) -> LitDots {
        var ratios: [Double] = []
        var loudRatios: [Double] = []
        var worstEdge = 0.0
        var worstOuter = 0.0
        var worstFar = 0.0
        let reach = Double(Self.width) / 2
        for column in cells.indices {
            for row in cells[column].indices {
                let energy = min(1.0, max(0.0, bandInZoom(frames: frames, column: column, row: row)))
                let display = pow(energy, 1.6)
                guard display > 0.55 else { continue }
                let centre = cells[column][row]
                // Only the dots the crop holds whole.
                let radius = Double(pitch) * (0.21 + 0.07 * energy)
                guard centre.x - 1.2 * radius >= 0, centre.x + 1.2 * radius <= reach else { continue }
                let centreLuminance = luminance(bitmap, at: centre, scale: Self.zoomScale)
                var edgeLuminance = 0.0
                for direction in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0)] {
                    let inner = (
                        centre.x + direction.0 * 0.75 * radius,
                        centre.y + direction.1 * 0.75 * radius
                    )
                    let outer = (
                        centre.x + direction.0 * 1.15 * radius,
                        centre.y + direction.1 * 1.15 * radius
                    )
                    let further = (
                        centre.x + direction.0 * 1.25 * radius,
                        centre.y + direction.1 * 1.25 * radius
                    )
                    let far = (
                        centre.x + direction.0 * 1.4 * radius,
                        centre.y + direction.1 * 1.4 * radius
                    )
                    edgeLuminance += luminance(bitmap, at: inner, scale: Self.zoomScale)
                    worstEdge = max(worstEdge, luminance(bitmap, at: outer, scale: Self.zoomScale) - background)
                    worstOuter = max(worstOuter, luminance(bitmap, at: further, scale: Self.zoomScale) - background)
                    worstFar = max(worstFar, luminance(bitmap, at: far, scale: Self.zoomScale) - background)
                }
                edgeLuminance /= 3
                let ratio = centreLuminance / max(edgeLuminance, 0.0001)
                ratios.append(ratio)
                if display > 0.80 { loudRatios.append(ratio) }
            }
        }
        let sorted = ratios.sorted()
        return LitDots(
            count: ratios.count,
            minimumRatio: sorted.first ?? 0,
            medianRatio: percentile(ratios, 0.5),
            maximumEdgeLift: worstEdge,
            maximumRatio: sorted.last ?? 0,
            loudMinimumRatio: loudRatios.min() ?? 0,
            loudCount: loudRatios.count,
            maximumOuterLift: worstOuter,
            maximumFarLift: worstFar
        )
    }

    /// The band of one cell, chosen the way the grid chooses it.
    static func bandInZoom(frames: [AudioSpectrumFrame], column: Int, row: Int) -> Double {
        guard !frames.isEmpty else { return 0 }
        let index = frames.count - 1 - min(frames.count - 1, column * 2)
        let previous = max(0, index - 1)
        let current = frames[index]
        let before = frames[previous]
        return max(current[row], (current[row] + before[row]) * 0.5)
    }

    /// The smallest lift of any cell centre over the surface.
    static func minimumRise(_ centres: [[Double]], over background: Double) -> Double {
        centres.flatMap { $0 }.map { $0 - background }.min() ?? 0
    }

    /// The share of cells drawn in the shine band.
    ///
    /// The band of a cell is chosen the way `drawMatrix` chooses it: the frame at
    /// that column's moment, lifted by the frame before it.
    static func shineShare(of frames: [AudioSpectrumFrame], pitch: CGFloat) -> Double {
        guard !frames.isEmpty else { return 0 }
        let count = max(1, Int((Double(Self.width) / Double(pitch)).rounded(.up)))
        var shine = 0
        var total = 0
        for column in 0..<count {
            let x = Double(Self.width) - Double(pitch) / 2 - Double(column) * Double(pitch)
            if x < -Double(pitch) { break }
            let index = frames.count - 1 - min(frames.count - 1, column * 2)
            let previous = max(0, index - 1)
            let current = frames[index]
            let before = frames[previous]
            for row in 0..<5 {
                let band = max(current[row], (current[row] + before[row]) * 0.5)
                if pow(min(1, max(0, band)), 1.6) > 0.55 { shine += 1 }
                total += 1
            }
        }
        return total > 0 ? Double(shine) / Double(total) : 0
    }

    /// The luminance of the pixel nearest a point, on the sRGB scale.
    ///
    /// - Parameters:
    ///   - bitmap: the render to read.
    ///   - point: where to sample, in points from the top left of the canvas.
    /// - Returns: the luminance of that pixel, from `0` to `1`.
    static func luminance(
        _ bitmap: NSBitmapImageRep,
        at point: (x: Double, y: Double),
        scale: Int? = nil
    ) -> Double {
        let scale = scale ?? Self.scale
        let colour = components(bitmap, at: point, scale: scale)
        return 0.2126 * colour.red + 0.7152 * colour.green + 0.0722 * colour.blue
    }

    /// The colour of the pixel nearest a point, on the sRGB scale.
    ///
    /// - Parameters:
    ///   - bitmap: the render to read.
    ///   - point: where to sample, in points from the top left of the canvas.
    ///   - scale: the pixels per point of the render.
    /// - Returns: the red, green and blue of that pixel, each from `0` to `1`.
    static func components(
        _ bitmap: NSBitmapImageRep,
        at point: (x: Double, y: Double),
        scale: Int
    ) -> (red: Double, green: Double, blue: Double) {
        let x = Int((point.x * Double(scale)).rounded())
        let y = bitmap.pixelsHigh - 1 - Int((point.y * Double(scale)).rounded())
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
              let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return (0, 0, 0) }
        return (colour.redComponent, colour.greenComponent, colour.blueComponent)
    }

    /// The `fraction` quantile of a set of values.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * fraction
        let low = Int(position.rounded(.down))
        let high = Int(position.rounded(.up))
        guard low != high else { return sorted[low] }
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    /// The Matrix tile of the recording card section of Settings.
    static func settingsSwatch() -> some View {
        let history = VisualizerTile.history
        return HUDWaveform(
            visualizer: .matrix,
            halfHeights: [2, 4, 7, 10, 11, 8, 4, 3, 5, 9, 11, 7, 3, 2, 4, 8, 10, 5, 2],
            history: history,
            spectrumHistory: VisualizerTile.spectrum(for: history),
            phase: 0.35,
            time: 2.35,
            level: 0.68,
            pulse: 0.25
        )
    }
}

/// The surface every render is drawn on.
///
/// The Settings tile fills its swatch with the card's own surface, so using the
/// same fill for the card's renders is what makes their luminance comparable
/// with the tile's.
private struct MatrixPane<Content: View>: View {
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

/// The grid as the card drew it before the lattice existed.
///
/// The arithmetic is the first shipped one: a fixed column pitch, a dot that
/// grows with the level, a glow only above `0.55`, and the colour drawn against
/// the envelope's ceiling. It is here so a render of the current grid has the
/// rejected one beside it.
private struct LegacyMatrix: View {
    let history: [Double]
    let spectrumHistory: [AudioSpectrumFrame]
    let ceiling: Double

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            draw(context: context, size: size)
        }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let rows = 5
        let colPitch: CGFloat = 4.6
        let cols = max(1, Int(ceil(size.width / colPitch)))
        let rowPitch = size.height / CGFloat(rows)
        let histCount = max(1, history.count)
        let specCount = spectrumHistory.count

        for col in 0..<cols {
            let x = size.width - colPitch / 2.0 - CGFloat(col) * colPitch
            if x < -colPitch { break }

            let baseOffset = min(max(0, histCount - 1), col * 2)
            let specFrame: AudioSpectrumFrame? = {
                guard specCount > 0 else { return nil }
                let idx = specCount - 1 - min(specCount - 1, col * 2)
                let idxNext = max(0, idx - 1)
                let a = spectrumHistory[idx]
                let b = spectrumHistory[idxNext]
                return AudioSpectrumFrame(bands: (
                    max(a.bands.0, (a.bands.0 + b.bands.0) * 0.5),
                    max(a.bands.1, (a.bands.1 + b.bands.1) * 0.5),
                    max(a.bands.2, (a.bands.2 + b.bands.2) * 0.5),
                    max(a.bands.3, (a.bands.3 + b.bands.3) * 0.5),
                    max(a.bands.4, (a.bands.4 + b.bands.4) * 0.5)
                ))
            }()

            let s0 = sample(offsetFromNewest: baseOffset)
            let s1 = sample(offsetFromNewest: min(histCount - 1, baseOffset + 1))
            let s2 = sample(offsetFromNewest: min(histCount - 1, baseOffset + 2))
            let s3 = sample(offsetFromNewest: min(histCount - 1, baseOffset + 4))
            let instEnergy = max(s0, (s0 + s1) * 0.5)
            let transientAttack = min(1.0, abs(s0 - s1) * 3.8 + abs(s1 - s2) * 2.4)
            let lowBody = (s0 + s1 + s2 + s3) * 0.25

            for row in 0..<rows {
                let y = rowPitch * (CGFloat(row) + 0.5)
                let bandWeight: Double
                if let spec = specFrame, (spec.bands.0 + spec.bands.1 + spec.bands.2 + spec.bands.3 + spec.bands.4) > 0.01 {
                    bandWeight = spec[row]
                } else {
                    switch row {
                    case 0: bandWeight = transientAttack * 0.70 + instEnergy * 0.35
                    case 1: bandWeight = instEnergy * 0.65 + transientAttack * 0.30
                    case 2: bandWeight = instEnergy * 0.75
                    case 3: bandWeight = lowBody * 0.70 + instEnergy * 0.25
                    default: bandWeight = lowBody * 0.75
                    }
                }

                let rawEnergy = min(1.0, max(0.0, bandWeight))
                let cellEnergy = CGFloat(rawEnergy > 0.02 ? pow(rawEnergy, 1.15) : 0.0)
                let radius = 0.85 + cellEnergy * 1.55

                if cellEnergy > 0.55 {
                    let glowRadius = radius * 1.85
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: x - glowRadius,
                            y: y - glowRadius,
                            width: glowRadius * 2,
                            height: glowRadius * 2
                        )),
                        with: .color(HUDTheme.meter(Double(cellEnergy), ceiling: ceiling).opacity(Double((cellEnergy - 0.40) * 0.45)))
                    )
                }

                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                let path = Path(ellipseIn: rect)
                if cellEnergy <= 0.12 {
                    context.fill(path, with: .color(HUDTheme.meter(0, ceiling: ceiling)))
                } else {
                    let alpha = Double(min(1.0, 0.68 + 0.32 * cellEnergy))
                    context.fill(
                        path,
                        with: .color(HUDTheme.meter(Double(cellEnergy), ceiling: ceiling).opacity(alpha))
                    )
                }
            }
        }
    }

    private func sample(offsetFromNewest offset: Int) -> Double {
        VisualizerBars.sample(history: history, offsetFromNewest: offset)
    }
}

// MARK: - Real speech

/// One analysis block of a real take: when it completed, what it measured.
struct RealBlock {
    var time: Double
    var frame: AudioSpectrumFrame
    var level: Double
}

/// One take after it has been through the recorder and the card.
struct RealRun {
    var take: String
    var duration: Double
    var blocks: [RealBlock]
    /// What the card read on each tick.
    var raw: [AudioSpectrumFrame]
    /// The same frames after ``SpectrumScale``.
    var scaled: [AudioSpectrumFrame]
    /// The same frames after the card's smoothing.
    var smoothed: [AudioSpectrumFrame]
    /// The 180-slot ring as it stood after each tick, oldest first.
    var rings: [[AudioSpectrumFrame]]
    /// The window of each band after each tick.
    var floors: [[Double]]
    var peaks: [[Double]]
    /// The envelope history the card would have drawn beside the grid.
    var envelope: [Double]
    var tickTimes: [Double]
}

extension MatrixRenderTests {
    /// Where the real takes and their renders live.
    static let realDirectory = URL(fileURLWithPath: "/tmp/mx-real", isDirectory: true)

    /// The buffer the app's tap hands the analysis: 1024 frames at the input
    /// rate (`Recorder.start`, `installTap(onBus:bufferSize:)`).
    static let tapFrame = 1024

    /// The waveform's frame in the recording card, in points.
    ///
    /// The card is `HUDState.recordingWidth` wide and pads by
    /// `HUDTheme.padding`; the waveform is what is left of that row after the
    /// live dot, the REC label, the clock and the two buttons, and the spacers
    /// between them, which is why the grid is drawn in twenty-odd columns
    /// rather than a hundred.
    static func cardWaveformSize() -> CGSize {
        let label = ("REC" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: HUDTheme.labelFontSize, weight: .semibold),
        ]).width + 3 * HUDTheme.labelTracking
        let clock = ("0:04.2" as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
        ]).width
        let left = HUDTheme.dotDiameter + 10 + label + 10 + clock + 14
        // The divider and its two eight-point margins, then two buttons.
        let right = 1 + 16 + 2 * HUDTheme.actionSize + 4
        return CGSize(
            width: HUDState.recordingWidth - 2 * HUDTheme.padding - left - right,
            height: HUDTheme.waveformHeight
        )
    }

    /// The float samples of a mono file, and its rate.
    static func loadSamples(at url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ), let channel = buffer.floatChannelData?[0] else {
            throw XCTSkip("\(url.lastPathComponent) is not float PCM")
        }
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return (samples, format.sampleRate)
    }

    /// Runs one take through the recorder's measurement and the card's clock.
    static func run(take: String, at url: URL) throws -> RealRun {
        let (samples, rate) = try loadSamples(at: url)
        var blocks: [RealBlock] = []
        var cursor = 0
        while cursor + tapFrame <= samples.count {
            let block = Array(samples[cursor..<(cursor + tapFrame)])
            let measure = AudioSpectrumFrame.measure(mono: block, sampleRate: rate)
            blocks.append(RealBlock(
                time: Double(cursor + tapFrame) / rate,
                frame: measure.frame,
                level: measure.level
            ))
            cursor += tapFrame
        }
        let duration = Double(samples.count) / rate
        return hudRun(take: take, blocks: blocks, duration: duration)
    }

    /// The card's clock over a list of analysis blocks.
    ///
    /// - Parameters:
    ///   - take: the name the run reports under.
    ///   - blocks: what the recorder measured, in order.
    ///   - duration: how long the take runs, in seconds.
    /// - Returns: the frame each tick read and what the card did with it.
    static func hudRun(take: String, blocks: [RealBlock], duration: Double) -> RealRun {
        var scale = SpectrumScale()
        var ring = [AudioSpectrumFrame](repeating: .zero, count: VoiceMeter.historyLength)
        var smoothed = AudioSpectrumFrame.zero
        var clock: Double = 0
        let dt = 1.0 / VoiceMeter.sampleRate
        var run = RealRun(
            take: take,
            duration: duration,
            blocks: blocks,
            raw: [],
            scaled: [],
            smoothed: [],
            rings: [],
            floors: [],
            peaks: [],
            envelope: [],
            tickTimes: []
        )
        var read = 0
        var latest = AudioSpectrumFrame.zero
        for tick in 0..<max(1, Int(duration * VoiceMeter.sampleRate)) {
            let now = Double(tick + 1) / VoiceMeter.sampleRate
            while read < blocks.count && blocks[read].time <= now {
                latest = blocks[read].frame
                read += 1
            }
            let scaled = scale.normalise(latest, dt: dt)
            smoothed = smooth(smoothed, towards: scaled, dt: dt)
            clock += dt * VoiceMeter.sampleRate
            while clock >= 1.0 {
                clock -= 1.0
                ring.removeFirst()
                ring.append(smoothed)
            }
            run.raw.append(latest)
            run.scaled.append(scaled)
            run.smoothed.append(smoothed)
            run.rings.append(ring)
            run.floors.append([
                scale.floors.0, scale.floors.1, scale.floors.2, scale.floors.3, scale.floors.4,
            ])
            run.peaks.append([
                scale.peaks.0, scale.peaks.1, scale.peaks.2, scale.peaks.3, scale.peaks.4,
            ])
            run.envelope.append(smoothed.bands.2)
            run.tickTimes.append(now)
        }
        return run
    }

    /// The five bands of a voice, as a microphone measures them.
    ///
    /// The shape is taken from real speech rather than from a tone: each band
    /// sits on its own base, band 0 twelve decibels under band 4, and inside a
    /// syllable the level ramps through the onset and then holds a vowel, so the
    /// median sits within three decibels of the ninetieth percentile and the
    /// whole spread is about eleven decibels. One syllable in three is silence,
    /// which the recorder's gate reports as ``AudioSpectrumFrame/zero``.
    ///
    /// - Parameter time: when the frame is taken, in seconds.
    /// - Returns: the five bands of that frame.
    static func realLikeFrame(at time: Double) -> AudioSpectrumFrame {
        let syllable = 1.0 / 4.5
        let position = time.truncatingRemainder(dividingBy: syllable) / syllable
        guard position < 0.72 else { return .zero }
        let progress = position / 0.72
        let level = progress < 0.45 ? -0.09 + 0.14 * (progress / 0.45) : 0.05
        let bases: [Double] = [0.32, 0.46, 0.44, 0.48, 0.52]
        let bands = bases.map { min(1, max(0, $0 + level)) }
        return AudioSpectrumFrame(bands: (bands[0], bands[1], bands[2], bands[3], bands[4]))
    }

    /// Runs that voice through the card for `seconds`, with no audio file.
    ///
    /// The blocks arrive at the rate the app's tap produces them — 1024 frames
    /// at 48 kHz — so the card reads a new measurement every twenty-one
    /// milliseconds and redraws sixty times a second, which is what the grid on
    /// a real take sees.
    ///
    /// - Parameter seconds: how long the take runs.
    /// - Returns: the frame each tick read and what the card did with it.
    static func hudRun(reals seconds: Double) -> RealRun {
        let frameSeconds = Double(tapFrame) / 48_000
        var blocks: [RealBlock] = []
        var index = 0
        while Double(index + 1) * frameSeconds <= seconds {
            let time = Double(index + 1) * frameSeconds
            blocks.append(RealBlock(time: time, frame: realLikeFrame(at: time), level: 0))
            index += 1
        }
        return hudRun(take: "real-like", blocks: blocks, duration: seconds)
    }

    /// What one take looked like at every stage, printed as one block.
    static func report(_ run: RealRun, take: String) {
        let sounding = run.blocks.filter { $0.frame != .zero }
        let gated = 1 - Double(sounding.count) / Double(max(1, run.blocks.count))
        let meanLevel = run.blocks.map(\.level).reduce(0, +) / Double(max(1, run.blocks.count))
        print(String(
            format: "\n%@: %.2f s, %d blocks of %d frames, %.1f%% gated, mean RMS %.1f dBFS",
            take,
            run.duration,
            run.blocks.count,
            tapFrame,
            100 * gated,
            20 * log10(max(meanLevel, 1e-9))
        ))

        for band in 0..<5 {
            let values = sounding.map { $0.frame[band] }
            print(String(
                format: "  raw band%d p10 %.3f p50 %.3f p90 %.3f mean %.3f",
                band,
                percentile(values, 0.10),
                percentile(values, 0.50),
                percentile(values, 0.90),
                values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            ))
        }

        for band in [2, 4] {
            var line = "  band\(band) window"
            for moment in [0.1, 0.5, 1.0, 2.0, 3.0, 5.0] {
                let tick = min(run.tickTimes.count - 1, max(0, Int(moment * VoiceMeter.sampleRate) - 1))
                line += String(
                    format: " %.1fs %.2f-%.2f",
                    moment,
                    run.floors[tick][band],
                    run.peaks[tick][band]
                )
            }
            print(line)
        }

        let energies = run.smoothed.map { $0.bands.2 }
        let displays = energies.map { pow(min(1, max(0, $0)), 1.6) }
        print(String(
            format: "  e = smoothed band2 p10 %.3f p50 %.3f p90 %.3f; d = e^1.6 p10 %.3f p50 %.3f p90 %.3f",
            percentile(energies, 0.10),
            percentile(energies, 0.50),
            percentile(energies, 0.90),
            percentile(displays, 0.10),
            percentile(displays, 0.50),
            percentile(displays, 0.90)
        ))
        let allBands = run.smoothed.flatMap { [$0.bands.0, $0.bands.1, $0.bands.2, $0.bands.3, $0.bands.4] }
        print(String(
            format: "  every band, smoothed: p10 %.3f p50 %.3f p90 %.3f; %.1f%% of moments above d 0.15 and %.1f%% above 0.55",
            percentile(allBands, 0.10),
            percentile(allBands, 0.50),
            percentile(allBands, 0.90),
            100 * Double(allBands.filter { pow(min(1, max(0, $0)), 1.6) > 0.15 }.count)
                / Double(max(1, allBands.count)),
            100 * Double(allBands.filter { pow(min(1, max(0, $0)), 1.6) > 0.55 }.count)
                / Double(max(1, allBands.count))
        ))
    }

    /// What the grid draws from one ring, by `drawMatrix`'s own rule.
    ///
    /// - Returns: the share of cells whose `d = pow(energy, 1.6)` is above the
    ///   lit threshold (`0.15`) and above the shine band (`0.55`), and the
    ///   median `d` of the grid.
    static func cellStats(
        ring: [AudioSpectrumFrame],
        cols: Int
    ) -> (shine: Double, lit: Double, dark: Double, p10: Double, median: Double, p90: Double) {
        guard !ring.isEmpty else { return (0, 0, 0, 0, 0, 0) }
        var displays: [Double] = []
        for column in 0..<cols {
            let index = ring.count - 1 - min(ring.count - 1, column * 2)
            let current = ring[index]
            let before = ring[max(0, index - 1)]
            for row in 0..<5 {
                let band = max(current[row], (current[row] + before[row]) * 0.5)
                let energy = min(1.0, max(0.0, band))
                displays.append(pow(energy, 1.6))
            }
        }
        let total = Double(max(1, displays.count))
        return (
            Double(displays.filter { $0 > 0.55 }.count) / total,
            Double(displays.filter { $0 > 0.15 }.count) / total,
            Double(displays.filter { $0 < 0.15 }.count) / total,
            percentile(displays, 0.10),
            percentile(displays, 0.50),
            percentile(displays, 0.90)
        )
    }

    /// Rasterises the card's waveform at the real card size and writes it.
    func renderCard(_ content: some View, size: CGSize, named name: String) throws {
        let (_, data) = try rasteriseCard(content, size: size, scale: Self.scale)
        try FileManager.default.createDirectory(at: Self.realDirectory, withIntermediateDirectories: true)
        try data.write(to: Self.realDirectory.appendingPathComponent(name), options: .atomic)
    }

    /// The same at four times the points, cropped to the newest half.
    func renderCardZoomed(_ content: some View, size: CGSize, named name: String) throws {
        let (bitmap, _) = try rasteriseCard(content, size: size, scale: Self.zoomScale)
        let crop = CGRect(
            x: bitmap.pixelsWide - Int(size.width / 2) * Self.zoomScale,
            y: 0,
            width: Int(size.width / 2) * Self.zoomScale,
            height: bitmap.pixelsHigh
        )
        let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: crop), "the zoom could not be cropped")
        let zoom = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(zoom.representation(using: .png, properties: [:]), "\(name) did not encode")
        try FileManager.default.createDirectory(at: Self.realDirectory, withIntermediateDirectories: true)
        try data.write(to: Self.realDirectory.appendingPathComponent(name), options: .atomic)
    }

    private func rasteriseCard(
        _ content: some View,
        size: CGSize,
        scale: Int
    ) throws -> (NSBitmapImageRep, Data) {
        let hosting = NSHostingView(
            rootView: MatrixPane { content }.frame(width: size.width, height: size.height)
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
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
        ), "the card render could not be allocated")
        bitmap.size = size
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        let data = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:]),
            "the card render did not encode"
        )
        return (bitmap, data)
    }
}
