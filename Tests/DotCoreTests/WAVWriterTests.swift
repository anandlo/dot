import XCTest

@testable import DotCore

final class WAVWriterTests: XCTestCase {
    func testHeaderIs44Bytes() {
        let header = WAVWriter.header(dataLength: 0)
        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(WAVSpec.headerSize, 44)
    }

    func testHeaderLayoutMatchesTheReference() {
        // The reference layout of a canonical 16 kHz mono PCM16 WAV:
        //
        //   "RIFF" u32(36 + data) "WAVE" "fmt " u32(16) u16(1) u16(1)
        //   u32(16000) u32(32000) u16(2) u16(16) "data" u32(data)
        let dataLength = 3200
        let header = WAVWriter.header(dataLength: dataLength)
        let bytes = [UInt8](header)

        XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(readUInt32(bytes, 4), UInt32(36 + dataLength))
        XCTAssertEqual(String(bytes: bytes[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(bytes: bytes[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(readUInt32(bytes, 16), 16)
        XCTAssertEqual(readUInt16(bytes, 20), 1)          // WAVE_FORMAT_PCM
        XCTAssertEqual(readUInt16(bytes, 22), 1)          // one channel
        XCTAssertEqual(readUInt32(bytes, 24), 16_000)     // sample rate
        XCTAssertEqual(readUInt32(bytes, 28), 32_000)     // byte rate
        XCTAssertEqual(readUInt16(bytes, 32), 2)          // block align
        XCTAssertEqual(readUInt16(bytes, 34), 16)         // bits per sample
        XCTAssertEqual(String(bytes: bytes[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(readUInt32(bytes, 40), UInt32(dataLength))
    }

    func testEncodedFileIsCanonical() throws {
        let samples: [Int16] = [0, 1, -1, 32_767, -32_768, 1234]
        let wav = WAVWriter.encode(samples: samples)
        XCTAssertEqual(wav.count, 44 + samples.count * 2)

        let info = try WAVWriter.parse(wav)
        XCTAssertEqual(info.audioFormat, WAVSpec.audioFormat)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sampleRate, 16_000)
        XCTAssertEqual(info.bitsPerSample, 16)
        XCTAssertEqual(info.blockAlign, 2)
        XCTAssertEqual(info.byteRate, 32_000)
        XCTAssertEqual(info.dataOffset, 44)
        XCTAssertEqual(info.dataLength, samples.count * 2)
        XCTAssertEqual(info.frames, samples.count)
        XCTAssertTrue(info.isCanonical)
    }

    func testByteExactRoundTripOfAKnownSine() throws {
        let sampleRate = 16_000
        let frames = 4_800
        var expected = Data(capacity: frames * 2)
        for index in 0..<frames {
            let value = sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))
            let scaled = Int16((value * 32_767).rounded())
            var littleEndian = UInt16(bitPattern: scaled).littleEndian
            withUnsafeBytes(of: &littleEndian) { expected.append(contentsOf: $0) }
        }

        let wav = WAVWriter.encode(pcm16: expected)
        XCTAssertEqual(wav.count, 44 + expected.count)

        let recovered = try WAVWriter.samples(in: wav)
        XCTAssertEqual(recovered.count, frames)
        let recoveredBytes = WAVWriter.encode(samples: recovered)
        XCTAssertEqual(recoveredBytes, wav)
        XCTAssertEqual(wav.suffix(expected.count), expected)
    }

    func testSamplesRoundTripExactly() throws {
        let samples: [Int16] = [0, -1, 1, 300, -300, 32_767, -32_768]
        let wav = WAVWriter.encode(samples: samples)
        XCTAssertEqual(try WAVWriter.samples(in: wav), samples)
    }

    func testOddSampleCountIsTruncated() {
        var raw = Data([0x01, 0x02, 0x03])
        let wav = WAVWriter.encode(pcm16: raw)
        XCTAssertEqual(wav.count, 44 + 2)
        let info = try? WAVWriter.parse(wav)
        XCTAssertEqual(info?.dataLength, 2)
        raw.removeAll()
    }

    func testParsingRejectsBrokenFiles() {
        XCTAssertThrowsError(try WAVWriter.parse(Data([0x01, 0x02])))
        XCTAssertThrowsError(try WAVWriter.parse(Data("RIFF____WAVE".utf8)))
        var missingFormat = WAVWriter.header(dataLength: 0)
        missingFormat.replaceSubrange(12..<16, with: [0x58, 0x58, 0x58, 0x58]) // "XXXX"
        XCTAssertThrowsError(try WAVWriter.parse(missingFormat)) { error in
            XCTAssertEqual(error as? WAVError, .missingFormat)
        }
    }

    func testANonCanonicalSampleRateIsReported() throws {
        // A 44.1 kHz WAV is not the container every provider receives.
        var header = WAVWriter.header(dataLength: 0)
        header.replaceSubrange(24..<28, with: [0x44, 0xAC, 0x00, 0x00]) // 44100
        let info = try WAVWriter.parse(header)
        XCTAssertEqual(info.sampleRate, 44_100)
        XCTAssertFalse(info.isCanonical)
    }

    private func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
