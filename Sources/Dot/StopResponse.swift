import DotCore
import Foundation

/// What one take teaches the calibration book.
struct StopCalibrationLearning: Sendable {
    let observation: MicrophoneObservation
    let book: [String: MicrophoneCalibration]
    let at: Date
}

/// Measures a take off the main actor.
///
/// The samples are copied into the detached task at the capture cutoff. The
/// device UID and the book are values captured there too, so a suspension
/// cannot read a newer device or a newer setting. The function itself is
/// Swift 6.0 compatible; the host decides how to leave the main actor.
func stopCalibrationLearning(
    samples: [Int16],
    peakDBFS: Double,
    deviceUID: String?,
    book: [String: MicrophoneCalibration],
    at: Date
) -> StopCalibrationLearning? {
    guard let observation = MicrophoneCalibrationBook.observation(
        samples: samples,
        peakDBFS: peakDBFS
    ) else { return nil }
    return StopCalibrationLearning(
        observation: observation,
        book: MicrophoneCalibrationBook.folding(
            book,
            observation: observation,
            device: deviceUID,
            now: at
        ),
        at: at
    )
}

/// Where a stop result came from, for the host's logging policy.
enum StopDeliverySource {
    case complete
    case live
    case tail
    case fallback
}

/// Everything the one stop orchestration needs from its host.
///
/// The function below is the production path. AppDelegate supplies its real
/// HUD and effects; the test supplies the same function with an offscreen HUD,
/// synthetic audio and held dependencies. There is no second ordering model.
///
/// The take itself is not part of the handoff: a normal stop captures this on
/// the turn Stop is pressed, and the audio queue answers with the take later,
/// through the claim. ``perform(_:recording:)`` is the same orchestration for a
/// take that is already in hand.
@MainActor
struct StopHandoff {
    let hud: HUD
    let ledger: TranscriptLedger
    let liveTask: Task<Void, Never>?
    let capturedBook: [String: MicrophoneCalibration]
    let currentBook: () -> [String: MicrophoneCalibration]
    let isTerminating: () -> Bool
    let ownsCard: () -> Bool
    let enterWorking: () -> Void
    let markMenuNotRecording: () -> Void
    let clearLedger: () -> Void
    let finishEmpty: () -> Void
    let applyCalibration: ([String: MicrophoneCalibration], MicrophoneCalibration) -> Void
    let observe: (
        [Int16], Double, String?, [String: MicrophoneCalibration], Date
    ) async -> StopCalibrationLearning?
    let transcribe: ([Int16], String) async throws -> String
    /// Called with the take once the audio queue has drained it, before the card
    /// decides what the stop still owes. The app writes the take's final numbers
    /// here, where they are known.
    let drained: (Recorder.Recording) -> Void
    /// Called with the words, where they came from, and the number of samples the
    /// take held when it ended, for the log line that names the take.
    let deliver: (String, StopDeliverySource, Int) -> Void
    let abandon: () -> Void
    let fail: (Error) -> Void
}

/// The small, injectable part of a stop that decides when the card may move on.
@MainActor
enum StopResponse {
    /// Runs one stop whose take is already drained.
    ///
    /// The card leaves recording here, on the caller's turn of the main actor,
    /// exactly as it did before a stop could be claimed. A take with no samples
    /// is empty in this call and is answered before it returns, so a card that
    /// never has anything to transcribe never shows the transcribing state.
    @discardableResult
    static func perform(
        _ handoff: StopHandoff,
        recording: Recorder.Recording
    ) -> Task<Void, Never> {
        handoff.liveTask?.cancel()
        handoff.enterWorking()
        guard recording.sampleCount > 0 else {
            handoff.hud.showMessage(text: "Nothing was recorded.", action: nil)
            handoff.finishEmpty()
            return Task {}
        }
        announce(handoff)
        return Task { @MainActor in
            handoff.drained(recording)
            await finish(handoff, recording: recording)
        }
    }

