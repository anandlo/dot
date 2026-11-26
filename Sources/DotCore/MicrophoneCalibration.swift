import Foundation

/// What Dot has learned about one microphone.
///
/// A quiet headset and a hot USB microphone produce very different numbers for
/// the same voice. The calibration records the two facts that describe a device
/// rather than a performance — where its room sits and how loud it gets — so the
/// level meter can start from what is known instead of starting blind.
///
/// It affects metering only. Nothing in this type, and nothing that reads it,
/// may touch the audio that is sent to a provider: the samples are measured
/// after they are recorded, never scaled or gated before the WAV is written.
public struct MicrophoneCalibration: Codable, Sendable, Equatable {
    /// The room floor of the device, in dBFS.
    public var noiseFloorDBFS: Double
    /// The loudest moment Dot has heard on the device, in dBFS.
    public var peakDBFS: Double
    /// How loud the person's speech gets on the device, in dBFS: the upper end
    /// of the 20 ms frames that carry a voice, averaged over takes.
    ///
    /// `nil` for an entry learned before Dot measured it. Unlike the peak, one
    /// clap or plosive is a single frame among hundreds, so it cannot move it.
    public var speechDBFS: Double?
    /// How many recordings were folded in.
    public var observedSamples: Int
    /// When the entry last changed.
    public var updatedAt: Date

    /// The room floors Dot accepts, in dBFS.
    ///
    /// The upper bound is where the level scale stops lifting its bottom: a
    /// floor above it would make the scale a few decibels wide and every level
    /// would read the same.
    public static let noiseFloorRange: ClosedRange<Double> = -90 ... -30
    /// The peaks Dot accepts, in dBFS.
    ///
    /// The upper bound is the top of the fixed scale, so a calibration can
    /// never describe a device as louder than the window the meter can draw.
    public static let peakRange: ClosedRange<Double> = -90 ... 6
    /// The largest count a stored entry carries.
    ///
    /// The count is a counter, not a weight: it stops growing here so a file
    /// that has been through thousands of takes still holds a number a person
    /// can read, and so the update weight can never round to zero.
    public static let maximumObservedSamples = 999

    /// Creates an entry.
    public init(
        noiseFloorDBFS: Double,
        peakDBFS: Double,
        observedSamples: Int,
        updatedAt: Date,
        speechDBFS: Double? = nil
    ) {
        self.noiseFloorDBFS = noiseFloorDBFS
        self.peakDBFS = peakDBFS
        self.speechDBFS = speechDBFS
        self.observedSamples = observedSamples
        self.updatedAt = updatedAt
    }

    /// The entry with every value inside the range Dot accepts.
    ///
    /// Decoding cannot refuse a file a person edited by hand, and a value that
    /// is not a number would poison every scale that reads it, so the clamp is
    /// applied on the way in as well as on the way out.
    public var clamped: MicrophoneCalibration {
        MicrophoneCalibration(
            noiseFloorDBFS: Self.clamp(noiseFloorDBFS, to: Self.noiseFloorRange),
            peakDBFS: Self.clamp(peakDBFS, to: Self.peakRange),
            observedSamples: min(max(observedSamples, 0), Self.maximumObservedSamples),
            updatedAt: updatedAt,
            speechDBFS: speechDBFS.map { Self.clamp($0, to: Self.peakRange) }
        )
    }

    /// Whether the entry describes a device Dot can draw.
    public var isUsable: Bool {
        noiseFloorDBFS.isFinite && peakDBFS.isFinite && observedSamples > 0
    }

    /// A value held inside a range, with a non-number mapped to the low end.
    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// What one recording measured about the microphone that made it.
public struct MicrophoneObservation: Sendable, Equatable {
    /// The room floor of the take, in dBFS.
    public let noiseFloorDBFS: Double
    /// The loudest moment of the take, in dBFS.
    public let peakDBFS: Double
    /// How loud the voice got in the take, in dBFS, or `nil` when the take
    /// held too little voice to say.
    public let speechDBFS: Double?

    /// Creates an observation.
    public init(noiseFloorDBFS: Double, peakDBFS: Double, speechDBFS: Double? = nil) {
        self.noiseFloorDBFS = noiseFloorDBFS
        self.peakDBFS = peakDBFS
        self.speechDBFS = speechDBFS
    }
}

/// The book of calibrations, keyed by the microphone's CoreAudio UID.
///
/// The rules live here rather than in the recorder so they can be tested
/// without a microphone: which takes count, how one take moves an entry, when
/// an entry is thrown away, and what a reset removes.
public enum MicrophoneCalibrationBook {
    /// How many devices the book keeps.
    ///
    /// Microphones come and go — a borrowed headset, a dock, a Bluetooth
    /// speaker — and a file that grows one entry per device ever seen is a file
    /// that grows forever. The oldest entry is dropped past this count.
    public static let maximumEntries = 24

