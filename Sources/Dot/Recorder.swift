import AVFoundation
import AppKit
import Foundation
import DotCore

/// Why a recording could not be made.
enum RecorderError: Error, LocalizedError, Equatable {
    /// The microphone permission was refused.
    case permissionDenied
    /// There is no input device, or it went away.
    case noInputDevice
    /// The engine refused to start.
    case engineFailed(String)
    /// The microphone's format could not be converted.
    case unsupportedFormat(String)
    /// The take was taken back before the microphone opened.
    ///
    /// A stop or a cancel that arrives while the engine is starting reports
    /// this: the person already knows why the take is gone, so the message is
    /// never shown.
    case cancelled

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
        case .cancelled:
            "The recording was stopped before the microphone started."
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

/// The engine calls one take makes.
///
/// The recorder owns a small protocol rather than `AVAudioEngine` itself for two
/// reasons: the framework's class is not `Sendable`, and a take that has to be
/// measured must be runnable without a microphone. The real engine is a thin
/// wrapper around `AVAudioEngine`; a test supplies its own.
protocol CaptureEngine: AnyObject {
    /// The format the input node of bus 0 is running at.
    func inputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat
    /// Installs the recording callback on bus 0.
    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    )
    /// Removes the callback from bus 0.
    func removeTap(onBus bus: AVAudioNodeBus)
    /// Allocates and primes the render graph.
    func prepare()
    /// Opens the device and starts the input.
    func start() throws
    /// Stops the input.
    func stop()
    /// Clears the render graph.
    func reset()
    /// Whether the input is running.
    var isRunning: Bool { get }
    /// The UID of the device the input is running on, read from the audio unit.
    ///
    /// The engine is the only witness of what it opened, so this is the take's
    /// identity rather than the device the configuration or the cache expected.
    func currentDeviceUID() -> String?
}

/// The microphone, through `AVAudioEngine`.
///
/// The class is `@unchecked Sendable` because the engine it holds is only called
/// from ``CaptureSession``, which is confined to the recorder's audio control
/// queue: one take has one thread on its engine.
final class LiveCaptureEngine: CaptureEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()

    func inputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat {
        engine.inputNode.inputFormat(forBus: bus)
    }

    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        engine.inputNode.installTap(onBus: bus, bufferSize: bufferSize, format: format, block: block)
    }

    func removeTap(onBus bus: AVAudioNodeBus) {
        engine.inputNode.removeTap(onBus: bus)
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    func reset() {
        engine.reset()
    }

    var isRunning: Bool { engine.isRunning }

    func currentDeviceUID() -> String? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        return CoreAudioInput.deviceUID(of: unit)
    }
}

/// What a running take publishes for the card and the live loop.
///
/// The take's audio is owned by ``CaptureSession`` on the audio control queue,
/// while the card samples the meter on every frame and the live loop asks how
/// much audio has arrived, both from the main thread. This box is the hand-over:
/// the session installs the processor and the store once, and the reads below
/// take a lock. The processor's own level and spectrum are already lock
/// protected snapshots of the audio thread's work, so no audio state is shared.
final class CapturePublication: @unchecked Sendable {
    private let lock = NSLock()
    private var processor: AudioTapProcessor?
    private var store: AudioSampleStore?

    /// Installs or drops the take's audio. Called on the audio queue.
    func publish(processor: AudioTapProcessor?, store: AudioSampleStore?) {
        lock.lock()
        self.processor = processor
        self.store = store
        lock.unlock()
    }

    /// The level of the last block of audio.
    var level: Double {
        lock.lock()
        defer { lock.unlock() }
        return processor?.level ?? 0
    }

    /// The 5-band acoustic spectrum of the last block of audio.
    var spectrum: AudioSpectrumFrame {
        lock.lock()
        defer { lock.unlock() }
        return processor?.spectrum ?? .zero
    }

    /// The take's sample store, or `nil` when no take is running.
    var currentStore: AudioSampleStore? {
        lock.lock()
        defer { lock.unlock() }
        return store
    }

    /// How many samples the take holds.
    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return store?.count ?? 0
    }

    /// A copy of the samples in `range` of the take.
    func samples(in range: Range<Int>) -> [Int16] {
        lock.lock()
        let store = self.store
        lock.unlock()
        return store?.samples(in: range) ?? []
    }
}

