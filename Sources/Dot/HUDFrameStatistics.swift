import DotCore
import Foundation

/// A fixed-size record of the frames of one recording.
///
/// The buffers are allocated once. A tick writes two numbers into them; no
/// array grows while the island is on screen. At the end one summary is made
/// and logged, with numbers only.
@MainActor
final class HUDFrameStatistics {
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
    }

    private static let capacity = 3_600

    private var intervals = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
    private var durations = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
    private var cursor = 0
    private var stored = 0
    private var backendName = HUDRenderLoop.Backend.timer.rawValue
    private var liveMainMaxMS = 0.0
    private var active = false

    /// Whether a recording is being measured.
    var isRecording: Bool { active }

    /// Starts a new recording's window.
    func start(backend: String) {
        intervals = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
        durations = [Double](repeating: 0, count: HUDFrameStatistics.capacity)
        cursor = 0
        stored = 0
        backendName = backend
        liveMainMaxMS = 0
        active = true
    }

    /// Records a backend change during this presentation.
    func note(backend: String) {
        guard active else { return }
        backendName = backend
    }

    /// Records one frame.
    func record(intervalMS: Double, durationMS: Double) {
        guard active else { return }
        intervals[cursor] = intervalMS
        durations[cursor] = durationMS
        cursor = (cursor + 1) % HUDFrameStatistics.capacity
        stored = min(stored + 1, HUDFrameStatistics.capacity)
    }

    /// The longest main-actor slice of a live-transcription attempt.
    func recordLiveMain(ms: Double) {
        guard active else { return }
        liveMainMaxMS = max(liveMainMaxMS, ms)
    }

    /// Ends the window, returns its summary and logs it once.
    @discardableResult
    func finish() -> Summary? {
        guard active else { return nil }
        active = false
        let summary = current()
        Log.shared.info("hud.frames", [
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
        ])
        return summary
    }

    /// The statistics of the current window, without ending it.
    func current() -> Summary {
        let frames = Array(intervals[0..<stored])
        let ticks = Array(durations[0..<stored])
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
            liveMainMax: liveMainMaxMS
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
