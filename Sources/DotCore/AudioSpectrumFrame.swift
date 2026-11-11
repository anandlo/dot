import Foundation

/// One frame of the microphone's 5-band acoustic spectrum.
///
/// Each band is an energy level in `0...1`, measured on the PCM of one audio tap
/// buffer rather than from a prepared analysis of the recording. The frame is a
/// value type with no behaviour beyond its own accessors, so it lives here: the
/// per-voice scaling in ``SpectrumScale`` is written against it, and the analysis
/// that fills it stays with the recorder that owns the audio.
public struct AudioSpectrumFrame: Sendable, Equatable {
    /// The bands, from row `0` at the top (sibilants and fricatives) to row `4`
    /// at the bottom (the fundamental and chest resonance).
    public var bands: (Double, Double, Double, Double, Double)

    public static let zero = AudioSpectrumFrame(bands: (0, 0, 0, 0, 0))

    public init(bands: (Double, Double, Double, Double, Double)) {
        self.bands = bands
    }

    public static func == (lhs: AudioSpectrumFrame, rhs: AudioSpectrumFrame) -> Bool {
        lhs.bands.0 == rhs.bands.0
            && lhs.bands.1 == rhs.bands.1
            && lhs.bands.2 == rhs.bands.2
            && lhs.bands.3 == rhs.bands.3
            && lhs.bands.4 == rhs.bands.4
    }

    public subscript(row: Int) -> Double {
        switch row {
        case 0: return bands.0
        case 1: return bands.1
        case 2: return bands.2
        case 3: return bands.3
        default: return bands.4
        }
    }

    /// What one audio buffer measured.
    public struct Measure: Sendable, Equatable {
        /// The RMS of the buffer, from `0` to `1`.
        public var level: Double
        /// The five bands of the buffer.
        public var frame: AudioSpectrumFrame

        public init(level: Double, frame: AudioSpectrumFrame) {
            self.level = level
            self.frame = frame
        }
    }
}