    /// Runs one stop whose take is still on the audio queue.
    ///
    /// The card leaves recording here, on the caller's turn of the main actor,
    /// before the queue is awaited: a route reconciliation that was already
    /// running can hold the queue for as long as the device takes to restart,
    /// and the person must not see a live meter over a take that has ended.
    ///
    /// The samples the take had already published decide what the card leaves
    /// recording for. A take with audio is shown as transcribing now, once. A
    /// take with none waits for the drain, because the converter's flushed tail
    /// can still make it non-empty; a take that really is empty is answered with
    /// its message and never flashes the transcribing state.
    @discardableResult
    static func perform(
        _ handoff: StopHandoff,
        claim: Recorder.StopClaim
    ) -> Task<Void, Never> {
        handoff.liveTask?.cancel()
        handoff.enterWorking()
        // The take has ended, whatever the card is about to show: the menu may
        // not keep offering to stop a recording that no longer runs.
        handoff.markMenuNotRecording()
        let announced = claim.publishedSamples > 0
        if announced {
            handoff.hud.showTranscribing()
        } else {
            // The take is accepted and its audio is still on the queue, so the
            // card stops showing a live recording it can no longer read. It
            // claims nothing about the take: a take that turns out to be empty
            // must never show the transcribing state, and its audio may still be
            // in the converter. The card stays up until this stop replaces it,
            // so a drain held behind a device restart cannot outlive the
            // message's dwell and reopen the island afterwards.
            handoff.hud.showMessage(
                text: "Finishing recording…",
                symbol: "info.circle",
                dwell: 0
            )
        }
        return Task { @MainActor in
            guard case .drained(let recording) = await claim.result else { return }
            // The take's final numbers are known here, and they are written
            // whichever way the card decides below.
            handoff.drained(recording)
            guard mayContinue(handoff) else {
                drop(handoff)
                return
            }
            if !announced {
                guard recording.sampleCount > 0 else {
                    handoff.hud.showMessage(text: "Nothing was recorded.", action: nil)
                    handoff.finishEmpty()
                    return
                }
                handoff.hud.showTranscribing()
            }
            await finish(handoff, recording: recording)
        }
    }

    /// Shows that the take is being turned into words.
    ///
    /// Called once per stop: at the claim when the take already had audio, or
    /// when the drain answers for a take whose audio was still in the converter.
    private static func announce(_ handoff: StopHandoff) {
        handoff.hud.showTranscribing()
        handoff.markMenuNotRecording()
    }

    /// Whether the owner of the card may still touch it.
    private static func mayContinue(_ handoff: StopHandoff) -> Bool {
        canContinue(
            isTerminating: handoff.isTerminating(),
            isCancelled: Task.isCancelled,
            ownsCard: handoff.ownsCard()
        )
    }

    /// Lets go of a stop that may not touch the card any more.
    ///
    /// A cancelled or terminating stop cleans up only while it still owns the
    /// card. A newer owner must keep its own state.
    private static func drop(_ handoff: StopHandoff) {
        guard handoff.ownsCard(), handoff.isTerminating() || Task.isCancelled else { return }
        handoff.abandon()
    }

    /// The stop's work after the take is drained: what it still owes, and how
    /// the words get to the card.
    private static func finish(
        _ handoff: StopHandoff,
        recording: Recorder.Recording
    ) async {
        let samples = recording.sampleCount
        // The device the take's calibration belongs to. A take that ran on two
        // devices has no single microphone to teach.
        let deviceUID = AppDelegate.calibrationTarget(for: recording)
        guard mayContinue(handoff) else {
            drop(handoff)
            return
        }

        // A nil device has no entry in the book. The old learn path did
        // nothing in that case, so the scan is skipped entirely.
        if deviceUID != nil,
           let learning = await handoff.observe(
               recording.samples,
               recording.peakDBFS,
               deviceUID,
               handoff.capturedBook,
               Date()
           ) {
            guard mayContinue(handoff) else {
                drop(handoff)
                return
            }
            let currentBook = handoff.currentBook()
            if let finalBook = Self.calibrationBookAfterObservation(
                capturedBook: handoff.capturedBook,
                currentBook: currentBook,
                deviceUID: deviceUID,
                learning: learning
            ),
               finalBook != currentBook,
               let entry = MicrophoneCalibrationBook.calibration(
                   for: deviceUID,
                   in: finalBook
               ) {
                handoff.applyCalibration(finalBook, entry)
            }
        }

        guard mayContinue(handoff) else {
            drop(handoff)
            return
        }

        if let covered = Self.completeReuse(ledger: handoff.ledger, sampleCount: samples) {
            handoff.clearLedger()
            handoff.deliver(covered, .complete, samples)
            return
        }

        let lastTranscribed = handoff.ledger.provisional?.endSample
            ?? handoff.ledger.committedSamples
        let uncoveredCount = max(0, samples - lastTranscribed)
        let uncoveredHasSpeech = Self.uncoveredHasSpeech(
            in: recording.samples,
            uncoveredCount: uncoveredCount
        )

        // The display text join happens only in the branch that reuses it.
        if handoff.liveTask != nil, !uncoveredHasSpeech {
            let candidate = handoff.ledger.displayText
            if Self.shouldReuseLiveCandidate(
                liveTaskExists: true,
                uncoveredHasSpeech: uncoveredHasSpeech,
                candidate: candidate
            ) {
                handoff.clearLedger()
                handoff.deliver(candidate, .live, samples)
                return
            }
        }

        handoff.clearLedger()
        switch Self.tailPlan(
            ledger: handoff.ledger,
            sampleCount: samples,
            uncoveredHasSpeech: uncoveredHasSpeech
        ) {
        case .alreadyFinal(let text):
            handoff.deliver(text, .complete, samples)
        case .send(let range, let prefix):
            let piece = Array(recording.samples[range])
            do {
                let transcript = try await handoff.transcribe(piece, prefix)
                guard mayContinue(handoff) else {
                    drop(handoff)
                    return
                }
                handoff.deliver(transcript, .tail, samples)
            } catch is CancellationError {
                guard handoff.ownsCard() else { return }
                handoff.abandon()
            } catch {
                guard mayContinue(handoff) else {
                    drop(handoff)
                    return
                }
                let fallback = handoff.ledger.displayText
                if !fallback.isEmpty {
                    handoff.deliver(fallback, .fallback, samples)
                } else {
                    handoff.fail(error)
                }
            }
        }
    }

