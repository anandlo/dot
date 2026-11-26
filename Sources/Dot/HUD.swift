import AppKit
import QuartzCore
import DotCore
import SwiftUI

/// The panel the HUD lives in.
///
/// It never takes focus: it is a borderless, non-activating panel that floats
/// above every window but below the system alerts.
///
/// Not final: a test builds one off every display, which is a subclass that
/// refuses to be pulled onto a screen. The app builds this class itself.
class HUDPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Keeps the frame the HUD asked for.
    ///
    /// The panel now reaches the top of the display, because the shape has to be
    /// drawn under the notch, and AppKit's own constraint would pull a window
    /// whose title bar would sit behind the menu bar back down the screen. There
    /// is no title bar here and no click outside the card: the frame is the
    /// HUD's to place.
    ///
    /// - Parameters:
    ///   - frameRect: the frame the HUD set.
    ///   - screen: the screen it would be constrained to.
    /// - Returns: the frame, unchanged.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The hosting view of the island.
///
/// The panel is nonactivating and can never become key, so the app is usually
/// inactive while the card is up. AppKit treats the first click in an inactive
/// window as the click that activates it and does not deliver it to the view
/// under the pointer — which would make every button in the card need two
/// clicks. Accepting the first mouse event keeps the panel nonactivating and
/// still delivers the click to SwiftUI's buttons.
final class HUDHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// The heads-up display: the card at the top of the screen.
///
/// The panel has one fixed size and only its frame is placed. The card animates
/// *inside* that frame, so the window server never sees a transparent window
/// change size, which is what leaves a grey edge around a shape. The card is a
/// single SwiftUI surface, so there is no second material and no second shadow.
@MainActor
final class HUD {
    /// The size of the panel. It is large enough for the biggest card plus
    /// the room the shadow needs, and it never changes.
    static let panelSize = CGSize(width: 640, height: 340)
    /// The tallest card the panel can hold.
    ///
    /// The card is placed ``shadowPadding`` below the top of the panel, so its
    /// height plus that inset has to stay inside the panel: a taller card would
    /// be cut by the window that draws it, which is why a long transcript's
    /// body scrolls at ``HUDTranscript/maxBodyHeight``.
    static var maximumCardHeight: CGFloat { panelSize.height - shadowPadding }
    /// The room around the card, so its shadow is never clipped.
    static let shadowPadding: CGFloat = 28
    /// How far below the top of the usable screen the top of the panel sits.
    /// The card itself starts `shadowPadding` lower, inside the panel.
    private static let topInset: CGFloat = 10
    /// If no frame has rendered this soon after the card was ordered front,
    /// the render loop is not alive. The deadline is inside the 100 ms in
    /// which the card must become visible, so a stalled first frame can never
    /// leave an invisible island on screen.
    private static let renderFallbackDelay: TimeInterval = 0.1
    private static let linkFallbackDelay: TimeInterval = 0.35

    private let panel: HUDPanel
    var panelScreen: NSScreen? { panel.screen }
    private let model = HUDModel()
    private let frameModel = HUDFrameModel()
    private let meter = VoiceMeter()
    /// What Dot learned about the microphone that is recording.
    ///
    /// The meter's floor is seeded from it and the level scale is drawn on the
    /// window it produces. It never reaches the audio: ``Recorder`` hands the
    /// WAV to the provider untouched.
    private var calibration: MicrophoneCalibration?
    /// Whether the panel stays off screen. Set by the headless test; the app
    /// never asks for it.
    private let offscreen: Bool
    private var hostingView: HUDHostingView!

    /// The island's actions. `AppDelegate` fills them in before the first
    /// card is shown; an action without a closure is not drawn.
    var actions = HUDActions() {
        didSet {
            hostingView?.rootView = makeRootView()
        }
    }

    /// Called when the transcript card is replaced by another kind of card.
    ///
    /// The rewrite layer belongs to the words it was offered for. The runner is
    /// told so a stream from the old card can never attach its result to the new
    /// one; the card itself has already dropped the layer.
    var onTranscriptEnded: (() -> Void)?
    /// Called when the card is hidden for any reason, including the countdown.
    var onHide: (() -> Void)?
    /// Called when active HUD rendering starts or stops.
    var onRenderActivityChange: ((Bool) -> Void)?

    private let renderLoop = HUDRenderLoop()
    private let frameStats = HUDFrameStatistics()
    private var renderFallbackTimer: Timer?
    private var linkFallbackTimer: Timer?
    nonisolated(unsafe) private var idleDwellTimer: Timer?
    private var isRenderLoopSleepingForStaticIdle = false
    private var lastTick: CFTimeInterval?
    private var lastWakeTimestamp: CFTimeInterval?
    /// When the current presentation was ordered front, in media time.
    private var presentedAt: CFTimeInterval = 0
    /// Whether a frame has run since the current presentation.
    private var hasRenderedSincePresent = true
    /// Whether the first frame of the current presentation has been logged.
    private var hasReportedFirstTick = true
    private var recordingStartedAt: CFTimeInterval = 0
    private var dwellSeconds: Double = HUDDwell.defaultSeconds
    /// How long the launch card stays on screen.
    private var readyDwellSeconds: Double = 60
    private var dismissTimer: Timer?
    /// The countdown of the transcript, which stops while the card is read.
    private var dwellClock: HUDDwellClock?
    /// Whether the pointer is over the card.
    private var isPointerInside = false
    private var debugPointerOverride: Bool?
    /// When the card was last scrolled, in media time; `nil` when it never was.
    private var lastScrollAt: CFTimeInterval?
    /// The horizontal swipe over the text body, fed from precise scroll events.
    private var rewriteSwipe = RewriteSwipeGesture()
    /// The scroll view the wheel or trackpad gesture belongs to.
    private var wheelGesture = HUDWheelGesture()
    /// The monitors that see the pointer while another app is frontmost.
    private var pointerMonitor: Any?
    private var scrollMonitor: Any?
    nonisolated(unsafe) private var defaultNotificationTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var workspaceNotificationTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var renderActivity: NSObjectProtocol?
    private var hasSyncedRestAppearance = false
    /// How many times the pointer monitors have been installed. The headless
    /// test reads it to prove a countdown reset never tears down a live pair;
    /// the app never asks for it.
    private(set) var debugPointerTrackingInstallCount = 0
    private var hasLoggedScroll = false
    private var hideTask: Task<Void, Never>?
    private var actionFeedbackTask: Task<Void, Never>?
    private var levelProvider: (() -> Double)?
    private var spectrumProvider: (() -> AudioSpectrumFrame)?
    /// The spectrum the card draws: the per-voice window, the per-band filter and
    /// the ring whose entries carry the tick they were measured on.
    private var spectrum = VisualizerSpectrum()
    private var spectrumBuffer: [AudioSpectrumFrame] = []
    private var isPreviewingVisualizer = false
    private var isPreviewingMaterial = false

    /// Whether the card is currently showing an interactive style or material demo.
    var isPreviewing: Bool {
        isPreviewingVisualizer || isPreviewingMaterial
    }
    /// Reusable envelope history buffer to avoid CoW allocations across ticks.
    private var historyBuffer: [Double] = []
    private var speechTopBuffer: [Double] = []
    private var lastPublishedWrittenSamples = -1
    /// How much of the shape has arrived, from `0` to `1`.
    ///
    /// It rises when a recording starts and falls when it ends, so the shape
    /// grows out of the axis and settles back into it instead of appearing at
    /// whatever height the last frame of the last take left behind.
    private var reveal: Double = 0
    /// How present the card is, in screen space.
    ///
    /// It is the progress of the emergence: `0` is the notch, `1` is the card at
    /// rest, and it passes `1` on the way in, which is the overshoot the shape
    /// spends on the card's own height. The island leaves faster than it arrives:
    /// the arrival is a pour out of the screen and takes 0.65 s with a little
    /// overshoot on the settle, and the departure is the same shape going home,
    /// critically damped and over in 0.45 s.
    private var emergeSpring = Spring(value: 0, target: 0, duration: 0.65, bounce: 0.12)
    /// The opacity of a card that arrives with its motion reduced.
    ///
    /// Reduced motion keeps the card where it rests and crossfades it instead,
    /// so the appearance is this straight ramp rather than the spring. It starts
    /// at `0` and stops on its target, which is what makes the appearance a
    /// known length of time.
    private var reduceFade = HUDCrossfade(value: 0, duration: 0.15)
    /// How far through the card's departure the HUD is.
    ///
    /// The card cannot leave the way it arrived until its content has faded: the
    /// words belong to the surface, not to the shape. The dismissal is carried
    /// between frames so the two are one movement with one clock, and it is
    /// what tells the panel when it may be ordered out.
    private struct Dismissal {
        /// How long the departure has been running, in seconds.
        var elapsed: TimeInterval = 0
        /// Whether the shape has been given its own order to leave.
        var shapeStarted = false
    }
    private var dismissal: Dismissal?
    /// Where the panel is placed on the display it is on, when it is on one.
    ///
    /// It carries the panel's frame, the notch the shape pours out of and the
    /// distance the card hangs below the top of the panel. Without it the card
    /// has no shape to pour out of and fades, which is what happens off the
    /// screens.
    private var placement: HUDEmergence.Placement?
    /// The display the panel is placed on, when a test hands one in.
    private var debugPlacementScreen: HUDEmergence.Screen?
    /// Whether a test set the motion setting, which the system otherwise owns.
    private var debugReduceMotionOverride: Bool?
    /// Whether the card has a notch to pour out of.
    ///
    /// It does when the panel is placed on a display whose geometry was read.
    /// A card with no display behind it — a HUD asked for off the screens, a
    /// display that could not be read — has no shape to come out of, and fades
    /// in where it rests, exactly as it did before the emergence existed.
    private var poursFromTheNotch: Bool { placement != nil }
    /// Whether the card has been read again since it arrived and began to take
    /// the mouse. The card ignores every event until the shape is nearly at
    /// rest, and a pointer that does not move produces no event of its own.
    private var hasReadPointerSinceArrival = false
    /// Whether the rail's opening position has been restored for this card.
    private var railPositionRestored = false
    /// The position the person last gave the rail during this card.
    ///
    /// The card opens the rail on its first style, and the person may move it
    /// before the appearance has stopped: a wheel, a version's arrow, the row's
    /// own arrow keys or VoiceOver actions, and the scroll a styled version
    /// opens on. Whichever of those wrote last is where the rail belongs, so the
    /// opening correction restores this rather than zero.
    private var railIntendedOrigin: CGPoint = .zero
    /// The rail's clip the person's position is read from, and the observation
    /// that reads it.
    ///
    /// The row's scroll view is SwiftUI's: the arrows, the arrow keys, the
    /// VoiceOver actions and a styled version's scroll all move it from inside
    /// the row, so the clip's own bounds change is the only report the card gets
    /// of them. The clip is read again whenever the row is laid out as a new
    /// view, which is why the observation is kept beside it rather than made
    /// once.
    private weak var railOriginClip: NSClipView?
    private var railOriginToken: NSObjectProtocol?
    /// Whether every write to the rail's clip is being taken as the person's.
    ///
    /// The row's own reveal is an eased scroll of several frames, and its last
    /// steps are each shorter than the residue's reach. One write that carries
    /// the rail further than that qualifies the ones after it: they are followed
    /// until the clip holds still, so the record lands on where the
    /// reveal came to rest rather than on the frame that crossed the window.
    private var railOriginTracks = false
    /// The clip origin the tracking last read, so frames without a write can end it.
    private var railTrackedOrigin: CGPoint?
    /// How many frames in a row have read the clip where the last write left it.
    private var railStillFrames = 0
    /// The frame time the tracking last saw the clip move.
    private var railMovedAt: CFTimeInterval = 0
    /// The rail the appearance is reading, kept between frames.
    ///
    /// The rail is a scroll view inside the card's SwiftUI tree, and finding it
    /// means walking that tree. The correction reads it on every frame, so the
    /// one it found is kept until the row is laid out again as a new view.
    private weak var railScrollView: NSScrollView?
    /// Whether the card itself is writing the rail, which is not the person.
    private var isCorrectingRailOrigin = false
    /// The rail's frame on the previous tick, while its position is restored.
    private var lastRailFrame: CGRect?
    /// How settled the content of the card is.
    private var contentSpring = Spring(value: 0, target: 0, duration: 0.34, bounce: 0.10)
    var reducesMotionPreference: Bool = false {
        didSet {
            guard oldValue != reducesMotionPreference else { return }
            hostingView?.rootView = makeRootView()
        }
    }

    private var reduceMotion: Bool {
        debugReduceMotionOverride ?? (reducesMotionPreference || DotMotion.systemReducesMotion)
    }

    /// Creates the HUD.
    ///
    /// - Parameter offscreen: keeps the panel off every screen. The headless
    ///   test uses it; the app never does.
    init(offscreen: Bool = false) {
        self.offscreen = offscreen
        panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level.statusBar + 1
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Glass follows the system's own appearance so its ink can adapt to the
        // backdrop. Black keeps the dark appearance its opaque card has always
        // used, including for the system chrome inside the transcript.
        applyPanelAppearance()
        // The buttons need the mouse. The panel is still nonactivating and
        // can never become key: a click never moves keyboard focus.
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        hostingView = HUDHostingView(rootView: makeRootView())
        hostingView.wantsLayer = true
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        // The hosting view fills the panel; the card is centred at the top.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        // The panel is taller than this when it reaches the top of the display,
        // and the card has to be laid out against the panel it is in.
        container.autoresizingMask = [.width, .height]
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        panel.contentView = container

        placePanel()
        observeScreens()
    }

    /// The SwiftUI tree inside the panel.
    ///
    /// It is rebuilt when the actions change, so the buttons always call the
    /// closures the app last handed over.
    private func makeRootView() -> AnyView {
        let onCanvasDraw: (@Sendable (CFTimeInterval, Double) -> Void)?
        if offscreen {
            onCanvasDraw = nil
        } else {
            let stats = frameStats
            onCanvasDraw = { [weak stats] now, durationMS in
                stats?.recordCanvasDraw(now: now, durationMS: durationMS)
            }
        }
        frameModel.visualizerSink.onLayerDraw = onCanvasDraw
        return Self.rootView(
            model: model,
            frame: frameModel,
            actions: actions,
            animated: !reduceMotion,
            reduceMotionOverride: reduceMotion ? true : nil,
            placement: placement,
            size: placement?.panelFrame.size ?? Self.panelSize,
            onCanvasDraw: onCanvasDraw
        )
    }

