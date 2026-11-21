import DotCore
@testable import Dot
import XCTest

/// The post-analysis half of a live attempt must not call a provider after the
/// take has been cancelled while preparation was suspended.
@MainActor
final class LiveTranscriptionCancellationTests: XCTestCase {
    func testCancelledAttemptDoesNotReachTheProvider() async throws {
        let samples = MatrixProbeSpeech.samples(seconds: 10, seed: 11)
        let store = AudioSampleStore()
        _ = store.append(samples, from: store.currentGeneration)
        let prepared = await LiveTranscriptionAnalyzer.shared.prepare(
            ledger: TranscriptLedger(commitSeconds: 60),
            sampleCount: store.count,
            store: store,
            noiseFloorDBFS: -42
        )
        XCTAssertNotNil(prepared.request)

        var providerCalls = 0
        var resultText: String?
        let runner = LiveTranscriptionAttemptRunner(
            isCurrent: { false },
            transcribe: { _ in
                providerCalls += 1
                return "late transcript"
            },
            onResult: { text, _, _, _ in resultText = text }
        )

        let sent = await runner.run(prepared: prepared)

        XCTAssertFalse(sent)
        XCTAssertEqual(providerCalls, 0, "a cancelled take still reached the provider")
        XCTAssertNil(resultText, "a cancelled take still changed the ledger")
    }

    func testCurrentAttemptReachesTheProvider() async throws {
        let samples = MatrixProbeSpeech.samples(seconds: 10, seed: 11)
        let store = AudioSampleStore()
        _ = store.append(samples, from: store.currentGeneration)
        let prepared = await LiveTranscriptionAnalyzer.shared.prepare(
            ledger: TranscriptLedger(commitSeconds: 60),
            sampleCount: store.count,
            store: store,
            noiseFloorDBFS: -42
        )

        var providerCalls = 0
        let runner = LiveTranscriptionAttemptRunner(
            isCurrent: { true },
            transcribe: { _ in
                providerCalls += 1
                return "live transcript"
            },
            onResult: { _, _, _, _ in }
        )

        let sent = await runner.run(prepared: prepared)

        XCTAssertTrue(sent)
        XCTAssertEqual(providerCalls, 1)
    }
}
