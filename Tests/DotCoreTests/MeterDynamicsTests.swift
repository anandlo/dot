import CoreGraphics
import Foundation
import XCTest

@testable import DotCore

/// The dynamics of the meter.
///
/// The complaint behind these tests is a visual one, "it just hits the
/// threshold whenever I speak, it is not able to reflect my audio range", so
/// every test here is about a number the shape is drawn from: the level at a
/// given RMS, the two adaptive values that keep a room and a voice apart, and
/// the envelope that decides how fast the shape answers.
@MainActor
final class MeterDynamicsTests: XCTestCase {
    /// The anchors of the shipped window, printed and asserted.
    ///
    /// The table is the contract. A whisper is a small shape, ordinary speech is
    /// a little over half, a raised voice is three quarters, a shout is high and
    /// not at the top, and full scale keeps a hair of headroom above it.
    private let anchors: [(decibels: Double, minimum: Double, maximum: Double)] = [
        (-50, 0.0, 0.10),
        (-45, 0.12, 0.24),
        (-35, 0.34, 0.48),
        (-25, 0.55, 0.68),
        (-15, 0.72, 0.84),
        (-8, 0.82, 0.92),
        (0, 0.90, 0.98),
    ]

    func testTheScaleSpreadsTheVoiceOverTheWholeShape() {
        var previous = -1.0
        for anchor in anchors {
            let level = LevelScale.level(decibels: anchor.decibels)
            XCTAssertGreaterThanOrEqual(level, anchor.minimum, "\(anchor.decibels) dBFS")
            XCTAssertLessThanOrEqual(level, anchor.maximum, "\(anchor.decibels) dBFS")
            XCTAssertGreaterThan(level, previous, "\(anchor.decibels) dBFS is higher than the one before")
            previous = level
        }
        let shape = anchors.map { String(format: "%5.1f dBFS -> %.3f", $0.decibels, LevelScale.level(decibels: $0.decibels)) }
        print("level scale\n  " + shape.joined(separator: "\n  "))
    }

    func testThePerceptualCurveKeepsItsEnds() {
        // A position of zero is still the floor and a position of one is still
        // one: the knee bends the middle without moving either end.
        XCTAssertEqual(LevelScale.perceptual(0), 0)
        XCTAssertEqual(LevelScale.perceptual(1), 1, accuracy: 0.000001)
        XCTAssertEqual(LevelScale.perceptual(-3), 0)
        XCTAssertEqual(LevelScale.perceptual(7), 1)

        // Monotonic, with no flat spot a level could disappear into.
        var previous = -1.0
        for step in 0...1000 {
            let value = LevelScale.perceptual(Double(step) / 1000)
            XCTAssertGreaterThan(value, previous + 0.0001)
            previous = value
        }

        // And it lifts the middle, which is the whole point of it.
        XCTAssertGreaterThan(LevelScale.perceptual(0.5), 0.6)
    }

    func testWhisperNormalAndLoudAreThreeVisiblyDifferentHeights() {
        let whisper = LevelScale.level(decibels: -45)
        let normal = LevelScale.level(decibels: -25)
        let loud = LevelScale.level(decibels: -8)
        XCTAssertGreaterThan(whisper, 0.10, "a whisper is above the floor")
        XCTAssertLessThan(whisper, 0.28)
        XCTAssertGreaterThan(normal - whisper, 0.30, "normal speech is well above a whisper")
        XCTAssertGreaterThan(loud - normal, 0.18, "a loud word is well above normal speech")
        XCTAssertLessThan(loud, 0.95, "and never at the top")
    }

    func testSilenceIsTheFloor() {
        XCTAssertEqual(LevelScale.level(decibels: -.infinity), 0)
        XCTAssertEqual(LevelScale.level(decibels: -90), 0)
        XCTAssertEqual(LevelScale.level(decibels: -58), 0)
    }