    /// The tree the panel hosts, for one model and one placement.
    ///
    /// The card hangs from the top of the panel by the distance the placement
    /// asks for, which is the margin its shadow needs plus the room the panel
    /// gained by reaching the top of the display. The panel's own size is given
    /// so a render can draw the same tree, cropped to what the shape covers,
    /// without a window.
    ///
    /// - Parameters:
    ///   - model: what the card draws.
    ///   - actions: what the card's buttons do.
    ///   - animated: whether the card's shape springs between sizes.
    ///   - placement: where the panel is and where its notch is, or `nil` when
    ///     the card has no display to pour out of.
    ///   - size: the size of the panel.
    /// - Returns: the tree the panel hosts.
    static func rootView(
        model: HUDModel,
        frame: HUDFrameModel? = nil,
        actions: HUDActions,
        animated: Bool,
        reduceMotionOverride: Bool? = nil,
        placement: HUDEmergence.Placement?,
        size: CGSize,
        onCanvasDraw: (@Sendable (CFTimeInterval, Double) -> Void)? = nil
    ) -> AnyView {
        AnyView(
            ZStack(alignment: .top) {
                Color.clear
                HUDView(
                    model: model,
                    frame: frame,
                    animated: animated,
                    actions: actions,
                    reduceMotionOverride: reduceMotionOverride,
                    onCanvasDraw: onCanvasDraw,
                    emergence: placement?.scene
                )
                .padding(.top, placement?.cardTopInset ?? shadowPadding)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        )
    }

    /// How long the transcript stays on screen.
    var dwell: Double {
        get { dwellSeconds }
        set { dwellSeconds = newValue }
    }

    /// How long the launch card stays on screen.
    var readyDwell: Double {
        get { readyDwellSeconds }
        set { readyDwellSeconds = newValue }
    }

    /// What visualizer the HUD island uses to draw incoming audio.
    var visualizer: HUDVisualizer {
        get { model.visualizer }
        set {
            model.visualizer = newValue
            pushVisualizerSettingsUpdateIfLive()
        }
    }

    /// Tells the card which microphone is about to record, so the meter starts
    /// from what is known about it.
    ///
    /// - Parameter calibration: the entry for the recording device, or `nil`
    ///   for a device Dot has no history with. A missing entry keeps the fixed
    ///   window, which is what shipped.
    func setCalibration(_ calibration: MicrophoneCalibration?) {
        self.calibration = calibration?.clamped
        meter.setCalibration(calibration)
    }

    /// What material the HUD island is made of: .glass or .black.
    var material: HUDMaterial {
        get { model.material }
        set {
            model.material = newValue
            applyPanelAppearance()
            pushVisualizerSettingsUpdateIfLive()
        }
    }

    private func pushVisualizerSettingsUpdateIfLive() {
        let isRecording = if case .recording = model.mode { true } else { false }
        guard model.isVisible, isRecording || frameModel.reveal > 0 else { return }
        frameModel.visualizerSink.push(
            frameModel.currentVisualizerFrame(
                visualizer: model.visualizer,
                material: model.material,
                reduceMotion: reduceMotion
            )
        )
        if isRecording {
            frameModel.liveDotSink.push(
                frameModel.currentLiveDotFrame(material: model.material, reduceMotion: reduceMotion)
            )
        }
    }

    /// Glass inherits the system appearance; Black keeps the fixed dark one.
    private func applyPanelAppearance() {
        panel.appearance = model.material == .glass ? nil : NSAppearance(named: .darkAqua)
    }

    /// The microphone level, read on every frame.
    func setLevelProvider(_ provider: @escaping () -> Double) {
        levelProvider = provider
    }

    /// The microphone 5-band acoustic spectrum, read on every frame.
    func setSpectrumProvider(_ provider: @escaping () -> AudioSpectrumFrame) {
        spectrumProvider = provider
    }

    // MARK: - States

    /// Shows the recording state.
    ///
    /// - Parameter elapsed: the clock of the recording.
    func showRecording(elapsed: String) {
        openRecordingCard(.recording(elapsed: elapsed))
    }

    /// Opens the recording card.
    private func openRecordingCard(_ mode: HUDMode) {
        isPreviewingVisualizer = false
        isPreviewingMaterial = false
        clearActionFeedback()
        clearLiveText()
        model.grammar = nil
        model.grammarWasLong = false
        recordingStartedAt = CACurrentMediaTime()
        meter.reset()
        // The floor and the window are known before the first buffer arrives,
        // so the first syllable is drawn at the level the room really has
        // instead of at the level a blind meter guessed from one frame.
        meter.setCalibration(calibration)
        meter.seed(floor: calibration?.noiseFloorDBFS)
        spectrum.reset()
        spectrumBuffer.removeAll(keepingCapacity: true)
        historyBuffer.removeAll(keepingCapacity: true)
        speechTopBuffer.removeAll(keepingCapacity: true)
        lastPublishedWrittenSamples = -1
        reveal = 0
        frameModel.reveal = 0
        if case .recording(let elapsed) = mode, frameModel.elapsedLabel != elapsed {
            frameModel.elapsedLabel = elapsed
        }
        setMode(mode, size: HUDState.recordingCard.size)
        present()
    }

    /// Updates the clock of the recording state.
    func updateRecording(elapsed: String) {
        if frameModel.elapsedLabel != elapsed {
            frameModel.elapsedLabel = elapsed
        }
        model.updateRecording(elapsed: elapsed)
    }

    private func clearLiveText() {
        model.clearLiveText()
        if !frameModel.liveText.isEmpty {
            frameModel.liveText = ""
        }
    }

    /// Shows a live partial while the recording is running.
    ///
    /// The card grows once, when the first words arrive, and keeps its live
    /// size as the text changes. A partial that is empty puts the recording
    /// pill back. Anything outside the recording state is ignored: a request
    /// that returns late must never cover the transcribing card or a final
    /// transcript.
    func showLiveText(_ text: String) {
        guard case .recording = model.mode else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if frameModel.liveText != trimmed {
            frameModel.liveText = trimmed
        }
        if model.liveText.isEmpty != trimmed.isEmpty {
            model.showLiveText(trimmed)
        }
        // The recording card is normally already up; presenting again would
        // only re-place and re-log the panel on every partial.
        if !model.isVisible {
            present()
        }
    }

    /// Drops the live partial when the user cancels the recording.
    func cancel() {
        clearLiveText()
    }

    /// Shows the transcribing state.
    ///
    /// - Parameters:
    ///   - done: how many requests have been sent, `0` before the first one.
    ///   - total: how many the recording needs in all.
    func showTranscribing(done: Int = 0, total: Int = 0) {
        isPreviewingVisualizer = false
        isPreviewingMaterial = false
        clearActionFeedback()
        clearLiveText()
        model.grammar = nil
        model.grammarWasLong = false
        model.workingDetail = HUDProgress.detail(done: done, total: total)
        setMode(
            .working,
            size: CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        )
        present()
    }

    /// Shows the transcript.
    ///
    /// The countdown starts here, when the transcript lands, and not when the
    /// card is ordered front: the dwell is the time the user gets to read the
    /// words, and it must not be eaten by the opening animation.
    ///
    /// - Parameters:
    ///   - text: the words that were transcribed.
    ///   - delivery: how the words were delivered.
    ///   - elapsed: the clock of the recording they came from.
    ///   - destination: the localized name of the application the words were
    ///     pasted into, when it is known. The header names it; a missing name
    ///     leaves the plain delivery word.
    ///   - grammar: the grammar the words were rewritten for, when one was.
    ///   - grammarWasLong: whether that rewrite flagged the words as long.
    func showTranscript(
        text: String,
        delivery: HUDDelivery,
        elapsed: String,
        destination: String? = nil,
        grammar: DictationTarget? = nil,
        grammarWasLong: Bool = false
    ) {
        isPreviewingVisualizer = false
        isPreviewingMaterial = false
        clearActionFeedback()
        // A new transcript is a new card, even when the previous card was also a
        // transcript. The runner is told before the layer is dropped so a
        // stream from the old take cannot attach its result to these words.
        onTranscriptEnded?()
        clearLiveText()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showMessage(text: "Nothing was heard.", symbol: "waveform.slash")
            return
        }
        // The chip belongs to the transcript, so it is set with it and cleared
        // by every other state.
        model.grammar = grammar
        model.grammarWasLong = grammarWasLong
        // A rewrite belongs to the take that carried it, so a new transcript
        // starts with no layer. The runner sets it once the card is up.
        model.rewrite = nil
        let measuredContentHeight = Self.transcriptContentHeight(text: trimmed)
        let cardSize = CGSize(
            width: HUDState.transcriptWidth,
            height: HUDTheme.headerHeight + 1 + HUDTranscript.bodyHeight(contentHeight: measuredContentHeight)
        )
        setMode(
            .transcript(
                text: trimmed,
                delivery: delivery,
                elapsed: elapsed,
                destination: destination
            ),
            size: cardSize
        )
        present()
        let effectiveDwell = delivery == .pasted ? min(dwellSeconds, 3.5) : dwellSeconds
        startDwelling(duration: effectiveDwell)
        Log.shared.info("hud.transcript.shown", [
            "characters": .int(trimmed.count),
            "card_height": .double(model.cardSize.height),
            "scrolls": .bool(
                HUDTranscript.scrolls(
                    contentHeight: measuredContentHeight
                )
            ),
            "dwell_s": .double(effectiveDwell),
        ])
    }

    /// Shows a message, with a titled button when there is something to do
    /// about it.
    ///
    /// - Parameters:
    ///   - action: the title of the button, or `nil` for a message that only
    ///     reports.
    ///   - actionHandler: what the button does. A title without a handler is
    ///     dropped, because a button that does nothing is worse than no button:
    ///     the message then reads as a plain report.
    func showMessage(text: String, action: String? = nil, actionHandler: (() -> Void)? = nil) {
        let title = action?.trimmingCharacters(in: .whitespacesAndNewlines)
        let handler = (title?.isEmpty == false) ? actionHandler : nil
        let symbol = handler == nil ? "info.circle" : "exclamationmark.circle"
        showMessage(
            text: text,
            symbol: symbol,
            action: handler == nil ? nil : title,
            actionHandler: handler
        )
    }

    /// Shows a message with a symbol.
    ///
    /// - Parameters:
    ///   - action: the title of the button the message offers, or `nil` for a
    ///     message that only reports.
    ///   - actionHandler: what the button does.
    ///   - dwell: how long to leave it up, when the message is not a report but
    ///     a preview of something the person is choosing. A material has no
    ///     other way to be seen: the card only names it.
    func showMessage(
        text: String,
        symbol: String,
        action: String? = nil,
        actionHandler: (() -> Void)? = nil,
        dwell: TimeInterval? = nil
    ) {
        isPreviewingVisualizer = false
        isPreviewingMaterial = false
        clearActionFeedback()
        clearLiveText()
        model.grammar = nil
        model.grammarWasLong = false
        setMode(
            .message(text: text, symbol: symbol),
            size: CGSize(
                width: Self.messageWidth(text: text, actionTitle: action),
                height: HUDState.recordingHeight
            )
        )
        // Set after the mode, so the state change cannot clear the button that
        // belongs to the message it just moved to.
        if let action, let actionHandler {
            model.messageAction = HUDMessageAction(title: action, handler: actionHandler)
        } else {
            model.messageAction = nil
        }
        present()
        scheduleDismiss(in: dwell)
    }

    /// Shows the island for a moment, so a material can be chosen by eye.
    func previewMaterial(_ material: HUDMaterial) {
        self.material = material
        let name = material == .glass ? "Glass" : "Black"
        let symbol = material == .glass ? "sparkles" : "circle.fill"
        showMessage(text: name, symbol: symbol, dwell: 1.8)
        isPreviewingMaterial = true
    }

    /// Immediately dismisses an active visualizer or material demo without affecting live recordings.
    func dismissPreview() {
        guard isPreviewing else { return }
        isPreviewingVisualizer = false
        isPreviewingMaterial = false
        clearActionFeedback()
        hide()
    }

    private func clearActionFeedback() {
        actionFeedbackTask?.cancel()
        actionFeedbackTask = nil
        if model.actionFeedback != nil {
            model.actionFeedback = nil
        }
    }

