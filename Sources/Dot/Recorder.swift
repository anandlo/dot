import AVFoundation
import AppKit
import CoreAudio
import Foundation
import os
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
    private struct MetricsState: Sendable {
        var latestLevel: Double = 0
        var latestSpectrum: AudioSpectrumFrame = .zero
        var failure: String?
    }

    private struct StreamState {
        var closed = false
        var monoScratch: [Float] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: MetricsState())
    /// Serialises one converter stream.
    ///
    /// A buffer conversion and the flush that ends the stream never run at the
    /// same time, so the samples of the take keep the order the microphone
    /// produced them in even when a rebuild arrives while a callback is still
    /// running.
    private let streamLock = OSAllocatedUnfairLock(initialState: StreamState())
    private let resampler: Resampler
    /// The samples of the take, shared with the processors that follow this one.
    private let store: AudioSampleStore
    /// The generation of the store this processor is allowed to append with.
    private let generation: Int

    init(resampler: Resampler, store: AudioSampleStore, generation: Int) {
        self.resampler = resampler
        self.store = store
        self.generation = generation
    }

    /// The format the converter expects.
    var inputFormat: AVAudioFormat { resampler.inputFormat }

    /// Handles one buffer from the input tap.
    func handle(_ buffer: AVAudioPCMBuffer) {
        streamLock.withLockUnchecked { state in
            Resampler.copyMonoSamples(from: buffer, into: &state.monoScratch)
            let sampleRate = buffer.format.sampleRate
            let measure = AudioSpectrumFrame.measure(mono: state.monoScratch, sampleRate: sampleRate)
            lock.withLock { metrics in
                metrics.latestLevel = measure.level
                metrics.latestSpectrum = measure.frame
            }

            // A buffer that arrives after the stream was flushed belongs to a
            // converter that is no longer part of the take.
            guard !state.closed else { return }
            do {
                // The downmix above is the one conversion this buffer needs: the
                // resampler is handed the samples it already has instead of mixing
                // them again.
                let converted = try resampler.convert(
                    monoSamples: state.monoScratch,
                    sampleRate: sampleRate
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
        let tail = flushTail()
        guard !tail.isEmpty else { return false }
        return store.append(tail, from: generation)
    }

    /// Ends the converter stream and hands its tail to the caller.
    ///
    /// A gated candidate keeps its predecessor open until it is verified. At
    /// commit the predecessor's tail is appended to the accepted store first;
    /// at rejection the converter stays open for a later recovery instead of
    /// adding samples the take has not accepted.
    func flushTail() -> [Int16] {
        streamLock.withLockUnchecked { state in
            guard !state.closed else { return [] }
            state.closed = true
            do {
                return try resampler.flush()
            } catch {
                record(error)
                return []
            }
        }
    }

    /// Remembers the last error the converter ran into.
    private func record(_ error: Error) {
        let message = error.localizedDescription
        lock.withLock { $0.failure = message }
    }

    /// The level of the last buffer.
    var level: Double {
        lock.withLock { $0.latestLevel }
    }

    /// The 5-band acoustic spectrum of the last buffer.
    var spectrum: AudioSpectrumFrame {
        lock.withLock { $0.latestSpectrum }
    }

    /// The error the converter ran into, if any.
    var error: String? {
        lock.withLock { $0.failure }
    }
}

/// The hand-over from a candidate input to the take's accepted samples.
///
/// An explicit route cannot let frames into the take before its readback has
/// answered: the audio unit can start yielding audio before the device identity
/// is known. The gate holds a candidate converter until verification succeeds,
/// then flushes its samples into the accepted store in one lock. A rejected
/// candidate is fenced by advancing its store generation, so a callback already
/// in flight cannot land late frames in the recovered take.
private final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var target: AudioTapProcessor?
    /// Called inside the lock after a target was found for a buffer.
    ///
    /// Nil in the app. A test holds a callback here to prove the hand-over
    /// cannot close the processor whose buffer is already being admitted.
    let afterAdmission: (@Sendable () -> Void)?
    /// Called inside the lock after the admitted buffer was handled.
    ///
    /// Nil in the app. A test reads the publication at the end of the callback
    /// boundary, where a transiently published frame would still be visible.
    let afterHandle: (@Sendable () -> Void)?
    /// Called before the hand-over takes the gate lock.
    ///
    /// Nil in the app. A test pauses promotion itself and reads the take before
    /// the candidate's frames are appended.
    let beforePromotion: (@Sendable () -> Void)?

    init(
        target: AudioTapProcessor?,
        afterAdmission: (@Sendable () -> Void)? = nil,
        afterHandle: (@Sendable () -> Void)? = nil,
        beforePromotion: (@Sendable () -> Void)? = nil
    ) {
        self.target = target
        self.afterAdmission = afterAdmission
        self.afterHandle = afterHandle
        self.beforePromotion = beforePromotion
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        // The lock is held for the whole callback. Promotion clears the target
        // and flushes the candidate under this lock, so it cannot close a
        // processor whose buffer has already been admitted: a callback either
        // finishes before the hand-over or finds no target afterwards.
        lock.lock()
        defer { lock.unlock() }
        guard let target else { return }
        afterAdmission?()
        target.handle(buffer)
        afterHandle?()
    }

    /// Fences callbacks while the engine is being stopped or re-opened.
    func suspend() {
        lock.lock()
        target = nil
        lock.unlock()
    }

    func accept(
        _ accepted: AudioTapProcessor,
        from pending: AudioTapProcessor?,
        pendingStore: AudioSampleStore?,
        into store: AudioSampleStore
    ) {
        beforePromotion?()
        lock.lock()
        target = nil
        pending?.finish()
        if let pendingStore {
            // The tail is now in the candidate store. Advancing its generation
            // drops any callback that was already in flight when the swap began.
            _ = pendingStore.beginGeneration()
            store.append(contentsOf: pendingStore.all())
        }
        target = accepted
        lock.unlock()
    }

    func discard(pending: AudioTapProcessor?, pendingStore: AudioSampleStore?) {
        lock.lock()
        target = nil
        _ = pendingStore?.beginGeneration()
        lock.unlock()
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
    /// Points the input at the device with this UID.
    ///
    /// Must be called before `inputFormat(forBus:)`, because changing the device
    /// changes the format the input node reports.
    func selectInputDevice(uid: String) throws
    /// The object a real configuration notification names for this engine.
    ///
    /// A fixture supplies its own identity so route events can be addressed to
    /// one engine without waking another take's observer.
    var configurationIdentity: AnyObject? { get }
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

    var configurationIdentity: AnyObject? { engine }

    func selectInputDevice(uid: String) throws {
        guard let desired = CoreAudioInput.deviceID(forUID: uid),
              let unit = engine.inputNode.audioUnit else {
            throw RecorderError.noInputDevice
        }
        // A unit already on the requested device needs no write. The UID readback
        // still has to agree: an unreadable unit is not a known selection.
        if let current = CoreAudioInput.currentDeviceID(of: unit), current == desired {
            guard CoreAudioInput.deviceUID(of: unit) == uid else {
                throw RecorderError.noInputDevice
            }
            return
        }
        // Changing CurrentDevice on a running unit is not a supported operation.
        // The caller stops the engine and preserves the accepted converter tail
        // before it asks for a different device.
        guard !engine.isRunning else { throw RecorderError.noInputDevice }
        var deviceID = desired
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            size
        ) == noErr else { throw RecorderError.noInputDevice }
        guard CoreAudioInput.currentDeviceID(of: unit) == desired,
              CoreAudioInput.deviceUID(of: unit) == uid else {
            throw RecorderError.noInputDevice
        }
    }

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
    /// The candidate converter of a start whose identity is still unverified.
    private struct Admission {
        let gate: FrameGate
        let candidate: AudioTapProcessor
        let pending: AudioTapProcessor?
        let pendingStore: AudioSampleStore?
    }

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
        /// A candidate input was stopped and rejected; the accepted take waits
        /// for the route to recover, with its samples and identity intact.
        case rejected
        /// The take cannot continue.
        case ended(String)
    }

    /// The take's audio, after the engine stopped.
    struct StoppedCapture {
        /// Every 16 kHz sample the take collected.
        let samples: [Int16]
        /// Whether the take recorded on more than one device.
        let spanned: Bool
        let deviceUID: String?
    }

    private let makeEngine: @Sendable () -> CaptureEngine
    private let readDeviceUID: @Sendable (CaptureEngine) -> String?
    private let now: @Sendable () -> TimeInterval
    private let publication: CapturePublication
    private var engine: CaptureEngine?
    private var processor: AudioTapProcessor?
    private var store: AudioSampleStore?
    private var gate: FrameGate?
    private var admission: Admission?
    /// The microphone this take was asked to open, or `nil` for the system
    /// default. Kept for the life of the take so a restart or a rebuild opens the
    /// same device again.
    private var requestedDeviceUID: String?
    /// What the engine reported when it opened a device other than the one asked
    /// for. The recorder turns this into a failed start and a warning.
    private(set) var deviceMismatch: (requested: String, opened: String)?
    /// Whether an input tap is installed on bus 0.
    private var tapInstalled = false
    /// The open this session is serving. Only touched on the audio queue.
    private(set) var generation = 0
    /// The device the engine reports it is running on, read after each start.
    ///
    /// It is the take's identity: what the engine opened, never what the
    /// configuration or the cache expected it to open.
    private(set) var openedDeviceUID: String?
    /// The last device whose frames were admitted to the take.
    ///
    /// A rejected restart keeps this value: a later route event recovers toward
    /// the identity the accepted samples were recorded on, not the device of a
    /// candidate that was stopped before verification.
    private(set) var acceptedDeviceUID: String?
    /// Whether the current input was rejected and the take is waiting to recover.
    private(set) var inputRejected = false
    /// How many rejection episodes this take has had.
    ///
    /// Only the queue increments it, when the input goes from accepted to
    /// rejected. A repeated rejection of the same episode keeps the number it
    /// was given, so the one deadline of that episode is never reset.
    private var rejectionEpisodes = 0
    /// The rejection episode the take is waiting in, or `nil` when it recovered.
    ///
    /// It is the deadline's identity: a deadline armed for an older episode
    /// cannot end the episode that runs now, even when both are rejected.
    private(set) var rejectionEpisode: Int?
    /// When the live rejection episode began, on the same clock the deadline
    /// is measured with.
    ///
    /// The episode gets its two seconds from this instant, not from the moment
    /// a held answer reaches the main actor and asks for the deadline.
    private(set) var rejectionStartedAt: TimeInterval?
    /// Whether the take has recorded on more than one device.
    ///
    /// It is decided here, where the audio is, at the one place every start goes
    /// through: by the time the app hears about a route change the audio may
    /// already have crossed the device, and a stop can land before that news.
    private(set) var spanned = false
    /// The result of the last terminal stop of this session.
    ///
    /// A stop already performed on the audio queue is the take's audio. A
    /// second caller that arrives before the next open, such as a claimed stop
    /// that lands after a recovery deadline cut the take off, gets the same
    /// result instead of an empty take.
    private var lastStoppedCapture: StoppedCapture?
    /// How many reconciliation passes this session has run.
    ///
    /// Read by a test to prove a foreign notification never reached the audio
    /// queue. The counter is lock protected because it is written on the queue
    /// and read from the main actor.
    private let reconcilePassLock = NSLock()
    private var reconcilePasses = 0

    var reconcilePassCount: Int {
        reconcilePassLock.lock()
        defer { reconcilePassLock.unlock() }
        return reconcilePasses
    }

    private let afterAdmission: (@Sendable () -> Void)?
    private let afterHandle: (@Sendable () -> Void)?
    private let beforePromotion: (@Sendable () -> Void)?

    init(
        makeEngine: @escaping @Sendable () -> CaptureEngine,
        readDeviceUID: @escaping @Sendable (CaptureEngine) -> String?,
        now: @escaping @Sendable () -> TimeInterval = { CACurrentMediaTime() },
        publication: CapturePublication,
        afterAdmission: (@Sendable () -> Void)? = nil,
        afterHandle: (@Sendable () -> Void)? = nil,
        beforePromotion: (@Sendable () -> Void)? = nil
    ) {
        self.makeEngine = makeEngine
        self.readDeviceUID = readDeviceUID
        self.now = now
        self.publication = publication
        self.afterAdmission = afterAdmission
        self.afterHandle = afterHandle
        self.beforePromotion = beforePromotion
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
        lastStoppedCapture = nil
        requestedDeviceUID = deviceUID
        deviceMismatch = nil
        acceptedDeviceUID = nil
        openedDeviceUID = nil
        inputRejected = false
        rejectionEpisode = nil
        rejectionStartedAt = nil
        let engine = makeEngine()
        self.engine = engine
        if let deviceUID {
            do {
                try engine.selectInputDevice(uid: deviceUID)
            } catch {
                self.engine = nil
                throw RecorderError.noInputDevice
            }
        }
        let format = engine.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            self.engine = nil
            throw RecorderError.noInputDevice
        }
        if let deviceUID, !matchesDevice(format, deviceUID) {
            self.engine = nil
            throw RecorderError.noInputDevice
        }

        let store = AudioSampleStore()
        self.store = store
        let candidate: AudioTapProcessor
        let pending: AudioTapProcessor
        let pendingStore: AudioSampleStore
        do {
            candidate = AudioTapProcessor(
                resampler: try Resampler(inputFormat: format),
                store: store,
                generation: store.currentGeneration
            )
            // Every start stages what its engine emits before the identity is
            // known. The take's own store is what the start's span decision
            // reads, so a frame from the device that is opening cannot pass for
            // audio the take already accepted.
            let candidateStore = AudioSampleStore()
            pending = AudioTapProcessor(
                resampler: try Resampler(inputFormat: format),
                store: candidateStore,
                generation: candidateStore.currentGeneration
            )
            pendingStore = candidateStore
        } catch {
            self.engine = nil
            self.store = nil
            throw RecorderError.unsupportedFormat(error.localizedDescription)
        }

        let gate = FrameGate(
            target: pending,
            afterAdmission: afterAdmission,
            afterHandle: afterHandle,
            beforePromotion: beforePromotion
        )
        self.gate = gate
        admission = Admission(
            gate: gate,
            candidate: candidate,
            pending: pending,
            pendingStore: pendingStore
        )
        // Nothing is published as accepted until the engine's device is known;
        // the meter still follows the frames as they arrive.
        publication.publish(processor: pending, store: store)

        // 1024 frames is about 21 ms at 48 kHz: short enough for the meter to
        // feel live, long enough to keep the callback cheap.
        engine.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.tapBlock(for: gate)
        )
        tapInstalled = true
        engine.prepare()
        do {
            try start(engine)
        } catch {
            engine.removeTap(onBus: 0)
            tapInstalled = false
            admission = nil
            self.gate = nil
            processor = nil
            self.store = nil
            self.engine = nil
            publication.publish(processor: nil, store: nil)
            if let recorderError = error as? RecorderError, recorderError == .noInputDevice {
                throw recorderError
            }
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
        // The samples the take had accepted before this start are the only ones
        // that can make it a take on two devices. The frames this start emitted
        // are staged for the identity that is about to be read, and the
        // predecessor's tail was already flushed into the accepted store by the
        // rebuild that preceded this start; a buffer that produced no samples
        // and no tail is not audio.
        let hadAcceptedAudio = (store?.count ?? 0) > 0
        let previous = acceptedDeviceUID
        let reported = readDeviceUID(engine)
        let accepted: String?
        if let requestedDeviceUID {
            // The engine's own readback, not the reporting seam, decides whether
            // an explicit route may be admitted. An unreadable unit fails closed.
            let actual = engine.currentDeviceUID()
            guard let actual, actual == requestedDeviceUID else {
                deviceMismatch = (requestedDeviceUID, reported ?? "unknown")
                rejectCandidate(engine: engine)
                throw RecorderError.noInputDevice
            }
            accepted = actual
        } else {
            accepted = reported
        }
        // A take that already holds audio and is now on another device ran on
        // both. The comparison includes a device that became readable and one
        // that stopped being readable, because either means the take's audio
        // came from two answers.
        if hadAcceptedAudio, accepted != previous {
            spanned = true
        }
        openedDeviceUID = accepted
        acceptedDeviceUID = accepted
        deviceMismatch = nil
        inputRejected = false
        rejectionEpisode = nil
        rejectionStartedAt = nil
        // The staged frames enter the take only now: their device is the one
        // just accepted, and the span decision above was made without them.
        commitAdmission()
    }

    /// Stops a candidate that failed verification and discards only its frames.
    ///
    /// The accepted store, its converter and its identity are left alone, so a
    /// later route event can recover the take that was recording before the
    /// rejected start.
    private func rejectCandidate(engine: CaptureEngine) {
        engine.stop()
        if let admission {
            admission.gate.discard(
                pending: admission.pending,
                pendingStore: admission.pendingStore
            )
            publication.publish(processor: processor, store: store)
        }
        admission = nil
        enterRejectionEpisode()
    }

    /// Starts the rejection episode this input belongs to.
    ///
    /// The transition from accepted to rejected is what numbers a new episode.
    /// A rejection that lands while the take is already waiting is the same
    /// episode, so the deadline it already has is the one that applies.
    private func enterRejectionEpisode() {
        if !inputRejected {
            rejectionEpisodes += 1
            rejectionEpisode = rejectionEpisodes
            rejectionStartedAt = now()
        }
        inputRejected = true
    }

    /// What a rejected restart means for the take.
    ///
    /// The candidate's frames are discarded and the accepted take waits for the
    /// requested device to come back. The recorder puts a deadline on that wait
    /// and ends the take visibly when it passes.
    private func rejectionOutcome() -> RouteOutcome {
        .rejected
    }

    /// Promotes a verified candidate's frames and converter into the take.
    private func commitAdmission() {
        guard let admission, let store else { return }
        admission.gate.accept(
            admission.candidate,
            from: admission.pending,
            pendingStore: admission.pendingStore,
            into: store
        )
        processor = admission.candidate
        publication.publish(processor: admission.candidate, store: store)
        self.admission = nil
    }

    /// Answers a microphone configuration change.
    ///
    /// The decision is ``CaptureRouteChange``'s; everything that needs the
    /// device is here. A build of the new converter that fails ends the take
    /// instead of leaving a stopped engine behind a recording that looks live.
    ///
    /// - Returns: what happened, for the recorder to log or to end the take on.
    func reconcile() -> RouteOutcome {
        reconcilePassLock.lock()
        reconcilePasses += 1
        reconcilePassLock.unlock()
        guard let engine, let processor, let store else { return .unchanged }
        // A stale or foreign notification may still reach this generation. Only
        // a mismatch of the engine's own readback justifies a device write, and
        // that write happens after the engine has been stopped.
        let needsSelection = requestedDeviceUID.map { engine.currentDeviceUID() != $0 } ?? false
        if needsSelection || inputRejected {
            gate?.suspend()
            if engine.isRunning { engine.stop() }
            if let requestedDeviceUID {
                do {
                    try engine.selectInputDevice(uid: requestedDeviceUID)
                } catch {
                    publication.publish(processor: processor, store: store)
                    return .ended("The chosen microphone is no longer available.")
                }
            }
            let format = engine.inputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                return .ended("The microphone was disconnected.")
            }
            let details: (sameFormat: Bool, previousRate: Double)
            do {
                details = try prepareCandidate(on: engine, format: format)
            } catch {
                return .ended("The microphone changed to a format Dot cannot use.")
            }
            engine.prepare()
            do {
                try start(engine)
            } catch {
                retireFailedCandidate(on: engine)
                return rejectionOutcome()
            }
            return details.sameFormat
                ? .reinstalled(rate: format.sampleRate)
                : .formatChanged(from: details.previousRate, to: format.sampleRate)
        }

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
            // A restart always gets a converter of its own, bound to the store
            // generation that is live now, and it stages what it emits until
            // its device is known. A processor that a failed rebuild fenced is
            // retired and never re-armed.
            do {
                _ = try prepareCandidate(on: engine, format: format)
            } catch {
                return .ended("The microphone changed to a format Dot cannot use.")
            }
            engine.prepare()
            do {
                try start(engine)
            } catch {
                retireFailedCandidate(on: engine)
                return rejectionOutcome()
            }
            return .restarted(rate: format.sampleRate)
        case .rebuild:
            let details: (sameFormat: Bool, previousRate: Double)
            do {
                details = try prepareCandidate(on: engine, format: format)
            } catch {
                return .ended("The microphone changed to a format Dot cannot use.")
            }
            engine.prepare()
            do {
                try start(engine)
            } catch {
                retireFailedCandidate(on: engine)
                return rejectionOutcome()
            }
            return details.sameFormat
                ? .reinstalled(rate: format.sampleRate)
                : .formatChanged(from: details.previousRate, to: format.sampleRate)
        }
    }

    /// Discards a candidate whose engine would not start.
    ///
    /// The replacement converter was built and the accepted processor is
    /// already fenced, so the take cannot go back to it. The candidate's frames
    /// are dropped, the accepted audio and its identity stay, and the take
    /// enters a rejection episode: the requested device has to come back, and
    /// the recorder's deadline ends the take if it does not.
    private func retireFailedCandidate(on engine: CaptureEngine) {
        guard admission != nil else { return }
        rejectCandidate(engine: engine)
    }

    /// Builds a fresh converter for a start that follows a route change.
    ///
    /// The engine is stopped and the accepted converter is flushed before the
    /// replacement is published, so the old tail lands at the end of the
    /// accepted samples and no callback can cross the swap. The replacement's
    /// frames are staged in a candidate store: the engine emits them before its
    /// device is known, and the start commits them only once that device is
    /// accepted.
    private func prepareCandidate(
        on engine: CaptureEngine,
        format: AVAudioFormat
    ) throws -> (sameFormat: Bool, previousRate: Double) {
        guard let store else { throw RecorderError.noInputDevice }
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw RecorderError.noInputDevice
        }
        let sameFormat = processor?.inputFormat.isEqual(format) ?? false
        let previousRate = processor?.inputFormat.sampleRate ?? format.sampleRate
        gate?.suspend()
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.removeTap(onBus: 0)
            tapInstalled = false
        }
        // The predecessor's tail is part of the accepted audio, and it belongs
        // before every frame of the replacement: flush it now, while the tap is
        // still fenced, so the store's order survives the swap. A tail that
        // produces no samples adds nothing, which is what keeps a take that
        // only ever received an empty buffer from being labelled as mixed.
        if let previous = processor {
            let tail = previous.flushTail()
            store.append(contentsOf: tail)
            if let error = previous.error {
                Log.shared.error("recorder.convert.failed", ["error": .string(error)])
            }
        }
        // The store moves to the generation the replacement appends with before
        // the tap can deliver: a buffer the engine emits while it starts is then
        // part of the take instead of being fenced out. A new processor is the
        // only one that can append with it; the fenced predecessor is never
        // re-armed.
        let generation = store.beginGeneration()
        let candidate = AudioTapProcessor(
            resampler: try Resampler(inputFormat: format),
            store: store,
            generation: generation
        )
        // The tap can deliver while the engine starts. The candidate store
        // holds those frames until the identity is verified, and a rejected or
        // failed candidate takes them with it.
        let candidateStore = AudioSampleStore()
        let pending = AudioTapProcessor(
            resampler: try Resampler(inputFormat: format),
            store: candidateStore,
            generation: candidateStore.currentGeneration
        )
        // A fresh tap gets a gate of its own. The retired callback keeps the
        // gate it was installed with, and that gate stays suspended, so a
        // buffer the old tap still holds cannot reach the converter that
        // replaced it.
        let nextGate = FrameGate(
            target: pending,
            afterAdmission: afterAdmission,
            afterHandle: afterHandle,
            beforePromotion: beforePromotion
        )
        gate = nextGate
        admission = Admission(
            gate: nextGate,
            candidate: candidate,
            pending: pending,
            pendingStore: candidateStore
        )
        engine.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.tapBlock(for: nextGate)
        )
        tapInstalled = true
        publication.publish(processor: pending, store: store)
        return (sameFormat, previousRate)
    }

    /// Rebuilds the converter for the microphone's new format.
    ///
    /// The take keeps its store, so samples collected before the change keep
    /// their absolute offsets and the staged candidate appends only after its
    /// device has been verified. The only caller is a start whose route moved
    /// to another device, so the requested device is selected again first.
    private func rebuild(
        with format: AVAudioFormat,
        on engine: CaptureEngine
    ) -> RouteOutcome {
        var format = format
        if let requestedDeviceUID {
            gate?.suspend()
            if engine.isRunning { engine.stop() }
            do {
                try engine.selectInputDevice(uid: requestedDeviceUID)
            } catch {
                return .ended("The chosen microphone is no longer available.")
            }
            format = engine.inputFormat(forBus: 0)
        }
        guard format.channelCount > 0, format.sampleRate > 0 else {
            return .ended("The microphone was disconnected.")
        }
        let details: (sameFormat: Bool, previousRate: Double)
        do {
            details = try prepareCandidate(on: engine, format: format)
        } catch {
            return .ended("The microphone changed to a format Dot cannot use.")
        }
        engine.prepare()
        do {
            try start(engine)
        } catch {
            retireFailedCandidate(on: engine)
            return rejectionOutcome()
        }
        return details.sameFormat
            ? .reinstalled(rate: format.sampleRate)
            : .formatChanged(from: details.previousRate, to: format.sampleRate)
    }

    /// Stops the engine and hands over every sample the take collected.
    ///
    /// The gate is suspended first, so no new callback can be admitted; the tap
    /// and the engine go next. The converter may still hold part of its last
    /// frame, and a callback may still be finishing one: the fence `suspend()`
    /// put in place is what lets the flush take the stream lock without a later
    /// buffer adding audio after the snapshot.
    ///
    /// The result is kept for a second caller that arrives before the next
    /// open. A claimed stop that lands after a recovery deadline already cut
    /// the take off gets the same audio instead of an empty take.
    func stopCapture() -> StoppedCapture {
        if let lastStoppedCapture, engine == nil, processor == nil, store == nil {
            return lastStoppedCapture
        }
        gate?.suspend()
        if let engine {
            if tapInstalled {
                engine.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
            engine.reset()
            self.engine = nil
        }
        // The take is ending: the gate is suspended, so no callback can be in
        // flight, and the last converter's tail belongs to the accepted audio
        // even when a rejected candidate had moved the store's generation on.
        let tail = processor?.flushTail() ?? []
        if let error = processor?.error {
            Log.shared.error("recorder.convert.failed", ["error": .string(error)])
        }
        store?.append(contentsOf: tail)
        let samples = store?.all() ?? []
        // The take's identity is the device whose frames were admitted, not the
        // readback of a candidate that was stopped before verification.
        let result = StoppedCapture(samples: samples, spanned: spanned, deviceUID: acceptedDeviceUID)
        processor = nil
        store = nil
        gate = nil
        admission = nil
        openedDeviceUID = nil
        acceptedDeviceUID = nil
        requestedDeviceUID = nil
        deviceMismatch = nil
        inputRejected = false
        rejectionEpisode = nil
        rejectionStartedAt = nil
        self.spanned = false
        lastStoppedCapture = result
        publication.publish(processor: nil, store: nil)
        return result
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
        if deviceUID != nil {
            // A chosen device was selected before the first format read in
            // `open`, and the connected check was made there. Settle the take
            // through `reconcile`, which reads the format after selecting that
            // device again, so the converter cannot be left on an older format.
            if deviceChanged { return .unusable }
            let outcome = reconcile()
            if case .ended = outcome { return .unusable }
            if case .rejected = outcome { return .unusable }
            if case .unchanged = outcome { return .ready }
            return .reconciled(outcome)
        }
        let format = engine.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return .unusable }
        if deviceChanged {
            // The route moved to a device that happens to run the same format:
            // the tap is installed again, so the take starts on the device it
            // opened on rather than on the one that replaced it.
            let outcome = rebuild(with: format, on: engine)
            if case .ended = outcome { return .unusable }
            if case .rejected = outcome { return .unusable }
            return .reconciled(outcome)
        }
        guard !processor.inputFormat.isEqual(format) || !engine.isRunning || !tapInstalled else {
            return .ready
        }
        let outcome = reconcile()
        if case .ended = outcome { return .unusable }
        if case .rejected = outcome { return .unusable }
        return .reconciled(outcome)
    }

    /// Builds the callback the input tap runs.
    ///
    /// The callback runs on the audio thread, so it is built outside any actor:
    /// a closure that inherited the main actor's isolation would be reported by
    /// the concurrency runtime every time the audio thread called it.
    private static func tapBlock(
        for gate: FrameGate
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            gate.handle(buffer)
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
        /// A normal stop has claimed the take and the audio queue has not
        /// drained it yet.
        ///
        /// The card has already left recording: what is left is the microphone,
        /// which belongs to the drain until it answers. Opening a new take over
        /// it is what the state refuses.
        case stopping
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
        /// Reads the clock a rejected route's recovery deadline runs on.
        var now: @Sendable () -> TimeInterval = { CACurrentMediaTime() }
        /// Schedules the recovery deadline check.
        ///
        /// The app's schedule runs it on the audio queue, where the take's state
        /// lives. A test supplies one it can fire from its own clock.
        var scheduleRecovery:
            (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)?
        /// Called inside the tap gate after a buffer found its converter.
        ///
        /// Nil in the app. A test holds a callback here to prove the hand-over
        /// cannot close a processor whose buffer is already being admitted.
        var afterAdmission: (@Sendable () -> Void)?
        /// Called inside the tap gate after the admitted buffer was handled.
        ///
        /// Nil in the app. A test reads the publication at the end of the
        /// callback boundary, where a transiently published frame would still
        /// be visible.
        var afterHandle: (@Sendable () -> Void)?
        /// Called before a hand-over takes the gate lock.
        ///
        /// Nil in the app. A test pauses promotion itself and reads the take
        /// before the candidate's frames are appended.
        var beforePromotion: (@Sendable () -> Void)?
        /// Called at the start of a claimed stop's drain, on the audio queue.
        ///
        /// Nil in the app. A test holds the drain here so the take's published
        /// samples can be read before the engine is released.
        var beforeDrain: (@Sendable () -> Void)?

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
        private var openedGeneration: Int?
        private var cleanupTaken = false
        private var completed = false
        private var cutoff: StopCutoff?

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

        /// Records the generation `open` returned, once.
        func markOpened(_ generation: Int) {
            lock.lock()
            if openedGeneration == nil { openedGeneration = generation }
            lock.unlock()
        }

        /// Takes the one cleanup of an open that was already started.
        ///
        /// The start block and a quit can both reach the abandoned open. Only
        /// the first caller gets the generation and performs the stop.
        func takeCleanup() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard !cleanupTaken, let openedGeneration else { return nil }
            cleanupTaken = true
            return openedGeneration
        }

        /// Installs the cutoff a quit waits for, or finishes it when the start
        /// already cleaned itself up.
        func installCutoff() -> StopCutoff {
            lock.lock()
            let cutoff = self.cutoff ?? StopCutoff()
            self.cutoff = cutoff
            let done = completed
            lock.unlock()
            if done { cutoff.finish() }
            return cutoff
        }

        /// Records that the start block no longer owns the engine.
        func complete() {
            lock.lock()
            completed = true
            let cutoff = self.cutoff
            lock.unlock()
            cutoff?.finish()
        }
    }

    /// One normal stop, claimed on the main actor before the take is drained.
    ///
    /// The claim is what lets the card leave recording on the turn Stop was
    /// pressed: the samples the take had already published are read here, on
    /// the main actor, and the drain of the engine is queued on the audio queue
    /// behind whatever it was already doing. The drain's answer comes back
    /// through the claim, and a quit or a cancel takes the delivery back
    /// without waiting for the queue.
    @MainActor
    final class StopClaim {
        /// How a claimed stop ended.
        enum Outcome {
            /// The audio queue drained the take, and this is all of its audio.
            case drained(Recording)
            /// The delivery was taken back before the queue answered.
            case abandoned
        }

        /// How many samples the take had already published when Stop was
        /// accepted.
        ///
        /// The card reads it to decide what it can show before the queue
        /// answers: a take with audio is transcribing now; one with none waits,
        /// because the converter's flushed tail can still make it non-empty.
        let publishedSamples: Int

        private var outcome: Outcome?
        private var waiters: [CheckedContinuation<Outcome, Never>] = []

        init(publishedSamples: Int) {
            self.publishedSamples = publishedSamples
        }

        /// How the claim ended.
        ///
        /// Awaiting it suspends the caller, not the main actor: the audio queue
        /// answers when it answers.
        var result: Outcome {
            get async {
                if let outcome { return outcome }
                return await withCheckedContinuation { waiters.append($0) }
            }
        }

        /// Whether the delivery was taken back before the queue answered.
        var isAbandoned: Bool {
            if case .abandoned = outcome { return true }
            return false
        }

        /// Records the one outcome of the claim.
        ///
        /// The first answer wins: a drain that finishes after the delivery was
        /// taken back changes nothing.
        func resolve(_ outcome: Outcome) {
            guard self.outcome == nil else { return }
            self.outcome = outcome
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume(returning: outcome) }
        }

        /// Takes the delivery back without waiting for the drain.
        func abandon() {
            resolve(.abandoned)
        }
    }

    /// The end of a claimed stop's audio work, for a quit that joins it.
    ///
    /// It is signalled on the audio queue after the one drain, not by the
    /// claim's delivery, so the join can only ever wait for the engine being
    /// released. It is a lock and continuations rather than a task so that
    /// ``Recorder/claimStop()`` enqueues the drain on the caller's turn instead
    /// of from a task that may start after a newer route callback.
    final class StopCutoff: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        /// Records that the audio queue finished the drain.
        func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in pending { waiter.resume() }
        }

        /// Waits for the audio queue to finish the drain.
        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    /// How long the start path waits for the device cache, off the main thread.
    private nonisolated static let catalogWaitSeconds: TimeInterval = 2

    /// The deadline a rejected route has to recover within.
    ///
    /// A rejection leaves the accepted take recording over a stopped engine: the
    /// requested input has to come back or the take ends where the person sees
    /// it. The state is a lock and a token because the timer runs on the audio
    /// queue while the recorder that armed it lives on the main actor. Each
    /// deadline belongs to the episode that armed it, so a deadline left over
    /// from an older rejection can never end the episode that runs now.
    private final class RecoveryState: @unchecked Sendable {
        private let lock = NSLock()
        private var deadline: TimeInterval?
        private var episode: Int?
        private var token = 0

        /// Arms the one deadline of a rejection episode.
        ///
        /// - Returns: the token that owns the deadline, or `nil` when this
        ///   episode already has one. A repeated `.rejected` of the same episode
        ///   does not reset the clock: the take ends when that episode said it
        ///   would. A newer episode gets a deadline of its own.
        func arm(episode: Int, startedAt: TimeInterval, seconds: TimeInterval) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard self.episode != episode else { return nil }
            token += 1
            self.episode = episode
            deadline = startedAt + seconds
            return token
        }

        /// Clears the deadline when `token` still owns it.
        ///
        /// A newer arm or a teardown has a newer token, and this call must not
        /// clear the state that belongs to it.
        @discardableResult
        func cancel(token: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard self.token == token else { return false }
            deadline = nil
            episode = nil
            self.token += 1
            return true
        }

        /// Clears whatever deadline the take has.
        func cancel() {
            lock.lock()
            deadline = nil
            episode = nil
            token += 1
            lock.unlock()
        }

        /// The deadline and the episode that own `token`, or `nil` when a newer
        /// arm or a teardown has taken the state.
        func state(for token: Int) -> (deadline: TimeInterval, episode: Int)? {
            lock.lock()
            defer { lock.unlock() }
            guard self.token == token, let deadline, let episode else { return nil }
            return (deadline, episode)
        }
    }

    /// The identity of the engine the current start opened.
    ///
    /// A route notification from another engine is stale or belongs to another
    /// take; a notification with no object is the synthetic case fixtures use
    /// and stays accepted.
    private final class EngineIdentity: @unchecked Sendable {
        private let lock = NSLock()
        private var identifier: ObjectIdentifier?

        func set(_ object: AnyObject?) {
            lock.lock()
            identifier = object.map(ObjectIdentifier.init)
            lock.unlock()
        }

        var hasIdentity: Bool {
            lock.lock()
            defer { lock.unlock() }
            return identifier != nil
        }

        func accepts(_ candidate: ObjectIdentifier?) -> Bool {
            guard let candidate else { return true }
            lock.lock()
            defer { lock.unlock() }
            return identifier == candidate
        }
    }

    private let environment: Environment
    private let engineIdentity = EngineIdentity()
    /// How long a rejected route has to recover before the take ends visibly.
    private nonisolated static let recoverySeconds: TimeInterval = 2.0
    /// The one queue every engine call runs on, in the order the calls arrive.
    private let audioQueue: DispatchQueue
    /// Where the recovery deadline check is scheduled.
    private let recoveryScheduler:
        @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    /// The deadline a rejected route has to recover within.
    ///
    /// It is a lock and a token because the timer runs on the audio queue while
    /// the recorder that armed it lives on the main actor.
    private let recovery = RecoveryState()
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
    /// The normal stop that owns the microphone while it drains.
    ///
    /// It is the take's identity for the delivery of the drain's answer: only
    /// this claim's answer is recorded, and a claim that was taken back never
    /// delivers.
    private var activeStop: StopClaim?
    /// The audio-queue drain of that stop, for a quit that joins it.
    private var stopCutoff: StopCutoff?
    /// The cleanup of a start that was abandoned, for a quit that joins it.
    private var startCutoff: StopCutoff?
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
        let queue = DispatchQueue(
            label: "com.anandlo.dot.audio-control",
            qos: .userInitiated
        )
        self.audioQueue = queue
        self.recoveryScheduler = environment.scheduleRecovery ?? { delay, work in
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        let publication = CapturePublication()
        self.publication = publication
        let identity = self.engineIdentity
        self.session = CaptureSession(
            makeEngine: {
                let engine = environment.makeEngine()
                identity.set(engine.configurationIdentity)
                return engine
            },
            readDeviceUID: environment.openedDeviceUID,
            now: environment.now,
            publication: publication,
            afterAdmission: environment.afterAdmission,
            afterHandle: environment.afterHandle,
            beforePromotion: environment.beforePromotion
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
        // A take that is already open, opening, or being drained by a stop is
        // not started twice, and the caller must not be left waiting for an
        // answer that will never come. A take whose drain has not answered still
        // owns the microphone; opening over it would drain the new take's store
        // in the old one's cutoff.
        let canTakeOverAbandonedStop = state == .stopping && activeStop?.isAbandoned == true
        guard state == .idle || canTakeOverAbandonedStop else {
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
        if canTakeOverAbandonedStop {
            activeStop = nil
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
            // allowed here, off the main thread, and only here. A timeout never
            // turns an explicit choice into the system default: when the cache
            // is unavailable the HAL translation and the unit's readback are the
            // authority, and a device that cannot be verified fails closed.
            let requestedDeviceUID = deviceUID
            var waitedOut = false
            let catalogAvailable = MicrophoneCatalog.awaitSnapshot(
                timeout: Self.catalogWaitSeconds
            ) != nil
            if !catalogAvailable { waitedOut = true }
            let plannedDeviceUID = MicrophoneCatalog.recordingDeviceUID(configured: deviceUID)
            // A quit or a cancel that landed while this block waited for the
            // device cache owns the take: the microphone is not opened at all,
            // so there is no engine to drain and no take to publish.
            if request.isAbandoned {
                request.complete()
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
            var failure: RecorderError?
            var openGeneration: Int?
            do {
                openGeneration = try session.open(
                    deviceUID: deviceUID,
                    matchesDevice: { format, uid in
                        if catalogAvailable { return Self.formatMatchesDevice(format, deviceUID: uid) }
                        return true
                    }
                )
            } catch {
                failure = (error as? RecorderError) ?? .engineFailed(error.localizedDescription)
            }
            // The generation is read once here: the answers below are handed to
            // closures that outlive this block, and a captured `var` is not
            // something a concurrent closure may read.
            let openedGeneration = openGeneration
            // The open is the slow part a quit can land inside. The abandonment
            // read is made again here, on the audio queue and immediately after
            // the open returns, so an engine that opened while the quit was in
            // flight is closed on this queue before anything is reconciled or
            // published. The request takes the one cleanup of this open.
            if let openedGeneration { request.markOpened(openedGeneration) }
            if request.isAbandoned {
                if let openedGeneration {
                    if request.takeCleanup() != nil {
                        _ = session.stopCapture(generation: openedGeneration)
                        request.complete()
                    }
                } else {
                    request.complete()
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
                    matchesDevice: { format, uid in
                        if catalogAvailable { return Self.formatMatchesDevice(format, deviceUID: uid) }
                        return true
                    }
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
            // The engine is the only witness of what it opened. A take that
            // opened another device than the one asked for is unusable, even when
            // the system still lists the configured microphone.
            if let mismatch = session.deviceMismatch {
                logWarning("capture.device.mismatch", [
                    "requested_device": .string(mismatch.requested),
                    "opened_device": .string(mismatch.opened),
                ])
                if failure == nil {
                    if let openedGeneration {
                        _ = session.stopCapture(generation: openedGeneration)
                    }
                    failure = .noInputDevice
                }
            }
            // The take's identity is the device whose frames were admitted. The
            // raw readback is kept for a warning about a device that was rejected.
            let acceptedDeviceUID = session.acceptedDeviceUID
            let openedDeviceUID = session.openedDeviceUID
            if waitedOut {
                logWarning("catalog.wait.timeout", [
                    "seconds": .double(Self.catalogWaitSeconds),
                    "requested_device": .string(requestedDeviceUID ?? "system"),
                    "opened_device": .string(
                        session.deviceMismatch?.opened ?? openedDeviceUID ?? "unknown"
                    ),
                ])
            }
            let engineMilliseconds = Int(((CACurrentMediaTime() - queuedAt) * 1000).rounded())
            let queueWait = Int(((queuedAt - requestedAt) * 1000).rounded())

            // A stop or an Escape that arrived while the engine was opening owns
            // the take now: its own open is drained, and the cancellation is what
            // the caller is waiting for.
            if request.isAbandoned {
                if let openedGeneration {
                    if request.takeCleanup() != nil {
                        _ = session.stopCapture(generation: openedGeneration)
                        request.complete()
                    }
                } else {
                    request.complete()
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
                // The open is over and the engine is released; a quit that
                // waited for this start has nothing left to join.
                request.complete()
                deliver { [weak self] in
                    guard let self else { return }
                    // Only the newest start may put the recorder back to idle: an
                    // answer that has been replaced must not touch the take that
                    // replaced it.
                    let ownsStart = self.pendingStart === request && !request.isAbandoned
                    if ownsStart {
                        self.pendingStart = nil
                        self.state = .idle
                        self.removeConfigurationObserver(generation: generation)
                        self.pendingRouteCheck = false
                    }
                    completion(StartReport(
                        generation: generation,
                        openedDeviceUID: nil,
                        result: .failure(ownsStart ? failure : .cancelled)
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
                    // A quit may already have taken the cleanup of this open
                    // and be waiting on it; only the path that takes the
                    // cleanup queues the stop, so the engine is released once.
                    if let openedGeneration {
                        if request.takeCleanup() != nil {
                            self.audioQueue.async {
                                _ = session.stopCapture(generation: openedGeneration)
                                request.complete()
                            }
                        }
                    } else {
                        request.complete()
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
                self.publishedDeviceUID = acceptedDeviceUID
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
                    openedDeviceUID: acceptedDeviceUID,
                    result: .success(())
                ))
            }
        }
    }

    /// Stops recording and returns the WAV.
    ///
    /// This is the stop that waits for the audio queue. The normal stop of the
    /// app is ``claimStop()``, which does not: the card must leave recording
    /// before the queue answers, and a route reconciliation queued ahead of the
    /// drain can take as long as the device. Every caller that has to have the
    /// audio before it returns, such as the failed-capture recovery and the
    /// cancel paths, keeps using this one.
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
        case .stopping:
            // A claimed stop already owns the one drain of this take. A second
            // stop must not stop the engine again, and it has no audio to hand
            // over: the claim's answer is the only result of that drain.
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

    /// Claims the running take for a normal stop.
    ///
    /// Everything a stop decides on the main actor happens on the caller's turn:
    /// the take is marked as stopping, its clock and its route observer are
    /// released, and exactly one drain of the engine is queued on the audio
    /// queue. The queue is not waited for, so a route reconciliation that was
    /// already running (the slow part, because it opens the device again) holds
    /// only the drain, not the card.
    ///
    /// The drain itself is unchanged: the tap is removed, the engine is stopped
    /// and reset, the converter is flushed, and the samples and the device are
    /// snapshotted in that order. The claim is the answer's identity: only its
    /// own drain is recorded, and a claim that was taken back delivers nothing.
    ///
    /// - Returns: the claim, or `nil` when there is no running take to claim.
    ///   A take a route failure already ended is answered here from the audio it
    ///   kept, without a drain. A second stop of the same take, a stop of a take
    ///   that has not opened, or a stop of a take that has already been drained
    ///   changes nothing and queues no second drain.
    func claimStop() -> StopClaim? {
        // A take a visible route failure already ended keeps its audio and its
        // identity for the stop that follows, and the answer is known here: no
        // queue is asked and no second drain is queued.
        if let endedTake {
            self.endedTake = nil
            let claim = StopClaim(publishedSamples: endedTake.samples.count)
            claim.resolve(.drained(endedTake))
            return claim
        }
        guard state == .recording else { return nil }
        let claim = StopClaim(publishedSamples: publication.sampleCount)
        activeStop = claim
        beginTeardown(next: .stopping)
        // The take ended when Stop was accepted, not when the queue answered.
        let duration = elapsed
        startedAt = nil
        let session = self.session
        let deliver = environment.deliver
        // The claim's answer, prepared before the queue is asked so the closure
        // the queue runs does not have to reach back to this recorder on another
        // thread.
        let settled: @MainActor @Sendable (CaptureSession.StoppedCapture, TimeInterval, Double) -> Void = {
            [weak self] stopped, duration, peakDBFS in
            self?.finishStop(
                claim,
                stopped: stopped,
                duration: duration,
                peakDBFS: peakDBFS
            )
        }
        // The join a quit may make: it is the audio queue releasing the engine,
        // not the claim's delivery, so a quit can wait for it without waiting
        // for a main-actor completion. It is signalled by the queue itself,
        // after the one drain, so nothing about the join can move the enqueue
        // below off this turn.
        let cutoff = StopCutoff()
        stopCutoff = cutoff
        let beforeDrain = environment.beforeDrain
        audioQueue.async {
            // A reconcile that was queued before this block runs first, exactly
            // as the synchronous stop used to wait for it.
            beforeDrain?()
            let stopped = session.stopCapture()
            let peakDBFS = AudioLevel.peakDBFS(samples: stopped.samples)
            deliver { settled(stopped, duration, peakDBFS) }
            cutoff.finish()
        }
        return claim
    }

    /// Puts the recorder back to idle when a claimed stop's drain answers.
    ///
    /// The claim is the identity: a drain that answers after the delivery was
    /// taken back still releases the microphone, and only this claim's own
    /// answer is ever recorded.
    private func finishStop(
        _ claim: StopClaim,
        stopped: CaptureSession.StoppedCapture,
        duration: TimeInterval,
        peakDBFS: Double
    ) {
        guard activeStop === claim else { return }
        activeStop = nil
        stopCutoff = nil
        state = .idle
        claim.resolve(.drained(Recording(
            samples: stopped.samples,
            duration: duration,
            peakDBFS: peakDBFS,
            spannedDevices: stopped.spanned,
            deviceUID: stopped.deviceUID
        )))
    }

    /// The audio-queue work a quit may wait for, handed over once.
    ///
    /// A normal stop leaves one drain behind, and an abandoned start leaves the
    /// cleanup of the engine it opened. Both are the engine being released,
    /// which is the only stop work a quit waits for; the claim's own delivery is
    /// not waited for, because the quit has already taken it back.
    func takePendingStopCutoff() -> Task<Void, Never>? {
        let stop = stopCutoff
        let start = startCutoff
        stopCutoff = nil
        startCutoff = nil
        guard stop != nil || start != nil else { return nil }
        return Task {
            if let stop { await stop.wait() }
            if let start { await start.wait() }
        }
    }

    /// Takes back the delivery of a normal stop that is still draining.
    ///
    /// The one drain the claim queued is left alone: it is what stops the
    /// engine, and a quit may neither wait for the audio queue on the main
    /// actor nor ask for a second drain.
    func invalidateStopDelivery() {
        activeStop?.abandon()
    }

    /// Releases the take a quit found, without waiting for the audio queue.
    ///
    /// A quit has to close the microphone on the turn it is accepted. A take
    /// that has not opened yet is taken back the way a cancel takes it back; an
    /// open that has already started is closed on the audio queue, and the quit
    /// can join that cleanup through ``takePendingStopCutoff()``. A take that
    /// is recording is claimed exactly as ``claimStop()`` claims it, so one
    /// drain is queued behind whatever the audio queue was doing and the
    /// claim's delivery is taken back at once; a take that is already draining
    /// only loses its delivery. Nothing here reaches for the queue: a route
    /// reconciliation that is still running is held only by the work that was
    /// already behind it, never by the thread asking for the quit.
    ///
    /// - Returns: the claim the quit took back, when the take was recording.
    @discardableResult
    func shutDown() -> StopClaim? {
        switch state {
        case .idle:
            return nil
        case .starting:
            // `abandonStart` installs the cutoff before it takes the start
            // back, so the cleanup the held open still owes has something to
            // signal.
            abandonStart()
            return nil
        case .recording:
            // The claim is what carries the one drain and the identity of the
            // answer; taking its delivery back is what keeps a quit from
            // publishing, while the queue still releases the microphone.
            let claim = claimStop()
            claim?.abandon()
            return claim
        case .stopping:
            // A second quit, or the cancel of the teardown that follows it, adds
            // nothing: the one drain is already on the queue and its answer is
            // already taken back.
            activeStop?.abandon()
            return activeStop
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
        case .stopping:
            // The drain belongs to a normal stop that is already on the audio
            // queue. Taking it back means dropping its delivery, not stopping
            // the engine a second time or waiting for the queue on this thread.
            activeStop?.abandon()
        case .recording:
            let claim = claimStop()
            claim?.abandon()
        }
    }

    /// Takes back a start that has not opened the engine yet.
    ///
    /// Everything the start put in place goes with it: its route observer and the
    /// change it may have noted. A later answer for this start cannot take them
    /// from the start that replaced it, because both are matched by generation.
    ///
    /// Whatever the open is still doing, this start owes the engine a cleanup.
    /// The cutoff is registered before the request is abandoned, so a quit that
    /// follows a stop or a cancel has something to join: the open may return
    /// long after both, and the quit must not let the process end with the
    /// engine still running.
    private func abandonStart() {
        if let request = pendingStart {
            startCutoff = request.installCutoff()
            request.abandon()
            removeConfigurationObserver(generation: request.generation)
            pendingRouteCheck = false
            // The open may already have returned on the audio queue. Close that
            // engine here rather than waiting for the held answer, and let the
            // cleanup signal the cutoff a quit joined.
            if let generation = request.takeCleanup() {
                let session = self.session
                audioQueue.async {
                    _ = session.stopCapture(generation: generation)
                    request.complete()
                }
            }
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

    /// How many reconciliation passes the audio queue has run.
    ///
    /// It is the observable a test uses to prove a foreign notification never
    /// reached the queue. The counter belongs to the session, where the pass
    /// runs.
    var reconcilePassCount: Int { session.reconcilePassCount }

    #if DEBUG
    /// Waits until every block queued on the audio queue before it has run.
    ///
    /// It is the completion barrier a test uses to tell a notification that
    /// reached the queue from one that was filtered on the main actor. The
    /// queue never waits on the main actor, so the barrier cannot deadlock.
    func drainAudioQueueForTesting() {
        audioQueue.sync {}
    }
    #endif

    /// How many takes ended through the synchronous `audioQueue.sync` path.
    ///
    /// A recovery deadline stops the take on the audio queue itself, so its
    /// end must not add a pass here. It is readable so a test can assert that.
    private(set) var synchronousCapturePasses = 0

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
        // The take that asks is part of the question. An answer that has been
        // held on its way to the main actor can arrive after this take was
        // claimed and after the next one started, and the phase alone would
        // apply the old microphone's rebuild to the new take.
        let take = startGeneration
        let session = self.session
        let deliver = environment.deliver
        let logWarning = environment.logWarning
        audioQueue.async { [weak self] in
            let outcome = session.reconcile()
            let deviceUID = session.acceptedDeviceUID
            if let mismatch = session.deviceMismatch {
                logWarning("capture.device.mismatch", [
                    "requested_device": .string(mismatch.requested),
                    "opened_device": .string(mismatch.opened),
                ])
            }
            // The answer goes through the same delivery as a start's, so the one
            // seam covers every hop the recorder makes to the main actor.
            deliver { [weak self] in
                self?.apply(outcome, deviceUID: deviceUID, take: take)
            }
        }
    }

    /// Reports what a route change did, and ends the take when it could not
    /// continue.
    ///
    /// - Parameter take: the start that asked for the reconciliation. It is the
    ///   take's identity: a delivery from a take that has been claimed or
    ///   replaced cannot touch the one that runs now.
    private func apply(
        _ outcome: CaptureSession.RouteOutcome,
        deviceUID: String?,
        take: Int
    ) {
        guard state == .recording, take == startGeneration else { return }
        switch outcome {
        case .rejected:
            armRecoveryDeadline(take: take)
        case .unchanged:
            settleOutcome(deviceUID: deviceUID)
        case .restarted(let rate):
            settleOutcome(deviceUID: deviceUID)
            Log.shared.info("recorder.engine.restarting", ["rate": .double(rate)])
        case .reinstalled(let rate):
            settleOutcome(deviceUID: deviceUID)
            Log.shared.info("recorder.tap.reinstalled", ["rate": .double(rate)])
        case .formatChanged(let from, let to):
            settleOutcome(deviceUID: deviceUID)
            Log.shared.info("recorder.format.changed", [
                "from": .double(from),
                "to": .double(to),
            ])
        case .ended(let message):
            settleOutcome(deviceUID: deviceUID)
            fail(message)
        }
    }

    /// Ends a rejection episode and follows the device the take now uses.
    private func settleOutcome(deviceUID: String?) {
        recovery.cancel()
        // A rebuild can land the take on another device. The identity follows the
        // engine, so the app's calibration does too. Whether the take crossed
        // devices is not decided here: the audio queue decided it when it started
        // the engine again, and the take carries it out.
        if deviceUID != publishedDeviceUID {
            publishedDeviceUID = deviceUID
            onDeviceChange?(deviceUID)
        }
    }

    /// Starts the deadline a rejected route has to recover within.
    ///
    /// One episode has one deadline, and the audio queue owns the episode. Main
    /// asks the queue to arm whatever episode is live, because by the time a
    /// held `.rejected` answer lands here the take may have recovered and
    /// rejected again. A stale answer then arms the episode that runs now, and
    /// the episode it belonged to cannot end it.
    private func armRecoveryDeadline(take: Int) {
        guard state == .recording else { return }
        let recovery = self.recovery
        let session = self.session
        let queue = audioQueue
        let deliver = environment.deliver
        queue.async { [weak self] in
            guard let episode = session.rejectionEpisode,
                  let startedAt = session.rejectionStartedAt else { return }
            guard let token = recovery.arm(
                episode: episode,
                startedAt: startedAt,
                seconds: Self.recoverySeconds
            ) else { return }
            deliver { [weak self] in self?.scheduleRecovery(token: token, take: take) }
        }
    }

    /// Schedules the check that ends a take no route recovered.
    ///
    /// The expiry runs on the audio queue, serialized with the recovery it is
    /// racing. If the rejection is gone by the time the clock reaches the
    /// deadline, the take is left alone. If it is still there, the queue
    /// performs the terminal stop itself and hands the preserved capture to the
    /// main actor, which never reaches back for the queue.
    private func scheduleRecovery(token: Int, take: Int) {
        guard let state = recovery.state(for: token) else { return }
        let remaining = max(0, state.deadline - environment.now())
        let episode = state.episode
        let session = self.session
        let queue = audioQueue
        let now = environment.now
        let deliver = environment.deliver
        let recovery = self.recovery
        let scheduler = recoveryScheduler
        scheduler(remaining) { [weak self] in
            queue.async { [weak self] in
                guard let deadline = recovery.state(for: token)?.deadline else { return }
                guard now() >= deadline else {
                    // The clock has not reached the deadline yet: wait out the
                    // rest instead of ending the take early.
                    deliver { [weak self] in self?.scheduleRecovery(token: token, take: take) }
                    return
                }
                // Recovery and expiry both run on this queue, and the episode
                // is the queue's. A take that recovered and rejected again is a
                // new episode: this deadline belonged to the older one and
                // never ends the newer one.
                guard session.rejectionEpisode == episode, session.inputRejected else {
                    _ = recovery.cancel(token: token)
                    return
                }
                // A newer arm or a teardown owns the deadline now. Clearing it
                // here would take the take from that owner.
                guard recovery.cancel(token: token) else { return }
                let stopped = session.stopCapture()
                let peakDBFS = AudioLevel.peakDBFS(samples: stopped.samples)
                deliver { [weak self] in
                    self?.finishExpiredCapture(
                        stopped,
                        peakDBFS: peakDBFS,
                        take: take
                    )
                }
            }
        }
    }

    /// Applies the capture the audio queue already stopped at the deadline.
    ///
    /// It is the claimed-stop answer without the claim: the samples, the span
    /// and the device are the ones the queue snapshotted. The take is preserved
    /// for the stop that follows, and the engine is not touched again.
    private func finishExpiredCapture(
        _ stopped: CaptureSession.StoppedCapture,
        peakDBFS: Double,
        take: Int
    ) {
        guard state == .recording, take == startGeneration else { return }
        // The audio queue already released the engine and flushed the
        // converter. Nothing here may reach for it.
        beginTeardown(next: .idle)
        // A claim queued before this message arrived would drain a session that
        // is already stopped. Its delivery is dropped; the capture is kept for
        // the stop that follows.
        activeStop?.abandon()
        let duration = elapsed
        startedAt = nil
        endedTake = Recording(
            samples: stopped.samples,
            duration: duration,
            peakDBFS: peakDBFS,
            spannedDevices: stopped.spanned,
            deviceUID: stopped.deviceUID
        )
        onFailure?("The chosen microphone is no longer available.")
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
        beginTeardown(next: .idle)
        synchronousCapturePasses += 1
        // The audio queue is serial and a start that had not finished was
        // abandoned, so the engine is not in the middle of anything: this block
        // runs after the last call that touched it.
        let stopped = audioQueue.sync { session.stopCapture() }
        let duration = elapsed
        startedAt = nil
        return (stopped.samples, duration, stopped.spanned, stopped.deviceUID)
    }

    /// Releases the main-actor machinery of the take that is ending.
    ///
    /// The clock and the route observer go first, then the change a route may
    /// have noted, so a queued answer of this take has nothing left to act on.
    /// The engine is not touched: only the audio queue may, and what it is told
    /// to do depends on where the take is going.
    ///
    /// - Parameter next: the state the recorder is left in.
    private func beginTeardown(next: State) {
        recovery.cancel()
        state = next
        ticker?.cancel()
        ticker = nil
        removeConfigurationObserver()
        pendingRouteCheck = false
        publishedDeviceUID = nil
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
        ) { [weak self] note in
            // A notification posted with no object must stay accepted: casting a
            // nil `Any?` to `AnyObject` yields a boxed optional, not nil, and
            // that would be read as a foreign engine.
            let identity: ObjectIdentifier? = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainThreadTick.run { [weak self] in
                guard let self else { return }
                if let identity, self.engineIdentity.hasIdentity,
                   !self.engineIdentity.accepts(identity) { return }
                self.noteConfigurationChange(for: generation)
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
        guard onTick != nil else { return }
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
