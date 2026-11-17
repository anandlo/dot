import DotCore
@testable import Dot
import XCTest

/// The height a style draws is absolute, not a share of the take's own peak.
///
/// The owner reported that the filament reached its brightest reading very quickly
/// "with just start of the voice". The cause was arithmetic:
/// `VisualizerMath.displayEnergy` divided a measurement by the take's running peak,
/// and the running peak was taken from the same measurement, so every rising
/// syllable read `0.85` within four frames whatever its loudness, and a bar already
/// on the row was rescaled whenever a louder syllable arrived.
@MainActor
final class AbsoluteLevelTests: XCTestCase {
    /// How many ticks a second the meter is pushed at.
    private static let rate: Double = 60

    /// Two seconds of a steady level through the real meter.
    ///
    /// - Parameters:
    ///   - decibels: the level of every frame, in dBFS.
    ///   - seconds: how long the take lasts.
    /// - Returns: the meter after the last frame.
    private func steady(_ decibels: Double, seconds: Double = 2) -> VoiceMeter {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        for step in 0...Int(seconds * Self.rate) {
            meter.push(decibels: decibels, now: Double(step) / Self.rate)
        }
        return meter
    }

    /// A steady -30 dBFS reads a little under the middle of the scale.
    func testSteadyMinusThirtyReadsMidScale() throws {
        let meter = steady(-30)
        let newest = try XCTUnwrap(meter.orderedHistory.last, "the meter holds no history")
        let level = VisualizerMath.displayEnergy(newest)
        print(String(format: "B5.1 steady -30 dBFS reads %.4f of the scale", level))
        XCTAssertGreaterThanOrEqual(level, 0.40, "a steady -30 dBFS reads below the middle of the scale")
        XCTAssertLessThanOrEqual(level, 0.60, "a steady -30 dBFS reads above the middle of the scale")
    }

    /// Four steady voices read four different heights, in the order of their
    /// loudness.
    func testLoudnessOrderIsPreserved() throws {
        var levels: [(decibels: Double, level: Double)] = []
        for decibels in [-40.0, -30.0, -20.0, -10.0] {
            let meter = steady(decibels)
            let newest = try XCTUnwrap(meter.orderedHistory.last, "the meter holds no history")
            levels.append((decibels, VisualizerMath.displayEnergy(newest)))
        }
        print("B5.2 " + levels.map { String(format: "%.0f dBFS -> %.4f", $0.decibels, $0.level) }
            .joined(separator: ", "))
        for index in 1..<levels.count {
            let step = levels[index].level - levels[index - 1].level
            XCTAssertGreaterThan(step, 0, "\(levels[index].decibels) dBFS does not read louder")
            XCTAssertGreaterThanOrEqual(
                step,
                0.08,
                String(format: "%.0f dBFS is only %.4f above %.0f dBFS",
                       levels[index].decibels, step, levels[index - 1].decibels)
            )
        }
    }

    /// A measurement already in the history keeps its drawn height when the take
    /// goes quiet.
    func testEmittedSamplesAreNotRescaled() throws {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        var written = 0
        func push(_ decibels: Double) {
            meter.push(decibels: decibels, now: Double(written) / Self.rate)
            written += 1
        }
        for _ in 0..<Int(0.5 * Self.rate) { push(-15) }
        let early = meter.orderedHistory
        let candidate = early[VoiceMeter.historyLength - 12]
        XCTAssertGreaterThan(candidate, 0.5, "the loud part did not record a loud sample")
        XCTAssertEqual(
            early.filter { $0.bitPattern == candidate.bitPattern }.count,
            1,
            "the sampled measurement is not unique in the ring"
        )
        let earlyIndex = try XCTUnwrap(
            early.firstIndex { $0.bitPattern == candidate.bitPattern },
            "the sampled measurement is not in the ring"
        )
        let earlyValue = VisualizerMath.displayEnergy(early[earlyIndex])
        for _ in 0..<Int(1.9 * Self.rate) { push(-55) }
        let late = meter.orderedHistory
        let lateIndex = try XCTUnwrap(
            late.firstIndex { $0.bitPattern == candidate.bitPattern },
            "the sampled measurement has left the ring"
        )
        let lateValue = VisualizerMath.displayEnergy(late[lateIndex])
        print(String(
            format: "B5.3 the sample at index %d read at 0.6 s as %.17g (bits %d) and at index %d at 2.4 s as %.17g (bits %d)",
            earlyIndex, earlyValue, earlyValue.bitPattern, lateIndex, lateValue, lateValue.bitPattern
        ))
        XCTAssertLessThan(lateIndex, earlyIndex - 100, "the ring did not move past the sample")
        XCTAssertEqual(earlyValue.bitPattern, lateValue.bitPattern, "a measurement changed after it was drawn")
        XCTAssertGreaterThan(earlyValue, 0, "the loud sample drew nothing")
    }

