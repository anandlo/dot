import Foundation
import XCTest

@testable import DotCore

/// What Dot learns about one microphone.
///
/// The contract has two halves. The numbers: a take moves an entry by a bounded
/// amount, the values stay inside what a meter can draw, and the book cannot
/// grow without limit. And the boundary: a calibration is a fact about the
/// level meter, never about the audio, so the bytes a provider receives must be
/// identical whether or not one exists.
final class MicrophoneCalibrationTests: XCTestCase {
    private var directory: URL!
    private let rate = 16_000

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-calibration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    /// A square wave at a precise RMS, as the microphone would hand it over.
    private func square(decibels: Double, seconds: Double) -> [Int16] {
        let amplitude = pow(10, decibels / 20)
        let count = Int(seconds * Double(rate))
        return (0..<count).map { index in
            Int16((index % 2 == 0 ? amplitude : -amplitude) * 32_767)
        }
    }

    private func entry(
        floor: Double,
        peak: Double,
        count: Int,
        at time: TimeInterval = 0
    ) -> MicrophoneCalibration {
        MicrophoneCalibration(
            noiseFloorDBFS: floor,
            peakDBFS: peak,
            observedSamples: count,
            updatedAt: Date(timeIntervalSinceReferenceDate: time)
        )
    }

    // MARK: - The update

    func testTheFirstTakeSeedsAnEntry() {
        let book = MicrophoneCalibrationBook.folding(
            [:],
            observation: MicrophoneObservation(noiseFloorDBFS: -64, peakDBFS: -8),
            device: "mic-1",
            now: Date(timeIntervalSinceReferenceDate: 10)
        )

        let seeded = book["mic-1"]
        XCTAssertEqual(seeded?.noiseFloorDBFS, -64)
        XCTAssertEqual(seeded?.peakDBFS, -8)
        XCTAssertEqual(seeded?.observedSamples, 1)
        XCTAssertEqual(seeded?.updatedAt, Date(timeIntervalSinceReferenceDate: 10))
    }

    func testATakeMovesAnEntryByTheBoundedWeight() {
        let existing = entry(floor: -60, peak: -10, count: 10)
        let book = MicrophoneCalibrationBook.folding(
            ["mic-1": existing],
            observation: MicrophoneObservation(noiseFloorDBFS: -40, peakDBFS: -3),
            device: "mic-1",
            now: Date(timeIntervalSinceReferenceDate: 20)
        )

        // A settled entry keeps a quarter of the new take: -60 + (-40 + 60) / 4.
        XCTAssertEqual(book["mic-1"]?.noiseFloorDBFS ?? 0, -55, accuracy: 0.0001)
        // The peak rises at once and falls slowly, so the loudest moment is
        // remembered until another take replaces it.
        XCTAssertEqual(book["mic-1"]?.peakDBFS ?? 0, -3, accuracy: 0.0001)
        XCTAssertEqual(book["mic-1"]?.observedSamples, 11)
    }

