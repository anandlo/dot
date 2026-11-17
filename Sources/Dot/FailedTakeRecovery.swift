import DotCore
import Foundation

/// What a failed take still owes after its microphone went away.
///
/// A normal stop can leave up to two seconds of trailing audio to an existing
/// partial, because the key release explains that silence: the person stopped
/// speaking before the key came up. A failed take has no key release. The
/// microphone simply stopped, so the trailing audio may be speech cut
/// mid-word; recovery therefore keeps the speech tolerance of a quarter of a
/// second and sends the rest of the tail rather than trusting a partial that
/// stopped earlier.
///
/// The decision is pure so it can be tested without a recorder, a provider or
/// a window.
enum FailedTakeRecovery {
    /// The trailing audio, in 16 kHz samples, that recovery may leave to an
    /// existing partial.
    static let trailingTolerance = WAVSpec.sampleRate / 4

    /// The work the recovered take still owes.
    ///
    /// - Parameters:
    ///   - ledger: what the live loop had already transcribed.
    ///   - sampleCount: how many samples the failed take captured.
    /// - Returns: the stop plan a normal stop would produce for speech.
    static func plan(ledger: TranscriptLedger, sampleCount: Int) -> TranscriptLedger.StopPlan {
        ledger.stopPlan(sampleCount: sampleCount, trailingTolerance: trailingTolerance)
    }
}
