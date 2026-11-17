import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The lattice the drawing owns; see ``HUDWaveform/MatrixLattice``.
private typealias MatrixLattice = HUDWaveform.MatrixLattice

/// Visible flashes on the grid, and the syllable modulation of the same files.
///
/// A flash is a rise of the drawn brightness by at least 0.30 followed by a fall
/// of at least 0.30 from the peak, or a fall of at least 0.30 followed by a rise of
/// at least 0.30, with both legs inside one window. The drawn brightness is
/// `display * reveal`, the lamp value after the reveal. Durations are in the file's
/// time: a 1024-frame block at 16 kHz is 64 ms and is drawn for six frames, so one
/// card frame is 10.667 ms of the file.
///
/// Skipped unless `DOT_FLOOR_DIR` names the directory the speech files are in.
@MainActor
final class FlashFactsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    /// The recording card's waveform canvas, in points.
    static let canvas = CGSize(width: 140, height: 26)
    /// One card frame in the file's time, in seconds.
    static let audioPerFrame = 64.0 / 6.0 / 1000
    /// The smallest rise and fall a flash must carry.
    static let flashAmplitude = 0.30

    struct Prepared {
        let name: String
        let blocks: [(level: Double, samples: ArraySlice<Double>)]
        let bands: [AudioSpectrumFrame]
        let duration: Double
    }

    struct PlaceKey: Hashable {
        let file: String
        let place: Int
    }

    struct Stats {
        var total = 0
        var durations: [Double] = []
        var observed = 0.0
        var fastRises = 0
        var fastFalls = 0
        var perPlace: [PlaceKey: Int] = [:]
    }

    func testTheFlashFacts() throws {
        guard let directory = Self.speechDirectory else {
            throw XCTSkip("DOT_FLOOR_DIR is not set")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".wav") }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 6, "the speech files are missing")

        var prepared: [Prepared] = []
        for name in names {
            prepared.append(try Self.prepare(name: name, directory: directory))
        }

        var peaks: [(name: String, energy: Double)] = []
        var stats: [String: Stats] = [:]
        let conditions: [(label: String, rise: Double, fall: Double)] = [
            ("0.160", VisualizerSpectrum.riseTau, 0.160),
            ("0.100", VisualizerSpectrum.riseTau, 0.100),
            ("0", 0, 0),
        ]

        for file in prepared {
            for condition in conditions {
                let meter = VoiceMeter()
                meter.setCalibration(nil)
                var spectrum = VisualizerSpectrum(riseTau: condition.rise, fallTau: condition.fall)
                var samplesByPlace: [Int: [(frame: Int, value: Double)]] = [:]
                var peakLevel = 0.0
                var frame = 0
                for (number, block) in file.blocks.enumerated() {
                    for _ in 0..<FloorTrackerTests.repeats {
                        meter.push(decibels: block.level, now: Double(frame) / 60)
                        spectrum.advance(
                            target: file.bands[number],
                            writtenSamples: meter.writtenSamples,
                            dt: 1.0 / 60
                        )
                        peakLevel = max(peakLevel, meter.level)
                        let view = HUDWaveform(
                            visualizer: .matrix,
                            halfHeights: [],
                            history: meter.orderedHistory,
                            spectrumHistory: spectrum.ring,
                            phase: meter.phase,
                            time: Double(frame) / 60,
                            ceiling: 1
                        )
                        for dot in view.matrixDots(in: Self.canvas) {
                            let key = dot.column * MatrixLattice.rows + dot.row
                            samplesByPlace[key, default: []].append((frame, dot.display * dot.reveal))
                        }
                        frame += 1
                    }
                }
                if condition.label == "0.160" {
                    peaks.append((file.name, VisualizerMath.displayEnergy(peakLevel)))
                }
                for window in [0.100, 0.200] {
                    let key = "\(condition.label)|\(window)"
                    for (place, samples) in samplesByPlace {
                        let flashes = Self.flashes(in: samples, maxDuration: window)
                        stats[key, default: Stats()].total += flashes.count
                        stats[key, default: Stats()].durations.append(contentsOf: flashes.durations)
                        stats[key, default: Stats()].observed += flashes.observed
                        let legs = Self.fastLegs(in: samples, maxDuration: window)
                        stats[key, default: Stats()].fastRises += legs.rises
                        stats[key, default: Stats()].fastFalls += legs.falls
                        if flashes.count > 0 {
                            stats[key, default: Stats()].perPlace[PlaceKey(file: file.name, place: place), default: 0] += flashes.count
                        }
                    }
                }
            }
        }

        for peak in peaks {
            print(String(format: "R6 peak display | %@ | %.4f", peak.name, peak.energy))
        }
        print(String(
            format: "R6 peak display | median of %d files %.4f",
            peaks.count, Self.median(peaks.map(\.energy))
        ))

        for condition in conditions {
            for window in [0.100, 0.200] {
                let key = "\(condition.label)|\(window)"
                guard let value = stats[key] else { continue }
                let observed = value.observed
                let rate = observed > 0 ? Double(value.total) / observed : 0
                let worst = value.perPlace.max { left, right in
                    if left.value != right.value { return left.value < right.value }
                    if left.key.place != right.key.place { return left.key.place > right.key.place }
                    return left.key.file > right.key.file
                }
                let summary = Self.intervalSummary(value.durations)
                print(String(
                    format: "R6 flash | fall %@ | W %.0f ms file (%.1f ms card) | total %d | place-seconds %.1f | %.3f/place-s | worst %@ c%02d r%02d %d | durations n %d min %.1f p5 %.1f p25 %.1f median %.1f p75 %.1f p95 %.1f max %.1f ms",
                    condition.label, window * 1000, window * 1000 / 0.64,
                    value.total, observed, rate,
                    worst?.key.file ?? "-",
                    (worst?.key.place ?? 0) / MatrixLattice.rows,
                    (worst?.key.place ?? 0) % MatrixLattice.rows,
                    worst?.value ?? 0,
                    value.durations.count, summary.min, summary.p5, summary.p25,
                    summary.median, summary.p75, summary.p95, summary.max
                ))
                print("R6 flash histogram | fall \(condition.label) | W \(Int(window * 1000)) ms: "
                    + Self.histogram(value.durations, width: window, bin: 0.020))
                print(String(
                    format: "R6 legs | fall %@ | W %.0f ms | rises >= 0.30 within W %d | falls >= 0.30 within W %d",
                    condition.label, window * 1000, value.fastRises, value.fastFalls
                ))
            }
        }

        for file in prepared {
            let samples = try FloorTrackerTests.samples(
                at: directory.appendingPathComponent(file.name)
            )
            let syllable = Self.syllableOnsets(in: samples, sampleRate: 16000)
            let duration = file.duration
            print(String(
                format: "R6 syllable | %@ | %.2f s | signed %d = %.2f/s | rectified %d = %.2f/s",
                file.name, duration, syllable.signed.count,
                duration > 0 ? Double(syllable.signed.count) / duration : 0,
                syllable.rectified.count,
                duration > 0 ? Double(syllable.rectified.count) / duration : 0
            ))
        }
    }

    /// Reads one file into the blocks and bands the card sees.
    fileprivate static func prepare(name: String, directory: URL) throws -> Prepared {
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
        return Prepared(
            name: name,
            blocks: blocks,
            bands: bands,
            duration: Double(samples.count) / 16000
        )
    }

    /// The flashes of one place's brightness, split at any frame where the place
    /// was not drawn.
    fileprivate static func flashes(
        in samples: [(frame: Int, value: Double)],
        maxDuration: Double
    ) -> (count: Int, durations: [Double], observed: Double) {
        let points = turningPoints(in: samples)
        var count = 0
        var durations: [Double] = []
        for cleaned in points.runs {
            var index = 0
            while index + 2 < cleaned.count {
                let first = cleaned[index]
                let middle = cleaned[index + 1]
                let last = cleaned[index + 2]
                var firstLeg = 0.0
                var secondLeg = 0.0
                if !first.isPeak && middle.isPeak && !last.isPeak {
                    firstLeg = middle.value - first.value
                    secondLeg = middle.value - last.value
                } else if first.isPeak && !middle.isPeak && last.isPeak {
                    firstLeg = first.value - middle.value
                    secondLeg = last.value - middle.value
                } else {
                    index += 1
                    continue
                }
                let duration = Double(last.frame - first.frame) * audioPerFrame
                if firstLeg >= flashAmplitude, secondLeg >= flashAmplitude, duration <= maxDuration {
                    count += 1
                    durations.append(duration)
                    index += 2
                } else {
                    index += 1
                }
            }
        }
        return (count, durations, points.observed)
    }

    /// Single legs that clear the amplitude inside a window, whether or not the
    /// other leg follows in time.
    fileprivate static func fastLegs(
        in samples: [(frame: Int, value: Double)],
        maxDuration: Double
    ) -> (rises: Int, falls: Int) {
        let points = turningPoints(in: samples)
        var rises = 0
        var falls = 0
        for cleaned in points.runs {
            guard cleaned.count >= 2 else { continue }
            for index in 1..<cleaned.count {
                let first = cleaned[index - 1]
                let second = cleaned[index]
                let duration = Double(second.frame - first.frame) * audioPerFrame
                guard duration <= maxDuration else { continue }
                if !first.isPeak && second.isPeak && second.value - first.value >= flashAmplitude {
                    rises += 1
                } else if first.isPeak && !second.isPeak && first.value - second.value >= flashAmplitude {
                    falls += 1
                }
            }
        }
        return (rises, falls)
    }

    /// The turning points of each contiguous run of one place's brightness.
    fileprivate static func turningPoints(
        in samples: [(frame: Int, value: Double)]
    ) -> (runs: [[(frame: Int, value: Double, isPeak: Bool)]], observed: Double) {
        var runs: [[(frame: Int, value: Double)]] = []
        var current: [(frame: Int, value: Double)] = []
        for sample in samples {
            if let last = current.last, sample.frame != last.frame + 1 {
                if !current.isEmpty { runs.append(current) }
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { runs.append(current) }

        var observed = 0.0
        var output: [[(frame: Int, value: Double, isPeak: Bool)]] = []
        for run in runs {
            if let first = run.first, let last = run.last {
                observed += Double(last.frame - first.frame) * audioPerFrame
            }
            guard run.count >= 3 else { continue }
            var extrema: [(frame: Int, value: Double, isPeak: Bool)] = []
            for index in 1..<(run.count - 1) {
                let previous = run[index - 1].value
                let value = run[index].value
                let next = run[index + 1].value
                if value >= previous && value > next {
                    extrema.append((run[index].frame, value, true))
                } else if value <= previous && value < next {
                    extrema.append((run[index].frame, value, false))
                }
            }
            var cleaned: [(frame: Int, value: Double, isPeak: Bool)] = []
            for point in extrema {
                if let last = cleaned.last, last.isPeak == point.isPeak {
                    if (point.isPeak && point.value > last.value)
                        || (!point.isPeak && point.value < last.value) {
                        cleaned[cleaned.count - 1] = point
                    }
                } else {
                    cleaned.append(point)
                }
            }
            output.append(cleaned)
        }
        return (output, observed)
    }

    /// The 4-16 Hz band of the 20 ms RMS envelope, and its upward crossings of
    /// twice its running median (6 dB), 80 ms apart at least.
    fileprivate static func syllableOnsets(
        in samples: [Double],
        sampleRate: Double
    ) -> (signed: [Double], rectified: [Double]) {
        let window = Int(0.020 * sampleRate)
        let hop = Int(0.010 * sampleRate)
        guard window > 0, hop > 0, samples.count >= window else { return ([], []) }
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
        guard envelope.count >= 3 else { return ([], []) }
        let rate = sampleRate / Double(hop)
        let band = bandPass(envelope, sampleRate: rate)
        let median = runningMedian(band, halfWindow: Int(rate / 2))
        let threshold = median.map { $0 * pow(10.0, 6.0 / 20.0) }
        let signed = crossings(band, threshold: threshold, refractory: 0.080, hop: 1 / rate)
        let magnitude = band.map { abs($0) }
        let magnitudeMedian = runningMedian(magnitude, halfWindow: Int(rate / 2))
        let magnitudeThreshold = magnitudeMedian.map { $0 * pow(10.0, 6.0 / 20.0) }
        let rectified = crossings(
            magnitude,
            threshold: magnitudeThreshold,
            refractory: 0.080,
            hop: 1 / rate
        )
        return (signed, rectified)
    }

    /// A second-order Butterworth band-pass, 4 Hz to 16 Hz, at the envelope's rate.
    fileprivate static func bandPass(_ values: [Double], sampleRate: Double) -> [Double] {
        let lower = 4.0
        let upper = 16.0
        let centre = (lower * upper).squareRoot()
        let q = centre / (upper - lower)
        let omega = 2 * Double.pi * centre / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        let b0 = alpha / a0
        let b2 = -alpha / a0
        let a1 = -2 * cosine / a0
        let a2 = (1 - alpha) / a0
        var output = [Double](repeating: 0, count: values.count)
        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0
        for index in values.indices {
            let x = values[index]
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            output[index] = y
        }
        return output
    }

    fileprivate static func runningMedian(_ values: [Double], halfWindow: Int) -> [Double] {
        var result = [Double](repeating: 0, count: values.count)
        for index in values.indices {
            let lower = max(0, index - halfWindow)
            let upper = min(values.count, index + halfWindow + 1)
            let window = values[lower..<upper].sorted()
            result[index] = window[window.count / 2]
        }
        return result
    }

    fileprivate static func crossings(
        _ signal: [Double],
        threshold: [Double],
        refractory: Double,
        hop: Double
    ) -> [Double] {
        var result: [Double] = []
        var last = -Double.infinity
        for index in 1..<signal.count
            where signal[index - 1] <= threshold[index] && signal[index] > threshold[index] {
            let time = Double(index) * hop
            if time - last >= refractory {
                result.append(time)
                last = time
            }
        }
        return result
    }

    fileprivate static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        if sorted.count % 2 == 1 { return sorted[sorted.count / 2] }
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    fileprivate static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    fileprivate static func intervalSummary(
        _ values: [Double]
    ) -> (min: Double, p5: Double, p25: Double, median: Double, p75: Double, p95: Double, max: Double) {
        guard let first = values.min(), let last = values.max() else {
            return (0, 0, 0, 0, 0, 0, 0)
        }
        return (
            first * 1000,
            percentile(values, 0.05) * 1000,
            percentile(values, 0.25) * 1000,
            percentile(values, 0.5) * 1000,
            percentile(values, 0.75) * 1000,
            percentile(values, 0.95) * 1000,
            last * 1000
        )
    }

    fileprivate static func histogram(_ values: [Double], width: Double, bin: Double) -> String {
        let count = Int((width / bin).rounded())
        var buckets = [Int](repeating: 0, count: max(1, count))
        for value in values {
            let index = min(buckets.count - 1, max(0, Int(value / bin)))
            buckets[index] += 1
        }
        return buckets.enumerated().map { index, value in
            String(format: "%.0f-%.0f ms %d", Double(index) * bin * 1000, Double(index + 1) * bin * 1000, value)
        }.joined(separator: ", ")
    }

    /// Where the speech files are, when the run asks for them.
    fileprivate static var speechDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOT_FLOOR_DIR"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
