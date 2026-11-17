import XCTest

@testable import DotCore

/// A provider that answers with whatever it is told to.
private final class ScriptedProvider: Provider, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Scripted"
    let maxSegmentSeconds: Int
    let answers: [Result<String, Error>]
    private(set) var requests: [Data] = []

    init(maxSegmentSeconds: Int = 30, answers: [Result<String, Error>]) {
        self.maxSegmentSeconds = maxSegmentSeconds
        self.answers = answers
    }

    func isAvailable() async -> Bool { true }

    func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
        requests.append(wav)
        let index = min(requests.count - 1, answers.count - 1)
        return try answers[index].get()
    }
}

private struct ScriptedError: Error, Equatable {
    let message: String
}

/// An async gate that a test opens when the request it is watching may finish.
///
/// Cancellation does not open it: a task parked here stays parked, which is what
/// lets a test cancel a take while its request is in flight and choose the
/// moment the answer comes back.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        guard !opened else {
            lock.unlock()
            return
        }
        opened = true
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in waiting { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// A provider that can hold one request open and counts what it was sent.
private final class GatedProvider: Provider, @unchecked Sendable {
    let id = "gated"
    let displayName = "Gated"

    private let answers: [Result<String, Error>]
    private let holdAt: Int
    private let gate: Gate
    private let lock = NSLock()
    private var sent = 0

    /// Creates a provider that holds the `holdAt`-th request (1-based) until
    /// `gate` opens; `0` holds nothing.
    init(answers: [Result<String, Error>], holdAt: Int = 0, gate: Gate = Gate()) {
        self.answers = answers
        self.holdAt = holdAt
        self.gate = gate
    }

    /// How many requests the provider has been handed.
    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func isAvailable() async -> Bool { true }

    func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
        let index = lock.withLock {
            sent += 1
            return sent
        }
        if index == holdAt { await gate.wait() }
        return try answers[min(index - 1, answers.count - 1)].get()
    }
}

/// Holds a take after it is created, so a synchronous callback running inside
/// it can cancel the task it is running on.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<TranscriptReport, Error>?

    func store(_ task: Task<TranscriptReport, Error>) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        lock.withLock { task?.cancel() }
    }
}

/// Records the progress callbacks a take makes.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ done: Int) {
        lock.withLock { values.append(done) }
    }

    var recorded: [Int] {
        lock.withLock { values }
    }
}

/// Records both numbers a progress callback announces: how many requests are
/// done, and how many the take will send in total.
private final class ProgressTotals: @unchecked Sendable {
    private let lock = NSLock()
    private var pairs: [(done: Int, total: Int)] = []

    func record(_ done: Int, _ total: Int) {
        lock.withLock { pairs.append((done: done, total: total)) }
    }

    var recorded: [(done: Int, total: Int)] {
        lock.withLock { pairs }
    }
}

final class SegmentsTests: XCTestCase {
    private func samples(seconds: Double) -> [Int16] {
        [Int16](repeating: 1_000, count: Int(seconds * Double(WAVSpec.sampleRate)))
    }

    /// Waits, for a bounded time, until the provider has been sent `count`
    /// requests.
    private func waitForRequests(_ provider: GatedProvider, _ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while provider.requests < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return provider.requests >= count
    }

    func testTheSegmentsAreThirtySecondsLongByDefault() {
        XCTAssertEqual(Segmenter.defaultSegmentSeconds, 30)
        XCTAssertEqual(Segmenter.sampleCount(seconds: 30), 480_000)
    }

    func testNinetyFiveSecondsBecomeFourSegments() {
        let pieces = Segmenter.segments(samples: samples(seconds: 95), seconds: 30)
        XCTAssertEqual(pieces.count, 4)
        XCTAssertEqual(pieces[0].count, 480_000)
        XCTAssertEqual(pieces[3].count, 95 * 16_000 - 3 * 480_000)
    }

