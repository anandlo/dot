import Foundation

/// The exact shape of the WAV every provider receives.
///
/// The reference implementation records with `cpal`, decimates to 16 kHz mono
/// and wraps the samples with `hound` (`src/audio.rs::encode_wav_16k`). That
/// produces a canonical RIFF/WAVE file with a 44-byte header: `RIFF` / size /
/// `WAVE` / `fmt ` (16 bytes) / `data`. The speech services accept that
/// container untouched, so Dot produces byte-for-byte the same one.
///
/// The format is fixed: 16 000 Hz, one channel, signed 16-bit little-endian
/// PCM.
public enum WAVSpec {
    /// The sample rate every provider expects.
    public static let sampleRate: Int = 16_000
    /// Mono.
    public static let channels: Int = 1
    /// Signed 16-bit little-endian.
    public static let bitsPerSample: Int = 16
    /// `WAVE_FORMAT_PCM`.
    public static let audioFormat: UInt16 = 1
    /// Bytes per sample frame: 1 channel × 16 bit.
    public static let blockAlign: Int = 2
    /// Bytes per second: 16 000 × 2.
    public static let byteRate: Int = 32_000
    /// The size of the canonical header.
    public static let headerSize: Int = 44
}

/// What a RIFF/WAVE header says.
public struct WAVInfo: Sendable, Equatable {
    /// The format code (`1` is uncompressed PCM).
    public let audioFormat: UInt16
    /// The number of channels.
    public let channels: Int
    /// The sample rate in Hz.
    public let sampleRate: Int
    /// Bytes per second.
    public let byteRate: Int
    /// Bytes per sample frame.
    public let blockAlign: Int
    /// Bits per sample.
    public let bitsPerSample: Int
    /// The offset of the first sample byte.
    public let dataOffset: Int
    /// The number of sample bytes.
    public let dataLength: Int

    /// The number of sample frames.
    public var frames: Int { blockAlign > 0 ? dataLength / blockAlign : 0 }
    /// The playing time of the data chunk.
    public var durationMilliseconds: Int {
        sampleRate > 0 ? frames * 1000 / sampleRate : 0
    }
    /// Whether the file is exactly the canonical container.
    public var isCanonical: Bool {
        audioFormat == WAVSpec.audioFormat
            && bitsPerSample == WAVSpec.bitsPerSample
            && channels == WAVSpec.channels
            && sampleRate == WAVSpec.sampleRate
            && dataOffset == WAVSpec.headerSize
    }
}

/// A WAV that cannot be read.
public enum WAVError: Error, Equatable, LocalizedError {
    /// The file is shorter than a RIFF header.
    case tooShort
    /// The file does not start with `RIFF`.
    case notRIFF
    /// The file does not contain `WAVE`.
    case notWAVE
    /// The file has no `fmt ` chunk.
    case missingFormat
    /// The file has no `data` chunk.
    case missingData
    /// The file is not 16-bit PCM.
    case notPCM16
    /// The file is not mono.
    case notMono
    /// The file is not 16 kHz.
    case wrongSampleRate(Int)

    public var errorDescription: String? {
        switch self {
        case .tooShort: "The audio is too short to be a WAV file."
        case .notRIFF: "The audio does not start with a RIFF header."
        case .notWAVE: "The audio is not a WAVE file."
        case .missingFormat: "The audio has no format chunk."
        case .missingData: "The audio has no data chunk."
        case .notPCM16: "The audio is not 16-bit PCM."
        case .notMono: "The audio is not mono."
        case .wrongSampleRate(let rate): "The audio is \(rate) Hz, expected 16 kHz."
        }
    }
}

