import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The lattice the drawing owns; see ``HUDWaveform/MatrixLattice``.
private typealias MatrixLattice = HUDWaveform.MatrixLattice

/// The Matrix holds one measurement per dot for the whole of its travel.
///
/// The owner reported the grid as "many jerky and flashing dots". Two of the
/// causes are arithmetic. A column read its band by how far back the pair was from
/// the meter's newest sample, and that distance is even on one frame and odd on the
/// next, so the same place on the canvas presented two different measurements on
/// alternate frames. And a dot's lamp was switched on across a tenth of a warped
/// range, so a cell near the threshold went from nearly nothing to nearly a lamp
/// between two frames.
@MainActor
final class MatrixStabilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    /// The recording card's waveform canvas, in points.
    fileprivate static let canvas = CGSize(width: 140, height: 26)
    /// How long a run lasts, in seconds.
    fileprivate static let seconds: Double = 3
    /// One frame of the card's clock, in seconds.
    fileprivate static let step: Double = 1.0 / 60
    /// Where the recorded runs start: the first syllable, so a run is speech.
    fileprivate static var speech: Double { DictationScript.speechStart }

    // MARK: - One specimen per dot

    /// A dot is drawn with the measurement it was born with, on every frame of its
    /// travel.
    private func assertOneSpecimenPerDot(steady: Bool) throws {
        let frames = steady
            ? Self.steadyFrames(seconds: Self.seconds)
            : Self.frames(from: VisualizerFeed(), startingAt: Self.speech, seconds: Self.seconds)
        XCTAssertGreaterThan(frames.count, 170, "the run is too short to measure")

        var firstReading: [String: (energy: Double, frame: Int)] = [:]
        var changes: Int = 0
        var drawn = 0
        for (index, frame) in frames.enumerated() {
            for dot in frame.dots(in: Self.canvas) {
                drawn += 1
                let key = "\(dot.sampleTick):\(dot.row)"
                if let first = firstReading[key] {
                    if first.energy.bitPattern != dot.energy.bitPattern {
                        changes += 1
                        if changes <= 5 {
                            print(String(format: "B6.1 CHANGE specimen %@ frame %d %.17g -> %.17g",
                                         key, index, first.energy, dot.energy))
                        }
                    }
                } else {
                    firstReading[key] = (dot.energy, index)
                }
            }
        }
        print(String(
            format: "B6.1 %@: %d frames, %d dots drawn, %d specimens, %d readings that changed",
            steady ? "steady" : "script", frames.count, drawn, firstReading.count, changes
        ))
        XCTAssertGreaterThan(drawn, 1000, "the run drew too few dots to measure")
        XCTAssertEqual(changes, 0, "a dot changed its measurement while it was on the canvas")
    }

    func testADotReadsOneSpecimenForItsWholeLife() throws {
        try assertOneSpecimenPerDot(steady: false)
        try assertOneSpecimenPerDot(steady: true)
    }

    /// The rule the stamps replace does alternate, and this is the measurement.
    ///
    /// A ring built without stamps is read by position, which is the rule every
    /// style had before the stamps: the same specimen is then drawn from two
    /// adjacent ring entries on alternate frames. The test is the record of the
    /// defect rather than a guard on the fix.
    func testThePositionalRuleAlternatesEveryFrame() throws {
        // A ring whose neighbouring entries are plainly different, so the rule can
        // be seen at all: the demonstration's own bands are equal on many adjacent
        // ticks, which hides the alternation it is meant to show.
        let ring = (0..<VoiceMeter.historyLength).map { index in
            let band = index % 2 == 0 ? 0.20 : 0.80
            return AudioSpectrumFrame(bands: (band, band, band, band, band))
        }
        var readings: [Int: [Double]] = [:]
        for step in 0..<120 {
            let time = 1.0 + Double(step) / 60
            let view = HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: [Double](repeating: 0.5, count: VoiceMeter.historyLength),
                spectrumHistory: ring,
                phase: 0,
                time: time,
                ceiling: 1
            )
            for dot in view.matrixDots(in: Self.canvas) {
                readings[dot.sampleTick, default: []].append(dot.energy)
            }
        }
        var alternating = 0
        var measured = 0
        for (_, values) in readings where values.count >= 4 {
            measured += 1
            for index in 1..<values.count where values[index].bitPattern != values[index - 1].bitPattern {
                alternating += 1
            }
        }
        print("B6.1 positional rule: \(measured) specimens followed, \(alternating) frame-to-frame readings that changed")
        XCTAssertGreaterThan(measured, 20, "the positional rule was not measured")
        XCTAssertGreaterThan(alternating, 20, "the positional rule did not alternate, so nothing was measured")
    }

    // MARK: - No flashing

    /// A fixed place on the canvas does not flash.
    func testNoDotFlashes() throws {
        let script = Self.frames(from: VisualizerFeed(), startingAt: Self.speech, seconds: Self.seconds)
        var worstCrossings = 0
        var worstPlace = ""
        var crossers = 0
        for column in 0..<MatrixLattice.columnCount(for: Self.canvas) {
            for row in 0..<MatrixLattice.rows {
                var sequence: [Double] = []
                for frame in script {
                    guard let dot = frame.dots(in: Self.canvas)
                        .first(where: { $0.column == column && $0.row == row })
                    else { continue }
                    sequence.append(dot.reveal)
                }
                guard sequence.count > 60 else { continue }
                var crossings = 0
                var lit = sequence[0] >= 0.5
                for value in sequence.dropFirst() {
                    let nowLit = value >= 0.5
                    if nowLit != lit { crossings += 1 }
                    lit = nowLit
                }
                if Double(crossings) / Self.seconds > 2 { crossers += 1 }
                if crossings > worstCrossings {
                    worstCrossings = crossings
                    worstPlace = "column \(column) row \(row)"
                }
            }
        }
        let perSecond = Double(worstCrossings) / Self.seconds
        print(String(
            format: "B6.2 script: worst fixed place %@ crossed its lamp %d times in %.0f s (%.2f per second); %d places above 2 per second",
            worstPlace, worstCrossings, Self.seconds, perSecond, crossers
        ))
        XCTAssertLessThanOrEqual(perSecond, 2, "a fixed place on the canvas flashes more than twice a second")

        let steady = Self.steadyFrames(seconds: Self.seconds)
        var worstReversals = 0
        for column in 0..<MatrixLattice.columnCount(for: Self.canvas) {
            for row in 0..<MatrixLattice.rows {
                var sequence: [Double] = []
                for frame in steady {
                    guard let dot = frame.dots(in: Self.canvas)
                        .first(where: { $0.column == column && $0.row == row })
                    else { continue }
                    sequence.append(dot.reveal)
                }
                guard sequence.count > 60 else { continue }
                var reversals = 0
                var sign = 0.0
                for index in 1..<sequence.count {
                    let difference = sequence[index] - sequence[index - 1]
                    guard abs(difference) > 1e-12 else { continue }
                    let direction = difference > 0 ? 1.0 : -1.0
                    if sign != 0, direction != sign { reversals += 1 }
                    sign = direction
                }
                worstReversals = max(worstReversals, reversals)
            }
        }
        print(String(format: "B6.2 steady: worst fixed place reversed its light %d times in %.0f s",
                     worstReversals, Self.seconds))
        XCTAssertLessThanOrEqual(Double(worstReversals) / Self.seconds, 1,
                                 "a fixed place on a steady spectrum reverses its light more than once a second")
    }

    // MARK: - One feed, two surfaces

    /// The Settings tile and the island's preview draw the same frame.
    func testTileAndIslandDrawTheSameFrames() throws {
        let size = Self.canvas
        for moment in [0.5, 1.7, 4.25, 6.1] {
            let tileFeed = VisualizerFeed()
            let islandFeed = VisualizerFeed()
            let tile = VisualizerTile.waveform(.matrix, from: tileFeed, at: moment, halfHeights: [])
            islandFeed.advance(to: moment)
            let island = HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: islandFeed.history,
                spectrumHistory: islandFeed.ring,
                phase: islandFeed.phase,
                time: islandFeed.time,
                ceiling: 1
            )
            let tileDots = tile.matrixDots(in: size)
            let islandDots = island.matrixDots(in: size)
            XCTAssertGreaterThan(tileDots.count, 20, "the tile drew nothing at \(moment) s")
            XCTAssertEqual(tileDots.count, islandDots.count, "the two surfaces drew a different number of dots")
            for (left, right) in zip(tileDots, islandDots) {
                XCTAssertEqual(left.sampleTick, right.sampleTick, "a dot holds a different pair")
                XCTAssertEqual(left.column, right.column, "a dot stands in a different column")
                XCTAssertEqual(left.row, right.row, "a dot draws a different band")
                XCTAssertEqual(Double(left.centre.x).bitPattern, Double(right.centre.x).bitPattern, "a dot is at a different x")
                XCTAssertEqual(Double(left.centre.y).bitPattern, Double(right.centre.y).bitPattern, "a dot is at a different y")
                XCTAssertEqual(left.energy.bitPattern, right.energy.bitPattern, "a dot reads a different measurement")
                XCTAssertEqual(left.display.bitPattern, right.display.bitPattern, "a dot's lamp is a different value")
                XCTAssertEqual(left.reveal.bitPattern, right.reveal.bitPattern, "a dot's reveal is a different value")
                XCTAssertEqual(left.glint.bitPattern, right.glint.bitPattern, "a dot's glint is a different value")
            }
            let left = try MatrixSlideTests.rasterise(tile, size: size, scale: 2)
            let right = try MatrixSlideTests.rasterise(island, size: size, scale: 2)
            let difference = Self.maximumChannelDifference(left, right)
            print("B6.3 t\(moment) s: \(tileDots.count) dots, maximum channel difference \(difference)")
            XCTAssertEqual(difference, 0, "the tile and the island draw different pixels at \(moment) s")
        }
    }

    // MARK: - The glint

    /// The glint of one measurement falls as the measurement travels.
    ///
    /// With the specimen fixed the spark is a function of the measurement and of
    /// the dot's age alone, so from full ink it can only fall. The dot is also
    /// faded in at the canvas's edge over its first pitch of travel
    /// (``MatrixLattice/edgeFade``, two ticks), which is a property of where the
    /// dot is rather than of the glint: a dot born at the edge carries no ink at
    /// all, so its glint rises over those two frames before the freshness term
    /// takes it down. The criterion is therefore monotone non-increasing from the
    /// first frame that carries full edge ink, and that 33 ms rise is the edge
    /// fade-in rather than a flicker. The frames before it are printed.
    func testGlintDecaysMonotonically() throws {
        let frames = Self.steadyFrames(seconds: Self.seconds, band: 0.95)
        let samples = frames[frames.count / 2].dots(in: Self.canvas).map(\.sampleTick)
        let tracked = try XCTUnwrap(samples.min(), "the frame drew no dot")

        var ages: [Double] = []
        var inks: [Double] = []
        var fades: [Double] = []
        for frame in frames {
            guard let dot = frame.dots(in: Self.canvas).first(where: { $0.sampleTick == tracked && $0.row == 2 })
            else { continue }
            guard dot.age <= MatrixLattice.glintLife else { break }
            ages.append(dot.age)
            inks.append(dot.glint)
            fades.append(dot.edgeFade)
        }
        XCTAssertGreaterThan(inks.count, 8, "the glint's life was not followed")
        print("B6.4 glint " + zip(ages, inks).map { String(format: "%.3fs:%.4f", $0, $1) }.joined(separator: " "))
        let full = try XCTUnwrap(fades.firstIndex { $0 >= 1 }, "the dot never reached the canvas")
        for index in (full + 2)..<inks.count {
            XCTAssertLessThanOrEqual(
                inks[index], inks[index - 1],
                String(format: "the glint rose from %.6f to %.6f at %.3f s",
                       inks[index - 1], inks[index], ages[index])
            )
        }
        XCTAssertGreaterThan(inks[full], 0, "the glint is not drawn at all")
    }

    // MARK: - One bad column

    /// A column the ring does not hold is skipped, not the end of the walk.
    func testOneOutOfRangeColumnDoesNotHideTheRest() throws {
        let frames = Self.frames(from: VisualizerFeed(), startingAt: Self.speech, seconds: Self.seconds)
        let frame = frames[frames.count / 2]
        let whole = HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: frame.history,
            spectrumHistory: frame.spectrum,
            phase: frame.phase,
            time: frame.time,
            ceiling: 1
        ).matrixDots(in: Self.canvas)
        let columns = Set(whole.map(\.column))
        XCTAssertGreaterThan(columns.count, 8, "the grid is too narrow to measure")

        let middle = (columns.max() ?? 0) / 2
        let sample = try XCTUnwrap(whole.first { $0.column == middle }?.sampleTick, "the middle column drew nothing")
        var ring = frame.spectrum
        let victim = try XCTUnwrap(ring.firstIndex { $0.sample == sample }, "the ring does not hold the middle column")
        ring[victim].sample = sample - 1
        let holed = HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: frame.history,
            spectrumHistory: ring,
            phase: frame.phase,
            time: frame.time,
            ceiling: 1
        ).matrixDots(in: Self.canvas)

        let holedColumns = Set(holed.map(\.column))
        print(String(format: "B6.5 columns whole %d, with column %d missing %d",
                     columns.count, middle, holedColumns.count))
        XCTAssertFalse(holedColumns.contains(middle), "the hole was not made")
        XCTAssertEqual(holedColumns.count, columns.count - 1, "the missing column took its neighbours with it")
        XCTAssertTrue(holedColumns.contains(columns.max() ?? 0), "the columns behind the hole were dropped")
    }

    // MARK: - The smoothing ladder

    /// The two times the grid's bands are filtered at, measured against each other.
    ///
    /// The card ships 0.014 s on a rise and 0.030 s on a fall. The measure of a
    /// place's light is the ink the drawing gives its dot: `reveal * display *
    /// edgeFade`, summed over the five rows of a column. Nothing is chosen here.
    func testTheSmoothingLadder() throws {
        let pairs: [(rise: Double, fall: Double)] = [
            (0.014, 0.030), (0.014, 0.060), (0.014, 0.100), (0.014, 0.160),
            (0.040, 0.030), (0.040, 0.060), (0.040, 0.100), (0.040, 0.160),
        ]
        let gap = try XCTUnwrap(DictationScript.pauses.first { $0.kind == .clause }, "the script has no clause")
        print(String(format: "B6.4 gap: the clause after %.3f s, %.0f ms long", gap.start, gap.duration * 1000))
        print("B6.4 rise fall | reverses/s darkest column darkest frame mean crossers")
        for pair in pairs {
            let feed = VisualizerFeed(spectrum: VisualizerSpectrum(riseTau: pair.rise, fallTau: pair.fall))
            let frames = Self.frames(from: feed, startingAt: Self.speech, seconds: Self.seconds)
            var worstReversals = 0
            var crossers = 0
            for column in 0..<MatrixLattice.columnCount(for: Self.canvas) {
                for row in 0..<MatrixLattice.rows {
                    var inks: [Double] = []
                    var reveals: [Double] = []
                    for frame in frames {
                        guard let dot = frame.dots(in: Self.canvas)
                            .first(where: { $0.column == column && $0.row == row })
                        else { continue }
                        inks.append(dot.reveal * dot.display * dot.edgeFade)
                        reveals.append(dot.reveal)
                    }
                    guard inks.count > 60 else { continue }
                    var reversals = 0
                    var sign = 0.0
                    for index in 1..<inks.count {
                        let difference = inks[index] - inks[index - 1]
                        guard abs(difference) > 1e-9 else { continue }
                        let direction = difference > 0 ? 1.0 : -1.0
                        if sign != 0, direction != sign { reversals += 1 }
                        sign = direction
                    }
                    worstReversals = max(worstReversals, reversals)
                    var crossings = 0
                    var lit = reveals[0] >= 0.5
                    for value in reveals.dropFirst() {
                        let nowLit = value >= 0.5
                        if nowLit != lit { crossings += 1 }
                        lit = nowLit
                    }
                    if Double(crossings) / Self.seconds > 2 { crossers += 1 }
                }
            }
            let after = Self.frames(from: feed, startingAt: gap.start + 0.02, seconds: 0.15)
            var darkest = Double.infinity
            var dimmestMean = Double.infinity
            for frame in after {
                var columns: [Int: Double] = [:]
                for dot in frame.dots(in: Self.canvas) {
                    columns[dot.column, default: 0] += dot.reveal * dot.display * dot.edgeFade
                }
                dimmestMean = min(dimmestMean, columns.isEmpty ? 0 : columns.values.reduce(0, +) / Double(columns.count))
                darkest = min(darkest, columns.values.min() ?? 0)
            }
            print(String(
                format: "B6.4 %.3f %.3f | %d %.4f %.4f %d",
                pair.rise, pair.fall,
                Int((Double(worstReversals) / Self.seconds).rounded(.up)),
                darkest, dimmestMean, crossers
            ))
            XCTAssertGreaterThan(after.count, 5, "the breath was not measured")
            XCTAssertFalse(darkest.isInfinite, "the breath has no columns")
        }
    }

    // MARK: - The spectrum's clock is the meter's

    /// A stalled frame leaves no hole in the grid.
    ///
    /// The meter caps the time it will advance by in one call at a quarter of a
    /// second, and the drawing caps its own step at a tenth, so two clocks
    /// integrated from the frame times write different numbers of samples on a
    /// stalled frame. The spectrum therefore writes one entry per sample the meter
    /// closed, stamped with the meter's number, and a column whose sample number the
    /// ring skipped is a column the grid cannot draw.
    ///
    /// - Parameter gap: how long the stalled frame is, in seconds.
    private func assertNoHole(gap: Double) throws {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        var spectrum = VisualizerSpectrum()
        var last = 0.0
        func push(at now: Double) {
            let dt = min(max(now - last, 0), 0.1)
            meter.push(decibels: -58 + DictationScript.level(at: now) * 50, now: now)
            spectrum.advance(
                target: DictationScript.bands(at: now),
                writtenSamples: meter.writtenSamples,
                dt: dt
            )
            last = now
        }
        var now = 0.0
        push(at: now)
        while now < 1 {
            now += 1.0 / 60
            push(at: now)
        }
        let beforeGap = meter.writtenSamples
        let stampBefore = spectrum.ring.last?.sample ?? -1
        now += gap
        push(at: now)
        let afterGap = meter.writtenSamples
        let stampAfter = spectrum.ring.last?.sample ?? -1
        while now < 2 + gap {
            now += 1.0 / 60
            push(at: now)
        }
        let ring = spectrum.ring
        var breaks = 0
        for (left, right) in zip(ring, ring.dropFirst()) {
            guard let a = left.sample, let b = right.sample else { continue }
            if b != a + 1 { breaks += 1 }
        }
        print(String(
            format: "B6.6 gap %.2f s: meter writes %d -> %d (%.0f samples), ring newest %d, breaks %d",
            gap, beforeGap, afterGap, Double(afterGap - beforeGap), ring.last?.sample ?? -1, breaks
        ))
        XCTAssertEqual(breaks, 0, "the ring skipped a sample across a \(gap) s stall")
        XCTAssertEqual(ring.last?.sample, meter.writtenSamples - 1, "the newest stamp is not the meter's newest sample")
        XCTAssertEqual(stampAfter - stampBefore, afterGap - beforeGap,
                       "the ring did not gain exactly the samples the meter closed across the stall")
        // Every column the frame walks finds its measurement.
        let frame = Frame(time: 3, phase: meter.phase, history: meter.orderedHistory, spectrum: ring)
        let newest = MatrixLattice.newestPairTick(
            clock: Double(ring.last?.sample ?? 0) + min(max(meter.phase, 0), 1),
            tick: ring.last?.sample ?? 0
        )
        var misses = 0
        for column in 0..<MatrixLattice.columnLimit(for: Self.canvas) {
            let sample = newest - column * MatrixLattice.ticksPerPitch
            if MatrixLattice.offset(ofStamp: sample, in: ring) == nil { misses += 1 }
        }
        print(String(format: "B6.6 gap %.2f s: %d columns, %d without a measurement", gap, MatrixLattice.columnLimit(for: Self.canvas), misses))
        XCTAssertEqual(misses, 0, "a column of the grid has no measurement")
        XCTAssertGreaterThan(frame.dots(in: Self.canvas).count, 100, "the grid drew nothing")
    }

    func testAStallLeavesNoHoleInTheGrid() throws {
        try assertNoHole(gap: 0.2)
        try assertNoHole(gap: 0.4)
    }

    /// The spectrum writes once for every sample the meter closes.
    func testTheSpectrumWritesOnceForEveryMeterSample() throws {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        var spectrum = VisualizerSpectrum()
        var now = 0.0
        var last = 0.0
        var seed: UInt64 = 17
        var steps = 0
        while now < 3 {
            // A frame interval between 8 and 34 ms, from a fixed seed.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let fraction = Double((seed >> 33) % 10_000) / 10_000
            let interval = 0.008 + (0.034 - 0.008) * fraction
            now += interval
            let dt = min(max(now - last, 0), 0.1)
            meter.push(decibels: -58 + DictationScript.level(at: now) * 50, now: now)
            spectrum.advance(target: DictationScript.bands(at: now), writtenSamples: meter.writtenSamples, dt: dt)
            last = now
            steps += 1
        }
        let entries = spectrum.ring.compactMap(\.sample)
        let newest = entries.max() ?? -1
        print(String(
            format: "B6.7 %d frames in %.2f s, meter writes %d, ring stamps %d...%d, newest is meter-1: %@",
            steps, now, meter.writtenSamples, entries.min() ?? -1, newest,
            newest == meter.writtenSamples - 1 ? "yes" : "no"
        ))
        XCTAssertGreaterThan(meter.writtenSamples, 150, "the run is too short to measure")
        XCTAssertEqual(newest, meter.writtenSamples - 1,
                       "the newest stamp is not the meter's newest sample (stamps are 0-based)")
        XCTAssertEqual(entries.count, VoiceMeter.historyLength, "the ring is not full")
        // Every stamp is the meter's number for that sample: the ring is contiguous
        // and ends on the newest one.
        for (index, stamp) in entries.enumerated() where index > 0 {
            XCTAssertEqual(stamp, entries[index - 1] + 1, "the ring skipped a sample")
        }
    }

    // MARK: - Articulation ladder

    /// The grid's attack and release, measured for articulation rather than for
    /// flicker alone.
    ///
    /// The shipped pair is 0.040 / 0.160. A longer release holds a syllable's light
    /// across the breath after it, which is articulation: the grid should dip
    /// between two words and not go out. For each fall the three readings are
    /// printed: how often a fixed place crosses the middle of its lamp, how far the
    /// newest columns drop at the middle of a word gap against the end of the word
    /// before it, and the same flicker count taken on rendered pixels rather than on
    /// the model.
    func testTheArticulationLadder() throws {
        guard ProcessInfo.processInfo.environment["DOT_MATRIX_LADDER"] != nil else {
            throw XCTSkip("DOT_MATRIX_LADDER is not set")
        }
        let falls = [0.060, 0.100, 0.160]
        // The gaps between syllables of at least 120 ms, from the script itself.
        var gaps: [(start: Double, length: Double, previousEnd: Double)] = []
        for (before, after) in zip(DictationScript.syllables, DictationScript.syllables.dropFirst()) {
            let length = after.start - before.end
            if length >= 0.12 {
                gaps.append((before.end + length / 2, length, before.end))
            }
        }
        print("B6.8 word gaps: " + gaps.map { String(format: "%.3f s (+%.0f ms, after %.3f)", $0.start, $0.length * 1000, $0.previousEnd) }
            .joined(separator: ", "))
        for fall in falls {
            let feed = VisualizerFeed(spectrum: VisualizerSpectrum(riseTau: 0.040, fallTau: fall))
            let frames = Self.frames(from: feed, startingAt: 0, seconds: DictationScript.duration)
            // (a) the flicker number.
            var worst = 0
            var crossers = 0
            for column in 0..<MatrixLattice.columnCount(for: Self.canvas) {
                for row in 0..<MatrixLattice.rows {
                    var reveals: [Double] = []
                    for frame in frames {
                        guard let dot = frame.dots(in: Self.canvas)
                            .first(where: { $0.column == column && $0.row == row })
                        else { continue }
                        reveals.append(dot.reveal)
                    }
                    guard reveals.count > 60 else { continue }
                    var crossings = 0
                    var lit = reveals[0] >= 0.5
                    for value in reveals.dropFirst() {
                        let nowLit = value >= 0.5
                        if nowLit != lit { crossings += 1 }
                        lit = nowLit
                    }
                    if Double(crossings) / DictationScript.duration > 2 { crossers += 1 }
                    worst = max(worst, crossings)
                }
            }
            let perSecond = Double(worst) / DictationScript.duration
            // (b) the dip at the middle of every word gap.
            func ink(at time: Double) -> Double {
                guard let frame = frames.min(by: {
                    abs($0.time - time) < abs($1.time - time)
                }) else { return 0 }
                var columns: [Int: Double] = [:]
                for dot in frame.dots(in: Self.canvas) where dot.column < 3 {
                    columns[dot.column, default: 0] += dot.reveal * dot.display * dot.edgeFade
                }
                return columns.values.isEmpty ? 0 : columns.values.reduce(0, +) / Double(columns.count)
            }
            var ratios: [Double] = []
            var detail: [String] = []
            for gap in gaps {
                let end = ink(at: gap.previousEnd)
                let middle = ink(at: gap.start)
                ratios.append(end > 0 ? middle / end : 0)
                detail.append(String(format: "%.4f/%.4f", middle, end))
            }
            print("B6.8 fall \(fall) gap ink / end ink: " + detail.joined(separator: " "))
            let sorted = ratios.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            print(String(
                format: "B6.8 fall %.3f | flicker %.2f/s crossers %d | ratios %@ median %.3f",
                fall, perSecond, crossers,
                ratios.map { String(format: "%.3f", $0) }.joined(separator: " "), median
            ))
            // (c) the flicker number taken on the drawn pixels rather than on the
            // model: a 3 x 3 pixel patch at nine fixed points of the canvas.
            let drawn = MatrixLattice.columnCount(for: Self.canvas)
            let pitch = MatrixLattice.pitch(forHeight: Self.canvas.height)
            var points: [(x: Double, y: Double)] = []
            for step in 0..<3 {
                let column = Int(Double(step) * Double(drawn - 1) / 2)
                for row in [0, 2, 4] {
                    points.append((
                        Double(Self.canvas.width) - Double(pitch) / 2 - Double(column) * Double(pitch),
                        Double(MatrixLattice.centreY(row: row, forHeight: Self.canvas.height))
                    ))
                }
            }
            let scale = 2
            var reversals: [Int] = Array(repeating: 0, count: points.count)
            var previous: [Double?] = Array(repeating: nil, count: points.count)
            var lastSign: [Double] = Array(repeating: 0, count: points.count)
            for frame in frames {
                let bitmap = try MatrixSlideTests.rasterise(frame.waveform, size: Self.canvas, scale: scale)
                for (index, point) in points.enumerated() {
                    let x = Int((point.x * Double(scale)).rounded())
                    let y = Int((point.y * Double(scale)).rounded())
                    var total = 0.0
                    var count = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let px = x + dx
                            let py = y + dy
                            guard px >= 0, px < bitmap.pixelsWide, py >= 0, py < bitmap.pixelsHigh,
                                  let colour = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
                            else { continue }
                            total += 0.2126 * colour.redComponent
                                + 0.7152 * colour.greenComponent
                                + 0.0722 * colour.blueComponent
                            count += 1
                        }
                    }
                    let luminance = count == 0 ? 0 : total / Double(count)
                    if let before = previous[index] {
                        let change = luminance - before
                        if abs(change) > 0.02 {
                            let sign = change > 0 ? 1.0 : -1.0
                            if lastSign[index] != 0, sign != lastSign[index] { reversals[index] += 1 }
                            lastSign[index] = sign
                        }
                    }
                    previous[index] = luminance
                }
            }
            let sortedReversals = reversals.sorted()
            let worstPixels = Double(sortedReversals.last ?? 0) / DictationScript.duration
            let medianPixels = Double(sortedReversals[sortedReversals.count / 2]) / DictationScript.duration
            print(String(
                format: "B6.8 fall %.3f | pixel reversals/s worst %.2f median %.2f (%@)",
                fall, worstPixels, medianPixels,
                reversals.map(String.init).joined(separator: " ")
            ))
            XCTAssertGreaterThan(frames.count, 600, "the run is too short")
            XCTAssertGreaterThan(gaps.count, 2, "the script has no word gaps")
        }
    }

    // MARK: - Articulation on real speech

    /// How much light survives a word gap, on real speech.
    ///
    /// The demonstration's bands are exactly zero in its gaps, so a ratio measured
    /// on it is zero for every release. These files are continuous prose spoken by
    /// three voices at two rates, put through the recorder's own band analysis and
    /// the card's own spectrum path, so a gap is a real dip in a real voice rather
    /// than a synthetic zero.
    ///
    /// Skipped unless `DOT_FLOOR_DIR` names the directory the speech files are in.
    func testTheArticulationOnRealSpeech() throws {
        guard let directory = Self.speechDirectory else {
            throw XCTSkip("DOT_FLOOR_DIR is not set")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".wav") }
            .sorted()
        XCTAssertGreaterThanOrEqual(files.count, 6, "the speech files are missing")
        print("B6.9 rise 0.040, speech files: " + files.joined(separator: ", "))
        for fall in [0.060, 0.100, 0.160] {
            var ratios: [Double] = []
            var ends: [Double] = []
            var gapList: [String] = []
            var worstFlicker = 0.0
            var worstCrossers = 0
            for name in files {
                let samples = try FloorTrackerTests.samples(at: directory.appendingPathComponent(name))
                // The blocks the recorder would hand the card, and their levels.
                var blocks: [(level: Double, samples: ArraySlice<Double>)] = []
                var index = 0
                while index < samples.count {
                    let end = min(index + FloorTrackerTests.blockFrames, samples.count)
                    let block = samples[index..<end]
                    index = end
                    guard !block.isEmpty else { continue }
                    let sumSquares = block.reduce(0.0) { $0 + $1 * $1 }
                    let rms = (sumSquares / Double(block.count)).squareRoot()
                    blocks.append((AudioLevel.decibels(rms), block))
                }
                guard !blocks.isEmpty else { continue }
                let levels = blocks.map(\.level).sorted()
                let median = levels[levels.count / 2]
                let voicedFloor = max(-50, median - 12)
                // The gaps of at least 120 ms, in the audio's own time: a block is
                // 1024 frames at 16 kHz, 64 ms.
                var gaps: [(startBlock: Int, blocks: Int)] = []
                var runStart: Int?
                for (number, block) in blocks.enumerated() {
                    if block.level < voicedFloor {
                        if runStart == nil { runStart = number }
                    } else if let start = runStart {
                        if number - start >= 2 { gaps.append((start, number - start)) }
                        runStart = nil
                    }
                }
                // The frames the gaps ask about, and the ink read only at them.
                var blockFirstFrame: [Int] = []
                var first = 0
                for _ in blocks {
                    blockFirstFrame.append(first)
                    first += FloorTrackerTests.repeats
                }
                var wanted = Set<Int>()
                for gap in gaps {
                    wanted.insert(blockFirstFrame[gap.startBlock] + (gap.blocks * FloorTrackerTests.repeats) / 2)
                    wanted.insert(blockFirstFrame[gap.startBlock] - 1)
                }
                var inkByFrame: [Int: Double] = [:]
                // One pass over the card's frames, with the flicker state kept as it
                // goes.
                let meter = VoiceMeter()
                meter.setCalibration(nil)
                var spectrum = VisualizerSpectrum(riseTau: 0.040, fallTau: fall)
                var frame = 0
                var crossings = [Int: Int](minimumCapacity: 256)
                var lit: [Int: Bool] = [:]
                for (number, block) in blocks.enumerated() {
                    let mono = block.samples.map(Float.init)
                    let measured = AudioSpectrumFrame.measure(mono: mono, sampleRate: 16000)
                    for _ in 0..<FloorTrackerTests.repeats {
                        meter.push(decibels: block.level, now: Double(frame) / 60)
                        spectrum.advance(
                            target: measured.frame,
                            writtenSamples: meter.writtenSamples,
                            dt: 1.0 / 60
                        )
                        let view = HUDWaveform(
                            visualizer: .matrix,
                            halfHeights: [],
                            history: meter.orderedHistory,
                            spectrumHistory: spectrum.ring,
                            phase: meter.phase,
                            time: Double(frame) / 60,
                            ceiling: 1
                        )
                        let dots = view.matrixDots(in: Self.canvas)
                        for dot in dots {
                            let key = dot.column * MatrixLattice.rows + dot.row
                            let nowLit = dot.reveal >= 0.5
                            if let before = lit[key], before != nowLit {
                                crossings[key, default: 0] += 1
                            }
                            lit[key] = nowLit
                        }
                        // The ink of the newest three columns at this frame, if it is
                        // a frame a gap asks about.
                        if wanted.contains(frame) {
                            var columns: [Int: Double] = [:]
                            for dot in dots where dot.column < 3 {
                                columns[dot.column, default: 0] += dot.reveal * dot.display * dot.edgeFade
                            }
                            inkByFrame[frame] = columns.isEmpty ? 0 : columns.values.reduce(0, +) / 3
                        }
                        frame += 1
                    }
                    _ = number
                }
                // The ratios, one per gap.
                for gap in gaps {
                    let middle = blockFirstFrame[gap.startBlock] + (gap.blocks * FloorTrackerTests.repeats) / 2
                    let end = blockFirstFrame[gap.startBlock] - 1
                    let midInk = inkByFrame[middle] ?? 0
                    let endInk = inkByFrame[end] ?? 0
                    ratios.append(endInk > 0 ? midInk / endInk : 0)
                    ends.append(endInk)
                    gapList.append(String(
                        format: "%@+%.0fms:%.3f/%.3f",
                        String(name.prefix(10)), Double(gap.blocks) * 64, midInk, endInk
                    ))
                }
                let seconds = Double(frame) / 60
                let worst = crossings.values.max() ?? 0
                worstFlicker = max(worstFlicker, Double(worst) / seconds)
                var here = 0
                for value in crossings.values where Double(value) / seconds > 2 { here += 1 }
                worstCrossers = max(worstCrossers, here)
            }
            let sorted = ratios.sorted()
            let medianRatio = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let sortedEnds = ends.sorted()
            let medianEnd = sortedEnds.isEmpty ? 0 : sortedEnds[sortedEnds.count / 2]
            let degenerate = ends.filter { $0 < 0.001 }.count
            print(String(
                format: "B6.9 fall %.3f | %d gaps | ratio median %.4f max %.4f | end ink median %.4f, %d gaps with end ink < 0.001 | flicker worst %.2f/s, crossers per file max %d of 140",
                fall, ratios.count, medianRatio, sorted.last ?? 0,
                medianEnd, degenerate, worstFlicker, worstCrossers
            ))
            print("B6.9 fall \(fall) gaps: " + gapList.joined(separator: " "))
            XCTAssertGreaterThan(ratios.count, 20, "too few gaps to measure")
        }
    }

    // MARK: - Flicker facts

    /// The intervals between reveal-0.5 crossings, and the syllable onsets of the
    /// same material.
    ///
    /// A 1024-frame block at 16 kHz is 64 ms of the file and is drawn for six
    /// frames, so one card frame is 10.667 ms of the file. Every interval and rate
    /// printed here is in the file's own time, which is what the onset count uses;
    /// the reveal trajectory itself is the one the card draws.
    ///
    /// For every fixed place the crossings of the whole file are recorded, the
    /// intervals between consecutive crossings are pooled over places, and the
    /// per-place minima and medians are summarised separately. A syllable onset is
    /// an upward crossing of the 20 ms RMS envelope through 30 dB below the file's
    /// 95th percentile RMS, with a 60 ms refractory.
    ///
    /// Skipped unless `DOT_FLOOR_DIR` names the directory the speech files are in.
    func testTheFlickerFacts() throws {
        guard let directory = Self.speechDirectory else {
            throw XCTSkip("DOT_FLOOR_DIR is not set")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".wav") }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 6, "the speech files are missing")

        struct Prepared {
            let name: String
            let blocks: [(level: Double, samples: ArraySlice<Double>)]
            let bands: [AudioSpectrumFrame]
            let duration: Double
            let onsets: [Double]
        }

        var prepared: [Prepared] = []
        for name in names {
            let samples = try FloorTrackerTests.samples(at: directory.appendingPathComponent(name))
            var blocks: [(level: Double, samples: ArraySlice<Double>)] = []
            var bands: [AudioSpectrumFrame] = []
            var index = 0
            while index < samples.count {
                let end = min(index + FloorTrackerTests.blockFrames, samples.count)
                let block = samples[index..<end]
                index = end
                guard !block.isEmpty else { continue }
                let sumSquares = block.reduce(0.0) { $0 + $1 * $1 }
                let rms = (sumSquares / Double(block.count)).squareRoot()
                blocks.append((AudioLevel.decibels(rms), block))
                bands.append(AudioSpectrumFrame.measure(mono: block.map(Float.init), sampleRate: 16000).frame)
            }
            let duration = Double(samples.count) / 16000
            let onsets = Self.onsets(in: samples, sampleRate: 16000)
            prepared.append(Prepared(name: name, blocks: blocks, bands: bands, duration: duration, onsets: onsets.times))
            print(String(
                format: "R5 onsets | %@ | %.2f s | p95 %.1f dBFS | threshold %.1f dBFS | upward %d | accepted %d | %.2f/s",
                name, duration, onsets.p95Decibels, onsets.thresholdDecibels,
                onsets.upwardCrossings, onsets.times.count,
                duration > 0 ? Double(onsets.times.count) / duration : 0
            ))
        }

        struct Place {
            let key: Int
            let crossings: Int
            let under80: Int
            let under50: Int
            let minimum: Double
        }

        for fall in [0.160, 0.100] {
            var allIntervals: [Double] = []
            var placeMinima: [Double] = []
            var placeMedians: [Double] = []
            var placesUnder80 = 0
            var placesUnder50 = 0
            var worstClose: (file: String, place: Place)?
            var worstCrossings: (file: String, place: Place, rate: Double)?
            var lines: [String] = []

            func isWorse(_ place: Place, than current: Place) -> Bool {
                if place.crossings != current.crossings { return place.crossings > current.crossings }
                if place.under50 != current.under50 { return place.under50 > current.under50 }
                return place.key < current.key
            }
            func isCloser(_ place: Place, than current: Place) -> Bool {
                if place.under50 != current.under50 { return place.under50 > current.under50 }
                if place.under80 != current.under80 { return place.under80 > current.under80 }
                if place.crossings != current.crossings { return place.crossings > current.crossings }
                return place.key < current.key
            }

            for file in prepared {
                let meter = VoiceMeter()
                meter.setCalibration(nil)
                var spectrum = VisualizerSpectrum(riseTau: 0.040, fallTau: fall)
                var times: [Int: [Double]] = [:]
                var lit: [Int: Bool] = [:]
                var frame = 0
                for (number, block) in file.blocks.enumerated() {
                    for _ in 0..<FloorTrackerTests.repeats {
                        meter.push(decibels: block.level, now: Double(frame) / 60)
                        spectrum.advance(
                            target: file.bands[number],
                            writtenSamples: meter.writtenSamples,
                            dt: 1.0 / 60
                        )
                        let view = HUDWaveform(
                            visualizer: .matrix,
                            halfHeights: [],
                            history: meter.orderedHistory,
                            spectrumHistory: spectrum.ring,
                            phase: meter.phase,
                            time: Double(frame) / 60,
                            ceiling: 1
                        )
                        let dots = view.matrixDots(in: Self.canvas)
                        // A block is 64 ms of the file and occupies six frames.
                        let now = Double(frame) * 64.0 / 6.0 / 1000
                        for dot in dots {
                            let key = dot.column * MatrixLattice.rows + dot.row
                            let nowLit = dot.reveal >= 0.5
                            if let before = lit[key], before != nowLit {
                                times[key, default: []].append(now)
                            }
                            lit[key] = nowLit
                        }
                        frame += 1
                    }
                }

                var fileIntervals: [Double] = []
                var fileUnder80 = 0
                var fileUnder50 = 0
                var fileWorst: Place?
                for (key, list) in times {
                    guard list.count >= 2 else { continue }
                    var intervals: [Double] = []
                    for index in 1..<list.count {
                        intervals.append(list[index] - list[index - 1])
                    }
                    let under80 = intervals.filter { $0 < 0.080 }.count
                    let under50 = intervals.filter { $0 < 0.050 }.count
                    let place = Place(
                        key: key,
                        crossings: list.count,
                        under80: under80,
                        under50: under50,
                        minimum: intervals.min() ?? 0
                    )
                    fileIntervals.append(contentsOf: intervals)
                    allIntervals.append(contentsOf: intervals)
                    placeMinima.append(place.minimum)
                    placeMedians.append(Self.percentile(intervals, 0.5))
                    fileUnder80 += under80
                    fileUnder50 += under50
                    if under80 > 0 { placesUnder80 += 1 }
                    if under50 > 0 { placesUnder50 += 1 }
                    if let current = fileWorst {
                        if isWorse(place, than: current) { fileWorst = place }
                    } else {
                        fileWorst = place
                    }
                    if let current = worstClose?.place {
                        if isCloser(place, than: current) { worstClose = (file.name, place) }
                    } else {
                        worstClose = (file.name, place)
                    }
                    if let current = worstCrossings?.place {
                        if isWorse(place, than: current) {
                            worstCrossings = (file.name, place, Double(place.crossings) / file.duration)
                        }
                    } else {
                        worstCrossings = (file.name, place, Double(place.crossings) / file.duration)
                    }
                }

                let onsetsPerSecond = file.duration > 0 ? Double(file.onsets.count) / file.duration : 0
                let worst = fileWorst ?? Place(key: 0, crossings: 0, under80: 0, under50: 0, minimum: 0)
                let worstRate = file.duration > 0 ? Double(worst.crossings) / file.duration : 0
                let stats = Self.intervalSummary(fileIntervals)
                lines.append(String(
                    format: "R5 fall %.3f | %@ | %.2f s | onsets %d = %.2f/s | worst place c%02d r%02d crossings %d = %.2f/s | ratio %.2f | pairs %d | min %.1f p1 %.1f p5 %.1f median %.1f ms | file <80 %d <50 %d | worst place <80 %d <50 %d",
                    fall, file.name, file.duration, file.onsets.count, onsetsPerSecond,
                    worst.key / MatrixLattice.rows, worst.key % MatrixLattice.rows,
                    worst.crossings, worstRate, onsetsPerSecond > 0 ? worstRate / onsetsPerSecond : 0,
                    fileIntervals.count, stats.min, stats.p1, stats.p5, stats.median,
                    fileUnder80, fileUnder50, worst.under80, worst.under50
                ))
            }

            let all = Self.intervalSummary(allIntervals)
            print(String(
                format: "R5 fall %.3f | ALL %d pairs | min %.1f p1 %.1f p5 %.1f median %.1f ms | <80 %d, <50 %d",
                fall, allIntervals.count, all.min, all.p1, all.p5, all.median,
                allIntervals.filter { $0 < 0.080 }.count,
                allIntervals.filter { $0 < 0.050 }.count
            ))
            let minima = Self.intervalSummary(placeMinima)
            let medians = Self.intervalSummary(placeMedians)
            print(String(
                format: "R5 fall %.3f | %d places | per-place minimum min %.1f p1 %.1f p5 %.1f median %.1f ms | per-place median min %.1f p1 %.1f p5 %.1f median %.1f ms",
                fall, placeMinima.count,
                minima.min, minima.p1, minima.p5, minima.median,
                medians.min, medians.p1, medians.p5, medians.median
            ))
            print(String(
                format: "R5 fall %.3f | places with <80 ms %d, <50 ms %d | worst close %@ c%02d r%02d: <50 %d, <80 %d, crossings %d, min %.1f ms | worst crossings %@ c%02d r%02d: %d = %.2f/s",
                fall, placesUnder80, placesUnder50,
                worstClose?.file ?? "-",
                (worstClose?.place.key ?? 0) / MatrixLattice.rows,
                (worstClose?.place.key ?? 0) % MatrixLattice.rows,
                worstClose?.place.under50 ?? 0, worstClose?.place.under80 ?? 0,
                worstClose?.place.crossings ?? 0, (worstClose?.place.minimum ?? 0) * 1000,
                worstCrossings?.file ?? "-",
                (worstCrossings?.place.key ?? 0) / MatrixLattice.rows,
                (worstCrossings?.place.key ?? 0) % MatrixLattice.rows,
                worstCrossings?.place.crossings ?? 0,
                worstCrossings?.rate ?? 0
            ))
            for line in lines {
                print(line)
            }
        }
    }

    /// The 20 ms RMS envelope's upward crossings through 30 dB below its 95th
    /// percentile, 60 ms apart at least.
    fileprivate static func onsets(
        in samples: [Double],
        sampleRate: Double
    ) -> (times: [Double], p95Decibels: Double, thresholdDecibels: Double, upwardCrossings: Int) {
        let window = Int(0.020 * sampleRate)
        let hop = Int(0.010 * sampleRate)
        guard window > 0, hop > 0, samples.count >= window else { return ([], -120, -120, 0) }
        var envelope: [Double] = []
        var start = 0
        while start + window <= samples.count {
            var sum = 0.0
            for index in start..<(start + window) {
                sum += samples[index] * samples[index]
            }
            envelope.append((sum / Double(window)).squareRoot())
            start += hop
        }
        guard !envelope.isEmpty else { return ([], -120, -120, 0) }
        let sorted = envelope.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let p95Decibels = 20 * log10(max(p95, 1e-12))
        let threshold = p95 * pow(10.0, -30.0 / 20.0)
        let thresholdDecibels = 20 * log10(max(threshold, 1e-12))
        guard p95 > 0 else { return ([], p95Decibels, thresholdDecibels, 0) }
        var result: [Double] = []
        var upward = 0
        var last = -Double.infinity
        for index in 1..<envelope.count
            where envelope[index - 1] <= threshold && envelope[index] > threshold {
            upward += 1
            let time = Double(index * hop + window / 2) / sampleRate
            if time - last >= 0.060 {
                result.append(time)
                last = time
            }
        }
        return (result, p95Decibels, thresholdDecibels, upward)
    }

    fileprivate static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    fileprivate static func intervalSummary(
        _ values: [Double]
    ) -> (min: Double, p1: Double, p5: Double, median: Double) {
        guard let first = values.min() else { return (0, 0, 0, 0) }
        return (
            first * 1000,
            percentile(values, 0.01) * 1000,
            percentile(values, 0.05) * 1000,
            percentile(values, 0.5) * 1000
        )
    }

    /// Where the speech files are, when the run asks for them.
    fileprivate static var speechDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOT_FLOOR_DIR"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The shipped release holds a little light for a moment after the voice stops.
    ///
    /// The ladder above walks three releases over the whole script and rasterises
    /// nine points of every frame, which is minutes of work. This is the same
    /// property at the shipped 0.160 in one case and under a second: a step from a
    /// loud band to silence, and the smoothed band 150 ms later. A release of 0.030
    /// would have decayed to 0.007 of the step, and 0.160 leaves 0.39.
    ///
    /// The script itself cannot be the fixture for this: `DictationScript.bands(at:)`
    /// is exactly zero in its gaps, so the newest columns of the grid are dark for
    /// the whole breath whatever the release is.
    func testTheShippedReleaseHoldsALittleLight() throws {
        var spectrum = VisualizerSpectrum()
        for frame in 0..<30 {
            spectrum.advance(
                target: AudioSpectrumFrame(bands: (1, 1, 1, 1, 1)),
                writtenSamples: frame + 1,
                dt: 1.0 / 60
            )
        }
        let peak = spectrum.smoothed.bands.0
        for frame in 30..<39 {
            spectrum.advance(
                target: .zero,
                writtenSamples: frame + 1,
                dt: 1.0 / 60
            )
        }
        let after = spectrum.smoothed.bands.0
        print(String(format: "B6.10 shipped release: %.4f of a step to silence after 150 ms (peak %.4f)", after, peak))
        XCTAssertGreaterThan(peak, 0.9, "the step did not arrive")
        XCTAssertGreaterThanOrEqual(after, 0.30, "the released band decayed past the shipped release")
        XCTAssertLessThanOrEqual(after, 0.50, "the released band held more light than the shipped release")
    }

    // MARK: - The runs

    /// One frame of the card: what the feed held, on the feed's clock.
    struct Frame {
        let time: Double
        let phase: Double
        let history: [Double]
        let spectrum: [AudioSpectrumFrame]

        /// The view this frame draws.
        @MainActor fileprivate var waveform: HUDWaveform {
            HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: history,
                spectrumHistory: spectrum,
                phase: phase,
                time: time,
                ceiling: 1
            )
        }

        @MainActor fileprivate func dots(in size: CGSize) -> [HUDWaveform.MatrixLattice.Dot] {
            waveform.matrixDots(in: size)
        }
    }

    /// A steady synthetic voice: one measurement, held, sixty frames a second.
    ///
    /// The ring is stamped the way ``VisualizerSpectrum`` stamps its own. The bands
    /// are built here rather than measured because the per-voice window follows a
    /// *voice*: a band that never moves is treated as the room, the floor climbs
    /// onto it, and the band is drawn at nothing.
    fileprivate static func steadyFrames(seconds: Double, band: Double = 0.62) -> [Frame] {
        let history = [Double](repeating: 0.55, count: VoiceMeter.historyLength)
        return (0..<Int((seconds * 60).rounded())).map { index in
            let time = Double(index) / 60
            let tick = HUDWaveform.Stretch.newestSample(at: time, phase: 0)
            let ring = (0..<VoiceMeter.historyLength).map { slot in
                AudioSpectrumFrame(
                    bands: (band, band, band, band, band),
                    sample: tick - (VoiceMeter.historyLength - 1 - slot)
                )
            }
            return Frame(time: time, phase: 0, history: history, spectrum: ring)
        }
    }

    /// The frames the card draws, sixty a second, from a feed.
    fileprivate static func frames(
        from feed: VisualizerFeed,
        startingAt moment: Double = 0,
        seconds: Double
    ) -> [Frame] {
        feed.reset(from: moment - 2)
        var time = moment - 2
        while time + step <= moment + 1e-9 {
            time += step
            feed.advance(to: time)
        }
        var frames: [Frame] = []
        for _ in 0..<Int((seconds * 60).rounded()) {
            time += step
            feed.advance(to: time)
            frames.append(Frame(time: feed.time, phase: feed.phase, history: feed.history, spectrum: feed.ring))
        }
        return frames
    }

    /// The largest difference of any channel at any pixel of two renders.
    fileprivate static func maximumChannelDifference(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep) -> Int {
        guard left.pixelsWide == right.pixelsWide,
              left.pixelsHigh == right.pixelsHigh,
              let first = left.bitmapData,
              let second = right.bitmapData
        else { return .max }
        let samples = min(4, min(left.samplesPerPixel, right.samplesPerPixel))
        var worst = 0
        for y in 0..<left.pixelsHigh {
            for x in 0..<left.pixelsWide {
                let firstIndex = y * left.bytesPerRow + x * left.samplesPerPixel
                let secondIndex = y * right.bytesPerRow + x * right.samplesPerPixel
                for channel in 0..<samples {
                    worst = max(worst, abs(Int(first[firstIndex + channel]) - Int(second[secondIndex + channel])))
                }
            }
        }
        return worst
    }
}
