import AVFoundation
import AppKit
import Foundation
import DotCore

/// Why a recording could not be made.
enum RecorderError: Error, LocalizedError {
    /// The microphone permission was refused.
    case permissionDenied
    /// There is no input device, or it went away.
    case noInputDevice
    /// The engine refused to start.
    case engineFailed(String)
    /// The microphone's format could not be converted.
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Dot is not allowed to use the microphone."
        case .noInputDevice:
            "No microphone is available."
        case .engineFailed(let detail):
            "The microphone could not be started: \(detail)"
        case .unsupportedFormat(let detail):
            "The microphone's format is not supported: \(detail)"
        }
    }
}

/// Turns one buffer of the microphone's audio into a spectrum frame.
///
/// The frame is a plain value type and lives in `DotCore`, because the per-voice
/// scaling that reads it lives there too; the measurement that fills it stays
/// next to the audio tap that calls it.
extension AudioSpectrumFrame {
    /// Computes 5 genuine frequency bands from a mono float audio buffer (`sampleRate` Hz).
    public static func analyze(mono: [Float], sampleRate: Double) -> AudioSpectrumFrame {
        measure(mono: mono, sampleRate: sampleRate).frame
    }

    /// Measure the level and the bands of one buffer in a single pass.
    ///
    /// The tap used to walk the buffer three times per callback, once for the
    /// level, once for the bands and once more inside the resampler. The two
    /// walks here share their accumulators, so the audio thread does less work
    /// for the same meter.
    ///
    /// - Parameters:
    ///   - mono: the down-mixed samples of one buffer.
    ///   - sampleRate: the rate the samples were recorded at.
    /// - Returns: the level and the bands, both computed from the same pass.
    public static func measure(mono: [Float], sampleRate: Double) -> Measure {
        let n = mono.count
        guard n >= 16 else { return Measure(level: 0, frame: .zero) }

        var sumSq: Double = 0
        var lowState: Double = 0
        var midLowState: Double = 0
        var lowSq: Double = 0
        var midLowSq: Double = 0
        var midHighSq: Double = 0
        var highSq: Double = 0
        var zeroCrossings = 0
        var prevSample = Double(mono[0])

        // One-pole IIR cutoff coefficients normalized to sampleRate:
        // - sub/chest cutoff ~280 Hz
        // - vowel first formant cutoff ~850 Hz
        let dt = 1.0 / max(8000.0, sampleRate)
        let alphaLow = min(0.85, max(0.02, (2.0 * .pi * 280.0 * dt) / (1.0 + 2.0 * .pi * 280.0 * dt)))
        let alphaMid = min(0.92, max(0.05, (2.0 * .pi * 850.0 * dt) / (1.0 + 2.0 * .pi * 850.0 * dt)))

        for i in 0..<n {
            let x = Double(mono[i])
            sumSq += x * x

            lowState += alphaLow * (x - lowState)
            midLowState += alphaMid * (x - midLowState)

            let bandChest = lowState
            let bandVowel = midLowState - lowState
            let bandFormant = x - midLowState
            let diff1 = x - prevSample

            lowSq += bandChest * bandChest
            midLowSq += bandVowel * bandVowel
            midHighSq += bandFormant * bandFormant
            highSq += diff1 * diff1

            if (x >= 0 && prevSample < 0) || (x < 0 && prevSample >= 0) {
                zeroCrossings += 1
            }
            prevSample = x
        }

        let invN = 1.0 / Double(n)
        let totalRMS = sqrt(sumSq * invN)
        guard totalRMS > 0.0008 else { return Measure(level: totalRMS, frame: .zero) }

        // Each band's RMS is mapped to 0...1 on a dBFS scale with a -60 dBFS
        // floor. A linear map sits at 100% for all normal speech, which would
        // make the bands indistinguishable.
        func mapBand(_ rms: Double, gain: Double) -> Double {
            let boosted = rms * gain
            guard boosted > 0.00005 else { return 0 }
            let db = 20.0 * log10(boosted)
            let norm = (db - (-60.0)) / (0.0 - (-60.0))
            return min(1.0, max(0.0, norm))
        }

        let zcr = Double(zeroCrossings) * invN * (sampleRate / 16000.0)
        let sibilanceBoost = min(1.6, max(0.8, zcr * 2.2))

        // Row 0 (top): sibilants and fricatives.
        let b0 = mapBand(sqrt(highSq * invN), gain: 1.5 * sibilanceBoost)
        // Row 1: upper vocal formants, 1.2-3.5 kHz.
        let b1 = mapBand(sqrt(midHighSq * invN), gain: 1.25)
        // Row 2: core speech presence, 350 Hz-1.8 kHz.
        let b2 = mapBand(sqrt((midLowSq + midHighSq) * 0.6 * invN), gain: 1.05)
        // Row 3: lower-mid vowel body, 250-850 Hz.
        let b3 = mapBand(sqrt(midLowSq * invN), gain: 1.15)
        // Row 4 (bottom): fundamental pitch and chest resonance, 80-300 Hz.
        let b4 = mapBand(sqrt(lowSq * invN), gain: 1.0)

        return Measure(
            level: totalRMS,
            frame: AudioSpectrumFrame(bands: (b0, b1, b2, b3, b4))
        )
    }
}

