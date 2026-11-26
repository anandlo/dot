import DotCore
import Foundation
import Observation

/// The values the card changes on every frame.
///
/// Keeping them out of ``HUDModel`` lets the leaves that draw a waveform or a
/// dot observe only what they read. A change to the level does not rebuild the
/// whole card, and a change to the transcript does not redraw the canvas.
@Observable
@MainActor
final class HUDFrameModel {
    /// The level of the voice, from `0` to `1`.
    @ObservationIgnored var level: Double = 0
    /// The loudest moment of the recording so far, from `0` to `1`.
    @ObservationIgnored var ceiling: Double = 1
    /// Where the speaker's loud speech sits in the meter window.
    @ObservationIgnored var speechTop: Double = VoiceMeter.defaultSpeechTop
    /// ``speechTop`` as it was at each sample of ``history``, oldest first.
    @ObservationIgnored var speechTops: [Double] = []
    /// How much of the shape has arrived, from `0` to `1`.
    @ObservationIgnored var reveal: Double = 0
    /// The half height of every column of the waveform, in points.
    @ObservationIgnored var halfHeights: [CGFloat] = []
    /// The raw 60 Hz envelope history, oldest first (`0` to `1`).
    @ObservationIgnored var history: [Double] = []
    /// Real-time 60 Hz five-band spectrum history, oldest first.
    @ObservationIgnored var spectrumHistory: [AudioSpectrumFrame] = []
    /// Where inside the current sample period the meter sits (`0` to `<1`).
    @ObservationIgnored var phase: Double = 0
    /// Continuous unwrapped elapsed time in seconds.
    @ObservationIgnored var time: Double = 0
    /// The phase of the live dot's pulse, from `0` to `1`.
    @ObservationIgnored var pulse: Double = 0
    /// Elapsed time observed only by `FrameRewriteIdentity` during active rewrites.
    var rewriteTime: Double = 0
    /// The phase of the transcribing label's shimmer, from `0` to `1`.
    var shimmer: Double = 0
    /// How far the shape has come out of the notch, from `0` to `1` and past it on overshoot.
    var emergence: Double = 0
    /// How present the card is, clamped to `0...1`.
    var presence: Double = 0
    /// How settled the card's content is, clamped to `0...1`.
    var content: Double = 0
    /// The formatted recording clock string, updated directly by the render loop.
    var elapsedLabel: String = "0:00"
    /// Live partial dictation text while recording, updated without invalidating `HUDModel`.
    var liveText: String = ""
    /// Direct frame sink pushing frames into the live CoreAnimation waveform layer.
    @ObservationIgnored let visualizerSink = VisualizerFrameSink()
    /// Direct frame sink pushing frames into the live CoreAnimation dot layer.
    @ObservationIgnored let liveDotSink = LiveDotSink()

    func currentVisualizerFrame(
        visualizer: HUDVisualizer,
        material: HUDMaterial,
        reduceMotion: Bool,
        glassRingLift: Double = HUDWaveform.Halo.glassRingLift,
        glassRingInkGain: Double = HUDWaveform.Halo.glassRingInkGain
    ) -> VisualizerFrame {
        VisualizerFrame(
            visualizer: visualizer,
            material: material,
            history: history,
            spectrumHistory: spectrumHistory,
            time: time,
            level: level,
            phase: phase,
            pulse: pulse,
            ceiling: ceiling,
            speechTop: speechTop,
            speechTops: speechTops,
            reveal: reveal,
            reduceMotion: reduceMotion,
            highlight: true,
            glassRingLift: glassRingLift,
            glassRingInkGain: glassRingInkGain
        )
    }

    func currentLiveDotFrame(material: HUDMaterial, reduceMotion: Bool) -> LiveDotFrame {
        LiveDotFrame(
            level: level,
            pulse: pulse,
            material: material,
            reduceMotion: reduceMotion
        )
    }
}