    /// The smallest share a single take keeps once the book is settled.
    ///
    /// The update is a bounded exponential average: early takes move an entry
    /// by up to a half, and from ``settledSamples`` on every take moves it by
    /// this much. The bound is the point — a device that is moved to another
    /// room, or a filter that is switched on, has to be able to replace what
    /// was learned, so old observations must decay instead of being permanent.
    public static let learningRate: Double = 0.25

    /// How many takes a new entry takes to reach the settled weight.
    static var settledSamples: Int { Int((1 / learningRate).rounded()) }

    /// The shortest take that can teach anything, in samples.
    ///
    /// A tenth of a second at the 16 kHz Dot records at. A tap of the shortcut
    /// that produced almost no audio says nothing about a room.
    public static let minimumTakeSamples = 1_600

    /// The length of one analysis frame, in samples.
    ///
    /// Twenty milliseconds at 16 kHz: long enough for an RMS to mean
    /// something, short enough that one syllable cannot become a whole frame.
    public static let frameSamples = 320

    /// The share of the quietest frames that describes the room.
    ///
    /// The frames are sorted and this position is taken, so a keyboard click, a
    /// door or one loud word cannot set the floor: only a take that is quiet
    /// almost everywhere describes a quiet room.
    public static let roomPercentile: Double = 0.15

    /// The entry for one device, or `nil` when the device has no history.
    ///
    /// A `nil` or blank UID has no entry: the system default microphone is not
    /// a device, and the UID that recorded is what the book is keyed by.
    public static func calibration(
        for device: String?,
        in book: [String: MicrophoneCalibration]
    ) -> MicrophoneCalibration? {
        guard let key = key(for: device), let entry = book[key], entry.isUsable else {
            return nil
        }
        return entry.clamped
    }

    /// Folds one take into the book.
    ///
    /// - Parameters:
    ///   - book: the entries as they are.
    ///   - observation: what the take measured.
    ///   - device: the UID of the microphone that recorded it.
    ///   - now: the time of the take.
    /// - Returns: the book with the entry moved, held at ``maximumEntries``.
    public static func folding(
        _ book: [String: MicrophoneCalibration],
        observation: MicrophoneObservation,
        device: String?,
        now: Date
    ) -> [String: MicrophoneCalibration] {
        guard let key = key(for: device),
              observation.noiseFloorDBFS.isFinite,
              observation.peakDBFS.isFinite
        else { return book }

        var next = book
        let observedFloor = MicrophoneCalibration.clamp(
            observation.noiseFloorDBFS,
            to: MicrophoneCalibration.noiseFloorRange
        )
        let observedPeak = MicrophoneCalibration.clamp(
            observation.peakDBFS,
            to: MicrophoneCalibration.peakRange
        )

        if let existing = book[key]?.clamped {
            let weight = updateWeight(observedSamples: existing.observedSamples)
            let floor = existing.noiseFloorDBFS + (observedFloor - existing.noiseFloorDBFS) * weight
            // The peak is a decaying maximum, not an average: an average would
            // let one quiet take describe a loud microphone as quiet, while a
            // permanent maximum would describe a device in the room it was in
            // a year ago. It falls by a fixed number of decibels per take, so
            // it can be replaced.
            let peak = max(observedPeak, existing.peakDBFS - peakDecayDB)
            // Speech is a level a person returns to, so it is averaged like
            // the floor. A take without enough voice leaves it as it was.
            let speech: Double?
            if let observed = observedSpeech(observation) {
                speech = existing.speechDBFS.map { $0 + (observed - $0) * weight } ?? observed
            } else {
                speech = existing.speechDBFS
            }
            next[key] = MicrophoneCalibration(
                noiseFloorDBFS: floor,
                peakDBFS: peak,
                observedSamples: min(existing.observedSamples + 1, MicrophoneCalibration.maximumObservedSamples),
                updatedAt: now,
                speechDBFS: speech
            ).clamped
        } else {
            next[key] = MicrophoneCalibration(
                noiseFloorDBFS: observedFloor,
                peakDBFS: observedPeak,
                observedSamples: 1,
                updatedAt: now,
                speechDBFS: observedSpeech(observation)
            ).clamped
        }
        return trimmed(next)
    }

