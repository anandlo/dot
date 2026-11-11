import AppKit
import DotCore
import SwiftUI

/// Renders the HUD without showing it.
///
/// The renderer is the only way the HUD is inspected during development: it
/// draws the very same `HUDView` into a bitmap with `ImageRenderer`, so no
/// window is ever created and nothing appears on the user's screen.
@MainActor
enum HUDPreview {
    /// The states that can be rendered.
    enum State: String, CaseIterable {
        case recording
        case live
        case transcribing
        case transcript
        case transcriptLong
        case message
        case ready
    }

    /// The argument that renders the card and exits.
    static let argument = "--render-hud"
    /// The environment variable that does the same, named without the product
    /// prefix that ``DotMigration/environment(_:in:)`` adds. That reader accepts
    /// the pre-rename spelling of the prefix as well.
    static let environmentKey = "RENDER_HUD"

    /// The text of the transcript render.
    static let transcript = "Dot is working end to end. It records the microphone, transcribes the words and pastes them back where you were."

    /// The text of the long transcript render: more than the seven lines the
    /// card shows before the text scrolls, so the render proves the body is
    /// clamped and the newest words are the ones on screen.
    static let longTranscript = """
    Dot is working end to end. It records the microphone, transcribes the words and pastes them back where you were. The card grows with the text and stops growing at seven lines, so a long recording neither stretches the island down the screen nor loses its ending.

    The view starts at the end of the text, because the newest words are the ones you are checking, and the wheel scrolls back to the beginning for as long as the card is up. Nothing here steals the keyboard from the application you were typing in: the panel can never become key, and the scroller moves without it.

    A transcript of a long meeting is more than six lines, and the six lines the card used to cut at were six lines of the middle of a sentence that the user had no way to read. The body now holds seven lines and scrolls after that, with the scroller drawn in the card's own ink tones.

    What the card says after the recording ends is the whole of what was said, which is why it has to be readable: the end of the recording is usually the part that was hardest to speak, and it is the part that a reader checks first.
    """

    /// The partial the live render shows.
    /// Long enough to scroll: the card keeps the newest words in view, so a
    /// render of it has to show the end of the text and not its beginning.
    static let livePartial = "Dot keeps listening while the recording runs, so the words arrive as you speak and the card grows to make room for them. The newest words stay in view, which means the beginning of a long thought scrolls up out of the card while the person is still talking."

    /// The shortcut the launch render shows.
    static let readyShortcut = "⌥⌘D"

    /// The actions the renders draw.
    ///
    /// The closures are empty: a render never sends a click. Every action the
    /// app wires is present so the buttons are drawn where they will be, but
    /// History is left out, exactly as the app leaves it out until the
    /// History window exists.
    static var previewActions: HUDActions {
        var actions = HUDActions()
        actions.stop = {}
        actions.cancel = {}
        actions.copy = {}
        actions.paste = {}
        actions.settings = {}
        actions.close = {}
        return actions
    }

    /// The directory the render was asked for, if any.
    static func requestedDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> URL? {
        if let index = arguments.firstIndex(of: argument), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let value = DotMigration.environment(Self.environmentKey, in: environment) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return nil
    }

