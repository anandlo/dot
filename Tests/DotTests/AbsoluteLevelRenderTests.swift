import AppKit
import CryptoKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The pictures the two arithmetic changes are judged by.
///
/// Skipped unless `DOT_LEVEL_FRAMES_DIR` names a directory. The tree before the
/// change renders the same fixtures with its own copy of this harness, so the
/// comparison is two trees rather than one tree and a memory.
@MainActor
final class AbsoluteLevelRenderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    static let canvas = CGSize(width: 140, height: 26)
    static let scale = 2
    static let stripScale = 4
    static let tag = "after"
    static let loudnesses: [(name: String, decibels: Double)] = [
        ("quiet", -35), ("normal", -22), ("loud", -8),
    ]

    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOT_LEVEL_FRAMES_DIR"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// A steady voice, measured the way the card measures one, with the level in
    /// every band.
    static func steady(decibels: Double) -> (history: [Double], spectrum: [AudioSpectrumFrame], phase: Double, ceiling: Double, level: Double) {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        for step in 0...120 {
            meter.push(decibels: decibels, now: Double(step) / 60)
        }
        let history = meter.orderedHistory
        let level = history.last ?? 0
        let ring = [AudioSpectrumFrame](
            repeating: AudioSpectrumFrame(bands: (level, level, level, level, level)),
            count: VoiceMeter.historyLength
        )
        return (history, ring, meter.phase, meter.ceiling, level)
    }

    static func meanLuminance(_ bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 0.2126 * colour.redComponent + 0.7152 * colour.greenComponent + 0.0722 * colour.blueComponent
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    @discardableResult
    static func write(_ content: some View, named name: String, to directory: URL, size: CGSize, scale: Int) throws -> (url: URL, hash: String, luminance: Double) {
        let bitmap = try MatrixSlideTests.rasterise(content, size: size, scale: scale)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), "\(name) did not encode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        let luminance = meanLuminance(bitmap)
        print(String(format: "FRAME %@ %@ luminance %.6f", name, MatrixSlideTests.hash(data), luminance))
        return (url, MatrixSlideTests.hash(data), luminance)
    }

    func testTheFiveStylesAtThreeLoudnesses() throws {
        guard let directory = Self.directory else {
            throw XCTSkip("DOT_LEVEL_FRAMES_DIR is not set")
        }
        var measured: [String: Double] = [:]
        for visualizer in HUDVisualizer.allCases {
            for loudness in Self.loudnesses {
                let voice = Self.steady(decibels: loudness.decibels)
                let view = HUDWaveform(
                    visualizer: visualizer,
                    halfHeights: [],
                    history: voice.history,
                    spectrumHistory: voice.spectrum,
                    phase: voice.phase,
                    time: 3,
                    level: voice.level,
                    pulse: 0,
                    ceiling: voice.ceiling,
                    reveal: 1
                )
                let slug = MatrixSlideTests.slug(visualizer)
                let frame = try Self.write(
                    view,
                    named: "\(slug)-\(loudness.name)-\(Self.tag).png",
                    to: directory,
                    size: Self.canvas,
                    scale: Self.scale
                )
                measured["\(slug)-\(loudness.name)"] = frame.luminance
                print(String(format: "B5.3 %@ %@ level %.4f ceiling %.4f luminance %.6f",
                             slug, loudness.name, voice.level, voice.ceiling, frame.luminance))
            }
        }
        for visualizer in HUDVisualizer.allCases {
            let slug = MatrixSlideTests.slug(visualizer)
            let quiet = try XCTUnwrap(measured["\(slug)-quiet"])
            let normal = try XCTUnwrap(measured["\(slug)-normal"])
            let loud = try XCTUnwrap(measured["\(slug)-loud"])
            print(String(format: "B5.3 %@ quiet %.6f normal %.6f loud %.6f", slug, quiet, normal, loud))
            XCTAssertLessThan(quiet, normal, "\(slug) does not read louder at -22 dBFS than at -35")
            XCTAssertLessThan(normal, loud, "\(slug) does not read louder at -8 dBFS than at -22")
        }
    }

    func testTheMatrixFrames() throws {
        guard let directory = Self.directory else {
            throw XCTSkip("DOT_LEVEL_FRAMES_DIR is not set")
        }
        let feed = VisualizerFeed(from: DictationScript.speechStart - 2)
        var moment = feed.time
        while moment + 1.0 / 60 <= DictationScript.speechStart {
            moment += 1.0 / 60
            feed.advance(to: moment)
        }
        var frames: [HUDWaveform] = []
        for _ in 0..<12 {
            moment += 1.0 / 60
            feed.advance(to: moment)
            frames.append(HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: feed.history,
                spectrumHistory: feed.ring,
                phase: feed.phase,
                time: feed.time,
                ceiling: feed.meter.ceiling,
                reveal: 1
            ))
        }
        var table: [String] = ["frame,x,y,luminance"]
        let pitch = HUDWaveform.MatrixLattice.pitch(forHeight: Self.canvas.height)
        for (index, view) in frames.enumerated() {
            try Self.write(
                view,
                named: String(format: "matrix-strip-%@-%02d.png", Self.tag, index),
                to: directory,
                size: Self.canvas,
                scale: Self.stripScale
            )
            let bitmap = try MatrixSlideTests.rasterise(view, size: Self.canvas, scale: Self.stripScale)
            for column in [2, 8, 14, 20, 26] {
                for row in 0..<4 {
                    let place = (
                        x: Double(Self.canvas.width) - Double(pitch) / 2 - Double(column) * Double(pitch),
                        y: Double(HUDWaveform.MatrixLattice.centreY(row: row, forHeight: Self.canvas.height))
                    )
                    table.append(String(format: "%d,%.2f,%.2f,%.6f", index, place.x, place.y,
                                        MatrixSlideTests.luminance(bitmap, at: place, scale: Self.stripScale)))
                }
            }
            let dots = view.matrixDots(in: Self.canvas)
            print(String(format: "B6.2 frame %02d t %.4f dots %d energies %.4f...%.4f",
                         index, view.time, dots.count,
                         dots.map(\.energy).min() ?? 0, dots.map(\.energy).max() ?? 0))
        }
        let csv = directory.appendingPathComponent("matrix-luma-\(Self.tag).csv")
        try table.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)
        print("CSV \(csv.path) rows \(table.count - 1)")
    }
}
