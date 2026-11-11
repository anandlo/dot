import AppKit
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
        XCTAssertGreaterThanOrEqual(lit.count, 20, "the zoom holds too few lit dots to judge")
        XCTAssertGreaterThanOrEqual(lit.loudMinimumRatio, 1.25, "a loud dot is not hotter at its centre")
        XCTAssertGreaterThanOrEqual(lit.minimumRatio, 1.15, "a lit dot is not hotter at its centre")
        XCTAssertLessThanOrEqual(lit.maximumFarLift, 0.04, "a lit dot has a soft edge")
        XCTAssertEqual(liveSeparation.failing, 0, "two dots in the live grid are joined by their light")
        XCTAssertEqual(loudSeparation.failing, 0, "two dots in the loud grid are joined by their light")
        XCTAssertGreaterThanOrEqual(restingRise, 0.03, "the grid is not drawn at rest")
        XCTAssertGreaterThanOrEqual(liveP90 / max(liveP10, 0.0001), 3.0, "the grid does not carry a range")
        XCTAssertGreaterThanOrEqual(
            Double(shining) / Double(max(1, liveValues.count)),
            0.10,
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
