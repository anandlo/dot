import DotCore
import XCTest

@MainActor
final class SpeechTopTests: XCTestCase {
    private func calibration(floor: Double, peak: Double) -> MicrophoneCalibration {
        MicrophoneCalibration(
            noiseFloorDBFS: floor,
            peakDBFS: peak,
            observedSamples: 2,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testAnUnheardMicrophoneUsesTheDefault() {
        let meter = VoiceMeter()
        XCTAssertEqual(meter.speechTop, VoiceMeter.defaultSpeechTop)
        meter.setCalibration(nil)
        XCTAssertEqual(meter.speechTop, VoiceMeter.defaultSpeechTop)
    }

    /// The learned peak less the crest allowance, as a position in the window
    /// the calibration draws on.
    func testTheReferenceIsTheLearnedPeakLessTheCrest() {
        let entry = calibration(floor: -47.4, peak: -8.6)
        let meter = VoiceMeter()
        meter.setCalibration(entry)
        let window = LevelScale.window(for: entry)
        let expected = (-8.6 - VoiceMeter.speechCrestDB - window.bottomDBFS)
            / (window.topDBFS - window.bottomDBFS)
        XCTAssertEqual(meter.speechTop, expected, accuracy: 1e-12)
        XCTAssertEqual(meter.speechTop, 0.4615, accuracy: 0.001)
    }

    /// A measured speech level is used as it is; the peak, which one cough can
    /// set, no longer enters.
    func testAMeasuredSpeechLevelIsUsedAndThePeakIsIgnored() {
        var entry = calibration(floor: -47.4, peak: -8.6)
        entry.speechDBFS = -24
        let window = LevelScale.window(for: entry)
        let expected = (-24 - window.bottomDBFS) / (window.topDBFS - window.bottomDBFS)
        let meter = VoiceMeter()
        meter.setCalibration(entry)
        XCTAssertEqual(meter.speechTop, expected, accuracy: 1e-12)

        var coughed = entry
        coughed.peakDBFS = 0
        let after = VoiceMeter()
        after.setCalibration(coughed)
        XCTAssertEqual(after.speechTop, expected, accuracy: 1e-12, "a cough's peak does not move the reference")
    }

    /// A fan that lifts the room during a take lifts the bottom of the window.
    /// The reference follows it, so a voice at the speech level still sits at
    /// the reference, and every sample keeps the reference it was written
    /// with, so what is already drawn is never rescaled.
    func testARisingRoomKeepsSpeechAtTheReferenceAndLeavesOldSamplesAlone() throws {
        var entry = calibration(floor: -47.4, peak: -8.6)
        entry.speechDBFS = -24
        let meter = VoiceMeter()
        meter.setCalibration(entry)
        meter.seed(floor: entry.noiseFloorDBFS)
        let rate = 60.0
        var tick = 0
        func push(_ decibels: Double, seconds: Double) {
            for _ in 0..<Int(seconds * rate) {
                meter.push(decibels: decibels, now: Double(tick) / rate)
                tick += 1
            }
        }
        push(-47, seconds: 1)
        var tops: [Double] = []
        meter.copyOrderedSpeechTops(into: &tops)
        let writtenBefore = meter.writtenSamples
        let before = try XCTUnwrap(tops.last)
        XCTAssertEqual(meter.speechTop, before, accuracy: 1e-12)

        // The history holds five seconds, so the rise has to fit beside the
        // samples it is compared with. The tracked floor stops at -40 dBFS.
        push(-36, seconds: 4)
        let floor = try XCTUnwrap(meter.floorDBFS)
        XCTAssertGreaterThan(floor, -41, "the room did not rise, so the test proves nothing")
        let after = meter.speechTop
        XCTAssertLessThan(after, before - 0.05, "the reference did not follow the room")

        // Speech at the reference sits at the reference on the window the meter
        // is drawing on now.
        let live = LevelWindow(
            bottomDBFS: max(LevelScale.window(for: entry).bottomDBFS, LevelScale.gate(floor: floor)),
            topDBFS: LevelScale.ceilingDBFS
        )
        let position = LevelScale.position(perceptual: LevelScale.level(decibels: -24, window: live))
        let range = VoiceMeter.speechTopRange
        XCTAssertEqual(min(max(position, range.lowerBound), range.upperBound), after, accuracy: 1e-9)

        // The samples from before the room rose keep the reference each was
        // written with.
        let snapshot = tops
        meter.copyOrderedSpeechTops(into: &tops)
        let elapsed = meter.writtenSamples - writtenBefore
        let kept = tops.count - elapsed
        XCTAssertGreaterThanOrEqual(kept, 30, "too few old samples remain to compare")
        for offset in 0..<kept {
            XCTAssertEqual(tops[offset], snapshot[offset + elapsed], accuracy: 1e-12)
        }
        XCTAssertEqual(try XCTUnwrap(tops.last), after, accuracy: 1e-12)
    }

    /// Each stored reference stays paired with its sample across the ring's
    /// seam and after a reset.
    func testReferencesStayPairedWithTheirSamplesAcrossTheSeamAndAReset() {
        var quiet = calibration(floor: -47.4, peak: -8.6)
        quiet.speechDBFS = -24
        var loud = quiet
        loud.speechDBFS = -14
        let meter = VoiceMeter()
        meter.setCalibration(quiet)
        meter.seed(floor: quiet.noiseFloorDBFS)
        var tick = 0
        func push(_ decibels: Double, count: Int) {
            for _ in 0..<count {
                meter.push(decibels: decibels, now: Double(tick) / VoiceMeter.sampleRate)
                tick += 1
            }
        }
        let length = VoiceMeter.historyLength
        push(-47, count: length + 10)
        let quietTop = meter.speechTop
        meter.setCalibration(loud)
        let loudTop = meter.speechTop
        XCTAssertGreaterThan(abs(loudTop - quietTop), 0.05, "the two references match, so the test proves nothing")
        push(-47, count: 7)
        XCTAssertEqual(meter.writtenSamples, length + 17, "a push wrote other than one sample")

        var tops: [Double] = []
        meter.copyOrderedSpeechTops(into: &tops)
        XCTAssertEqual(tops.count, length)
        for top in tops.suffix(7) { XCTAssertEqual(top, loudTop, accuracy: 1e-12) }
        XCTAssertEqual(tops[length - 8], quietTop, accuracy: 1e-12)

        meter.reset()
        meter.setCalibration(quiet)
        meter.seed(floor: quiet.noiseFloorDBFS)
        tick = 0
        push(-20, count: 1)
        XCTAssertEqual(meter.writtenSamples, 1)
        var history: [Double] = []
        meter.copyOrderedHistory(into: &history)
        meter.copyOrderedSpeechTops(into: &tops)
        XCTAssertGreaterThan(history[length - 1], 0, "the first sample after the reset is not the newest")
        XCTAssertTrue(history.dropLast().allSatisfy { $0 == 0 }, "samples from before the reset survived")
        XCTAssertEqual(tops[length - 1], meter.speechTop, accuracy: 1e-12)
        XCTAssertNotEqual(meter.speechTop, VoiceMeter.defaultSpeechTop, accuracy: 1e-3, "the new reference matches the reset value, so the test proves nothing")
        XCTAssertTrue(tops.dropLast().allSatisfy { $0 == VoiceMeter.defaultSpeechTop }, "references from before the reset survived")
    }

    func testTheReferenceIsHeldInsideItsRange() {
        let quiet = VoiceMeter()
        quiet.setCalibration(calibration(floor: -47, peak: -40))
        XCTAssertEqual(quiet.speechTop, VoiceMeter.speechTopRange.lowerBound)
        let hot = VoiceMeter()
        hot.setCalibration(calibration(floor: -50, peak: 6))
        XCTAssertEqual(hot.speechTop, VoiceMeter.speechTopRange.upperBound)
    }
}
