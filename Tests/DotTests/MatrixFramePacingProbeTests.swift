import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CryptoKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// Offscreen measurements of the Matrix recording visualizer.
///
/// Every image is rasterised from a SwiftUI hosting view into memory. No audio
/// hardware is opened: the audio path is driven by synthetic PCM buffers of the
/// tap's real size. No window is placed inside a display; the one hosted window
/// uses ``OffscreenWindow`` at its off-screen origin.
@MainActor
final class MatrixFramePacingProbeTests: XCTestCase {
    private nonisolated static var evidenceDirectory: String? {
        ProcessInfo.processInfo.environment["DOT_FRAME_PACING_DIR"]
    }

    private nonisolated static var evidence: URL {
        URL(fileURLWithPath: evidenceDirectory!, isDirectory: true)
    }

    override func setUpWithError() throws {
        try XCTSkipIf(
            Self.evidenceDirectory == nil,
            "DOT_FRAME_PACING_DIR is not set"
        )
        super.setUp()
        FontFixture.register()
        try FileManager.default.createDirectory(
            at: Self.evidence,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Live recording

    func testLiveRecordingCadenceInputAndFrameStrip() throws {
        let feed = try SyntheticTapFeed(rate: 48_000, framesPerBuffer: 1024)
        let hud = HUD(offscreen: true)
        hud.visualizer = .matrix
        hud.material = .black
        hud.debugSetReduceMotion(false)

        var providerTimes: [Double] = []
        var providerLevels: [Double] = []
        var providerSpectra: [AudioSpectrumFrame] = []
        hud.setLevelProvider {
            providerTimes.append(CFAbsoluteTimeGetCurrent())
            let value = feed.currentLevel
            providerLevels.append(value)
            return value
        }
        hud.setSpectrumProvider {
            let value = feed.currentSpectrum
            providerSpectra.append(value)
            return value
        }

        HUDTickProbe.reset()
        HUDTickProbe.captures = true
        BodyEvalProbe.reset()
        BodyEvalProbe.captures = true
        var snapshots: [HUDModel] = []
        HUDTickProbe.captureModel = { snapshots.append(Self.copyModel($0)) }

        var invalidations = 0
        var cancellables: [AnyCancellable] = []
        cancellables.append(hud.debugModel.objectWillChange.sink { _ in
            invalidations += 1
        })

        hud.showRecording(elapsed: "0:00")

        var labelTimes: [Double] = []
        var labelCosts: [Double] = []
        let tickerStart = CFAbsoluteTimeGetCurrent()
        let ticker = DispatchSource.makeTimerSource(queue: .main)
        ticker.schedule(deadline: .now() + 1.0 / 30.0, repeating: 1.0 / 30.0)
        ticker.setEventHandler {
            let started = CFAbsoluteTimeGetCurrent()
            hud.updateRecording(elapsed: HUDClock.string(for: started - tickerStart))
            labelCosts.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
            labelTimes.append(started)
        }
        ticker.resume()
        invalidations = 0

        feed.start()
        spin(for: 10)
        feed.stop()
        ticker.cancel()
        spin(for: 0.1)

        let ticks = HUDTickProbe.ticks
        let tickDurations = HUDTickProbe.tickDurations
        let bodyEvaluations = BodyEvalProbe.count
        HUDTickProbe.captures = false
        HUDTickProbe.captureModel = nil
        BodyEvalProbe.captures = false
        let writes = feed.writes()
        hud.hide()

        XCTAssertGreaterThan(ticks.count, 100, "the recording HUD did not produce a usable sample")
        XCTAssertGreaterThan(writes.count, 100, "the synthetic tap did not produce a usable sample")

        let intervals = Self.intervals(ticks.map(\.time))
        let levelChanges = Self.changes(ticks.map(\.level))
        let phaseChanges = Self.changes(ticks.map(\.phase))
        let clockChanges = Self.changes(ticks.map(\.clock))
        let bandChanges = Self.changes(ticks.map { AudioSpectrumFrame(bands: $0.bands) })
        let stampChanges = Self.changes(ticks.map(\.sample))
        let writtenChanges = Self.changes(ticks.map(\.writtenSamples))
        let rawLevelChanges = Self.changes(providerLevels)
        let rawSpectrumChanges = Self.changes(providerSpectra)
        let writeIntervals = Self.intervals(writes.map(\.time))

        let stripStart = max(0, min(snapshots.count - 12, snapshots.count / 2))
        let stripModels = Array(snapshots[stripStart..<(stripStart + 12)])
        var hashes: [String] = []
        for (index, model) in stripModels.enumerated() {
            let view = HUD.rootView(
                model: model,
                actions: HUDPreview.previewActions,
                animated: false,
                placement: nil,
                size: HUD.panelSize
            )
            let data = try Self.png(
                of: view,
                size: HUD.panelSize,
                scale: 2,
                name: String(format: "frame_%02d.png", index)
            )
            hashes.append(Self.sha256(data))
        }
        let identical = Self.identicalPairs(hashes)
        let sheet = try Self.contactSheet(
            directory: Self.evidence,
            scale: 2,
            columns: 4
        )
        try Self.writeJSON("live-hud-cadence.json", [
            "surface": "live HUD recording card, Matrix, material .black",
            "sample_seconds": 10,
            "ticks": ticks.count,
            "tick_intervals_ms": Self.stats(intervals),
            "tick_duration_ms": Self.stats(tickDurations),
            "view": [
                "body_evaluations": bodyEvaluations,
                "body_evals_per_tick": Double(bodyEvaluations) / Double(max(1, ticks.count)),
            ],
            "tick_state_changes": [
                "level": levelChanges,
                "phase": phaseChanges,
                "clock": clockChanges,
                "spectrum_bands": bandChanges,
                "spectrum_stamp": stampChanges,
                "meter_written_samples": writtenChanges,
            ],
            "provider_reads": providerTimes.count,
            "provider_level_changes": rawLevelChanges,
            "provider_spectrum_changes": rawSpectrumChanges,
            "model": [
                "object_will_change_events": invalidations,
                "events_per_tick": Double(invalidations) / Double(max(1, ticks.count)),
            ],
            "recorder_ticker": [
                "scheduled_hz": 30,
                "updates": labelTimes.count,
                "observed_hz": Double(labelTimes.count) / 10.0,
                "intervals_ms": Self.stats(Self.intervals(labelTimes)),
                "update_cost_ms": Self.stats(labelCosts),
            ],
            "input": [
                "buffer_frames": 1024,
                "sample_rate_hz": 48_000,
                "theoretical_update_hz": 48_000.0 / 1024.0,
                "observed_writes": writes.count,
                "observed_update_hz": Double(writes.count) / 10.0,
                "write_intervals_ms": Self.stats(writeIntervals),
            ],
            "frame_strip": [
                "directory": Self.evidence.path,
                "frames": 12,
                "display_scale": 2,
                "hashes": hashes,
                "identical_pairs": identical,
            ],
            "contact_sheet": sheet,
        ])
    }

    // MARK: - Live transcription

    /// The wall time of one live-transcription iteration body, measured on the
    /// actor that runs it today: open-buffer copy, VAD decision and WAV.
    func testLiveTranscriptionPreparationCost() throws {
        let durations = [10, 30, 60]
        let iterations = 50
        var buffers: [String: Any] = [:]

        for seconds in durations {
            let samples = MatrixProbeSpeech.samples(seconds: seconds, seed: 0x5eed)
            let store = AudioSampleStore()
            _ = store.append(samples, from: store.currentGeneration)
            let ledger = TranscriptLedger(commitSeconds: 60)

            var costs: [Double] = []
            var plans = 0
            var wavBytes = 0
            for _ in 0..<iterations {
                let started = CFAbsoluteTimeGetCurrent()
                let work = LiveTranscriptionWork.prepare(
                    ledger: ledger,
                    sampleCount: store.count,
                    store: store,
                    noiseFloorDBFS: -42
                )
                costs.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                if work.plan != nil { plans += 1 }
                wavBytes = work.request?.wav.count ?? 0
            }

            buffers["\(seconds)s"] = [
                "samples": samples.count,
                "iterations": iterations,
                "wall_ms": Self.stats(costs),
                "plans_found": plans,
                "wav_bytes": wavBytes,
            ]
        }

        try Self.writeJSON("live-transcription-preparation.json", [
            "surface": "live transcription iteration body",
            "caller": "the actor running the live loop",
            "buffers": buffers,
        ])
    }

    /// Main-actor time after the analysis moved to its own executor: the
    /// synchronous spans before and after the await, summed, over 50 attempts.
    func testLiveTranscriptionMainActorCostAfterOffload() async throws {
        let durations = [10, 30, 60]
        let iterations = 50
        let hud = HUD(offscreen: true)
        var buffers: [String: Any] = [:]

        for seconds in durations {
            let samples = MatrixProbeSpeech.samples(seconds: seconds, seed: 0x5eed)
            let store = AudioSampleStore()
            _ = store.append(samples, from: store.currentGeneration)
            let floor = -42.0
            var costs: [Double] = []

            for _ in 0..<iterations {
                let first = CFAbsoluteTimeGetCurrent()
                let ledger = TranscriptLedger(commitSeconds: 60)
                let committed = ledger.committedSamples
                let sampleCount = store.count
                let preWait = CFAbsoluteTimeGetCurrent() - first

                let prepared = await LiveTranscriptionAnalyzer.shared.prepare(
                    ledger: ledger,
                    sampleCount: sampleCount,
                    store: store,
                    noiseFloorDBFS: floor
                )
                let second = CFAbsoluteTimeGetCurrent()
                var applied = ledger
                if let request = prepared.request {
                    if request.isCommit {
                        applied.commit(range: committed..<request.commitUpTo, text: "word")
                    } else {
                        applied.recordProvisional(range: request.range, text: "word")
                    }
                }
                hud.showLiveText(applied.displayText)
                costs.append((preWait + (CFAbsoluteTimeGetCurrent() - second)) * 1000)
            }

            buffers["\(seconds)s"] = [
                "samples": samples.count,
                "iterations": iterations,
                "main_actor_ms": Self.stats(costs),
            ]
        }

        try Self.writeJSON("live-transcription-main-actor.json", [
            "surface": "live transcription main-actor body after offload",
            "measurement": "synchronous spans around the await, summed",
            "buffers": buffers,
        ])
    }

    // MARK: - Draw cost

    func testMatrixDrawCostOver600Frames() throws {
        let feed = VisualizerFeed()
        feed.advance(to: 2)
        let model = HUDModel()
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        model.isVisible = true
        model.presence = 1
        model.emergence = 1
        model.content = 1
        model.reveal = 1
        model.visualizer = .matrix
        model.material = .black
        model.level = 0.68
        model.ceiling = 1
        model.pulse = 0.25

        CanvasDrawProbe.reset()
        CanvasDrawProbe.capturesMatrix = true
        var raster: [Double] = []
        for index in 0..<600 {
            let moment = 2 + Double(index) / 60
            feed.advance(to: moment)
            model.history = feed.history
            model.spectrumHistory = feed.ring
            model.phase = feed.phase
            model.time = feed.time
            let view = HUD.rootView(
                model: model,
                actions: HUDPreview.previewActions,
                animated: false,
                placement: nil,
                size: HUD.panelSize
            )
            let started = CFAbsoluteTimeGetCurrent()
            _ = try Self.rasterise(view, size: HUD.panelSize, scale: 2)
            raster.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }

        let draws = CanvasDrawProbe.matrixDraws
        CanvasDrawProbe.capturesMatrix = false
        XCTAssertEqual(draws.count, 600, "the card did not draw one Matrix canvas per frame")

        try Self.writeJSON("draw-cost.json", [
            "frames": 600,
            "display_scale": 2,
            "full_hud_card_raster_ms": Self.stats(raster),
            "draw_matrix_ms": Self.stats(draws.map { $0.duration * 1000 }),
            "dots_per_frame": Self.stats(draws.map { Double($0.count) }),
        ])
    }

    func testRenderCostControls() throws {
        let feed = VisualizerFeed()
        feed.advance(to: 2)
        let model = HUDModel()
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        model.isVisible = true
        model.presence = 1
        model.emergence = 1
        model.content = 1
        model.reveal = 1
        model.material = .black
        model.level = 0.68
        model.ceiling = 1
        model.pulse = 0.25

        var empty: [Double] = []
        for _ in 0..<60 {
            let started = CFAbsoluteTimeGetCurrent()
            _ = try Self.rasterise(Color.clear, size: HUD.panelSize, scale: 2)
            empty.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }

        var stretch: [Double] = []
        model.visualizer = .stretch
        for index in 0..<60 {
            let moment = 2 + Double(index) / 60
            feed.advance(to: moment)
            model.history = feed.history
            model.spectrumHistory = feed.ring
            model.phase = feed.phase
            model.time = feed.time
            let view = HUD.rootView(
                model: model,
                actions: HUDPreview.previewActions,
                animated: false,
                placement: nil,
                size: HUD.panelSize
            )
            let started = CFAbsoluteTimeGetCurrent()
            _ = try Self.rasterise(view, size: HUD.panelSize, scale: 2)
            stretch.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }

        var matrixWaveform: [Double] = []
        let waveformSize = CGSize(width: 120, height: HUDTheme.waveformHeight)
        for index in 0..<60 {
            let moment = 2 + Double(index) / 60
            feed.advance(to: moment)
            let view = HUDWaveform(
                visualizer: .matrix,
                halfHeights: [],
                history: feed.history,
                spectrumHistory: feed.ring,
                phase: feed.phase,
                time: feed.time,
                level: 0.68,
                ceiling: 1,
                reveal: 1,
                material: .black
            )
            let started = CFAbsoluteTimeGetCurrent()
            _ = try Self.rasterise(view, size: waveformSize, scale: 2)
            matrixWaveform.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }

        try Self.writeJSON("render-cost-controls.json", [
            "frames_per_control": 60,
            "display_scale": 2,
            "empty_panel_raster_ms": Self.stats(empty),
            "full_card_stretch_raster_ms": Self.stats(stretch),
            "matrix_waveform_only_raster_ms": Self.stats(matrixWaveform),
        ])
    }

    // MARK: - Pixel identity

    /// Twelve fixed frames of every visualizer, rendered from one synthetic
    /// feed. The stage-2 change must produce byte-identical pixels.
    func testVisualizerFrameStrip() throws {
        let root = Self.evidence.appendingPathComponent("pixels", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var manifest: [String: Any] = [:]

        for visualizer in HUDVisualizer.allCases {
            let directory = root.appendingPathComponent(visualizer.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let feed = VisualizerFeed()
            feed.advance(to: 2)
            let model = HUDModel()
            model.mode = .recording(elapsed: "0:07")
            model.cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
            model.isVisible = true
            model.presence = 1
            model.emergence = 1
            model.content = 1
            model.reveal = 1
            model.visualizer = visualizer
            model.material = .black
            model.level = 0.68
            model.ceiling = 1
            model.pulse = 0.25
            model.shimmer = 0.45
            model.time = 2

            var hashes: [String] = []
            for index in 0..<12 {
                let moment = 2 + Double(index) / 60
                feed.advance(to: moment)
                model.history = feed.history
                model.spectrumHistory = feed.ring
                model.halfHeights = []
                model.phase = feed.phase
                model.time = moment
                let view = HUD.rootView(
                    model: model,
                    actions: HUDPreview.previewActions,
                    animated: false,
                    placement: nil,
                    size: HUD.panelSize
                )
                let data = try Self.pngData(of: view, size: HUD.panelSize, scale: 2)
                try data.write(
                    to: directory.appendingPathComponent(String(format: "frame_%02d.png", index)),
                    options: .atomic
                )
                hashes.append(Self.sha256(data))
            }
            manifest[visualizer.rawValue] = hashes
        }

        try Self.writeJSON("visualizer-frame-strip.json", [
            "material": "black",
            "display_scale": 2,
            "frames_per_visualizer": 12,
            "directory": root.path,
            "hashes": manifest,
        ])
    }

    /// The card states whose shadow is moved off the content composite.
    func testStateStripForShadowChange() throws {
        let root = Self.evidence.appendingPathComponent("state-pixels", isDirectory: true)
        var manifest: [String: Any] = [:]
        let states: [(HUDPreview.State, HUDVisualizer, String)] = [
            (.recording, .matrix, "recording-matrix"),
            (.recording, .stretch, "recording-wave"),
            (.transcript, .stretch, "transcript"),
            (.message, .stretch, "message"),
        ]
        for material in [HUDMaterial.black, .glass] {
            let directory = root.appendingPathComponent(material.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var hashes: [String: Any] = [:]
            for (state, visualizer, name) in states {
                let bitmap = try HUDPreview.render(
                    state: state,
                    visualizer: visualizer,
                    material: material
                )
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw TestError.encoding
                }
                try data.write(
                    to: directory.appendingPathComponent("\(name).png"),
                    options: .atomic
                )
                hashes[name] = Self.sha256(data)
            }
            manifest[material.rawValue] = hashes
        }
        try Self.writeJSON("state-strip.json", [
            "display_scale": 2,
            "directory": root.path,
            "hashes": manifest,
        ])
    }


}

extension MatrixFramePacingProbeTests {
    // MARK: - Run loop and files

    func spin(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.02))
            )
        }
    }

