import Foundation

/// The measurement of a recording.
///
/// These are measurements, not thresholds: Dot never refuses a recording
/// because of what they say.
public enum AudioLevel {
    /// The RMS of a set of samples, normalised to ±1.
    public static func rms(samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var total: Double = 0
        for sample in samples {
            let value = Double(sample) / 32_768.0
            total += value * value
        }
        return (total / Double(samples.count)).squareRoot()
    }

    /// The RMS of raw little-endian PCM16 bytes, normalised to ±1.
    public static func rms(pcm16: Data) -> Double {
        let bytes = [UInt8](pcm16)
        let count = bytes.count / 2
        guard count > 0 else { return 0 }
        var total: Double = 0
        for index in 0..<count {
            let low = UInt16(bytes[index * 2])
            let high = UInt16(bytes[index * 2 + 1])
            let value = Double(Int16(bitPattern: low | (high << 8))) / 32_768.0
            total += value * value
        }
        return (total / Double(count)).squareRoot()
    }

    /// The RMS in dBFS. Silence is negative infinity.
    public static func rmsDBFS(samples: [Int16]) -> Double {
        decibels(rms(samples: samples))
    }

    /// The RMS of raw PCM16 bytes in dBFS.
    public static func rmsDBFS(pcm16: Data) -> Double {
        decibels(rms(pcm16: pcm16))
    }

    /// The loudest sample in dBFS.
    public static func peakDBFS(samples: [Int16]) -> Double {
        var peak = 0
        for sample in samples {
            let value = abs(Int(sample))
            if value > peak { peak = value }
        }
        return decibels(Double(peak) / 32_768.0)
    }

    /// The loudest sample in dBFS.
    public static func peakDBFS(pcm16: Data) -> Double {
        let bytes = [UInt8](pcm16)
        let count = bytes.count / 2
        guard count > 0 else { return -.infinity }
        var peak = 0
        for index in 0..<count {
            let low = UInt16(bytes[index * 2])
            let high = UInt16(bytes[index * 2 + 1])
            let value = abs(Int(Int16(bitPattern: low | (high << 8))))
            if value > peak { peak = value }
        }
        return decibels(Double(peak) / 32_768.0)
    }

    /// A level in decibels.
    public static func decibels(_ amplitude: Double) -> Double {
        guard amplitude > 0 else { return -.infinity }
        return 20 * log10(amplitude)
    }
}
