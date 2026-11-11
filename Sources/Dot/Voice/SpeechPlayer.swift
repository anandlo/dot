import AVFoundation
import DotCore
import Foundation

/// Speaks an answer while the answer is still being written.
///
/// The product requirement is time to first audio, and it is won in two places.
/// The first is segmentation: the model's text is cut into sentences as it
/// arrives, so the first sentence is complete, and in flight to the vendor, long
/// before the answer is. The second is ordering: sentence two is synthesised
/// while sentence one is playing, its audio buffered until the head of the queue
/// has been scheduled. Both are done here, because both are about the queue and
/// not about any one vendor.
///
/// Playback itself belongs to ``SpeechEngine``: one lazily created
/// `AVAudioEngine` for output, separate from the microphone engine `Recorder`
/// owns. Nothing in this file touches the input node.
@MainActor
final class SpeechPlayer {
    /// How long the engine survives after the last buffer.
    static let idleTeardownSeconds: TimeInterval = 5
    /// How many sentences may be synthesised ahead of the one playing.
    static let lookahead = 2
    /// The most audio buffered for a sentence that is not playing yet.
    ///
    /// At 24 kHz mono that is about eleven seconds of speech, which is more than
    /// a sentence needs. The cap exists so a vendor that streams faster than
    /// realtime cannot turn a long answer into unbounded memory.
    static let maximumBufferedBytes = 512 * 1024

    /// One sentence in the queue.
    private struct Job {
        let id: Int
        let text: String
        var chunks: [VoiceChunk] = []
        var bufferedBytes = 0
        var started = false
        var finished = false
    }

    private let engine = SpeechEngine()
    private var segmenter = SentenceSegmenter()
    private var jobs: [Job] = []
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextJobID = 0
    private var turn = 0
    private var isStreamingText = false
    private var idleTask: Task<Void, Never>?
    private var provider: (any VoiceProvider)?
    private var settings: VoiceSettings?

    /// Called with the output level while speaking, `0...1`.
    var onLevel: ((Float) -> Void)? {
        didSet { forwardLevel() }
    }

    /// Called when a sentence could not be synthesised.
    var onFailure: ((Error) -> Void)?

    /// Called when the last queued sentence has been scheduled.
    var onFinish: (() -> Void)?

    /// Whether there is text or audio still to play.
    private(set) var isSpeaking = false

    /// Whether the output engine currently exists.
    var hasEngine: Bool { engine.hasEngine }

    /// How loud Dot's voice is, `0...1`.
    ///
    /// This is Dot's own gain, applied at the player node. Playback is mixed into
    /// the default output device like any other app's, so other audio keeps
    /// playing and nothing here changes the system volume. Recording is the one
    /// thing that must not run at the same time: the app calls ``stop()`` before
    /// it opens the microphone, which both silences Dot and stops Dot from
    /// hearing its own answer.
    var volume: Float {
        get { engine.volume }
        set { engine.volume = newValue }
    }

    init() {
        forwardLevel()
    }

    /// Starts a turn: the provider and voice the answer is spoken with.
    ///
    /// - Parameters:
    ///   - provider: the vendor that speaks.
    ///   - settings: the voice, model and speed.
    func begin(provider: any VoiceProvider, settings: VoiceSettings) {
        stop()
        turn += 1
        self.provider = provider
        self.settings = settings
        isStreamingText = true
        isSpeaking = true
    }

    /// Adds streamed answer text and speaks whatever sentences it completed.
    ///
    /// - Parameter delta: the text the model just produced.
    func feed(_ delta: String) {
        guard isStreamingText else { return }
        for sentence in segmenter.append(delta) {
            enqueue(sentence)
        }
    }

    /// Marks the end of the answer and speaks the tail.
    func finishText() {
        guard isStreamingText else { return }
        isStreamingText = false
        for sentence in segmenter.flush() {
            enqueue(sentence)
        }
        finishTurnIfIdle()
    }

    /// Speaks one complete piece of text, for a caller with no stream to feed.
    ///
    /// - Parameters:
    ///   - text: the answer.
    ///   - provider: the vendor that speaks.
    ///   - settings: the voice, model and speed.
    func speak(_ text: String, provider: any VoiceProvider, settings: VoiceSettings) {
        begin(provider: provider, settings: settings)
        feed(text)
        finishText()
    }

    /// Stops at once and forgets the rest of the answer.
    ///
    /// This is the barge-in path and the recording path: a key press during
    /// speech, or the microphone opening, must silence Dot in the same frame. The
    /// engine is paused rather than released so a follow-up answer can reuse it
    /// inside the idle window.
    func stop() {
        turn += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        jobs.removeAll()
        segmenter.reset()
        provider = nil
        settings = nil
        isStreamingText = false
        if isSpeaking || engine.hasEngine { engine.stop() }
        isSpeaking = false
        scheduleIdleTeardown()
    }

