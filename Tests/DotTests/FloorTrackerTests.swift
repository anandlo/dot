import DotCore
@testable import Dot
import XCTest

/// What the room floor does to a voice that holds still.
///
/// The floor rises while the level is steady within 1.5 dB between frames, which
/// is what a fan is and, the report says, what a held vowel can look like. This
/// measures real speech rather than a tone: six files of continuous prose, each
/// pushed through ``VoiceMeter`` the way the card pushes it, and the floor, the
/// gate and the level recorded over every block.
///
/// Skipped unless `DOT_FLOOR_DIR` names the directory the files and the table are
/// kept in.
@MainActor
final class FloorTrackerTests: XCTestCase {
    /// The recorder's block, in frames (Recorder.swift's tap installs 1024).
    static let blockFrames = 1024
    /// How many HUD frames see one block, as the meter's own comment states.
    static let repeats = 6
    /// How many HUD frames a second runs at.
    static let rate: Double = 60
    /// The compressor's threshold, in dBFS.
    static let thresholdDBFS: Double = -30
    /// The compressor's ratio.
    static let ratio: Double = 4
    /// The compressor's attack, in seconds.
    static let attack: Double = 0.005
    /// The compressor's release, in seconds.
    static let releaseSeconds: Double = 0.050

    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOT_FLOOR_DIR"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The samples of a 16-bit mono RIFF file.
    ///
    /// - Parameter url: the file.
    /// - Returns: its samples, scaled to `-1...1`.
    static func samples(at url: URL) throws -> [Double] {
        let data = try Data(contentsOf: url)
        guard data.count > 44, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw XCTSkip("\(url.lastPathComponent) is not a RIFF file")
        }
        var offset = 12
        while offset + 8 <= data.count {
            let name = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(data[(offset + 4)..<(offset + 8)].withUnsafeBytes { $0.load(as: UInt32.self) })
            let body = offset + 8
            if name == "data" {
                var samples: [Double] = []
                samples.reserveCapacity(size / 2)
                var index = body
                while index + 1 < min(body + size, data.count) {
                    let value = Int16(bitPattern: data[index..<(index + 2)].withUnsafeBytes { $0.load(as: UInt16.self) })
                    samples.append(Double(value) / 32768)
                    index += 2
                }
                return samples
            }
            offset = body + size + (size % 2)
        }
        return []
    }

    /// The samples of a file through a hard compressor.
    ///
    /// A four to one ratio above -30 dBFS, with a five millisecond attack and a
    /// fifty millisecond release on the envelope, which is the shape the report
    /// describes: the quiet parts untouched and the loud ones levelled.
    static func compressed(_ samples: [Double], sampleRate: Double) -> [Double] {
        let threshold = pow(10, thresholdDBFS / 20)
        let attackCoefficient = exp(-1 / (attack * sampleRate))
        let releaseCoefficient = exp(-1 / (releaseSeconds * sampleRate))
        var envelope = 0.0
        var result: [Double] = []
        result.reserveCapacity(samples.count)
        for sample in samples {
            let magnitude = abs(sample)
            let coefficient = magnitude > envelope ? attackCoefficient : releaseCoefficient
            envelope = coefficient * envelope + (1 - coefficient) * magnitude
            guard envelope > threshold else {
                result.append(sample)
                continue
            }
            let gain = pow(threshold / envelope, 1 - 1 / ratio)
            result.append(sample * gain)
        }
        return result
    }

    /// One case: a file at a gain, or through the compressor.
    struct Case {
        let name: String
        let samples: [Double]
    }

    /// The measurement for one case.
    struct Measurement {
        let name: String
        let maxFloor: Double
        let medianDBFS: Double
        let gateAboveSeconds: Double
        let silentShare: Double
        let rows: [String]
    }

    /// Runs one case through the meter.
    ///
    /// - Parameters:
    ///   - testCase: the samples and their name.
    ///   - startFloor: the room the meter seeds its floor with, in dBFS.
    /// - Returns: what the floor did.
    static func measure(_ testCase: Case, startFloor: Double) -> Measurement {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        meter.seed(floor: startFloor)
        var rows: [String] = ["time_s,floor_dbfs,level,rms_dbfs"]
        var floors: [Double] = []
        var levels: [Double] = []
        var blockRMS: [Double] = []
        var gateAbove = 0.0
        var voiced = 0
        var voicedSilent = 0
        var perBlock: [(rms: Double, floor: Double, level: Double)] = []
        var frame = 0
        var index = 0
        while index < testCase.samples.count {
            let block = Array(testCase.samples[index..<min(index + blockFrames, testCase.samples.count)])
            index += blockFrames
            guard !block.isEmpty else { continue }
            let sumSquares = block.reduce(0) { $0 + $1 * $1 }
            let rms = (sumSquares / Double(block.count)).squareRoot()
            let decibels = AudioLevel.decibels(rms)
            blockRMS.append(decibels)
            for _ in 0..<repeats {
                let now = Double(frame) / rate
                meter.push(decibels: decibels, now: now)
                frame += 1
                let floor = meter.floorDBFS ?? LevelScale.floorDBFS
                floors.append(floor)
                levels.append(meter.level)
                rows.append(String(format: "%.4f,%.2f,%.5f,%.2f", now, floor, meter.level, decibels))
            }
            perBlock.append((decibels, meter.floorDBFS ?? LevelScale.floorDBFS, meter.level))
        }
        let sorted = perBlock.map(\.rms).sorted()
        let median = sorted.isEmpty ? -90 : sorted[sorted.count / 2]
        // A block is voiced when it is within three decibels of the median of this
        // reading, or louder: the files are continuous prose, so their median is
        // inside the voice and the pauses are the part below it.
        for block in perBlock where block.rms >= median - 3 {
            voiced += 1
            if LevelScale.gate(floor: block.floor) > median {
                gateAbove += Double(repeats) / rate
            }
            if block.level == 0 { voicedSilent += 1 }
        }
        return Measurement(
            name: testCase.name,
            maxFloor: floors.max() ?? 0,
            medianDBFS: median,
            gateAboveSeconds: gateAbove,
            silentShare: voiced == 0 ? 0 : Double(voicedSilent) / Double(voiced),
            rows: rows
        )
    }

    func testTheFloorOnSustainedSpeech() throws {
        guard let directory = Self.directory else {
            throw XCTSkip("DOT_FLOOR_DIR is not set")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".wav") }
            .sorted()
        XCTAssertGreaterThanOrEqual(files.count, 6, "the speech files are missing")
        var table: [String] = ["file,case,max_floor_dbfs,median_block_dbfs,gate_above_seconds,voiced_drawn_at_zero"]
        for name in files {
            let samples = try Self.samples(at: directory.appendingPathComponent(name))
            XCTAssertGreaterThan(samples.count, 16000, "\(name) is too short")
            let quietGain = pow(10, -20.0 / 20)
            let cases = [
                Case(name: "as-recorded", samples: samples),
                Case(name: "minus-20-db", samples: samples.map { $0 * quietGain }),
                Case(name: "compressed", samples: Self.compressed(samples, sampleRate: 16000)),
            ]
            for testCase in cases {
                let measured = Self.measure(testCase, startFloor: -54.13)
                print(String(
                    format: "FLOOR %@ %@ max floor %.2f dBFS, median block %.2f dBFS, gate above the median %.2f s, voiced drawn at zero %.3f",
                    name, testCase.name, measured.maxFloor, measured.medianDBFS,
                    measured.gateAboveSeconds, measured.silentShare
                ))
                table.append(String(
                    format: "%@,%@,%.2f,%.2f,%.2f,%.3f",
                    name, testCase.name, measured.maxFloor, measured.medianDBFS,
                    measured.gateAboveSeconds, measured.silentShare
                ))
                let csv = directory.appendingPathComponent("floor-\(name.replacingOccurrences(of: ".wav", with: ""))-\(testCase.name).csv")
                try measured.rows.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)
            }
        }
        try table.joined(separator: "\n").write(
            to: directory.appendingPathComponent("floor-table.csv"),
            atomically: true,
            encoding: .utf8
        )
        print("FLOOR table rows \(table.count - 1)")
    }
}
