import AppKit
import QuartzCore
import DotCore
import SwiftUI

/// The panel the HUD lives in.
///
/// It never takes focus: it is a borderless, non-activating panel that floats
/// above every window but below the system alerts.
final class HUDPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
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
/// The panel is a fixed size; only its frame is placed. The card animates
/// *inside* it, so the window server never sees a transparent window change
/// size — the thing that used to leave a grey edge around the shape. The card
/// itself is one SwiftUI surface, so there is no second material and no second
/// shadow.
@MainActor
final class HUD {
    /// The size of the panel. It is large enough for the biggest card plus
    /// the room the shadow needs, and it never changes.
    private static let panelSize = CGSize(width: 640, height: 340)
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

    private let panel: HUDPanel
    private let model = HUDModel()
    private let meter = VoiceMeter()
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

    private let renderLoop = HUDRenderLoop()
    private var renderFallbackTimer: Timer?
    private var lastTick: CFTimeInterval = 0
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
    /// The monitors that see the pointer while another app is frontmost.
    private var pointerMonitor: Any?
    private var scrollMonitor: Any?
    private var hasLoggedScroll = false
    private var hideTask: Task<Void, Never>?
    private var levelProvider: (() -> Double)?
    private var spectrumProvider: (() -> AudioSpectrumFrame)?
    private var spectrumRing: [AudioSpectrumFrame] = Array(repeating: .zero, count: VoiceMeter.historyLength)
    private var spectrumSmoothed: AudioSpectrumFrame = .zero
    private var spectrumClock: Double = 0
    private var isPreviewingVisualizer = false
    /// How present the card is, in screen space.
    private var presenceSpring = Spring(value: 0, target: 0, duration: 0.36, bounce: 0.16)
    /// How settled the content of the card is.
    private var contentSpring = Spring(value: 0, target: 0, duration: 0.34, bounce: 0.10)
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        // The card is dark in every appearance, so the system chrome inside it —
        // the transcript's scroller above all — is drawn in the dark appearance
        // even when the rest of the app is light. A scroller that follows a
        // light appearance would be dark on a dark card.
        panel.appearance = NSAppearance(named: .darkAqua)
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
        AnyView(
            ZStack(alignment: .top) {
                Color.clear
                HUDView(
                    model: model,
                    animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    actions: actions
                )
                .padding(.top, Self.shadowPadding)
            }
            .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
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
        set { model.visualizer = newValue }
    }

