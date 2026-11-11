import XCTest
@testable import DotCore

/// The window one voice's spectrum is drawn on.
///
/// The scale is what turns the recorder's fixed measurement into a picture of
/// this speaker: without it every band of ordinary speech sits in the low half
/// of the dots, and the grid reads as switching on at a level rather than as a
/// voice. The tests below pin the range on two voices, the silence gate, the
/// burst above the window, the recovery after it, the guard and the reset.
final class SpectrumScaleTests: XCTestCase {
    /// The rate the card calls the scale at, in frames per second.
    private static let frameRate: Double = 60
    private static let step: Double = 1.0 / frameRate

    /// The rate of each band's oscillation, in hertz, and its phase offset.
    ///
    /// Five different rates mean no row of the grid is the same picture as the
    /// one beside it, which is what a spectrum looks like and what a single
    /// shared envelope would not.
    private static let bandRates: [Double] = [3.0, 4.0, 5.0, 6.0, 7.0]
    private static let bandPhases: [Double] = [0.0, 1.1, 2.3, 3.7, 5.1]

    // MARK: - The range

    /// A quiet voice, `0.30...0.50` on the recorder's scale, sweeps the grid.
    func testAQuietVoiceReachesTheTopOfTheGrid() {
        var scale = SpectrumScale()
        let frames = outputs(seconds: 3, from: &scale, signal: { Self.voice(centre: 0.40, spread: 0.10, at: $0) })
        let settled = Array(frames.suffix(Int(2 * Self.frameRate)))
        for band in 0..<5 {
            let values = settled.map { $0[band] }
            print(String(
                format: "quiet band %d p5 %.4f p95 %.4f",
                band,
                percentile(values, 0.05),
                percentile(values, 0.95)
            ))
            XCTAssertLessThanOrEqual(percentile(values, 0.05), 0.15, "band \(band) fifth percentile \(percentile(values, 0.05))")
            XCTAssertGreaterThanOrEqual(percentile(values, 0.95), 0.85, "band \(band) ninety-fifth percentile \(percentile(values, 0.95))")
        }
    }

    /// A loud voice, `0.62...0.92`, sweeps it too.
    ///
    /// Six seconds, because the floor climbs at four point eight decibels a
    /// second and the bottom of a loud voice is far above the seed: the last two
    /// seconds are the ones where the window has found the voice.
    func testALoudVoiceReachesTheTopOfTheGrid() {
        var scale = SpectrumScale()
        let frames = outputs(seconds: 6, from: &scale, signal: { Self.voice(centre: 0.77, spread: 0.15, at: $0) })
        let settled = Array(frames.suffix(Int(2 * Self.frameRate)))
        for band in 0..<5 {
            let values = settled.map { $0[band] }
            print(String(
                format: "loud band %d p5 %.4f p95 %.4f",
                band,
                percentile(values, 0.05),
                percentile(values, 0.95)
            ))
            XCTAssertLessThanOrEqual(percentile(values, 0.05), 0.15, "band \(band) fifth percentile \(percentile(values, 0.05))")
            XCTAssertGreaterThanOrEqual(percentile(values, 0.95), 0.85, "band \(band) ninety-fifth percentile \(percentile(values, 0.95))")
        }
    }

    // MARK: - The gate

    /// A gated frame draws nothing and teaches the window nothing.
    func testASilentFrameLeavesTheWindowAlone() {
        var scale = SpectrumScale()
        _ = outputs(seconds: 1, from: &scale, signal: { Self.voice(centre: 0.40, spread: 0.10, at: $0) })
        let floors = scale.floors
        let peaks = scale.peaks

        let out = scale.normalise(.zero, dt: Self.step)

        XCTAssertTrue(out == .zero, "a gated frame is drawn as zero")
        XCTAssertTrue(scale.floors == floors, "the floors moved on a gated frame")
        XCTAssertTrue(scale.peaks == peaks, "the peaks moved on a gated frame")
    }

    // MARK: - The burst

    /// One frame above the window is drawn at the top of the grid.
    func testABurstIsDrawnAtTheTop() {
        var scale = SpectrumScale()
        _ = outputs(seconds: 2, from: &scale, signal: { Self.voice(centre: 0.40, spread: 0.10, at: $0) })

        let burst = scale.normalise(AudioSpectrumFrame(bands: (1, 1, 1, 1, 1)), dt: Self.step)

        for band in 0..<5 {
            XCTAssertGreaterThanOrEqual(burst[band], 0.99, "band \(band) after a burst \(burst[band])")
        }
    }

