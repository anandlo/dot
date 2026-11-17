import DotCore
import Foundation

/// The numbers behind one frame of the visualiser.
///
/// Every style reads its own moments of the envelope and its own bands of the
/// spectrum, so a frame carries as many different heights as the voice had
/// moments. What is left here is the one reading every style shares: a sample of
/// the history at an offset from the newest, which is a value rather than a
/// drawing so it can be tested.
enum VisualizerBars {
    /// The envelope sample `offset` ticks ago, `0` being the newest.
    ///
    /// - Parameters:
    ///   - history: the envelope, oldest first.
    ///   - offset: how many ticks back to read.
    /// - Returns: the sample, from `0` to `1`; `0` when it is off the history.
    static func sample(history: [Double], offsetFromNewest offset: Int) -> Double {
        let index = history.count - 1 - offset
        guard index >= 0, index < history.count else { return 0 }
        return min(1, max(0, history[index]))
    }
}