    /// The book without one device.
    ///
    /// Reset is per device on purpose: forgetting what was learned about a
    /// borrowed headset must not throw away the calibration of the microphone
    /// the person uses every day.
    public static func resetting(
        _ book: [String: MicrophoneCalibration],
        device: String?
    ) -> [String: MicrophoneCalibration] {
        guard let key = key(for: device) else { return book }
        var next = book
        next.removeValue(forKey: key)
        return next
    }

    /// The book with only entries Dot can use, and never more than
    /// ``maximumEntries`` of them.
    public static func sanitized(_ book: [String: MicrophoneCalibration]) -> [String: MicrophoneCalibration] {
        var usable: [String: MicrophoneCalibration] = [:]
        for (storedKey, entry) in book {
            guard let device = key(for: storedKey) else { continue }
            let clamped = entry.clamped
            guard clamped.isUsable else { continue }
            usable[device] = clamped
        }
        return trimmed(usable)
    }

    /// How much one take moves an entry, from a half down to the floor.
    ///
    /// - Parameter observedSamples: how many takes the entry already holds.
    public static func updateWeight(observedSamples: Int) -> Double {
        let count = max(1, observedSamples)
        return max(learningRate, 1 / Double(count + 1))
    }

    /// The observation's speech level, or `nil` when it has none a book can use.
    private static func observedSpeech(_ observation: MicrophoneObservation) -> Double? {
        guard let value = observation.speechDBFS, value.isFinite else { return nil }
        return MicrophoneCalibration.clamp(value, to: MicrophoneCalibration.peakRange)
    }

    /// How far above the take's room a frame must be to count as voice, in dB.
    public static let voicedMarginDB: Double = 10
    /// The share of the voiced frames below the take's speech level.
    ///
    /// The upper end rather than the middle: the level is where the person's
    /// louder syllables sit, and the top tenth leaves out the plosives,
    /// coughs and claps a single loudest frame would be.
    public static let speechPercentile: Double = 0.90
    /// The fewest voiced frames that describe a voice: a fifth of a second.
    public static let minimumVoicedFrames = 10

    /// How far a stored peak falls per take, in decibels.
    public static let peakDecayDB: Double = 1.5

    /// What one take measured about the room and the loudest moment.
    ///
    /// - Parameters:
    ///   - samples: the 16 kHz mono samples of the take.
    ///   - peakDBFS: the loudest sample of the take, in dBFS.
    /// - Returns: the observation, or `nil` when the take carries no usable
    ///   audio — nothing recorded, only digital silence, or too short to say
    ///   anything about a room.
    public static func observation(samples: [Int16], peakDBFS: Double) -> MicrophoneObservation? {
        guard samples.count >= minimumTakeSamples else { return nil }
        var frames: [Double] = []
        frames.reserveCapacity(samples.count / frameSamples)
        var index = 0
        while index + frameSamples <= samples.count {
            var total = 0.0
            for offset in index..<(index + frameSamples) {
                let value = Double(samples[offset]) / 32_768.0
                total += value * value
            }
            let decibels = AudioLevel.decibels((total / Double(frameSamples)).squareRoot())
            if decibels.isFinite, decibels > LevelScale.silenceDBFS {
                frames.append(decibels)
            }
            index += frameSamples
        }
        guard !frames.isEmpty else { return nil }
        frames.sort()
        let position = min(
            frames.count - 1,
            max(0, Int((Double(frames.count - 1) * roomPercentile).rounded()))
        )
        let floor = frames[position]
        let voiced = frames.drop { $0 < floor + voicedMarginDB }
        var speech: Double?
        if voiced.count >= minimumVoicedFrames {
            let offset = min(
                voiced.count - 1,
                max(0, Int((Double(voiced.count - 1) * speechPercentile).rounded()))
            )
            speech = voiced[voiced.startIndex + offset]
        }
        return MicrophoneObservation(
            noiseFloorDBFS: floor,
            peakDBFS: peakDBFS,
            speechDBFS: speech
        )
    }

    /// The UID a book key may use, or `nil` for a device that cannot have one.
    static func key(for device: String?) -> String? {
        let trimmed = device?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Drops the oldest entries past ``maximumEntries``.
    private static func trimmed(_ book: [String: MicrophoneCalibration]) -> [String: MicrophoneCalibration] {
        guard book.count > maximumEntries else { return book }
        let ordered = book.sorted { $0.value.updatedAt > $1.value.updatedAt }
        var next: [String: MicrophoneCalibration] = [:]
        for (key, entry) in ordered.prefix(maximumEntries) {
            next[key] = entry
        }
        return next
    }
}
