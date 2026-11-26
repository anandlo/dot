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
        /// The peak heat the wire reaches a number of ticks after the voice steps
        /// from the room to speech.
        ///
        /// - Parameter ticks: how many frames of the syllable have been pushed.
        /// - Returns: the peak heat along the coil profile.
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
            return HUDWaveform.Filament.heatProfile(
                history: history,
                spectrum: spectrum,
                reveal: 1,
                reduceMotion: false
            ).max() ?? 0
        }

        // The heat the same syllable reaches when held for two seconds, so the
        // rise is judged against its own destination rather than an absolute
        // number the range can move.
        let fourth = heat(afterTicks: 4)
        let thirtieth = heat(afterTicks: 30)
        let settled = heat(afterTicks: 120)
        print(String(
            format: "B5.4 filament heat 67 ms after the step %.4f, 500 ms after it %.4f, 2 s after it %.4f",
            fourth, thirtieth, settled
        ))
        XCTAssertLessThan(fourth, 0.5 * settled, "the wire covered half its rise four frames into a medium syllable")
        XCTAssertLessThanOrEqual(thirtieth, settled + 0.02, "the wire overshoots its settled heat")
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

    /// The steady heat of the wire for a level on a calibrated microphone.
    ///
    /// The history is built from the device's own window rather than pushed
    /// through a meter: a steady tone held for seconds is what the meter's
    /// room tracker is built to treat as the room, and speech is not steady.
    private func steadyHeat(decibels: Double, calibration: MicrophoneCalibration) -> Double {
        let meter = VoiceMeter()
        meter.setCalibration(calibration)
        let window = LevelScale.window(for: calibration)
        let level = LevelScale.level(decibels: decibels, window: window)
        let count = HUDWaveform.Filament.lagSamples
        let history = [Double](repeating: level, count: count)
        let spectrum = [AudioSpectrumFrame](
            repeating: AudioSpectrumFrame(bands: (level, level, level, level, level)),
            count: count
        )
        return HUDWaveform.Filament.heatProfile(
            history: history,
            spectrum: spectrum,
            reveal: 1,
            reduceMotion: false,
            speechTop: meter.speechTop
        ).max() ?? 0
    }

    /// On a quiet laptop microphone ordinary speech reaches amber and loud
    /// speech the white core: the wire spans the voice, not the headroom.
    func testTheFilamentSpansAQuietMicrophonesVoice() throws {
        let calibration = MicrophoneCalibration(
            noiseFloorDBFS: -47.4,
            peakDBFS: -8.6,
            observedSamples: 2,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let ladder = [-47.0, -38, -30, -26, -22, -15, -6]
        let heats = ladder.map { steadyHeat(decibels: $0, calibration: calibration) }
        print("FIL-QUIET " + zip(ladder, heats).map { String(format: "%.0f dBFS %.4f", $0, $1) }
            .joined(separator: ", "))
        for index in 1..<heats.count {
            XCTAssertGreaterThanOrEqual(
                heats[index], heats[index - 1],
                "\(ladder[index]) dBFS is cooler than \(ladder[index - 1]) dBFS"
            )
            if heats[index - 1] < 0.99 {
                XCTAssertGreaterThan(
                    heats[index], heats[index - 1],
                    "\(ladder[index]) dBFS does not heat above \(ladder[index - 1]) dBFS"
                )
            }
        }
        XCTAssertLessThanOrEqual(heats[0], 0.20, "the room is past an ember")
        XCTAssertGreaterThanOrEqual(heats[1], 0.30, "quiet speech (-38 dBFS) does not glow")
        XCTAssertLessThanOrEqual(heats[1], 0.60, "quiet speech (-38 dBFS) is already amber")
        XCTAssertGreaterThanOrEqual(heats[2], 0.60, "normal speech (-30 dBFS) stays red")
        XCTAssertGreaterThanOrEqual(heats[4], HUDWaveform.Filament.coreOnset, "loud speech (-22 dBFS) does not reach the white core")
    }

    /// On a hot microphone ordinary speech is not white: the reference follows
    /// the device's own loudness.
    func testTheFilamentDoesNotSaturateOnAHotMicrophone() throws {
        let calibration = MicrophoneCalibration(
            noiseFloorDBFS: -57,
            peakDBFS: 0,
            observedSamples: 2,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        // Its loud speech is taken to sit at -12 dBFS (the peak less the crest);
        // ordinary speech is a crest below that again.
        let normal = steadyHeat(decibels: -24, calibration: calibration)
        let quiet = steadyHeat(decibels: -35, calibration: calibration)
        print(String(format: "FIL-HOT -35 dBFS %.4f, -24 dBFS %.4f", quiet, normal))
        XCTAssertLessThan(normal, HUDWaveform.Filament.coreOnset, "normal speech on a hot microphone lights the white core")
        XCTAssertLessThan(quiet, normal, "the hot microphone's range is flat")
    }

    /// Above the speaker's loud speech the wire keeps a little room, so a shout
    /// reads hotter than loud speech instead of the two drawing the same.
    func testTheFilamentKeepsHeadroomAboveLoudSpeech() {
        let calibration = MicrophoneCalibration(
            noiseFloorDBFS: -47.4,
            peakDBFS: -8.6,
            observedSamples: 2,
            updatedAt: Date(timeIntervalSince1970: 0),
            speechDBFS: -24
        )
        let speech = steadyHeat(decibels: -24, calibration: calibration)
        let louder = steadyHeat(decibels: -18, calibration: calibration)
        let shout = steadyHeat(decibels: -8, calibration: calibration)
        print(String(format: "FIL-HEADROOM speech %.4f, +6 dB %.4f, shout %.4f", speech, louder, shout))
        XCTAssertGreaterThanOrEqual(speech, HUDWaveform.Filament.coreOnset, "loud speech does not reach the white core")
        XCTAssertLessThan(speech, 0.98, "loud speech leaves no room above it")
        XCTAssertGreaterThan(louder, speech + 0.005, "6 dB above loud speech draws the same")
        XCTAssertGreaterThan(shout, louder, "a shout draws the same as raised speech")
    }

    /// A fan that lifts the room before the speaker talks does not cool their
    /// loud speech: the meter and the reference share one window.
    /// The coil reads each sample against the reference stored with it, not
    /// the reference the meter holds now.
    func testTheCoilReadsEachSampleAgainstItsOwnReference() {
        let level = LevelScale.level(decibels: -24, window: LevelScale.fixedWindow)
        let history = [Double](repeating: level, count: VoiceMeter.historyLength)
        let written = 0.5
        func heat(speechTop: Double, speechTops: [Double]) -> Double {
            HUDWaveform.Filament.heatProfile(
                history: history,
                spectrum: [],
                reveal: 1,
                reduceMotion: false,
                speechTop: speechTop,
                speechTops: speechTops
            ).max() ?? 0
        }
        let expected = heat(speechTop: written, speechTops: [])
        let stored = heat(
            speechTop: 0.70,
            speechTops: [Double](repeating: written, count: history.count)
        )
        XCTAssertEqual(stored, expected, accuracy: 1e-12)
        XCTAssertNotEqual(heat(speechTop: 0.70, speechTops: []), expected, accuracy: 1e-3, "the two references draw the same, so the test proves nothing")
    }

    func testLoudSpeechStaysHotAfterTheRoomRises() throws {
        let calibration = MicrophoneCalibration(
            noiseFloorDBFS: -47.4,
            peakDBFS: -8.6,
            observedSamples: 2,
            updatedAt: Date(timeIntervalSince1970: 0),
            speechDBFS: -24
        )
        let meter = VoiceMeter()
        meter.setCalibration(calibration)
        meter.seed(floor: calibration.noiseFloorDBFS)
        let rate = VoiceMeter.sampleRate
        var tick = 0
        func push(_ decibels: Double, seconds: Double) {
            for _ in 0..<Int(seconds * rate) {
                meter.push(decibels: decibels, now: Double(tick) / rate)
                tick += 1
            }
        }
        push(-36, seconds: 5)
        XCTAssertGreaterThan(try XCTUnwrap(meter.floorDBFS), -41, "the room did not rise, so the test proves nothing")
        push(-24, seconds: 3)

        var history: [Double] = []
        var tops: [Double] = []
        meter.copyOrderedHistory(into: &history)
        meter.copyOrderedSpeechTops(into: &tops)
        let heat = HUDWaveform.Filament.heatProfile(
            history: history,
            spectrum: [],
            reveal: 1,
            reduceMotion: false,
            speechTop: meter.speechTop,
            speechTops: tops
        ).max() ?? 0
        print(String(format: "FIL-ROOM speech after the room rose %.4f", heat))
        XCTAssertGreaterThanOrEqual(heat, HUDWaveform.Filament.coreOnset, "a risen room cooled loud speech")
        XCTAssertGreaterThan(heat, 0.9)
    }
}
