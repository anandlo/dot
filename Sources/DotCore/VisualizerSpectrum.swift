import Foundation

/// The spectrum the card draws: one measurement smoothed into a stamped ring.
///
/// The card has one spectrum path, and this is it. The bands of the last block of
/// audio are put on this voice's own window by ``SpectrumScale``, filtered band by
/// band so a syllable's edge is a shoulder rather than a cliff, and written into a
/// ring of frames at one entry per tick of the meter's clock.
///
/// Every entry carries the tick it was measured on (``AudioSpectrumFrame/sample``).
/// That stamp is what a style reads instead of a position: a ring moves one slot
/// every tick, so an entry found by how far back it is is a different measurement
/// on the next frame, while an entry found by its stamp is the same measurement for
/// as long as the ring holds it. The live card, the island's preview and the
/// Settings tile all advance this one type, so they draw one picture of a voice
/// rather than three that resemble each other.
public struct VisualizerSpectrum {
    /// How fast a band follows a louder measurement, in seconds.
    ///
    /// It is the rung of the measured ladder (rise 0.040 against fall 0.160) that
    /// leaves no fixed place on the grid crossing the middle of its lamp more than
    /// twice a second on the demonstration: a syllable's edge arrives over a
    /// fortieth of a second rather than a seventieth, which is slow enough that the
    /// grid follows the voice rather than the frame.
    public static let riseTau: Double = 0.040
    /// How fast a band follows a quieter measurement, in seconds.
    ///
    /// The release is four times the attack, so a gap between two words is a dip
    /// rather than a hole and the light of a syllable is still on the grid when the
    /// next one opens.
    public static let fallTau: Double = 0.160

    /// How fast a band follows a louder measurement here, in seconds.
    public let riseTau: Double
    /// How fast a band follows a quieter measurement here, in seconds.
    public let fallTau: Double
    /// Circular backing storage and its oldest-slot index.
    private var storage: [AudioSpectrumFrame]
    private var head = 0
    /// The ring, oldest first.
    public var ring: [AudioSpectrumFrame] {
        var ordered: [AudioSpectrumFrame] = []
        copyOrderedRing(into: &ordered)
        return ordered
    }
    /// The bands after the filter, which is what the next tick starts from.
    public private(set) var smoothed = AudioSpectrumFrame.zero
    /// The meter's sample number the ring was last written up to.
    private var written = 0
    /// The window of this voice's bands.
    private var scale = SpectrumScale()
    /// Whether the ring has been stamped at all.
    private var stamped = false

    /// Creates a spectrum of silence.
    ///
    /// - Parameters:
    ///   - length: how many ticks the ring holds.
    ///   - riseTau: how fast a band follows a louder measurement, in seconds.
    ///   - fallTau: how fast a band follows a quieter measurement, in seconds.
    public init(
        length: Int = Waveform.historyLength,
        riseTau: Double = VisualizerSpectrum.riseTau,
        fallTau: Double = VisualizerSpectrum.fallTau
    ) {
        self.riseTau = riseTau
        self.fallTau = fallTau
        storage = [AudioSpectrumFrame](repeating: .zero, count: max(1, length))
    }

    /// Empties the ring and the filter.
    public mutating func reset() {
        for index in storage.indices {
            storage[index] = .zero
        }
        head = 0
        smoothed = .zero
        written = 0
        scale.reset()
        stamped = false
    }

    /// Copies the ring's frames oldest-first into `destination` without extra array shifting.
    public func copyOrderedRing(into destination: inout [AudioSpectrumFrame]) {
        let count = storage.count
        destination.removeAll(keepingCapacity: true)
        destination.reserveCapacity(count)
        destination.append(contentsOf: storage[head..<count])
        if head > 0 {
            destination.append(contentsOf: storage[0..<head])
        }
    }

    /// Puts one measurement through the filter and into the ring.
    ///
    /// The ring is written from the meter's own sample count rather than from a
    /// clock of its own: one entry per sample the meter closed, stamped with that
    /// sample's number. A frame that arrives late, after the display stalled, has
    /// written several samples since the last call, and each of them gets an entry
    /// carrying the bands of this call. That is what keeps the ring contiguous: two
    /// integrators of the same clock (the meter's and the spectrum's) drift apart on
    /// a stalled frame, and a sample number the ring skipped is a column of the grid
    /// that cannot be drawn.
    ///
    /// - Parameters:
    ///   - target: the bands the recorder measured, on its own fixed scale.
    ///   - writtenSamples: how many samples the meter has written since the take
    ///     began, which is its newest sample's number plus one.
    ///   - dt: how long it is since the last call, in seconds, for the filter.
    public mutating func advance(target: AudioSpectrumFrame, writtenSamples: Int, dt: Double) {
        let scaled = scale.normalise(target, dt: dt)
        func step(_ current: Double, _ value: Double) -> Double {
            let tau = value > current ? riseTau : fallTau
            let coefficient = 1 - exp(-max(0, dt) / tau)
            return current + (value - current) * coefficient
        }
        smoothed = AudioSpectrumFrame(bands: (
            step(smoothed.bands.0, scaled.bands.0),
            step(smoothed.bands.1, scaled.bands.1),
            step(smoothed.bands.2, scaled.bands.2),
            step(smoothed.bands.3, scaled.bands.3),
            step(smoothed.bands.4, scaled.bands.4)
        ))

        let pending = writtenSamples - written
        guard pending > 0 else { return }
        let count = storage.count
        // The samples this call stands for are the meter's newest `pending`, in
        // order; they all carry the bands the filter has now.
        let newest = writtenSamples - 1
        if !stamped {
            // A ring the take has not written yet holds silence, and the slots it
            // holds are the samples before the first measurement: stamping them back
            // from it gives the grid a floor to rest on at the start of a take
            // instead of a hole that fills in from the right.
            stamped = true
            let oldest = newest - pending + 1 - count
            for index in 0..<count {
                storage[(head + index) % count].sample = oldest + index
            }
        }
        var next = newest - pending + 1
        if let last = storage[(head + count - 1) % count].sample, next <= last { next = last + 1 }
        for index in 0..<pending {
            storage[head] = AudioSpectrumFrame(bands: smoothed.bands, sample: next + index)
            head = (head + 1) % count
        }
        written = writtenSamples
    }
}