    func testSustainedSpeechDoesNotLiftTheFloor() {
        // Eight seconds of an unbroken voice, fed the way the recorder feeds the
        // card: one block held for six frames, then the next syllable. The floor
        // used to climb at one and a half decibels a second from every frame,
        // which raised the bottom of the scale by twelve decibels over the take
        // and drew the end of it as a hairline.
        let meter = VoiceMeter()
        for frame in 0..<(60 * 8) {
            let block = frame / 6
            let syllable = 5 * sin(Double(block) * 0.9)
            meter.push(decibels: -22 + syllable, now: Double(frame) / 60.0)
        }
        XCTAssertEqual(meter.floorDBFS ?? 0, LevelScale.floorDBFS, accuracy: 0.001)
        XCTAssertGreaterThan(meter.envelope, 0.5, "and the voice is drawn at its height")
    }

    func testEvenAPerfectlySteadyVoiceCannotTakeTheScaleWithIt() {
        // The pathological case: a tone with no modulation at all, held for
        // eight seconds. Real speech never does this, but a held vowel or a test
        // tone can, and the floor must still be bounded: it may never climb to
        // the voice itself, which would leave the shape a hairline.
        let meter = VoiceMeter()
        for frame in 0..<(60 * 8) {
            meter.push(decibels: -22, now: Double(frame) / 60.0)
        }
        XCTAssertLessThanOrEqual(meter.floorDBFS ?? 0, VoiceMeter.floorCeilingDBFS + 0.001)
        XCTAssertGreaterThan(meter.envelope, 0.35, "the voice is still a shape")
    }

    func testASteadyRoomLiftsTheFloorAndTheVoiceAboveItStillMoves() {
        // A fan: steady, and above the shipped floor.
        let meter = VoiceMeter()
        var frame = 0
        for _ in 0..<(60 * 5) {
            meter.push(decibels: -44, now: Double(frame) / 60.0)
            frame += 1
        }
        let floor = meter.floorDBFS ?? -56
        XCTAssertGreaterThan(floor, -50, "the floor rose to the fan")
        XCTAssertLessThanOrEqual(floor, VoiceMeter.floorCeilingDBFS)
        XCTAssertLessThan(meter.level, 0.10, "and the fan itself reads as the floor")

        // A voice over that fan is still a shape and not the floor.
        for _ in 0..<30 {
            meter.push(decibels: -20, now: Double(frame) / 60.0)
            frame += 1
        }
        XCTAssertGreaterThan(meter.envelope, 0.45)
    }

    func testTheFloorNeverSeedsFromFramesWithoutAudio() {
        let meter = VoiceMeter()
        for frame in 0..<120 {
            meter.push(decibels: -.infinity, now: Double(frame) / 60.0)
        }
        XCTAssertNil(meter.floorDBFS)
        XCTAssertEqual(meter.level, 0)

        // The first frame that carries audio seeds the shipped floor rather than
        // its own level, which is what keeps a take that begins with a word on
        // the scale it deserves.
        meter.push(decibels: -20, now: 2)
        XCTAssertEqual(meter.floorDBFS ?? 0, LevelScale.floorDBFS, accuracy: 0.001)
        XCTAssertGreaterThan(meter.level, 0.65)
    }

    func testTheCeilingHoldsTheLoudestMomentAndReleasesSlowly() {
        let meter = VoiceMeter()
        var frame = 0
        for _ in 0..<60 {
            meter.push(decibels: -8, now: Double(frame) / 60.0)
            frame += 1
        }
        let loud = meter.ceiling
        XCTAssertGreaterThan(loud, 0.8)

        // Three seconds of room: the ceiling falls, and never below the floor it
        // is allowed to fall to, so a quiet take still has a peak to draw.
        for _ in 0..<(60 * 3) {
            meter.push(decibels: -70, now: Double(frame) / 60.0)
            frame += 1
        }
        XCTAssertLessThan(meter.ceiling, loud)
        XCTAssertGreaterThanOrEqual(meter.ceiling, VoiceMeter.minimumCeiling)
    }