/// Value snapshot of all frame fields extracted from a `HUDModel` when no live
/// `HUDFrameModel` is attached (e.g., stills, previews, and snapshot tests).
struct HUDFrameSnapshot {
    let level: Double
    let ceiling: Double
    let reveal: Double
    let halfHeights: [CGFloat]
    let history: [Double]
    let spectrumHistory: [AudioSpectrumFrame]
    let phase: Double
    let time: Double
    let pulse: Double
    let shimmer: Double
    let emergence: Double
    let presence: Double
    let content: Double

    @MainActor
    init(_ model: HUDModel) {
        self.level = model.level
        self.ceiling = model.ceiling
        self.reveal = model.reveal
        self.halfHeights = model.halfHeights
        self.history = model.history
        self.spectrumHistory = model.spectrumHistory
        self.phase = model.phase
        self.time = model.time
        self.pulse = model.pulse
        self.shimmer = model.shimmer
        self.emergence = model.emergence
        self.presence = model.presence
        self.content = model.content
    }
}

/// Where a view reads a frame value from.
///
/// The app hands down ``HUDFrameModel``. Still renders and the tests that build
/// a card from a snapshot hand down ``HUDModel``, whose frame fields are
/// captured by value so SwiftUI sees changes to `model.time` without adding
/// `@ObservedObject var model` to every frame leaf.
@MainActor
enum HUDFrameSource {
    case frames(HUDFrameModel)
    case snapshot(HUDFrameSnapshot)

    static func model(_ model: HUDModel) -> HUDFrameSource {
        .snapshot(HUDFrameSnapshot(model))
    }

    var level: Double {
        switch self {
        case .frames(let frame): return frame.level
        case .snapshot(let snapshot): return snapshot.level
        }
    }

    var ceiling: Double {
        switch self {
        case .frames(let frame): return frame.ceiling
        case .snapshot(let snapshot): return snapshot.ceiling
        }
    }

    var reveal: Double {
        switch self {
        case .frames(let frame): return frame.reveal
        case .snapshot(let snapshot): return snapshot.reveal
        }
    }

    var halfHeights: [CGFloat] {
        switch self {
        case .frames(let frame): return frame.halfHeights
        case .snapshot(let snapshot): return snapshot.halfHeights
        }
    }

    var history: [Double] {
        switch self {
        case .frames(let frame): return frame.history
        case .snapshot(let snapshot): return snapshot.history
        }
    }

    var spectrumHistory: [AudioSpectrumFrame] {
        switch self {
        case .frames(let frame): return frame.spectrumHistory
        case .snapshot(let snapshot): return snapshot.spectrumHistory
        }
    }

    var phase: Double {
        switch self {
        case .frames(let frame): return frame.phase
        case .snapshot(let snapshot): return snapshot.phase
        }
    }

    var time: Double {
        switch self {
        case .frames(let frame): return frame.time
        case .snapshot(let snapshot): return snapshot.time
        }
    }

    var rewriteTime: Double {
        switch self {
        case .frames(let frame): return frame.rewriteTime
        case .snapshot(let snapshot): return snapshot.time
        }
    }

    var pulse: Double {
        switch self {
        case .frames(let frame): return frame.pulse
        case .snapshot(let snapshot): return snapshot.pulse
        }
    }

    var shimmer: Double {
        switch self {
        case .frames(let frame): return frame.shimmer
        case .snapshot(let snapshot): return snapshot.shimmer
        }
    }

    var emergence: Double {
        switch self {
        case .frames(let frame): return frame.emergence
        case .snapshot(let snapshot): return snapshot.emergence
        }
    }

    var presence: Double {
        switch self {
        case .frames(let frame): return frame.presence
        case .snapshot(let snapshot): return snapshot.presence
        }
    }

    var content: Double {
        switch self {
        case .frames(let frame): return frame.content
        case .snapshot(let snapshot): return snapshot.content
        }
    }

    func recordingElapsed(fallback: String) -> String {
        switch self {
        case .frames(let frame): return frame.elapsedLabel
        case .snapshot: return fallback
        }
    }

    func liveText(fallback: String) -> String {
        switch self {
        case .frames(let frame): return frame.liveText
        case .snapshot: return fallback
        }
    }
}
