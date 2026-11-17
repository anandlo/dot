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
        case assistantRecording
        case assistantThinking
        case assistantTool
        case assistantAnswerStreaming
        case assistantAnswerPasted
        case assistantAnswerCopied
        case assistantAnswerSpeaking
        case assistantAnswerSpoken
        case assistantConfirm
        case assistantConfirmDestructive
        case rewriteOffered
        case rewriteRunning
        case rewriteOriginal
        case rewriteTwoVersions
        case rewriteThreeVersions
        case rewriteLongTranscript
        case rewriteLongLabels
        case rewriteFailure
        case rewriteReducedMotion
        case rewriteAppliedFaithful
        case rewriteAppliedCheck
        case rewritePromptApplied
        case rewriteBlocked
        case rewriteCopied
    }

    /// The question the assistant renders show.
    static let assistantQuestion = "What is on my calendar tomorrow?"

    /// The connector the tool render names.
    static let assistantConnector = "Calendar"

    /// The answer the assistant renders show.
    static let assistantAnswerText = """
    You have two things tomorrow: a design review at ten, and lunch with Sam at half past twelve. \
    The review is in the small room, and nothing else is booked after three.
    """

    /// The request the confirmation render shows.
    ///
    /// It is longer than 120 characters on purpose: the card has to hold three
    /// lines of it, and a render of a short request would not prove that.
    static let assistantConfirmSummary = """
    Add a reminder to call the dentist on Thursday at nine in the morning, and set it to repeat \
    every month until the end of the year.
    """

    /// The request a destructive confirmation render shows.
    static let assistantDeleteSummary = """
    Delete the note called Meeting notes from last Tuesday, including everything filed under it \
    and its attachments, from Notes on this Mac.
    """

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

    /// The rewrite the rewrite renders show.
    ///
    /// It is shorter than the transcript on purpose, so the concise style's
    /// length band holds and the render of the applied card is the render of a
    /// rewrite that would really have been applied.
    static let rewrite = "Dot records the microphone, transcribes the words and pastes them back where you were."

    /// The prompt an applied Agent prompt render shows.
    ///
    /// It is a plausible answer to the transcript render: the sections the
    /// style asks for, holding only what the transcript said. A section the
    /// speaker gave nothing for is not drawn, and no detail is invented to fill
    /// one, which is what the style asks of the model.
    static let promptRewrite = """
    ## Goal
    Record, transcribe and paste the words back where the cursor was.

    ## Context
    Dot records the microphone end to end, transcribes the words, and pastes them back into the application that had focus.

    ## Requirements
    1. Record from the microphone.
    2. Transcribe the recording.
    3. Paste the transcript back where the cursor was.

    ## Constraints
    Do not lose the words when the paste is refused.
    """

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
        actions.copyVersion = { _ in }
        actions.pasteVersion = { _ in }
        actions.selectOriginal = {}
        actions.previousVersion = {}
        actions.nextVersion = {}
        actions.rerunRewrite = {}
        actions.settings = {}
        actions.close = {}
        actions.rewrite = { _ in }
        actions.cancelRewrite = {}
        actions.undoRewrite = {}
        actions.applyRewriteAnyway = {}
        actions.keepOriginal = {}
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
            let reduced = state == .rewriteReducedMotion
            let image = try render(state: state, reduceMotion: reduced)
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
        scheme: ColorScheme = .dark,
        reduceMotion: Bool = false
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
            actions: previewActions,
            reduceMotionOverride: reduceMotion
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
    /// Every value a recording still draws comes from one ``VoiceMeter`` fed
    /// ``DictationScript``'s voice: the history, the level, the adaptive ceiling,
    /// the column heights and the five bands. A still that set the level to a
    /// constant would prove only that the canvas can draw a constant, and the
    /// render is how the shape is reviewed.
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
        model.halfHeights = voice.halfHeights
        model.spectrumHistory = voice.spectrum

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
        case .assistantRecording:
            model.cardSize = HUDState.recordingCard.size
            model.mode = .assistantRecording(elapsed: "0:04")
        case .assistantThinking:
            model.cardSize = HUDState.assistantCard.size
            model.mode = .assistantThinking(question: assistantQuestion)
        case .assistantTool:
            model.cardSize = HUDState.assistantCard.size
            model.mode = .assistantTool(connectorName: assistantConnector)
        case .assistantAnswerStreaming, .assistantAnswerPasted, .assistantAnswerCopied,
             .assistantAnswerSpeaking, .assistantAnswerSpoken:
            let answerState: AssistantAnswerState = switch state {
            case .assistantAnswerPasted: .pasted("Mail")
            case .assistantAnswerCopied: .copied
            case .assistantAnswerSpeaking: .speaking
            case .assistantAnswerSpoken: .spoken
            default: .streaming
            }
            model.cardSize = HUD.assistantAnswerSize(text: assistantAnswerText)
            model.mode = .assistantAnswer(text: assistantAnswerText, state: answerState)
        case .assistantConfirm, .assistantConfirmDestructive:
            let destructive = state == .assistantConfirmDestructive
            let request = ConfirmationRequest(
                callID: "call-1",
                toolName: destructive ? "notes_delete" : "reminders_create",
                connectorID: destructive ? .notes : .reminders,
                connectorName: destructive ? "Notes" : "Reminders",
                risk: destructive ? .destructive : .write,
                summary: destructive ? assistantDeleteSummary : assistantConfirmSummary
            )
            let lines = HUD.assistantSummaryLines(request.summary)
            model.cardSize = CGSize(
                width: HUDConfirmLayout.width,
                height: HUDConfirmLayout.height(summaryLines: lines)
            )
            model.mode = .assistantConfirm(request)
            model.assistantAllow = {}
            model.assistantCancel = {}
        case .rewriteOffered, .rewriteRunning, .rewriteOriginal,
             .rewriteTwoVersions, .rewriteThreeVersions, .rewriteLongTranscript,
             .rewriteLongLabels, .rewriteFailure, .rewriteReducedMotion,
             .rewriteAppliedFaithful, .rewriteAppliedCheck, .rewritePromptApplied,
             .rewriteBlocked, .rewriteCopied:
            applyRewriteState(state, to: model)
        }
        return model
    }

    /// The states of the rewrite layer, on the transcript card.
    private static func applyRewriteState(_ state: State, to model: HUDModel) {
        let concise = RewriteStyle.concise
        let prompt = RewriteStyle.prompt
        let long = state == .rewriteRunning || state == .rewriteLongTranscript
        let text = long ? longTranscript : transcript
        model.mode = .transcript(
            text: text,
            delivery: .pasted,
            elapsed: long ? "4:18" : "0:07",
            destination: "Mail"
        )
        var card = RewriteCard(
            original: text,
            choices: RewriteStyle.builtIns,
            destination: "Mail"
        )
        switch state {
        case .rewriteRunning:
            card.append(id: 1, style: concise, text: rewrite, warning: nil)
            card.phase = .rewriting(styleID: concise.id, title: concise.title)
            card.draft = "Dot records the microphone, transcribes the words"
            card.selectedVersionID = 1
        case .rewriteOriginal:
            card.append(id: 1, style: concise, text: rewrite, warning: nil)
            card.append(id: 2, style: prompt, text: promptText, warning: nil)
            card.select(versionID: 0)
        case .rewriteTwoVersions:
            card.append(id: 1, style: concise, text: rewrite, warning: nil)
        case .rewriteThreeVersions, .rewriteReducedMotion:
            card.append(id: 1, style: concise, text: rewrite, warning: nil)
            card.append(id: 2, style: prompt, text: promptText, warning: nil)
        case .rewriteLongTranscript:
            card.append(id: 1, style: concise, text: rewrite, warning: nil)
            card.append(id: 2, style: prompt, text: promptText, warning: nil)
            // The still proves the long body scrolls while the version row is
            // still there; the selected version is the original words.
            card.select(versionID: 0)
        case .rewriteLongLabels:
            let customs = (0 ..< 6).map { index in
                RewriteStyle(
                    CustomRewriteStyle(
                        id: "custom-\(index)",
                        title: String(
                            ("Release notes rewrite \(index) ").prefix(CustomRewriteStyle.maximumTitleLength)
                        ),
                        instruction: "Rewrite."
                    )
                )
            }
            card.choices = customs
            card.append(
                id: 1,
                style: customs[0],
                text: "Release notes for the next build, rewritten once.",
                warning: nil
            )
            card.append(
                id: 2,
                style: customs[1],
                text: "Release notes for the next build, rewritten a second time with a different result.",
                warning: nil
            )
        case .rewriteFailure:
            card.note = RewriteCard.failureNote
        case .rewriteAppliedFaithful:
            card.append(id: 1, style: concise, text: rewrite, warning: nil)
            card.phase = .applied(versionID: 1)
            card.deliveryDestination = "Mail"
            card.canUndo = false
        case .rewriteAppliedCheck:
            card.append(id: 1, style: concise, text: rewrite, warning: FaithfulnessCheck.nameChanged)
            card.phase = .applied(versionID: 1)
            card.deliveryDestination = "Mail"
            card.canUndo = false
        case .rewritePromptApplied:
            card.append(id: 1, style: prompt, text: promptText, warning: nil)
            card.phase = .applied(versionID: 1)
            card.deliveryDestination = "Mail"
            card.canUndo = false
        case .rewriteBlocked:
            card.phase = .blocked(styleID: concise.id, error: FaithfulnessCheck.numberChanged)
            card.draft = rewrite
        case .rewriteCopied:
            card.append(id: 1, style: concise, text: rewrite, warning: nil)
            card.phase = .copied(versionID: 1)
            card.note = RewriteCard.clipboardNote
        case .rewriteOffered:
            break
        default:
            break
        }
        model.rewrite = card
        model.cardSize = HUD.transcriptSize(text: text, rewrite: card)
    }

    /// The Agent prompt render's words.
    ///
    /// The render is the model's own answer. Dot's standing rules are a block
    /// the person writes and the model never sees, and they are off in a fresh
    /// configuration, so the still shows the answer as the style produced it.
    private static var promptText: String {
        promptRewrite
    }

    /// Three seconds of the demonstration voice, through the product's own meter.
    ///
    /// The signal is ``DictationScript``'s: the same dictation the island's
    /// preview draws and the same five bands, so a still of the card is a still
    /// of what a recording of that script looks like rather than a second,
    /// invented voice.
    ///
    /// - Parameter moment: where in the script the still is drawn, in seconds.
    ///   The default is the moment the Settings tiles freeze at, just past the
    ///   loudest syllable, where the trace holds a vowel and the pause that
    ///   follows it rather than one even arch.
    /// - Returns: the history, the level, the ceiling, the column heights and
    ///   the spectrum history the card draws, all from one meter.
    static func voiceSample(
        at moment: Double = DictationScript.stillTime
    ) -> (
        history: [Double],
        level: Double,
        ceiling: Double,
        halfHeights: [CGFloat],
        spectrum: [AudioSpectrumFrame]
    ) {
        let meter = VoiceMeter()
        var scale = SpectrumScale()
        var spectrum: [AudioSpectrumFrame] = []
        // Three seconds before the moment as well as up to it, so the history
        // is full: the visualisers that scroll draw the whole three seconds, and
        // a still whose history began at zero draws a dead left half. Before the
        // voice starts there is room, which is what a recording opens with.
        var time: TimeInterval = moment - 3
        while time <= moment {
            meter.push(decibels: -58 + DictationScript.level(at: time) * 50, now: time)
            spectrum.append(scale.normalise(DictationScript.bands(at: time), dt: 1.0 / 60.0))
            time += 1.0 / 60.0
        }
        var history: [Double] = []
        meter.copyOrderedHistory(into: &history)
        let heights = Waveform.halfHeights(
            history: history,
            phase: meter.phase,
            count: Waveform.columnCount,
            maximum: HUDTheme.waveformHeight / 2,
            breath: 1.1
        )
        return (history, meter.envelope, meter.ceiling, heights, spectrum)
    }

    /// The render could not be made.
    enum RenderError: Error {
        case couldNotRender
        case couldNotEncode
    }
}
