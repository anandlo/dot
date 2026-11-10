import CoreGraphics
import Foundation
import XCTest

@testable import DotCore

/// The scale the waveform is drawn from.
///
/// The requirement is a visual one — "it has to follow my voice" — so the tests
/// are about the numbers that produce the shape: silence near the floor, normal
/// speech in the middle, loud speech high but not glued to the top, and a
/// release that falls in a bounded time.
@MainActor
final class LevelScaleTests: XCTestCase {
    private let rate = 16_000

    /// A sine at a precise RMS, as the microphone would hand it over.
    private func sine(rmsDBFS: Double, seconds: Double = 0.02) -> [Int16] {
        // A sine of amplitude A has RMS A/√2.
        let amplitude = min(1, pow(10, rmsDBFS / 20) * sqrt(2))
        let count = Int(seconds * Double(rate))
        return (0..<count).map { index in
            let value = amplitude * sin(2 * .pi * 220 * Double(index) / Double(rate))
            return Int16((value * 32_767).rounded())
        }
    }

    /// A square wave at a precise RMS.
    private func square(rmsDBFS: Double, seconds: Double = 0.02) -> [Int16] {
        let amplitude = min(1, pow(10, rmsDBFS / 20))
        let count = Int(seconds * Double(rate))
        return (0..<count).map { index in
            Int16((index % 2 == 0 ? amplitude : -amplitude) * 32_767)
        }
    }

    /// Pushes a signal into a fresh meter and returns it.
    private func meter(fed samples: [Int16], frames: Int = 1) -> VoiceMeter {
        let meter = VoiceMeter()
        let db = AudioLevel.rmsDBFS(samples: samples)
        for frame in 0..<frames {
            meter.push(decibels: db, now: Double(frame) / 60.0)
        }
        return meter
    }

    func testSilenceIsTheFloor() {
        let meter = VoiceMeter()
        meter.push(decibels: -.infinity, now: 0)
        XCTAssertEqual(meter.level, 0)
        XCTAssertEqual(meter.envelope, 0)
        XCTAssertNil(meter.floorDBFS)

        // Digital silence, and a room far below the scale.
        meter.push(decibels: -120, now: 0.02)
        XCTAssertEqual(meter.envelope, 0)
        XCTAssertNil(meter.floorDBFS)

        // A room at -70 dBFS is audible but reads as a hairline.
        meter.push(decibels: -70, now: 0.04)
        XCTAssertEqual(meter.level, 0, accuracy: 0.001)
    }

    func testNormalSpeechSitsInTheMiddleOfTheRange() {
        for db in [-30.0, -26.0, -20.0] {
            let level = LevelScale.level(decibels: db)
            XCTAssertGreaterThan(level, 0.35, "\(db) dBFS")
            XCTAssertLessThan(level, 0.65, "\(db) dBFS")
        }
        // A real sine, through the real RMS path, not only the arithmetic.
        let measured = AudioLevel.rmsDBFS(samples: sine(rmsDBFS: -26))
        let level = LevelScale.level(decibels: measured)
        XCTAssertEqual(level, 0.48, accuracy: 0.05)
    }

    func testLoudSpeechIsHighButNotAtTheTop() {
        let loud = LevelScale.level(decibels: -12)
        XCTAssertGreaterThan(loud, 0.65)
        XCTAssertLessThan(loud, 0.8)
    }

    func testDigitalFullScaleLeavesHeadroomAtTheTop() {
        // The loudest sample a PCM file can hold: a full-scale square wave is
        // the only signal whose RMS is 0 dBFS.
        let fullScale = AudioLevel.rmsDBFS(samples: square(rmsDBFS: 0))
        XCTAssertEqual(fullScale, 0, accuracy: 0.01)

        let level = LevelScale.level(decibels: fullScale)
        XCTAssertLessThan(level, 0.95)
        XCTAssertGreaterThan(level, 0.85)

        // And the drawn shape keeps headroom: a full-scale input does not
        // reach the top of the card.
        let maximum: CGFloat = 13
        let heights = Waveform.halfHeights(
            history: Array(repeating: level, count: Waveform.historyLength),
            phase: 0,
            count: Waveform.columnCount,
            maximum: maximum,
            breath: 0
        )
        XCTAssertLessThan(CGFloat(level) * maximum, maximum - 1)
        // The only thing above the scaled level is the breath, which is bounded.
        XCTAssertLessThanOrEqual(
            heights.max() ?? 0,
            CGFloat(level) * maximum + Waveform.breathAmplitude + 0.001
        )
    }