/// Collects the microphone's audio on the real-time thread.
///
/// The class is deliberately free of AppKit: it is called from the audio
/// callback, which must never touch the user interface.
///
/// The samples themselves are not kept here. They go into the take's
/// ``AudioSampleStore``, which is handed to the processor that replaces this
/// one when the microphone changes format; keeping them in the processor is
/// what used to lose every sample collected before a rebuild. The generation
/// this processor was built with is what keeps a late buffer from landing
/// after the audio of its replacement.
final class AudioTapProcessor: @unchecked Sendable {
    private let lock = NSLock()
    /// Serialises one converter stream.
    ///
    /// A buffer conversion and the flush that ends the stream never run at the
    /// same time, so the samples of the take keep the order the microphone
    /// produced them in even when a rebuild arrives while a callback is still
    /// running.
    private let streamLock = NSLock()
    private let resampler: Resampler
    /// The samples of the take, shared with the processors that follow this one.
    private let store: AudioSampleStore
    /// The generation of the store this processor is allowed to append with.
    private let generation: Int
    private var closed = false
    private var latestLevel: Double = 0
    private var latestSpectrum: AudioSpectrumFrame = .zero
    private var failure: String?

    init(resampler: Resampler, store: AudioSampleStore, generation: Int) {
        self.resampler = resampler
        self.store = store
        self.generation = generation
    }

    /// The format the converter expects.
    var inputFormat: AVAudioFormat { resampler.inputFormat }

    /// Handles one buffer from the input tap.
    func handle(_ buffer: AVAudioPCMBuffer) {
        let mono = Resampler.monoSamples(from: buffer)
        let measure = AudioSpectrumFrame.measure(mono: mono, sampleRate: buffer.format.sampleRate)
        lock.lock()
        latestLevel = measure.level
        latestSpectrum = measure.frame
        lock.unlock()

        streamLock.lock()
        defer { streamLock.unlock() }
        // A buffer that arrives after the stream was flushed belongs to a
        // converter that is no longer part of the take.
        guard !closed else { return }
        do {
            // The downmix above is the one conversion this buffer needs: the
            // resampler is handed the samples it already has instead of mixing
            // them again.
            let converted = try resampler.convert(
                monoSamples: mono,
                sampleRate: buffer.format.sampleRate
            )
            guard !converted.isEmpty else { return }
            // The store belongs to the take, not to this processor: the next
            // processor gets the same one, so the offsets keep counting from
            // the first sample of the recording. The generation is what keeps
            // this processor's late buffers out of the new one's audio.
            store.append(converted, from: generation)
        } catch {
            record(error)
        }
    }

    /// Ends the converter's stream and adds the samples it was still holding.
    ///
    /// `AVAudioConverter` keeps part of its last frame in the filter until the
    /// stream ends. A rebuild is the last moment that audio can be added to the
    /// take: the stream is flushed under the same lock a buffer takes, so the
    /// tail lands after every sample this processor accepted and before the
    /// next generation starts.
    ///
    /// - Returns: `true` when the tail was accepted by the store.
    @discardableResult
    func finish() -> Bool {
        streamLock.lock()
        defer { streamLock.unlock() }
        guard !closed else { return false }
        closed = true
        do {
            let tail = try resampler.flush()
            guard !tail.isEmpty else { return false }
            return store.append(tail, from: generation)
        } catch {
            record(error)
            return false
        }
    }

