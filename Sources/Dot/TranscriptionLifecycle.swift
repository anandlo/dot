import Foundation

/// Whether a finished transcription may still reach the person.
///
/// A transcription task can end in two ways that are not a result: the app is
/// quitting, or the task was cancelled. Both have to clear the card instead of
/// leaving it on "transcribing", and neither may paste. The decision is pure,
/// so it is tested without a window, a provider or a microphone.
enum TranscriptionLifecycle {
    /// What to do with a transcript that just finished.
    enum End: Equatable {
        /// Deliver it: paste or copy, write history and show the card.
        case deliver
        /// Drop it and hide the card; nothing is pasted or written.
        case abandon
    }

    /// Decides whether a finished transcript may be delivered.
    ///
    /// - Parameters:
    ///   - isTerminating: the app is inside `applicationWillTerminate`.
    ///   - isCancelled: the task that produced the transcript was cancelled.
    /// - Returns: `.abandon` when either is true. A cancelled or quitting app
    ///   never pastes, and a task that ends without a result must not leave a
    ///   card that says it is still working.
    static func end(isTerminating: Bool, isCancelled: Bool) -> End {
        isTerminating || isCancelled ? .abandon : .deliver
    }
}
