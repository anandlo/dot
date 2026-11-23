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
@MainActor
struct StopHandoff {
    let hud: HUD
    let recording: Recorder.Recording
    let ledger: TranscriptLedger
    let liveTask: Task<Void, Never>?
    let deviceUID: String?
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
    let deliver: (String, StopDeliverySource) -> Void
    let abandon: () -> Void
    let fail: (Error) -> Void
}

/// The small, injectable part of a stop that decides when the card may move on.
@MainActor
enum StopResponse {
    /// Runs one stop from the recorder cutoff to its final handoff.
    ///
    /// The ledger is a value captured by the caller. Nothing here reads the
    /// host's mutable ledger again, and the live candidate is joined only in
    /// the branch that can actually reuse it.
    @discardableResult
    static func perform(_ handoff: StopHandoff) -> Task<Void, Never> {
        handoff.liveTask?.cancel()
        handoff.enterWorking()
        guard handoff.recording.sampleCount > 0 else {
            handoff.hud.showMessage(text: "Nothing was recorded.", action: nil)
            handoff.finishEmpty()
            return Task {}
        }
        handoff.hud.showTranscribing()
        handoff.markMenuNotRecording()

        return Task { @MainActor in
            let ledger = handoff.ledger
            let samples = handoff.recording.sampleCount
            let terminate = { handoff.isTerminating() }
            let cancelled = { Task.isCancelled }
            let mayContinue = {
                Self.canContinue(
                    isTerminating: terminate(),
                    isCancelled: cancelled(),
                    ownsCard: handoff.ownsCard()
                )
            }
            let drop = {
                // A cancelled or terminating stop cleans up only while it still
                // owns the card. A newer owner must keep its own state.
                guard handoff.ownsCard(), terminate() || cancelled() else { return }
                handoff.abandon()
            }

            guard mayContinue() else {
                drop()
                return
            }

            // A nil device has no entry in the book. The old learn path did
            // nothing in that case, so the scan is skipped entirely.
            if handoff.deviceUID != nil,
               let learning = await handoff.observe(
                   handoff.recording.samples,
                   handoff.recording.peakDBFS,
                   handoff.deviceUID,
                   handoff.capturedBook,
                   Date()
               ) {
                guard mayContinue() else {
                    drop()
                    return
                }
                let currentBook = handoff.currentBook()
                if let finalBook = Self.calibrationBookAfterObservation(
                    capturedBook: handoff.capturedBook,
                    currentBook: currentBook,
                    deviceUID: handoff.deviceUID,
                    learning: learning
                ),
                   finalBook != currentBook,
                   let entry = MicrophoneCalibrationBook.calibration(
                       for: handoff.deviceUID,
                       in: finalBook
                   ) {
                    handoff.applyCalibration(finalBook, entry)
                }
            }

            guard mayContinue() else {
                drop()
                return
            }

            if let covered = Self.completeReuse(ledger: ledger, sampleCount: samples) {
                handoff.clearLedger()
                handoff.deliver(covered, .complete)
                return
            }

            let lastTranscribed = ledger.provisional?.endSample ?? ledger.committedSamples
            let uncoveredCount = max(0, samples - lastTranscribed)
            let uncoveredHasSpeech = Self.uncoveredHasSpeech(
                in: handoff.recording.samples,
                uncoveredCount: uncoveredCount
            )

            // The display text join happens only in the branch that reuses it.
            if handoff.liveTask != nil, !uncoveredHasSpeech {
                let candidate = ledger.displayText
                if Self.shouldReuseLiveCandidate(
                    liveTaskExists: true,
                    uncoveredHasSpeech: uncoveredHasSpeech,
                    candidate: candidate
                ) {
                    handoff.clearLedger()
                    handoff.deliver(candidate, .live)
                    return
                }
            }

            handoff.clearLedger()
            switch Self.tailPlan(
                ledger: ledger,
                sampleCount: samples,
                uncoveredHasSpeech: uncoveredHasSpeech
            ) {
            case .alreadyFinal(let text):
                handoff.deliver(text, .complete)
            case .send(let range, let prefix):
                let piece = Array(handoff.recording.samples[range])
                do {
                    let transcript = try await handoff.transcribe(piece, prefix)
                    guard mayContinue() else {
                        drop()
                        return
                    }
                    handoff.deliver(transcript, .tail)
                } catch is CancellationError {
                    guard handoff.ownsCard() else { return }
                    handoff.abandon()
                } catch {
                    guard mayContinue() else {
                        drop()
                        return
                    }
                    let fallback = ledger.displayText
                    if !fallback.isEmpty {
                        handoff.deliver(fallback, .fallback)
                    } else {
                        handoff.fail(error)
                    }
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