    func testTheLevelNeverDecreasesAsTheVoiceGetsLouder() {
        var previous = -1.0
        for db in stride(from: -80.0, through: 10.0, by: 1.0) {
            let level = LevelScale.level(decibels: db)
            XCTAssertGreaterThanOrEqual(level, previous, "\(db) dBFS")
            previous = level
        }
        XCTAssertEqual(LevelScale.level(decibels: 10), 1)
        XCTAssertEqual(LevelScale.level(decibels: 40), 1)
    }

    func testTheRoomFloorOnlyLiftsTheBottomOfTheScale() {
        // A quiet room leaves the fixed scale alone.
        XCTAssertEqual(LevelScale.gate(floor: -70), LevelScale.floorDBFS)
        XCTAssertEqual(LevelScale.gate(floor: -62), LevelScale.floorDBFS)

        // A room that is audible lifts the bottom by four decibels above it.
        XCTAssertEqual(LevelScale.gate(floor: -56), -52)

        // A noisy room lifts it, by a little, and not past the ceiling.
        XCTAssertEqual(LevelScale.gate(floor: -40), -36)
        XCTAssertEqual(LevelScale.gate(floor: -20), LevelScale.gateCeilingDBFS)

        // A loud room reads as quiet, and speech in it still moves.
        XCTAssertEqual(LevelScale.level(decibels: -40, floor: -40), 0)
        let speech = LevelScale.level(decibels: -18, floor: -40)
        XCTAssertGreaterThan(speech, 0.4)
        XCTAssertLessThan(speech, 0.8)
    }

    func testTheEnvelopeAttacksFastAndReleasesSlowly() {
        let attack = EnvelopeShape.step(envelope: 0, level: 1, dt: 1.0 / 60.0)
        XCTAssertGreaterThan(attack, 0.7, "one frame is most of the way up")

        let release = EnvelopeShape.step(envelope: 1, level: 0, dt: 1.0 / 60.0)
        XCTAssertGreaterThan(release, 0.8, "one frame is a small step down")

        // A full-scale envelope falls under a tenth in under half a second.
        XCTAssertLessThan(EnvelopeShape.releaseTime(to: 0.1), 0.5)
        var envelope = 1.0
        var elapsed = 0.0
        while envelope >= 0.1, elapsed < 5 {
            envelope = EnvelopeShape.step(envelope: envelope, level: 0, dt: 1.0 / 60.0)
            elapsed += 1.0 / 60.0
        }
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testTheShapeIsAFaithfulCopyOfTheEnvelope() {
        // No exaggeration and no soft knee: half an envelope is half a column.
        for value in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertEqual(Waveform.amplitude(for: value), value, accuracy: 0.0001)
        }
        XCTAssertEqual(Waveform.amplitude(for: -1), 0)
        XCTAssertEqual(Waveform.amplitude(for: 4), 1)
    }

    func testTheFirstFrameOfARecordingCannotPinTheWholeTake() {
        // The frame that is drawn before the engine has produced a buffer reads
        // as silence. It used to seed the noise floor at -120 dBFS, which pinned
        // the envelope at 1.0 for the next eighty seconds.
        let meter = VoiceMeter()
        var frame = 0.0
        for _ in 0..<3 {
            meter.push(decibels: -.infinity, now: frame)
            frame += 1.0 / 60.0
        }
        let speech = AudioLevel.rmsDBFS(samples: sine(rmsDBFS: -26))
        for _ in 0..<(60 * 20) {
            meter.push(decibels: speech, now: frame)
            frame += 1.0 / 60.0
        }
        XCTAssertLessThan(meter.envelope, 0.7)

        // The floor was seeded by the first frame that carried audio, not by
        // the silence before it.
        XCTAssertEqual(meter.floorDBFS ?? -1, speech, accuracy: 6)
    }