/// Writes and reads the canonical 16 kHz mono PCM16 WAV.
public enum WAVWriter {
    /// The 44-byte canonical header for a data chunk of `dataLength` bytes.
    ///
    /// The layout is the one `hound` writes for a mono 16-bit file:
    ///
    /// ```
    /// "RIFF" u32(36 + dataLength) "WAVE"
    /// "fmt " u32(16) u16(PCM) u16(channels) u32(sampleRate) u32(byteRate) u16(blockAlign) u16(bits)
    /// "data" u32(dataLength)
    /// ```
    public static func header(dataLength: Int) -> Data {
        let length = max(0, dataLength)
        var data = Data(capacity: WAVSpec.headerSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + length))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(WAVSpec.audioFormat)
        data.appendLittleEndian(UInt16(WAVSpec.channels))
        data.appendLittleEndian(UInt32(WAVSpec.sampleRate))
        data.appendLittleEndian(UInt32(WAVSpec.byteRate))
        data.appendLittleEndian(UInt16(WAVSpec.blockAlign))
        data.appendLittleEndian(UInt16(WAVSpec.bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(UInt32(length))
        return data
    }

    /// Wraps raw little-endian PCM16 samples in the canonical header.
    ///
    /// An odd number of bytes is truncated, because the container holds whole
    /// 16-bit samples.
    public static func encode(pcm16: Data) -> Data {
        var samples = pcm16
        if samples.count % 2 != 0 { samples.removeLast() }
        var out = header(dataLength: samples.count)
        out.append(samples)
        return out
    }

    /// Wraps signed 16-bit samples in the canonical header.
    ///
    /// The bytes are written into one buffer and appended in one go: the
    /// obvious `for sample in samples { data.append… }` appends two bytes at a
    /// time, which took 655 ms for the three minutes of audio of a real
    /// recording — on the main actor, between the stop and the request.
    public static func encode(samples: [Int16]) -> Data {
        let byteCount = samples.count * 2
        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes.withUnsafeMutableBufferPointer { destination in
            samples.withUnsafeBufferPointer { source in
                for index in 0..<source.count {
                    let value = UInt16(bitPattern: source[index])
                    destination[index * 2] = UInt8(truncatingIfNeeded: value)
                    destination[index * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
                }
            }
        }
        var out = header(dataLength: byteCount)
        out.reserveCapacity(WAVSpec.headerSize + byteCount)
        out.append(contentsOf: bytes)
        return out
    }

    /// Reads the interesting parts of a RIFF/WAVE header.
    public static func parse(_ data: Data) throws -> WAVInfo {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw WAVError.tooShort }
        guard Array(bytes[0..<4]) == Array("RIFF".utf8) else { throw WAVError.notRIFF }
        guard Array(bytes[8..<12]) == Array("WAVE".utf8) else { throw WAVError.notWAVE }

        var format: (UInt16, Int, Int, Int, Int, Int)?
        var dataOffset = -1
        var dataLength = 0
        var cursor = 12
        while cursor + 8 <= bytes.count {
            let chunkID = Array(bytes[cursor..<(cursor + 4)])
            let chunkSize = Int(readLittleEndianUInt32(bytes, at: cursor + 4))
            let payloadStart = cursor + 8
            let payloadEnd = payloadStart + chunkSize
            if chunkID == Array("fmt ".utf8), payloadStart + 16 <= bytes.count {
                let audioFormat = readLittleEndianUInt16(bytes, at: payloadStart)
                let channels = Int(readLittleEndianUInt16(bytes, at: payloadStart + 2))
                let sampleRate = Int(readLittleEndianUInt32(bytes, at: payloadStart + 4))
                let byteRate = Int(readLittleEndianUInt32(bytes, at: payloadStart + 8))
                let blockAlign = Int(readLittleEndianUInt16(bytes, at: payloadStart + 12))
                let bits = Int(readLittleEndianUInt16(bytes, at: payloadStart + 14))
                format = (audioFormat, channels, sampleRate, byteRate, blockAlign, bits)
            } else if chunkID == Array("data".utf8) {
                dataOffset = payloadStart
                dataLength = min(chunkSize, max(0, bytes.count - payloadStart))
            }
            cursor = payloadEnd + (chunkSize % 2)
        }

        guard let format else { throw WAVError.missingFormat }
        guard dataOffset >= 0 else { throw WAVError.missingData }
        let (audioFormat, channels, sampleRate, byteRate, blockAlign, bits) = format
        return WAVInfo(
            audioFormat: audioFormat,
            channels: channels,
            sampleRate: sampleRate,
            byteRate: byteRate,
            blockAlign: blockAlign,
            bitsPerSample: bits,
            dataOffset: dataOffset,
            dataLength: dataLength
        )
    }

    /// Reads the samples of a canonical WAV back.
    public static func samples(in data: Data) throws -> [Int16] {
        let info = try parse(data)
        guard info.dataOffset + info.dataLength <= data.count else { throw WAVError.tooShort }
        let count = info.dataLength / 2
        var result = [Int16](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { destination in
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for index in 0..<count {
                    let offset = info.dataOffset + index * 2
                    let low = UInt16(base[offset])
                    let high = UInt16(base[offset + 1])
                    destination[index] = Int16(bitPattern: low | (high << 8))
                }
            }
        }
        return result
    }
}

extension Data {
    /// Appends a little-endian `UInt16`.
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    /// Appends a little-endian `UInt32`.
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

func readLittleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    guard offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

func readLittleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    guard offset + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}