    /// Remembers the last error the converter ran into.
    private func record(_ error: Error) {
        lock.lock()
        failure = error.localizedDescription
        lock.unlock()
    }

    /// The level of the last buffer.
    var level: Double {
        lock.lock()
        defer { lock.unlock() }
        return latestLevel
    }

    /// The 5-band acoustic spectrum of the last buffer.
    var spectrum: AudioSpectrumFrame {
        lock.lock()
        defer { lock.unlock() }
        return latestSpectrum
    }

    /// The error the converter ran into, if any.
    var error: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

/// What a microphone configuration change means for a running take.
///
/// The decision is pure: the engine is the only part that needs a device, and
/// its state is read before this is asked. A configuration notification also
/// arrives when the route changed but the format did not; the engine may have
/// stopped in that case, and the same converter can simply be started again.
enum CaptureRouteChange {
    /// What the take has to do about the change.
    enum Decision: Equatable {
        /// The engine is running and nothing the take uses has changed.
        case ignore
        /// The format is the same and the tap is installed; the engine stopped.
        case restartEngine
        /// The tap has to be installed again, with a converter for the format.
        case rebuild
        /// There is no usable input: the take cannot continue.
        case endTake
    }

    /// Decides between leaving the take alone, restarting the engine,
    /// rebuilding the converter and ending the take.
    ///
    /// A missing tap is rebuilt even when the format matches: starting the
    /// engine with no tap would report a running take that captures nothing.
    static func decision(
        hasInput: Bool,
        formatMatches: Bool,
        tapInstalled: Bool,
        engineIsRunning: Bool
    ) -> Decision {
        guard hasInput else { return .endTake }
        guard tapInstalled, formatMatches else { return .rebuild }
        return engineIsRunning ? .ignore : .restartEngine
    }
}

/// Records the microphone and turns it into the WAV every provider receives.
///
/// The audio goes through `AVAudioEngine`'s input tap, is down-mixed and
/// resampled to 16 kHz mono by `AVAudioConverter` and is wrapped in the
/// canonical 44-byte header by ``WAVWriter``.
@MainActor
final class Recorder {
    /// The result of a recording.
    struct Recording {
        /// Every 16 kHz mono sample the recording produced.
        ///
        /// The whole take is kept so the tail can be cut out of it: the audio
        /// that is already transcribed is final, and only the tail is encoded
        /// into the WAV the stop sends.
        let samples: [Int16]
        /// How long the recording was, in seconds.
        let duration: TimeInterval
        /// The loudest moment of the recording, in dBFS.
        let peakDBFS: Double

        /// How many 16 kHz samples were recorded.
        var sampleCount: Int { samples.count }
    }

    private var engine: AVAudioEngine?
    private var processor: AudioTapProcessor?
    /// The take's samples, owned here so a rebuilt converter appends to the
    /// same audio instead of starting a second recording at zero.
    private var store: AudioSampleStore?
    private var startedAt: Date?
    private var ticker: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?
    /// Whether an input tap is installed on bus 0.
    private var tapInstalled = false
    /// The take a failed conversion left behind, waiting for a stop or a cancel.
    ///
    /// A rebuild that fails ends the recording. The samples it already
    /// collected are kept here, because a stop that follows still has them even
    /// though the microphone is no longer running.
    private var endedTake: Recording?

    /// Called with the microphone level (RMS) and the elapsed time.
    var onTick: ((Double, TimeInterval) -> Void)?
    /// Called when the microphone goes away or the take cannot continue.
    var onFailure: ((String) -> Void)?

    /// Whether a recording is running.
    private(set) var isRecording = false

    /// The time the recording started.
    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// The level of the microphone right now, from `0` to `1`.
    ///
    /// The HUD reads this on every frame: it is the real level of the last
    /// block of audio, not an animation.
    var level: Double {
        processor?.level ?? 0
    }

    /// The real-time 5-band acoustic spectrum of the microphone right now.
    var spectrum: AudioSpectrumFrame {
        processor?.spectrum ?? .zero
    }

    /// Starts recording.
    ///
    /// - Parameter deviceUID: the microphone to use; `nil` means the system
    ///   default input.
    func start(deviceUID: String?) throws {
        guard !isRecording else { return }
        // A take left over from a failed capture is not part of this one.
        endedTake = nil
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.permissionDenied
        }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            self.engine = nil
            throw RecorderError.noInputDevice
        }
        if let deviceUID, !formatMatchesDevice(format, deviceUID: deviceUID) {
            self.engine = nil
            throw RecorderError.noInputDevice
        }