    /// What material the HUD island is made of: .glass or .black.
    var material: HUDMaterial {
        get { model.material }
        set { model.material = newValue }
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
    func showRecording(elapsed: String) {
        isPreviewingVisualizer = false
        model.clearLiveText()
        recordingStartedAt = CACurrentMediaTime()
        meter.reset()
        spectrumRing = Array(repeating: .zero, count: VoiceMeter.historyLength)
        spectrumSmoothed = .zero
        spectrumClock = 0
        setMode(
            .recording(elapsed: elapsed),
            size: CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        )
        present()
    }

    /// Updates the clock of the recording state.
    func updateRecording(elapsed: String) {
        model.updateRecording(elapsed: elapsed)
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
        model.showLiveText(text)
        // The recording card is normally already up; presenting again would
        // only re-place and re-log the panel on every partial.
        if !model.isVisible {
            present()
        }
    }

    /// Drops the live partial when the user cancels the recording.
    func cancel() {
        model.clearLiveText()
    }

    /// Shows the transcribing state.
    ///
    /// - Parameters:
    ///   - done: how many requests have been sent, `0` before the first one.
    ///   - total: how many the recording needs in all.
    func showTranscribing(done: Int = 0, total: Int = 0) {
        isPreviewingVisualizer = false
        model.clearLiveText()
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
    func showTranscript(text: String, delivery: HUDDelivery, elapsed: String) {
        isPreviewingVisualizer = false
        model.clearLiveText()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showMessage(text: "Nothing was heard.", symbol: "waveform.slash")
            return
        }
        setMode(
            .transcript(text: trimmed, delivery: delivery, elapsed: elapsed),
            size: Self.transcriptSize(text: trimmed)
        )
        present()
        let effectiveDwell = delivery == .pasted ? min(dwellSeconds, 3.5) : dwellSeconds
        startDwelling(duration: effectiveDwell)
        Log.shared.info("hud.transcript.shown", [
            "characters": .int(trimmed.count),
            "card_height": .double(model.cardSize.height),
            "scrolls": .bool(
                HUDTranscript.scrolls(
                    contentHeight: Self.transcriptContentHeight(text: trimmed)
                )
            ),
            "dwell_s": .double(effectiveDwell),
        ])
    }

    /// Shows a message.
    func showMessage(text: String, action: String? = nil, actionHandler: (() -> Void)? = nil) {
        _ = actionHandler
        let symbol = action == nil ? "info.circle" : "exclamationmark.circle"
        showMessage(text: text, symbol: symbol)
    }

    /// Shows a message with a symbol.
    ///
    /// - Parameters:
    ///   - dwell: how long to leave it up, when the message is not a report but
    ///     a preview of something the person is choosing. A material has no
    ///     other way to be seen: the card only names it.
    func showMessage(text: String, symbol: String, dwell: TimeInterval? = nil) {
        isPreviewingVisualizer = false
        model.clearLiveText()
        setMode(
            .message(text: text, symbol: symbol),
            size: CGSize(width: Self.messageWidth(text: text), height: HUDState.recordingHeight)
        )
        present()
        scheduleDismiss(in: dwell)
    }

    /// Shows the island for a moment, so a material can be chosen by eye.
    func previewMaterial(_ material: HUDMaterial) {
        self.material = material
        let name = material == .glass ? "Glass" : "Black"
        let symbol = material == .glass ? "sparkles" : "circle.fill"
        showMessage(text: name, symbol: symbol, dwell: 1.8)
    }

    /// Shows the island with a live simulated voice wave so a visualizer can be chosen by eye.
    func previewVisualizer(_ visualizer: HUDVisualizer) {
        model.visualizer = visualizer
        model.clearLiveText()
        isPreviewingVisualizer = true
        let now = CACurrentMediaTime()
        recordingStartedAt = now
        meter.reset()
        spectrumRing = Array(repeating: .zero, count: VoiceMeter.historyLength)
        spectrumSmoothed = .zero
        spectrumClock = 0
        // Pre-seed the meter with 2 seconds of speech history so scrolling visualizers
        // (Filament, Matrix) immediately show a full, moving voice trace.
        var simTime = now - 2.0
        while simTime < now {
            let voice = SpeechSchedule.level(at: (simTime - (now - 2.0) + 0.6).truncatingRemainder(dividingBy: max(1.0, SpeechSchedule.spoken)))
            let db = -52.0 + voice * 42.0
            meter.push(decibels: db, now: simTime)
            let b0 = min(1.0, max(0.0, voice * (0.45 + 0.55 * abs(sin(simTime * 9.3)))))
            let b1 = min(1.0, max(0.0, voice * (0.55 + 0.45 * abs(cos(simTime * 6.7)))))
            let b2 = min(1.0, max(0.0, voice * (0.65 + 0.35 * abs(sin(simTime * 4.9 + 0.8)))))
            let b3 = min(1.0, max(0.0, voice * (0.58 + 0.42 * abs(cos(simTime * 3.8 + 1.4)))))
            let b4 = min(1.0, max(0.0, voice * (0.48 + 0.52 * abs(sin(simTime * 2.9 + 2.1)))))
            advanceSpectrum(target: AudioSpectrumFrame(bands: (b0, b1, b2, b3, b4)), dt: 1.0 / 60.0)
            simTime += 1.0 / 60.0
        }
        setMode(
            .recording(elapsed: "0:02"),
            size: CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        )
        present()
        scheduleDismiss(in: 2.6)
    }

    /// Shows the launch card: Dot is up and waiting for the shortcut.
    ///
    /// Names the service dictation goes to, and a masked hint of the key.
    ///
    /// The ready card shows this instead of teaching the shortcut, so the card
    /// answers "what is my speech going to right now". Both values are already
    /// safe to display: the name comes from the chosen row and the hint is
    /// produced by ``MaskedKey``, never from the secret itself.
    ///
    /// - Parameters:
    ///   - service: the service name, as the picker shows it.
    ///   - keyHint: a masked key such as `sk-p…1234`, or empty for a service
    ///     that needs no key.
    func setActiveService(_ service: String, keyHint: String) {
        model.activeService = service
        model.activeKeyHint = keyHint
    }

    /// The card is a greeting, not a notification: it never replaces a
    /// recording, a transcription or a transcript that is already on screen.
    /// A message is kept too, because a warning at launch is more useful than
    /// the greeting that would hide it.
    ///
    /// - Parameter shortcut: the label of the record shortcut.
    func showReady(shortcut: String) {
        guard Self.canShowReady(over: model.mode, visible: model.isVisible) else { return }
        isPreviewingVisualizer = false
        model.clearLiveText()
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
        isPreviewingVisualizer = false
        model.clearLiveText()
        model.isEditingTranscript = false
        model.hoveredAction = nil
        panel.allowsKey = false
        dismissTimer?.invalidate()
        dismissTimer = nil
        dwellClock = nil
        stopPointerTracking()
        panel.ignoresMouseEvents = true
        guard model.isVisible else { return }
        if case .ready = model.mode {
            Log.shared.info("hud.ready.hidden")
        }
        model.isVisible = false

        if reduceMotion {
            presenceSpring.snap(to: 0)
            contentSpring.snap(to: 0)
            model.presence = 0
            model.content = 0
        } else {
            presenceSpring.to(target: 0, duration: 0.22, bounce: 0)
        }

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.reduceMotion == true ? 60 : 320))
            guard let self, !self.model.isVisible else { return }
            self.panel.orderOut(nil)
            self.stopRendering()
        }
    }

    /// Whether the card is on screen.
    var isVisible: Bool { model.isVisible }

    /// How present the card is. The headless test reads it through the real
    /// render loop.
    var debugPresence: Double { model.presence }

    /// How settled the content is. The headless test reads it through the real
    /// render loop.
    var debugContent: Double { model.content }

    /// Whether AppKit considers the panel visible.
    var debugPanelVisible: Bool { panel.isVisible }

    /// How many frames the render loop has delivered. The headless test uses
    /// it to prove the loop ran, not only the visibility fallback.
    private(set) var debugTickCount = 0

    /// How many times the visibility fallback has run. The headless test uses
    /// it to prove the watchdog fired.
    private(set) var debugFallbackCount = 0

    /// Stops only the frame loop. The headless test uses it to prove the
    /// visibility fallback; the app never does.
    func debugStopRenderLoop() {
        renderLoop.stop()
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

    // MARK: - The loop

    private func present() {
        hideTask?.cancel()
        hideTask = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
        // A card that replaces another one gets its own countdown: the dwell of
        // the transcript that was on screen must not dismiss a message or a
        // recording that arrived after it.
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
        lastTick = now
        presentedAt = now
        hasRenderedSincePresent = false
        hasReportedFirstTick = false
        startRendering()
        scheduleRenderFallback()
        // The card is on screen, so the pointer's position decides whether it
        // takes the mouse. Tracking runs for as long as the card is up, not
        // only while a countdown is running.
        startPointerTracking()
        updatePointer(at: NSEvent.mouseLocation)

        if reduceMotion {
            presenceSpring.snap(to: 1)
            contentSpring.snap(to: 1)
            model.presence = 1
            model.content = 1
        } else {
            presenceSpring.to(target: 1, duration: 0.36, bounce: 0.16)
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

    /// Starts the countdown of the transcript.
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
            // Verify real screen pointer position on every frame so a pointer that moved
            // away while global monitors coalesced events never leaves the island stuck.
            updatePointer(at: NSEvent.mouseLocation)
        }
        let interacting = model.isEditingTranscript || panel.isKeyWindow || HUDDwell.isInteracting(
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
    /// when Dot is the active app. Neither monitor swallows an event: both
    /// return nothing and the wheel goes on to the scroll view.
    private func startPointerTracking() {
        stopPointerTracking()
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .scrollWheel,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // The monitor's thread is the event's, not necessarily the main
            // one: the read happens on the main actor, one turn later, which is
            // soon enough for a countdown measured in seconds.
            Task { @MainActor [weak self] in
                self?.pointerEvent(event)
            }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.pointerEvent(event)
            }
            return event
        }
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
    }

    /// Reads one of the events the monitors watch.
    private func pointerEvent(_ event: NSEvent) {
        let now = CACurrentMediaTime()
        let screenPoint = NSEvent.mouseLocation
        updatePointer(at: screenPoint)
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            if !isPointerInside {
                if model.isEditingTranscript || panel.isKeyWindow {
                    endInlineEditing()
                } else if var clock = dwellClock, clock.remaining > 0.8 {
                    // Clicking outside into another app signals the user has moved on:
                    // smoothly expire the dwell in 0.8s rather than lingering.
                    clock.advance(to: now + (clock.remaining - 0.8), interacting: false)
                    dwellClock = clock
                }
            }
            return
        }
        guard event.type == .scrollWheel else { return }
        guard isPointerInside else { return }
        lastScrollAt = now
        guard !hasLoggedScroll else { return }
        hasLoggedScroll = true
        Log.shared.info("hud.transcript.scrolled", [
            "inside": .bool(isPointerInside),
            "key_window": .bool(panel.isKeyWindow),
            "app_active": .bool(NSApp.isActive),
        ])
    }

    /// Records whether the pointer is over the card.
    ///
    /// The card is the only part of the panel that is drawn: the rest is the
    /// margin its shadow needs, and a pointer there is not reading anything.
    private func updatePointer(at screenPoint: CGPoint) {
        let card = HUDPlacement.cardFrame(
            panelFrame: panel.frame,
            cardSize: model.cardSize,
            topInset: Self.shadowPadding
        )
        let inside = card.contains(screenPoint)
        // The panel takes the mouse only over the card. A click anywhere else in
        // the panel's rectangle belongs to whatever is under it, and this is what
        // hands it back.
        panel.ignoresMouseEvents = !inside
        let detectedHover = inside ? hoveredAction(at: screenPoint, in: card) : nil
        if model.hoveredAction != detectedHover {
            model.hoveredAction = detectedHover
        }
        guard inside != isPointerInside else { return }
        isPointerInside = inside
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
            items = HUDAction.available([.copy, .paste, .history, .settings, .close], in: actions)
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
        let startX = card.maxX - HUDTheme.padding - totalWidth
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
        renderLoop.start { [weak self] in
            guard let self else { return }
            self.tick(now: CACurrentMediaTime())
        }
    }

    private func stopRendering() {
        renderLoop.stop()
        renderFallbackTimer?.invalidate()
        renderFallbackTimer = nil
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
            Task { @MainActor in
                self?.applyRenderFallback()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        renderFallbackTimer = timer
    }

    private func applyRenderFallback() {
        renderFallbackTimer = nil
        guard model.isVisible, !hasRenderedSincePresent else { return }
        let elapsed = (CACurrentMediaTime() - presentedAt) * 1000
        presenceSpring.to(target: 1)
        presenceSpring.snap(to: 1)
        contentSpring.to(target: 1)
        contentSpring.snap(to: 1)
        model.presence = 1
        model.content = 1
        hasRenderedSincePresent = true
        debugFallbackCount += 1
        Log.shared.warn("hud.render.fallback", [
            "elapsed_ms": .double(elapsed),
            "panel_visible": .bool(panel.isVisible),
            "loop_running": .bool(renderLoop.isRunning),
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
        guard panel.isVisible else { return }
        if !hasReportedFirstTick {
            hasReportedFirstTick = true
            Log.shared.info("hud.render.tick", [
                "elapsed_ms": .double((now - presentedAt) * 1000),
                "panel_visible": .bool(panel.isVisible),
            ])
        }

        let dt = min(max(now - lastTick, 0), 0.1)
        lastTick = now

        presenceSpring.advance(dt)
        contentSpring.advance(dt)
        model.presence = min(max(presenceSpring.value, 0), 1)
        model.content = min(max(contentSpring.value, 0), 1)

        if case .recording = model.mode {
            if isPreviewingVisualizer {
                let previewTime = (now - recordingStartedAt + 0.6).truncatingRemainder(
                    dividingBy: max(1.0, SpeechSchedule.spoken)
                )
                let voice = SpeechSchedule.level(at: previewTime)
                meter.push(decibels: -52.0 + voice * 42.0, now: now)
                model.level = meter.envelope
                let b0 = min(1.0, max(0.0, voice * (0.45 + 0.55 * abs(sin(now * 9.3)))))
                let b1 = min(1.0, max(0.0, voice * (0.55 + 0.45 * abs(cos(now * 6.7)))))
                let b2 = min(1.0, max(0.0, voice * (0.65 + 0.35 * abs(sin(now * 4.9 + 0.8)))))
                let b3 = min(1.0, max(0.0, voice * (0.58 + 0.42 * abs(cos(now * 3.8 + 1.4)))))
                let b4 = min(1.0, max(0.0, voice * (0.48 + 0.52 * abs(sin(now * 2.9 + 2.1)))))
                advanceSpectrum(target: AudioSpectrumFrame(bands: (b0, b1, b2, b3, b4)), dt: dt)
                updateRecording(elapsed: HUDClock.string(for: now - recordingStartedAt + 2))
            } else {
                // The recorder reports the RMS of the last block of audio; the
                // meter works in dBFS, which is the only domain in which a voice
                // has a range instead of a spiky 0-1 value.
                let rms = levelProvider?() ?? 0
                let db = AudioLevel.decibels(rms)
                meter.push(decibels: db, now: now)
                // Use the fixed dBFS scale directly (without a rising room floor) so
                // continuous speech stays just as bright at the end of a long sentence
                // as at the very beginning!
                let fixedLevel = LevelScale.level(decibels: db, floor: LevelScale.floorDBFS)
                model.level = max(meter.envelope, fixedLevel)
                let rawSpec = spectrumProvider?() ?? .zero
                advanceSpectrum(target: rawSpec, dt: dt)
                updateRecording(elapsed: HUDClock.string(for: now - recordingStartedAt))
            }
        } else {
            // The card still breathes while it waits.
            model.level = max(0, model.level - dt * 3)
        }

        let ordered = meter.orderedHistory
        model.history = ordered
        model.spectrumHistory = spectrumRing
        model.phase = meter.phase
        model.time = reduceMotion ? 1.8 : now
        model.halfHeights = Waveform.halfHeights(
            history: ordered,
            phase: meter.phase,
            count: Waveform.columnCount,
            maximum: HUDTheme.waveformHeight / 2,
            breath: reduceMotion ? 0 : now * 0.35
        )
        model.pulse = reduceMotion ? 0 : now.truncatingRemainder(dividingBy: 1.1) / 1.1
        model.shimmer = reduceMotion ? 0 : now.truncatingRemainder(dividingBy: 1.4) / 1.4
        updateDwell(now: now)
        hasRenderedSincePresent = true
        debugTickCount += 1
    }

    private func advanceSpectrum(target: AudioSpectrumFrame, dt: Double) {
        func step(_ cur: Double, _ tgt: Double) -> Double {
            let tau = tgt > cur ? 0.014 : 0.11
            let c = 1.0 - exp(-max(0, dt) / tau)
            return cur + (tgt - cur) * c
        }
        spectrumSmoothed = AudioSpectrumFrame(bands: (
            step(spectrumSmoothed.bands.0, target.bands.0),
            step(spectrumSmoothed.bands.1, target.bands.1),
            step(spectrumSmoothed.bands.2, target.bands.2),
            step(spectrumSmoothed.bands.3, target.bands.3),
            step(spectrumSmoothed.bands.4, target.bands.4)
        ))
        spectrumClock += dt * VoiceMeter.sampleRate
        while spectrumClock >= 1.0 {
            spectrumClock -= 1.0
            spectrumRing.removeFirst()
            spectrumRing.append(spectrumSmoothed)
        }
    }

    /// Moves the card to a state, restarting the content reveal when the kind
    /// of card changes. The clock of the recording card only changes text, so
    /// it does not restart anything.
    private func setMode(_ mode: HUDMode, size: CGSize) {
        let changed = !Self.sameKind(mode, model.mode)
        model.mode = mode
        model.cardSize = size
        if changed {
            model.isEditingTranscript = false
            model.hoveredAction = nil
            panel.allowsKey = false
        }
        guard changed else { return }
        contentSpring.snap(to: 0)
        contentSpring.to(target: 1, duration: 0.34, bounce: 0.10)
        if reduceMotion {
            contentSpring.snap(to: 1)
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
    /// The screen under the pointer wins, because that is the display the user
    /// is looking at. `NSScreen.main` is next, and the first screen is the
    /// last resort. The frame is clamped by `HUDPlacement`, so the panel can
    /// never be placed outside every screen — the bug that left the card at
    /// x = 1956 on a 1470-point display.
    private func placePanel() {
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

        let screen = screens[index]
        let frame = HUDPlacement.frame(
            visibleFrame: screen.visibleFrame,
            panelSize: Self.panelSize,
            topInset: Self.topInset
        )
        panel.setFrame(frame, display: false)

        let visible = screen.visibleFrame
        Log.shared.info("hud.placed", [
            "screen_index": .int(index),
            "screens": .int(screens.count),
            "x": .double(frame.origin.x),
            "y": .double(frame.origin.y),
            "width": .double(frame.width),
            "height": .double(frame.height),
            "visible_x": .double(visible.origin.x),
            "visible_y": .double(visible.origin.y),
            "visible_width": .double(visible.width),
            "visible_height": .double(visible.height),
        ])
    }

    private func observeScreens() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.placePanel()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endInlineEditing()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endInlineEditing()
            }
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
    static func transcriptSize(text: String) -> CGSize {
        let body = HUDTranscript.bodyHeight(contentHeight: transcriptContentHeight(text: text))
        return CGSize(
            width: HUDState.transcriptWidth,
            height: HUDTheme.headerHeight + 1 + body
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
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
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

    /// The width a message needs.
    static func messageWidth(text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ]
        let textWidth = (text as NSString).size(withAttributes: attributes).width
        let width = HUDTheme.padding * 2
            + 15
            + 10
            + textWidth
            + 10
            + 8
            + 10
            + HUDTheme.actionSize
            + 6
        return min(max(width, 280), 480)
    }
}