/// The audio of one take, confined to the recorder's audio control queue.
///
/// Confinement: `open`, `reconcile` and `stopCapture` are called only from the
/// blocks ``Recorder`` runs on its serial `audioQueue`, so the engine, the
/// installed tap and the processor reference are touched by one thread at a
/// time. The two values that leave are published through
/// ``CapturePublication``, which answers under its own lock.
final class CaptureSession: @unchecked Sendable {
    /// What a route change found, so the recorder can report it on the main
    /// actor.
    enum RouteOutcome: Equatable {
        /// The engine is running and nothing the take uses has changed.
        case unchanged
        /// The engine was stopped and is running again on the same converter.
        case restarted(rate: Double)
        /// The tap was installed again for the same format.
        case reinstalled(rate: Double)
        /// The microphone changed rate and a new converter took over the take.
        case formatChanged(from: Double, to: Double)
        /// The take cannot continue.
        case ended(String)
    }

    /// The take's audio, after the engine stopped.
    struct StoppedCapture {
        /// Every 16 kHz sample the take collected.
        let samples: [Int16]
        /// Whether the take recorded on more than one device.
        let spanned: Bool
    }

    private let makeEngine: @Sendable () -> CaptureEngine
    private let readDeviceUID: @Sendable (CaptureEngine) -> String?
    private let publication: CapturePublication
    private var engine: CaptureEngine?
    private var processor: AudioTapProcessor?
    private var store: AudioSampleStore?
    /// Whether an input tap is installed on bus 0.
    private var tapInstalled = false
    /// The open this session is serving. Only touched on the audio queue.
    private(set) var generation = 0
    /// The device the engine reports it is running on, read after each start.
    ///
    /// It is the take's identity: what the engine opened, never what the
    /// configuration or the cache expected it to open.
    private(set) var openedDeviceUID: String?
    /// Whether the take has recorded on more than one device.
    ///
    /// It is decided here, where the audio is, at the one place every start goes
    /// through: by the time the app hears about a route change the audio may
    /// already have crossed the device, and a stop can land before that news.
    private(set) var spanned = false

    init(
        makeEngine: @escaping @Sendable () -> CaptureEngine,
        readDeviceUID: @escaping @Sendable (CaptureEngine) -> String?,
        publication: CapturePublication
    ) {
        self.makeEngine = makeEngine
        self.readDeviceUID = readDeviceUID
        self.publication = publication
    }

    /// Opens the engine, installs the tap and starts the input.
    ///
    /// - Parameters:
    ///   - deviceUID: the microphone the configuration names, or `nil`.
    ///   - matchesDevice: whether the system still lists that microphone, asked
    ///     with the format the engine reports.
    /// Each open takes the next generation, and an open that finds the previous
    /// one still running drains it first: a take that was taken back while its
    /// engine was opening leaves an engine behind, and nothing else can stop it
    /// once the reference is replaced here.
    ///
    /// - Returns: the generation this open was given, which is what a
    ///   cancellation has to name to be allowed to stop it.
    /// - Throws: ``RecorderError`` when the take cannot be opened.
    func open(
        deviceUID: String?,
        matchesDevice: (AVAudioFormat, String) -> Bool
    ) throws -> Int {
        generation += 1
        let mine = generation
        if engine != nil {
            // The open this replaces belonged to a take that is gone.
            _ = stopCapture()
        }
        let engine = makeEngine()
        self.engine = engine
        let format = engine.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            self.engine = nil
            throw RecorderError.noInputDevice
        }
        if let deviceUID, !matchesDevice(format, deviceUID) {
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
        publication.publish(processor: tap, store: store)

        // 1024 frames is about 21 ms at 48 kHz: short enough for the meter to
        // feel live, long enough to keep the callback cheap.
        engine.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.tapBlock(for: tap)
        )
        tapInstalled = true
        engine.prepare()
        do {
            try start(engine)
        } catch {
            engine.removeTap(onBus: 0)
            tapInstalled = false
            processor = nil
            self.store = nil
            self.engine = nil
            publication.publish(processor: nil, store: nil)
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        return mine
    }

    /// Starts the engine and reads the device it is running on.
    ///
    /// Every successful start goes through here, so the take's identity is never
    /// older than the engine: an open, a restart of an engine that a route change
    /// stopped, and a rebuild onto another format all read it again. The read is a
    /// property of the audio unit, not of the configuration, because the device can
    /// change while the take is running.
    private func start(_ engine: CaptureEngine) throws {
        try engine.start()
        let previous = openedDeviceUID
        let current = readDeviceUID(engine)
        // A take that already holds audio and is now on another device ran on
        // both. The comparison includes a device that became readable and one
        // that stopped being readable, because either means the take's audio came
        // from two answers.
        if let store, store.count > 0, current != previous {
            spanned = true
        }
        openedDeviceUID = current
    }

