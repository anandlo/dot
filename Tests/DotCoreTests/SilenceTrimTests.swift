import XCTest

@testable import DotCore

/// A stretch of a tone at a known level.
///
/// The tone is a square wave, so every frame's RMS is exactly the amplitude
/// asked for and a test can name the level it built without depending on
/// chance. Digital silence is a square wave of amplitude zero, which is the
/// input that has no level in decibels at all.
///
/// - Parameters:
///   - milliseconds: how long the stretch is.
///   - dbfs: the level the stretch should measure, in dBFS.
private func tone(milliseconds: Int, dbfs: Double) -> [Int16] {
    let amplitude = min(32_767, max(0, Int((32_768 * pow(10, dbfs / 20)).rounded())))
    let count = WAVSpec.sampleRate * milliseconds / 1000
    return (0..<count).map { Int16($0.isMultiple(of: 2) ? amplitude : -amplitude) }
}

/// A stretch of digital silence: a muted input records nothing but zeros.
private func zeros(milliseconds: Int) -> [Int16] {
    [Int16](repeating: 0, count: WAVSpec.sampleRate * milliseconds / 1000)
}

final class SilenceTrimTests: XCTestCase {
    /// The level of the room tone in every clip here, in dBFS.
    private let roomTone = -60.0
    /// The level of the speech in every clip here, in dBFS.
    private let speech = -20.0

    /// 900 ms of room tone, 600 ms of speech, 500 ms of room tone.
    private func take() -> [Int16] {
        tone(milliseconds: 900, dbfs: roomTone)
            + tone(milliseconds: 600, dbfs: speech)
            + tone(milliseconds: 500, dbfs: roomTone)
    }

    func testTheRoomToneBeforeSpeechIsCutAndTheSpeechIsKept() {
        let clip = take()
        let trim = SilenceTrim.trim(clip, noiseFloorDBFS: nil)
        let onset = WAVSpec.sampleRate * 900 / 1000

        // The cut lands 150 ms in front of the first frame of speech.
        XCTAssertEqual(
            Double(trim.removedLeadingSamples),
            Double(onset - SilenceTrim.preRollSamples),
            accuracy: Double(WAVSpec.sampleRate) / 50
        )
        XCTAssertEqual(trim.range.lowerBound, trim.removedLeadingSamples)
        XCTAssertEqual(clip.count - trim.range.upperBound, trim.removedTrailingSamples)
        // Every sample of the speech is inside the range.
        XCTAssertLessThanOrEqual(trim.range.lowerBound, onset)
        XCTAssertGreaterThanOrEqual(trim.range.upperBound, onset + WAVSpec.sampleRate * 600 / 1000)
        // And what is kept is the audio itself: not one sample moved or scaled.
        XCTAssertEqual(Array(clip[trim.range]), Array(clip[trim.range.lowerBound..<trim.range.upperBound]))
    }

    /// A person who presses the key and then thinks before speaking leaves more
    /// than a second of room tone, and that is the take a chat-style speech
    /// model numbers most readily. The trim must therefore look past the first
    /// second rather than give up inside it: a window that stopped at 1.2 s cut
    /// nothing at all from any of these takes.
    func testALeadInLongerThanASecondIsStillCut() {
        for milliseconds in [1_200, 1_500, 2_000, 3_000] {
            let clip = tone(milliseconds: milliseconds, dbfs: roomTone)
                + tone(milliseconds: 600, dbfs: speech)
                + tone(milliseconds: 300, dbfs: roomTone)
            let onset = WAVSpec.sampleRate * milliseconds / 1000
            let trim = SilenceTrim.trim(clip, noiseFloorDBFS: roomTone)

            XCTAssertEqual(
                Double(trim.removedLeadingSamples),
                Double(onset - SilenceTrim.preRollSamples),
                accuracy: Double(WAVSpec.sampleRate) / 50,
                "a \(milliseconds) ms lead-in was not cut to the pre-roll"
            )
            // The speech is still whole, and it is still the audio that came in.
            XCTAssertLessThanOrEqual(trim.range.lowerBound, onset)
            XCTAssertGreaterThanOrEqual(trim.range.upperBound, onset + WAVSpec.sampleRate * 600 / 1000)
        }
    }

    func testTheRoomToneAfterSpeechIsKeptForAQuarterOfASecond() {
        let clip = take()
        let trim = SilenceTrim.trim(clip, noiseFloorDBFS: nil)
        XCTAssertEqual(
            Double(trim.removedTrailingSamples),
            Double(SilenceTrim.tailSamples),
            accuracy: Double(WAVSpec.sampleRate) / 50
        )
    }

    func testAClipThatBeginsOnSpeechIsUntouched() {
        // The tone before the first frame of speech is nothing, so there is
        // nothing to cut: a clip that opens on a word is all word.
        let clip = tone(milliseconds: 1_000, dbfs: speech)
        for floor in [nil, roomTone] as [Double?] {
            let trim = SilenceTrim.trim(clip, noiseFloorDBFS: floor)
            XCTAssertEqual(trim.range, 0..<clip.count)
            XCTAssertEqual(trim.removedLeadingSamples, 0)
            XCTAssertEqual(trim.removedTrailingSamples, 0)
        }
    }

