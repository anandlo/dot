import AVFoundation
import DotCore
import Foundation

/// Why playback could not start.
enum SpeechEngineError: Error, LocalizedError {
    /// The machine has no usable output format.
    case outputUnavailable
    /// The samples could not be converted to the engine's format.
    case conversionFailed(String)
    /// The engine refused to start.
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .outputUnavailable:
            "There is no audio output to speak through."
        case .conversionFailed(let detail):
            "The answer's audio could not be converted: \(detail)"
        case .engineFailed(let detail):
            "The speaker could not be started: \(detail)"
        }
    }
}

/// The output half of Dot's audio.
///
/// It is a **second** engine, not a shared one. `Recorder` builds an
/// `AVAudioEngine` around the input node for the length of a recording and tears
/// it down when the take ends. Sharing that engine would tie playback to the
/// microphone's lifetime: a long answer would keep the input node alive, and
/// starting a recording would tear down the output. One engine per direction
/// keeps both lifetimes honest, and the app stops speech before it opens the
/// microphone, which also stops Dot from hearing itself through the speakers.
///
/// The engine does not exist until the first chunk arrives, and it is released
/// again after an idle period. A Mac that never speaks never pays for an output
/// graph.
@MainActor
final class SpeechEngine {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSource: VoiceAudioFormat?
    private var converterOutput: AVAudioFormat?
    private var volumeValue: Float = 1

    /// Called with the level of each scheduled buffer, `0...1`.
    var onLevel: ((Float) -> Void)?

    /// How loud Dot's own voice is, `0...1`.
    ///
    /// It is the player node's own gain, not the device's: ducking Dot must never
    /// touch the system volume or another app's audio, which is what makes the
    /// output safe to mix with whatever the person is already listening to.
    var volume: Float {
        get { volumeValue }
        set {
            volumeValue = min(max(newValue, 0), 1)
            player?.volume = volumeValue
        }
    }

    /// Whether an engine exists, whether or not it is rendering.
    var hasEngine: Bool { engine != nil }

    /// Whether the engine is rendering right now.
    var isRunning: Bool { engine?.isRunning ?? false }

    /// Schedules one chunk of an answer.
    ///
    /// The chunk is converted to the engine's own format and handed to the
    /// player node, which queues it behind whatever is already scheduled. The
    /// engine starts on the first chunk, not before, and the first scheduled
    /// buffer is audible as soon as it exists.
    ///
    /// - Parameter chunk: the PCM the provider produced.
    /// - Throws: ``SpeechEngineError`` when there is no output or the samples
    ///   cannot be converted.
    func enqueue(_ chunk: VoiceChunk) throws {
        guard !chunk.data.isEmpty else { return }
        let (engine, player, destination) = try prepareIfNeeded()
        guard let buffer = try convert(chunk, to: destination) else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                throw SpeechEngineError.engineFailed(error.localizedDescription)
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
        if let onLevel { onLevel(level(of: buffer)) }
    }

    /// Stops playback at once and drops everything scheduled.
    ///
    /// This is the barge-in path: the person pressed the key, so the answer must
    /// stop in the same frame rather than at the end of the sentence. The engine
    /// is paused, not released, because a follow-up answer may arrive within the
    /// idle window.
    func stop() {
        player?.stop()
        engine?.pause()
        if let onLevel { onLevel(0) }
    }

    /// Releases the engine and its player.
    func teardown() {
        player?.stop()
        engine?.stop()
        if let engine, let player {
            engine.detach(player)
        }
        engine = nil
        player = nil
        format = nil
        converter = nil
        converterSource = nil
        converterOutput = nil
        if let onLevel { onLevel(0) }
    }

    // MARK: - The graph

    private func prepareIfNeeded() throws -> (AVAudioEngine, AVAudioPlayerNode, AVAudioFormat) {
        if let engine, let player, let format {
            return (engine, player, format)
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let destination = Self.destinationFormat(of: engine)
        guard let destination else { throw SpeechEngineError.outputUnavailable }
        engine.connect(player, to: engine.mainMixerNode, format: destination)
        player.volume = volumeValue
        engine.prepare()
        self.engine = engine
        self.player = player
        self.format = destination
        return (engine, player, destination)
    }

    /// The format the player node is connected with.
    ///
    /// It is the mixer's own format, so the mixer does no sample-rate conversion
    /// of its own and every conversion happens once, here, where a test could
    /// see it. A device that reports nothing yet gets the standard 48 kHz stereo
    /// float format instead of a crash.
    private static func destinationFormat(of engine: AVAudioEngine) -> AVAudioFormat? {
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        if mixerFormat.sampleRate > 0, mixerFormat.channelCount > 0 {
            return mixerFormat
        }
        return AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
    }

    /// Converts one chunk into the engine's format.
    private func convert(_ chunk: VoiceChunk, to destination: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: chunk.format.sampleRate,
            channels: AVAudioChannelCount(max(1, chunk.format.channelCount)),
            interleaved: true
        )
        guard let sourceFormat else {
            throw SpeechEngineError.conversionFailed("the answer's format is not usable")
        }
        let bytesPerFrame = max(1, chunk.format.channelCount) * 2
        let frames = chunk.data.count / bytesPerFrame
        guard frames > 0,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames))
        else {
            throw SpeechEngineError.conversionFailed("the chunk held no whole frame")
        }
        source.frameLength = AVAudioFrameCount(frames)
        let sampleCount = frames * max(1, chunk.format.channelCount)
        chunk.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let channel = source.int16ChannelData?[0] else { return }
            channel.update(from: base.assumingMemoryBound(to: Int16.self), count: sampleCount)
        }

        let converter = converter(for: chunk.format, source: sourceFormat, destination: destination)
        guard let converter else {
            throw SpeechEngineError.conversionFailed("no converter for the answer's format")
        }
        let ratio = destination.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: capacity) else {
            throw SpeechEngineError.conversionFailed("no room for the converted audio")
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard !supplied else {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return source
        }
        if let conversionError {
            throw SpeechEngineError.conversionFailed(conversionError.localizedDescription)
        }
        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        default:
            return nil
        }
    }

    /// The converter for one source format, rebuilt when the format changes.
    private func converter(
        for source: VoiceAudioFormat,
        source sourceFormat: AVAudioFormat,
        destination: AVAudioFormat
    ) -> AVAudioConverter? {
        if let converter,
           let converterSource,
           let converterOutput,
           converterSource.matches(source),
           converterOutput.sampleRate == destination.sampleRate,
           converterOutput.channelCount == destination.channelCount {
            return converter
        }
        guard let fresh = AVAudioConverter(from: sourceFormat, to: destination) else { return nil }
        converter = fresh
        converterSource = source
        converterOutput = destination
        return fresh
    }

    /// The RMS level of a converted buffer, scaled for a meter.
    private func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = channels[0]
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for frame in 0..<frames {
            let sample = samples[frame]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        return min(1, rms * 3)
    }
}