    func testACalibrationLiftsTheBottomAndNeverTheTop() {
        let quiet = MicrophoneCalibration(
            noiseFloorDBFS: -70, peakDBFS: -40, observedSamples: 8, updatedAt: Date()
        )
        let window = LevelScale.window(for: quiet)
        XCTAssertEqual(window.topDBFS, LevelScale.ceilingDBFS)
        // A room quieter than the shipped floor is drawn on the shipped window:
        // a calibration may lift the bottom of the scale, never lower it.
        XCTAssertEqual(window.bottomDBFS, LevelScale.fixedWindow.bottomDBFS)

        // No device, however quiet its loudest word, gets a window whose top
        // follows that word: a loud word is never glued to the top of the card
        // on one microphone and drawn mid-height on another.
        for (floor, peak) in [(-70.0, -40.0), (-55.0, -6.0), (-45.0, -9.0), (-30.0, 0.0)] {
            let entry = MicrophoneCalibration(
                noiseFloorDBFS: floor, peakDBFS: peak, observedSamples: 8, updatedAt: Date()
            )
            let drawn = LevelScale.window(for: entry)
            XCTAssertEqual(drawn.topDBFS, LevelScale.ceilingDBFS, "room \(floor)")
            XCTAssertLessThan(
                LevelScale.level(decibels: -3, window: drawn),
                0.97,
                "room \(floor) pins a loud word at the top"
            )
        }
    }
}

/// The amber the meter is drawn in.
///
/// The product's colour is one: the live dot's amber, `#F5B944`. The shape has
/// to be recognisably that colour at every height, because a shape that turns
/// white at the top has no colour left to say "that was loud" with and is not
/// the meter the owner of the product remembers.
final class MeterRampTests: XCTestCase {
    func testEveryHeightIsWarmAmber() {
        for step in 0...100 {
            let tint = MeterRamp.tint(level: Double(step) / 100, ceiling: 1)
            XCTAssertGreaterThan(tint.red, tint.green, "red is the brightest component")
            XCTAssertGreaterThan(tint.green, tint.blue)
            XCTAssertLessThan(tint.blue, 0.62, "never white")
        }
    }

    func testABarGetsBrighterAndMoreOpaqueAsItRises() {
        var previous = MeterRamp.tint(level: 0, ceiling: 1)
        var previousLuma = previous.red + previous.green + previous.blue
        for step in 1...100 {
            let tint = MeterRamp.tint(level: Double(step) / 100, ceiling: 1)
            let luma = tint.red + tint.green + tint.blue
            XCTAssertGreaterThanOrEqual(luma, previousLuma - 0.0001)
            XCTAssertGreaterThan(tint.opacity, previous.opacity - 0.0001)
            previous = tint
            previousLuma = luma
        }
        XCTAssertLessThan(previous.opacity, 1.01)
    }

    func testTheQuietEndIsDimAndTheLiveColourIsTheProductAmber() {
        let floor = MeterRamp.tint(level: 0, ceiling: 1)
        XCTAssertLessThan(floor.opacity, 0.4)
        XCTAssertLessThan(floor.green, MeterRamp.live.green, "the floor is deeper than the live amber")

        // The colour at ordinary speech is the product's own `#F5B944`.
        XCTAssertEqual(MeterRamp.live.red, 0.961, accuracy: 0.001)
        XCTAssertEqual(MeterRamp.live.green, 0.725, accuracy: 0.001)
        XCTAssertEqual(MeterRamp.live.blue, 0.267, accuracy: 0.001)
    }

    func testAPeakIsWarmerThanTheSameHeightInAQuietTake() {
        let quietTake = MeterRamp.tint(level: 0.55, ceiling: 0.55)
        let loudTake = MeterRamp.tint(level: 0.55, ceiling: 1)
        XCTAssertGreaterThan(quietTake.blue, loudTake.blue, "a peak of a quiet take is warmer")
    }
}
