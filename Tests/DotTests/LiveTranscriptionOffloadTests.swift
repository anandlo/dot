import CryptoKit
import DotCore
@testable import Dot
import XCTest

/// The live loop's decision and WAV are checked against the algorithm it
/// replaced, on one recording fed in fixed increments. No provider is contacted:
/// the fake answer is a deterministic string per attempt.
@MainActor
final class LiveTranscriptionOffloadTests: XCTestCase {
    private struct Attempt: Equatable {
        let range: Range<Int>?
        let wavHash: String
        let ledgerState: String
        let isCommit: Bool
    }

    private struct Decision {
        let plan: TranscriptLedger.VADPlan?
        let range: Range<Int>?
        let isCommit: Bool
        let commitUpTo: Int
        let wav: Data?
    }

    func testPreparedWorkMatchesTheOriginalAlgorithmForOneRecording() async throws {
        let sampleCount = 12 * WAVSpec.sampleRate
        let samples = MatrixProbeSpeech.samples(seconds: 12, seed: 7)
        XCTAssertEqual(samples.count, sampleCount)

        let store = AudioSampleStore()
        let generation = store.currentGeneration
        let chunk = WAVSpec.sampleRate / 4
        let floor = -42.0

        var originalLedger = TranscriptLedger(commitSeconds: 10)
        var preparedLedger = TranscriptLedger(commitSeconds: 10)
        var originalAttempts: [Attempt] = []
        var preparedAttempts: [Attempt] = []
        var commits = 0
        var provisionals = 0

        for offset in stride(from: 0, to: sampleCount, by: chunk) {
            _ = store.append(Array(samples[offset..<min(offset + chunk, sampleCount)]), from: generation)

            let original = Self.originalDecision(
                ledger: originalLedger,
                sampleCount: store.count,
                store: store,
                floor: floor
            )
            let prepared = await LiveTranscriptionAnalyzer.shared.prepare(
                ledger: preparedLedger,
                sampleCount: store.count,
                store: store,
                noiseFloorDBFS: floor
            )

            XCTAssertEqual(prepared.plan, original.plan)
            XCTAssertEqual(prepared.request?.range, original.range)
            XCTAssertEqual(prepared.request?.isCommit ?? false, original.isCommit)
            XCTAssertEqual(prepared.request?.commitUpTo ?? 0, original.commitUpTo)
            if let preparedWAV = prepared.request?.wav, let originalWAV = original.wav {
                XCTAssertEqual(preparedWAV, originalWAV)
            } else {
                XCTAssertNil(prepared.request?.wav)
                XCTAssertNil(original.wav)
            }

            let answer = "words-\(offset / chunk)"
            if original.plan != nil, let range = original.range {
                if original.isCommit {
                    commits += 1
                    originalLedger.commit(
                        range: originalLedger.committedSamples..<original.commitUpTo,
                        text: answer
                    )
                    preparedLedger.commit(
                        range: preparedLedger.committedSamples..<original.commitUpTo,
                        text: answer
                    )
                } else {
                    provisionals += 1
                    originalLedger.recordProvisional(range: range, text: answer)
                    preparedLedger.recordProvisional(range: range, text: answer)
                }
            }

            originalAttempts.append(
                Attempt(
                    range: original.range,
                    wavHash: Self.sha256(original.wav ?? Data()),
                    ledgerState: Self.state(originalLedger),
                    isCommit: original.isCommit
                )
            )
            preparedAttempts.append(
                Attempt(
                    range: prepared.request?.range,
                    wavHash: Self.sha256(prepared.request?.wav ?? Data()),
                    ledgerState: Self.state(preparedLedger),
                    isCommit: prepared.request?.isCommit ?? false
                )
            )
        }

        XCTAssertGreaterThan(commits, 0, "the recording did not reach a commit")
        XCTAssertGreaterThan(provisionals, 0, "the recording did not reach a provisional")
        XCTAssertEqual(preparedAttempts, originalAttempts)
        XCTAssertEqual(preparedLedger, originalLedger)
        XCTAssertEqual(
            preparedLedger.stopPlan(sampleCount: sampleCount),
            originalLedger.stopPlan(sampleCount: sampleCount)
        )
    }

    /// The algorithm the live loop used before the work was moved: copy the
    /// open audio on the calling actor, ask the ledger, copy the request range
    /// again, trim and encode.
    private static func originalDecision(
        ledger: TranscriptLedger,
        sampleCount: Int,
        store: AudioSampleStore,
        floor: Double?
    ) -> Decision {
        let committed = ledger.committedSamples
        let openSamples = sampleCount > committed
            ? store.samples(in: committed..<sampleCount)
            : []
        guard let plan = ledger.evaluateVAD(in: openSamples) else {
            return Decision(plan: nil, range: nil, isCommit: false, commitUpTo: 0, wav: nil)
        }
        let range: Range<Int>
        let isCommit: Bool
        let commitUpTo: Int
        switch plan {
        case .sendSegment(let segRange, let upTo):
            range = segRange
            isCommit = true
            commitUpTo = upTo
        case .sendProvisional(let provRange):
            range = provRange
            isCommit = false
            commitUpTo = provRange.upperBound
        }
        let samples = store.samples(in: range)
        guard !samples.isEmpty else {
            return Decision(plan: plan, range: range, isCommit: isCommit, commitUpTo: commitUpTo, wav: nil)
        }
        let wav: Data
        if let floor {
            let trim = SilenceTrim.trim(samples, noiseFloorDBFS: floor)
            wav = trim.range == 0..<samples.count
                ? WAVWriter.encode(samples: samples)
                : WAVWriter.encode(samples: Array(samples[trim.range]))
        } else {
            wav = WAVWriter.encode(samples: samples)
        }
        return Decision(plan: plan, range: range, isCommit: isCommit, commitUpTo: commitUpTo, wav: wav)
    }

    private static func state(_ ledger: TranscriptLedger) -> String {
        "\(ledger.committedSamples)|\(ledger.displayText)|"
            + "\(ledger.provisional?.startSample ?? -1)|\(ledger.provisional?.endSample ?? -1)"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The same deterministic source the frame probes use, shared so the
/// differential test and the timing probe feed identical audio.
enum MatrixProbeSpeech {
    static func samples(seconds: Int, seed: UInt64) -> [Int16] {
        let rate = WAVSpec.sampleRate
        var state = seed
        func nextUnit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 12) % 1_000_000) / 500_000 - 1
        }
        var samples = [Int16]()
        samples.reserveCapacity(seconds * rate)
        for index in 0..<(seconds * rate) {
            let t = Double(index) / Double(rate)
            let phase = t.truncatingRemainder(dividingBy: 3)
            let syllable = 0.45 + 0.55 * (0.5 + 0.5 * sin(2 * Double.pi * 2.3 * t))
            let word = 0.2 + 0.8 * pow(max(0, sin(2 * Double.pi * 0.35 * t)), 0.6)
            let amplitude = phase > 2.4 ? 0.001 : 0.28 * syllable * word
            let value = amplitude * (nextUnit() * 0.75 + 0.25 * sin(2 * Double.pi * 150 * t))
            samples.append(Int16(max(-1, min(1, value)) * 32767))
        }
        return samples
    }
}
