import Foundation

/// A synthetic voice.
///
/// The preview mode needs a signal that looks like speech without a
/// microphone: a slow envelope with gaps and peaks, never a sine wave. This
/// is that envelope, as the RMS of a plausible voice.
public enum SpeechEnvelope {
    /// The length of the loop, in seconds.
    public static let loopSeconds: Double = 2.6
    /// The level of the room between the phrases.
    public static let roomTone: Double = 0.010

    /// The RMS of the voice at a moment in time, from `0` to `1`.
    ///
    /// - Parameter time: the time in seconds.
    /// - Returns: the RMS of the voice.
    public static func rms(at time: Double) -> Double {
        let t = time.truncatingRemainder(dividingBy: loopSeconds)
        for phrase in phrases where t >= phrase.start && t < phrase.start + phrase.length {
            let local = (t - phrase.start) / phrase.length
            let syllable = local * Double(phrase.syllables)
            let index = Int(syllable)
            let phase = syllable - Double(index)
            let weight = phrase.weights[index % phrase.weights.count]
            // A syllable is a bump: it rises and falls.
            let bump = sin(phase * .pi)
            // The phrase fades in and out.
            let envelope = min(1, local / 0.06) * min(1, (1 - local) / 0.10)
            return roomTone + phrase.gain * weight * bump * envelope
        }
        return roomTone
    }

    /// One phrase of the synthetic voice.
    private struct Phrase {
        var start: Double
        var length: Double
        var gain: Double
        var syllables: Int
        var weights: [Double]
    }

    /// The phrases of the loop: a loud one, a short one and a quiet one,
    /// with gaps between them.
    private static let phrases: [Phrase] = [
        Phrase(
            start: 0.25,
            length: 0.80,
            gain: 0.32,
            syllables: 5,
            weights: [0.55, 0.95, 0.40, 0.80, 0.65]
        ),
        Phrase(
            start: 1.30,
            length: 0.45,
            gain: 0.20,
            syllables: 3,
            weights: [0.70, 0.45, 0.85]
        ),
        Phrase(
            start: 1.95,
            length: 0.42,
            gain: 0.26,
            syllables: 3,
            weights: [0.50, 0.90, 0.60]
        ),
    ]
}

/// A clock, as the HUD shows it.
public enum HUDClock {
    /// The clock of a recording, as `m:ss`.
    ///
    /// - Parameter seconds: the length of the recording.
    /// - Returns: the clock, as it is drawn.
    public static func string(for seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