    /// The quiet voice gets its range back within ten seconds of the burst.
    func testAQuietVoiceRecoversAfterABurst() {
        var before = SpectrumScale()
        let quiet = outputs(seconds: 3, from: &before, signal: { Self.voice(centre: 0.40, spread: 0.10, at: $0) })
        let quietSettled = Array(quiet.suffix(Int(2 * Self.frameRate)))
        let quietSpan = span(of: quietSettled, band: 2)

        var scale = SpectrumScale()
        _ = outputs(seconds: 2, from: &scale, signal: { Self.voice(centre: 0.40, spread: 0.10, at: $0) })
        _ = scale.normalise(AudioSpectrumFrame(bands: (1, 1, 1, 1, 1)), dt: Self.step)
        let recovered = outputs(seconds: 10, from: &scale, signal: { Self.voice(centre: 0.40, spread: 0.10, at: $0) })
        let recoveredSpan = span(of: Array(recovered.suffix(Int(2 * Self.frameRate))), band: 2)

        print(String(format: "recovery quiet span %.4f recovered span %.4f ratio %.4f", quietSpan, recoveredSpan, recoveredSpan / quietSpan))
        XCTAssertGreaterThanOrEqual(recoveredSpan, quietSpan * 0.9, "recovered span \(recoveredSpan) of \(quietSpan)")
    }

    // MARK: - The guard

    /// Every band keeps at least twelve decibels between its floor and its peak.
    func testEveryBandKeepsItsMinimumSpan() {
        var scale = SpectrumScale()
        for (seconds, signal) in [
            (2.0, { Self.voice(centre: 0.40, spread: 0.10, at: $0) }),
            (2.0, { Self.voice(centre: 0.77, spread: 0.15, at: $0) }),
            (1.0, { _ in AudioSpectrumFrame(bands: (1, 1, 1, 1, 1)) }),
            (1.0, { _ in AudioSpectrumFrame.zero }),
            (1.0, { _ in AudioSpectrumFrame(bands: (0.001, 0.02, 0.004, 0.03, 0.002)) }),
        ] {
            let steps = Int(seconds * Self.frameRate)
            for step in 0..<steps {
                _ = scale.normalise(signal(Double(step) * Self.step), dt: Self.step)
                let floors = scale.floors
                let peaks = scale.peaks
                for band in 0..<5 {
                    let floor = band == 0 ? floors.0 : band == 1 ? floors.1 : band == 2 ? floors.2 : band == 3 ? floors.3 : floors.4
                    let peak = band == 0 ? peaks.0 : band == 1 ? peaks.1 : band == 2 ? peaks.2 : band == 3 ? peaks.3 : peaks.4
                    XCTAssertGreaterThanOrEqual(peak - floor, SpectrumScale.minimumSpan - 1e-12, "band \(band) span \(peak - floor)")
                }
            }
        }
    }

    // MARK: - The reset

    /// A reset puts the window back where a take starts.
    func testResetRestoresTheSeeds() {
        var scale = SpectrumScale()
        _ = outputs(seconds: 1, from: &scale, signal: { Self.voice(centre: 0.77, spread: 0.15, at: $0) })
        XCTAssertFalse(scale.floors == SpectrumScale.floorSeeds, "the test needs a window that has moved")

        scale.reset()

        XCTAssertTrue(scale.floors == SpectrumScale.floorSeeds, "the floors were not reset")
        XCTAssertTrue(scale.peaks == SpectrumScale.peakSeeds, "the peaks were not reset")
    }

    // MARK: - The signal

    /// Five bands sharing an envelope, each at its own rate and phase.
    ///
    /// - Parameters:
    ///   - centre: the middle of this band's oscillation, in the recorder's band
    ///     domain.
    ///   - spread: the distance from the middle to either end.
    ///   - time: when the frame is taken, in seconds.
    /// - Returns: one frame of the five bands.
    private static func voice(centre: Double, spread: Double, at time: Double) -> AudioSpectrumFrame {
        var bands: [Double] = []
        bands.reserveCapacity(5)
        for index in 0..<5 {
            let value = centre + spread * sin(2 * Double.pi * bandRates[index] * time + bandPhases[index])
            bands.append(min(1, max(0, value)))
        }
        return AudioSpectrumFrame(bands: (bands[0], bands[1], bands[2], bands[3], bands[4]))
    }

    /// Feeds `seconds` of a signal through a scale at the card's rate.
    ///
    /// - Parameters:
    ///   - seconds: how long the signal runs.
    ///   - scale: the window, updated in place.
    ///   - signal: the frame at a moment, in seconds.
    /// - Returns: one frame per tick, in order.
    private func outputs(
        seconds: Double,
        from scale: inout SpectrumScale,
        signal: (Double) -> AudioSpectrumFrame
    ) -> [AudioSpectrumFrame] {
        let steps = Int((seconds * Self.frameRate).rounded())
        var frames: [AudioSpectrumFrame] = []
        frames.reserveCapacity(steps)
        for step in 0..<steps {
            frames.append(scale.normalise(signal(Double(step) * Self.step), dt: Self.step))
        }
        return frames
    }

    /// The distance between the fifth and the ninety-fifth percentile of a band.
    ///
    /// - Parameters:
    ///   - frames: the frames to measure.
    ///   - band: the band to read.
    /// - Returns: the span of that band's drawn value.
    private func span(of frames: [AudioSpectrumFrame], band: Int) -> Double {
        let values = frames.map { $0[band] }
        return percentile(values, 0.95) - percentile(values, 0.05)
    }

    /// The `fraction` quantile of a set of values.
    ///
    /// - Parameters:
    ///   - values: the values to place.
    ///   - fraction: where on the sorted values to read, from `0` to `1`.
    /// - Returns: the value at that position.
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