    /// Answers a microphone configuration change.
    ///
    /// The decision is ``CaptureRouteChange``'s; everything that needs the
    /// device is here. A build of the new converter that fails ends the take
    /// instead of leaving a stopped engine behind a recording that looks live.
    ///
    /// - Returns: what happened, for the recorder to log or to end the take on.
    func reconcile() -> RouteOutcome {
        guard let engine, let processor else { return .unchanged }
        let format = engine.inputFormat(forBus: 0)
        switch CaptureRouteChange.decision(
            hasInput: format.channelCount > 0 && format.sampleRate > 0,
            formatMatches: processor.inputFormat.isEqual(format),
            tapInstalled: tapInstalled,
            engineIsRunning: engine.isRunning
        ) {
        case .ignore:
            return .unchanged
        case .endTake:
            return .ended("The microphone was disconnected.")
        case .restartEngine:
            engine.prepare()
            do {
                try start(engine)
            } catch {
                return .ended("The microphone could not be restarted: \(error.localizedDescription)")
            }
            return .restarted(rate: format.sampleRate)
        case .rebuild:
            return rebuild(with: format, on: engine, replacing: processor)
        }
    }

    /// Rebuilds the converter for the microphone's new format.
    ///
    /// The take keeps its store, so the samples collected with the old
    /// converter stay at their absolute offsets and the new processor appends
    /// after them.
    private func rebuild(
        with format: AVAudioFormat,
        on engine: CaptureEngine,
        replacing processor: AudioTapProcessor
    ) -> RouteOutcome {
        guard let store else { return .unchanged }
        // The decision already refused a route change with no input; the check
        // is repeated here so a rebuild can never install a tap on a format the
        // engine does not have.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            return .ended("The microphone was disconnected.")
        }
        // Validate the new converter before the running tap is torn down: an
        // unsupported format ends the take with its samples intact instead of
        // stopping the engine first and discovering the problem after.
        guard let resampler = try? Resampler(inputFormat: format) else {
            return .ended("The microphone changed to a format Dot cannot use.")
        }
        let sameFormat = processor.inputFormat.isEqual(format)
        let previousRate = processor.inputFormat.sampleRate
        if tapInstalled {
            engine.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        // The old converter may still hold part of its last frame. Flushing it
        // here, before the store moves to the next generation, keeps that tail
        // at the end of the samples the old processor produced and ahead of
        // anything the new one will append.
        processor.finish()
        // The replacement takes over the take, so this is the last moment the
        // old processor's conversion error can be reported.
        if let error = processor.error {
            Log.shared.error("recorder.convert.failed", ["error": .string(error)])
        }
        let tap = AudioTapProcessor(
            resampler: resampler,
            store: store,
            generation: store.beginGeneration()
        )
        self.processor = tap
        publication.publish(processor: tap, store: store)
        engine.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.tapBlock(for: tap)
        )
        tapInstalled = true
        engine.prepare()
        do {
            try start(engine)
        } catch {
            return .ended("The microphone could not be restarted: \(error.localizedDescription)")
        }
        return sameFormat
            ? .reinstalled(rate: format.sampleRate)
            : .formatChanged(from: previousRate, to: format.sampleRate)
    }

    /// Stops the engine and hands over every sample the take collected.
    ///
    /// The tap and the engine go first, so no new buffer can start. The converter
    /// may still hold part of its last frame, and a callback may still be
    /// finishing one: `finish()` waits for that callback under the stream lock,
    /// appends the tail, and closes the processor to anything that arrives
    /// later. The snapshot after it is the whole take.
    func stopCapture() -> StoppedCapture {
        if let engine {
            if tapInstalled {
                engine.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
            engine.reset()
            self.engine = nil
        }
        processor?.finish()
        if let error = processor?.error {
            Log.shared.error("recorder.convert.failed", ["error": .string(error)])
        }
        let samples = store?.all() ?? []
        let spanned = self.spanned
        processor = nil
        store = nil
        openedDeviceUID = nil
        self.spanned = false
        publication.publish(processor: nil, store: nil)
        return StoppedCapture(samples: samples, spanned: spanned)
    }

    /// Stops the open whose generation is `expected`, if it is still the one this
    /// session serves.
    ///
    /// A take that was taken back while its engine was opening asks for this from
    /// the main thread, and the request can reach the queue after the next take
    /// has already opened. The generation is what keeps that late request from
    /// stopping the microphone of the take that replaced it.
    ///
    /// - Returns: the drained audio, or `nil` when the open had already been
    ///   replaced and nothing was touched.
    func stopCapture(generation expected: Int) -> StoppedCapture? {
        guard expected == generation else { return nil }
        return stopCapture()
    }

    /// What a take that has just opened found waiting for it.
    enum StartReadiness: Equatable {
        /// The engine is running on the format the device has now.
        case ready
        /// The take rebuilt or restarted before it was published.
        case reconciled(RouteOutcome)
        /// The device is gone or cannot be used.
        case unusable
    }

    /// Reconciles a take that has just opened, before it is published as running.
    ///
    /// Opening the engine is a question to the device, and the device can change
    /// inside that window: a headset that finishes connecting, a route the system
    /// switched, a sample rate that settled after the engine asked for one. The
    /// take settles once here, so the converter the first buffer lands in is the
    /// one the device is running. A configured microphone that is no longer
    /// listed ends the start instead of publishing a recording nothing feeds.
    ///
    /// - Parameters:
    ///   - deviceChanged: whether the system would record from a different device
    ///     than the one the open began for.
    ///   - deviceUID: the microphone the configuration names, or `nil`.
    ///   - matchesDevice: whether the system still lists that microphone.
    func reconcileForStart(
        deviceChanged: Bool,
        deviceUID: String?,
        matchesDevice: (AVAudioFormat, String) -> Bool
    ) -> StartReadiness {
        guard let engine, let processor else { return .unusable }
        let format = engine.inputFormat(forBus: 0)
        if let deviceUID, !matchesDevice(format, deviceUID) {
            return .unusable
        }
        guard format.channelCount > 0, format.sampleRate > 0 else { return .unusable }
        if deviceChanged {
            // The route moved to a device that happens to run the same format:
            // the tap is installed again, so the take starts on the device it
            // opened on rather than on the one that replaced it.
            let outcome = rebuild(with: format, on: engine, replacing: processor)
            if case .ended = outcome { return .unusable }
            return .reconciled(outcome)
        }
        guard !processor.inputFormat.isEqual(format) || !engine.isRunning || !tapInstalled else {
            return .ready
        }
        let outcome = reconcile()
        if case .ended = outcome { return .unusable }
        return .reconciled(outcome)
    }

    /// Builds the callback the input tap runs.
    ///
    /// The callback runs on the audio thread, so it is built outside any actor:
    /// a closure that inherited the main actor's isolation would be reported by
    /// the concurrency runtime every time the audio thread called it.
    private static func tapBlock(
        for processor: AudioTapProcessor
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            processor.handle(buffer)
        }
    }
}

