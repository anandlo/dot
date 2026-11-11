import AVFoundation
import Foundation

/// Something went wrong while converting the microphone's samples.
public enum ResamplerError: Error, Equatable, LocalizedError {
    /// The converter could not be built for the given formats.
    case unsupportedFormat(String)
    /// `AVAudioConverter` refused the conversion.
    case conversionFailed(String)
    /// A buffer arrived whose format does not match the converter's input.
    case formatMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let detail): "The microphone format is not supported: \(detail)"
        case .conversionFailed(let detail): "The audio could not be converted: \(detail)"
        case .formatMismatch: "The microphone changed format while recording."
        }
    }
}

/// Converts the microphone's samples into the 16 kHz mono PCM16 a provider wants.
///
/// The channel down-mix is done here, in Swift, and averages the channels
/// exactly like Scrawl does (`src/audio.rs::input_stream`). The rate
/// conversion is done by `AVAudioConverter`, the same resampler Core Audio
/// uses everywhere: it is a high-quality band-limited resampler.
///
/// The class is a *stream*: buffers are pushed in with ``convert(_:)`` while the
/// microphone is running and the tail is flushed with ``flush()`` when the
/// recording stops. `AVAudioConverter` keeps its resampling phase across
/// calls, so a recording that arrives in many small buffers is converted
/// exactly like the same audio in one buffer.
public final class Resampler: @unchecked Sendable {
    /// The sample rate every provider expects.
    public static let targetSampleRate: Double = 16_000

    /// The format the converter produces: mono float at the target rate.
    public let outputFormat: AVAudioFormat
    /// The format the converter expects: mono float at the source rate.
    public let monoFormat: AVAudioFormat
    /// The format the microphone delivers.
    public let inputFormat: AVAudioFormat

    private let converter: AVAudioConverter
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var endRequested = false

