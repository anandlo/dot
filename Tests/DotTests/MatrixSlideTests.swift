import AppKit
import CryptoKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The lattice the drawing owns; see ``HUDWaveform/MatrixLattice``.
private typealias MatrixLattice = HUDWaveform.MatrixLattice

/// The sliding grid: its cadence, its identity, its containment, its shine and
/// the still grid a person who asked for no motion is given.
///
/// The owner reported the grid as choppy: the card's clock and the meter's own
/// clock are not aligned, and the drawing used to step a whole column whenever
/// the meter's ring gained a sample. The measurements here are of the picture:
/// one sample's dot is followed frame by frame and its displacement, its band and
/// its ink are read from the view's own list of dots, so what is described is
/// what the card drew.
///
/// No window is ever put on a display: a render is hosted off screen and captured
/// with `cacheDisplay`, exactly as ``VisualizerLiftTests`` and
/// ``VisualizerRedesignTests`` do.
@MainActor
final class MatrixSlideTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    /// The pixels per point of every render.
    static let scale = 2
    /// The recording card's waveform canvas, in points.
    static var canvas: CGSize { MatrixRenderTests.cardWaveformSize() }
    /// The pitch of the card's lattice, in points.
    static var pitch: CGFloat { MatrixLattice.pitch(forHeight: canvas.height) }

    // MARK: - MS1 Cadence

    /// The grid runs at one pitch per two ticks, on every frame.
    ///
    /// A real ``VoiceMeter`` is pushed at 240 Hz and the view is read on every
    /// fourth push, which is the sixty frames a second the card draws at. One
    /// sample pair's dot is followed from the frame it is born on until it leaves
    /// the canvas, and its displacement between two frames must be the same on
    /// every frame: a quarter of a pitch, `2.5` points on the card's five point
    /// lattice.
    func testMS1TheGridSlidesOnePitchPerPair() throws {
        let frames = Self.meteredFrames(seconds: 3)
        XCTAssertGreaterThan(frames.count, 150, "the run is too short to measure")

        // The pair that is newest on the eighth frame, then followed. A frame is
        // not promised to land on a pair boundary, so the newest pair is the one
        // with the greatest tick the frame drew.
        let birth = 8
        let tracked = frames[birth].dots(in: Self.canvas).max { $0.sampleTick < $1.sampleTick }
        let sampleTick = try XCTUnwrap(tracked?.sampleTick, "the frame drew no dot")

        var positions: [(frame: Int, x: Double)] = []
        for (index, frame) in frames.enumerated() {
            guard let dot = frame.dots(in: Self.canvas).first(where: { $0.sampleTick == sampleTick })
            else { continue }
            positions.append((index, Double(dot.centre.x)))
        }
        XCTAssertGreaterThan(positions.count, 30, "the dot was followed for only \(positions.count) frames")

        var steps: [Double] = []
        for index in 1..<positions.count {
            steps.append(positions[index - 1].x - positions[index].x)
        }
        let mean = steps.reduce(0, +) / Double(steps.count)
        let worst = steps.map { abs($0 - mean) }.max() ?? 0
        let smallest = steps.min() ?? 0
        print(String(
            format: "MS1 %d frames, sample %d, %d steps: mean %.4f pt/frame, worst deviation %.4f pt (%.2f%%), smallest %.4f pt, pitch %.2f pt",
            frames.count,
            sampleTick,
            steps.count,
            mean,
            worst,
            100 * worst / max(mean, 1e-9),
            smallest,
            Double(Self.pitch)
        ))
        XCTAssertEqual(mean, 2.50, accuracy: 0.02 * 2.50, "the grid does not run at 2.5 pt a frame")
        XCTAssertLessThanOrEqual(worst, 0.15 * mean, "a frame moved the dot by something other than the mean")
        XCTAssertGreaterThan(smallest, 0, "a frame moved the dot backwards or not at all")

        // The same cadence on the canvas the first measurements used, where the
        // pitch is a height fifth rather than the card's own five points.
        let wide = CGSize(width: 240, height: 22)
        let widePitch = Double(MatrixLattice.pitch(forHeight: wide.height))
        let wideDots = frames[birth].dots(in: wide).filter { $0.sampleTick == sampleTick }
        let wideLater = frames[birth + 1].dots(in: wide).filter { $0.sampleTick == sampleTick }
        guard let before = wideDots.first, let after = wideLater.first(where: { $0.row == before.row })
        else { return XCTFail("the wide canvas did not draw the tracked dot twice") }
        print(String(
            format: "MS1 wide canvas %.1f pt: pitch %.2f pt, one frame moved the dot %.4f pt",
            wide.width,
            widePitch,
            Double(before.centre.x - after.centre.x)
        ))
        XCTAssertEqual(
            Double(before.centre.x - after.centre.x),
            widePitch / 2,
            accuracy: 0.02 * widePitch / 2,
            "the cadence is not a quarter of a pitch on the wide canvas"
        )

        // The Settings tile draws this view on the script's clock, so the grid
        // slides there too: two frames a sixtieth of a second apart carry the same
        // pair one half-pitch further left.
        let tileSize = CGSize(width: 200, height: 22)
        func tile(_ time: Double) -> HUDWaveform {
            HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: VisualizerTile.history(at: time),
                spectrumHistory: VisualizerTile.spectrum(at: time),
                phase: DictationScript.phase(at: time),
                time: time,
                level: 0.68,
                pulse: 0.25
            )
        }
        let firstTile = tile(VisualizerTile.stillTime)
        let nextTile = tile(VisualizerTile.stillTime + 1 / VoiceMeter.sampleRate)
        var shared = 0
        for dot in firstTile.matrixDots(in: tileSize) where dot.row == 2 {
            guard let moved = nextTile.matrixDots(in: tileSize).first(where: {
                $0.sampleTick == dot.sampleTick && $0.row == 2
            }) else { continue }
            shared += 1
            XCTAssertEqual(
                Double(dot.centre.x - moved.centre.x),
                Double(MatrixLattice.pitch(forHeight: tileSize.height)) / 2,
                accuracy: 0.02,
                "the Settings tile's grid is not sliding"
            )
        }
        print("MS1 the tile shared \(shared) dots between two frames")
        XCTAssertGreaterThan(shared, 4, "the tile's two frames share no dot to follow")
    }

    // MARK: - MS2 Identity

    /// A dot's band is the same on every frame of its life.
    ///
    /// The pair is indexed on the meter's tick rather than on a slot of the ring,
    /// so the slot it is read from walks one place further into its own past every
    /// tick and the sample it holds is the same sample. The energy is compared
    /// exactly: a band that moved by one level of the ring would be a dot whose
    /// light changes while it travels, which is the choppiness itself.
    func testMS2TheDotsBandIsConstantForItsWholeLife() throws {
        let frames = Self.meteredFrames(seconds: 3)
        // The loudest pair born in the first two seconds: a dot whose band is a
        // measurement rather than the floor, with its whole life left to run.
        var loudest: (index: Int, dot: MatrixLattice.Dot)?
        for index in frames.indices.prefix(120) {
            guard let newest = frames[index].dots(in: Self.canvas).max(by: { $0.sampleTick < $1.sampleTick })
            else { continue }
            if loudest == nil || newest.energy > loudest!.dot.energy {
                loudest = (index, newest)
            }
        }
        let tracked = try XCTUnwrap(loudest, "the run drew no dot").dot
        var energies: [(frame: Int, energy: Double)] = []
        for (index, frame) in frames.enumerated() {
            guard let dot = frame.dots(in: Self.canvas).first(where: { $0.sampleTick == tracked.sampleTick })
            else { continue }
            energies.append((index, dot.energy))
        }
        XCTAssertGreaterThan(energies.count, 30, "the dot was followed for only \(energies.count) frames")
        let first = try XCTUnwrap(energies.first?.energy)
        var moved = 0
        for entry in energies where entry.energy != first {
            moved += 1
            print(String(format: "MS2 frame %d drew band %.17g, not %.17g", entry.frame, entry.energy, first))
        }
        print(String(
            format: "MS2 sample %d held %.17g on all %d frames; %d frames disagreed",
            tracked.sampleTick,
            first,
            energies.count,
            moved
        ))
        XCTAssertEqual(moved, 0, "the dot's band moved while the dot travelled")
        XCTAssertEqual(Set(energies.map(\.energy)).count, 1, "the dot's band is not one value")
    }

    // MARK: - MS3 No blob

    /// Two dots never join, at the loudest level the grid can draw.
    ///
    /// Every band at one is every dot at its widest and brightest: the darkest
    /// point between two neighbouring dots has to stay under a third of the light
    /// at a dot's centre, along a row and along a column. The haloes are added to
    /// the card with `plusLighter` and stop at half a pitch, so they meet only at
    /// the empty midpoint between two dots, where their falloff has reached zero.
    func testMS3NoTwoDotsAreJoinedAtFullLevel() throws {
        let size = Self.canvas
        let ring = [AudioSpectrumFrame](
            repeating: AudioSpectrumFrame(bands: (1, 1, 1, 1, 1)),
            count: VoiceMeter.historyLength
        )
        let view = HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: [1],
            spectrumHistory: ring,
            phase: DictationScript.phase(at: 6.96),
            time: 6.96,
            ceiling: 1
        )
        let bitmap = try rasterise(Self.pane(view), size: size)
        let dots = view.matrixDots(in: size)
        let columns = MatrixLattice.columnCount(for: size)
        XCTAssertEqual(dots.count % MatrixLattice.rows, 0, "a column of the grid is not whole")
        XCTAssertGreaterThanOrEqual(
            dots.count,
            (columns - 1) * MatrixLattice.rows,
            "the grid lost more than the column its slide is between"
        )

        func luminance(_ point: CGPoint) -> Double {
            Self.luminance(bitmap, at: (Double(point.x), Double(point.y)), scale: Self.scale)
        }
        var worstHorizontal = 0.0
        var worstVertical = 0.0
        var pairs = 0
        for dot in dots where dot.edgeFade == 1 && dot.reveal == 1 {
            for neighbour in dots where neighbour.row == dot.row
                && neighbour.column == dot.column + 1
                && neighbour.edgeFade == 1
            {
                pairs += 1
                let midpoint = CGPoint(
                    x: (dot.centre.x + neighbour.centre.x) / 2,
                    y: dot.centre.y
                )
                let ratio = luminance(midpoint) / max(min(luminance(dot.centre), luminance(neighbour.centre)), 1e-9)
                worstHorizontal = max(worstHorizontal, ratio)
            }
            for neighbour in dots where neighbour.column == dot.column
                && neighbour.row == dot.row + 1
                && neighbour.edgeFade == 1
            {
                pairs += 1
                let midpoint = CGPoint(
                    x: dot.centre.x,
                    y: (dot.centre.y + neighbour.centre.y) / 2
                )
                let ratio = luminance(midpoint) / max(min(luminance(dot.centre), luminance(neighbour.centre)), 1e-9)
                worstVertical = max(worstVertical, ratio)
            }
        }
        let brightest = dots.map { luminance($0.centre) }.max() ?? 0
        print(String(
            format: "MS3 %d pairs over %d dots at full level: worst midpoint/dot along a row %.4f, along a column %.4f, brightest centre %.4f, surface %.4f",
            pairs,
            dots.count,
            worstHorizontal,
            worstVertical,
            brightest,
            luminance(CGPoint(x: size.width - 1, y: size.height - 1))
        ))
        XCTAssertGreaterThan(pairs, 50, "too few interior pairs were measured")
        XCTAssertLessThanOrEqual(worstHorizontal, 0.35, "two dots in a row are joined by their light")
        XCTAssertLessThanOrEqual(worstVertical, 0.35, "two dots in a column are joined by their light")

        // The picture the measurement is read on.
        if let directory = Self.evidence {
            try write(Self.pane(view), size: size, named: "matrix-allmax.png", to: directory)
        }
    }

    // MARK: - MS4 Glow bound

    /// A lit dot's light ends at half a pitch from its centre.
    ///
    /// One pair of samples is lit on an otherwise silent grid, and the render is
    /// compared with the same grid with every band at zero: outside half a pitch
    /// plus half a point of the lit dot's centre no pixel may differ.
    func testMS4TheGlowIsContainedInHalfAPitch() throws {
        let size = Self.canvas
        let pitch = Double(Self.pitch)
        var ring = [AudioSpectrumFrame](repeating: .zero, count: VoiceMeter.historyLength)
        // The pair of samples four ticks back is the lit one, so the dot is
        // two pitches inside the right edge and its halo is whole.
        let lit = pow(1.0, 1.0 / 1.6)
        ring[VoiceMeter.historyLength - 5] = AudioSpectrumFrame(bands: (lit, lit, lit, lit, lit))
        ring[VoiceMeter.historyLength - 6] = AudioSpectrumFrame(bands: (lit, lit, lit, lit, lit))
        let view = HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: [0],
            spectrumHistory: ring,
            time: 62.0 / VoiceMeter.sampleRate,
            ceiling: 1
        )
        let dark = HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: [0],
            spectrumHistory: [AudioSpectrumFrame](repeating: .zero, count: VoiceMeter.historyLength),
            time: 62.0 / VoiceMeter.sampleRate,
            ceiling: 1
        )
        let dots = view.matrixDots(in: size)
        let litDots = dots.filter { $0.reveal == 1 }
        XCTAssertEqual(litDots.count, MatrixLattice.rows, "the lit pair did not draw one dot per band")
        let bitmap = try rasterise(Self.pane(view), size: size)
        let empty = try rasterise(Self.pane(dark), size: size)
        let reach = pitch / 2 + 0.5

        var worst = 0.0
        var worstAt = (x: 0, y: 0)
        var checked = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let px = Double(x) / Double(Self.scale)
                let py = Double(y) / Double(Self.scale)
                let outside = litDots.allSatisfy { dot in
                    let dx = px - Double(dot.centre.x)
                    let dy = py - Double(dot.centre.y)
                    return (dx * dx + dy * dy).squareRoot() > reach
                }
                guard outside else { continue }
                checked += 1
                let difference = abs(
                    Self.luminance(bitmap, at: (px, py), scale: Self.scale)
                        - Self.luminance(empty, at: (px, py), scale: Self.scale)
                )
                if difference > worst {
                    worst = difference
                    worstAt = (x, y)
                }
            }
        }
        print(String(
            format: "MS4 %d pixels beyond %.2f pt of the %d lit dots, worst difference %.6f at (%d, %d)",
            checked,
            reach,
            litDots.count,
            worst,
            worstAt.x,
            worstAt.y
        ))
        XCTAssertGreaterThan(checked, 1000, "nothing was measured outside the glow")
        XCTAssertEqual(worst, 0, accuracy: 1e-9, "a lit dot's light reaches past half a pitch")
    }

    // MARK: - MS5 Glint

    /// A bright dot sparkles, and only while it is new.
    ///
    /// The same frame holds a young dot and an old one at the same band, so the
    /// body and the halo under the two are the same and the only difference is the
    /// glint. The point measured is on the horizontal arm, one and a half points
    /// from a centre, outside the dot's own radius.
    func testMS5TheGlintIsOnAYoungBrightDotAndOffAnOldOne() throws {
        let size = Self.canvas
        func frame(_ display: Double, still: Bool) -> HUDWaveform {
            let energy = pow(display, 1.0 / 1.6)
            return HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: [energy],
                spectrumHistory: [AudioSpectrumFrame](
                    repeating: AudioSpectrumFrame(bands: (energy, energy, energy, energy, energy)),
                    count: VoiceMeter.historyLength
                ),
                phase: 0,
                time: 2.0 / VoiceMeter.sampleRate,
                ceiling: 1,
                reduceMotionOverride: still
            )
        }
        // Two ticks in, with the frame on the even tick, the grid stands on the
        // still lattice: column one holds the pair two ticks old. The same view
        // without motion is therefore the same picture with the glint left out,
        // which is the one difference the spark is measured on.
        let bright = frame(0.95, still: false)
        let brightNoGlint = frame(0.95, still: true)
        let dim = frame(0.70, still: false)
        let dimNoGlint = frame(0.70, still: true)
        let empty = frame(0, still: true)
        let brightBitmap = try rasterise(Self.pane(bright), size: size)
        let brightNoGlintBitmap = try rasterise(Self.pane(brightNoGlint), size: size)
        let dimBitmap = try rasterise(Self.pane(dim), size: size)
        let dimNoGlintBitmap = try rasterise(Self.pane(dimNoGlint), size: size)
        let emptyBitmap = try rasterise(Self.pane(empty), size: size)

        func dot(_ view: HUDWaveform, column: Int) throws -> MatrixLattice.Dot {
            try XCTUnwrap(
                view.matrixDots(in: size).first { $0.column == column && $0.row == 2 },
                "no dot in column \(column)"
            )
        }
        let young = try dot(bright, column: 1)
        let old = try dot(bright, column: 10)
        XCTAssertEqual(young.centre, try dot(brightNoGlint, column: 1).centre, "the two grids are not the same grid")
        XCTAssertEqual(young.age, 1.0 / 30, accuracy: 1e-9, "the young dot is not a thirtieth of a second old")
        XCTAssertGreaterThan(old.age, 0.25, "the old dot is not past the glint's life")
        XCTAssertGreaterThan(young.glint, 0, "the young bright dot carries no glint")
        XCTAssertEqual(old.glint, 0, "the old bright dot still carries a glint")
        XCTAssertEqual(try dot(dim, column: 1).glint, 0, "a dot at 0.70 carries a glint")

        /// The ink on a dot's horizontal arm, and what the same point reads
        /// without a glint.
        func arm(_ bitmap: NSBitmapImageRep, _ dot: MatrixLattice.Dot) -> Double {
            let x = Double(dot.centre.x) + 1.5
            let y = Double(dot.centre.y)
            return Self.luminance(bitmap, at: (x, y), scale: Self.scale)
                - Self.luminance(emptyBitmap, at: (x, y), scale: Self.scale)
        }
        func spark(_ bitmap: NSBitmapImageRep, _ without: NSBitmapImageRep, _ dot: MatrixLattice.Dot) -> Double {
            let x = Double(dot.centre.x) + 1.5
            let y = Double(dot.centre.y)
            return Self.luminance(bitmap, at: (x, y), scale: Self.scale)
                - Self.luminance(without, at: (x, y), scale: Self.scale)
        }
        let youngSpark = spark(brightBitmap, brightNoGlintBitmap, young)
        let oldSpark = spark(brightBitmap, brightNoGlintBitmap, old)
        let dimYoungSpark = spark(dimBitmap, dimNoGlintBitmap, try dot(dim, column: 1))
        let dimOldSpark = spark(dimBitmap, dimNoGlintBitmap, try dot(dim, column: 10))
        print(String(
            format: "MS5 at 0.95 the young dot's arm reads %.4f over the bare card (glint %.3f, spark %.4f), the old dot's %.4f (spark %.4f); at 0.70 the young dot's spark is %.4f and the old dot's %.4f",
            arm(brightBitmap, young),
            young.glint,
            youngSpark,
            arm(brightBitmap, old),
            oldSpark,
            dimYoungSpark,
            dimOldSpark
        ))
        XCTAssertGreaterThan(arm(brightBitmap, young), 0.05, "the young dot's arm is not brighter than the bare card")
        XCTAssertGreaterThan(youngSpark, 0.05, "the young bright dot's arm carries no glint")
        XCTAssertEqual(oldSpark, 0, accuracy: 1.0 / 255.0, "the old bright dot still carries a glint")
        XCTAssertEqual(dimYoungSpark, 0, accuracy: 1.0 / 255.0, "a dot below the onset carries a glint")
        XCTAssertEqual(dimOldSpark, 0, accuracy: 1.0 / 255.0, "a dot below the onset carries a glint")
    }

    // MARK: - MS6 Edges

    /// No dot is ever cut, and a dot arrives by fading in.
    ///
    /// The grid is swept over two seconds of the card's clock: every dot a frame
    /// draws has its whole body and its whole halo inside the canvas, and its ink
    /// reaches its full amount only once it has travelled a pitch. A dot is born
    /// with nothing, which is what makes the right edge a fade rather than a pop.
    func testMS6NoDotIsCutAndTheEdgeFades() throws {
        let size = Self.canvas
        let pitch = Double(Self.pitch)
        let halo = Double(MatrixLattice.glowRadius(forPitch: Self.pitch))
        let ring = [AudioSpectrumFrame](
            repeating: AudioSpectrumFrame(bands: (0.9, 0.8, 0.7, 0.6, 0.5)),
            count: VoiceMeter.historyLength
        )
        let view = HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: [0.9],
            spectrumHistory: ring,
            phase: 0,
            ceiling: 1
        )
        var dots = 0
        var cut = 0
        var fullBeforeAPitch = 0
        var shortAfterAPitch = 0
        var closest = 0.0
        for step in 0..<120 {
            var frame = view
            frame.time = 6.0 + Double(step) / VoiceMeter.sampleRate
            frame.phase = 0
            for dot in frame.matrixDots(in: size) {
                dots += 1
                if dot.centre.x - dot.radius < 0 || dot.centre.x + dot.radius > size.width {
                    cut += 1
                }
                closest = max(closest, max(
                    halo - Double(dot.centre.x),
                    Double(dot.centre.x) + halo - Double(size.width)
                ))
                // The ink the right side of the canvas leaves a dot, and how far
                // the dot has travelled: a pitch of travel is a whole fade.
                let rightFade = MeterRamp.smoothstep(
                    0,
                    1,
                    (Double(size.width) - halo - Double(dot.centre.x)) / pitch
                )
                let travel = dot.age * Double(VoiceMeter.sampleRate) / Double(MatrixLattice.ticksPerPitch)
                if travel >= 1 - 1e-9 {
                    if rightFade < 1 { shortAfterAPitch += 1 }
                } else if rightFade >= 1 {
                    fullBeforeAPitch += 1
                }
            }
        }
        print(String(
            format: "MS6 %d dots over 120 frames: %d cut, %d at full ink before a pitch of travel, %d short after it, closest halo to a side %.4f pt",
            dots,
            cut,
            fullBeforeAPitch,
            shortAfterAPitch,
            closest
        ))
        XCTAssertGreaterThan(dots, 2000, "the sweep drew too little to measure")
        XCTAssertEqual(cut, 0, "a clip of the grid draws a cut dot")
        XCTAssertEqual(fullBeforeAPitch, 0, "a dot reaches its full ink before travelling a pitch")
        XCTAssertEqual(shortAfterAPitch, 0, "a dot that has travelled a pitch is still faded")
        XCTAssertLessThanOrEqual(closest, 0, "a dot's halo crosses the canvas's side")

        // The newborn dot is nothing, which is the fade rather than a pop.
        var newborn = view
        newborn.time = 6.0
        newborn.phase = 0
        let columns = newborn.matrixDots(in: size)
        let first = columns.filter { $0.column == 0 }
        let second = columns.filter { $0.column == 1 }
        XCTAssertEqual(first.count, MatrixLattice.rows, "the newborn column is not a whole one")
        XCTAssertEqual(second.count, MatrixLattice.rows, "the second column is not a whole one")
        XCTAssertTrue(first.allSatisfy { $0.edgeFade == 0 }, "the newborn dot is not at nothing")
        XCTAssertTrue(second.allSatisfy { $0.edgeFade == 1 }, "the dot one pitch in is not at full ink")
    }

    // MARK: - MS7 Reduce motion

    /// A grid asked not to move is the same bytes at any clock.
    func testMS7ReducedMotionIsAByteIdenticalPair() throws {
        let size = Self.canvas
        let ring = Self.scriptedRing(at: 2.4)
        let history = VisualizerTile.history(at: VisualizerTile.stillTime)
        func still(time: Double, phase: Double) -> HUDWaveform {
            HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: history,
                spectrumHistory: ring,
                phase: phase,
                time: time,
                ceiling: 1,
                reduceMotionOverride: true
            )
        }
        let first = try PNG(rasterise(Self.pane(still(time: 1.0, phase: 0.25)), size: size))
        let second = try PNG(rasterise(Self.pane(still(time: 5.0 + 1.0 / 60, phase: 0.80)), size: size))
        print(String(
            format: "MS7 still at t1.00 phase 0.25 %@ (%d bytes); at t5.02 phase 0.80 %@ (%d bytes)",
            Self.hash(first),
            first.count,
            Self.hash(second),
            second.count
        ))
        XCTAssertEqual(first, second, "the reduced-motion grid moved between two clocks")
        XCTAssertEqual(Self.hash(first), Self.hash(second), "the reduced-motion grid is two pictures")

        // And it is a still grid: the fixed lattice, no glint, the glow kept.
        let dots = still(time: 5.0, phase: 0.8).matrixDots(in: size)
        XCTAssertEqual(dots.count, MatrixLattice.columnCount(for: size) * MatrixLattice.rows, "the still grid is not whole")
        XCTAssertTrue(dots.allSatisfy { $0.glint == 0 }, "the still grid carries a glint")
        XCTAssertTrue(dots.allSatisfy { $0.age == 0 }, "the still grid is drawn on a clock")
        for dot in dots {
            let fixed = MatrixLattice.centre(column: dot.column, row: dot.row, forHeight: size.height, width: size.width)
            XCTAssertEqual(dot.centre, fixed, "a still dot is not on the lattice")
        }
        XCTAssertTrue(dots.contains { $0.reveal > 0 }, "the still grid has no lit dot")
    }

    // MARK: - MS8 The other styles

    /// The other four styles draw the same bytes as the tree before the change.
    ///
    /// The frames are the ones ``VisualizerLiftTests/testBlackCardFrames`` writes,
    /// drawn through the real recording card on the black material at twice the
    /// points. The base tree's frames are written by the harness in
    /// `/tmp/dot-matrix-base`, so the comparison is two trees rather than one.
    /// They are a record of one tree rather than a fixture of this one: a later
    /// change to another style repaints its frames on purpose. The comparison
    /// therefore runs only when `DOT_MATRIX_BASE_FRAMES` names that directory.
    func testMS8TheOtherStylesAreUnchanged() throws {
        guard let path = DotMigration.environment("MATRIX_BASE_FRAMES") else {
            throw XCTSkip("DOT_MATRIX_BASE_FRAMES is not set, so nothing was compared")
        }
        let base = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else {
            throw XCTSkip("the base tree's frames are not at \(base.path)")
        }
        let size = Self.cardSize
        var compared = 0
        for visualizer in [HUDVisualizer.stretch, .filament, .silk, .haloEdge] {
            for moment in Self.moments {
                let name = String(format: "base-black-%@-t%.2f.png", Self.slug(visualizer), moment)
                let url = base.appendingPathComponent(name)
                guard let baseData = try? Data(contentsOf: url) else {
                    return XCTFail("the base tree's \(name) is missing")
                }
                let snapshot = VisualizerRedesignTests.previewSnapshot(at: moment)
                let data = try PNG(rasterise(Self.card(snapshot, visualizer, time: moment), size: size))
                let work = Self.hash(data)
                let before = Self.hash(baseData)
                compared += 1
                print("MS8 \(name) base \(before) work \(work) \(work == before ? "identical" : "DIFFERENT")")
                XCTAssertEqual(work, before, "\(visualizer) at t\(moment) is a different picture")
            }
        }
        XCTAssertEqual(compared, 8, "a style or a moment was not compared")
    }

    // MARK: - MS9 Glass

    /// The grid reads over the card's glass, on both backdrops.
    ///
    /// The material is composited by the window server, so the only picture of it
    /// is a capture of the window, at the two backdrops the material is measured
    /// on: a white page at 0.92 and a dark one at 0.12. The brightest dot is
    /// measured against the material behind it, in WCAG contrast.
    func testMS9TheGridReadsOverTheGlass() throws {
        let room = CGSize(width: 400, height: 160)
        let cardSize = Self.cardSize
        let cardRect = CGRect(
            x: (room.width - cardSize.width) / 2,
            y: (room.height - cardSize.height) / 2,
            width: cardSize.width,
            height: cardSize.height
        )
        let loud = VisualizerRedesignTests.previewSnapshot(at: Self.moments[1])
        let fullest = VisualizerRedesignTests.Snapshot(
            history: [Double](repeating: 1, count: Waveform.historyLength),
            spectrum: [AudioSpectrumFrame](
                repeating: AudioSpectrumFrame(bands: (1, 1, 1, 1, 1)),
                count: Waveform.historyLength
            ),
            ceiling: 1,
            level: 1,
            phase: loud.phase
        )
        let silence = VisualizerRedesignTests.Snapshot(
            history: [Double](repeating: 0, count: Waveform.historyLength),
            spectrum: [AudioSpectrumFrame](repeating: .zero, count: Waveform.historyLength),
            ceiling: 1,
            level: 0,
            phase: 0.4
        )
        var measured: [String: Double] = [:]
        for backdrop in [
            (name: "bright", colour: Color(red: 0.92, green: 0.92, blue: 0.92)),
            (name: "dark", colour: Color(red: 0.12, green: 0.12, blue: 0.12)),
        ] {
            let quiet = try capture(backdrop.colour, of: Self.glassCard(silence, time: Self.moments[1]), size: room)
            let picture = try capture(backdrop.colour, of: Self.glassCard(fullest, time: Self.moments[1]), size: room)
            let box = WindowCapture.Rect.points(
                cardRect,
                scaleX: CGFloat(picture.width) / room.width,
                scaleY: CGFloat(picture.height) / room.height
            )
            if picture.width != quiet.width || picture.height != quiet.height {
                return XCTFail(
                    "the window server returned the two captures at different sizes "
                        + "(\(quiet.width)x\(quiet.height) and \(picture.width)x\(picture.height))"
                )
            }
            guard let changed = WindowCapture.changedBounds(picture, quiet, threshold: 6) else {
                return XCTFail("the grid drew nothing on the \(backdrop.name) backdrop")
            }
            let region = WindowCapture.Rect(
                x: max(box.x, changed.x),
                y: max(box.y, changed.y),
                width: min(box.x + box.width, changed.x + changed.width) - max(box.x, changed.x),
                height: min(box.y + box.height, changed.y + changed.height) - max(box.y, changed.y)
            )
            var ink: [(luminance: Double, colour: (Double, Double, Double))] = []
            var materialPixels: [(luminance: Double, colour: (Double, Double, Double))] = []
            for y in region.y..<(region.y + region.height) {
                for x in region.x..<(region.x + region.width) {
                    let colour = picture.pixel(x, y)
                    let quietColour = quiet.pixel(x, y)
                    let change = abs(colour.0 - quietColour.0)
                        + abs(colour.1 - quietColour.1)
                        + abs(colour.2 - quietColour.2)
                    let entry = (WindowCapture.luminance(colour), colour)
                    if change > 6 {
                        ink.append(entry)
                    } else {
                        materialPixels.append(entry)
                    }
                }
            }
            ink.sort { $0.luminance < $1.luminance }
            materialPixels.sort { $0.luminance < $1.luminance }
            let material = materialPixels[materialPixels.count / 2]
            let brightest = ink[ink.count - 1]
            let ratio = WindowCapture.contrast(brightest.colour, material.colour)
            measured[backdrop.name] = ratio
            print(String(
                format: "MS9 glass %@: region (%d, %d, %d, %d), material %.4f, brightest %.4f, contrast %.3f:1",
                backdrop.name,
                region.x,
                region.y,
                region.width,
                region.height,
                material.luminance,
                brightest.luminance,
                ratio
            ))
            if let directory = Self.evidence {
                try write(picture, named: "matrix-glass-\(backdrop.name)-t6.96.png", to: directory)
            }
        }
        let bright = try XCTUnwrap(measured["bright"], "the bright backdrop was not measured")
        let dark = try XCTUnwrap(measured["dark"], "the dark backdrop was not measured")
        print(String(format: "MS9 the brightest dot reads %.3f:1 on the bright glass and %.3f:1 on the dark", bright, dark))
        // Offscreen windows have no display, so live light/dark Glass adaptation cannot be shown here.
        XCTAssertGreaterThan(bright, 1.4, "the brightest dot draws no visible ink against the bright glass: \(bright):1")
    }

    // MARK: - The metered frames

    /// One frame of the card: what the meter held, on the meter's clock.
    private struct Frame {
        var time: Double
        var phase: Double
        var history: [Double]
        var spectrum: [AudioSpectrumFrame]

        /// The dots this frame draws on a canvas, by the view's own rules.
        @MainActor
        func dots(in size: CGSize) -> [MatrixLattice.Dot] {
            HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: history,
                spectrumHistory: spectrum,
                phase: phase,
                time: time,
                ceiling: 1
            ).matrixDots(in: size)
        }
    }

    /// Three seconds of a voice, pushed at 240 Hz and read every fourth push.
    ///
    /// The meter is the app's own, fed the demonstration's decibels, and the
    /// spectrum is the card's path: the per-voice window, the attack and release
    /// smoothing, and the 60 Hz ring. The ring gains a sample on the tick the
    /// meter closes rather than on an accumulator of its own, so its newest slot
    /// is the tick the view reads: the grid's contract is that a sample keeps its
    /// slot while the ring advances past it, and a second clock that drifted from
    /// the meter's by a fraction of a sample would break it.
    ///
    /// - Parameter seconds: how long the run lasts.
    /// - Returns: the frames the card would draw, sixty a second.
    private static func meteredFrames(seconds: Double) -> [Frame] {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        var scale = SpectrumScale()
        var smoothed = AudioSpectrumFrame.zero
        var ring = [AudioSpectrumFrame](repeating: .zero, count: VoiceMeter.historyLength)
        var appended = -1
        var frames: [Frame] = []
        let rate = 240.0
        for step in 0...Int(seconds * rate) {
            let now = Double(step) / rate
            meter.push(decibels: -58 + DictationScript.level(at: now) * 50, now: now)
            let dt = 1 / rate
            let scaled = scale.normalise(DictationScript.bands(at: now), dt: dt)
            smoothed = MatrixRenderTests.smooth(smoothed, towards: scaled, dt: dt)
            let tick = HUDWaveform.Stretch.newestSample(at: now, phase: meter.phase)
            while appended < tick {
                ring.removeFirst()
                ring.append(smoothed)
                appended += 1
            }
            guard step % 4 == 0 else { continue }
            frames.append(Frame(time: now, phase: meter.phase, history: meter.orderedHistory, spectrum: ring))
        }
        return frames
    }

    /// The script's own bands on the card's ring at a moment.
    static func scriptedRing(at time: Double) -> [AudioSpectrumFrame] {
        DictationScript.spectrumHistory(endingAt: time)
    }

    // MARK: - The views

    /// The recording card's size, in points.
    static var cardSize: CGSize {
        CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
    }

    /// The two moments the black frames are compared at.
    static let moments: [Double] = [1.50, 6.96]

    /// Where the evidence is written, when the run asks for it.
    static var evidence: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOT_VISUALIZER_EVIDENCE"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The recording card at one moment of the demonstration, on the black
    /// material.
    static func card(
        _ snapshot: VisualizerRedesignTests.Snapshot,
        _ visualizer: HUDVisualizer,
        time: Double
    ) -> some View {
        let size = cardSize
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
            actions: HUDPreview.previewActions
        )
        .frame(width: size.width, height: size.height)
    }

    /// The recording card in the Glass material, at one moment.
    static func glassCard(
        _ snapshot: VisualizerRedesignTests.Snapshot,
        time: Double
    ) -> some View {
        let size = cardSize
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.material = .glass
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = size
        model.visualizer = .matrix
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
        .frame(width: size.width, height: size.height)
    }

    /// The card's own surface, which every render is drawn on.
    static func pane<Content: View>(_ content: Content) -> some View {
        ZStack {
            LinearGradient(
                colors: [HUDTheme.surfaceTop.opacity(0.95), HUDTheme.surfaceBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content
        }
    }

    // MARK: - The renders

    /// Rasterises a view at twice the points, off every display.
    func rasterise(_ content: some View, size: CGSize) throws -> NSBitmapImageRep {
        try Self.rasterise(content, size: size, scale: Self.scale)
    }

    /// Rasterises a view and writes its PNG into the evidence directory.
    func write(_ bitmap: NSBitmapImageRep, named name: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "\(name) did not encode")
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        print(String(format: "EVIDENCE %@ %dx%d %@", name, bitmap.pixelsWide, bitmap.pixelsHigh, Self.hash(data)))
    }

    /// Renders a view, writes it, and returns the bitmap.
    @discardableResult
    func write(_ content: some View, size: CGSize, named name: String, to directory: URL) throws -> NSBitmapImageRep {
        let bitmap = try rasterise(content, size: size)
        try write(bitmap, named: name, to: directory)
        return bitmap
    }

    /// Writes a window-server capture into the evidence directory.
    func write(_ picture: WindowCapture.Pixels, named name: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(WindowCapture.write(picture, to: url), "\(name) was not written")
        print("EVIDENCE \(name) \(picture.width)x\(picture.height)")
    }

    /// The window server's picture of a view over a backdrop, off every display.
    func capture(_ backdrop: Color, of view: some View, size: CGSize) throws -> WindowCapture.Pixels {
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
        try WindowCapture.requireUsableCapture(picture)
        return picture
    }

    /// The colour of the pixel nearest a point, in sRGB.
    static func luminance(_ bitmap: NSBitmapImageRep, at point: (x: Double, y: Double), scale: Int) -> Double {
        let x = Int((point.x * Double(scale)).rounded())
        let y = Int((point.y * Double(scale)).rounded())
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
              let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return 0 }
        return 0.2126 * colour.redComponent + 0.7152 * colour.greenComponent + 0.0722 * colour.blueComponent
    }

    /// The PNG bytes of a render.
    func PNG(_ bitmap: NSBitmapImageRep) throws -> Data {
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "the render did not encode")
    }

    /// The SHA-256 of some bytes.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The file-name stem of a visualizer.
    static func slug(_ visualizer: HUDVisualizer) -> String {
        visualizer.title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    // MARK: - Evidence

    /// Writes the pictures and the table a reviewer reads the grid from.
    ///
    /// Skipped unless `DOT_VISUALIZER_EVIDENCE` names a directory. Every frame is
    /// at twice the points; the close-up is the canvas alone at six times the
    /// points with no interpolation, so a dot's own edge is a square of pixels.
    func testEvidenceRenders() throws {
        guard let directory = Self.evidence else {
            throw XCTSkip("DOT_VISUALIZER_EVIDENCE is not set")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canvas = Self.canvas
        let ring = Self.scriptedRing(at: Self.moments[1])
        let history = VisualizerTile.history(at: Self.moments[1])
        func grid(_ time: Double, _ bands: [AudioSpectrumFrame]) -> HUDWaveform {
            HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: history,
                spectrumHistory: bands,
                phase: DictationScript.phase(at: time),
                time: time,
                ceiling: 1
            )
        }
        for moment in Self.moments {
            let bands = Self.scriptedRing(at: moment)
            let name = String(format: "matrix-black-t%.2f.png", moment)
            try write(Self.pane(grid(moment, bands)), size: canvas, named: name, to: directory)
        }

        // The close-up: the canvas at twice the points, enlarged three times
        // without interpolation, so a dot's own edge is a square of pixels.
        let closeFrame = try rasterise(Self.pane(grid(Self.moments[1], ring)), size: canvas)
        let closeUp = try Self.enlarge(closeFrame, times: 3)
        let closeData = try PNG(closeUp)
        try closeData.write(to: directory.appendingPathComponent("matrix-black-closeup-t6.96.png"), options: .atomic)
        print("EVIDENCE matrix-black-closeup-t6.96.png \(closeUp.pixelsWide)x\(closeUp.pixelsHigh) \(Self.hash(closeData))")

        // Twelve frames of a fifth of a second, stacked, so the walk is one picture.
        let strip = try Self.strip(
            from: 6.90,
            frames: 12,
            step: 1 / VoiceMeter.sampleRate,
            size: canvas,
            ring: ring,
            history: history
        )
        try write(strip, named: "matrix-strip.png", to: directory)

        // The table: one sample's dot, frame by frame, in the grid the card drew.
        try writeMotionTable(to: directory, canvas: canvas)
    }

    /// Twelve consecutive frames of the grid, stacked vertically on the card's
    /// surface.
    static func strip(
        from start: Double,
        frames: Int,
        step: Double,
        size: CGSize,
        ring: [AudioSpectrumFrame],
        history: [Double]
    ) throws -> NSBitmapImageRep {
        let frameSize = CGSize(width: size.width * CGFloat(scale), height: size.height * CGFloat(scale))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(frameSize.width),
            pixelsHigh: Int(frameSize.height) * frames,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the strip could not be allocated")
        bitmap.size = CGSize(width: frameSize.width, height: frameSize.height * CGFloat(frames))
        if let data = bitmap.bitmapData {
            memset(data, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for index in 0..<frames {
            let time = start + Double(index) * step
            let view = HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: history,
                spectrumHistory: ring,
                phase: DictationScript.phase(at: time),
                time: time,
                ceiling: 1
            )
            let frame = try Self.rasterise(Self.pane(view), size: size, scale: Self.scale)
            _ = frame.draw(in: NSRect(
                x: 0,
                y: frameSize.height * CGFloat(frames - 1 - index),
                width: frameSize.width,
                height: frameSize.height
            ))
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// Writes the motion table: the tracked dot's place and band, frame by frame.
    func writeMotionTable(to directory: URL, canvas: CGSize) throws {
        let frames = Self.meteredFrames(seconds: 3)
        // The loudest pair born in the first two seconds, so the table carries a
        // band that is a measurement rather than the floor.
        var tracked: MatrixLattice.Dot?
        for index in frames.indices.prefix(120) {
            guard let newest = frames[index].dots(in: canvas).max(by: { $0.sampleTick < $1.sampleTick })
            else { continue }
            if tracked == nil || newest.energy > tracked!.energy { tracked = newest }
        }
        guard let tracked else { return XCTFail("no dot to track") }
        var lines = ["side,frame,time,x,displacement,energy"]
        var previous: Double?
        for (index, frame) in frames.enumerated() {
            guard let dot = frame.dots(in: canvas).first(where: { $0.sampleTick == tracked.sampleTick })
            else { continue }
            let x = Double(dot.centre.x)
            let step = previous.map { $0 - x }
            lines.append(String(
                format: "work,%d,%.6f,%.4f,%@,%.17g",
                index,
                frame.time,
                x,
                step.map { String(format: "%.4f", $0) } ?? "",
                dot.energy
            ))
            previous = x
        }
        // The base tree's grid: the dot of one column, which does not move.
        for (index, frame) in frames.enumerated() {
            let column = 7
            let x = Double(MatrixLattice.centre(column: column, row: 2, forHeight: canvas.height, width: canvas.width).x)
            let energy = min(1, max(0, MatrixRenderTests.band(ring: frame.spectrum, column: column, row: 2)))
            lines.append(String(
                format: "base,%d,%.6f,%.4f,%.4f,%.17g",
                index,
                frame.time,
                x,
                0.0,
                energy
            ))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(
            to: directory.appendingPathComponent("matrix-motion.csv"),
            atomically: true,
            encoding: .utf8
        )
        print("EVIDENCE matrix-motion.csv \(lines.count - 1) rows")
    }

    /// A bitmap enlarged by whole pixels, without interpolation.
    ///
    /// Nearest neighbour is the enlargement a reviewer reads a dot's edge on: every
    /// pixel of the frame becomes a square of the same colour, so the antialiasing
    /// of the drawn dot is visible as steps rather than smoothed away.
    ///
    /// - Parameters:
    ///   - bitmap: the frame to enlarge.
    ///   - times: how many pixels each pixel becomes on each side.
    /// - Returns: the enlarged frame.
    static func enlarge(_ bitmap: NSBitmapImageRep, times: Int) throws -> NSBitmapImageRep {
        let scale = max(1, times)
        let enlarged = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: bitmap.pixelsWide * scale,
            pixelsHigh: bitmap.pixelsHigh * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the close-up could not be allocated")
        enlarged.size = CGSize(
            width: bitmap.size.width * CGFloat(scale),
            height: bitmap.size.height * CGFloat(scale)
        )
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        enlarged.setColor(colour, atX: x * scale + dx, y: y * scale + dy)
                    }
                }
            }
        }
        return enlarged
    }

}

extension MatrixSlideTests {
    /// Rasterises a view at a scale, off every display.
    ///
    /// The hosting view is never put in a window on a screen: it is laid out and
    /// asked to draw into a bitmap, so a render neither opens a window nor takes
    /// the focus from whoever is using the Mac.
    ///
    /// - Parameters:
    ///   - content: the view to draw.
    ///   - size: the canvas, in points.
    ///   - scale: the pixels per point of the render.
    /// - Returns: the render.
    static func rasterise(_ content: some View, size: CGSize, scale: Int) throws -> NSBitmapImageRep {
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
        try WindowCapture.requireRetinaBacking(window)
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
}