/// Records the microphone and turns it into the WAV every provider receives.
///
/// The audio goes through `AVAudioEngine`'s input tap, is down-mixed and
/// resampled to 16 kHz mono by `AVAudioConverter` and is wrapped in the
/// canonical 44-byte header by ``WAVWriter``.
///
/// The class is `@MainActor` for its callers, but nothing in this file touches
/// the audio hardware on the main thread: opening the engine, installing the tap
/// and starting the input run on one private serial queue, and a start is
/// answered through a completion instead of a return value.
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
        /// Whether the take ran on more than one input device.
        ///
        /// A take that did carries the floor and the peak of two microphones at
        /// once, so it describes neither of them. The flag is decided on the
        /// audio queue, where the audio is, and travels with the take.
        var spannedDevices = false
        /// The device the take was running on when it stopped, when it is known.
        var deviceUID: String?

        /// How many 16 kHz samples were recorded.
        var sampleCount: Int { samples.count }
    }

    /// Where a take is in its life.
    enum State: Equatable {
        /// Nothing is open.
        case idle
        /// The audio queue is opening the engine.
        case starting
        /// The microphone is running.
        case recording
    }

    /// What a start cost, for the timing line the app writes once the card is up.
    struct StartTiming {
        /// How long the start waited for the audio queue, in milliseconds.
        let queueWaitMilliseconds: Int
        /// How long the engine took to open and run, in milliseconds.
        let engineMilliseconds: Int
    }

    /// What a start answers.
    ///
    /// The generation names the start it belongs to. A take that a stop took back
    /// can still be answering while the next take is opening, and the app may
    /// only act on the answer of the newest start.
    struct StartReport: Sendable {
        /// The start this answer belongs to.
        let generation: Int
        /// The microphone the take actually opened, or `nil` when it opened none.
        ///
        /// It is the take's identity: a start that fell back to the system
        /// default input because the device cache did not answer names the device
        /// it really opened, not the one the configuration asked for.
        let openedDeviceUID: String?
        /// How it went.
        let result: Result<Void, RecorderError>
    }

    /// What the recorder asks the system for.
    ///
    /// The engine is built through ``CaptureEngine`` so a test can measure a take
    /// without a microphone, and the permission question is injected with it for
    /// the same reason: a test binary has no microphone entitlement to answer
    /// with.
    struct Environment: Sendable {
        /// Builds the engine one take records with.
        var makeEngine: @Sendable () -> CaptureEngine
        /// Whether the app may use the microphone right now.
        var isAuthorized: @Sendable () -> Bool
        /// Hands a start's answer to the main actor.
        ///
        /// Every hop the recorder makes to the main actor goes through it: a
        /// start's answer and a route change's outcome. It is the seam a test
        /// uses to hold the gap between the audio queue finishing and the app
        /// hearing about it, because the ownership checks and the take's identity
        /// have to hold inside that gap. The app's own delivery is
        /// ``MainThreadTick``.
        var deliver: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
        /// Reads the device an opened engine is running on.
        ///
        /// The engine is the only witness of what it opened. A test supplies a
        /// reader whose answer is not the device the default lookup would name,
        /// which is what proves the take is labelled by the engine.
        var openedDeviceUID: @Sendable (CaptureEngine) -> String? = { $0.currentDeviceUID() }
        /// Writes a warning line. The app's own is ``Log``.
        var logWarning: @Sendable (String, [String: LogValue]) -> Void = {
            Log.shared.warn($0, $1)
        }

        /// The engine and the permission of the running app.
        static let live = Environment(
            makeEngine: { LiveCaptureEngine() },
            isAuthorized: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
            deliver: { MainThreadTick.run($0) }
        )
    }

    /// One question to the audio queue, and whether it was taken back.
    ///
    /// A stop or an Escape that arrives while the engine is opening cannot wait
    /// for the open to finish, so it leaves a mark here instead. The queued start
    /// reads it when it is done and takes its own take apart.
    private final class StartRequest: @unchecked Sendable {
        /// The start this request belongs to.
        let generation: Int
        private let lock = NSLock()
        private var abandoned = false

        init(generation: Int) {
            self.generation = generation
        }

        func abandon() {
            lock.lock()
            abandoned = true
            lock.unlock()
        }

        var isAbandoned: Bool {
            lock.lock()
            defer { lock.unlock() }
            return abandoned
        }
    }

    /// How long the start path waits for the device cache, off the main thread.
    private nonisolated static let catalogWaitSeconds: TimeInterval = 2

    private let environment: Environment
    /// The one queue every engine call runs on, in the order the calls arrive.
    private let audioQueue = DispatchQueue(
        label: "com.anandlo.dot.audio-control",
        qos: .userInitiated
    )
    /// The take's audio, owned by ``CaptureSession`` on `audioQueue`.
    private let publication: CapturePublication
    private let session: CaptureSession

    /// Where the take is in its life.
    private(set) var state: State = .idle
    /// The newest start the recorder accepted, so an answer can say which one it
    /// belongs to.
    private(set) var startGeneration = 0
    private var pendingStart: StartRequest?
    private var startedAt: Date?
    private var ticker: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?
    /// The start whose route the observer belongs to.
    private var observedGeneration: Int?
    /// Whether a route change arrived while the take was still starting.
    ///
    /// The take runs the rebuild path for it as soon as it is published. It is
    /// readable so a test can wait for the change to have been noted instead of
    /// sleeping.
    private(set) var pendingRouteCheck = false
    /// The take a failed conversion left behind, waiting for a stop or a cancel.
    ///
    /// A rebuild that fails ends the recording. The samples it already collected
    /// are kept here, because a stop that follows still has them even though the
    /// microphone is no longer running.
    private var endedTake: Recording?
    /// What the last successful start cost.
    private(set) var lastStartTiming: StartTiming?
    /// The device the running take is published on, so a route change that lands
    /// it elsewhere is reported once.
    private var publishedDeviceUID: String?


    /// Called with the microphone level (RMS) and the elapsed time.
    var onTick: ((Double, TimeInterval) -> Void)?
    /// Called when the microphone goes away or the take cannot continue.
    var onFailure: ((String) -> Void)?
    /// Called when the running take is on another device than it was published
    /// on, so the app files its calibration under the device recording now.
    var onDeviceChange: ((String?) -> Void)?

    init(environment: Environment = .live) {
        self.environment = environment
        let publication = CapturePublication()
        self.publication = publication
        self.session = CaptureSession(
            makeEngine: environment.makeEngine,
            readDeviceUID: environment.openedDeviceUID,
            publication: publication
        )
    }

    /// Whether a recording is running.
    var isRecording: Bool { state == .recording }

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
        publication.level
    }

    /// The real-time 5-band acoustic spectrum of the microphone right now.
    var spectrum: AudioSpectrumFrame {
        publication.spectrum
    }

    /// Starts recording.
    ///
    /// The permission question is answered here, because it is a system call and
    /// cheap; everything that opens the device runs on the audio queue, and the
    /// answer arrives on the main actor.
    ///
    /// - Parameters:
    ///   - deviceUID: the microphone to use; `nil` means the system default
    ///     input.
    ///   - completion: the answer, delivered on the main actor with the
    ///     generation of the start it belongs to. A start that a stop or a
    ///     cancel took back reports ``RecorderError/cancelled``.
    func start(
        deviceUID: String?,
        completion: @escaping @MainActor (StartReport) -> Void
    ) {
        // A take that is already open or opening is not started twice, and the
        // caller must not be left waiting for an answer that will never come.
        guard state == .idle else {
            completion(StartReport(
                generation: startGeneration,
                openedDeviceUID: nil,
                result: .failure(.cancelled)
            ))
            return
        }
        guard environment.isAuthorized() else {
            completion(StartReport(
                generation: startGeneration,
                openedDeviceUID: nil,
                result: .failure(.permissionDenied)
            ))
            return
        }
        // A take left over from a failed capture is not part of this one.
        endedTake = nil
        startGeneration += 1
        let generation = startGeneration
        let requestedAt = CACurrentMediaTime()
        let request = StartRequest(generation: generation)
        pendingStart = request
        state = .starting

        // The observer is installed before anything is opened, so a route change
        // that arrives while the take is being reconciled is not missed: it is
        // noted here and run once the take is published.
        observeConfigurationChanges(generation: generation)
        let session = self.session
        let deliver = environment.deliver
        let logWarning = environment.logWarning
        audioQueue.async { [weak self] in
            let queuedAt = CACurrentMediaTime()
            // The device cache is enumerated on its own queue. Waiting for it is
            // allowed here, off the main thread, and only here: a menu or a press
            // never blocks on the device list. A cache that does not answer in
            // time does not stop the recording; the take opens the system default
            // input and names the device it really opened.
            let requestedDeviceUID = deviceUID
            var deviceUID = deviceUID
            var waitedOut = false
            if MicrophoneCatalog.awaitSnapshot(timeout: Self.catalogWaitSeconds) == nil {
                deviceUID = nil
                waitedOut = true
            }
            // Which device would record is asked before the engine opens, so a
            // route that moves while it opens can be told apart from the device
            // the take was opened for.
            let plannedDeviceUID = MicrophoneCatalog.recordingDeviceUID(configured: deviceUID)
            var failure: RecorderError?
            var openGeneration: Int?
            do {
                openGeneration = try session.open(
                    deviceUID: deviceUID,
                    matchesDevice: Self.formatMatchesDevice
                )
            } catch {
                failure = (error as? RecorderError) ?? .engineFailed(error.localizedDescription)
            }
            // The generation is read once here: the answers below are handed to
            // closures that outlive this block, and a captured `var` is not
            // something a concurrent closure may read.
            let openedGeneration = openGeneration
            if failure == nil {
                // A device can change inside the window the engine takes to
                // open: a headset that finishes connecting, a route the system
                // switched, a sample rate that settled after the engine asked
                // for one. The take settles once here, so the converter the first
                // buffer lands in is the one the device is running.
                let movedDevice = MicrophoneCatalog.recordingDeviceUID(configured: deviceUID)
                    != plannedDeviceUID
                switch session.reconcileForStart(
                    deviceChanged: movedDevice,
                    deviceUID: deviceUID,
                    matchesDevice: Self.formatMatchesDevice
                ) {
                case .ready, .reconciled:
                    break
                case .unusable:
                    if let openedGeneration {
                        _ = session.stopCapture(generation: openedGeneration)
                    }
                    failure = .noInputDevice
                }
            }
            // The take's identity is the device the engine reports, read after it
            // started: the default input can have moved while it opened.
            let openedDeviceUID = session.openedDeviceUID
            if waitedOut {
                logWarning("catalog.wait.timeout", [
                    "seconds": .double(Self.catalogWaitSeconds),
                    "requested_device": .string(requestedDeviceUID ?? "system"),
                    "opened_device": .string(openedDeviceUID ?? "unknown"),
                ])
            }
            let engineMilliseconds = Int(((CACurrentMediaTime() - queuedAt) * 1000).rounded())
            let queueWait = Int(((queuedAt - requestedAt) * 1000).rounded())

            // A stop or an Escape that arrived while the engine was opening owns
            // the take now: its own open is drained, and the cancellation is what
            // the caller is waiting for.
            if request.isAbandoned {
                if let openedGeneration {
                    _ = session.stopCapture(generation: openedGeneration)
                }
                deliver { [weak self] in
                    guard let self else { return }
                    if self.pendingStart === request {
                        self.pendingStart = nil
                        self.state = .idle
                        self.removeConfigurationObserver(generation: generation)
                        self.pendingRouteCheck = false
                    }
                    completion(StartReport(
                        generation: generation,
                        openedDeviceUID: nil,
                        result: .failure(.cancelled)
                    ))
                }
                return
            }
            if let failure {
                deliver { [weak self] in
                    guard let self else { return }
                    // Only the newest start may put the recorder back to idle: an
                    // answer that has been replaced must not touch the take that
                    // replaced it.
                    if self.pendingStart === request {
                        self.pendingStart = nil
                        self.state = .idle
                        self.removeConfigurationObserver(generation: generation)
                        self.pendingRouteCheck = false
                    }
                    completion(StartReport(
                        generation: generation,
                        openedDeviceUID: nil,
                        result: .failure(failure)
                    ))
                }
                return
            }
            deliver { [weak self] in
                guard let self else { return }
                // The cancel may have landed between the check above and this
                // block, and the next start may already own the recorder. Only
                // this start's own open is drained, and only a start that is
                // still the newest one changes the recorder.
                let owned = self.pendingStart === request
                if owned { self.pendingStart = nil }
                guard owned, !request.isAbandoned else {
                    if owned {
                        self.removeConfigurationObserver(generation: generation)
                        self.pendingRouteCheck = false
                    }
                    self.audioQueue.async {
                        if let openedGeneration {
                            _ = session.stopCapture(generation: openedGeneration)
                        }
                    }
                    completion(StartReport(
                        generation: generation,
                        openedDeviceUID: nil,
                        result: .failure(.cancelled)
                    ))
                    return
                }
                self.startedAt = Date()
                self.state = .recording
                self.publishedDeviceUID = openedDeviceUID
                self.lastStartTiming = StartTiming(
                    queueWaitMilliseconds: queueWait,
                    engineMilliseconds: engineMilliseconds
                )
                self.startTicker()
                // A route change that arrived while the take was being
                // reconciled was noted rather than acted on: the take runs the
                // rebuild path now that it is published as recording.
                if self.pendingRouteCheck {
                    self.pendingRouteCheck = false
                    self.checkForFormatChange()
                }
                completion(StartReport(
                    generation: generation,
                    openedDeviceUID: openedDeviceUID,
                    result: .success(())
                ))
            }
        }
    }

    /// Stops recording and returns the WAV.
    func stop() -> Recording {
        if let endedTake {
            self.endedTake = nil
            return endedTake
        }
        switch state {
        case .idle:
            return Recording(samples: [], duration: 0, peakDBFS: -.infinity)
        case .starting:
            // Nothing was opened, so there is nothing to drain: the take is
            // taken back here and the queued start tears its engine down when it
            // finishes.
            abandonStart()
            return Recording(samples: [], duration: 0, peakDBFS: -.infinity)
        case .recording:
            let ended = endCapture()
            return Recording(
                samples: ended.samples,
                duration: ended.duration,
                peakDBFS: AudioLevel.peakDBFS(samples: ended.samples),
                spannedDevices: ended.spanned,
                deviceUID: ended.deviceUID
            )
        }
    }

    /// Throws the recording away and stops the engine.
    func cancel() {
        if endedTake != nil {
            endedTake = nil
            return
        }
        switch state {
        case .idle:
            return
        case .starting:
            abandonStart()
        case .recording:
            _ = stop()
        }
    }

    /// Takes back a start that has not opened the engine yet.
    ///
    /// Everything the start put in place goes with it: its route observer and the
    /// change it may have noted. A later answer for this start cannot take them
    /// from the start that replaced it, because both are matched by generation.
    private func abandonStart() {
        if let request = pendingStart {
            request.abandon()
            removeConfigurationObserver(generation: request.generation)
            pendingRouteCheck = false
        }
        pendingStart = nil
        state = .idle
    }

    /// How many samples the current recording holds.
    ///
    /// The live loop reads this to decide whether a whole chunk can be
    /// committed, without copying the audio it does not need. The count comes
    /// from the take's store, so it does not fall back to zero when the
    /// converter is rebuilt.
    var sampleCount: Int {
        publication.sampleCount
    }

    /// The take's locked sample store, for work that runs off the main actor.
    var takeStore: AudioSampleStore? { publication.currentStore }

    /// A copy of the samples in `range` from the current recording.
    func samples(in range: Range<Int>) -> [Int16] {
        publication.samples(in: range)
    }

    /// A WAV of one range of the current recording.
    ///
    /// - Parameter range: the samples to send, as offsets from the start of the
    ///   recording.
    /// - Returns: `nil` when the range holds nothing that has arrived yet.
    func wav(range: Range<Int>) -> Data? {
        let slice = publication.samples(in: range)
        guard !slice.isEmpty else { return nil }
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
    ///
    /// The engine is read on the audio queue, where nothing else may be holding
    /// it, and the outcome comes back to the main actor to be logged or to end
    /// the take.
    func checkForFormatChange() {
        guard state == .recording else { return }
        let session = self.session
        let deliver = environment.deliver
        audioQueue.async { [weak self] in
            let outcome = session.reconcile()
            let deviceUID = session.openedDeviceUID
            // The answer goes through the same delivery as a start's, so the one
            // seam covers every hop the recorder makes to the main actor.
            deliver { [weak self] in
                self?.apply(outcome, deviceUID: deviceUID)
            }
        }
    }

    /// Reports what a route change did, and ends the take when it could not
    /// continue.
    private func apply(_ outcome: CaptureSession.RouteOutcome, deviceUID: String?) {
        guard state == .recording else { return }
        // A rebuild can land the take on another device. The identity follows the
        // engine, so the app's calibration does too. Whether the take crossed
        // devices is not decided here: the audio queue decided it when it started
        // the engine again, and the take carries it out.
        if deviceUID != publishedDeviceUID {
            publishedDeviceUID = deviceUID
            onDeviceChange?(deviceUID)
        }
        switch outcome {
        case .unchanged:
            return
        case .restarted(let rate):
            Log.shared.info("recorder.engine.restarting", ["rate": .double(rate)])
        case .reinstalled(let rate):
            Log.shared.info("recorder.tap.reinstalled", ["rate": .double(rate)])
        case .formatChanged(let from, let to):
            Log.shared.info("recorder.format.changed", [
                "from": .double(from),
                "to": .double(to),
            ])
        case .ended(let message):
            fail(message)
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
            peakDBFS: AudioLevel.peakDBFS(samples: ended.samples),
            spannedDevices: ended.spanned,
            deviceUID: ended.deviceUID
        )
        onFailure?(message)
    }

    /// Stops the engine, the clock and the observer of a take.
    ///
    /// - Returns: every sample the take collected and how long it ran. The
    ///   store is given up here, so a take is drained exactly once.
    private func endCapture() -> (
        samples: [Int16],
        duration: TimeInterval,
        spanned: Bool,
        deviceUID: String?
    ) {
        // The take's identity is read before anything is cleared: it is what the
        // app files the take's calibration against.
        let deviceUID = publishedDeviceUID
        state = .idle
        ticker?.cancel()
        ticker = nil
        removeConfigurationObserver()
        pendingRouteCheck = false
        publishedDeviceUID = nil
        // The audio queue is serial and a start that had not finished was
        // abandoned, so the engine is not in the middle of anything: this block
        // runs after the last call that touched it.
        let stopped = audioQueue.sync { session.stopCapture() }
        let duration = elapsed
        startedAt = nil
        return (stopped.samples, duration, stopped.spanned, deviceUID)
    }

    /// Whether the configured microphone is still one the system lists.
    ///
    /// The answer comes from the catalog's cache, not from a discovery session:
    /// the device list is enumerated once, off the main thread, and the press
    /// only takes a lock. The format is checked where it always was, through the
    /// channel count the engine reports.
    nonisolated static func formatMatchesDevice(
        _ format: AVAudioFormat,
        deviceUID: String
    ) -> Bool {
        format.channelCount > 0 && MicrophoneCatalog.isConnected(deviceUID)
    }

    /// Watches the route for the start that is opening.
    ///
    /// - Parameter generation: the start this observer belongs to. A notification
    ///   that reaches an observer of an older start is ignored, because that take
    ///   no longer owns the microphone.
    private func observeConfigurationChanges(generation: Int) {
        removeConfigurationObserver()
        // A new take starts with no change noted: a flag left by the take before
        // it is not this take's to consume.
        pendingRouteCheck = false
        observedGeneration = generation
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainThreadTick.run { [weak self] in
                self?.noteConfigurationChange(for: generation)
            }
        }
    }

    /// How many route observers the recorder holds, 0 or 1.
    ///
    /// It is readable so a test can prove that a cancelled start leaves none
    /// behind.
    var routeObserverCount: Int { configurationObserver == nil ? 0 : 1 }

    /// Removes the observer of the route of the take.
    private func removeConfigurationObserver() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        observedGeneration = nil
    }

    /// Removes the observer only when it belongs to `generation`.
    ///
    /// A completion of an older start arrives after the next one has installed
    /// its own observer; the generation is what keeps it from taking that one
    /// away.
    private func removeConfigurationObserver(generation: Int) {
        guard observedGeneration == generation else { return }
        removeConfigurationObserver()
    }

    /// Notes a route change for the start that is opening, or acts on it once the
    /// take is recording.
    ///
    /// A change that arrives while the take is being reconciled is left to the
    /// take itself; one that arrives after that moment but before the take is
    /// published is run as soon as it is.
    private func noteConfigurationChange(for generation: Int) {
        guard generation == startGeneration else { return }
        if state == .recording {
            checkForFormatChange()
        } else if state == .starting {
            pendingRouteCheck = true
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
                self.onTick?(self.level, self.elapsed)
            }
        }
        source.resume()
        ticker = source
    }
}