    /// Builds a converter for `inputFormat`.
    ///
    /// - Throws: ``ResamplerError/unsupportedFormat(_:)`` when `AVAudioConverter`
    ///   cannot handle the pair of formats.
    public init(inputFormat: AVAudioFormat, targetSampleRate: Double = Resampler.targetSampleRate) throws {
        self.inputFormat = inputFormat
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ResamplerError.unsupportedFormat("cannot create a mono format")
        }
        self.monoFormat = mono
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ResamplerError.unsupportedFormat("cannot create a \(targetSampleRate) Hz mono format")
        }
        self.outputFormat = output
        guard let converter = AVAudioConverter(from: mono, to: output) else {
            throw ResamplerError.unsupportedFormat(
                "\(inputFormat.sampleRate) Hz is not convertible to \(targetSampleRate) Hz"
            )
        }
        self.converter = converter
    }

    /// Converts one buffer of microphone audio into 16 kHz mono PCM16.
    ///
    /// - Returns: the samples produced so far. An empty array means the
    ///   converter is still filling its filter.
    /// - Throws: ``ResamplerError/formatMismatch`` when the buffer does not
    ///   match the format the converter was built for.
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [Int16] {
        try convert(buffers: [buffer])
    }

    /// Converts a batch of buffers that arrived together.
    public func convert(buffers: [AVAudioPCMBuffer]) throws -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        for buffer in buffers where !matches(buffer.format) {
            throw ResamplerError.formatMismatch
        }
        for buffer in buffers {
            try enqueueLocked(Self.monoSamples(from: buffer))
        }
        return try run()
    }

    /// Converts one buffer that is already down-mixed.
    ///
    /// The audio tap mixes a buffer to mono to measure it. Handing those
    /// samples straight here saves the second down-mix the callback used to
    /// pay for on every buffer, and the allocation that came with it.
    ///
    /// - Parameters:
    ///   - monoSamples: the mono mix of one buffer.
    ///   - sampleRate: the rate the buffer was recorded at; it has to be the
    ///     rate this converter was built for.
    /// - Returns: the samples produced so far.
    /// - Throws: ``ResamplerError/formatMismatch`` when the rate is not the
    ///   one the converter expects.
    public func convert(monoSamples: [Float], sampleRate: Double) throws -> [Int16] {
        guard sampleRate == inputFormat.sampleRate else {
            throw ResamplerError.formatMismatch
        }
        lock.lock()
        defer { lock.unlock() }
        try enqueueLocked(monoSamples)
        return try run()
    }

    /// Puts one mono buffer in line for the converter.
    private func enqueueLocked(_ mono: [Float]) throws {
        guard !mono.isEmpty else { return }
        guard let monoBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: AVAudioFrameCount(mono.count)
        ), let channel = monoBuffer.floatChannelData?[0] else {
            throw ResamplerError.conversionFailed("no buffer")
        }
        monoBuffer.frameLength = AVAudioFrameCount(mono.count)
        channel.update(from: mono, count: mono.count)
        pending.append(monoBuffer)
    }

    /// Ends the stream and returns the samples the converter was still holding.
    ///
    /// Without this call the last fraction of a second is lost: the converter
    /// keeps a partial output frame in its filter until the stream ends.
    public func flush() throws -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        endRequested = true
        return try run()
    }

    /// Whether the given format is the one this converter was built for.
    public func matches(_ format: AVAudioFormat) -> Bool {
        format.sampleRate == inputFormat.sampleRate
            && format.channelCount == inputFormat.channelCount
    }

    // MARK: - Internals

    private func run() throws -> [Int16] {
        var output: [Int16] = []
        let capacity = AVAudioFrameCount(max(4096, outputFormat.sampleRate / 4))
        while true {
            let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
            guard let outBuffer else { throw ResamplerError.conversionFailed("no output buffer") }
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { [self] _, status in
                if !pending.isEmpty {
                    status.pointee = .haveData
                    return pending.removeFirst()
                }
                if endRequested {
                    status.pointee = .endOfStream
                } else {
                    status.pointee = .noDataNow
                }
                return nil
            }
            if status == .error {
                throw ResamplerError.conversionFailed(error?.localizedDescription ?? "unknown error")
            }
            if outBuffer.frameLength > 0 {
                output.append(contentsOf: Self.int16Samples(from: outBuffer))
            }
            switch status {
            case .haveData:
                continue
            case .endOfStream, .inputRanDry:
                return output
            case .error:
                return output
            @unknown default:
                return output
            }
        }
    }

    /// The mono mix of a buffer: the average of its channels.
    ///
    /// This is the down-mix Scrawl uses (`src/audio.rs::input_stream`): the
    /// channels are averaged, so a stereo microphone is not louder than a mono
    /// one.
    public static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }
        let format = buffer.format
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frameCount)

        if format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData {
            if format.isInterleaved {
                let pointer = channels[0]
                for frame in 0..<frameCount {
                    var total: Float = 0
                    for channel in 0..<channelCount {
                        total += pointer[frame * channelCount + channel]
                    }
                    mono[frame] = total / Float(channelCount)
                }
            } else {
                for channel in 0..<channelCount {
                    let pointer = channels[channel]
                    for frame in 0..<frameCount {
                        mono[frame] += pointer[frame]
                    }
                }
                let scale = 1 / Float(channelCount)
                for frame in 0..<frameCount { mono[frame] *= scale }
            }
        } else if format.commonFormat == .pcmFormatInt16, let channels = buffer.int16ChannelData {
            if format.isInterleaved {
                let pointer = channels[0]
                for frame in 0..<frameCount {
                    var total: Float = 0
                    for channel in 0..<channelCount {
                        total += Float(pointer[frame * channelCount + channel]) / 32_768
                    }
                    mono[frame] = total / Float(channelCount)
                }
            } else {
                for channel in 0..<channelCount {
                    let pointer = channels[channel]
                    for frame in 0..<frameCount {
                        mono[frame] += Float(pointer[frame]) / 32_768
                    }
                }
                let scale = 1 / Float(channelCount)
                for frame in 0..<frameCount { mono[frame] *= scale }
            }
        } else {
            // The engine always hands us float32; anything else is a bug we
            // cannot recover from inside a real-time callback.
            return []
        }
        return mono
    }

    /// Reads the mono float samples of a buffer and turns them into PCM16.
    ///
    /// The conversion matches Scrawl's `pcm16` helper (`src/audio.rs`): the
    /// sample is clamped to ±1, scaled by 32 768 and rounded.
    public static func int16Samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        let mono = monoSamples(from: buffer)
        var result = [Int16](repeating: 0, count: mono.count)
        for frame in 0..<mono.count {
            result[frame] = pcm16(mono[frame])
        }
        return result
    }

    /// The RMS of a buffer's mono mix, normalised to ±1.
    ///
    /// This is what drives the level meter: it is the real level of the
    /// microphone, not an animation.
    public static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        let mono = monoSamples(from: buffer)
        guard !mono.isEmpty else { return 0 }
        var total = 0.0
        for value in mono {
            let sample = Double(value)
            total += sample * sample
        }
        return (total / Double(mono.count)).squareRoot()
    }

    /// Turns one normalised sample into a signed 16-bit sample.
    ///
    /// The rule is the one Scrawl uses (`src/audio.rs::pcm16`), so the bytes
    /// Dot uploads are the same bytes Scrawl would upload. A sample that
    /// is not a number becomes silence.
    public static func pcm16(_ sample: Float) -> Int16 {
        let value = sample.isFinite ? min(max(sample, -1.0), 1.0) : 0.0
        let scaled = (value * 32_768.0).rounded()
        let clamped = min(max(scaled, -32_768.0), 32_767.0)
        return Int16(clamped)
    }

    /// Converts a whole mono float buffer that lives at `inputSampleRate`.
    ///
    /// This is the one-shot form used by the tests and by anything that already
    /// has the samples in memory.
    public static func resample(
        monoSamples: [Float],
        inputSampleRate: Double,
        targetSampleRate: Double = Resampler.targetSampleRate
    ) throws -> [Int16] {
        guard !monoSamples.isEmpty else { return [] }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ResamplerError.unsupportedFormat("cannot create a \(inputSampleRate) Hz mono format")
        }
        let resampler = try Resampler(inputFormat: inputFormat, targetSampleRate: targetSampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(monoSamples.count))
        guard let buffer, let channel = buffer.floatChannelData?[0] else {
            throw ResamplerError.conversionFailed("no input buffer")
        }
        buffer.frameLength = AVAudioFrameCount(monoSamples.count)
        channel.update(from: monoSamples, count: monoSamples.count)
        var result = try resampler.convert(buffer)
        result.append(contentsOf: try resampler.flush())
        return result
    }
}