    /// Shows temporary confirmation feedback directly on a HUD action button and its tooltip.
    func showActionFeedback(for action: HUDAction, outcome: HUDActionOutcome) {
        actionFeedbackTask?.cancel()
        let token = HUDActionFeedback(id: UUID(), action: action, outcome: outcome)
        model.actionFeedback = token
        if let announcement = Self.accessibilityAnnouncement(for: outcome) {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
        let durationMS = outcome == .triggered ? 350 : 1350
        actionFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(durationMS))
            guard let self, self.model.actionFeedback?.id == token.id else { return }
            self.model.actionFeedback = nil
        }
    }

    private static func accessibilityAnnouncement(for outcome: HUDActionOutcome) -> String? {
        switch outcome {
        case .copied:
            return "Copied to clipboard"
        case .pasted:
            return "Pasted at cursor"
        case .fallbackCopied:
            return "Could not paste at cursor. Copied to clipboard instead."
        case .triggered:
            return nil
        }
    }

    /// Shows the island with a live simulated voice wave so a visualizer can be chosen by eye.
    func previewVisualizer(_ visualizer: HUDVisualizer) {
        model.visualizer = visualizer
        clearLiveText()
        isPreviewingMaterial = false
        isPreviewingVisualizer = true
        // The preview draws a simulated voice, not a microphone: a calibration
        // left over from the last take would put it on the wrong scale.
        meter.reset()
        meter.setCalibration(nil)
        let now = CACurrentMediaTime()
        recordingStartedAt = now
        spectrum.reset()
        lastPublishedWrittenSamples = -1
        // The opening five seconds are walked by the same feed the Settings tile
        // draws with, on this card's own meter and this card's own spectrum, so a
        // scrolling visualizer immediately shows a full, moving voice trace instead
        // of filling up from an empty history, and the trace it opens on is the
        // take the live frames below go on to draw rather than a second, different
        // voice measured by a second, different path.
        let seedSeconds = Double(Waveform.historyLength) / Waveform.sampleRate
        let feed = VisualizerFeed(
            meter: meter,
            from: now - seedSeconds,
            level: { time in
                DictationScript.level(at: Self.wrapped(time - now + Self.previewOffset, loop: DictationScript.loop))
            },
            bands: { time in
                DictationScript.bands(at: Self.wrapped(time - now + Self.previewOffset, loop: DictationScript.loop))
            }
        )
        feed.seed(to: now)
        spectrum = feed.spectrum
        if frameModel.elapsedLabel != "0:02" {
            frameModel.elapsedLabel = "0:02"
        }
        setMode(
            .recording(elapsed: "0:02"),
            size: CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        )
        present()
        lastTick = now
        // A still preview is a picture rather than a performance: there is no
        // movement to finish, so it stays until the person moves on from it.
        scheduleDismiss(in: reduceMotion ? nil : Self.previewDismissDelay)
    }

    /// How long the demonstration is shown before the card dismisses itself.
    ///
    /// One whole loop of the script, rest included. The preview and its
    /// dismissal are the same measurement, so a longer demonstration cannot be
    /// cut off half way through.
    static let previewDismissDelay: TimeInterval = DictationScript.loop

    /// Where inside the loop the demonstration starts.
    ///
    /// The script opens with a second of room before the first syllable, and the
    /// card is at its most legible when the voice begins a moment after the card
    /// has arrived, so the clock starts four tenths of a second in: on the breath
    /// before the first word, with the seeded history behind it already speaking.
    static let previewOffset: Double = 0.4

    /// The moment of the demonstration a clock reading sits at.
    ///
    /// - Parameters:
    ///   - now: the clock's reading, in seconds.
    ///   - startedAt: the moment the preview started.
    /// - Returns: the position in the loop, in seconds.
    static func previewPhase(now: TimeInterval, startedAt: TimeInterval) -> Double {
        let elapsed = max(0, now - startedAt) + previewOffset
        return elapsed.truncatingRemainder(dividingBy: DictationScript.loop)
    }

    /// A moment of the demonstration, brought back inside its loop.
    ///
    /// The preview's clock runs past the end of the loop while its dismissal is
    /// pending, and the history it seeds reaches back before the loop began;
    /// both are the same take seen from a different point in it.
    ///
    /// - Parameters:
    ///   - time: the moment, in seconds, possibly negative or past the loop.
    ///   - loop: the length of the loop, in seconds.
    /// - Returns: the same moment, from `0` up to `loop`.
    /// The wrapped preview phase, for looping back before `0`.
    static func wrapped(_ time: Double, loop: Double) -> Double {
        guard loop > 0 else { return 0 }
        let wrapped = time.truncatingRemainder(dividingBy: loop)
        return wrapped < 0 ? wrapped + loop : wrapped
    }

    /// Tells the launch card which service dictation goes to, and a masked hint
    /// of the key in use.
    ///
    /// Both values are safe to display: the name comes from the chosen row, and
    /// the hint is produced by ``MaskedKey`` and never from the secret itself.
    ///
    /// - Parameters:
    ///   - service: the service name, as the picker shows it.
    ///   - keyHint: a masked key such as `sk-p…1234`, or empty for a service
    ///     that needs no key.
    func setActiveService(_ service: String, keyHint: String) {
        model.activeService = service
        model.activeKeyHint = keyHint
    }

    /// Shows the launch card unless the card is already showing something more
    /// urgent: it never replaces a recording, a transcription, a transcript or a
    /// message that is on screen.
    ///
    /// - Parameter shortcut: the label of the record shortcut.
    func showReady(shortcut: String) {
        guard Self.canShowReady(over: model.mode, visible: model.isVisible) else { return }
        isPreviewingVisualizer = false
        isPreviewingMaterial = false
        clearActionFeedback()
        clearLiveText()
        model.grammar = nil
        model.grammarWasLong = false
        setMode(
            .ready(shortcut: shortcut),
            size: CGSize(width: HUDState.readyWidth, height: HUDState.readyHeight)
        )
        present()
        Log.shared.info("hud.ready.shown")
        scheduleReadyDismiss()
    }

    /// Whether the launch card may take the screen from `mode`.
    ///
    /// - Parameters:
    ///   - mode: what the card is showing.
    ///   - visible: whether the card is on screen.
    /// - Returns: `true` when the card is hidden or already shows the launch
    ///   state.
    static func canShowReady(over mode: HUDMode, visible: Bool) -> Bool {
        guard visible else { return true }
        if case .ready = mode { return true }
        return false
    }

    /// Begins inline editing of the transcript inside the HUD island.
    func beginInlineEditing() {
        guard case .transcript = model.mode else { return }
        model.isEditingTranscript = true
        panel.allowsKey = true
        panel.makeKey()
    }

    /// Concludes inline editing of the transcript inside the HUD island and
    /// immediately releases keyboard focus back to whatever app the user is in.
    func endInlineEditing() {
        guard model.isEditingTranscript || panel.allowsKey else { return }
        model.isEditingTranscript = false
        panel.makeFirstResponder(nil)
        panel.allowsKey = false
        if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    /// Updates the transcript text displayed inside the HUD island while editing.
    func updateTranscriptText(_ newText: String) {
        model.updateTranscriptText(newText)
    }

    /// Hides the card.
    func hide() {
        clearLiveText()
        model.grammar = nil
        model.grammarWasLong = false
        model.rewrite = nil
        model.isEditingTranscript = false
        model.hoveredAction = nil
        clearActionFeedback()
        model.messageAction = nil
        panel.allowsKey = false
        dismissTimer?.invalidate()
        dismissTimer = nil
        dwellClock = nil
        lastPublishedWrittenSamples = -1
        _ = frameStats.finish()
        stopPointerTracking()
        panel.ignoresMouseEvents = true
        // The layer cannot outlive the surface that showed it. This also stops
        // a stream that would otherwise finish into a card nobody can see.
        onHide?()
        guard model.isVisible else {
            isPreviewingVisualizer = false
            isPreviewingMaterial = false
            return
        }
        if case .ready = model.mode {
            Log.shared.info("hud.ready.hidden")
        }
        model.isVisible = false
        ensureRenderingActive()

        if reduceMotion {
            contentSpring.snap(to: 0)
            frameModel.content = 0
            model.content = 0
            reduceFade.to(0)
            dismissal = poursFromTheNotch ? Dismissal(elapsed: 0, shapeStarted: true) : nil
        } else if poursFromTheNotch {
            contentSpring.to(target: 0, duration: 0.12, bounce: 0)
            dismissal = Dismissal(elapsed: 0, shapeStarted: false)
        } else {
            // A card with no shape to go back into fades out where it is, which
            // is the appearance it has always had.
            dismissal = nil
            emergeSpring.to(target: 0, duration: 0.22, bounce: 0)
        }

        // The panel may not be ordered out until the shape has gone back into
        // the notch: the window is the only thing that can draw it. The frames
        // decide that, on the same clock they always spend, and the task below
        // is what keeps a stalled loop from leaving an invisible window behind:
        // it gives up on the frames after the escape the departure is allowed.
        hideTask?.cancel()
        let escape: Int
        if poursFromTheNotch {
            escape = 1050
        } else {
            escape = reduceMotion ? 60 : 320
        }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(escape))
            guard let self, !self.model.isVisible else { return }
            self.dismissal = nil
            self.finishHiding()
        }
    }

    /// Orders the panel out once the card has left it.
    private func finishHiding() {
        guard !model.isVisible else { return }
        isPreviewingVisualizer = false
        isPreviewingMaterial = false
        clearActionFeedback()
        panel.orderOut(nil)
        stopRendering()
    }

    /// Whether the card is on screen.
    var isVisible: Bool { model.isVisible }

    /// The mode the real card is drawing. The headless stop test reads it to
    /// prove the working card replaced the recording card before held work ends.
    var debugMode: HUDMode { model.mode }

    #if DEBUG
    /// Every mode the card has entered, in order. The stop ordering test reads
    /// it to prove a forbidden working state was never entered even briefly.
    private(set) var debugModeHistory: [HUDMode] = []
    #endif

    /// The grammar the transcript card is naming. The headless test reads it to
    /// prove the chip is attached to the text it describes; the app never does.
    var debugGrammar: DictationTarget? { model.grammar }

    /// Whether the grammar flagged the transcript as long.
    var debugGrammarWasLong: Bool { model.grammarWasLong }

    /// The titled button the current message offers, if any. The test reads it
    /// to prove the handler reached the card; the app never does.
    var debugMessageAction: HUDMessageAction? { model.messageAction }

    /// How present the card is. The headless test reads it through the real
    /// render loop.
    var debugPresence: Double { frameModel.presence }

    /// How far the shape has come out of the notch, overshoot included. The
    /// headless test reads it to time the emergence; the app never does.
    var debugEmergence: Double { frameModel.emergence }

    /// How settled the content is. The headless test reads it through the real
    /// render loop.
    var debugContent: Double { frameModel.content }

    /// Whether the springs that move the card's appearance are at rest.
    ///
    /// The card arrives by changing its shape and by scaling and offsetting
    /// itself, and those are these springs' values: SwiftUI hands them to the
    /// views it hosts as frame transforms, and AppKit re-derives a hosted scroll
    /// view's clip geometry under each one. A test that reads a hosted view's
    /// scroll position waits for this rather than for a duration, because the
    /// render loop advances the springs once per frame and a busy machine
    /// delivers fewer frames.
    var debugAppearanceAtRest: Bool {
        contentSpring.isResting && (reduceMotion ? reduceFade.isResting : emergeSpring.isResting)
    }

    /// Whether the record is still following writes to the rail's clip.
    ///
    /// The headless test reads it to know that a reveal has stopped arriving,
    /// which is a state of the card rather than a duration; the app never does.
    var debugRailFollowsWrites: Bool { railOriginTracks }

    /// Whether the opening correction has been decided for this card.
    ///
    /// The headless test reads it to know which frame's clip origin is the last
    /// one the correction could still have read; the app never does.
    var debugRailPositionRestored: Bool { railPositionRestored }

    /// The position the person last gave the rail, as the opening correction reads it.
    ///
    /// The headless test reads it to prove the card took the scroll the row ran
    /// for itself as the person's; the app never does.
    var debugRailIntendedOrigin: CGPoint { railIntendedOrigin }

    /// Places the rail's intended origin for a test that positions the rail by hand.
    ///
    /// The card applies the person's travel to the intended origin while the
    /// opening correction has not been decided, so a test that writes the clip
    /// itself has to write the intended origin with it. Placing only the clip
    /// leaves the card applying the next gesture to where it last intended,
    /// which is a position the test never chose. The app never calls this.
    ///
    /// - Parameter origin: the position to take as the person's.
    func debugSetRailIntendedOrigin(_ origin: CGPoint) {
        railIntendedOrigin = origin
    }

    /// Whether a test is holding the entrance short of its rest frame.
    ///
    /// The render loop keeps ticking while this is set, so the rail's observer
    /// attaches, but the appearance stays away from rest and the opening
    /// correction cannot decide. A fixture sets this before presenting a card
    /// and clears it when the test wants the card to come to rest. The app
    /// never sets it.
    var debugHoldTheEntrance = false

    /// Whether a test is holding the opening correction undecided at rest.
    ///
    /// The correction decides on the first quiet frame after the appearance
    /// comes to rest, and a loaded machine can deliver that frame in the same
    /// run-loop pass as the rest frame, so a test cannot reliably observe the
    /// rest-but-undecided state by waiting for it. While this is set the card
    /// still comes to rest but the correction does not decide; clearing it lets
    /// the next quiet frames decide as usual. The app never sets it.
    var debugHoldTheOpeningCorrection = false

    /// Moves the card's appearance by a known amount of time.
    ///
    /// The appearance runs on the frames the render loop delivers and spends
    /// whatever time passed between two of them, which is a property of the
    /// machine rather than of the card. The headless test therefore moves this
    /// clock itself, through the same advance the frame loop calls; the app
    /// never does.
    ///
    /// - Parameter seconds: the time to move forward, in seconds.
    func debugAdvanceAppearance(by seconds: TimeInterval) {
        guard seconds > 0 else { return }
        advanceAppearance(by: seconds)
    }

    /// Places the panel on a display that exists only for the test.
    ///
    /// The shape's geometry is read from the display, so the pointer's rules and
    /// the card's rest rectangle can only be proved against one. A display that
    /// is not the person's is the only one a test may place a window on, and
    /// this one is never ordered front. The app never calls this.
    ///
    /// The panel is ordered out before it is placed: the display does not exist,
    /// so the frame it describes is a place on the person's screen, and a window
    /// ordered front there would be drawn on it.
    ///
    /// - Parameter screen: the display to place the panel on.
    func debugPlace(on screen: HUDEmergence.Screen) {
        panel.orderOut(nil)
        debugPlacementScreen = screen
        placePanel()
    }

    /// The card's rectangle on the screen, as the pointer tests it.
    var debugCardFrame: CGRect { cardFrame }

    /// Reads the pointer at a point on the screen, as the monitors do. The
    /// headless test uses it because it cannot move the real pointer; the app
    /// never does.
    ///
    /// - Parameter point: where the pointer is, in screen coordinates.
    func debugUpdatePointer(at point: CGPoint) {
        updatePointer(at: point)
    }

    /// Sets the appearance the pointer's rules read. The headless test uses it
    /// to hold a card at a moment of its emergence; the app never does.
    ///
    /// - Parameter value: how far the shape has come out of the notch.
    func debugSetEmergence(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        frameModel.emergence = value
        frameModel.presence = clamped
        model.emergence = value
        model.presence = clamped
    }

    /// Sets the motion setting. The headless test uses it because the system's
    /// own preference is not the test's to change; the app never does.
    ///
    /// - Parameter value: the setting, or `nil` to read the system's again.
    func debugSetReduceMotion(_ value: Bool?) {
        debugReduceMotionOverride = value
        hostingView?.rootView = makeRootView()
    }

    /// Whether AppKit considers the panel visible.
    var debugPanelVisible: Bool { panel.isVisible }

    /// The panel the island is drawn in.
    ///
    /// The headless test reads its frame to place an event in the card, and its
    /// key state to prove that a scroll takes no focus; the app never asks for
    /// it.
    var debugPanel: HUDPanel { panel }

    /// How many frames the render loop has delivered. The headless test uses
    /// it to prove the loop ran, not only the visibility fallback.
    private(set) var debugTickCount = 0

#if DEBUG
    /// The model a frame-pacing measurement renders from.
    var debugModel: HUDModel { model }

    /// The frame values the app hands to the drawing leaves.
    var debugFrameModel: HUDFrameModel { frameModel }

    /// The frame clock the card is using, for the headless backend tests.
    var debugRenderLoop: HUDRenderLoop { renderLoop }

    /// The shipped frame statistics, read by the headless tests.
    var debugFrameStatistics: HUDFrameStatistics { frameStats }

    /// Moves the frame clock by one known step. The headless test uses it to
    /// drive a long recording without waiting on a display.
    func debugTick(now: CFTimeInterval) {
        tick(now: now)
    }