    func testTheFirstTakesMoveAnEntryFurtherThanSettledOnes() {
        // Half of the first observation, then a falling weight that settles at
        // the floor instead of reaching zero.
        XCTAssertEqual(MicrophoneCalibrationBook.updateWeight(observedSamples: 0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MicrophoneCalibrationBook.updateWeight(observedSamples: 1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MicrophoneCalibrationBook.updateWeight(observedSamples: 3), 0.25, accuracy: 0.0001)
        XCTAssertEqual(MicrophoneCalibrationBook.updateWeight(observedSamples: 500), 0.25, accuracy: 0.0001)
        XCTAssertEqual(
            MicrophoneCalibrationBook.updateWeight(observedSamples: 10),
            MicrophoneCalibrationBook.learningRate,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(MicrophoneCalibrationBook.learningRate, 0, "an old take must keep decaying")
    }

    func testOldObservationsAreReplacedRatherThanAccumulated() {
        // A microphone that moves to a quieter room converges on the new room
        // instead of keeping an average of both.
        var book = ["mic-1": entry(floor: -50, peak: -12, count: 20)]
        for step in 0..<40 {
            book = MicrophoneCalibrationBook.folding(
                book,
                observation: MicrophoneObservation(noiseFloorDBFS: -76, peakDBFS: -60),
                device: "mic-1",
                now: Date(timeIntervalSinceReferenceDate: Double(step + 1))
            )
        }
        XCTAssertEqual(book["mic-1"]?.noiseFloorDBFS ?? 0, -76, accuracy: 1)
        // The peak decays by a fixed number of decibels per take, so it is
        // reachable in a few dozen recordings rather than never.
        XCTAssertEqual(book["mic-1"]?.peakDBFS ?? 0, -60, accuracy: 0.001)
    }

    func testStoredValuesAreClamped() {
        let book = MicrophoneCalibrationBook.folding(
            [:],
            observation: MicrophoneObservation(noiseFloorDBFS: -400, peakDBFS: 40),
            device: "mic-1",
            now: Date()
        )
        XCTAssertEqual(book["mic-1"]?.noiseFloorDBFS, MicrophoneCalibration.noiseFloorRange.lowerBound)
        XCTAssertEqual(book["mic-1"]?.peakDBFS, MicrophoneCalibration.peakRange.upperBound)

        let loud = MicrophoneCalibrationBook.folding(
            [:],
            observation: MicrophoneObservation(noiseFloorDBFS: -2, peakDBFS: -800),
            device: "mic-2",
            now: Date()
        )
        XCTAssertEqual(loud["mic-2"]?.noiseFloorDBFS, MicrophoneCalibration.noiseFloorRange.upperBound)
        XCTAssertEqual(loud["mic-2"]?.peakDBFS, MicrophoneCalibration.peakRange.lowerBound)
    }

    func testAHandEditedBookKeepsOnlyWhatAMeterCanDraw() {
        let book = MicrophoneCalibrationBook.sanitized([
            "mic-1": entry(floor: -70, peak: -6, count: 4),
            "  ": entry(floor: -70, peak: -6, count: 4),
            "mic-nan": MicrophoneCalibration(
                noiseFloorDBFS: .nan,
                peakDBFS: .nan,
                observedSamples: 4,
                updatedAt: Date()
            ),
            "mic-empty": entry(floor: -70, peak: -6, count: 0),
        ])
        XCTAssertEqual(Set(book.keys), ["mic-1", "mic-nan"])
        XCTAssertEqual(book["mic-nan"]?.noiseFloorDBFS, MicrophoneCalibration.noiseFloorRange.lowerBound)
    }

    func testTheBookNeverGrowsPastItsLimit() {
        var book: [String: MicrophoneCalibration] = [:]
        for index in 0..<(MicrophoneCalibrationBook.maximumEntries + 12) {
            book = MicrophoneCalibrationBook.folding(
                book,
                observation: MicrophoneObservation(noiseFloorDBFS: -60, peakDBFS: -10),
                device: "mic-\(index)",
                now: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
        XCTAssertEqual(book.count, MicrophoneCalibrationBook.maximumEntries)
        // The newest devices are the ones kept.
        XCTAssertNotNil(book["mic-\(MicrophoneCalibrationBook.maximumEntries + 11)"])
        XCTAssertNil(book["mic-0"])
    }

    func testResetForgetsOneDeviceAndOnlyThatDevice() {
        let book = [
            "mic-1": entry(floor: -60, peak: -10, count: 4),
            "mic-2": entry(floor: -70, peak: -12, count: 2),
        ]
        let reset = MicrophoneCalibrationBook.resetting(book, device: "mic-1")
        XCTAssertNil(reset["mic-1"])
        XCTAssertEqual(reset["mic-2"], book["mic-2"])
        XCTAssertEqual(MicrophoneCalibrationBook.resetting(book, device: "mic-3"), book)
        XCTAssertEqual(MicrophoneCalibrationBook.resetting(book, device: nil), book)
    }

    func testADeviceWithNoEntryHasNoCalibration() {
        let book = ["mic-1": entry(floor: -60, peak: -10, count: 4)]
        XCTAssertNotNil(MicrophoneCalibrationBook.calibration(for: "mic-1", in: book))
        XCTAssertNil(MicrophoneCalibrationBook.calibration(for: "mic-2", in: book))
        XCTAssertNil(MicrophoneCalibrationBook.calibration(for: nil, in: book))
        XCTAssertNil(MicrophoneCalibrationBook.calibration(for: "   ", in: book))
    }

    // MARK: - The measurement

    func testATakeWithNoAudioTeachesNothing() {
        XCTAssertNil(MicrophoneCalibrationBook.observation(samples: [], peakDBFS: -.infinity))
        XCTAssertNil(
            MicrophoneCalibrationBook.observation(
                samples: Array(repeating: 0, count: rate * 2),
                peakDBFS: -.infinity
            )
        )
        // A tap of the shortcut that produced a tenth of a second says nothing
        // about a room.
        XCTAssertNil(
            MicrophoneCalibrationBook.observation(
                samples: square(decibels: -40, seconds: 0.05),
                peakDBFS: -40
            )
        )
    }

    func testTheRoomFloorIgnoresARareLoudFrame() {
        // Two seconds of a quiet room with one loud syllable in the middle: the
        // floor describes the room, not the syllable.
        var samples = square(decibels: -70, seconds: 2)
        let burst = square(decibels: -8, seconds: 0.1)
        let start = samples.count / 2
        for (offset, value) in burst.enumerated() {
            samples[start + offset] = value
        }
        let observation = MicrophoneCalibrationBook.observation(
            samples: samples,
            peakDBFS: AudioLevel.peakDBFS(samples: samples)
        )
        XCTAssertNotNil(observation)
        XCTAssertEqual(observation?.noiseFloorDBFS ?? 0, -70, accuracy: 3)
        XCTAssertGreaterThan(observation?.peakDBFS ?? -100, -12, "the loud moment is measured")
    }

    // MARK: - The book in the configuration

    func testAConfigurationWithoutTheBookLoads() throws {
        let url = directory.appendingPathComponent("config.json")
        try #"{"provider": "openai", "autoPaste": false}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let loaded = DotConfig.load(from: url)
        XCTAssertTrue(loaded.microphoneCalibration.isEmpty)
        XCTAssertFalse(loaded.autoPaste)
    }

    func testTheBookRoundTripsAndIsReadBack() throws {
        var config = DotConfig.default
        config.microphoneDeviceUID = "mic-1"
        config.microphoneCalibration = ["mic-1": entry(floor: -62, peak: -11, count: 14, at: 120)]
        let url = directory.appendingPathComponent("config.json")
        try config.save(to: url)

        let loaded = DotConfig.load(from: url)
        XCTAssertEqual(loaded.microphoneCalibration, config.microphoneCalibration)
        XCTAssertEqual(
            MicrophoneCalibrationBook.calibration(for: "mic-1", in: loaded.microphoneCalibration)?
                .observedSamples,
            14
        )
    }

    func testABookOfNonsenseLoadsEmptyRatherThanBroken() throws {
        let url = directory.appendingPathComponent("config.json")
        try #"{"microphoneCalibration": {"mic-1": {"noiseFloorDBFS": 5, "peakDBFS": 900, "observedSamples": -4, "updatedAt": 0}}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let loaded = DotConfig.load(from: url)
        // A negative count is not a device Dot has heard: the entry is dropped.
        XCTAssertTrue(loaded.microphoneCalibration.isEmpty)

        try #"{"microphoneCalibration": "not a book"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(DotConfig.load(from: url).microphoneCalibration.isEmpty)
    }

    // MARK: - The scale

    func testADeviceWithNoHistoryIsDrawnExactlyAsItShipped() {
        XCTAssertEqual(LevelScale.window(for: nil), LevelScale.fixedWindow)
        XCTAssertEqual(LevelScale.fixedWindow.bottomDBFS, LevelScale.gate(floor: LevelScale.floorDBFS))
        XCTAssertEqual(LevelScale.fixedWindow.topDBFS, LevelScale.ceilingDBFS)

        for decibels in stride(from: -90.0, through: 10.0, by: 5.0) {
            XCTAssertEqual(
                LevelScale.level(decibels: decibels, window: LevelScale.fixedWindow),
                LevelScale.level(decibels: decibels, floor: LevelScale.floorDBFS),
                accuracy: 0.0001,
                "\(decibels) dBFS"
            )
        }
    }

    func testAQuietMicrophoneGetsTheRoomItNeeds() {
        // A headset whose room is -70 and whose loudest word is -40 dBFS.
        let quiet = entry(floor: -70, peak: -40, count: 8)
        let window = LevelScale.window(for: quiet)
        // A room quieter than the shipped floor is drawn on the shipped window:
        // the scale never goes below the one every device is drawn on.
        XCTAssertEqual(window.bottomDBFS, LevelScale.fixedWindow.bottomDBFS)
        // The top is the physical ceiling whatever the device did: a top that
        // followed the loudest word of one device made the window 24 decibels
        // tall there and 38 on another, so ordinary speech was at full height
        // from the first syllable. Heights have to mean the same thing on every
        // device, so only the bottom is the device's.
        XCTAssertEqual(window.topDBFS, LevelScale.ceilingDBFS)

        let fixed = LevelScale.level(decibels: -40, window: LevelScale.fixedWindow)
        let calibrated = LevelScale.level(decibels: -40, window: window)
        XCTAssertEqual(calibrated, fixed, accuracy: 0.0001)
        XCTAssertEqual(calibrated, 0.297, accuracy: 0.01)
    }

    func testANoisyRoomLiftsTheBottomAndAHotMicrophoneKeepsTheTop() {
        let noisy = entry(floor: -30, peak: 0, count: 8)
        let window = LevelScale.window(for: noisy)
        XCTAssertEqual(window.bottomDBFS, LevelScale.gateCeilingDBFS)
        XCTAssertEqual(window.topDBFS, LevelScale.ceilingDBFS)

        // A room louder than the scale can lift to is drawn as a quiet room
        // with a voice in it, not as a window a few decibels wide.
        let narrow = entry(floor: -50, peak: -49, count: 2)
        let narrowWindow = LevelScale.window(for: narrow)
        XCTAssertEqual(narrowWindow.topDBFS, LevelScale.ceilingDBFS)
        XCTAssertGreaterThanOrEqual(
            narrowWindow.topDBFS - narrowWindow.bottomDBFS,
            LevelScale.ceilingDBFS - LevelScale.gateCeilingDBFS
        )

        // The voice in the noisy room still moves, which is the point of the
        // floor: it is drawn from the room up, never normalised to the room.
        let speech = LevelScale.level(decibels: -18, window: window)
        XCTAssertGreaterThan(speech, 0.30)
        XCTAssertLessThan(speech, 0.85)
    }

    @MainActor
    func testTheMeterStartsFromTheLearnedFloor() {
        let meter = VoiceMeter()
        meter.seed(floor: -50)
        XCTAssertEqual(meter.floorDBFS, -50)

        // A quieter moment does not move a seeded floor far, and the level is
        // drawn against the room Dot already knows.
        meter.push(decibels: -20, now: 0)
        XCTAssertEqual(meter.floorDBFS ?? 0, -50, accuracy: 0.5)
        XCTAssertGreaterThan(meter.level, 0.45)

        // A missing or impossible seed leaves the meter blind, as it shipped.
        let blind = VoiceMeter()
        blind.seed(floor: nil)
        blind.seed(floor: .nan)
        XCTAssertNil(blind.floorDBFS)
    }

    @MainActor
    func testAQuietMicrophonesWaveformMovesAsMuchAsAHotOnes() {
        // The defect the calibration exists for: the same voice on a quiet
        // headset drew a hairline next to a hot USB microphone. The fix is the
        // scale's, not the calibration's — heights are absolute on one dBFS
        // window for every device — so a blind meter and a calibrated one draw
        // the same words at the same height, and the calibration's job is only
        // to put the room at the floor instead of above it.
        let quiet = entry(floor: -70, peak: -40, count: 8)
        let speech = -42.0

        let blind = VoiceMeter()
        let learned = VoiceMeter()
        learned.setCalibration(quiet)
        learned.seed(floor: quiet.noiseFloorDBFS)
        for frame in 0..<120 {
            let now = Double(frame) / 60
            let syllable = 4 * sin(Double(frame / 6) * 0.9)
            blind.push(decibels: speech + syllable, now: now)
            learned.push(decibels: speech + syllable, now: now)
        }

        XCTAssertGreaterThan(blind.envelope, 0.2, "a quiet device is drawn, not silenced")
        XCTAssertGreaterThan(learned.envelope, 0.2)
        XCTAssertEqual(learned.envelope, blind.envelope, accuracy: 0.05, "on the same top")

        // A room above the shipped floor lifts the bottom, and the voice above
        // that room is still a shape rather than the same height as the room.
        let noisy = entry(floor: -44, peak: -8, count: 8)
        let inNoise = VoiceMeter()
        inNoise.setCalibration(noisy)
        var frame = 0
        for _ in 0..<(60 * 3) {
            inNoise.push(decibels: -44, now: Double(frame) / 60)
            frame += 1
        }
        XCTAssertLessThan(inNoise.envelope, 0.12, "the room sits at the floor")
        for _ in 0..<60 {
            inNoise.push(decibels: -20, now: Double(frame) / 60)
            frame += 1
        }
        XCTAssertGreaterThan(inNoise.envelope, 0.45, "and the voice is drawn above it")
    }

    @MainActor
    func testADeviceWithNoCalibrationKeepsTheFixedScale() {
        let shipped = VoiceMeter()
        let calibrated = VoiceMeter()
        calibrated.setCalibration(nil)
        for frame in 0..<60 {
            let level = -34.0
            shipped.push(decibels: level, now: Double(frame) / 60)
            calibrated.push(decibels: level, now: Double(frame) / 60)
        }
        XCTAssertEqual(shipped.envelope, calibrated.envelope, accuracy: 0.0001)
        XCTAssertNil(calibrated.calibration)
    }

    // MARK: - The boundary

    func testTheWAVIsByteIdenticalWithAndWithoutACalibration() {
        // The take the microphone produced.
        var samples = square(decibels: -70, seconds: 1)
        samples.append(contentsOf: square(decibels: -20, seconds: 1))
        let original = samples
        let baseline = WAVWriter.encode(samples: samples)

        // Learning from the take, and drawing it on the window that entry
        // produces, must not touch a single byte of what a provider receives.
        XCTAssertNotNil(
            MicrophoneCalibrationBook.observation(
                samples: samples,
                peakDBFS: AudioLevel.peakDBFS(samples: samples)
            )
        )
        var config = DotConfig.default
        config.microphoneCalibration = MicrophoneCalibrationBook.folding(
            [:],
            observation: MicrophoneObservation(noiseFloorDBFS: -70, peakDBFS: -40),
            device: "mic-1",
            now: Date()
        )
        let calibration = MicrophoneCalibrationBook.calibration(
            for: "mic-1",
            in: config.microphoneCalibration
        )
        XCTAssertNotNil(calibration)
        // A quiet room is drawn on the shipped window: a calibration may lift the
        // bottom of a scale, never lower it below the one every device is drawn
        // on, because that would make a quiet room read as speech.
        XCTAssertEqual(LevelScale.window(for: calibration), LevelScale.fixedWindow)

        XCTAssertEqual(WAVWriter.encode(samples: samples), baseline)
        XCTAssertEqual(samples, original, "the audio is measured, never scaled in place")
    }
}