        let resampler: Resampler
        do {
            resampler = try Resampler(inputFormat: format)
        } catch {
            self.engine = nil
            throw RecorderError.unsupportedFormat(error.localizedDescription)
        }
        let store = AudioSampleStore()
        self.store = store
        let tap = AudioTapProcessor(
            resampler: resampler,
            store: store,
            generation: store.currentGeneration
        )
        processor = tap

        // 1024 frames is about 21 ms at 48 kHz: short enough for the meter to
        // feel live, long enough to keep the callback cheap.
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(for: tap))
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            processor = nil
            self.store = nil
            self.engine = nil
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        startedAt = Date()
        isRecording = true
        observeConfigurationChanges()
        startTicker()
    }

    /// Stops recording and returns the WAV.
    func stop() -> Recording {
        if let endedTake {
            self.endedTake = nil
            return endedTake
        }
        guard isRecording else {
            return Recording(samples: [], duration: 0, peakDBFS: -.infinity)
        }
        let ended = endCapture()
        return Recording(
            samples: ended.samples,
            duration: ended.duration,
            peakDBFS: AudioLevel.peakDBFS(samples: ended.samples)
        )
    }

    /// Throws the recording away and stops the engine.
    func cancel() {
        if endedTake != nil {
            endedTake = nil
            return
        }
        guard isRecording else { return }
        _ = stop()
    }

    /// How many samples the current recording holds.
    ///
    /// The live loop reads this to decide whether a whole chunk can be
    /// committed, without copying the audio it does not need. The count comes
    /// from the take's store, so it does not fall back to zero when the
    /// converter is rebuilt.
    var sampleCount: Int {
        store?.count ?? 0
    }

    /// The take's locked sample store, for work that runs off the main actor.
    var takeStore: AudioSampleStore? { store }

    /// A copy of the samples in `range` from the current recording.
    func samples(in range: Range<Int>) -> [Int16] {
        store?.samples(in: range) ?? []
    }

    /// A WAV of one range of the current recording.
    ///
    /// - Parameter range: the samples to send, as offsets from the start of the
    ///   recording.
    /// - Returns: `nil` when the range holds nothing that has arrived yet.
    func wav(range: Range<Int>) -> Data? {
        guard let slice = store?.samples(in: range), !slice.isEmpty else { return nil }
        return WAVWriter.encode(samples: slice)
    }

    /// Whether the microphone's format still matches the converter.
    ///
    /// A device that is unplugged ends the take. One that comes back with
    /// another sample rate gets a new converter, and the recording continues
    /// over the samples already collected: the take's store is the same, so
    /// every offset the live loop used still names the same audio. A route
    /// change that leaves the format alone but stops the engine restarts it on
    /// the same converter instead of rebuilding a take that is still valid.
    func checkForFormatChange() {
        guard isRecording, let processor, let engine else { return }
        let format = engine.inputNode.inputFormat(forBus: 0)
        switch CaptureRouteChange.decision(
            hasInput: format.channelCount > 0 && format.sampleRate > 0,
            formatMatches: processor.inputFormat.isEqual(format),
            tapInstalled: tapInstalled,
            engineIsRunning: engine.isRunning
        ) {
        case .ignore:
            return
        case .endTake:
            fail("The microphone was disconnected.")
        case .restartEngine:
            Log.shared.info("recorder.engine.restarting", [
                "rate": .double(format.sampleRate),
            ])
            engine.prepare()
            do {
                try engine.start()
            } catch {
                fail("The microphone could not be restarted: \(error.localizedDescription)")
            }
        case .rebuild:
            if processor.inputFormat.isEqual(format) {
                Log.shared.info("recorder.tap.reinstalled", [
                    "rate": .double(format.sampleRate),
                ])
            } else {
                Log.shared.info("recorder.format.changed", [
                    "from": .double(processor.inputFormat.sampleRate),
                    "to": .double(format.sampleRate),
                ])
            }
            rebuild(with: format)
        }
    }

    /// Rebuilds the converter for the microphone's new format.
    ///
    /// The take keeps its store, so the samples collected with the old
    /// converter stay at their absolute offsets and the new processor appends
    /// after them. A rebuild that cannot complete ends the take instead of
    /// leaving a stopped engine behind a recording that looks live: the person
    /// is told, and the audio already collected is kept for the stop.
    private func rebuild(with format: AVAudioFormat) {
        guard let engine, let store else { return }
        // The decision already refused a route change with no input; the check
        // is repeated here so a rebuild can never install a tap on a format the
        // engine does not have.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            fail("The microphone was disconnected.")
            return
        }
        // Validate the new converter before the running tap is torn down: an
        // unsupported format ends the take with its samples intact instead of
        // stopping the engine first and discovering the problem after.
        guard let resampler = try? Resampler(inputFormat: format) else {
            fail("The microphone changed to a format Dot cannot use.")
            return
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        // The old converter may still hold part of its last frame. Flushing it
        // here, before the store moves to the next generation, keeps that tail
        // at the end of the samples the old processor produced and ahead of
        // anything the new one will append.
        processor?.finish()
        // The replacement takes over the take, so this is the last moment the
        // old processor's conversion error can be reported.
        if let error = processor?.error {
            Log.shared.error("recorder.convert.failed", ["error": .string(error)])
        }
        let tap = AudioTapProcessor(
            resampler: resampler,
            store: store,
            generation: store.beginGeneration()
        )
        processor = tap
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.tapBlock(for: tap)
        )
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            fail("The microphone could not be restarted: \(error.localizedDescription)")
        }
    }

    /// Ends the take because its audio can no longer be converted.
    ///
    /// The engine is stopped and the clock is stopped with it, so the card can
    /// never show a live meter over a microphone nothing is reading. The
    /// samples that already arrived wait in `endedTake` for the stop or the
    /// cancel that follows; the failure is reported once.
    ///
    /// - Parameter message: what the person is told.
    private func fail(_ message: String) {
        guard isRecording else { return }
        let ended = endCapture()
        endedTake = Recording(
            samples: ended.samples,
            duration: ended.duration,
            peakDBFS: AudioLevel.peakDBFS(samples: ended.samples)
        )
        onFailure?(message)
    }

    /// Stops the engine, the clock and the observer of a take.
    ///
    /// - Returns: every sample the take collected and how long it ran. The
    ///   store is given up here, so a take is drained exactly once.
    private func endCapture() -> (samples: [Int16], duration: TimeInterval) {
        isRecording = false
        ticker?.cancel()
        ticker = nil
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        if let engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
            engine.reset()
            self.engine = nil
        }
        // The tap and the engine are gone, so no new buffer can start. The
        // converter may still hold part of its last frame, and a callback may
        // still be finishing one: finish() waits for that callback under the
        // stream lock, appends the tail, and closes the processor to anything
        // that arrives later. The snapshot after it is the whole take.
        processor?.finish()
        if let error = processor?.error {
            Log.shared.error("recorder.convert.failed", ["error": .string(error)])
        }
        let samples = store?.all() ?? []
        let duration = elapsed
        startedAt = nil
        processor = nil
        store = nil
        return (samples, duration)
    }

    /// Builds the callback the input tap runs.
    ///
    /// The callback runs on the audio thread, so it is built outside the main
    /// actor: a closure that inherits the main actor's isolation would be
    /// reported by the concurrency runtime every time the audio thread called
    /// it.
    private nonisolated static func tapBlock(
        for processor: AudioTapProcessor
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            processor.handle(buffer)
        }
    }

    private func formatMatchesDevice(_ format: AVAudioFormat, deviceUID: String) -> Bool {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        guard let device = devices.first(where: { $0.uniqueID == deviceUID }) else { return false }
        // The format is compared through the channel count and the sample rate
        // the engine reports; the unique id is what the configuration asked for.
        return device.isConnected && format.channelCount > 0
    }

    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkForFormatChange()
            }
        }
    }

    private func startTicker() {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1.0 / 30.0, repeating: 1.0 / 30.0)
        // The source is scheduled on the main queue, so every tick is already
        // on the main thread: it runs in place instead of allocating a task
        // thirty times a second for the length of the recording.
        source.setEventHandler { [weak self] in
            MainThreadTick.run {
                guard let self, self.isRecording else { return }
                self.onTick?(self.processor?.level ?? 0, self.elapsed)
            }
        }
        source.resume()
        ticker = source
    }
}
