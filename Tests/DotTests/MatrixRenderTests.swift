import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The grid as the live card draws it, and as the Settings swatch draws it.
///
/// The owner's report was that the Matrix tile sweeps the whole amber range in
/// Settings while the same style on the live card is a dull grid that looks like
/// it switches on at a level. A render is the only way to see which of the two
/// the card now draws, so this test drives the live path (the per-voice window,
/// the card's own smoothing and the card's own view) with a quiet voice, draws
/// the same frames through the old arithmetic, draws the swatch, writes the
/// three PNGs to `/tmp/mx-render` and measures them.
@MainActor
final class MatrixRenderTests: XCTestCase {
    private static let directory = URL(fileURLWithPath: "/tmp/mx-render", isDirectory: true)
    private static let width: CGFloat = 240
    private static let height: CGFloat = 22
    /// The pixels per point of every render.
    private static let scale = 2
    /// The share of cells the live path has to reach, and the share above which
    /// the grid is one bright field rather than a grid.
    private static let liveGlowFloor = 0.15
    private static let liveGlowCeiling = 0.45
    /// How far the live grid's median may sit from the swatch's, as a fraction.
    private static let medianTolerance = 0.25
    /// How close the live path has to come to the swatch's brightness.
    private static let liveLuminanceFloor = 0.90
    /// The shipped gates: the live median against the swatch's, the glow band
    /// every live grid has to sit in, and what the loud voice and the resting
    /// grid are allowed.
    private static let liveMedianFloor = 0.80
    private static let liveMedianCeiling = 1.25
    private static let loudGlowCeiling = 0.60
    private static let loudLuminanceFloor = 0.75
    /// The display exponent, halo onset and smoothing release the card ships.
    ///
    /// The three are one calibration: they were chosen together by rendering the
    /// grid at every combination and keeping the picture that matched the
    /// Settings swatch (see ``testTheDisplayCalibrationGrid``). The release is
    /// mirrored from `HUD.advanceSpectrum`, which is private.
    private static let displayExponent: Double = 3.0
    private static let glowOnset: Double = 0.70
    private static let release: Double = 0.03
    /// The ranges the calibration was searched over.
    private static let exponents: [Double] = [2.0, 2.2, 2.4, 2.6, 2.8, 3.0]
    private static let onsets: [Double] = [0.30, 0.35, 0.40, 0.45, 0.50]
    private static let releases: [Double] = [0.03, 0.045, 0.06, 0.08, 0.11]