#endif

    /// Adds the main-actor slice of one live-transcription attempt to the
    /// shipped frame summary.
    func recordLiveTranscriptionMainActor(ms: Double) {
        frameStats.recordLiveMain(ms: ms)
    }

    /// How many times the visibility fallback has run. The headless test uses
    /// it to prove the watchdog fired.
    private(set) var debugFallbackCount = 0

    /// Stops only the frame loop. The headless test uses it to prove the
    /// visibility fallback; the app never does.
    func debugStopRenderLoop() {
        renderLoop.stop()
    }

    /// Runs one frame of the rail's origin tracking without the render loop.
    ///
    /// The headless test writes a reveal's steps itself and needs one tracking
    /// frame for each write. Waiting for the wall-clock loop lets a loaded
    /// machine deliver a frame with no write, which ends the follow before the
    /// last step. The app never calls this.
    func debugAdvanceRailTrackingFrame(now: CFTimeInterval) {
        guard let rail = cardRail() else { return }
        observeTheRailsOrigin(of: rail)
        trackTheRailsOriginToRest(rail, now: now)
    }

    /// Starts a new reveal's run of tracking frames at the recorded position.
    ///
    /// The headless test has written the first step and wants the following
    /// short steps to be measured from it. A wall-clock tick may already have
    /// primed the follow, so this clears only that frame of history and keeps
    /// the follow active. The app never calls this.
    func debugPrimeRailTrackingFromTheRecord() {
        railOriginTracks = true
        railTrackedOrigin = nil
    }

    /// How much of the transcript's dwell is left, in seconds. `nil` when no
    /// card is counting down. The headless test reads it to prove that reading
    /// the card suspends the countdown instead of restarting it.
    var debugDwellRemaining: Double? { dwellClock?.remaining }

    /// Whether the countdown is suspended. The headless test reads it after
    /// ``debugPointer(inside:)``; the app never does.
    var debugDwellPaused: Bool { dwellClock?.isPaused ?? false }

    /// Puts the pointer over the card, as the monitors would when the user
    /// moves onto it. The headless test uses it because it cannot move the real
    /// pointer; the app never does.
    func debugPointer(inside: Bool) {
        debugPointerOverride = inside
        isPointerInside = inside
    }

    /// The view the island is drawn in.
    ///
    /// The headless test walks it to find the card's scroll views, which are
    /// SwiftUI's; the app never asks for it.
    var debugRootView: NSView { hostingView }

    /// Whether the pointer monitors are installed. The headless test reads it
    /// to prove that a countdown reset leaves them alone; the app never asks
    /// for it.
    var debugPointerTrackingInstalled: Bool {
        pointerMonitor != nil && scrollMonitor != nil
    }

    /// Applies one scroll at a point, as a background pointer monitor would.
    ///
    /// The headless test cannot make another application the frontmost one, so
    /// it cannot produce the event the background island receives; it hands the
    /// event here instead, at the point it would have come from. The event goes
    /// through the same path the monitors use, with `delivered` false; the app
    /// never calls this.
    ///
    /// - Parameters:
    ///   - event: the wheel to apply.
    ///   - screenPoint: where the pointer was when the event was produced.
    /// - Returns: whether the card would swallow the event. A background event
    ///   is never swallowed, so this is informational here.
    @discardableResult
    func debugHandleScrollEvent(_ event: NSEvent, at screenPoint: CGPoint) -> Bool {
        guard event.type == .scrollWheel else { return false }
        return pointerEvent(
            HUDPointerEvent(event),
            at: screenPoint,
            delivered: false
        )
    }

    /// Delivers one scroll to the card as the local monitor would.
    ///
    /// A delivered wheel is the one AppKit also hands to the card's own views.
    /// A rail-owned gesture is applied here and swallowed, whichever axis it
    /// owns, so AppKit never applies the same event again. The app never calls
    /// this.
    ///
    /// - Parameters:
    ///   - event: the wheel AppKit delivered.
    ///   - screenPoint: where the pointer was when it was produced.
    /// - Returns: whether the event is swallowed by the card.
    @discardableResult
    func debugDeliverWheel(_ event: NSEvent, at screenPoint: CGPoint) -> Bool {
        guard event.type == .scrollWheel else { return false }
        return pointerEvent(
            HUDPointerEvent(event),
            at: screenPoint,
            delivered: true
        )
    }

    /// Moves the transcript's countdown by a known amount of time.
    ///
    /// The countdown runs on the frames the render loop delivers and spends
    /// whatever time passed between two of them. A machine running the test
    /// bundle in parallel can withhold frames for longer than the dwell itself
    /// and then deliver one frame that carries all of it, which is a property of
    /// the machine and not of the countdown. The headless test therefore moves
    /// the clock itself, through the same `updateDwell` the frame loop calls;
    /// the app never does.
    func debugAdvanceDwell(by seconds: CFTimeInterval) {
        guard let clock = dwellClock else { return }
        updateDwell(now: clock.advancedAt + seconds)
    }

    // MARK: - The loop

    private func present() {
        hideTask?.cancel()
        hideTask = nil
        dismissal = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
        // Each card gets its own countdown: the dwell of the transcript that was
        // replaced must not dismiss the message or recording that replaced it.
        dwellClock = nil
        stopPointerTracking()

        let now = CACurrentMediaTime()
        // The user may have moved to another display, or a display may have
        // been unplugged, since the last time the card was up. Place it again
        // before it is ordered front, so it can never appear off-screen.
        placePanel()
        // Only the card itself takes the mouse. The rest of the panel is the
        // margin its shadow needs, and a window that swallowed clicks there made
        // the whole strip above the screen's content dead: what the user clicked
        // belonged to another app, and the panel took it. The pointer decides
        // once the first move is seen.
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        verifyPanelVisibility()
        model.isVisible = true
        lastTick = nil
        lastWakeTimestamp = nil
        presentedAt = now
        hasRenderedSincePresent = false
        hasReportedFirstTick = false
        railPositionRestored = false
        railIntendedOrigin = .zero
        railOriginTracks = false
        railTrackedOrigin = nil
        hasReadPointerSinceArrival = false
        startRendering()
        scheduleRenderFallback()
        // The card is on screen, so the pointer's position decides whether it
        // takes the mouse. Tracking runs for as long as the card is up, not
        // only while a countdown is running.
        startPointerTracking()
        updatePointer(at: NSEvent.mouseLocation)

        if reduceMotion {
            contentSpring.snap(to: 1)
            frameModel.content = 1
            model.content = 1
            reduceFade.to(1)
        } else {
            if poursFromTheNotch {
                emergeSpring.to(target: 1, duration: 0.65, bounce: 0.12)
            } else {
                emergeSpring.to(target: 1, duration: 0.36, bounce: 0.16)
            }
            if contentSpring.target < 1 {
                contentSpring.to(target: 1, duration: 0.34, bounce: 0.10)
            }
        }
    }

    /// Dismisses a message after the dwell.
    ///
    /// The transcript does not use this timer: its countdown runs on the frame
    /// loop, because it has to stop while the card is being read and a timer
    /// cannot be paused without losing what is left of it.
    private func scheduleDismiss(in seconds: TimeInterval? = nil) {
        dismissTimer?.invalidate()
        let interval = seconds ?? dwellSeconds
        guard interval > 0 else { return }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    // MARK: - Dwell

    /// Resets the transcript's countdown.
    ///
    /// A reset gives the card a fresh clock, not a fresh pair of monitors: the
    /// monitors belong to the card's presentation, so a phase that changes
    /// while a wheel gesture is in flight does not lose the gesture.
    private func startDwelling(duration: Double? = nil) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        let targetDuration = duration ?? dwellSeconds
        dwellClock = HUDDwellClock(duration: targetDuration, now: CACurrentMediaTime())
        lastScrollAt = nil
        isPointerInside = false
        hasLoggedScroll = false
        startPointerTracking()
        // The pointer may already be over the card when the transcript lands,
        // and a pointer that does not move produces no event: ask once, so a
        // card shown under the pointer is paused from the first frame.
        updatePointer(at: NSEvent.mouseLocation)
    }

    /// Counts the dwell down on the frame the card is drawn on.
    ///
    /// The clock is told whether the card is being read, and it consumes no
    /// time while it is: the countdown is suspended, never restarted, so the
    /// card stays for what was left when the pointer leaves.
    private func updateDwell(now: CFTimeInterval) {
        guard var clock = dwellClock else { return }
        if let override = debugPointerOverride {
            isPointerInside = override
        } else if !offscreen {
            // The pointer is read again on every frame: a global monitor coalesces
            // events, and a pointer that left between two of them would otherwise
            // leave the countdown suspended for good.
            updatePointer(at: NSEvent.mouseLocation)
        }
        let interacting = model.isEditingTranscript
            || panel.isKeyWindow
            || model.rewrite?.isStreaming == true
            || HUDDwell.isInteracting(
                pointerInside: isPointerInside,
                lastScroll: lastScrollAt,
                now: now
            )
        let expired = clock.advance(to: now, interacting: interacting)
        dwellClock = clock
        guard expired, !interacting else { return }
        Log.shared.info("hud.dwell.expired", [
            "dwell_s": .double(clock.duration),
            "paused": .bool(clock.isPaused),
        ])
        hide()
    }

    // MARK: - The pointer

    /// Watches the pointer and the wheel while the transcript is up.
    ///
    /// The panel can never become key and the app is usually not active — the
    /// user is dictating into another app — so the card's own mouse-moved
    /// events do not arrive. The global monitor sees the pointer wherever it is,
    /// including over the frontmost application, and the local monitor sees it
    /// when Dot is the active app. Both observe the event; the local monitor
    /// swallows a delivered wheel that belongs to the style rail, because the
    /// card applies that gesture itself.
    private func startPointerTracking() {
        // The monitors live as long as the card does. A countdown reset — the
        // phase of a rewrite changing, a note arriving, a version completing —
        // restarts the clock, never the monitors: removing and reinstalling a
        // global monitor on every token would lose the gesture in flight.
        guard !debugPointerTrackingInstalled else { return }
        stopPointerTracking()
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .scrollWheel,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // The values are snapshotted before the asynchronous handoff to the
            // main actor, so the location and the deltas are the ones the event
            // carried and a later pointer move cannot change where it was
            // produced.
            let point = HUD.screenPoint(of: event)
            let pointer = HUDPointerEvent(event)
            Task { @MainActor [weak self] in
                _ = self?.pointerEvent(pointer, at: point, delivered: false)
            }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let point = HUD.screenPoint(of: event)
            let pointer = HUDPointerEvent(event)
            let windowNumber = event.windowNumber
            guard let self else { return event }
            // Local monitors are always called on the main thread, before the
            // event is dispatched. The card is observed synchronously there, so
            // the event-time location is the one the callback was given, and a
            // swallowed event is stopped before any view applies it.
            let swallow = MainActor.assumeIsolated {
                self.pointerEvent(
                    pointer,
                    at: point,
                    delivered: windowNumber == self.panel.windowNumber
                )
            }
            return swallow ? nil : event
        }
        debugPointerTrackingInstallCount += 1
        if pointerMonitor == nil {
            // A monitor that cannot be installed is not fatal: the card still
            // dismisses itself, it only stops waiting while it is read.
            Log.shared.warn("hud.pointer.monitor.missing")
        }
    }

    private func stopPointerTracking() {
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        pointerMonitor = nil
        scrollMonitor = nil
        isPointerInside = false
        lastScrollAt = nil
        wheelGesture.cancel()
        rewriteSwipe.cancel()
    }

    /// Where a pointer event was produced, in screen coordinates.
    ///
    /// An event attached to a window carries its point in that window's
    /// coordinates; a monitor event from another application has no window and
    /// carries the screen point already. Reading this here, before any
    /// asynchronous handoff, is what keeps the gesture's beginning where the
    /// person made it.
    ///
    /// - Parameter event: the pointer event.
    /// - Returns: the event-time location, in screen coordinates.
    static func screenPoint(of event: NSEvent) -> CGPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    /// Reads one of the events the monitors watch.
    ///
    /// - Parameters:
    ///   - event: the event copied off its `NSEvent`.
    ///   - point: where the event was produced, in screen coordinates.
    ///   - delivered: whether AppKit delivered the event to the panel, which
    ///     means the card's own views also see it.
    /// - Returns: whether the card swallowed the event. A delivered wheel
    ///   owned by the style rail is swallowed: the card applies it itself so the
    ///   row receives the gesture exactly once.
    @discardableResult
    private func pointerEvent(
        _ event: HUDPointerEvent,
        at point: CGPoint,
        delivered: Bool
    ) -> Bool {
        let now = CACurrentMediaTime()
        updatePointer(at: point)
        if event.kind == .click {
            if !isPointerInside {
                if model.isEditingTranscript || panel.isKeyWindow {
                    endInlineEditing()
                } else if var clock = dwellClock, clock.remaining > 0.8 {
                    // A click outside the card means the person has moved on, so
                    // the remaining dwell is cut to 0.8 s rather than left running.
                    clock.advance(to: now + (clock.remaining - 0.8), interacting: false)
                    dwellClock = clock
                }
            }
            return false
        }
        guard event.kind == .wheel else { return false }
        // A gesture the card already owns keeps its events when the pointer
        // leaves the card, and momentum in particular keeps arriving after the
        // fingers are gone: the owner, not the pointer, decides.
        guard isPointerInside || wheelGesture.isTracking else {
            rewriteSwipe.cancel()
            return false
        }
        lastScrollAt = now
        let swallow = scrollEvent(event, at: point, delivered: delivered)
        guard !hasLoggedScroll else { return swallow }
        hasLoggedScroll = true
        Log.shared.info("hud.transcript.scrolled", [
            "inside": .bool(isPointerInside),
            "key_window": .bool(panel.isKeyWindow),
            "app_active": .bool(NSApp.isActive),
        ])
        return swallow
    }

    /// Routes one wheel event to the scroll view its gesture belongs to.
    ///
    /// The owner and the axis are decided once, on the event that starts the
    /// gesture, and every later event of it — including momentum, whose
    /// location follows the pointer — keeps that owner. A gesture that begins
    /// over the style chips belongs to the rail and to nothing else: it never
    /// pages the versions and never moves the transcript's body.
    ///
    /// A rail-owned gesture is applied here and, when AppKit delivered it,
    /// swallowed, whatever its axis: the card owns the row's travel and the
    /// native scroll view must not apply it a second time. A gesture over the
    /// body or the version paging keeps its existing path.
    ///
    /// - Parameters:
    ///   - event: the wheel.
    ///   - screenPoint: where the event was produced, in screen coordinates.
    ///   - delivered: whether AppKit delivered it to the panel.
    /// - Returns: whether the card swallows the event.
    @discardableResult
    private func scrollEvent(
        _ event: HUDPointerEvent,
        at screenPoint: CGPoint,
        delivered: Bool
    ) -> Bool {
        let cardFrame = self.cardFrame
        let railFrame = Self.rewriteChipRowFrame(cardFrame: cardFrame, card: model.rewrite)
        let bodyFrame = Self.transcriptBodyFrame(cardFrame: cardFrame, card: model.rewrite)
        let rail = Self.chipRowScrollView(in: hostingView)
        let body = Self.transcriptScrollView(in: hostingView)

        let phase = event.phase
        let momentum = event.momentumPhase

        // A legacy wheel — no phases at all — is one self-contained step, the
        // way one mouse notch is. There is no gesture to carry between events.
        if phase.isEmpty, momentum.isEmpty {
            wheelGesture.cancel()
            let owner = wheelOwner(at: screenPoint, railFrame: railFrame, bodyFrame: bodyFrame)
            return applyWheel(
                owner: owner,
                axis: HUDWheelAxis.beginning(deltaX: event.deltaX, deltaY: event.deltaY),
                event: event,
                at: screenPoint,
                delivered: delivered,
                rail: rail,
                body: body
            )
        }

        let isMomentum = !momentum.isEmpty
        // Momentum belongs to the gesture that flicked it. An orphan tail — the
        // card appeared after the fingers lifted, or the owner was cancelled —
        // is not allowed to latch the rail from wherever the pointer drifted.
        if isMomentum, !wheelGesture.isTracking { return false }

        let beginsNewGesture = phase.contains(.began)
            || phase.contains(.mayBegin)
            || !wheelGesture.isTracking
        if beginsNewGesture {
            let owner = wheelOwner(at: screenPoint, railFrame: railFrame, bodyFrame: bodyFrame)
            wheelGesture.begin(
                owner: owner,
                axis: HUDWheelAxis.beginning(deltaX: event.deltaX, deltaY: event.deltaY)
            )
        }

        let swallow = applyWheel(
            owner: wheelGesture.owner,
            axis: wheelGesture.latchAxis(deltaX: event.deltaX, deltaY: event.deltaY),
            event: event,
            at: screenPoint,
            delivered: delivered,
            rail: rail,
            body: body
        )

        if momentum.contains(.cancelled) || momentum.contains(.ended) {
            wheelGesture.cancel()
        } else if phase.contains(.cancelled), momentum.isEmpty {
            wheelGesture.cancel()
        }
        return swallow
    }

    /// Which scroll view a gesture beginning at this point belongs to.
    ///
    /// - Returns: the rail, the transcript body, or the version paging when the
    ///   gesture began on neither.
    private func wheelOwner(
        at screenPoint: CGPoint,
        railFrame: CGRect,
        bodyFrame: CGRect
    ) -> HUDWheelOwner {
        if railFrame.contains(screenPoint) { return .rail }
        if bodyFrame.contains(screenPoint) { return .body }
        return .versions
    }

    /// Applies one wheel event to the owner the gesture latched.
    ///
    /// - Returns: whether the event is swallowed by the card.
    private func applyWheel(
        owner: HUDWheelOwner,
        axis: HUDWheelAxis?,
        event: HUDPointerEvent,
        at screenPoint: CGPoint,
        delivered: Bool,
        rail: NSScrollView?,
        body: NSScrollView?
    ) -> Bool {
        switch owner {
        case .rail:
            rewriteSwipe.cancel()
            // A rail-owned gesture is applied by the card on every path and
            // swallowed when AppKit delivered it. Leaving a delivered event to
            // the native scroll view would make the applier depend on where
            // AppKit latched the gesture; the card already knows the owner, so
            // it applies the same travel once and the native view never sees
            // it. Background events were never delivered, so there is nothing
            // to swallow. A stationary beginning has no axis yet and nothing
            // to apply, but it still belongs to the rail and is swallowed.
            // A non-precise wheel reports lines, not points. The scroll view's
            // own line height is what AppKit would multiply the delta by, so
            // the card uses the same setting to keep one notch the same travel
            // on both appliers.
            if let axis, let rail {
                let scale = event.isPrecise ? 1 : rail.horizontalLineScroll
                // While the card is arriving, a clip still inside the residue
                // window is an appearance position, so travel is applied to
                // the intended origin. A clip already outside that window is
                // a reveal or a person's position even if the record has not
                // seen it, and travel starts there. Once the opening
                // correction has decided there is no residue to inherit, and
                // the clip is the position.
                let clipOrigin = rail.contentView.bounds.origin
                let followClip = railPositionRestored || Self.railWriteIsPersons(
                    origin: clipOrigin,
                    intended: railIntendedOrigin,
                    window: Self.railResidueWindow(for: rail)
                )
                let base = followClip ? nil : railIntendedOrigin.x
                if Self.scrollRail(
                    scrollView: rail,
                    step: axis.step(deltaX: event.deltaX, deltaY: event.deltaY) * scale,
                    base: base
                ) {
                    // A wheel that moved the rail is the person's position,
                    // however small: the opening correction puts the rail back
                    // on this rather than on its first style.
                    railIntendedOrigin = rail.contentView.bounds.origin
                    // The explicit wheel ends any reveal follow, including the
                    // one its own far write armed through the bounds observer,
                    // so later in-window writes are residue, not the person's.
                    railOriginTracks = false
                    railTrackedOrigin = nil
                }
            }
            return delivered
        case .body:
            // A delivered vertical wheel is the native scroll view's; only the
            // background one has to be applied here. The horizontal swipe that
            // pages the versions stays with `handleRewriteSwipe`.
            if !delivered,
               abs(event.deltaY) > abs(event.deltaX),
               let body {
                let scale = event.isPrecise ? 1 : body.verticalLineScroll
                _ = Self.scrollVertical(scrollView: body, deltaY: event.deltaY * scale)
            }
            handleRewriteSwipe(event, at: screenPoint)
            return false
        case .versions:
            handleRewriteSwipe(event, at: screenPoint)
            return false
        case .none:
            return false
        }
    }

    /// Turns a precise horizontal trackpad swipe over the text body into one
    /// previous/next move.
    ///
    /// The event is observed, not swallowed: the vertical scroll view keeps its
    /// wheel, and the rail is a separate owner, so its wheel is never taken.
    /// A mostly vertical gesture cancels the swipe, and momentum after the
    /// fingers lift is ignored.
    private func handleRewriteSwipe(_ event: HUDPointerEvent, at screenPoint: CGPoint) {
        guard let card = model.rewrite,
              !card.isBlocked,
              !model.isEditingTranscript,
              event.isPrecise,
              event.momentumPhase.isEmpty
        else {
            rewriteSwipe.cancel()
            return
        }
        let cardFrame = self.cardFrame
        let body = Self.rewriteBodyFrame(cardFrame: cardFrame, card: card)
        guard body.contains(screenPoint) else {
            rewriteSwipe.cancel()
            return
        }
        let phase = event.phase
        if phase.contains(.cancelled) {
            rewriteSwipe.cancel()
            return
        }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            rewriteSwipe.begin()
        }
        // `scrollingDeltaX/Y` carry the person's natural-scrolling setting:
        // AppKit inverts them for it and says so on the event. The gesture is
        // defined in finger deltas, so the inversion is undone once, for both
        // axes, and the classifier sees one convention on every Mac: the same
        // swipe asks for the same version whatever the preference.
        let deltas = RewriteSwipeGesture.fingerDeltas(
            rawHorizontal: event.deltaX,
            rawVertical: event.deltaY,
            directionInverted: event.isDirectionInvertedFromDevice
        )
        if let direction = rewriteSwipe.add(horizontal: deltas.horizontal, vertical: deltas.vertical) {
            move(to: direction)
        } else if phase.contains(.ended), let direction = rewriteSwipe.end() {
            move(to: direction)
        }
    }

    private func move(to direction: RewriteSwipeGesture.Direction) {
        switch direction {
        case .previous:
            actions.previousVersion?()
        case .next:
            actions.nextVersion?()
        }
        Log.shared.info("hud.rewrite.swiped", ["direction": .string("\(direction)")])
    }

    /// The part of the card a horizontal swipe may page: the text body, not the
    /// header and not the version row.
    static func rewriteBodyFrame(cardFrame: CGRect, card: RewriteCard) -> CGRect {
        let extra = rewriteExtraHeight(card)
        let bodyHeight = max(0, cardFrame.height - HUDTheme.headerHeight - 1 - extra)
        return CGRect(
            x: cardFrame.minX,
            y: cardFrame.minY + extra,
            width: cardFrame.width,
            height: bodyHeight
        )
    }

    /// The part of the card the text of a body scrolled vertically lives in.
    ///
    /// A plain transcript is the card under the header and its hairline; a
    /// versioned one gives the rewrite layer the bottom of the card, so the
    /// body ends where the layer begins.
    ///
    /// - Parameters:
    ///   - cardFrame: the card's rectangle, in screen coordinates.
    ///   - card: the rewrite layer, or `nil` for a plain transcript.
    /// - Returns: the body's rectangle, in the same coordinates.
    static func transcriptBodyFrame(cardFrame: CGRect, card: RewriteCard?) -> CGRect {
        guard let card else {
            return CGRect(
                x: cardFrame.minX,
                y: cardFrame.minY,
                width: cardFrame.width,
                height: max(0, cardFrame.height - HUDTheme.headerHeight - 1)
            )
        }
        return rewriteBodyFrame(cardFrame: cardFrame, card: card)
    }

    // MARK: - The rail and the wheel

    /// The tallest a horizontal rail's scroll view can be, in points.
    ///
    /// The chip row is one 24 point line. The transcript body is the card's
    /// other scroll view, and it is told apart by the room it has to scroll —
    /// the rail never has any vertically — and by its height, which is the
    /// body's rather than one line of chips.
    static let maximumRailHeight: CGFloat = 36

    /// The band of the card the style chips occupy.
    ///
    /// The layer under the body is drawn from the bottom of the card up: the
    /// card's vertical padding, then the chip row, then the gap above it. The
    /// row is therefore always the same 24 points above the card's bottom edge,
    /// whether or not a note line sits under the body, and the version arrows at
    /// both ends are left out of the band so a scroll over one of them stays a
    /// click's business.
    ///
    /// - Parameters:
    ///   - cardFrame: the card's rectangle, in screen coordinates.
    ///   - card: the rewrite layer the card is showing, if any.
    /// - Returns: the rail's rectangle, or ``CGRect/zero`` when the card draws
    ///   no chips.
    static func rewriteChipRowFrame(cardFrame: CGRect, card: RewriteCard?) -> CGRect {
        guard let card, card.showsChips else { return .zero }
        let leading = HUDTheme.padding + HUDRewriteLayout.versionArrowWidth
        let showsRerun = card.selectedVersion.styleID != nil
            && !card.isStreaming
            && !card.isBlocked
        let trailing = leading
            + (showsRerun ? HUDRewriteLayout.chipGap + HUDRewriteLayout.versionArrowWidth : 0)
        let width = cardFrame.width - leading - trailing
        guard width > 0, cardFrame.height > 0 else { return .zero }
        return CGRect(
            x: cardFrame.minX + leading,
            y: cardFrame.minY + HUDState.verticalPadding,
            width: width,
            height: HUDRewriteLayout.chipHeight
        )
    }

    /// Every scroll view under a view, deepest last.
    ///
    /// - Parameter root: the view to walk.
    /// - Returns: the scroll views in the subtree, in subview order.
    static func scrollViews(in root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scrollView = root as? NSScrollView { found.append(scrollView) }
        for subview in root.subviews {
            found.append(contentsOf: scrollViews(in: subview))
        }
        return found
    }

    /// The scroll view of the style chips.
    ///
    /// The rail is the one horizontal scroll view on the card: it is one chip
    /// tall, it has more content than its viewport when the styles outgrow the
    /// card, and it never scrolls vertically. The transcript body is the other
    /// way round — never this short, and the only one with a taller document
    /// than its viewport.
    ///
    /// - Parameter root: the view the card is drawn in.
    /// - Returns: the rail's scroll view, or `nil` when the card draws none.
    static func chipRowScrollView(in root: NSView?) -> NSScrollView? {
        guard let root else { return nil }
        var short: NSScrollView?
        var wide: NSScrollView?
        for scrollView in scrollViews(in: root) {
            let clip = scrollView.contentView
            let document = scrollView.documentView
            let documentWidth = document?.frame.width ?? 0
            let documentHeight = document?.frame.height ?? 0
            // A view whose document is taller than its viewport is the body,
            // never the rail: the rail is one line and cannot scroll that way.
            guard documentHeight <= clip.bounds.height + 0.5 else { continue }
            let hasHorizontalRoom = documentWidth > clip.bounds.width + 0.5
            if scrollView.frame.height <= maximumRailHeight {
                if hasHorizontalRoom { return scrollView }
                if short == nil { short = scrollView }
            } else if hasHorizontalRoom, wide == nil {
                wide = scrollView
            }
        }
        return short ?? wide
    }

    /// The scroll view of the transcript body, when it has more than it shows.
    ///
    /// - Parameter root: the view the card is drawn in.
    /// - Returns: the tallest scroll view with a document taller than its
    ///   viewport, or `nil` when the body fits.
    static func transcriptScrollView(in root: NSView?) -> NSScrollView? {
        guard let root else { return nil }
        var best: NSScrollView?
        for scrollView in scrollViews(in: root) {
            let clip = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            guard documentHeight > clip.bounds.height + 0.5 else { continue }
            guard scrollView.frame.height > maximumRailHeight else { continue }
            if let current = best, current.contentView.bounds.height >= clip.bounds.height {
                continue
            }
            best = scrollView
        }
        return best
    }

    /// Moves the rail by one gesture's travel, from the position the person last gave it.
    ///
    /// The travel has already been read from the axis the gesture latched, and
    /// it already carries the person's natural-scrolling setting: a negative
    /// horizontal delta means the fingers went left, which reveals what is on
    /// the right, so the clip's origin increases. One step is the travel
    /// subtracted from the base, held between the two ends of the content. The
    /// rail never bounces: the end of the content is where the gesture stops.
    ///
    /// The base is not always the live clip origin. While the card is arriving,
    /// the appearance's frame transform has the clip a residue inside its
    /// content, and that residue is not a position anybody chose: adding the
    /// person's travel to it writes the residue into the position the card
    /// records as the person's, and the opening correction then restores the
    /// rail to the residue for the rest of the card's life. The caller
    /// therefore passes the last origin the person or the card intended, which
    /// is the clip origin once the opening correction has been decided and the
    /// intended origin before that. See the rail branch of ``pointerEvent``.
    ///
    /// - Parameters:
    ///   - scrollView: the rail.
    ///   - step: the travel in points, with any line delta already converted.
    ///   - base: the origin to apply the travel to, or `nil` to use the clip's
    ///     origin as it stands.
    /// - Returns: whether the rail's logical origin moved. The clip is written
    ///   only when that movement's target differs from the live clip origin.
    @discardableResult
    static func scrollRail(scrollView: NSScrollView, step: CGFloat, base: CGFloat? = nil) -> Bool {
        guard step != 0 else { return false }
        let clip = scrollView.contentView
        let documentWidth = scrollView.documentView?.frame.width ?? 0
        let maximum = max(0, documentWidth - clip.bounds.width)
        guard maximum > 0 else { return false }
        let logicalOrigin = base ?? clip.bounds.origin.x
        let x = min(max(logicalOrigin - step, 0), maximum)
        guard x != logicalOrigin else { return false }
        let target = CGPoint(x: x, y: 0)
        if clip.bounds.origin != target {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }
        return true
    }

    /// Moves a vertical scroll view by a wheel's vertical delta.
    ///
    /// The body's document is flipped, so its origin is zero at the top: a
    /// positive `scrollingDeltaY` — the wheel rolled up, or two fingers pushed
    /// down the trackpad — goes back towards the first word, which is the origin
    /// decreasing.
    ///
    /// - Parameters:
    ///   - scrollView: the transcript body.
    ///   - deltaY: the vertical travel in points, with any line delta already
    ///     converted.
    /// - Returns: whether the body moved.
    @discardableResult
    static func scrollVertical(scrollView: NSScrollView, deltaY: CGFloat) -> Bool {
        let clip = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maximum = max(0, documentHeight - clip.bounds.height)
        guard maximum > 0, deltaY != 0 else { return false }
        let y = min(max(clip.bounds.origin.y - deltaY, 0), maximum)
        guard y != clip.bounds.origin.y else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    /// Records whether the pointer is over the card.
    ///
    /// The card is the only part of the panel that is drawn: the rest is the
    /// margin its shadow needs, and a pointer there is not reading anything.
    /// The card does not take the mouse until it has arrived either: while the
    /// shape is still coming out of the notch there is no card to click, and the
    /// strip the panel covers above it belongs to whatever is under it.
    private func updatePointer(at screenPoint: CGPoint) {
        let card = cardFrame
        let inside = card.contains(screenPoint)
        // The panel takes the mouse only over the card, and only once the card
        // is there. A click anywhere else in the panel's rectangle belongs to
        // whatever is under it, and this is what hands it back.
        let shouldIgnore = !(inside && frameModel.presence >= 0.98)
        if panel.ignoresMouseEvents != shouldIgnore {
            panel.ignoresMouseEvents = shouldIgnore
        }
        let detectedHover = inside ? hoveredAction(at: screenPoint, in: card) : nil
        if model.hoveredAction != detectedHover {
            model.hoveredAction = detectedHover
        }
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        // A card that offers the chips restarts its countdown when the pointer
        // leaves it. Crossing the card is how a person says they are done with
        // it, so what was left of the long dwell is not kept.
        if !inside, model.rewrite != nil, var clock = dwellClock {
            clock.restart(duration: HUDDwell.rewriteLeaveSeconds, now: CACurrentMediaTime())
            dwellClock = clock
        }
        Log.shared.info(inside ? "hud.pointer.inside" : "hud.pointer.outside")
    }

    /// Determines which trailing header action button the pointer is hovering over,
    /// so button hover highlights and themed tooltips work even when Dot is in the background.
    private func hoveredAction(at screenPoint: CGPoint, in card: CGRect) -> HUDAction? {
        let items: [HUDAction]
        let headerH: CGFloat
        switch model.mode {
        case .recording:
            items = HUDAction.available([.stop, .cancel], in: actions)
            headerH = model.liveText.isEmpty ? card.height : HUDState.headerHeight
        case .working:
            items = HUDAction.available([.cancel], in: actions)
            headerH = card.height
        case .transcript:
            items = HUDAction.available(
                [.copy, .paste, .history, .settings, .close],
                in: actions,
                versioned: model.rewrite != nil
            )
            headerH = HUDTheme.headerHeight
        case .message:
            items = HUDAction.available([.close], in: actions)
            headerH = card.height
        case .ready:
            items = HUDAction.available([.settings, .close], in: actions)
            headerH = card.height
        }
        guard !items.isEmpty else { return nil }
        // In screen coordinates, card.maxY is the top edge of the card.
        let headerMinY = card.maxY - headerH
        guard screenPoint.y >= headerMinY, screenPoint.y <= card.maxY else { return nil }
        let centerY = card.maxY - headerH / 2
        guard abs(screenPoint.y - centerY) <= HUDTheme.actionSize / 2 + 4 else { return nil }

        let size = HUDTheme.actionSize
        let spacing: CGFloat = 4
        let totalWidth = CGFloat(items.count) * size + CGFloat(max(0, items.count - 1)) * spacing
        // A message that offers a titled button draws it to the left of the
        // icon buttons, so the run of icons starts that much further left. The
        // titled button names itself and needs no tooltip, so a pointer over it
        // reports no action.
        let titleWidth: CGFloat
        if case .message = model.mode, let action = model.messageAction {
            titleWidth = HUDView.messageActionWidth(title: action.title)
        } else {
            titleWidth = 0
        }
        let startX = card.maxX - HUDTheme.padding - titleWidth - totalWidth
        let relX = screenPoint.x - startX
        guard relX >= -2, relX <= totalWidth + 2 else { return nil }
        let step = size + spacing
        let index = Int((relX + 2) / step)
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    /// Dismisses the launch card after its own dwell.
    ///
    /// The timer checks the state first: a recording that started while the
    /// greeting was up must not be hidden by the greeting's timer.
    private func scheduleReadyDismiss() {
        dismissTimer?.invalidate()
        guard readyDwellSeconds > 0 else { return }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: readyDwellSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.isVisible else { return }
                guard case .ready = self.model.mode else { return }
                self.hide()
            }
        }
    }

    private func startRendering() {
        isRenderLoopSleepingForStaticIdle = false
        idleDwellTimer?.invalidate()
        idleDwellTimer = nil
        if !offscreen, renderActivity == nil {
            renderActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Animate the HUD island"
            )
        }
        onRenderActivityChange?(true)
        renderLoop.wakeProvider = { [weak self] in
            guard let self, let view = self.panel.contentView else { return nil }
            return (view, self.offscreen ? nil : Self.screenID(of: self.panel.screen))
        }
        renderLoop.start(
            on: panel.contentView,
            screenID: offscreen ? nil : Self.screenID(of: panel.screen),
            offscreen: offscreen
        ) { [weak self] time in
            guard let self else { return }
            self.tick(now: time)
        }
    }

    private func ensureRenderingActive() {
        guard isRenderLoopSleepingForStaticIdle else {
            idleDwellTimer?.invalidate()
            idleDwellTimer = nil
            return
        }
        lastTick = nil
        lastWakeTimestamp = nil
        startRendering()
    }

    private func sleepRenderLoopIfStaticIdle() {
        guard !offscreen, model.isVisible else { return }
        isRenderLoopSleepingForStaticIdle = true
        renderLoop.stop()
        lastTick = nil
        lastWakeTimestamp = nil
        if let renderActivity {
            ProcessInfo.processInfo.endActivity(renderActivity)
            self.renderActivity = nil
        }
        onRenderActivityChange?(false)
        if dwellClock != nil, idleDwellTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateDwell(now: CACurrentMediaTime())
                }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            idleDwellTimer = timer
        }
    }

    private static func screenID(of screen: NSScreen?) -> Int? {
        guard let screen else { return nil }
        return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .intValue
    }

    private func stopRendering() {
        isRenderLoopSleepingForStaticIdle = false
        renderLoop.stop()
        idleDwellTimer?.invalidate()
        idleDwellTimer = nil
        lastTick = nil
        lastWakeTimestamp = nil
        if let renderActivity {
            ProcessInfo.processInfo.endActivity(renderActivity)
            self.renderActivity = nil
        }
        onRenderActivityChange?(false)
        renderFallbackTimer?.invalidate()
        renderFallbackTimer = nil
        linkFallbackTimer?.invalidate()
        linkFallbackTimer = nil
    }

    /// Shows the card outright when the render loop has not produced a frame
    /// shortly after the panel was ordered front.
    ///
    /// The entry animation is the normal path. This is only the guarantee that
    /// a stalled loop cannot leave the island invisible: the springs snap to
    /// their settled values and the fallback is logged without any content.
    private func scheduleRenderFallback() {
        renderFallbackTimer?.invalidate()
        let timer = Timer(timeInterval: Self.renderFallbackDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyRenderFallback()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        renderFallbackTimer = timer

        linkFallbackTimer?.invalidate()
        let linkTimer = Timer(timeInterval: Self.linkFallbackDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyLinkFallback()
            }
        }
        RunLoop.main.add(linkTimer, forMode: .common)
        linkFallbackTimer = linkTimer
    }

    private func applyRenderFallback() {
        renderFallbackTimer = nil
        // The island is invisible only while the shape has not left the notch,
        // which is the first few frames of the emergence. A card that is half
        // way out of the screen is drawn where the person is looking, so it is
        // not this watchdog's business: what it may not leave behind is a card
        // that was never drawn at all.
        guard model.isVisible, (!hasRenderedSincePresent || frameModel.presence < 0.05) else { return }
        let elapsed = (CACurrentMediaTime() - presentedAt) * 1000
        emergeSpring.to(target: 1)
        emergeSpring.snap(to: 1)
        reduceFade.to(1)
        reduceFade.snap(to: 1)
        contentSpring.to(target: 1)
        contentSpring.snap(to: 1)
        frameModel.emergence = 1
        frameModel.presence = 1
        frameModel.content = 1
        model.emergence = 1
        model.presence = 1
        model.content = 1
        debugFallbackCount += 1
        Log.shared.warn("hud.render.fallback", [
            "elapsed_ms": .double(elapsed),
            "panel_visible": .bool(panel.isVisible),
            "loop_running": .bool(renderLoop.isRunning),
        ])
    }

    private func applyLinkFallback() {
        linkFallbackTimer = nil
        guard model.isVisible, !hasRenderedSincePresent, renderLoop.activeBackend == .displayLink else { return }
        renderLoop.fallbackToTimer()
        frameStats.note(backend: HUDRenderLoop.Backend.timer.rawValue)
        Log.shared.info("hud.renderLoop.fallback", [
            "reason": .string("displayLink did not render"),
        ])
    }

    /// Checks that ordering the panel front actually made it visible.
    ///
    /// `orderFrontRegardless` can be missed while the window server is
    /// settling, so the card retries once with `orderFront(nil)`. Neither call
    /// activates the app or changes the panel's level: the panel stays
    /// nonactivating and can never become key.
    private func verifyPanelVisibility() {
        guard !panel.isVisible else { return }
        panel.orderFront(nil)
        Log.shared.info("hud.panel.orderfront", [
            "visible": .bool(panel.isVisible),
        ])
    }

    private func tick(now: CFTimeInterval) {
        guard panel.isVisible || offscreen else { return }
        let tickStarted = CFAbsoluteTimeGetCurrent()
        let wakeDeltaMS = lastWakeTimestamp.map { max(0, (tickStarted - $0) * 1000) }
        lastWakeTimestamp = tickStarted
        if !hasReportedFirstTick {
            hasReportedFirstTick = true
            Log.shared.info("hud.render.tick", [
                "elapsed_ms": .double((now - presentedAt) * 1000),
                "panel_visible": .bool(panel.isVisible),
            ])
        }

        let dt = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 0
        lastTick = now
        if case .recording = model.mode, model.isVisible, !frameStats.isRecording {
            frameStats.start(backend: renderLoop.activeBackend.rawValue)
        }

        advanceAppearance(by: dt)
        if case .transcript = model.mode, model.rewrite?.showsChips == true {
            restoreTheRailsOpeningPosition(now: now)
        }

        let nextLevel: Double
        if case .recording = model.mode, model.isVisible {
            if isPreviewingVisualizer {
                let previewTime = Self.previewPhase(now: now, startedAt: recordingStartedAt)
                let voice = DictationScript.level(at: previewTime)
                meter.push(decibels: VisualizerFeed.decibels(for: voice), now: now)
                nextLevel = meter.envelope
                advanceSpectrum(target: DictationScript.bands(at: previewTime), dt: dt, now: now)
                let nextElapsed = HUDClock.string(for: now - recordingStartedAt + 2)
                if frameModel.elapsedLabel != nextElapsed {
                    frameModel.elapsedLabel = nextElapsed
                }
            } else {
                let rms = levelProvider?() ?? 0
                meter.push(decibels: AudioLevel.decibels(rms), now: now)
                nextLevel = meter.envelope
                let rawSpec = spectrumProvider?() ?? .zero
                advanceSpectrum(target: rawSpec, dt: dt, now: now)
                let nextElapsed = HUDClock.string(for: now - recordingStartedAt)
                if frameModel.elapsedLabel != nextElapsed {
                    frameModel.elapsedLabel = nextElapsed
                }
            }
        } else {
            // The card still breathes while it waits or dismisses.
            nextLevel = max(0, frameModel.level - dt * 3)
        }
        if frameModel.level != nextLevel {
            frameModel.level = nextLevel
        }

        // The shape arrives when a recording starts and settles when it ends.
        // Reduce Motion keeps the fade and drops the growth, which is the part
        // that moves.
        var revealTarget: Double = 0
        if case .recording = model.mode, model.isVisible { revealTarget = 1 }
        let revealTau = revealTarget > reveal ? 0.10 : 0.22
        reveal += (revealTarget - reveal) * (1 - exp(-dt / revealTau))
        if abs(revealTarget - reveal) < 0.002 { reveal = revealTarget }
        let nextReveal = reduceMotion ? revealTarget : reveal
        if frameModel.reveal != nextReveal {
            frameModel.reveal = nextReveal
        }

        let isRecording = if case .recording = model.mode { true } else { false }
        let written = meter.writtenSamples
        if written != lastPublishedWrittenSamples || frameModel.history.isEmpty || frameModel.spectrumHistory.isEmpty {
            lastPublishedWrittenSamples = written
            if isRecording || reveal > 0 || !historyBuffer.isEmpty {
                meter.copyOrderedHistory(into: &historyBuffer)
                frameModel.history = historyBuffer
                meter.copyOrderedSpeechTops(into: &speechTopBuffer)
                frameModel.speechTops = speechTopBuffer
            }
            if isRecording || reveal > 0 || !spectrumBuffer.isEmpty {
                spectrum.copyOrderedRing(into: &spectrumBuffer)
                frameModel.spectrumHistory = spectrumBuffer
            }
        }
        if let ending = model.rewriteEnding,
           HUDRewriteActivity.arcFade(
               isRunning: false,
               endedAt: ending.at,
               time: now,
               reduceMotion: reduceMotion
           ) <= 0 {
            model.rewriteEnding = nil
        }

        let isWorking = if case .working = model.mode { true } else { false }
        let isTranscriptAnimating: Bool = {
            guard case .transcript = model.mode else { return false }
            return model.rewrite?.activeStyleTitle != nil
                || model.rewriteEnding != nil
                || model.rewrite?.isStreaming == true
                || !(model.rewrite?.draftChunks.isEmpty ?? true)
        }()

        let nextPhase = meter.phase
        if frameModel.phase != nextPhase { frameModel.phase = nextPhase }
        let nextCeiling = meter.ceiling
        if frameModel.ceiling != nextCeiling { frameModel.ceiling = nextCeiling }
        let nextSpeechTop = meter.speechTop
        if frameModel.speechTop != nextSpeechTop { frameModel.speechTop = nextSpeechTop }
        if isRecording || isTranscriptAnimating || frameModel.reveal > 0 {
            let nextTime = reduceMotion ? 1.8 : now
            if frameModel.time != nextTime { frameModel.time = nextTime }
            if isTranscriptAnimating, frameModel.rewriteTime != nextTime {
                frameModel.rewriteTime = nextTime
            }
        }
        if isRecording {
            let nextPulse = reduceMotion ? 0 : now.truncatingRemainder(dividingBy: 1.1) / 1.1
            if frameModel.pulse != nextPulse { frameModel.pulse = nextPulse }
        } else if frameModel.pulse != 0 {
            frameModel.pulse = 0
        }
        if isRecording || frameModel.reveal > 0 {
            let frame = frameModel.currentVisualizerFrame(
                visualizer: model.visualizer,
                material: model.material,
                reduceMotion: reduceMotion
            )
            frameModel.visualizerSink.push(frame)
            if isRecording {
                frameModel.liveDotSink.push(
                    frameModel.currentLiveDotFrame(material: model.material, reduceMotion: reduceMotion)
                )
            }
#if DEBUG
            if FrameLeafProbe.captures {
                FrameLeafProbe.waveformBodies += 1
            }
#endif
        }
        if isWorking {
            let nextShimmer = reduceMotion ? 0 : now.truncatingRemainder(dividingBy: 1.4) / 1.4
            if frameModel.shimmer != nextShimmer { frameModel.shimmer = nextShimmer }
        } else if frameModel.shimmer != 0 {
            frameModel.shimmer = 0
        }
        updateDwell(now: now)
        frameStats.record(
            intervalMS: dt * 1000,
            durationMS: (CFAbsoluteTimeGetCurrent() - tickStarted) * 1000,
            wakeDeltaMS: wakeDeltaMS
        )
        hasRenderedSincePresent = true
        renderFallbackTimer?.invalidate()
        renderFallbackTimer = nil
        linkFallbackTimer?.invalidate()
        linkFallbackTimer = nil
        debugTickCount += 1
        let showsRewriteChips: Bool = {
            guard case .transcript = model.mode else { return false }
            return model.rewrite?.showsChips == true
        }()
        if dismissal == nil,
           debugAppearanceAtRest,
           !isRecording,
           !isWorking,
           !isTranscriptAnimating,
           frameModel.reveal <= 0,
           !showsRewriteChips || railPositionRestored {
            sleepRenderLoopIfStaticIdle()
        }
#if DEBUG
        HUDTickProbe.recordDuration((CFAbsoluteTimeGetCurrent() - tickStarted) * 1000)
        HUDTickProbe.record(
            time: now,
            level: frameModel.level,
            phase: frameModel.phase,
            clock: frameModel.time,
            bands: frameModel.spectrumHistory.last?.bands ?? AudioSpectrumFrame.zero.bands,
            sample: frameModel.spectrumHistory.last?.sample,
            writtenSamples: meter.writtenSamples,
            model: model
        )
#endif
    }

    /// Reads the pointer once the shape has arrived.
    ///
    /// The panel takes the mouse only over the card and only once it is there,
    /// and a pointer that does not move produces no event: without this read, a
    /// card that arrived under a still pointer would ignore the first click on
    /// it.
    private func refreshThePointerAfterArrival() {
        guard debugPointerOverride == nil, !offscreen else { return }
        updatePointer(at: NSEvent.mouseLocation)
    }

    /// Moves the card's appearance forward by `dt` seconds.
    ///
    /// It is the one place the appearance advances, so the frame loop and a test
    /// that moves the clock itself cannot disagree about what a second of the
    /// card's life is. The springs and the departure are the whole of it: the
    /// shape's progress is the spring's value, `presence` is that value clamped,
    /// and the dismissal is a shape that leaves after the content has gone.
    ///
    /// - Parameter dt: the time that passed, in seconds.
    private func advanceAppearance(by dt: Double) {
        func writeFrame(_ value: Double, to keyPath: ReferenceWritableKeyPath<HUDFrameModel, Double>) {
            guard frameModel[keyPath: keyPath] != value else { return }
            frameModel[keyPath: keyPath] = value
            hasSyncedRestAppearance = false
        }
        func syncModelIfRested() {
            guard debugAppearanceAtRest else {
                hasSyncedRestAppearance = false
                return
            }
            guard !hasSyncedRestAppearance else { return }
            if model.emergence != frameModel.emergence { model.emergence = frameModel.emergence }
            if model.presence != frameModel.presence { model.presence = frameModel.presence }
            if model.content != frameModel.content { model.content = frameModel.content }
            hasSyncedRestAppearance = true
        }
        if reduceMotion {
            reduceFade.advance(dt)
            if reduceFade.isResting { reduceFade.snap(to: reduceFade.target) }
            emergeSpring.snap(to: reduceFade.value)
            writeFrame(reduceFade.value, to: \.emergence)
            writeFrame(reduceFade.value, to: \.presence)
        } else {
            emergeSpring.advance(dt)
            if emergeSpring.isResting { emergeSpring.snap(to: emergeSpring.target) }
            writeFrame(emergeSpring.value, to: \.emergence)
            writeFrame(min(max(emergeSpring.value, 0), 1), to: \.presence)
        }
        contentSpring.advance(dt)
        if contentSpring.isResting { contentSpring.snap(to: contentSpring.target) }
        writeFrame(min(max(contentSpring.value, 0), 1), to: \.content)

        if debugHoldTheEntrance {
            // Keep the card visibly arrived but one step short of rest, so the
            // opening correction cannot decide while the render loop ticks.
            let held = 0.99
            if reduceMotion {
                reduceFade.snap(to: held)
                reduceFade.to(1)
                emergeSpring.snap(to: held)
                writeFrame(held, to: \.emergence)
                writeFrame(held, to: \.presence)
            } else {
                emergeSpring.snap(to: held)
                writeFrame(held, to: \.emergence)
                writeFrame(held, to: \.presence)
            }
            contentSpring.snap(to: held)
            writeFrame(held, to: \.content)
        } else {
            syncModelIfRested()
        }

        if frameModel.presence >= 0.98, !hasReadPointerSinceArrival {
            hasReadPointerSinceArrival = true
            refreshThePointerAfterArrival()
        }

        guard var dismissal else { return }
        dismissal.elapsed += dt
        if !dismissal.shapeStarted,
           reduceMotion || frameModel.content < 0.05 || dismissal.elapsed >= 0.12 {
            dismissal.shapeStarted = true
            if !reduceMotion {
                emergeSpring.to(target: 0, duration: 0.45, bounce: 0)
            }
        }
        let left = reduceMotion ? frameModel.presence <= 0.001 : emergeSpring.value <= 0.001
        if dismissal.shapeStarted, left || dismissal.elapsed >= 1 {
            self.dismissal = nil
            finishHiding()
            return
        }
        self.dismissal = dismissal
    }

    /// How far the card's appearance can leave the rail from where it belongs, in points.
    ///
    /// SwiftUI hands the card's appearance scale and offset to the scroll view
    /// it hosts as a frame transform, and AppKit answers each one by
    /// re-deriving the rail's clip bounds, which it leaves inside its content.
    /// The residue is a small number of device pixels, so its reach in points
    /// shrinks as the display puts more pixels in a point: measured here it is
    /// one pixel, 0.9994 points at 1x and 0.4994 points at 2x, and the largest
    /// seen on a 1x backing is three pixels, 3.0 points.
    ///
    /// The window is therefore a function of the backing scale. At 1x it is
    /// 3.5 points, three pixels plus half a point of headroom, so the largest
    /// residue measured there is still the appearance's and can still be
    /// corrected. A constant 2.5 points would classify a three-pixel residue
    /// as somebody's position and leave it, which is the failure this replaces.
    /// From 2x up the window stays at 2.5 points, the value the card shipped
    /// with: three pixels there is 1.5 points and the measured residue is one
    /// pixel, so 2.5 points is already more than the residue can reach.
    ///
    /// A rail with no window is read as 2x, the scale of every display this
    /// card has been measured on, and the caller is expected to fall back the
    /// same way: see ``railResidueWindow(for:)``.
    ///
    /// - Parameter backingScale: the display's backing scale, in pixels per point.
    /// - Returns: the residue's reach in points at that scale.
    static func railResidueWindow(backingScale: CGFloat) -> CGFloat {
        max(2.5, 3.5 / max(backingScale, 1))
    }

    /// The residue window of the display a rail is drawn on.
    ///
    /// The rail's window is the display it is composited on, and its backing
    /// scale is the one AppKit rounds the clip's origin to. A rail that is not
    /// in a window yet has no display to read, and is taken as 2x, the scale of
    /// every display this card has been measured on; that fallback is the same
    /// one ``railResidueWindow(backingScale:)`` documents.
    ///
    /// - Parameter rail: the card's rail.
    /// - Returns: the residue's reach in points on that rail's display.
    static func railResidueWindow(for rail: NSScrollView) -> CGFloat {
        railResidueWindow(backingScale: rail.window?.backingScaleFactor ?? 2)
    }

    /// Where the opening correction puts the rail, or `nil` when it leaves it.
    ///
    /// The correction only touches the appearance's own residue. A rail whose
    /// clip sits inside the residue window of the position the person last gave
    /// it is holding that residue over the position, and is put back on it. A
    /// rail further than the window from that position was put there by
    /// something else and is left alone, and one already on it has nothing to
    /// correct.
    ///
    /// - Parameters:
    ///   - origin: where the rail's clip is now.
    ///   - intended: the position the person last wrote, or `.zero` when they
    ///     wrote none.
    ///   - window: the residue's reach, in points, from ``railResidueWindow(backingScale:)``.
    ///   - scrollRange: how far the rail's document travels on each axis.
    /// - Returns: the origin to scroll to, held inside the document, or `nil`
    ///   to leave the rail where it is.
    static func railOpeningOrigin(
        origin: CGPoint,
        intended: CGPoint,
        window: CGFloat,
        scrollRange: CGSize
    ) -> CGPoint? {
        guard origin != intended,
              abs(origin.x - intended.x) <= window,
              abs(origin.y - intended.y) <= window
        else { return nil }
        return CGPoint(
            x: min(max(intended.x, 0), max(0, scrollRange.width)),
            y: min(max(intended.y, 0), max(0, scrollRange.height))
        )
    }

    /// Puts the style rail back on the position the person gave it once the card has arrived.
    ///
    /// SwiftUI hands the card's appearance scale and offset to the scroll view
    /// it hosts as a frame transform, and AppKit answers each one by
    /// re-deriving the rail's clip bounds: the clip is left a couple of points
    /// inside its content, a residue that depends on the frames the appearance
    /// happened to take. Nothing else writes it back, so the card restores it
    /// itself once per appearance.
    ///
    /// What it restores is the position the person last wrote, not zero. Every
    /// way of reaching a position is the person's, whether it is the wheel, the
    /// versions' arrows, the row's arrow keys, its VoiceOver actions or the
    /// scroll a styled version opens on, and each of them records what it
    /// wrote. A card with a style selected therefore needs no rule of its own:
    /// the row opens on that style, which is one of the positions the person's
    /// own reveal wrote.
    private func restoreTheRailsOpeningPosition(now: CFTimeInterval) {
        guard let rail = cardRail() else { return }
        observeTheRailsOrigin(of: rail)
        trackTheRailsOriginToRest(rail, now: now)
        guard !railPositionRestored, !debugHoldTheOpeningCorrection, debugAppearanceAtRest else { return }
        // The rail's frame changes while the card's own size springs to the
        // layer's height, and a correction made during that would be answered by
        // the transform that is still arriving. One quiet frame decides it.
        guard rail.frame == lastRailFrame else {
            lastRailFrame = rail.frame
            return
        }
        railPositionRestored = true
        lastRailFrame = nil
        let clip = rail.contentView
        let document = rail.documentView?.frame.size ?? .zero
        let scrollRange = CGSize(
            width: document.width - clip.bounds.width,
            height: document.height - clip.bounds.height
        )
        guard let origin = Self.railOpeningOrigin(
            origin: clip.bounds.origin,
            intended: railIntendedOrigin,
            window: Self.railResidueWindow(for: rail),
            scrollRange: scrollRange
        ) else { return }
        isCorrectingRailOrigin = true
        clip.scroll(to: origin)
        rail.reflectScrolledClipView(clip)
        isCorrectingRailOrigin = false
    }

    /// The card's style rail, as the appearance correction reads it.
    ///
    /// The row is laid out again as a new view when a card arrives, which gives
    /// it a new scroll view. One that is no longer in the card's tree is looked
    /// for again.
    ///
    /// - Returns: the rail, or `nil` while the card draws none.
    private func cardRail() -> NSScrollView? {
        if let railScrollView, railScrollView.isDescendant(of: hostingView) {
            return railScrollView
        }
        let rail = Self.chipRowScrollView(in: hostingView)
        railScrollView = rail
        return rail
    }

    /// Reads the rail's position from the clip the row scrolls, while the card is up.
    ///
    /// The row's scroll view is SwiftUI's, so the card never sees the call that
    /// moves it: the versions' arrows, the row's arrow keys, its VoiceOver
    /// actions and a styled version's scroll all write the clip from inside the
    /// row, and the clip's own bounds change is the only report of them. The
    /// appearance writes the clip the same way, so a write is taken as the
    /// person's only when it carries the rail further than the residue can
    /// reach: the appearance leaves a couple of device pixels, and every one of
    /// those actions centres a chip, which travels tens of points.
    ///
    /// The row is laid out again as a new view when a version arrives, which
    /// gives it a new clip to scroll, and the reveal that follows is one jump
    /// on the turn the new row appears. A reveal over a rail whose clip the
    /// observation kept is read here; one that lands on a clipped row before the
    /// next frame is not, and it does not need reading: a reveal that far from
    /// the residue is outside the correction's window and is left alone.
    ///
    /// - Parameter rail: the card's rail, as the appearance correction reads it.
    private func observeTheRailsOrigin(of rail: NSScrollView) {
        let clip = rail.contentView
        if clip === railOriginClip, railOriginToken != nil { return }
        if let railOriginToken {
            NotificationCenter.default.removeObserver(railOriginToken)
        }
        railOriginClip = clip
        clip.postsBoundsChangedNotifications = true
        railOriginToken = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self, weak rail] _ in
            MainActor.assumeIsolated {
                guard let self, let rail else { return }
                self.recordTheRailsOrigin(rail)
            }
        }
    }

    /// Whether a write to the rail's clip is a position the person chose.
    ///
    /// The appearance's residue moves the rail by at most the window on either
    /// axis, so a write that carries it further on either one is a position of
    /// its own. The rail scrolls sideways only and its clip's height never
    /// moves, so the answer is the larger of the two axes' travel: a write that
    /// moves the rail across counts even though nothing else moved.
    ///
    /// - Parameters:
    ///   - origin: where the clip was written to.
    ///   - intended: the position the person last wrote, or `.zero` when they
    ///     wrote none.
    ///   - window: the residue's reach, in points, from ``railResidueWindow(backingScale:)``.
    /// - Returns: whether the write is the person's position.
    static func railWriteIsPersons(origin: CGPoint, intended: CGPoint, window: CGFloat) -> Bool {
        max(abs(origin.x - intended.x), abs(origin.y - intended.y)) > window
    }

    /// Keeps the rail's position from a write that is the person's.
    ///
    /// A write further than the residue reaches qualifies, and every write after
    /// it is kept too, at any distance, until the clip holds still (see
    /// ``railFollowEnds(stillFrames:stillFor:)``): the row's reveal arrives in
    /// steps and its last ones are short. The record
    /// keeps following the rail after the opening correction has been decided,
    /// because a person who reaches a style then has still moved the rail.
    ///
    /// - Parameter rail: the card's rail.
    private func recordTheRailsOrigin(_ rail: NSScrollView) {
        guard !isCorrectingRailOrigin else { return }
        let origin = rail.contentView.bounds.origin
        guard railOriginTracks || Self.railWriteIsPersons(
            origin: origin,
            intended: railIntendedOrigin,
            window: Self.railResidueWindow(for: rail)
        ) else { return }
        railIntendedOrigin = origin
        if !railOriginTracks {
            railOriginTracks = true
            railTrackedOrigin = nil
        }
    }

    /// Ends the following once the clip has held still, by frames and by time.
    ///
    /// The origin is read once per frame and held beside the frame before it: a
    /// frame that wrote the clip moved it, and a frame that did not left it where
    /// the last write put it. The reveal's steps and the card's frames run on
    /// separate clocks, so on a loaded machine one frame can land between two
    /// steps, and so can a burst of frames the timer delivers back to back. See
    /// ``railFollowEnds(stillFrames:stillFor:)``.
    ///
    /// - Parameters:
    ///   - rail: the card's rail.
    ///   - now: the frame's time.
    private func trackTheRailsOriginToRest(_ rail: NSScrollView, now: CFTimeInterval) {
        guard railOriginTracks else { return }
        let origin = rail.contentView.bounds.origin
        if let previous = railTrackedOrigin, previous == origin {
            railStillFrames += 1
            if Self.railFollowEnds(stillFrames: railStillFrames, stillFor: now - railMovedAt) {
                railOriginTracks = false
            }
        } else {
            railStillFrames = 0
            railMovedAt = now
        }
        railTrackedOrigin = origin
    }

    /// Whether the clip has held still long enough to end following a reveal.
    ///
    /// Both limits have to be met. Three frames rule out the single late frame
    /// after a stall, which arrives long after the last write but before the
    /// reveal's next step has run. Fifty milliseconds rule out frames the timer
    /// fires back to back. A reveal that has stopped meets both within four
    /// frames at 60 Hz.
    ///
    /// - Parameters:
    ///   - stillFrames: consecutive frames that read the clip unmoved.
    ///   - stillFor: seconds since the frame that last saw the clip move.
    /// - Returns: whether the follow ends.
    static func railFollowEnds(stillFrames: Int, stillFor: TimeInterval) -> Bool {
        stillFrames >= 3 && stillFor >= 0.05
    }

    private func advanceSpectrum(target: AudioSpectrumFrame, dt: Double, now: TimeInterval) {
        // The bands arrive on the recorder's fixed scale, where ordinary speech
        // never reaches the top. ``VisualizerSpectrum`` applies the window of this
        // voice first, so the grid is drawn between the quietest and the loudest
        // this speaker's bands have been, and the filter there is what settles it.
        // The entry is stamped with the tick the meter's own history is closed on,
        // which is the tick a style looks a measurement up by.
        spectrum.advance(target: target, writtenSamples: meter.writtenSamples, dt: dt)
    }

    /// Moves the card to a state, restarting the content reveal when the kind
    /// of card changes. The clock of the recording card only changes text, so
    /// it does not restart anything.
    private func setMode(_ mode: HUDMode, size: CGSize) {
        let changed = !Self.sameKind(mode, model.mode)
        var wasTranscript = false
        var wasRecording = false
        if case .transcript = model.mode { wasTranscript = true }
        if case .recording = model.mode { wasRecording = true }
        if wasRecording { _ = frameStats.finish() }
        model.mode = mode
        #if DEBUG
        debugModeHistory.append(mode)
        #endif
        model.cardSize = size
        ensureRenderingActive()
        if changed {
            // A chip belongs to the transcript card that carried it.
            if case .transcript = mode {} else {
                model.grammar = nil
                model.grammarWasLong = false
                model.rewrite = nil
            }
            model.isEditingTranscript = false
            model.hoveredAction = nil
            clearActionFeedback()
            // A button belongs to the message that offered it. Leaving the
            // closure behind would let a card that cannot show it run it.
            model.messageAction = nil
            panel.allowsKey = false
            if wasTranscript {
                if case .transcript = mode {} else {
                    onTranscriptEnded?()
                }
            }
        }
        guard changed else { return }
        contentSpring.snap(to: 0)
        contentSpring.to(target: 1, duration: 0.34, bounce: 0.10)
        if reduceMotion {
            contentSpring.snap(to: 1)
            frameModel.content = 1
            model.content = 1
        }
    }

    /// Whether two states are the same kind of card.
    private static func sameKind(_ first: HUDMode, _ second: HUDMode) -> Bool {
        switch (first, second) {
        case (.recording, .recording),
             (.working, .working),
             (.transcript, .transcript),
             (.message, .message),
             (.ready, .ready):
            true
        default:
            false
        }
    }

    // MARK: - Placement

    /// Puts the panel at the top centre of the screen the user is on.
    ///
    /// The screen under the pointer wins, because that is the display the person
    /// is looking at; `NSScreen.main` is next and the first screen is the last
    /// resort. The panel now spans from the top edge of that display down, so the
    /// shape has the whole of the menu bar's strip to be drawn in; the card's
    /// rest rectangle is the one it always had, which
    /// ``HUDEmergence/placement(screen:panelSize:topInset:shadowPadding:)``
    /// guarantees by giving the card the room the panel gained as its inset.
    /// A display that cannot be read leaves the card with no notch to pour out
    /// of, and it fades.
    private func placePanel() {
        if let debugPlacementScreen {
            apply(
                HUDEmergence.placement(
                    screen: debugPlacementScreen,
                    panelSize: Self.panelSize,
                    topInset: Self.topInset,
                    shadowPadding: Self.shadowPadding
                ),
                index: 0,
                screens: 1
            )
            return
        }
        if offscreen {
            panel.setFrame(
                NSRect(
                    x: -10_000,
                    y: -10_000,
                    width: Self.panelSize.width,
                    height: Self.panelSize.height
                ),
                display: false
            )
            placement = nil
            renderLoop.refresh(on: panel.contentView, screenID: nil)
            return
        }

        let screens = NSScreen.screens
        let frames = screens.map(\.frame)
        let mainIndex = NSScreen.main.flatMap { main in
            screens.firstIndex { $0 === main }
        }
        guard let index = HUDPlacement.screenIndex(
            containing: NSEvent.mouseLocation,
            frames: frames,
            fallback: mainIndex
        ),
        screens.indices.contains(index)
        else { return }

        apply(
            HUDEmergence.placement(
                screen: Self.geometry(of: screens[index]),
                panelSize: Self.panelSize,
                topInset: Self.topInset,
                shadowPadding: Self.shadowPadding
            ),
            index: index,
            screens: screens.count
        )
    }

    /// The near geometry of a display, as the emergence reads it.
    ///
    /// - Parameter screen: the display.
    /// - Returns: its frame, its usable frame, the depth of its notch and the
    ///   two areas beside it.
    static func geometry(of screen: NSScreen) -> HUDEmergence.Screen {
        HUDEmergence.Screen(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeTop: screen.safeAreaInsets.top,
            leftArea: screen.auxiliaryTopLeftArea,
            rightArea: screen.auxiliaryTopRightArea
        )
    }

    /// Places the panel for one display and tells the card where its notch is.
    ///
    /// The frame is read back after it is set: AppKit constrains a window to keep
    /// part of it on a screen, and a frame that reached the top edge of the
    /// display must not be pulled back under the menu bar. ``HUDPanel`` answers
    /// that constraint with the frame it was given, and the read back is what
    /// proves the panel really is where the shape is drawn.
    ///
    /// - Parameters:
    ///   - placement: where the panel is and where its notch is.
    ///   - index: the display's index, for the log.
    ///   - screens: how many displays there are, for the log.
    private func apply(_ placement: HUDEmergence.Placement, index: Int, screens: Int) {
        if panel.frame != placement.panelFrame {
            panel.setFrame(placement.panelFrame, display: false)
        }
        renderLoop.refresh(on: panel.contentView, screenID: offscreen ? nil : Self.screenID(of: panel.screen))
        let accepted = panel.frame
        let constrained = abs(accepted.origin.y - placement.panelFrame.origin.y) > 0.5
            || abs(accepted.height - placement.panelFrame.height) > 0.5
        if constrained {
            Log.shared.warn("hud.placed.constrained", [
                "asked_y": .double(placement.panelFrame.origin.y),
                "asked_height": .double(placement.panelFrame.height),
                "granted_y": .double(accepted.origin.y),
                "granted_height": .double(accepted.height),
            ])
        }

        let changed = self.placement != placement
        self.placement = placement
        // The notch is part of the tree the card draws, so the panel's content is
        // rebuilt when the display it is on changes. A presentation that lands on
        // the same display rebuilds nothing: the card's scroll views keep their
        // positions.
        if changed {
            hostingView?.rootView = makeRootView()
        }

        let visible = placement.screen.visibleFrame
        Log.shared.info("hud.placed", [
            "screen_index": .int(index),
            "screens": .int(screens),
            "x": .double(placement.panelFrame.origin.x),
            "y": .double(placement.panelFrame.origin.y),
            "width": .double(placement.panelFrame.width),
            "height": .double(placement.panelFrame.height),
            "visible_x": .double(visible.origin.x),
            "visible_y": .double(visible.origin.y),
            "visible_width": .double(visible.width),
            "visible_height": .double(visible.height),
            "card_top_inset": .double(placement.cardTopInset),
            "notch_x": .double(placement.source.rect.origin.x),
            "notch_width": .double(placement.source.rect.width),
            "notch_height": .double(placement.source.rect.height),
            "constrained": .bool(constrained),
        ])
    }

    /// The card's rectangle on the screen, in screen coordinates.
    ///
    /// The panel reaches the display's top edge, so the card hangs by the
    /// placement's inset rather than by the shadow margin alone. Every reader of
    /// the card's place on the screen — the pointer, the wheel, the swipe — reads
    /// it here, so none of them can disagree with what is drawn.
    private var cardFrame: CGRect {
        HUDPlacement.cardFrame(
            panelFrame: panel.frame,
            cardSize: model.cardSize,
            topInset: placement?.cardTopInset ?? Self.shadowPadding
        )
    }

    deinit {
        idleDwellTimer?.invalidate()
        if let renderActivity {
            ProcessInfo.processInfo.endActivity(renderActivity)
        }
        for token in defaultNotificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        for token in workspaceNotificationTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private func observeScreens() {
        defaultNotificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.placePanel()
            }
        })
        defaultNotificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.placePanel()
            }
        })
        defaultNotificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endInlineEditing()
            }
        })
        workspaceNotificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endInlineEditing()
            }
        })
    }

    /// Shows the rewrite layer on the transcript card.
    ///
    /// The card is sized from the layer: the chips add a row, a note adds a
    /// line, and the body follows the text that is on it. A nil layer returns
    /// the card to the plain transcript it was.
    ///
    /// - Parameter card: the layer, or `nil` when the take carries no rewrite.
    func setRewrite(_ card: RewriteCard?) {
        let previous = model.rewrite
        // The arc that says a style is running leaves over 140 ms rather than in
        // the frame the phase changed, so the end is dated here, where every way
        // a run can end passes through exactly once.
        if card?.isStreaming == true {
            model.rewriteEnding = nil
        } else if previous?.isStreaming == true, let styleID = previous?.activeStyleID {
            model.rewriteEnding = RewriteEnding(styleID: styleID, at: CACurrentMediaTime())
        }
        model.rewrite = card
        if previous?.selectedVersionID != card?.selectedVersionID {
            clearActionFeedback()
        }
        ensureRenderingActive()
        guard case .transcript(let text, _, _, _) = model.mode else { return }
        model.cardSize = Self.transcriptSize(text: text, rewrite: card)
        guard let card else {
            // The rail is gone with the layer, so a gesture that belonged to it
            // cannot carry into whatever the card shows next.
            wheelGesture.cancel()
            rewriteSwipe.cancel()
            return
        }
        // A card that holds versions stays for a minute from the latest
        // interaction, so there is time to read, compare, copy and paste. The
        // countdown is suspended while the pointer is over it or a request is
        // streaming; it is a clock, not a window that never closes.
        let target = max(dwellSeconds, HUDDwell.rewriteSeconds)
        let changed = previous == nil
            || previous?.versions.count != card.versions.count
            || previous?.selectedVersionID != card.selectedVersionID
            || previous?.phase != card.phase
            || previous?.note != card.note
        if dwellClock == nil || (dwellClock?.duration ?? 0) < target || changed {
            startDwelling(duration: target)
        }
    }

    // MARK: - Sizes
    /// The size of the transcript card.
    ///
    /// The card grows with the words up to the height at which the body
    /// scrolls. The measured height is the height of the text plus the padding
    /// around it, and `HUDTranscript` holds it inside the range the card draws:
    /// below the limit the card fits the text exactly, above it the body stops
    /// growing and the text scrolls under its own scroller.
    static func transcriptSize(text: String, rewrite: RewriteCard? = nil) -> CGSize {
        guard let rewrite else {
            let body = HUDTranscript.bodyHeight(contentHeight: transcriptContentHeight(text: text))
            return CGSize(
                width: HUDState.transcriptWidth,
                height: HUDTheme.headerHeight + 1 + body
            )
        }
        let extra = rewriteExtraHeight(rewrite)
        let contentHeight: CGFloat
        if rewrite.isStreaming {
            // The body is measured from the words that were there before the
            // request. A draft that arrives one token at a time may not resize
            // the card: the number is the same for the first token and the
            // hundredth, and the draft scrolls in the room the status block and
            // the summary leave.
            contentHeight = HUDRewriteLayout.streamingContentHeight(
                originalContentHeight: transcriptContentHeight(
                    text: rewrite.original.isEmpty ? text : rewrite.original
                )
            )
        } else {
            let bodyText = rewrite.bodyText
            contentHeight = transcriptContentHeight(text: bodyText.isEmpty ? text : bodyText)
        }
        // A failure is reported on the card that is already open: its note
        // takes its line out of the body's viewport instead of growing the
        // card, so the chips cannot be pushed past the bottom edge in the frame
        // the failure arrives. Every other note grows the card as it always has.
        let noteReserve = rewrite.phase == .failed && rewrite.note != nil
            ? HUDRewriteLayout.extraHeight(
                showsChips: rewrite.showsChips,
                showsActions: false,
                noteLines: 1
            ) - HUDRewriteLayout.extraHeight(
                showsChips: rewrite.showsChips,
                showsActions: false,
                noteLines: 0
            )
            : 0
        // One budget for the header, the body and every row under it.
        let body = min(
            HUDTranscript.bodyHeight(contentHeight: contentHeight),
            HUDRewriteLayout.maximumBodyHeight(extraHeight: extra - noteReserve)
        ) - noteReserve
        return CGSize(
            width: HUDState.transcriptWidth,
            height: HUDTheme.headerHeight + 1 + max(0, body) + extra
        )
    }

    /// The height the rewrite layer adds under the body of the card.
    static func rewriteExtraHeight(_ card: RewriteCard) -> CGFloat {
        var blocked = false
        if case .blocked = card.phase { blocked = true }
        var noteLines = card.note == nil ? 0 : 1
        if blocked { noteLines += 1 }
        return HUDRewriteLayout.extraHeight(
            showsChips: card.showsChips,
            showsActions: blocked,
            noteLines: noteLines
        )
    }

    /// The height the transcript text needs, with the padding around it.
    ///
    /// - Parameter text: the transcript.
    /// - Returns: the height of the unwrapped text on the card's width, in
    ///   points, plus the padding the body keeps above and below it.
    static func transcriptContentHeight(text: String) -> CGFloat {
        let width = HUDState.transcriptWidth - HUDTheme.padding * 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = HUDTheme.transcriptLineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DotType.nsFont(15, .regular),
            .paragraphStyle: paragraph,
        ]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let lines = max(1, Int(ceil(rect.height / HUDTheme.transcriptLineHeight)))
        return CGFloat(lines) * HUDTheme.transcriptLineHeight + HUDTheme.verticalPadding * 2
    }

    /// The width a message needs.    ///
    /// - Parameters:
    ///   - text: the message.
    ///   - actionTitle: the title of the button the message offers, when it has
    ///     one. The card has to be wide enough for it, or the button would push
    ///     the text out of the card instead of sitting beside it.
    static func messageWidth(text: String, actionTitle: String? = nil) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DotType.nsFont(13, .medium),
        ]
        let textWidth = (text as NSString).size(withAttributes: attributes).width
        let actionWidth = actionTitle.map { HUDView.messageActionWidth(title: $0) } ?? 0
        let width = HUDTheme.padding * 2
            + 15
            + 10
            + textWidth
            + 10
            + actionWidth
            + 8
            + 10
            + HUDTheme.actionSize
            + 6
        return min(max(width, 280), 560)
    }
}