    func testSeventySecondsBecomeThreeSegments() {
        let pieces = Segmenter.segments(samples: samples(seconds: 70), seconds: 30)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces[2].count, 70 * 16_000 - 2 * 480_000)
    }

    func testTheSegmentCountMatchesTheSegments() {
        // The count is what the card shows before the first request, so it has
        // to agree with what the transcriber actually sends.
        for seconds in [0.0, 0.5, 12.0, 12.1, 30.0, 30.1, 63.0, 163.9] {
            let input = samples(seconds: seconds)
            XCTAssertEqual(
                Segmenter.segmentCount(samples: input.count, seconds: 30),
                Segmenter.segments(samples: input, seconds: 30).count,
                "\(seconds) s"
            )
        }
        XCTAssertEqual(Segmenter.segmentCount(samples: 0, seconds: 30), 0)
        XCTAssertEqual(Segmenter.segmentCount(samples: 1, seconds: 30), 1)
    }

    func testTheSegmentsKeepEverySample() {
        let input = samples(seconds: 61)
        let pieces = Segmenter.segments(samples: input, seconds: 30)
        XCTAssertEqual(pieces.flatMap { $0 }.count, input.count)
    }

    func testASilentBufferIsStillSent() async throws {
        // There is no gate: a recording of silence reaches the provider.
        let provider = ScriptedProvider(answers: [.success("")])
        let silence = WAVWriter.encode(samples: [Int16](repeating: 0, count: 16_000))
        let report = try await Transcriber.transcribe(
            wav: silence,
            provider: provider,
            maxSegmentSeconds: 30
        )
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(report.total, 1)
        XCTAssertEqual(report.succeeded, 1)
    }

    func testAZeroSampleRecordingSendsNothing() async throws {
        let provider = ScriptedProvider(answers: [.success("never")])
        let report = try await Transcriber.transcribe(
            wav: WAVWriter.encode(samples: []),
            provider: provider,
            maxSegmentSeconds: 30
        )
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.total, 0)
    }

    func testALongRecordingIsSplitAndSentInOrder() async throws {
        let provider = ScriptedProvider(answers: [
            .success("first"), .success("second"), .success("third"),
        ])
        let report = try await Transcriber.transcribe(
            wav: WAVWriter.encode(samples: samples(seconds: 70)),
            provider: provider,
            maxSegmentSeconds: 30
        )
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertEqual(report.total, 3)
        XCTAssertEqual(report.succeeded, 3)
        XCTAssertEqual(report.text, "first second third")
        // Every request is a WAV of its own, at most thirty seconds long.
        for request in provider.requests {
            let info = try WAVWriter.parse(request)
            XCTAssertTrue(info.isCanonical)
            XCTAssertLessThanOrEqual(info.durationMilliseconds, 30_000)
        }
    }

    func testAFailingSegmentDoesNotDiscardTheOthers() async throws {
        let provider = ScriptedProvider(answers: [
            .success("one"),
            .failure(ScriptedError(message: "boom")),
            .success("three"),
            .success("four"),
        ])
        let report = try await Transcriber.transcribe(
            wav: WAVWriter.encode(samples: samples(seconds: 95)),
            provider: provider,
            maxSegmentSeconds: 30
        )
        XCTAssertEqual(report.total, 4)
        XCTAssertEqual(report.succeeded, 3)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.text, "one three four")
    }

    func testWhenEverySegmentFailsTheErrorIsThrown() async throws {
        let provider = ScriptedProvider(answers: [
            .failure(ScriptedError(message: "boom")),
        ])
        do {
            _ = try await Transcriber.transcribe(
                wav: WAVWriter.encode(samples: samples(seconds: 70)),
                provider: provider,
                maxSegmentSeconds: 30
            )
            XCTFail("the transcription should have failed")
        } catch let error as ScriptedError {
            XCTAssertEqual(error, ScriptedError(message: "boom"))
        }
    }

    func testTheSegmentSizeIsTheProvidersCapability() {
        // The size is a capability of the provider, not a hardcoded number.
        let provider = ScriptedProvider(maxSegmentSeconds: 12, answers: [.success("ok")])
        XCTAssertEqual(provider.maxSegmentSeconds, 12)
        let pieces = Segmenter.segments(samples: samples(seconds: 30), seconds: provider.maxSegmentSeconds)
        XCTAssertEqual(pieces.count, 3)
    }

    // MARK: - Cancellation

    func testCancellingBeforeTheFirstRequestSendsNothing() async throws {
        let audio = samples(seconds: 70)
        let provider = GatedProvider(answers: [.success("never")])
        let started = Gate()
        let task = Task {
            // Parked until the test has cancelled: whenever the take begins, it
            // begins with the cancellation already set.
            await started.wait()
            return try await Transcriber.transcribe(
                samples: audio,
                provider: provider,
                maxSegmentSeconds: 30
            )
        }
        task.cancel()
        started.open()
        do {
            _ = try await task.value
            XCTFail("a cancelled take returned a report")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("cancellation became \(error)")
        }
        XCTAssertEqual(provider.requests, 0, "a request was sent for a cancelled take")
    }

    func testCancellingWhileASegmentIsInFlightStopsTheRest() async throws {
        let audio = samples(seconds: 70) // three segments
        let gate = Gate()
        let provider = GatedProvider(
            answers: [.success("one"), .success("two"), .success("three")],
            holdAt: 1,
            gate: gate
        )
        let task = Task {
            try await Transcriber.transcribe(
                samples: audio,
                provider: provider,
                maxSegmentSeconds: 30
            )
        }
        let arrived = await waitForRequests(provider, 1)
        XCTAssertTrue(arrived, "the first request never reached the provider")
        task.cancel()
        gate.open()
        do {
            _ = try await task.value
            XCTFail("a cancelled take returned a report")
        } catch is CancellationError {
            // Expected: the answer that was already in flight does not make the
            // take a success, and the next two segments are never sent.
        } catch {
            XCTFail("cancellation became \(error)")
        }
        XCTAssertEqual(provider.requests, 1, "a segment was sent after cancellation")
    }

    func testAProvidersOwnCancellationIsAFailedSegment() async throws {
        // The caller never cancelled. A provider's own cancellation — either
        // form it can take — is one failed segment, and the rest of the
        // recording is still sent.
        let provider = ScriptedProvider(answers: [
            .success("one"),
            .failure(CancellationError()),
            .failure(URLError(.cancelled)),
            .success("four"),
        ])
        let report = try await Transcriber.transcribe(
            wav: WAVWriter.encode(samples: samples(seconds: 95)),
            provider: provider,
            maxSegmentSeconds: 30
        )
        XCTAssertEqual(provider.requests.count, 4, "the rest of the recording was dropped")
        XCTAssertEqual(report.total, 4)
        XCTAssertEqual(report.succeeded, 2)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(report.text, "one four")
    }

    func testEverySegmentCancelledByTheProviderIsNotCallerCancellation() async throws {
        // The caller never cancelled. Every segment failed because the provider
        // reported cancellation, which must not reach the caller as a
        // CancellationError: that is the caller's word for its own decision.
        let provider = ScriptedProvider(answers: [.failure(CancellationError())])
        do {
            _ = try await Transcriber.transcribe(
                wav: WAVWriter.encode(samples: samples(seconds: 70)),
                provider: provider,
                maxSegmentSeconds: 30
            )
            XCTFail("every segment failed and no error was thrown")
        } catch let failure as ProviderCancellationFailure {
            XCTAssertEqual(failure.provider, "Scripted")
            XCTAssertEqual(failure.segments, 3)
            XCTAssertEqual(
                failure.errorDescription,
                "Scripted reported a cancellation as the first failure; 3 segments were attempted."
            )
        } catch {
            XCTFail("the provider's cancellation surfaced as \(error)")
        }
        XCTAssertEqual(provider.requests.count, 3, "every segment should have been tried")
    }

    func testAFirstProviderCancellationWithDifferentLaterFailuresDoesNotOverclaim() async throws {
        // Only the first failure is a cancellation; the failures behind it are
        // ordinary. The wrapper names the first failure and the attempt count,
        // and must not say that every request was cancelled.
        let provider = ScriptedProvider(answers: [
            .failure(CancellationError()),
            .failure(ScriptedError(message: "boom")),
            .failure(ScriptedError(message: "later")),
        ])
        do {
            _ = try await Transcriber.transcribe(
                wav: WAVWriter.encode(samples: samples(seconds: 70)),
                provider: provider,
                maxSegmentSeconds: 30
            )
            XCTFail("nothing was transcribed and no error was thrown")
        } catch let failure as ProviderCancellationFailure {
            XCTAssertEqual(failure.provider, "Scripted")
            XCTAssertEqual(failure.segments, 3)
            XCTAssertEqual(
                failure.errorDescription,
                "Scripted reported a cancellation as the first failure; 3 segments were attempted."
            )
            XCTAssertFalse(
                failure.errorDescription?.contains("cancelled every") ?? true,
                "the message claimed every request was cancelled"
            )
        } catch {
            XCTFail("the first failure did not become the wrapper: \(error)")
        }
        XCTAssertEqual(provider.requests.count, 3, "every segment should have been tried")
    }

    func testCancellingInsideTheProgressCallbackStopsTheNextRequest() async throws {
        let audio = samples(seconds: 70) // three segments
        let gate = Gate()
        let provider = GatedProvider(
            answers: [.success("one"), .success("two"), .success("three")],
            holdAt: 1,
            gate: gate
        )
        let box = TaskBox()
        let log = ProgressLog()
        let task = Task {
            try await Transcriber.transcribe(
                samples: audio,
                provider: provider,
                maxSegmentSeconds: 30,
                progress: { done, _ in
                    log.record(done)
                    // The second callback runs after the first answer, so the
                    // handle is stored by then. Cancelling here must stop the
                    // request the callback is announcing.
                    if done == 2 { box.cancel() }
                }
            )
        }
        box.store(task)
        let arrived = await waitForRequests(provider, 1)
        XCTAssertTrue(arrived, "the first request never reached the provider")
        gate.open()
        do {
            _ = try await task.value
            XCTFail("a take cancelled from its progress callback returned a report")
        } catch is CancellationError {
            // Expected: the callback cancelled before the second request.
        } catch {
            XCTFail("cancellation became \(error)")
        }
        XCTAssertEqual(log.recorded, [1, 2])
        XCTAssertEqual(provider.requests, 1, "the announced request was sent")
    }

    func testACancelledTaskIgnoresAnOrdinaryErrorFromTheInFlightRequest() async throws {
        let audio = samples(seconds: 70) // three segments
        let gate = Gate()
        let provider = GatedProvider(
            answers: [
                .failure(ScriptedError(message: "boom")),
                .success("two"),
                .success("three"),
            ],
            holdAt: 1,
            gate: gate
        )
        let task = Task {
            try await Transcriber.transcribe(
                samples: audio,
                provider: provider,
                maxSegmentSeconds: 30
            )
        }
        let arrived = await waitForRequests(provider, 1)
        XCTAssertTrue(arrived, "the first request never reached the provider")
        task.cancel()
        gate.open()
        do {
            _ = try await task.value
            XCTFail("a cancelled take returned a report")
        } catch is CancellationError {
            // Expected: the caller's cancellation wins over what the in-flight
            // request reported.
        } catch {
            XCTFail("the in-flight error replaced the cancellation: \(error)")
        }
        XCTAssertEqual(provider.requests, 1, "a segment was sent after cancellation")
    }

    func testCancellationAfterTheLastAnswerIsNotASuccess() async throws {
        let audio = samples(seconds: 10) // one segment
        let gate = Gate()
        let provider = GatedProvider(answers: [.success("only")], holdAt: 1, gate: gate)
        let task = Task {
            try await Transcriber.transcribe(
                samples: audio,
                provider: provider,
                maxSegmentSeconds: 30
            )
        }
        let arrived = await waitForRequests(provider, 1)
        XCTAssertTrue(arrived, "the request never reached the provider")
        task.cancel()
        gate.open()
        do {
            _ = try await task.value
            XCTFail("a take cancelled before its return was reported as a success")
        } catch is CancellationError {
            // Expected: the last answer arrived, but the caller had cancelled.
        } catch {
            XCTFail("cancellation became \(error)")
        }
        XCTAssertEqual(provider.requests, 1)
    }

    // MARK: - Room tone

    /// A stretch of a square tone, whose frames all measure its amplitude.
    ///
    /// - Parameters:
    ///   - milliseconds: how long the stretch is.
    ///   - amplitude: the level in samples, positive.
    private func tone(milliseconds: Int, amplitude: Int16) -> [Int16] {
        (0..<(WAVSpec.sampleRate * milliseconds / 1000)).map {
            $0.isMultiple(of: 2) ? amplitude : -amplitude
        }
    }

    /// Room tone at -60 dBFS, then speech at -20 dBFS, then nothing.
    private func toneThenSpeech(leadMilliseconds: Int, speechMilliseconds: Int) -> [Int16] {
        tone(milliseconds: leadMilliseconds, amplitude: 33)
            + tone(milliseconds: speechMilliseconds, amplitude: 3_277)
    }

    func testTheRoomToneBeforeSpeechIsNotSent() async throws {
        // 800 ms of room tone before the first word. A chat-style model answers
        // that tone with a list number, so it must not reach the provider.
        let audio = toneThenSpeech(leadMilliseconds: 800, speechMilliseconds: 2_000)
        let provider = ScriptedProvider(answers: [.success("hello")])
        let report = try await Transcriber.transcribe(
            samples: audio,
            provider: provider,
            noiseFloorDBFS: -60,
            maxSegmentSeconds: 30
        )
        XCTAssertEqual(report.total, 1)
        XCTAssertEqual(provider.requests.count, 1)

        let sent = try WAVWriter.samples(in: provider.requests[0])
        XCTAssertLessThan(sent.count, audio.count, "the room tone was sent")
        // The cut is the lead-in minus the pre-roll kept in front of the word.
        XCTAssertEqual(
            Double(audio.count - sent.count) / Double(WAVSpec.sampleRate),
            0.65,
            accuracy: 0.05
        )
        // What is sent is the speech, unchanged.
        XCTAssertEqual(sent, Array(audio.suffix(sent.count)))
    }

    func testTheProgressCountsTheAudioThatIsSent() async throws {
        // 800 ms of tone then 2.5 s of speech: four one-second segments before
        // the trim, three after it.
        let audio = toneThenSpeech(leadMilliseconds: 800, speechMilliseconds: 2_500)
        XCTAssertEqual(Segmenter.segmentCount(samples: audio.count, seconds: 1), 4)
        let provider = ScriptedProvider(answers: [.success("ok")])
        let progress = ProgressTotals()
        _ = try await Transcriber.transcribe(
            samples: audio,
            provider: provider,
            noiseFloorDBFS: -60,
            maxSegmentSeconds: 1,
            progress: { done, total in progress.record(done, total) }
        )
        let sent = try provider.requests.map { try WAVWriter.samples(in: $0) }
        let sentSamples = sent.map(\.count).reduce(0, +)
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertEqual(progress.recorded.last?.done, provider.requests.count)
        XCTAssertEqual(
            progress.recorded.last?.total,
            Segmenter.segmentCount(samples: sentSamples, seconds: 1),
            "the card announced a count the audio does not have"
        )
    }

    func testWithoutAFloorTheAudioIsSentAsItArrived() async throws {
        // No calibration entry for the device is not a guess to make: the clip
        // is sent exactly as the recorder produced it.
        let audio = toneThenSpeech(leadMilliseconds: 800, speechMilliseconds: 2_000)
        let provider = ScriptedProvider(answers: [.success("hello")])
        _ = try await Transcriber.transcribe(
            samples: audio,
            provider: provider,
            maxSegmentSeconds: 30
        )
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests[0], WAVWriter.encode(samples: audio))
    }
}