    static func writeJSON(_ name: String, _ object: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: evidence.appendingPathComponent(name), options: .atomic)
    }

    static func png(
        of view: some View,
        size: CGSize,
        scale: Int,
        name: String
    ) throws -> Data {
        let data = try pngData(of: view, size: size, scale: scale)
        try data.write(to: evidence.appendingPathComponent(name), options: .atomic)
        return data
    }

    static func pngData(of view: some View, size: CGSize, scale: Int) throws -> Data {
        let bitmap = try rasterise(view, size: size, scale: scale)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw TestError.encoding
        }
        return data
    }

    static func rasterise(_ view: some View, size: CGSize, scale: Int) throws -> NSBitmapImageRep {
        let hosted = view
            .frame(width: size.width, height: size.height)
            .environment(\.displayScale, CGFloat(scale))
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: hosted)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw TestError.bitmap }
        bitmap.size = size
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        return bitmap
    }

    static func contactSheet(directory: URL, scale: Int, columns: Int) throws -> String {
        let thumbWidth = 320
        let thumbHeight = 170
        let gap = 4
        let rows = 3
        let width = columns * thumbWidth + (columns + 1) * gap
        let height = rows * thumbHeight + (rows + 1) * gap
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError.bitmap }
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.08, 0.08, 0.09, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for index in 0..<12 {
            let url = directory.appendingPathComponent(String(format: "frame_%02d.png", index))
            guard let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data),
                  let image = rep.cgImage
            else { throw TestError.encoding }
            let column = index % columns
            let row = index / columns
            let x = gap + column * (thumbWidth + gap)
            let y = height - gap - (row + 1) * thumbHeight - row * gap
            context.draw(image, in: CGRect(x: x, y: y, width: thumbWidth, height: thumbHeight))
        }
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw TestError.encoding }
        let url = directory.appendingPathComponent("contact-sheet.png")
        try data.write(to: url, options: .atomic)
        return url.path
    }

    enum TestError: Error {
        case bitmap
        case encoding
    }

    // MARK: - Arithmetic

    static func intervals(_ times: [Double]) -> [Double] {
        zip(times, times.dropFirst()).map { ($1 - $0) * 1000 }
    }

    static func stats(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else {
            return [
                "count": 0,
                "mean": 0,
                "p50": 0,
                "p95": 0,
                "p99": 0,
                "max": 0,
                "over_20_ms": 0,
                "over_33_ms": 0,
            ]
        }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        func percentile(_ fraction: Double) -> Double {
            let rank = min(sorted.count - 1, max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1))
            return sorted[rank]
        }
        return [
            "count": values.count,
            "mean": mean,
            "p50": percentile(0.50),
            "p95": percentile(0.95),
            "p99": percentile(0.99),
            "max": sorted.last ?? 0,
            "over_20_ms": values.filter { $0 > 20 }.count,
            "over_33_ms": values.filter { $0 > 33 }.count,
        ]
    }

    static func changes<T: Equatable>(_ values: [T]) -> Int {
        zip(values, values.dropFirst()).filter { $0 != $1 }.count
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func identicalPairs(_ hashes: [String]) -> [[Int]] {
        var pairs: [[Int]] = []
        for first in hashes.indices {
            for second in hashes.indices where second > first {
                if hashes[first] == hashes[second] { pairs.append([first, second]) }
            }
        }
        return pairs
    }

    // MARK: - Model snapshot

    static func copyModel(_ model: HUDModel) -> HUDModel {
        let copy = HUDModel()
        copy.mode = model.mode
        copy.cardSize = model.cardSize
        copy.liveText = model.liveText
        copy.isVisible = model.isVisible
        copy.presence = model.presence
        copy.emergence = model.emergence
        copy.content = model.content
        copy.level = model.level
        copy.ceiling = model.ceiling
        copy.reveal = model.reveal
        copy.halfHeights = model.halfHeights
        copy.history = model.history
        copy.spectrumHistory = model.spectrumHistory
        copy.phase = model.phase
        copy.time = model.time
        copy.visualizer = model.visualizer
        copy.material = model.material
        copy.pulse = model.pulse
        copy.shimmer = model.shimmer
        copy.workingDetail = model.workingDetail
        copy.activeService = model.activeService
        copy.activeKeyHint = model.activeKeyHint
        copy.hoveredAction = model.hoveredAction
        copy.messageAction = model.messageAction
        copy.grammar = model.grammar
        copy.grammarWasLong = model.grammarWasLong
        copy.isEditingTranscript = model.isEditingTranscript
        copy.rewrite = model.rewrite
        copy.rewriteEnding = model.rewriteEnding
        return copy
    }
}

