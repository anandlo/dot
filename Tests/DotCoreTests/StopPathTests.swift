import XCTest

@testable import DotCore

/// What a recording costs, before and after the ledger.
///
/// The numbers this test prints are the ones the report quotes. They are
/// measured, not estimated: every request goes through a provider that counts
/// the samples it was handed and takes a real, injected latency, so the
/// wall-clock figure is the sum of the sequential round trips and nothing else.
final class StopPathTests: XCTestCase {
    /// A provider that answers like a service and remembers what it was sent.
    private final class CountingProvider: Provider, @unchecked Sendable {
        let id = "counting"
        let displayName = "Counting"
        let latency: TimeInterval
        private let lock = NSLock()
        private var frames: [Int] = []

        init(latency: TimeInterval = 0) {
            self.latency = latency
        }

        var calls: Int {
            lock.withLock { frames.count }
        }

        var audioSamples: Int {
            lock.withLock { frames.reduce(0, +) }
        }

        func isAvailable() async -> Bool { true }

        func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
            let count = (try? WAVWriter.parse(wav))?.frames ?? 0
            let index = lock.withLock {
                frames.append(count)
                return frames.count
            }
            if latency > 0 {
                try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
            }
            return "part \(index)"
        }
    }

    /// One simulated recording: the live requests and what the stop still owes.
    private struct Run {
        var liveRequests = 0
        var liveSamples = 0
        var stopRequests = 0
        var stopSamples = 0
        var stopSeconds: TimeInterval = 0
        var text = ""
    }

    private let rate = WAVSpec.sampleRate
    private let latency: TimeInterval = 0.03

    /// Audio of a given length. The content is only ever counted, so a cheap
    /// sawtooth keeps the fixture fast in a debug build.
    private func samples(seconds: Double) -> [Int16] {
        let count = Int(seconds * Double(rate))
        return (0..<count).map { index in
            Int16(truncatingIfNeeded: (index % 400) * 80 - 16_000)
        }
    }

    /// The loop as it was: a rolling twelve-second window every 1.4 s, then the
    /// whole recording in thirty-second segments.
    private func runBefore(
        samples: [Int16],
        provider: CountingProvider,
        live: Bool = false
    ) async throws -> Run {
        var run = Run()
        var elapsed = 1.0
        let duration = Double(samples.count) / Double(rate)
        while live, elapsed < duration {
            let window = Array(samples.suffix(12 * rate))
            _ = try await provider.transcribe(wav: WAVWriter.encode(samples: window), model: nil, language: nil)
            run.liveRequests += 1
            run.liveSamples += window.count
            elapsed += 1.4
        }
        let started = ProcessInfo.processInfo.systemUptime
        let report = try await Transcriber.transcribe(
            samples: samples,
            provider: provider,
            maxSegmentSeconds: 30
        )
        run.stopSeconds = ProcessInfo.processInfo.systemUptime - started
        run.stopRequests = report.total
        run.stopSamples = samples.count
        run.text = report.text
        return run
    }

    /// The loop as it is now: commit every twelve seconds, preview the tail.
    ///
    /// The fixture models the live loop's schedule — a whole chunk is committed
    /// as soon as one is open, and the tail is previewed after enough new audio
    /// — because what this file measures is the *stop*, and the stop's cost is
    /// decided by what the loop left committed.
    private func runAfter(samples: [Int16], provider: CountingProvider) async throws -> Run {
        var run = Run()
        var ledger = TranscriptLedger(commitSeconds: 12)
        let growth = Int(2.0 * Double(rate))
        // Audio arrives in 60 ms blocks; the loop ticks every 1.4 s.
        var arrived = 0
        var ticks = 1.4
        while arrived < samples.count {
            arrived = min(samples.count, arrived + rate * 6 / 100)
            let elapsed = Double(arrived) / Double(rate)
            guard elapsed >= ticks else { continue }
            ticks += 1.4
            let chunk = ledger.committedSamples..<(ledger.committedSamples + ledger.commitSamples)
            if arrived >= chunk.upperBound {
                _ = try await provider.transcribe(
                    wav: WAVWriter.encode(samples: Array(samples[chunk])),
                    model: nil,
                    language: nil
                )
                ledger.commit(range: chunk, text: "chunk \(ledger.committedText.count + 1)")
                run.liveRequests += 1
                run.liveSamples += chunk.count
            } else if arrived - (ledger.provisional?.endSample ?? ledger.committedSamples) >= growth {
                let range = ledger.committedSamples..<arrived
                _ = try await provider.transcribe(
                    wav: WAVWriter.encode(samples: Array(samples[range])),
                    model: nil,
                    language: nil
                )
                ledger.recordProvisional(range: range, text: "partial")
                run.liveRequests += 1
                run.liveSamples += range.count
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        switch ledger.stopPlan(sampleCount: samples.count) {
        case .alreadyFinal(let text):
            run.text = text
        case .send(let range, let prefix):
            let report = try await Transcriber.transcribe(
                samples: Array(samples[range]),
                provider: provider,
                maxSegmentSeconds: 30
            )
            run.stopRequests = report.total
            run.stopSamples = range.count
            run.text = TranscriptLedger.join([prefix, report.text])
        }
        run.stopSeconds = ProcessInfo.processInfo.systemUptime - started
        return run
    }

    func testTheStopOnlyPaysForTheAudioThatIsNotFinal() async throws {
        for seconds in [8.0, 32.6, 52.9, 163.9] {
            let audio = samples(seconds: seconds)
            let before = CountingProvider(latency: latency)
            let beforeRun = try await runBefore(samples: audio, provider: before)
            let after = CountingProvider(latency: latency)
            let afterRun = try await runAfter(samples: audio, provider: after)

            print(String(
                format: "STOP %5.1f s  before: %d request(s), %.1f s of audio, %.0f ms | after: %d request(s), %.1f s of audio, %.0f ms",
                seconds,
                beforeRun.stopRequests,
                Double(beforeRun.stopSamples) / Double(rate),
                beforeRun.stopSeconds * 1000,
                afterRun.stopRequests,
                Double(afterRun.stopSamples) / Double(rate),
                afterRun.stopSeconds * 1000
            ))

            // The stop never sends more than one chunk of audio.
            XCTAssertLessThanOrEqual(afterRun.stopSamples, 12 * rate, "a \(seconds) s recording")
            XCTAssertLessThanOrEqual(afterRun.stopRequests, 1, "a \(seconds) s recording")
            // It used to send the whole recording.
            XCTAssertEqual(beforeRun.stopSamples, audio.count)
            if seconds > 12 {
                // And for anything longer than one chunk the stop is materially
                // faster, because the chunks before the tail are already done.
                XCTAssertLessThan(afterRun.stopSeconds, beforeRun.stopSeconds)
                XCTAssertLessThan(afterRun.stopSamples, beforeRun.stopSamples)
            } else {
                // A recording shorter than one chunk is sent once either way.
                XCTAssertEqual(afterRun.stopRequests, 1)
            }
            XCTAssertFalse(afterRun.text.isEmpty)
        }
    }

    func testALongRecordingSendsTheSameAudioOnceDuringTheRecording() async throws {
        let audio = samples(seconds: 163.9)
        let before = CountingProvider()
        let beforeRun = try await runBefore(samples: audio, provider: before, live: true)
        let after = CountingProvider()
        let afterRun = try await runAfter(samples: audio, provider: after)

        print(String(
            format: "UPLOAD 164 s  before: %.1f s of audio in %d requests | after: %.1f s of audio in %d requests",
            Double(beforeRun.liveSamples) / Double(rate), beforeRun.liveRequests,
            Double(afterRun.liveSamples) / Double(rate), afterRun.liveRequests
        ))

        // The old loop re-sent the same twelve seconds on every tick: eight
        // times the length of the recording. The new one uploads every sample
        // once as a committed chunk, plus the open tail it previews, which is
        // the standing cost of a stateless endpoint and is bounded by the
        // preview window.
        XCTAssertGreaterThan(beforeRun.liveSamples, 6 * audio.count)
        XCTAssertLessThan(afterRun.liveSamples, 4 * audio.count)
    }

    func testAShortRecordingIsSentOnce() async throws {
        let audio = samples(seconds: 6)
        let provider = CountingProvider()
        let run = try await runAfter(samples: audio, provider: provider)

        // Six seconds never reach a twelve-second chunk, so nothing is final and
        // the stop sends the whole recording once. The live previews are extra
        // on top of that, and they are what the card shows while speaking.
        XCTAssertEqual(run.stopRequests, 1)
        XCTAssertEqual(run.stopSamples, audio.count)
        XCTAssertGreaterThan(run.liveRequests, 0)
    }

    func testWhatIsLeftAfterACommitIsAllTheStopSends() async throws {
        let audio = samples(seconds: 26)
        let provider = CountingProvider()
        let run = try await runAfter(samples: audio, provider: provider)

        // Two twelve-second chunks are final; the stop sends the fragment the
        // recording ended on, which is less than one tick of audio.
        XCTAssertEqual(run.stopRequests, 1)
        XCTAssertLessThanOrEqual(run.stopSamples, Int(2.0 * Double(rate)))
        XCTAssertGreaterThan(run.stopSamples, 0)
    }
}
