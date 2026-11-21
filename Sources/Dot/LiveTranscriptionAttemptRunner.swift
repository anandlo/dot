import Foundation

/// The work after one live preparation: check that the take is still current,
/// ask the provider once, and hand the answer back to the caller.
///
/// The check is made again after the provider answers, so a take that ended
/// while the request was in flight cannot change the card.
@MainActor
struct LiveTranscriptionAttemptRunner {
    var isCurrent: () -> Bool
    var transcribe: (Data) async throws -> String
    var onResult: (String, Bool, Range<Int>, Int) -> Void

    func run(prepared: LiveTranscriptionWork) async -> Bool {
        guard isCurrent() else { return false }
        guard prepared.plan != nil, let request = prepared.request else { return false }
        do {
            let text = try await transcribe(request.wav)
            guard isCurrent() else { return false }
            onResult(
                text.trimmingCharacters(in: .whitespacesAndNewlines),
                request.isCommit,
                request.range,
                request.commitUpTo
            )
            return true
        } catch {
            return false
        }
    }
}