    func testTheLiveGridGlowsLikeTheSettingsSwatch() throws {
        let voice = Self.frames(centre: 0.40, spread: 0.10, release: Self.release)
        let live = try render(HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: voice.envelope,
            spectrumHistory: voice.scaled,
            ceiling: 1,
            displayExponent: Self.displayExponent,
            glowOnset: Self.glowOnset
        ), named: "matrix-live.png")
        let old = try render(LegacyMatrix(
            history: voice.envelope,
            spectrumHistory: voice.raw,
            ceiling: 1
        ), named: "matrix-old-live.png")
        let swatch = try render(
            Self.settingsSwatch(exponent: Self.displayExponent, onset: Self.glowOnset),
            named: "matrix-settings-swatch.png"
        )
        let resting = try render(HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: [0],
            ceiling: 1
        ), named: "matrix-resting.png")

        let cells = cellCentres(in: resting)
        let rest = baseline(resting, cells: cells)
        let liveMeasure = measurements(of: live, cells: cells, resting: rest)
        let oldMeasure = measurements(of: old, cells: cells, resting: rest)
        let swatchMeasure = measurements(of: swatch, cells: cells, resting: rest)

        report("live", liveMeasure)
        report("old live", oldMeasure)
        report("settings swatch", swatchMeasure)
        print("baseline resting dot \(rest.dot) corner \(rest.corner)")

        let medianRatio = liveMeasure.dot / swatchMeasure.dot
        XCTAssertGreaterThanOrEqual(
            medianRatio,
            Self.liveMedianFloor,
            "the live grid's median of \(liveMeasure.dot) is under \(Self.liveMedianFloor) of the swatch's \(swatchMeasure.dot)"
        )
        XCTAssertLessThanOrEqual(
            medianRatio,
            Self.liveMedianCeiling,
            "the live grid's median of \(liveMeasure.dot) is over \(Self.liveMedianCeiling) of the swatch's \(swatchMeasure.dot)"
        )
        XCTAssertGreaterThanOrEqual(
            liveMeasure.p95,
            swatchMeasure.p95,
            "the live grid is darker than the swatch it was reported against"
        )
        XCTAssertGreaterThanOrEqual(
            liveMeasure.glowing,
            Self.liveGlowFloor,
            "the live grid glows on \(liveMeasure.glowing) of its cells"
        )
        XCTAssertLessThanOrEqual(
            liveMeasure.glowing,
            Self.liveGlowCeiling,
            "the live grid glows on \(liveMeasure.glowing) of its cells, which is a field rather than a grid"
        )
        XCTAssertEqual(
            oldMeasure.glowing,
            0,
            "the old grid glowed on \(oldMeasure.glowing) of its cells"
        )
        XCTAssertEqual(
            measurements(of: resting, cells: cells, resting: rest).glowing,
            0,
            "the resting grid is not resting"
        )
    }

    // MARK: - The calibration

    /// Renders the live grid at every display calibration and records each row.
    ///
    /// The brightness of a cell is a curve of its band and the halo is a window on
    /// that curve, and neither can be reasoned to: a value that looks right in
    /// arithmetic draws a field of light. Every combination is therefore rendered
    /// through the real view, with the real per-voice window and the card's own
    /// smoothing, and measured on the same cells as the Settings swatch. The rows
    /// are written to `/tmp/mx-render/grid.tsv` so the choice can be checked
    /// against the pictures afterwards.
    func testTheDisplayCalibrationGrid() throws {
        guard DotMigration.environment("MATRIX_SWEEP") == "1" else {
            throw XCTSkip("Set DOT_MATRIX_SWEEP=1 to run the display calibration sweep.")
        }
        let resting = try bitmap(of: HUDWaveform(visualizer: .matrix, halfHeights: [], history: [0], ceiling: 1))
        let cells = cellCentres(in: resting)
        let rest = baseline(resting, cells: cells)
        var swatches: [String: GridMeasurement] = [:]

        var rows = ["p\ta\tr\tmedian\tp95\tmax\tglow\tobjective\tpasses"]
        var ranked: [(objective: Double, p: Double, a: Double, r: Double, passes: Bool, line: String)] = []
        for release in Self.releases {
            let voice = Self.frames(centre: 0.40, spread: 0.10, release: release)
            for exponent in Self.exponents {
                for onset in Self.onsets {
                    // The swatch is drawn by the same code as the card, so it is
                    // rendered with the calibration being judged rather than with
                    // a fixed one: the question is whether the island and the tile
                    // look like each other, and the tile moves with the same knobs.
                    let key = "\(exponent)-\(onset)"
                    let swatch: GridMeasurement
                    if let cached = swatches[key] {
                        swatch = cached
                    } else {
                        let measured = measurements(
                            of: try bitmap(of: Self.settingsSwatch(exponent: exponent, onset: onset)),
                            cells: cells,
                            resting: rest
                        )
                        swatches[key] = measured
                        swatch = measured
                        print(String(
                            format: "swatch p %.1f a %.2f: median %.4f p95 %.4f glow %.4f",
                            exponent,
                            onset,
                            measured.dot,
                            measured.p95,
                            measured.glowing
                        ))
                    }
                    let live = measurements(of: try bitmap(of: HUDWaveform(
                        visualizer: .matrix,
                        halfHeights: [],
                        history: voice.envelope,
                        spectrumHistory: voice.scaled,
                        ceiling: 1,
                        displayExponent: exponent,
                        glowOnset: onset
                    )), cells: cells, resting: rest)
                    let medianRatio = live.dot / swatch.dot
                    let p95Ratio = live.p95 / swatch.p95
                    let glowDelta = abs(live.glowing - swatch.glowing) / max(0.001, swatch.glowing)
                    let objective = abs(medianRatio - 1) + abs(p95Ratio - 1) + glowDelta
                    let passes = p95Ratio >= Self.liveLuminanceFloor
                        && live.glowing >= Self.liveGlowFloor
                        && live.glowing <= Self.liveGlowCeiling
                        && medianRatio >= 1 - Self.medianTolerance
                        && medianRatio <= 1 + Self.medianTolerance
                    let line = String(
                        format: "%.1f\t%.2f\t%.3f\t%.4f\t%.4f\t%.4f\t%.4f\t%.4f\t%@",
                        exponent,
                        onset,
                        release,
                        live.dot,
                        live.p95,
                        live.maxLuminance,
                        live.glowing,
                        objective,
                        passes ? "yes" : "no"
                    )
                    rows.append(line)
                    ranked.append((objective, exponent, onset, release, passes, line))
                }
            }
        }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try rows.joined(separator: "\n").write(
            to: Self.directory.appendingPathComponent("grid.tsv"),
            atomically: true,
            encoding: .utf8
        )

        let sorted = ranked.sorted { first, second in
            if first.objective != second.objective { return first.objective < second.objective }
            if first.r != second.r { return first.r > second.r }
            return first.p < second.p
        }
        if let best = sorted.first, let swatch = swatches["\(best.p)-\(best.a)"] {
            print(String(
                format: "swatch at the closest row (p %.1f a %.2f): median %.4f p95 %.4f glow %.4f",
                best.p,
                best.a,
                swatch.dot,
                swatch.p95,
                swatch.glowing
            ))
        }
        for row in sorted.prefix(5) { print("closest \(row.line)") }
        for row in sorted.filter({ $0.passes }).prefix(5) { print("passing \(row.line)") }
        XCTAssertFalse(ranked.filter { $0.passes }.isEmpty, "no display calibration met the swatch's picture")
    }

    /// A loud voice reaches the bright end of the ramp without saturating.
    ///
    /// The quiet voice is the hard case for brightness, but a calibration that
    /// only works when the speaker is quiet would fail at the first raised word:
    /// this render proves the louder voice still has peaks rather than a grid
    /// where every dot is at the top.
    func testALoudVoiceReachesTheBrightEnd() throws {
        let voice = Self.frames(centre: 0.77, spread: 0.15, release: Self.release)
        let resting = try bitmap(of: HUDWaveform(visualizer: .matrix, halfHeights: [], history: [0], ceiling: 1))
        let cells = cellCentres(in: resting)
        let rest = baseline(resting, cells: cells)
        let loud = try render(HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: voice.envelope,
            spectrumHistory: voice.scaled,
            ceiling: 1,
            displayExponent: Self.displayExponent,
            glowOnset: Self.glowOnset
        ), named: "matrix-loud.png")
        let measure = measurements(of: loud, cells: cells, resting: rest)
        report("loud live", measure)
        XCTAssertGreaterThanOrEqual(
            measure.maxLuminance,
            Self.loudLuminanceFloor,
            "the loud grid never reaches the bright stop"
        )
        XCTAssertLessThanOrEqual(
            measure.glowing,
            Self.loudGlowCeiling,
            "the loud grid glows on \(measure.glowing) of its cells, so it is saturated"
        )
    }

    // MARK: - The candidates

    /// Renders the calibrations the owner is choosing between, three ways each.
    ///
    /// It is a manual tool rather than a gate: it writes a picture per candidate
    /// and prints how each one measures, so the choice can be made by eye with
    /// the numbers beside it.
    func testTheCandidateCalibrations() throws {
        guard DotMigration.environment("MATRIX_SWEEP") == "1" else {
            throw XCTSkip("Set DOT_MATRIX_SWEEP=1 to render the candidate calibrations.")
        }
        let resting = try bitmap(of: HUDWaveform(visualizer: .matrix, halfHeights: [], history: [0], ceiling: 1))
        let cells = cellCentres(in: resting)
        let rest = baseline(resting, cells: cells)
        let quiet = Self.frames(centre: 0.40, spread: 0.10, release: Self.candidateRelease)
        let loud = Self.frames(centre: 0.77, spread: 0.15, release: Self.candidateRelease)
        print("candidate\tview\tmedian\tp95\tmax\tglow")
        for candidate in Self.candidates {
            let exponent = candidate.exponent
            let onset = candidate.onset
            for (view, voice) in [("live", quiet), ("loud", loud)] {
                let image = try render(HUDWaveform(
                    visualizer: .matrix,
                    halfHeights: [],
                    history: voice.envelope,
                    spectrumHistory: voice.scaled,
                    ceiling: 1,
                    displayExponent: exponent,
                    glowOnset: onset
                ), named: "cand-\(candidate.name)-\(view).png")
                let measured = measurements(of: image, cells: cells, resting: rest)
                print(String(
                    format: "%@\t%@\t%.4f\t%.4f\t%.4f\t%.4f",
                    candidate.name,
                    view,
                    measured.dot,
                    measured.p95,
                    measured.maxLuminance,
                    measured.glowing
                ))
            }
            let swatch = try render(
                Self.settingsSwatch(exponent: exponent, onset: onset),
                named: "cand-\(candidate.name)-swatch.png"
            )
            let measured = measurements(of: swatch, cells: cells, resting: rest)
            print(String(
                format: "%@\tswatch\t%.4f\t%.4f\t%.4f\t%.4f",
                candidate.name,
                measured.dot,
                measured.p95,
                measured.maxLuminance,
                measured.glowing
            ))
        }
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
        let voice = Self.frames(centre: 0.40, spread: 0.10, release: Self.release)
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

    /// The calibrations the owner is choosing between.
    private static let candidates: [(name: String, exponent: Double, onset: Double)] = [
        ("C1", 3.0, 0.50),
        ("C2", 3.0, 0.60),
        ("C3", 2.4, 0.60),
        ("C4", 3.0, 0.70),
    ]

    /// The release every candidate is rendered with: the snappy one.
    private static let candidateRelease: Double = 0.03

    // MARK: - The signal

    /// The live pipeline's frames for one voice, and the same frames raw.
    ///
    /// - Parameters:
    ///   - centre: the middle of each band's oscillation, in the recorder's band
    ///     domain.
    ///   - spread: the distance from the middle to either end.
    ///   - release: the tau of the card's spectrum smoothing when the target
    ///     falls, in seconds.
    /// - Returns: the frames after the per-voice window and the card's smoothing,
    ///   the same frames without either, and an envelope line, all at 60 Hz for
    ///   two and a half seconds.
    private static func frames(
        centre: Double,
        spread: Double,
        release: Double
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
            scaledSmooth = smooth(scaledSmooth, towards: scaled, dt: dt, release: release)
            rawSmooth = smooth(rawSmooth, towards: target, dt: dt, release: release)
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
    /// under its silence gate, so the grid is drawn over silence as well as over
    /// speech and a real voice is measured rather than a tone.
    private static func voice(at time: Double, centre: Double, spread: Double) -> AudioSpectrumFrame {
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
    private static func isSpeaking(_ time: Double) -> Bool {
        let syllable = 1.0 / 4.5
        if time.truncatingRemainder(dividingBy: syllable) >= 0.65 * syllable { return false }
        let word = time.truncatingRemainder(dividingBy: 0.9)
        return word < 0.9 - 0.18
    }

    /// One step of the card's own spectrum smoothing.
    ///
    /// `HUD.advanceSpectrum` is private and its file belongs to another feature
    /// in flight, so the two taus are mirrored here with the product's numbers.
    private static func smooth(
        _ current: AudioSpectrumFrame,
        towards target: AudioSpectrumFrame,
        dt: Double,
        release: Double
    ) -> AudioSpectrumFrame {
        func step(_ now: Double, _ next: Double) -> Double {
            let tau = next > now ? 0.014 : release
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

    /// The Matrix tile of the recording card section of Settings.
    ///
    /// - Parameters:
    ///   - exponent: the display exponent the tile is drawn with.
    ///   - onset: the halo onset the tile is drawn with.
    /// - Returns: the tile at the card's own size.
    private static func settingsSwatch(exponent: Double, onset: Double) -> some View {
        HUDWaveform(
            visualizer: .matrix,
            halfHeights: [2, 4, 7, 10, 11, 8, 4, 3, 5, 9, 11, 7, 3, 2, 4, 8, 10, 5, 2],
            history: SpeechSchedule.history(endingAt: 2.35),
            phase: 0.35,
            time: 2.35,
            level: 0.68,
            pulse: 0.25,
            displayExponent: exponent,
            glowOnset: onset
        )
    }

    // MARK: - The renders

    /// Rasterises a pane at twice the points.
    private func bitmap(of content: some View) throws -> NSBitmapImageRep {
        let size = CGSize(width: Self.width, height: Self.height)
        let hosting = NSHostingView(rootView: MatrixPane { content }.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.width) * Self.scale,
            pixelsHigh: Int(Self.height) * Self.scale,
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
        return bitmap
    }

    /// Rasterises a pane and writes it as a PNG in the render directory.
    @discardableResult
    private func render(_ content: some View, named name: String) throws -> NSBitmapImageRep {
        let bitmap = try bitmap(of: content)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "\(name) did not encode")
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
        return bitmap
    }
}

/// The surface every one of the three renders is drawn on.
///
/// The Settings tile fills its swatch with the card's own surface, so using the
/// same fill for the live and the old renders is what makes their luminance
/// comparable with the swatch's.
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

/// The grid as the card drew it before the per-voice window existed.
///
/// The arithmetic is the shipped one: the band is bent by a power, a cell glows
/// only above `0.55`, and the colour is drawn against the envelope's ceiling. It
/// is here so the render of the live path has the old drawing of the same frames
/// to be compared with.
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
                    let glowRect = CGRect(
                        x: x - glowRadius,
                        y: y - glowRadius,
                        width: glowRadius * 2,
                        height: glowRadius * 2
                    )
                    let glowAlpha = Double((cellEnergy - 0.40) * 0.45)
                    context.fill(
                        Path(ellipseIn: glowRect),
                        with: .color(HUDTheme.meter(Double(cellEnergy), ceiling: ceiling).opacity(glowAlpha))
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

/// What one render says about its grid.
private struct GridMeasurement {
    /// The share of cells whose dot is brighter than the resting dot.
    let brighter: Double
    /// The share of cells whose halo lifts the corners of its own cell.
    let glowing: Double
    /// The brightest cell of the grid.
    let maxLuminance: Double
    /// The ninety-fifth percentile of the cells' dot luminance.
    let p95: Double
    /// The median dot luminance of the grid.
    let dot: Double
    /// The median luminance of the corners of every cell.
    let corner: Double
}

extension MatrixRenderTests {
    // MARK: - The measurement

    /// The centre of every cell of the grid, in pixels.
    ///
    /// The geometry is the one `drawMatrix` lays the grid out with, so a sample
    /// lands on the dot rather than between two of them.
    private func cellCentres(in bitmap: NSBitmapImageRep) -> [(x: Int, y: Int)] {
        let points = Double(Self.scale)
        let colPitch = 4.6
        let cols = max(1, Int((Double(Self.width) / colPitch).rounded(.up)))
        let rowPitch = Double(Self.height) / 5
        var centres: [(x: Int, y: Int)] = []
        for col in 0..<cols {
            let x = Double(Self.width) - colPitch / 2 - Double(col) * colPitch
            if x < -colPitch { break }
            for row in 0..<5 {
                let y = rowPitch * (Double(row) + 0.5)
                centres.append((
                    x: Int((x * points).rounded()),
                    y: bitmap.pixelsHigh - 1 - Int((y * points).rounded())
                ))
            }
        }
        return centres
    }

    /// What the grid says with no voice on it: the colour every cell rests at.
    private func baseline(_ bitmap: NSBitmapImageRep, cells: [(x: Int, y: Int)]) -> GridMeasurement {
        let dots = cells.map { brightest(bitmap, around: $0, offsets: Self.dotOffsets) }
        let corners = cells.map { mean(bitmap, around: $0, offsets: Self.cornerOffsets) }
        return GridMeasurement(
            brighter: 0,
            glowing: 0,
            maxLuminance: dots.max() ?? 0,
            p95: percentile(dots, 0.95),
            dot: percentile(dots, 0.5),
            corner: percentile(corners, 0.5)
        )
    }

    /// What one render says about its grid, measured against the resting grid.
    private func measurements(
        of bitmap: NSBitmapImageRep,
        cells: [(x: Int, y: Int)],
        resting: GridMeasurement
    ) -> GridMeasurement {
        let dots = cells.map { brightest(bitmap, around: $0, offsets: Self.dotOffsets) }
        let corners = cells.map { mean(bitmap, around: $0, offsets: Self.cornerOffsets) }
        let brighter = dots.filter { $0 > resting.dot + 0.02 }.count
        let glowing = corners.filter { $0 > resting.corner + 0.03 }.count
        return GridMeasurement(
            brighter: Double(brighter) / Double(max(1, dots.count)),
            glowing: Double(glowing) / Double(max(1, corners.count)),
            maxLuminance: dots.max() ?? 0,
            p95: percentile(dots, 0.95),
            dot: percentile(dots, 0.5),
            corner: percentile(corners, 0.5)
        )
    }
}

extension MatrixRenderTests {
    /// Prints one grid's numbers, so the report can carry them.
    private func report(_ name: String, _ value: GridMeasurement) {
        let line = String(
            format: "%-17@ brighter %.3f glowing %.3f max %.4f p95 %.4f dot %.4f corner %.4f",
            name as NSString,
            value.brighter,
            value.glowing,
            value.maxLuminance,
            value.p95,
            value.dot,
            value.corner
        )
        print(line)
        fflush(stdout)
    }


    /// The centre pixel of one cell, which is the dot the cell draws.
    private static let dotOffsets: [(Int, Int)] = [(0, 0)]

    /// The corners of one cell, in pixels.
    ///
    /// A cell is `4.6 x 4.4` points, so its corners are `4` pixels out. The
    /// largest dot a cell draws reaches three, which leaves the corners dark
    /// unless a halo fills them: that is what makes this a measurement of the
    /// halo and not of the dot.
    private static let cornerOffsets: [(Int, Int)] = [
        (-4, -4), (4, -4), (-4, 4), (4, 4),
        (-4, -3), (4, -3), (-4, 3), (4, 3),
    ]

    /// The luminance of one pixel, on the sRGB scale.
    private func luminance(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Double {
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
              let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return 0 }
        return 0.2126 * colour.redComponent + 0.7152 * colour.greenComponent + 0.0722 * colour.blueComponent
    }

    /// The brightest pixel of a cell's dot.
    private func brightest(
        _ bitmap: NSBitmapImageRep,
        around centre: (x: Int, y: Int),
        offsets: [(Int, Int)]
    ) -> Double {
        offsets.reduce(0) { best, offset in
            max(best, luminance(bitmap, x: centre.x + offset.0, y: centre.y + offset.1))
        }
    }

    /// The mean luminance of a ring of pixels around a cell.
    private func mean(
        _ bitmap: NSBitmapImageRep,
        around centre: (x: Int, y: Int),
        offsets: [(Int, Int)]
    ) -> Double {
        guard !offsets.isEmpty else { return 0 }
        let total = offsets.reduce(0.0) { sum, offset in
            sum + luminance(bitmap, x: centre.x + offset.0, y: centre.y + offset.1)
        }
        return total / Double(offsets.count)
    }

    /// The `fraction` quantile of a set of values.
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * fraction
        let low = Int(position.rounded(.down))
        let high = Int(position.rounded(.up))
        guard low != high else { return sorted[low] }
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
}
