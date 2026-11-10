import CoreGraphics
import Foundation
import DotCore

/// Everything the card draws.
///
/// The model is pushed by the HUD's display link: the microphone level, the
/// columns of the waveform, the pulse of the live dot. The view only reads it,
/// so a frame is one assignment instead of a tree walk.
@MainActor
final class HUDModel: ObservableObject {
    /// What the card is showing.
    @Published var mode: HUDMode = .message(text: "", symbol: "info.circle")
    /// The size the card is heading for.
    @Published var cardSize = CGSize(
        width: HUDState.recordingWidth,
        height: HUDState.recordingHeight
    )
    /// The live partial transcript of the recording, when there is one.
    @Published var liveText: String = ""
    /// Whether the card is on screen.
    @Published var isVisible = false
    /// How present the card is: `0` is gone, `1` is settled. The spring in
    /// the HUD moves it, so a frame is never a jump.
    @Published var presence: Double = 0
    /// How settled the content is: `0` is fresh, `1` is shown. Every state
    /// change restarts it, which is what makes the card's content arrive
    /// rather than appear.
    @Published var content: Double = 0
    /// The level of the voice, from `0` to `1`.
    @Published var level: Double = 0
    /// The half height of every column of the waveform, in points.
    @Published var halfHeights: [CGFloat] = []
    /// The raw 60 Hz envelope history, oldest first (`0` to `1`).
    @Published var history: [Double] = []
    /// Real-time 60 Hz 5-band acoustic spectrum history, oldest first.
    @Published var spectrumHistory: [AudioSpectrumFrame] = []
    /// Where inside the current sample period the meter sits (`0` to `<1`), for sub-pixel scrolling.
    @Published var phase: Double = 0
    /// Continuous unwrapped elapsed time in seconds, so harmonic visualizers never snap at a loop boundary.
    @Published var time: Double = 0
    /// The visualizer style selected for the recording card.
    @Published var visualizer: HUDVisualizer = .stretch
    /// The material selected for the HUD surface: .glass or .black.
    @Published var material: HUDMaterial = .glass
    /// The phase of the live dot's pulse, from `0` to `1`.
    @Published var pulse: Double = 0
    /// The phase of the shimmer of the transcribing label, from `0` to `1`.
    @Published var shimmer: Double = 0
    /// How much of the transcription is left, e.g. `"2 of 3"`.
    ///
    /// Empty when there is nothing to count, which is also what the card shows
    /// for a single request.
    @Published var workingDetail: String = ""

    /// The service dictation is currently going to, named the way the person
    /// picked it. The ready card shows this instead of teaching the shortcut:
    /// knowing which service is active is more useful than being told again how
    /// to hold a key.
    @Published var activeService: String = ""

    /// A masked hint of the key in use, e.g. `sk-p…1234`, or empty when the
    /// service needs no key.
    @Published var activeKeyHint: String = ""

    /// Which control button the pointer is currently hovering over, if any.
    @Published var hoveredAction: HUDAction? = nil

    /// Whether the user is editing the transcript directly inside the HUD island.
    @Published var isEditingTranscript: Bool = false

    /// Updates the transcript text in place while editing inline on the HUD island.
    func updateTranscriptText(_ newText: String) {
        if case .transcript(_, let delivery, let elapsed) = mode {
            mode = .transcript(text: newText, delivery: delivery, elapsed: elapsed)
        }
    }

    // MARK: - Live transcript

    /// Shows a live partial while the recording is running.
    ///
    /// An empty text collapses the card back to the recording pill, and a
    /// partial that arrives outside the recording state is ignored so a late
    /// request can never cover a transcript or a message.
    func showLiveText(_ text: String) {
        guard case .recording = mode else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        liveText = trimmed
        cardSize = trimmed.isEmpty ? HUDState.recordingCard.size : HUDState.liveCard.size
    }

    /// Drops the live partial when the recording ends.
    func clearLiveText() {
        liveText = ""
    }

    /// Updates the clock of the recording without touching the live partial.
    func updateRecording(elapsed: String) {
        if case .recording = mode {
            mode = .recording(elapsed: elapsed)
        }
    }
}