/// Synthetic PCM at the recorder's tap size, measured by the real tap processor.
///
/// The processor, the analyser and the resampler are the production ones. Only
/// the source of the samples is replaced: a generated buffer stands in for the
/// microphone and no audio engine is started.
final class SyntheticTapFeed: @unchecked Sendable {
    struct Write {
        let time: Double
        let level: Double
        let spectrum: AudioSpectrumFrame
    }

    let rate: Double
    let framesPerBuffer: Int
    private let format: AVAudioFormat
    private let processor: AudioTapProcessor
    private let lock = NSLock()
    private var stopped = false
    private var records: [Write] = []

    init(rate: Double, framesPerBuffer: Int) throws {
        self.rate = rate
        self.framesPerBuffer = framesPerBuffer
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
                channels: 1,
                interleaved: false
            )
        )
        self.format = format
        let store = AudioSampleStore()
        processor = AudioTapProcessor(
            resampler: try Resampler(inputFormat: format),
            store: store,
            generation: store.currentGeneration
        )
    }

    var currentLevel: Double { processor.level }
    var currentSpectrum: AudioSpectrumFrame { processor.spectrum }

    func start() {
        Thread.detachNewThread { [self] in
            let started = CFAbsoluteTimeGetCurrent()
            var index = 0
            while !isStopped {
                processor.handle(buffer(at: index))
                let level = processor.level
                let spectrum = processor.spectrum
                lock.lock()
                records.append(Write(time: CFAbsoluteTimeGetCurrent(), level: level, spectrum: spectrum))
                lock.unlock()
                index += 1
                let target = started + Double(index) * Double(framesPerBuffer) / rate
                let delay = target - CFAbsoluteTimeGetCurrent()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func writes() -> [Write] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func buffer(at index: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(framesPerBuffer)
        )!
        buffer.frameLength = AVAudioFrameCount(framesPerBuffer)
        let channel = buffer.floatChannelData![0]
        let start = Double(index) * Double(framesPerBuffer) / rate
        let syllable = 0.5 + 0.5 * sin(2 * Double.pi * 2.3 * start)
        let word = 0.3 + 0.7 * pow(max(0, sin(2 * Double.pi * 0.55 * start)), 0.7)
        let amplitude = 0.02 + 0.4 * syllable * word
        let fundamental = 140 + 60 * sin(2 * Double.pi * 0.7 * start)
        for frame in 0..<framesPerBuffer {
            let t = Double(frame) / rate
            let sample = amplitude * (
                sin(2 * Double.pi * fundamental * t)
                    + 0.35 * sin(2 * Double.pi * 950 * t)
                    + 0.15 * sin(2 * Double.pi * 2400 * t)
            )
            channel[frame] = Float(max(-1, min(1, sample)))
        }
        return buffer
    }
}
