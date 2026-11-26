import DotCore
import Foundation
import os

/// A fixed-size record of the frames of one recording.
///
/// The buffers are allocated once. A tick writes two numbers into them; no
/// array grows while the island is on screen. At the end one summary is made
/// and logged, with numbers only.
final class HUDFrameStatistics: @unchecked Sendable {
    struct Summary: Equatable, Sendable {
        let backend: String
        let frames: Int
        let intervalP50: Double
        let intervalP95: Double
        let intervalP99: Double
        let intervalMax: Double
        let over25ms: Int
        let over33ms: Int
        let tickP95: Double
        let tickMax: Double
        let liveMainMax: Double
        var wakeP95: Double = 0
        var wakeMax: Double = 0
        var wakeOver25ms: Int = 0
        var canvasDraws: Int = 0
        var canvasDrawP95: Double = 0
        var canvasDrawMax: Double = 0
        var canvasGapMax: Double = 0
        var canvasGapsOver25ms: Int = 0
    }

    private static let capacity = 3_600

    private let lock = OSAllocatedUnfairLock<Void>(initialState: ())
    private var intervals = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
    private var durations = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
    private var wakeDeltas = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
    private var canvasGaps = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
    private var canvasDurations = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
    private var cursor = 0
    private var stored = 0
    private var wakeCursor = 0
    private var wakeStored = 0
    private var canvasCursor = 0
    private var canvasStored = 0
    private var canvasTotal = 0
    private var lastCanvasTimestamp: CFTimeInterval?
    private var backendName = HUDRenderLoop.Backend.timer.rawValue
    private var liveMainMaxMS = 0.0
    private var active = false

    /// Whether a recording is being measured.
    var isRecording: Bool { lock.withLock { active } }

    /// Starts a new recording's window.
    func start(backend: String) {
        lock.withLock {
            intervals = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
            durations = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
            wakeDeltas = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
            canvasGaps = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
            canvasDurations = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
            cursor = 0
            stored = 0
            wakeCursor = 0
            wakeStored = 0
            canvasCursor = 0
            canvasStored = 0
            canvasTotal = 0
            lastCanvasTimestamp = nil
            backendName = backend
            liveMainMaxMS = 0
            active = true
        }
    }

    /// Records a backend change during this presentation.
    func note(backend: String) {
        lock.withLock {
            guard active else { return }
            backendName = backend
        }
    }

    /// Records one frame.
    func record(intervalMS: Double, durationMS: Double, wakeDeltaMS: Double? = nil) {
        lock.withLock {
            guard active else { return }
            intervals[cursor] = intervalMS
            durations[cursor] = durationMS
            cursor = (cursor + 1) % HUDFrameStatistics.capacity
            stored = min(stored + 1, HUDFrameStatistics.capacity)
            if let wakeDeltaMS {
                wakeDeltas[wakeCursor] = wakeDeltaMS
                wakeCursor = (wakeCursor + 1) % HUDFrameStatistics.capacity
                wakeStored = min(wakeStored + 1, HUDFrameStatistics.capacity)
            }
        }
    }

    /// Records one completed Canvas draw pass and its gap from the previous draw.
    func recordCanvasDraw(now: CFTimeInterval, durationMS: Double) {
        lock.withLock {
            guard active else { return }
            canvasTotal += 1
            let gapMS: Double
            if let lastCanvasTimestamp {
                gapMS = max(0, (now - lastCanvasTimestamp) * 1000)
            } else {
                gapMS = 0
            }
            lastCanvasTimestamp = now
            canvasGaps[canvasCursor] = gapMS
            canvasDurations[canvasCursor] = durationMS
            canvasCursor = (canvasCursor + 1) % HUDFrameStatistics.capacity
            canvasStored = min(canvasStored + 1, HUDFrameStatistics.capacity)
        }
    }

    /// The longest main-actor slice of a live-transcription attempt.
    func recordLiveMain(ms: Double) {
        lock.withLock {
            guard active else { return }
            liveMainMaxMS = max(liveMainMaxMS, ms)
        }
    }

    /// Ends the window, returns its summary and logs it once.
    @discardableResult
    func finish() -> Summary? {
        let finished: Summary? = lock.withLock {
            guard active else { return nil }
            active = false
            return currentLocked()
        }
        guard let summary = finished else { return nil }
        var fields: [String: LogValue] = [
            "backend": .string(summary.backend),
            "frames": .int(summary.frames),
            "interval_p50_ms": .double(summary.intervalP50),
            "interval_p95_ms": .double(summary.intervalP95),
            "interval_p99_ms": .double(summary.intervalP99),
            "interval_max_ms": .double(summary.intervalMax),
            "over_25_ms": .int(summary.over25ms),
            "over_33_ms": .int(summary.over33ms),
            "tick_p95_ms": .double(summary.tickP95),
            "tick_max_ms": .double(summary.tickMax),
            "live_main_max_ms": .double(summary.liveMainMax),
        ]
        if summary.wakeMax > 0 || summary.wakeOver25ms > 0 {
            fields["wake_p95_ms"] = .double(summary.wakeP95)
            fields["wake_max_ms"] = .double(summary.wakeMax)
            fields["wake_over_25_ms"] = .int(summary.wakeOver25ms)
        }
        if summary.canvasDraws > 0 {
            fields["canvas_draws"] = .int(summary.canvasDraws)
            fields["canvas_draw_p95_ms"] = .double(summary.canvasDrawP95)
            fields["canvas_draw_max_ms"] = .double(summary.canvasDrawMax)
            fields["canvas_gap_max_ms"] = .double(summary.canvasGapMax)
            fields["canvas_gaps_over_25_ms"] = .int(summary.canvasGapsOver25ms)
        }
        Log.shared.info("hud.frames", fields)
        return summary
    }

    /// The statistics of the current window, without ending it.
    func current() -> Summary {
        lock.withLock {
            currentLocked()
        }
    }

    private func currentLocked() -> Summary {
        let frames = Array(intervals[0..<stored])
        let ticks = Array(durations[0..<stored])
        let wakes = Array(wakeDeltas[0..<wakeStored])
        let gaps = Array(canvasGaps[0..<canvasStored])
        let draws = Array(canvasDurations[0..<canvasStored])
        return Summary(
            backend: backendName,
            frames: stored,
            intervalP50: Self.percentile(frames, 0.50),
            intervalP95: Self.percentile(frames, 0.95),
            intervalP99: Self.percentile(frames, 0.99),
            intervalMax: frames.max() ?? 0,
            over25ms: frames.filter { $0 > 25 }.count,
            over33ms: frames.filter { $0 > 33 }.count,
            tickP95: Self.percentile(ticks, 0.95),
            tickMax: ticks.max() ?? 0,
            liveMainMax: liveMainMaxMS,
            wakeP95: Self.percentile(wakes, 0.95),
            wakeMax: wakes.max() ?? 0,
            wakeOver25ms: wakes.filter { $0 > 25 }.count,
            canvasDraws: canvasTotal,
            canvasDrawP95: Self.percentile(draws, 0.95),
            canvasDrawMax: draws.max() ?? 0,
            canvasGapMax: gaps.max() ?? 0,
            canvasGapsOver25ms: gaps.filter { $0 > 25 }.count
        )
    }

    /// The nearest-rank percentile of known values.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = min(sorted.count - 1, max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[rank]
    }
}