    func testAnAllNoiseClipIsUntouched() {
        // Nothing in the first 1.2 s reaches the threshold, so the take did not
        // open on room tone before speech; it is a clip of room tone.
        let clip = tone(milliseconds: 1_500, dbfs: roomTone)
        for floor in [nil, -43.0] as [Double?] {
            let trim = SilenceTrim.trim(clip, noiseFloorDBFS: floor)
            XCTAssertEqual(trim.range, 0..<clip.count)
            XCTAssertEqual(trim.removedLeadingSamples, 0)
            XCTAssertEqual(trim.removedTrailingSamples, 0)
        }
    }

    func testAClipShorterThanTheShortestTakeIsUntouched() {
        // 200 ms, under the 300 ms the trimmer will measure.
        let clip = tone(milliseconds: 100, dbfs: roomTone) + tone(milliseconds: 100, dbfs: speech)
        XCTAssertLessThan(clip.count, SilenceTrim.minimumClipSamples)
        let trim = SilenceTrim.trim(clip, noiseFloorDBFS: roomTone)
        XCTAssertEqual(trim.range, 0..<clip.count)
        XCTAssertEqual(trim.removedLeadingSamples, 0)
        XCTAssertEqual(trim.removedTrailingSamples, 0)
    }

    func testTheFloorDecidesWhetherTheOpeningIsSound() {
        // One floor, two openings. The stored floor says the room sits at
        // -60 dBFS, so the bar is -48: a tone at -43 is above it and is sound,
        // and the clip is left alone; a tone at -70 is below it and is silence,
        // and the lead-in is cut.
        let sound = tone(milliseconds: 900, dbfs: -43)
            + tone(milliseconds: 600, dbfs: speech)
            + tone(milliseconds: 500, dbfs: -43)
        let kept = SilenceTrim.trim(sound, noiseFloorDBFS: -60)
        XCTAssertEqual(kept.range, 0..<sound.count)
        XCTAssertEqual(kept.removedLeadingSamples, 0)
        XCTAssertEqual(kept.removedTrailingSamples, 0)

        let silence = tone(milliseconds: 900, dbfs: -70)
            + tone(milliseconds: 600, dbfs: speech)
        let cut = SilenceTrim.trim(silence, noiseFloorDBFS: -60)
        XCTAssertGreaterThan(cut.removedLeadingSamples, 0)
        XCTAssertEqual(
            Double(cut.removedLeadingSamples),
            Double(WAVSpec.sampleRate * 900 / 1000 - SilenceTrim.preRollSamples),
            accuracy: Double(WAVSpec.sampleRate) / 50
        )
    }

    func testDigitalSilenceIsFlooredAndStillMeasured() {
        // A muted input records zeros, which have no level in decibels at all.
        // They are a floor, not a hole: the speech behind them is still found.
        let clip = zeros(milliseconds: 900) + tone(milliseconds: 600, dbfs: speech)
        XCTAssertTrue(clip.prefix(WAVSpec.sampleRate * 900 / 1000).allSatisfy { $0 == 0 })
        let trim = SilenceTrim.trim(clip, noiseFloorDBFS: LevelScale.silenceDBFS)
        XCTAssertEqual(
            Double(trim.removedLeadingSamples),
            Double(WAVSpec.sampleRate * 900 / 1000 - SilenceTrim.preRollSamples),
            accuracy: Double(WAVSpec.sampleRate) / 50
        )
    }

    func testAnEmptyClipHasNothingToTrim() {
        for samples in [[], [Int16(0)], [Int16(1_000), Int16(-1_000)]] {
            let trim = SilenceTrim.trim(samples, noiseFloorDBFS: roomTone)
            XCTAssertEqual(trim.range, 0..<samples.count)
            XCTAssertEqual(trim.removedLeadingSamples, 0)
            XCTAssertEqual(trim.removedTrailingSamples, 0)
        }
    }

    func testAMeasurementThatIsNotANumberDecidesNothing() {
        let clip = take()
        for floor in [Double.nan, .infinity, -.infinity] {
            let trim = SilenceTrim.trim(clip, noiseFloorDBFS: floor)
            XCTAssertEqual(trim.range, 0..<clip.count, "floor \(floor)")
            XCTAssertEqual(trim.removedLeadingSamples, 0)
            XCTAssertEqual(trim.removedTrailingSamples, 0)
        }
    }

    func testTheThresholdSitsAboveTheMeasuredFloor() {
        XCTAssertEqual(
            SilenceTrim.thresholdDBFS(take(), noiseFloorDBFS: -43.87),
            -43.87 + SilenceTrim.thresholdAboveFloorDB,
            accuracy: 0.001
        )
        // With no floor the clip's own opening is the reference: the 900 ms of
        // room tone before the speech is the median of the first 300 ms.
        XCTAssertEqual(
            SilenceTrim.thresholdDBFS(take(), noiseFloorDBFS: nil),
            roomTone + SilenceTrim.thresholdAboveFloorDB,
            accuracy: 0.5
        )
        XCTAssertTrue(SilenceTrim.thresholdDBFS([], noiseFloorDBFS: nil).isNaN)
    }
}