    /// Whether a live candidate may be promoted without waiting for its task.
    ///
    /// The live response guard refuses to touch the ledger once the state has
    /// left .recording, so a candidate captured at the cutoff is the last one
    /// that task could have produced.
    static func shouldReuseLiveCandidate(
        liveTaskExists: Bool,
        uncoveredHasSpeech: Bool,
        candidate: String?
    ) -> Bool {
        liveTaskExists && !uncoveredHasSpeech && !(candidate?.isEmpty ?? true)
    }

    /// Whether the owner of the card may still publish a result.
    static func canContinue(isTerminating: Bool, isCancelled: Bool, ownsCard: Bool) -> Bool {
        TranscriptionLifecycle.end(
            isTerminating: isTerminating,
            isCancelled: isCancelled
        ) == .deliver && ownsCard
    }

    /// Text that already covers every sample, so the stop owes no request.
    static func completeReuse(ledger: TranscriptLedger, sampleCount: Int) -> String? {
        guard case .alreadyFinal(let text) = ledger.stopPlan(sampleCount: sampleCount),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// Folds a take into the current book without undoing a reset.
    ///
    /// - Returns: `nil` when the device was reset while the observation ran.
    ///   Changes to other devices in the current book are kept in every other case.
    static func calibrationBookAfterObservation(
        capturedBook: [String: MicrophoneCalibration],
        currentBook: [String: MicrophoneCalibration],
        deviceUID: String?,
        learning: StopCalibrationLearning
    ) -> [String: MicrophoneCalibration]? {
        let capturedEntry = MicrophoneCalibrationBook.calibration(
            for: deviceUID,
            in: capturedBook
        )
        let currentEntry = MicrophoneCalibrationBook.calibration(
            for: deviceUID,
            in: currentBook
        )
        if capturedEntry != nil, currentEntry == nil { return nil }
        if currentBook == capturedBook { return learning.book }
        return MicrophoneCalibrationBook.folding(
            currentBook,
            observation: learning.observation,
            device: deviceUID,
            now: learning.at
        )
    }

    /// Whether the audio after the last live response contains speech.
    static func uncoveredHasSpeech(in samples: [Int16], uncoveredCount: Int) -> Bool {
        guard uncoveredCount > 0 else { return false }
        let start = max(0, samples.count - uncoveredCount)
        guard start < samples.count else { return false }
        let hop = 256
        let frames = uncoveredCount / hop
        guard frames > 0 else { return false }
        var maxRMS = 0.0
        for f in 0..<frames {
            var sumSq = 0.0
            let fStart = start + f * hop
            for i in fStart..<(fStart + hop) {
                let s = Double(samples[i]) / 32768.0
                sumSq += s * s
            }
            let rms = sqrt(sumSq / Double(hop))
            if rms > maxRMS { maxRMS = rms }
            if maxRMS > 0.015 { return true }
        }
        return false
    }

    /// The tail the stop still owes after live transcription.
    static func tailPlan(
        ledger: TranscriptLedger,
        sampleCount: Int,
        uncoveredHasSpeech: Bool
    ) -> TranscriptLedger.StopPlan {
        let tolerance = uncoveredHasSpeech ? WAVSpec.sampleRate / 4 : WAVSpec.sampleRate * 2
        return ledger.stopPlan(sampleCount: sampleCount, trailingTolerance: tolerance)
    }
}
