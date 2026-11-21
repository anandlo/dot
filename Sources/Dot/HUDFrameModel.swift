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
    var level: Double = 0
    /// The loudest moment of the recording so far, from `0` to `1`.
    var ceiling: Double = 1
    /// How much of the shape has arrived, from `0` to `1`.
    var reveal: Double = 0
    /// The half height of every column of the waveform, in points.
    var halfHeights: [CGFloat] = []
    /// The raw 60 Hz envelope history, oldest first (`0` to `1`).
    var history: [Double] = []
    /// Real-time 60 Hz five-band spectrum history, oldest first.
    var spectrumHistory: [AudioSpectrumFrame] = []
    /// Where inside the current sample period the meter sits (`0` to `<1`).
    var phase: Double = 0
    /// Continuous unwrapped elapsed time in seconds.
    var time: Double = 0
    /// The phase of the live dot's pulse, from `0` to `1`.
    var pulse: Double = 0
    /// The phase of the transcribing label's shimmer, from `0` to `1`.
    var shimmer: Double = 0
}

/// Where a view reads a frame value from.
///
/// The app hands down ``HUDFrameModel``. Still renders and the tests that build
/// a card from a snapshot hand down ``HUDModel``, whose frame fields still hold
/// the values of that still.
@MainActor
enum HUDFrameSource {
    case frames(HUDFrameModel)
    case model(HUDModel)

    var level: Double {
        switch self {
        case .frames(let frame): return frame.level
        case .model(let model): return model.level
        }
    }

    var ceiling: Double {
        switch self {
        case .frames(let frame): return frame.ceiling
        case .model(let model): return model.ceiling
        }
    }

    var reveal: Double {
        switch self {
        case .frames(let frame): return frame.reveal
        case .model(let model): return model.reveal
        }
    }

    var halfHeights: [CGFloat] {
        switch self {
        case .frames(let frame): return frame.halfHeights
        case .model(let model): return model.halfHeights
        }
    }

    var history: [Double] {
        switch self {
        case .frames(let frame): return frame.history
        case .model(let model): return model.history
        }
    }

    var spectrumHistory: [AudioSpectrumFrame] {
        switch self {
        case .frames(let frame): return frame.spectrumHistory
        case .model(let model): return model.spectrumHistory
        }
    }

    var phase: Double {
        switch self {
        case .frames(let frame): return frame.phase
        case .model(let model): return model.phase
        }
    }

    var time: Double {
        switch self {
        case .frames(let frame): return frame.time
        case .model(let model): return model.time
        }
    }

    var pulse: Double {
        switch self {
        case .frames(let frame): return frame.pulse
        case .model(let model): return model.pulse
        }
    }

    var shimmer: Double {
        switch self {
        case .frames(let frame): return frame.shimmer
        case .model(let model): return model.shimmer
        }
    }
}
