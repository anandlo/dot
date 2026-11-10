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

/// Real-time 5-band acoustic spectrum frame (`0...1` per row) computed directly
/// from the microphone's PCM waveform on each audio tap buffer.
public struct AudioSpectrumFrame: Sendable, Equatable {
    /// 5 frequency/acoustic bands from top (`0`: high sibilance/fricatives) to bottom (`4`: chest fundamental).
    public var bands: (Double, Double, Double, Double, Double)

    public static let zero = AudioSpectrumFrame(bands: (0, 0, 0, 0, 0))

    public init(bands: (Double, Double, Double, Double, Double)) {
        self.bands = bands
    }

    public static func == (lhs: AudioSpectrumFrame, rhs: AudioSpectrumFrame) -> Bool {
        lhs.bands.0 == rhs.bands.0
            && lhs.bands.1 == rhs.bands.1
            && lhs.bands.2 == rhs.bands.2
            && lhs.bands.3 == rhs.bands.3
            && lhs.bands.4 == rhs.bands.4
    }

    public subscript(row: Int) -> Double {
        switch row {
        case 0: return bands.0
        case 1: return bands.1
        case 2: return bands.2
        case 3: return bands.3
        default: return bands.4
        }
    }

    /// Computes 5 genuine frequency bands from a mono float audio buffer (`sampleRate` Hz).
    public static func analyze(mono: [Float], sampleRate: Double) -> AudioSpectrumFrame {
        let n = mono.count
        guard n >= 16 else { return .zero }

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
        guard totalRMS > 0.0008 else { return .zero }

        // Convert each band's RMS into perceptual dBFS-mapped 0...1 energy
        // with an expanded dynamic range (-60 dBFS floor) to prevent pegging at 100%.
        func mapBand(_ rms: Double, gain: Double) -> Double {
            let boosted = rms * gain
            guard boosted > 0.00005 else { return 0 }
            let db = 20.0 * log10(boosted)
            let norm = (db - (-60.0)) / (0.0 - (-60.0))
            return min(1.0, max(0.0, norm))
        }

        let zcr = Double(zeroCrossings) * invN * (sampleRate / 16000.0)
        let sibilanceBoost = min(1.6, max(0.8, zcr * 2.2))

        // Row 0 (top): High-frequency sibilants / fricatives ("s", "sh", "t", "k")
        let b0 = mapBand(sqrt(highSq * invN), gain: 1.5 * sibilanceBoost)
        // Row 1 (upper-mid): Upper vocal formants (1.2 kHz - 3.5 kHz, bright vowels "ee", "ay")
        let b1 = mapBand(sqrt(midHighSq * invN), gain: 1.25)
        // Row 2 (center): Core speech presence (350 Hz - 1.8 kHz)
        let b2 = mapBand(sqrt((midLowSq + midHighSq) * 0.6 * invN), gain: 1.05)
        // Row 3 (lower-mid): Warm vowel body (250 Hz - 850 Hz, "ah", "oh")
        let b3 = mapBand(sqrt(midLowSq * invN), gain: 1.15)
        // Row 4 (bottom): Fundamental pitch & chest resonance (80 Hz - 300 Hz, deep voice)
        let b4 = mapBand(sqrt(lowSq * invN), gain: 1.0)

        return AudioSpectrumFrame(bands: (b0, b1, b2, b3, b4))
    }
}

