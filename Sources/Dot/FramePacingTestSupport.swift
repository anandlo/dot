#if DEBUG
import Foundation

/// Hooks the environment-gated frame probes open.
///
/// Compiled only into DEBUG builds. Each one is a no-op until a probe test sets
/// its capture flag, so a normal debug run collects nothing and the shipped
/// frame recorder in `HUDFrameStatistics` carries the production numbers.
struct FramePacingTick {
    let time: Double
    let level: Double
    let phase: Double
    let clock: Double
    let bands: (Double, Double, Double, Double, Double)
    let sample: Int?
    let writtenSamples: Int
}

struct FramePacingDraw {
    let time: Double
    let duration: Double
    let count: Int
}

@MainActor
enum HUDTickProbe {
    static var captures = false
    static var ticks: [FramePacingTick] = []
    static var tickDurations: [Double] = []
    static var captureModel: ((HUDModel) -> Void)?

    static func reset() {
        captures = false
        ticks = []
        tickDurations = []
        captureModel = nil
    }

    static func recordDuration(_ ms: Double) {
        guard captures else { return }
        tickDurations.append(ms)
    }

    static func record(
        time: Double,
        level: Double,
        phase: Double,
        clock: Double,
        bands: (Double, Double, Double, Double, Double),
        sample: Int?,
        writtenSamples: Int,
        model: HUDModel
    ) {
        guard captures else { return }
        ticks.append(FramePacingTick(
            time: time,
            level: level,
            phase: phase,
            clock: clock,
            bands: bands,
            sample: sample,
            writtenSamples: writtenSamples
        ))
        captureModel?(model)
    }
}

@MainActor
enum BodyEvalProbe {
    static var captures = false
    static var count = 0

    static func reset() {
        captures = false
        count = 0
    }

    static func record() {
        guard captures else { return }
        count += 1
    }
}

@MainActor
enum FrameLeafProbe {
    static var captures = false
    static var waveformBodies = 0
    static var liveDotBodies = 0
    static var spinnerBodies = 0
    static var rewriteBodies = 0

    static func reset() {
        captures = false
        waveformBodies = 0
        liveDotBodies = 0
        spinnerBodies = 0
        rewriteBodies = 0
    }
}

enum CanvasDrawProbe {
    nonisolated(unsafe) static var capturesMatrix = false
    nonisolated(unsafe) static var matrixDraws: [FramePacingDraw] = []

    static func reset() {
        capturesMatrix = false
        matrixDraws = []
    }

    static func recordMatrix(duration: Double, dots: Int) {
        guard capturesMatrix else { return }
        matrixDraws.append(FramePacingDraw(
            time: CFAbsoluteTimeGetCurrent(),
            duration: duration,
            count: dots
        ))
    }
}
#endif