    /// The proof, without a microphone: a synthetic voice, through the real RMS
    /// path and the real meter, printed as bars.
    func testTheEnvelopeFollowsASyntheticVoice() {
        // A profile of a person talking: the room, a phrase, a pause, a louder
        // phrase, then the room again. Amplitudes are RMS in dBFS.
        func targetDBFS(at time: Double) -> Double {
            switch time {
            case ..<0.5: return -78
            case ..<1.6:
                // A phrase: syllables that rise and fall around -24 dBFS.
                let local = (time - 0.5) / 1.1
                return -38 + 20 * local + 6 * sin(local * 9 * .pi)
            case ..<2.3: return -78
            case ..<2.9:
                // A louder, shorter phrase.
                let local = (time - 2.3) / 0.6
                return -22 + 10 * sin(local * 10 * .pi)
            default: return -78
            }
        }

        let meter = VoiceMeter()
        let framesPerSecond = 60.0
        let blockSamples = rate / Int(framesPerSecond)
        let totalSeconds = 3.4
        var envelope: [Double] = []
        var levels: [Double] = []
        for index in 0..<Int(totalSeconds * framesPerSecond) {
            let time = Double(index) / framesPerSecond
            // Generate the samples of this block, then measure them: the test
            // goes through the same RMS the microphone goes through.
            let rms = min(1, pow(10, targetDBFS(at: time) / 20))
            let block = (0..<blockSamples).map { sample -> Int16 in
                let value = rms * sin(2 * .pi * 180 * Double(sample) / Double(rate))
                return Int16((value * 32_767).rounded())
            }
            meter.push(decibels: AudioLevel.rmsDBFS(samples: block), now: time)
            envelope.append(meter.envelope)
            levels.append(meter.level)
        }

        // The shape, in ASCII: one row every tenth of a second.
        var art = "\nlevel  "
        for index in stride(from: 0, to: envelope.count, by: 6) {
            art += String(format: "%.2f ", envelope[index])
        }
        art += "\n"
        for index in stride(from: 0, to: envelope.count, by: 6) {
            let filled = Int((envelope[index] * 40).rounded())
            let name = String(format: "%4.1fs ", Double(index) / framesPerSecond)
            art += name + String(repeating: "#", count: filled)
                + String(repeating: "·", count: max(0, 40 - filled)) + "\n"
        }
        print(art)

        // The assertions behind the picture.
        let room = envelope.prefix(30) // 0 … 0.5 s
        XCTAssertLessThan(room.max() ?? 1, 0.02, "the room is a hairline")

        let firstPhrase = Array(envelope[30..<96]) // 0.5 … 1.6 s
        XCTAssertGreaterThan(firstPhrase.max() ?? 0, 0.35, "the phrase is visible")
        XCTAssertLessThan(firstPhrase.max() ?? 1, 0.8, "and not at the top")
        XCTAssertGreaterThan(
            firstPhrase.max()! - firstPhrase.min()!,
            0.2,
            "the shape moves inside the phrase"
        )

        let pause = Array(envelope[96..<138]) // 1.6 … 2.3 s
        XCTAssertLessThan(pause.last ?? 1, 0.05, "it falls back in the pause")

        let loudPhrase = Array(envelope[138..<174])
        XCTAssertGreaterThan(loudPhrase.max() ?? 0, 0.55, "the louder phrase is higher")
        XCTAssertLessThan(loudPhrase.max() ?? 1, 0.95, "and still off the top")

        let tail = Array(envelope.suffix(24))
        XCTAssertLessThan(tail.last ?? 1, 0.05, "silence at the end is the floor")

        // Nothing in the take is pinned, which was the whole defect.
        XCTAssertEqual(envelope.filter { $0 >= 0.99 }.count, 0)
        XCTAssertEqual(levels.filter { $0 >= 0.99 }.count, 0)
    }
}