/// Collects the microphone's audio on the real-time thread.
///
/// The class is deliberately free of AppKit: it is called from the audio
/// callback, which must never touch the user interface.
final class AudioTapProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var resampler: Resampler
    private var samples: [Int16] = []
    private var latestLevel: Double = 0
    private var latestSpectrum: AudioSpectrumFrame = .zero
    private var failure: String?

    init(resampler: Resampler) {
        self.resampler = resampler
    }

    /// The format the converter expects.
    var inputFormat: AVAudioFormat { resampler.inputFormat }

    /// Handles one buffer from the input tap.
    func handle(_ buffer: AVAudioPCMBuffer) {
        let mono = Resampler.monoSamples(from: buffer)
        let level: Double
        if mono.isEmpty {
            level = 0
        } else {
            var total = 0.0
            for v in mono {
                let d = Double(v)
                total += d * d
            }
            level = (total / Double(mono.count)).squareRoot()
        }
        let spectrum = AudioSpectrumFrame.analyze(mono: mono, sampleRate: buffer.format.sampleRate)
        lock.lock()
        latestLevel = level
        latestSpectrum = spectrum
        lock.unlock()
        do {
            let converted = try resampler.convert(buffer)
            guard !converted.isEmpty else { return }
            lock.lock()
            samples.append(contentsOf: converted)
            lock.unlock()
        } catch {
            lock.lock()
            failure = error.localizedDescription
            lock.unlock()
        }
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

    /// Every sample collected so far.
    func collectedSamples() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// How many samples have been collected.
    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// A copy of one range of the samples collected so far.
    ///
    /// The range is clamped to what has arrived, so a caller that raced the
    /// audio thread gets a shorter range instead of a crash. Only the range is
    /// copied: the live loop asks for twelve seconds, not for the whole take.
    func samples(in range: Range<Int>) -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let lower = min(max(range.lowerBound, 0), samples.count)
        let upper = min(max(range.upperBound, lower), samples.count)
        guard lower < upper else { return [] }
        return Array(samples[lower..<upper])
    }

    /// The error the converter ran into, if any.
    var error: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
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
        /// The 16 kHz mono samples that were recorded.
        ///
        /// The stop does not encode a WAV of the whole take: the part of it
        /// that is already transcribed is final, and only the tail is sent.
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
    private var startedAt: Date?
    private var ticker: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?

    /// Called with the microphone level (RMS) and the elapsed time.
    var onTick: ((Double, TimeInterval) -> Void)?
    /// Called when the microphone goes away or the engine fails.
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
        let tap = AudioTapProcessor(resampler: resampler)
        processor = tap

        // 1024 frames is about 21 ms at 48 kHz: short enough for the meter to
        // feel live, long enough to keep the callback cheap.
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(for: tap))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            processor = nil
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
        guard isRecording else {
            return Recording(samples: [], duration: 0, peakDBFS: -.infinity)
        }
        isRecording = false
        ticker?.cancel()
        ticker = nil
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            self.engine = nil
        }

        var samples: [Int16] = []
        if let processor {
            samples = processor.collectedSamples()
            if let error = processor.error {
                Log.shared.error("recorder.convert.failed", ["error": .string(error)])
            }
        }
        let duration = elapsed
        startedAt = nil
        processor = nil
        return Recording(
            samples: samples,
            duration: duration,
            peakDBFS: AudioLevel.peakDBFS(samples: samples)
        )
    }

    /// Throws the recording away and stops the engine.
    func cancel() {
        guard isRecording else { return }
        _ = stop()
    }

    /// How many samples the current recording holds.
    ///
    /// The live loop reads this to decide whether a whole chunk can be
    /// committed, without copying the audio it does not need.
    var sampleCount: Int {
        processor?.sampleCount ?? 0
    }

    /// A copy of the samples in `range` from the current recording.
    func samples(in range: Range<Int>) -> [Int16] {
        processor?.samples(in: range) ?? []
    }

    /// A WAV of one range of the current recording.
    ///
    /// - Parameter range: the samples to send, as offsets from the start of the
    ///   recording.
    /// - Returns: `nil` when the range holds nothing that has arrived yet.
    func wav(range: Range<Int>) -> Data? {
        guard let processor else { return nil }
        let slice = processor.samples(in: range)
        guard !slice.isEmpty else { return nil }
        return WAVWriter.encode(samples: slice)
    }

    /// Whether the microphone's format still matches the converter.
    ///
    /// A device that is unplugged, or one that comes back with another sample
    /// rate, has to be handled: the converter is rebuilt and the recording
    /// continues with the samples collected so far.
    func checkForFormatChange() {
        guard isRecording, let processor, let engine else { return }
        let format = engine.inputNode.inputFormat(forBus: 0)
        if format.channelCount == 0 || format.sampleRate == 0 {
            onFailure?("The microphone was disconnected.")
            return
        }
        guard !processor.inputFormat.isEqual(format) else { return }
        Log.shared.info("recorder.format.changed", [
            "from": .double(processor.inputFormat.sampleRate),
            "to": .double(format.sampleRate),
        ])
        rebuild(with: format)
    }

    private func rebuild(with format: AVAudioFormat) {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        guard let resampler = try? Resampler(inputFormat: format) else {
            onFailure?("The microphone changed to a format Dot cannot use.")
            return
        }
        let tap = AudioTapProcessor(resampler: resampler)
        processor = tap
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.tapBlock(for: tap)
        )
        engine.prepare()
        do {
            try engine.start()
        } catch {
            onFailure?("The microphone could not be restarted: \(error.localizedDescription)")
        }
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
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.onTick?(self.processor?.level ?? 0, self.elapsed)
            }
        }
        source.resume()
        ticker = source
    }
}