    /// Renders every state into `directory`.
    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in State.allCases {
            let image = try render(state: state)
            let url = directory.appendingPathComponent("render-\(state.rawValue).png")
            guard let data = image.representation(using: .png, properties: [:]) else {
                throw RenderError.couldNotEncode
            }
            try data.write(to: url, options: .atomic)
        }
        for visualizer in HUDVisualizer.allCases {
            let image = try render(state: .recording, visualizer: visualizer)
            let url = directory.appendingPathComponent("render-visualizer-\(visualizer.rawValue).png")
            guard let data = image.representation(using: .png, properties: [:]) else {
                throw RenderError.couldNotEncode
            }
            try data.write(to: url, options: .atomic)
        }
        try renderMotion(to: directory)
    }

    /// Renders the frames of the two motions: the card arriving, and the
    /// transcript's content settling.
    static func renderMotion(to directory: URL) throws {
        let entries: [(String, Double)] = [("0", 0), ("110", 0.34), ("220", 0.72), ("330", 0.94), ("440", 1)]
        for (name, presence) in entries {
            let image = try render(state: .recording, presence: presence, content: 1)
            guard let data = image.representation(using: .png, properties: [:]) else {
                throw RenderError.couldNotEncode
            }
            try data.write(to: directory.appendingPathComponent("motion-entry-\(name).png"), options: .atomic)
        }
        let contentFrames: [(String, Double)] = [("0", 0), ("90", 0.42), ("180", 0.82), ("260", 1)]
        for (name, content) in contentFrames {
            let image = try render(state: .transcript, presence: 1, content: content)
            guard let data = image.representation(using: .png, properties: [:]) else {
                throw RenderError.couldNotEncode
            }
            try data.write(to: directory.appendingPathComponent("motion-content-\(name).png"), options: .atomic)
        }
    }

    /// Renders one state, with the room the shadow needs around the card.
    ///
    /// - Parameters:
    ///   - state: the state to draw.
    ///   - showsShadow: whether the card casts its shadow.
    ///   - presence: how present the card is, from `0` to `1`.
    ///   - content: how settled its content is, from `0` to `1`.
    ///   - scheme: the appearance the render is drawn in. The card is dark in
    ///     both, and the scheme is what the system draws its scrollers and the
    ///     rest of the chrome in, so both are rendered.
    static func render(
        state: State,
        visualizer: HUDVisualizer = .stretch,
        material: HUDMaterial = .black,
        showsShadow: Bool = true,
        presence: Double = 1,
        content: Double = 1,
        scheme: ColorScheme = .dark
    ) throws -> NSBitmapImageRep {
        let model = makeModel(state: state)
        model.visualizer = visualizer
        model.material = material
        model.presence = presence
        model.content = content
        let size = CGSize(
            width: model.cardSize.width + HUD.shadowPadding * 2,
            height: model.cardSize.height + HUD.shadowPadding * 2
        )
        let view = HUDView(
            model: model,
            showsShadow: showsShadow,
            animated: false,
            actions: previewActions
        )
            .padding(HUD.shadowPadding)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)

        // The card is drawn through an offscreen `NSHostingView`, not through
        // `ImageRenderer`: the transcript body is a `ScrollView`, and
        // `ImageRenderer` does not draw the content of one — a transcript render
        // came out as an empty card. The hosting view is never placed in a
        // window, so nothing appears on screen.
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * 2,
            pixelsHigh: Int(size.height) * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderError.couldNotRender
        }
        bitmap.size = size
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        return bitmap
    }

    /// The model of one state, with a signal that looks like speech.
    ///
    /// Every value a recording still draws comes from one ``VoiceMeter`` fed the
    /// synthetic voice of ``SpeechEnvelope``: the history, the level, the
    /// adaptive ceiling and the bars. A still that set the level to a constant
    /// would prove only that the canvas can draw a constant, and the render is
    /// how the shape is reviewed.
    static func makeModel(state: State) -> HUDModel {
        let model = HUDModel()
        let voice = voiceSample()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.level = voice.level
        model.ceiling = voice.ceiling
        model.reveal = 1
        model.pulse = 0.32
        model.shimmer = 0.45
        model.time = 2.4
        model.phase = 0.35
        model.history = voice.history
        model.bars = voice.bars
        model.halfHeights = voice.halfHeights
        model.spectrumHistory = spectrumHistory(for: voice.history)

        switch state {
        case .recording:
            model.cardSize = HUDState.recordingCard.size
            model.mode = .recording(elapsed: "0:07")
        case .live:
            model.cardSize = HUDState.liveCard.size
            model.mode = .recording(elapsed: "0:07")
            model.liveText = livePartial
        case .transcribing:
            model.cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
            model.mode = .working
            // The count the transcribing card shows while it waits, so the
            // still proves the detail is still drawn next to the spinner.
            model.workingDetail = HUDProgress.detail(done: 1, total: 3)
        case .transcript:
            model.cardSize = HUD.transcriptSize(text: transcript)
            model.mode = .transcript(
                text: transcript,
                delivery: .pasted,
                elapsed: "0:07",
                destination: "Mail"
            )
        case .transcriptLong:
            model.cardSize = HUD.transcriptSize(text: longTranscript)
            model.mode = .transcript(
                text: longTranscript,
                delivery: .pasted,
                elapsed: "4:18",
                destination: "Mail"
            )
        case .message:
            let text = "Dot needs the microphone."
            model.cardSize = CGSize(width: HUD.messageWidth(text: text), height: HUDState.recordingHeight)
            model.mode = .message(text: text, symbol: "exclamationmark.circle")
        case .ready:
            model.cardSize = CGSize(width: HUDState.readyWidth, height: HUDState.readyHeight)
            model.mode = .ready(shortcut: readyShortcut)
            // The launch card's job is to name what dictation is going to. A
            // render that leaves those empty cannot show whether it still does.
            model.activeService = ProviderPreset.host(of: ProviderPreset.xiaomi.baseURL) ?? "this Mac"
            model.activeKeyHint = "a1b2…9f3c"
        }
        return model
    }

    /// Three seconds of a plausible voice, through the product's own meter.
    ///
    /// - Parameter moment: how far into the synthetic voice the still is drawn,
    ///   in seconds. It is the moment where the drawn half second holds a pause
    ///   and the syllable after it, so the still shows the shape the meter makes
    ///   rather than one even arch: at `1.45 s` the bars fall through the pause
    ///   and rise into the next word.
    /// - Returns: the history, the level, the ceiling, the column heights and the
    ///   bar heights the card draws, all from one meter.
    static func voiceSample(
        at moment: Double = 1.45
    ) -> (history: [Double], level: Double, ceiling: Double, halfHeights: [CGFloat], bars: [Double]) {
        let meter = VoiceMeter()
        // Three seconds before the moment as well as up to it, so the history
        // is full: the visualisers that scroll draw the whole three seconds, and
        // a still whose history began at zero draws a dead left half. Before the
        // voice starts there is room, which is what a recording opens with.
        var time: TimeInterval = moment - 3
        while time <= moment {
            let rms = max(SpeechEnvelope.rms(at: time), 0.00001)
            meter.push(decibels: 20 * log10(rms), now: time)
            time += 1.0 / 60.0
        }
        var history: [Double] = []
        meter.copyOrderedHistory(into: &history)
        var bars: [Double] = []
        VisualizerBars.stretch(
            into: &bars,
            history: history,
            spectrum: spectrumHistory(for: history),
            reveal: 1
        )
        let heights = Waveform.halfHeights(
            history: history,
            phase: meter.phase,
            count: Waveform.columnCount,
            maximum: HUDTheme.waveformHeight / 2,
            breath: 1.1
        )
        return (history, meter.envelope, meter.ceiling, heights, bars)
    }

    /// The five bands the grid and the scrolling meter draw, for a still.
    ///
    /// A still has no audio tap, and the matrix is a picture of five bands, so
    /// the bands have to come from the one signal the still does have. The
    /// model is the honest one: a band carries the energy of the envelope, and
    /// the bands above the fundamental are lifted where the envelope is rising,
    /// which is where a sibilant sits in a word. It is the shape of a spectrum
    /// rather than a spectrum, and it is drawn only by the documentation
    /// renders.
    ///
    /// - Parameter history: the envelope history, oldest first.
    /// - Returns: one frame per tick of the history, oldest first.
    static func spectrumHistory(for history: [Double]) -> [AudioSpectrumFrame] {
        var frames: [AudioSpectrumFrame] = []
        frames.reserveCapacity(history.count)
        for index in history.indices {
            let energy = min(1, max(0, history[index]))
            let before = history[max(0, index - 2)]
            let onset = min(1, max(0, (energy - before) * 4))
            // The fundamental is the chest at the bottom row, the sibilance the
            // top row, and the middle three the vowel between them.
            let chest = energy * 0.88
            let vowel = energy * 0.94
            let presence = energy * 0.80
            let formant = min(1, energy * 0.62 + onset * 0.30)
            let sibilance = min(1, energy * 0.35 + onset * 0.55)
            frames.append(AudioSpectrumFrame(bands: (sibilance, formant, presence, vowel, chest)))
        }
        return frames
    }

    /// The render could not be made.
    enum RenderError: Error {
        case couldNotRender
        case couldNotEncode
    }
}
