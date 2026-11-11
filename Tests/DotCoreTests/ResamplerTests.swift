import AVFoundation
import XCTest

@testable import DotCore

final class ResamplerTests: XCTestCase {
    private func sine(
        frames: Int,
        sampleRate: Double,
        frequency: Double = 1_000,
        amplitude: Float = 0.5
    ) -> [Float] {
        (0..<frames).map { index in
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            return amplitude * Float(sin(phase))
        }
    }

    func test48000To16000KeepsTheLength() throws {
        let input = sine(frames: 48_000, sampleRate: 48_000)
        let output = try Resampler.resample(monoSamples: input, inputSampleRate: 48_000)
        XCTAssertEqual(output.count, 16_000)
        XCTAssertLessThanOrEqual(abs(output.count - 48_000 / 3), 1)
    }

    func testOutputLengthIsInputOverThreePlusOrMinusOne() throws {
        for frames in [3_000, 4_801, 12_003] {
            let input = sine(frames: frames, sampleRate: 48_000)
            let output = try Resampler.resample(monoSamples: input, inputSampleRate: 48_000)
            XCTAssertLessThanOrEqual(abs(output.count - frames / 3), 1, "frames: \(frames)")
        }
    }

    func test44100To16000KeepsTheLength() throws {
        let input = sine(frames: 44_100, sampleRate: 44_100)
        let output = try Resampler.resample(monoSamples: input, inputSampleRate: 44_100)
        XCTAssertEqual(output.count, 16_000)
    }

    func testNoSampleIsOutOfRange() throws {
        let input = sine(frames: 48_000, sampleRate: 48_000, amplitude: 1.0)
        let output = try Resampler.resample(monoSamples: input, inputSampleRate: 48_000)
        XCTAssertFalse(output.isEmpty)
        for sample in output {
            XCTAssertGreaterThanOrEqual(sample, -32_768)
            XCTAssertLessThanOrEqual(sample, 32_767)
        }
    }

    func testSilenceStaysSilent() throws {
        let input = [Float](repeating: 0, count: 48_000)
        let output = try Resampler.resample(monoSamples: input, inputSampleRate: 48_000)
        XCTAssertEqual(output.count, 16_000)
        for sample in output {
            XCTAssertEqual(sample, 0)
        }
    }

    func testNoNaNReachesTheOutput() {
        // Scrawl's rule: a sample that is not a number becomes silence.
        XCTAssertEqual(Resampler.pcm16(Float.nan), 0)
        XCTAssertEqual(Resampler.pcm16(Float.infinity), 0)
        XCTAssertEqual(Resampler.pcm16(-Float.infinity), 0)
        XCTAssertEqual(Resampler.pcm16(2.0), 32_767)
        XCTAssertEqual(Resampler.pcm16(-2.0), -32_768)
        XCTAssertEqual(Resampler.pcm16(0.5), 16_384)
    }

    func testAmplitudeSurvivesTheConversion() throws {
        let input = sine(frames: 48_000, sampleRate: 48_000, amplitude: 0.5)
        let output = try Resampler.resample(monoSamples: input, inputSampleRate: 48_000)
        let peak = output.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 15_000)
        XCTAssertLessThanOrEqual(peak, 32_767)
    }

    func testStreamingAndOneShotAgree() throws {
        let input = sine(frames: 48_000, sampleRate: 48_000)
        let oneShot = try Resampler.resample(monoSamples: input, inputSampleRate: 48_000)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("no format")
        }
        let resampler = try Resampler(inputFormat: format)
        var streamed: [Int16] = []
        let chunk = 480
        var start = 0
        while start < input.count {
            let count = min(chunk, input.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
            buffer?.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                buffer?.floatChannelData?[0][index] = input[start + index]
            }
            guard let buffer else { break }
            streamed.append(contentsOf: try resampler.convert(buffer))
            start += count
        }
        streamed.append(contentsOf: try resampler.flush())

        XCTAssertEqual(streamed.count, oneShot.count)
        XCTAssertEqual(streamed, oneShot)
    }

    func testStereoIsDownmixedToMono() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            return XCTFail("no format")
        }
        let resampler = try Resampler(inputFormat: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)
        buffer?.frameLength = 480
        for index in 0..<480 {
            buffer?.floatChannelData?[0][index] = 0.5
            buffer?.floatChannelData?[1][index] = -0.5
        }
        guard let buffer else { return XCTFail("no buffer") }
        var output = try resampler.convert(buffer)
        output.append(contentsOf: try resampler.flush())
        XCTAssertFalse(output.isEmpty)
        for sample in output {
            XCTAssertLessThanOrEqual(abs(Int(sample)), 2)
        }
    }
}

extension ResamplerTests {
    /// The tap already has the down-mixed buffer, so the converter takes it
    /// instead of mixing the same audio a second time.
    func testTheMonoOverloadProducesTheSameSamplesAsTheBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let mono = sine(frames: 4_800, sampleRate: 48_000)

        func throughBuffer() throws -> [Int16] {
            let resampler = try Resampler(inputFormat: format)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            buffer.floatChannelData?[0].update(from: mono, count: 4_800)
            var out = try resampler.convert(buffer)
            out.append(contentsOf: try resampler.flush())
            return out
        }

        func throughMono() throws -> [Int16] {
            let resampler = try Resampler(inputFormat: format)
            var out = try resampler.convert(monoSamples: mono, sampleRate: 48_000)
            out.append(contentsOf: try resampler.flush())
            return out
        }

        let expected = try throughBuffer()
        let actual = try throughMono()
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(actual, expected)
    }

    func testTheMonoOverloadRefusesTheWrongRate() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let resampler = try Resampler(inputFormat: format)
        XCTAssertThrowsError(try resampler.convert(monoSamples: [0.1, 0.2], sampleRate: 44_100)) { error in
            XCTAssertEqual(error as? ResamplerError, .formatMismatch)
        }
    }
}