    /// Releases the output engine now.
    func teardown() {
        stop()
        idleTask?.cancel()
        idleTask = nil
        engine.teardown()
    }
}

// MARK: - The queue

extension SpeechPlayer {
    /// Adds one sentence to the queue and makes sure a synthesis is running.
    private func enqueue(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        jobs.append(Job(id: nextJobID, text: trimmed))
        nextJobID += 1
        startSyntheses()
    }

    /// Starts as many queued sentences as the lookahead allows.
    private func startSyntheses() {
        guard let provider, let settings else { return }
        var budget = Self.lookahead - tasks.count
        for job in jobs where !job.started && !job.finished {
            guard budget > 0 else { break }
            budget -= 1
            start(job, provider: provider, settings: settings)
        }
    }

    /// Synthesises one sentence and routes its audio.
    private func start(_ job: Job, provider: any VoiceProvider, settings: VoiceSettings) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index].started = true
        }
        let turn = self.turn
        tasks[job.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await provider.speech(text: job.text, settings: settings)
                for try await chunk in stream {
                    guard self.turn == turn else { return }
                    self.receive(chunk, for: job.id)
                }
                self.complete(job.id)
            } catch {
                guard self.turn == turn else { return }
                self.fail(job.id, error: error)
            }
        }
    }

    /// Takes one chunk from a sentence and schedules or buffers it.
    ///
    /// Only the head of the queue writes to the engine. A later sentence keeps
    /// its audio until the head has been fully scheduled, which is what makes
    /// concurrent synthesis safe: the player node's queue is the ordering
    /// authority and nothing may enqueue out of turn.
    private func receive(_ chunk: VoiceChunk, for id: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if index == 0 {
            schedule(chunk)
            return
        }
        guard jobs[index].bufferedBytes + chunk.data.count <= Self.maximumBufferedBytes else {
            return
        }
        jobs[index].chunks.append(chunk)
        jobs[index].bufferedBytes += chunk.data.count
    }

    /// Marks a sentence finished and moves the queue on.
    private func complete(_ id: Int) {
        tasks[id] = nil
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].finished = true
        advance()
    }

    /// Reports a failed sentence and keeps the rest of the answer going.
    private func fail(_ id: Int, error: Error) {
        tasks[id] = nil
        Log.shared.error("speech.sentence.failed", [
            "provider": .string(provider?.id ?? "none"),
            "detail": .string(error.localizedDescription),
        ])
        onFailure?(error)
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].finished = true
        jobs[index].chunks.removeAll()
        jobs[index].bufferedBytes = 0
        advance()
    }

    /// Schedules the buffered audio of the new head, then starts more work.
    ///
    /// A finished sentence leaves the queue only once its audio has been
    /// scheduled, and a sentence that arrives already synthesised (because it was
    /// synthesised ahead) is scheduled here. Scheduling never reorders: the
    /// player node hears sentence one, then sentence two, and nothing in between.
    private func advance() {
        while let head = jobs.first {
            if head.finished, head.chunks.isEmpty {
                jobs.removeFirst()
                continue
            }
            guard !head.chunks.isEmpty else { break }
            for chunk in head.chunks { schedule(chunk) }
            jobs[0].chunks.removeAll()
            jobs[0].bufferedBytes = 0
        }
        startSyntheses()
        finishTurnIfIdle()
    }

    /// Hands one chunk to the output engine.
    private func schedule(_ chunk: VoiceChunk) {
        do {
            try engine.enqueue(chunk)
        } catch {
            Log.shared.error("speech.playback.failed", ["detail": .string(error.localizedDescription)])
            onFailure?(error)
            stop()
        }
    }

    /// Ends the turn when nothing is left.
    private func finishTurnIfIdle() {
        guard !isStreamingText, jobs.isEmpty, tasks.isEmpty else { return }
        guard isSpeaking else { return }
        isSpeaking = false
        onFinish?()
        scheduleIdleTeardown()
    }

    /// Releases the engine after the idle window, unless something is playing.
    private func scheduleIdleTeardown() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTeardownSeconds))
            guard !Task.isCancelled, let self else { return }
            self.teardownIfIdle()
        }
    }

    private func teardownIfIdle() {
        guard !isSpeaking, jobs.isEmpty, tasks.isEmpty, isStreamingText == false else { return }
        idleTask = nil
        engine.teardown()
    }

    /// Passes the engine's level through to whoever draws a meter.
    private func forwardLevel() {
        engine.onLevel = { [weak self] level in
            self?.onLevel?(level)
        }
    }
}