    /// The filament does not arrive at the top of its range on the first syllable.
    func testFilamentDoesNotSaturateOnFirstSyllable() throws {
        /// The heat the wire is drawn at a number of ticks after the voice steps
        /// from the room to speech.
        ///
        /// - Parameter ticks: how many frames of the syllable have been pushed.
        /// - Returns: the heat, from the reading the drawing mixes.
        func heat(afterTicks ticks: Int) -> Double {
            let meter = VoiceMeter()
            meter.setCalibration(nil)
            var history: [Double] = []
            var spectrum: [AudioSpectrumFrame] = []
            var written = 0
            func push(_ decibels: Double) {
                meter.push(decibels: decibels, now: Double(written) / Self.rate)
                written += 1
                meter.copyOrderedHistory(into: &history)
                let shape = meter.shape
                spectrum.append(AudioSpectrumFrame(bands: (shape, shape, shape, shape, shape)))
            }
            for _ in 0..<Int(1.0 * Self.rate) { push(-55) }
            for _ in 0..<ticks { push(-30) }
            let envelope = HUDWaveform.Filament.envelopeHeat(history, reduceMotion: false)
            let bands = HUDWaveform.Filament.bandHeat(spectrum, reduceMotion: false)
            let reading = 0.5 * envelope + 0.5 * bands[2]
            let temperature = HUDWaveform.Filament.temperature(reading)
            return HUDWaveform.Filament.ember + HUDWaveform.Filament.emberGain * temperature
        }

        let fourth = heat(afterTicks: 4)
        let thirtieth = heat(afterTicks: 30)
        print(String(format: "B5.4 filament heat 67 ms after the step %.4f, 500 ms after it %.4f", fourth, thirtieth))
        XCTAssertLessThan(fourth, 0.90, "the wire is at the top of its range four frames into the first syllable")
        XCTAssertLessThan(thirtieth, 0.90, "the wire is at the top of its range half a second into the first syllable")
        XCTAssertGreaterThan(thirtieth, fourth, "the wire does not go on heating as the syllable is held")
    }

    /// No style divides a measurement by the take's peak any more.
    func testSourceHasNoRunningPeakDivision() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Dot/HUDWaveform.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("/ max(0.30"), "the running-peak divisor is back in HUDWaveform.swift")
        for line in source.split(separator: "\n") where line.contains("displayEnergy(") {
            XCTAssertFalse(line.contains("ceiling:"), "a displayEnergy call still takes a ceiling: \(line)")
        }
    }

    /// The wire's reading at six loudnesses, and the heat four settings of
    /// ``HUDWaveform/Filament/fullReading`` would draw from them.
    func testTheFilamentFullReadingLadder() throws {
        var readings: [(decibels: Double, reading: Double)] = []
        for decibels in [-40.0, -30, -20, -15, -10, 0] {
            let meter = VoiceMeter()
            meter.setCalibration(nil)
            var history: [Double] = []
            var spectrum: [AudioSpectrumFrame] = []
            var written = 0
            for _ in 0...Int(2 * Self.rate) {
                meter.push(decibels: decibels, now: Double(written) / Self.rate)
                written += 1
                meter.copyOrderedHistory(into: &history)
                let shape = meter.shape
                spectrum.append(AudioSpectrumFrame(bands: (shape, shape, shape, shape, shape)))
            }
            let envelope = HUDWaveform.Filament.envelopeHeat(history, reduceMotion: false)
            let bands = HUDWaveform.Filament.bandHeat(spectrum, reduceMotion: false)
            readings.append((decibels, 0.5 * envelope + 0.5 * bands[2]))
        }
        let exponent = HUDWaveform.Filament.temperatureExponent
        let ember = HUDWaveform.Filament.ember
        let gain = HUDWaveform.Filament.emberGain
        print("B5.5 shipped fullReading \(HUDWaveform.Filament.fullReading)")
        print("B5.5 " + readings.map { String(format: "%.0f dBFS reading %.4f", $0.decibels, $0.reading) }
            .joined(separator: ", "))
        for full in [0.85, 0.90, 0.95, 1.00] {
            let heats = readings.map { entry -> Double in
                ember + gain * pow(min(1, max(0, entry.reading / full)), exponent)
            }
            print(String(
                format: "B5.5 fullReading %.2f heats -40 %.4f -30 %.4f -20 %.4f -15 %.4f -10 %.4f 0 %.4f",
                full, heats[0], heats[1], heats[2], heats[3], heats[4], heats[5]
            ))
        }
        XCTAssertEqual(readings.count, 6, "a loudness was not measured")

        // The shipped rung: a voice at -20 dBFS stays below four fifths of the
        // wire's range, and only a voice at 0 dBFS reaches the white of the top.
        let shipped = HUDWaveform.Filament.fullReading
        XCTAssertEqual(shipped, 0.95, accuracy: 1e-12, "the wire's full reading moved off the chosen rung")
        func heat(_ decibels: Double, full: Double) throws -> Double {
            let reading = try XCTUnwrap(readings.first { $0.decibels == decibels }?.reading)
            return ember + gain * pow(min(1, max(0, reading / full)), exponent)
        }
        let mid = try heat(-20, full: shipped)
        let top = try heat(0, full: shipped)
        print(String(format: "B5.5 shipped rung: heat at -20 dBFS %.4f, at 0 dBFS %.4f", mid, top))
        XCTAssertLessThanOrEqual(mid, 0.80, "an ordinary voice is at the top of the wire's range")
        XCTAssertGreaterThanOrEqual(top, 0.99, "the loudest voice does not reach the top of the wire")
    }
}
