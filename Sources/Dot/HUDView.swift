import AppKit
import DotCore
import SwiftUI

/// The actions the island can perform.
///
/// The HUD does not know what Stop, Copy or History do: it only knows where
/// the buttons are. `AppDelegate` fills these closures in; an action without a
/// closure is not drawn.
struct HUDActions {
    /// Stops the recording and transcribes it.
    var stop: (() -> Void)? = nil
    /// Drops the recording without sending it anywhere.
    var cancel: (() -> Void)? = nil
    /// Copies the transcript again.
    var copy: (() -> Void)? = nil
    /// Pastes the transcript again.
    var paste: (() -> Void)? = nil
    /// Copies one reviewed version, named at the moment of the click.
    var copyVersion: ((String) -> Void)? = nil
    /// Writes one reviewed version where the transcript was, or copies it.
    var pasteVersion: ((String) -> Void)? = nil
    /// Selects the original version.
    var selectOriginal: (() -> Void)? = nil
    /// Selects the version before the current one.
    var previousVersion: (() -> Void)? = nil
    /// Selects the version after the current one.
    var nextVersion: (() -> Void)? = nil
    /// Runs the selected version's style again, appending a version.
    var rerunRewrite: (() -> Void)? = nil
    /// Opens the history window.
    var history: (() -> Void)? = nil
    /// Opens the settings window.
    var settings: (() -> Void)? = nil
    /// Begins inline editing of the transcript right inside the HUD island.
    var beginInlineEdit: (() -> Void)? = nil
    /// Concludes inline editing of the transcript inside the HUD island.
    var endInlineEdit: (() -> Void)? = nil
    /// Updates the transcript text as the user edits inline inside the HUD island.
    var updateTranscript: ((String) -> Void)? = nil
    /// Dismisses the card.
    var close: (() -> Void)? = nil
    /// Runs one rewrite style from the chip row.
    var rewrite: ((RewriteStyle) -> Void)? = nil
    /// Stops the rewrite that is running.
    var cancelRewrite: (() -> Void)? = nil
    /// Legacy anchored undo. Kept for the dead internal path; a cursor paste
    /// never sets `canUndo`, so the button is not drawn.
    var undoRewrite: (() -> Void)? = nil
    /// Applies a rewrite the check refused.
    var applyRewriteAnyway: (() -> Void)? = nil
    /// Returns to the chips without writing the refused rewrite.
    var keepOriginal: (() -> Void)? = nil
}

/// The card.
///
/// One surface, one shape, one shadow. The card is near opaque on purpose: it
/// sits over whatever the user is working in, and the text has to stay
/// readable over a white page and a black terminal alike.
@MainActor
struct HUDView: View {
    /// The frame the card draws.
    @ObservedObject var model: HUDModel
    /// The values that change sixty times a second.
    ///
    /// The app hands its own frame model down. A still, built from a snapshot,
    /// leaves this nil and the drawing leaves read the snapshot's fields instead.
    var frame: HUDFrameModel? = nil
    /// Whether the card casts its shadow. The corner test renders without it.
    var showsShadow = true
    /// Whether the frame is animated. The documentation renders are not.
    var animated = true
    /// What the island's buttons do. An action without a closure is not
    /// drawn; the app wires History, the preview leaves it out.
    var actions = HUDActions()
    /// Whether the person asked for reduced motion, as the environment says.
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Whether this card's labels use the system's semantic ink.
    ///
    /// The environment write below reaches descendants, not `HUDView` itself, so
    /// the card has to read the material it already owns.
    var usesSystemInk: Bool { model.material == .glass }
    /// A value the documentation renders can set without a system preference.
    var reduceMotionOverride: Bool? = nil
    /// Optional telemetry hook reporting `(timestamp, drawDurationMS)` for live visualizers.
    var onCanvasDraw: (@Sendable (CFTimeInterval, Double) -> Void)? = nil
    /// How far the halo's ring ink is mixed toward the card's ink on the glass
    /// material.
    ///
    /// It is handed to the card's waveform unchanged, so a render of the real
    /// card can be taken at every rung of the ladder the ring's brightness is
    /// chosen from. The app passes nothing and the waveform's own default holds,
    /// see ``HUDWaveform/Halo/glassRingLift``.
    var glassRingLift: Double = HUDWaveform.Halo.glassRingLift
    /// How much more opaque the halo's ring ink is drawn on the glass material.
    ///
    /// It is handed to the card's waveform unchanged, for the reason
    /// ``glassRingLift`` is, see ``HUDWaveform/Halo/glassRingInkGain``.
    var glassRingInkGain: Double = HUDWaveform.Halo.glassRingInkGain
    /// Where the shape pours out of the notch, or `nil` for a card that simply
    /// appears where it rests.
    ///
    /// The HUD hands this in whenever it knows the display it is on, and the card
    /// then arrives by pouring out of that display's notch rather than by fading.
    /// A card with no display behind it — a still, a documentation render, the
    /// HUD a headless test keeps off the screens — keeps the fade.
    var emergence: HUDEmergence.Scene? = nil

    /// The motion setting the card obeys.
    var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    /// The source the drawing leaves read. Building it never reads a frame
    /// value, so this view's body is not invalidated by the frame clock.
    var frameSource: HUDFrameSource {
        frame.map { .frames($0) } ?? .model(model)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
    }

    private var motion: Bool {
        animated && !reduceMotion
    }

    /// The shadow the card casts, chosen by the fill it is drawn on.
    ///
    /// Liquid Glass has its own edge and sits lighter on the desktop than the
    /// filled shape it replaces, so the glass card casts a shorter, softer
    /// shadow than the opaque one. The Black card and every Mac without Liquid
    /// Glass keep the shadow they had. A shape that is still fused to the notch
    /// casts what is left of it: the shadow belongs to the card, and while the
    /// black is still pouring out of the screen there is no card to cast one.
    ///
    /// - Parameter mix: how much of the card's own surface has replaced the
    ///   black, from `0` to `1`.
    /// - Returns: the colour, the radius and the vertical offset of the shadow.
    private func shadow(_ mix: Double = 1) -> (color: Color, radius: CGFloat, y: CGFloat) {
        Self.shadow(for: model.material, showsShadow: showsShadow, mix: mix)
    }

    static func shadow(
        for material: HUDMaterial,
        showsShadow: Bool,
        mix: Double = 1
    ) -> (color: Color, radius: CGFloat, y: CGFloat) {
        guard showsShadow else { return (.clear, 0, 0) }
        let alpha: Double
        let radius: CGFloat
        let offset: CGFloat
        if HUDSurface.drawsSystemGlass(material) {
            alpha = 0.30
            radius = 18
            offset = 8
        } else {
            alpha = 0.55
            radius = 22
            offset = 10
        }
        return (Color.black.opacity(alpha * min(max(mix, 0), 1)), radius, offset)
    }

    var body: some View {
#if DEBUG
        let _ = BodyEvalProbe.record()
#endif
        Group {
            if let emergence {
                pouring(emergence)
            } else {
                fading
            }
        }
        .environment(\.hudUsesSystemInk, model.material == .glass)
    }

    /// The card that arrives by fading, drawn where it rests.
    ///
    /// This is the appearance of a card with no display to pour out of: a still,
    /// a documentation render, and the HUD the headless test keeps off the
    /// screens.
    private var fading: some View {
        let shade = shadow()
        // The shadow belongs to the surface, not to a group composite that
        // also holds the canvas. Compositing the waveform changed how its ink
        // met the fill while the recording was live.
        return FrameFadingCard(
            source: frameSource,
            cardSize: model.cardSize,
            material: model.material,
            cornerRadius: HUDTheme.cornerRadius,
            shadeColor: shade.color,
            shadeRadius: shade.radius,
            shadeY: shade.y,
            content: content,
            tooltip: tooltip
        )
        .animation(animation(.shape), value: model.cardSize)
    }

    /// The card that pours out of the notch and back into it.
    ///
    /// Three layers, all driven by the same progress. The first is the shape
    /// itself, the notch's black carried down the screen as one piece: the card's
    /// own rectangle and the neck that still joins it to the notch are subpaths
    /// of one path and one fill. The second is the card's material, held to that
    /// rectangle. The third is the card's content, laid out at the size the card
    /// rests at and clipped to the card's own shape, which never changes: the
    /// words belong to the card and not to the shape, they are not drawn at all
    /// until the shape has all but arrived, and a clip that moved with the shape
    /// would drag the scroll view it hosts out of its position by a point or two.
    /// As the shape nears its rest the black gives way to the material, which is
    /// what turns a hole in the screen into a surface; at rest the black is gone
    /// and the card is the card it always was.
    ///
    /// - Parameter scene: where the notch is and where the card's rest
    ///   rectangle begins.
    /// - Returns: the card, drawn at this moment of the emergence.
    private func pouring(_ scene: HUDEmergence.Scene) -> some View {
        ZStack(alignment: .topLeading) {
            FramePouringSurface(
                source: frameSource,
                scene: scene,
                cardSize: model.cardSize,
                material: model.material,
                showsShadow: showsShadow,
                reduceMotion: reduceMotion
            )

            FramePouringContent(
                source: frameSource,
                reduceMotion: reduceMotion,
                content: content
            )
            .frame(width: model.cardSize.width, height: model.cardSize.height)
            .clipShape(shape)
            .overlay(alignment: .topTrailing) { tooltip }
        }
        .frame(
            width: model.cardSize.width,
            height: model.cardSize.height,
            alignment: .topLeading
        )
        .animation(animation(.shape), value: model.cardSize)
    }

    /// The tooltip of the hovered or recently confirmed button, when there is one.
    private var activeTooltip: (action: HUDAction, confirmation: HUDActionOutcome?)? {
        if let hovered = model.hoveredAction {
            if let feedback = model.actionFeedback,
               feedback.action == hovered,
               feedback.outcome != .triggered {
                return (hovered, feedback.outcome)
            }
            return (hovered, nil)
        }
        if let feedback = model.actionFeedback, feedback.outcome != .triggered {
            return (feedback.action, feedback.outcome)
        }
        return nil
    }

    @ViewBuilder
    private var tooltip: some View {
        let current = activeTooltip
        let tooltipKey = current.map { "\($0.action)-\(String(describing: $0.confirmation))" } ?? ""
        ZStack(alignment: .topTrailing) {
            if let current {
                HUDActionTooltip(
                    action: current.action,
                    material: model.material,
                    versioned: model.rewrite != nil,
                    confirmation: current.confirmation
                )
                .offset(
                    x: tooltipOffsetX(
                        for: current.action,
                        title: HUDActionTooltip.title(
                            for: current.action,
                            versioned: model.rewrite != nil,
                            confirmation: current.confirmation
                        )
                    ),
                    y: -24
                )
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
            }
        }
        .animation(
            motion ? .timingCurve(0.23, 1, 0.32, 1, duration: 0.16) : nil,
            value: tooltipKey
        )
    }

    private func animation(_ kind: Kind) -> Animation? {
        guard motion else { return nil }
        switch kind {
        case .shape:
            return .spring(response: 0.34, dampingFraction: 0.86)
        }
    }

    private enum Kind {
        case shape
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .recording(let elapsed):
            recording(elapsed: elapsed)
        case .working:
            working
        case .transcript(let text, let delivery, let elapsed, let destination):
            transcript(
                text: text,
                delivery: delivery,
                elapsed: elapsed,
                destination: destination
            )
        case .message(let text, let symbol):
            message(text: text, symbol: symbol)
        case .ready(let shortcut):
            ready(shortcut: shortcut)
        }
    }

    // MARK: - Recording

    private func recording(elapsed: String) -> some View {
        let showsLiveText = !model.liveText.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                FrameLiveDot(source: frameSource, material: model.material, reduceMotion: reduceMotion)
                    .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)

                Color.clear.frame(width: 10)

                Text("REC")
                    .font(HUDTheme.labelFont)
                    .tracking(HUDTheme.labelTracking)
                    .hudInk(.primary)

                Color.clear.frame(width: 10)

                FrameRecordingClock(
                    source: frameSource,
                    material: model.material,
                    fallback: elapsed,
                    useSystemInk: usesSystemInk
                )

                Color.clear.frame(width: 14)

                FrameHUDWaveform(
                    source: frameSource,
                    visualizer: model.visualizer,
                    material: model.material,
                    reduceMotion: reduceMotion,
                    glassRingLift: glassRingLift,
                    glassRingInkGain: glassRingInkGain,
                    onCanvasDraw: onCanvasDraw
                )
                .frame(maxWidth: .infinity)
                .frame(height: HUDTheme.waveformHeight)

                controlsSection([.stop, .cancel])
            }
            .padding(.horizontal, HUDTheme.padding)
            .frame(maxWidth: .infinity)
            .frame(height: showsLiveText ? HUDState.headerHeight : HUDState.recordingHeight)

            if showsLiveText {
                FrameLiveTextBody(
                    source: frameSource,
                    fallbackText: model.liveText,
                    cardSize: model.cardSize
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Working

    private var working: some View {
        HStack(spacing: 10) {
            FrameWorkingPulse(source: frameSource)

            Text("TRANSCRIBING")
                .font(HUDTheme.labelFont)
                .tracking(HUDTheme.labelTracking)
                .hudInk(.secondary)

            // Which request of how many is in flight. A spinner alone cannot
            // tell "almost done" from "stuck", and the stop path is short
            // enough that the count is honest.
            if !model.workingDetail.isEmpty {
                Text(model.workingDetail)
                    .font(HUDTheme.clockFont)
                    .hudInk(.tertiary)
                    .accessibilityLabel(Text("Request \(model.workingDetail)"))
            }

            Spacer(minLength: 0)

            FrameSpinner(source: frameSource)

            controlsSection([.cancel])
        }
        .padding(.horizontal, HUDTheme.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transcript

    private func transcript(
        text: String,
        delivery: HUDDelivery,
        elapsed: String,
        destination: String?
    ) -> some View {
        let card = model.rewrite
        let failed = card?.phase == .failed
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                FrameRewriteIdentity(
                    source: frameSource,
                    card: card,
                    delivery: delivery,
                    material: model.material,
                    reduceMotion: reduceMotion,
                    title: headerTitle(for: card, delivery: delivery, destination: destination),
                    titleCap: headerTitleCap(for: card),
                    accessibilityTitle: headerAccessibilityLabel(
                        for: card,
                        delivery: delivery,
                        destination: destination
                    ),
                    ringStyleTitle: ringStyleTitle(card: card, running: card?.activeStyleTitle),
                    ending: model.rewriteEnding,
                    failed: failed
                )

                // The surface the words were written for, named on the card.
                // The rewrite changes the inserted text, so it has to be
                // visible that it ran; a longer commit subject says so too,
                // because the words were not cut.
                if let grammar = model.grammar {
                    GrammarChip(
                        title: grammar.title,
                        wasLong: model.grammarWasLong
                    )
                }

                Spacer(minLength: 8)

                // The clock is read at a glance against the card's dark
                // material.
                Text(elapsed)
                    .font(HUDTheme.clockFont)
                    .tracking(HUDTheme.clockTracking)
                    .foregroundStyle(HUDTheme.clockInk(model.material, useSystemInk: usesSystemInk))
                    .fixedSize()

                if card?.canUndo == true {
                    RewriteCapsuleButton(title: "Undo", isPrimary: false) {
                        actions.undoRewrite?()
                    }
                    .accessibilityLabel("Undo the rewrite")
                }

                // Stop is the header's own icon button, the same size and the
                // same press as Copy or Close, in the card's amber: the request
                // can be ended where the work is announced, without moving the
                // pointer to a line under the body.
                if let card, card.isStreaming, actions.cancelRewrite != nil {
                    HUDActionButton(action: .stopRewrite) {
                        actions.cancelRewrite?()
                    }
                }

                controlsSection(
                    [.copy, .paste, .history, .settings, .close],
                    versioned: card != nil,
                    deliveryEnabled: card?.canDeliverSelected ?? true
                )
            }
            .padding(.horizontal, HUDTheme.padding)
            .frame(height: HUDTheme.headerHeight)

            Rectangle()
                .fill(HUDTheme.hairline)
                .frame(height: 1)

            if let card, showsDraftBody(card) {
                rewriteBody(card)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .frame(height: transcriptBodyHeight(card))
                    .transition(.identity)
            } else {
                transcriptBody(text, height: bodyHeight(for: card))
                    .transition(.identity)
            }

            if let card {
                rewriteSection(card)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transaction { $0.animation = nil }
    }

    private func headerTitle(
        for card: RewriteCard?,
        delivery: HUDDelivery,
        destination: String?
    ) -> String {
        guard let card else { return HUDHeader.title(delivery: delivery, destination: destination) }
        return HUDHeader.title(for: card, delivery: delivery, destination: destination)
    }

    /// What VoiceOver reads for the ring of a running rewrite.
    ///
    /// The header draws no title while a style runs, so the ring carries the
    /// sentence the caps row used to: the style is named, and the person is told
    /// the work is under way without a second line under the body saying it.
    static func rewritingAccessibilityLabel(_ style: String?) -> String {
        guard let style else { return "Rewriting" }
        return "Rewriting as \(style)"
    }

    /// The style the header's ring names while a run is ending.
    ///
    /// The ending records the style's id rather than its title, so the title is
    /// looked up in the card the failure or completion left behind. A style
    /// that is no longer offered leaves the sentence without a name.
    private func ringStyleTitle(card: RewriteCard?, running: String?) -> String? {
        if let running { return running }
        guard let card, let ending = model.rewriteEnding else { return nil }
        return card.choices.first { $0.id == ending.styleID }?.title
    }

    private func headerAccessibilityLabel(
        for card: RewriteCard?,
        delivery: HUDDelivery,
        destination: String?
    ) -> String {
        guard let card else {
            return HUDHeader.accessibilityLabel(delivery: delivery, destination: destination)
        }
        return HUDHeader.accessibilityLabel(for: card, delivery: delivery, destination: destination)
    }

    /// Whether the mechanical check badge is drawn.
    ///
    /// It appears for a completed model version, not while the draft is still
    /// arriving and not for the original. The word is "Checked" or "Review",
    /// never "Faithful": the check is a short list of mechanical rules, not a
    /// proof that the meaning survived.
    ///
    /// It is not drawn while the header is acknowledging that same version's
    /// delivery. "COPIED" beside "Review" reads as a contradiction — one says
    /// the version left the card, the other asks whether it was safe to use —
    /// and the acknowledgement is the newer and more specific fact. The warning
    /// is not discarded: it stays on the version, the badge returns as soon as
    /// the selection moves, and a delivery recorded for another version changes
    /// nothing here.
    static func showsCheckBadge(_ card: RewriteCard) -> Bool {
        guard !card.isStreaming, !card.isBlocked, !card.selectedVersion.isOriginal else {
            return false
        }
        switch card.phase {
        case .applied(let versionID), .copied(let versionID):
            return card.selectedVersionID != versionID
        case .failed:
            // The header names the failure itself; a check badge beside it
            // would be a second verdict on a version the failure never
            // produced.
            return false
        case .offered, .rewriting, .blocked:
            return true
        }
    }

    /// The room the title has once the badge is drawn, and once the legacy
    /// Undo capsule is drawn when a card still carries one.
    private func headerTitleCap(for card: RewriteCard?) -> CGFloat {
        var cap = HUDHeader.maximumTitleWidth
        guard let card else { return cap }
        if Self.showsCheckBadge(card) {
            cap -= 72
        }
        if card.canUndo {
            cap -= 54
        }
        return max(120, cap)
    }

    /// The transcript itself: a body that grows with the words, then scrolls,
    /// and becomes directly editable inline at the clicked character position.
    @ViewBuilder
    private func transcriptBody(_ text: String, height: CGFloat? = nil) -> some View {
        HUDInlineTranscriptView(
            text: text,
            isEditing: model.isEditingTranscript,
            usesSystemInk: usesSystemInk,
            onBeginEditing: {
                actions.beginInlineEdit?()
            },
            onEndEditing: {
                actions.endInlineEdit?()
            },
            onUpdateText: { updated in
                model.updateTranscriptText(updated)
                actions.updateTranscript?(updated)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: height ?? transcriptBodyHeight)
        .accessibilityLabel(Text("Transcript"))
    }

    /// The height of the scrollable body inside the card.
    private var transcriptBodyHeight: CGFloat {
        max(0, model.cardSize.height - HUDTheme.headerHeight - 1)
    }

    /// Whether the body is the draft's view rather than the transcript's.
    ///
    /// A request that has not sent its first token has no words of its own: the
    /// body is still the version the person was reading. Drawing it with the
    /// view that drew it before the click keeps the words exactly where they
    /// were — the transcript view and the draft view are two different layouts,
    /// so switching at the click would move the paragraph for the second before
    /// the service answers. A selected rewrite keeps the draft's view even
    /// before the first token, because the words on the card are then the
    /// version's and not the transcript's.
    ///
    /// - Parameter card: the layer the card is drawing.
    /// - Returns: whether ``rewriteBody(_:)`` draws the body.
    private func showsDraftBody(_ card: RewriteCard) -> Bool {
        guard card.showsRewrite else { return false }
        return !(card.isStreaming && card.draft.isEmpty && card.selectedVersion.isOriginal)
    }

    /// The height of the body once the rewrite layer has taken its rows.
    private func transcriptBodyHeight(_ card: RewriteCard) -> CGFloat {
        max(
            0,
            model.cardSize.height - HUDTheme.headerHeight - 1 - HUD.rewriteExtraHeight(card)
        )
    }

    /// The height of an inline-editable body.
    ///
    /// A transcript that offers the chips keeps the body it would have had
    /// without them and grows by the row, so the words do not lose a line to a
    /// control the person has not chosen yet.
    private func bodyHeight(for card: RewriteCard?) -> CGFloat {
        guard let card else { return transcriptBodyHeight }
        return transcriptBodyHeight(card)
    }

    // MARK: - Message

    private func message(text: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(DotType.font(15, .semibold))
                .foregroundStyle(symbol.contains("exclamation") || symbol.contains("xmark")
                    ? HUDTheme.warning
                    : HUDTheme.accent)

            Text(text)
                .font(HUDTheme.messageFont)
                .hudInk(.primary)
                .lineLimit(2)

            Spacer(minLength: 8)

            if let action = model.messageAction {
                HUDMessageActionButton(title: action.title, perform: action.handler)
                    .padding(.trailing, HUDTheme.messageActionGap)
            }

            controlsSection([.close])
        }
        .padding(.horizontal, HUDTheme.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The width the titled button of a message occupies, gap included.
    ///
    /// The card's size and the pointer's hit test are computed without laying
    /// the view out, so both read the measurement from here and cannot disagree
    /// about where the button is.
    static func messageActionWidth(title: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: DotType.nsFont(11.5, .medium)]
        let text = (title as NSString).size(withAttributes: attributes).width
        return ceil(text) + HUDTheme.messageActionHPadding * 2 + HUDTheme.messageActionGap
    }

    // MARK: - Ready

    /// The card that says what dictation is currently going to.
    ///
    /// No mark: the card is on screen for a second and a half at launch, and
    /// its job is to say one thing. The 26 point tile that used to sit here
    /// was the logo at a size where it is a smudge of indigo, and it pushed
    /// the only sentence in the card to the right of the thing it explains.
    ///
    /// It used to say "Hold <key> to talk", which told the user something they
    /// had just configured. It now names the active service and a masked hint of
    /// the key, which is the thing they cannot otherwise see.
    /// Whether the service the card names is a host rather than a name.
    private var isHostLabel: Bool {
        model.activeService.contains(".") && !model.activeService.contains(" ")
    }

    private func ready(shortcut: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // A shipped service is a name and reads as one; a hand-filled
                // endpoint is a host, and a host set in caps with letter
                // spacing reads as an error code. Naming the key line "Key"
                // says what the eight characters under the name are: the card
                // used to print an unexplained fragment of the secret.
                if isHostLabel {
                    Text(model.activeService)
                        .font(DotType.tabularFont(11.5, .medium))
                        .foregroundStyle(HUDTheme.accent)
                        .lineLimit(1)
                } else {
                    Text(model.activeService.isEmpty ? "READY" : model.activeService.uppercased())
                        .font(HUDTheme.labelFont)
                        .tracking(HUDTheme.labelTracking)
                        .foregroundStyle(HUDTheme.accent)
                        .lineLimit(1)
                }

                if !model.activeKeyHint.isEmpty {
                    Text("Key \(model.activeKeyHint)")
                        .font(DotType.tabularFont(11.5, .medium))
                        .hudInk(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.readyAccessibilityLabel(
                service: model.activeService,
                keyHint: model.activeKeyHint,
                shortcut: shortcut
            )))

            Spacer(minLength: 8)

            controlsSection([.settings, .close])
        }
        .padding(.horizontal, HUDTheme.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What VoiceOver says for the ready card.
    ///
    /// The shortcut is still announced, because it is the one thing a person
    /// cannot discover by looking at a menu bar icon, even though the card no
    /// longer teaches it visually.
    static func readyAccessibilityLabel(service: String, keyHint: String, shortcut: String) -> String {
        var parts: [String] = []
        parts.append(service.isEmpty ? "Ready" : "Ready, using \(service)")
        if !keyHint.isEmpty { parts.append("key \(keyHint)") }
        parts.append("Press \(shortcut) to record")
        return parts.joined(separator: ". ")
    }

    // MARK: - Controls

    /// The hairline between the content and the buttons.
    private var divider: some View {
        Capsule()
            .fill(HUDTheme.hairline)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 8)
    }

    /// The divider and the buttons that actually have a closure.
    ///
    /// An action without a closure is not drawn: a button that does nothing
    /// is worse than a button that is not there. The divider follows the
    /// buttons, so an empty card has no dangling hairline either.
    @ViewBuilder
    private func controlsSection(
        _ items: [HUDAction],
        versioned: Bool = false,
        deliveryEnabled: Bool = true
    ) -> some View {
        let available = HUDAction.available(items, in: actions, versioned: versioned)
        if !available.isEmpty {
            divider
            controls(available, versioned: versioned, deliveryEnabled: deliveryEnabled)
        }
    }

    private func controls(
        _ items: [HUDAction],
        versioned: Bool = false,
        deliveryEnabled: Bool = true
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { action in
                HUDActionButton(
                    action: action,
                    isHovered: model.hoveredAction == action,
                    versioned: versioned,
                    isEnabled: deliveryEnabled || !action.deliversVersion,
                    feedback: model.actionFeedback?.action == action ? model.actionFeedback : nil,
                    onHoverChange: { inside in
                        if inside {
                            model.hoveredAction = action
                        } else if model.hoveredAction == action {
                            model.hoveredAction = nil
                        }
                    }
                ) {
                    perform(action, versioned: versioned)
                }
            }
        }
    }

    private func activeControlItems() -> [HUDAction] {
        let versioned = model.rewrite != nil
        switch model.mode {
        case .recording:
            return HUDAction.available([.stop, .cancel], in: actions)
        case .working:
            return HUDAction.available([.cancel], in: actions)
        case .transcript:
            return HUDAction.available(
                [.copy, .paste, .history, .settings, .close],
                in: actions,
                versioned: versioned
            )
        case .message:
            return HUDAction.available([.close], in: actions)
        case .ready:
            return HUDAction.available([.settings, .close], in: actions)
        }
    }

    private func tooltipOffsetX(for action: HUDAction, title: String) -> CGFloat {
        let items = activeControlItems()
        guard let idx = items.firstIndex(of: action) else { return -HUDTheme.padding }
        let trailingIndex = items.count - 1 - idx
        let step = HUDTheme.actionSize + 4
        let buttonCenterFromTrailing = HUDTheme.padding + HUDTheme.actionSize / 2 + CGFloat(trailingIndex) * step
        let pillWidth = HUDActionTooltip.estimatedWidth(for: title)
        return min(-8, -(buttonCenterFromTrailing - pillWidth / 2))
    }

    private func perform(_ action: HUDAction, versioned: Bool = false) {
        switch action {
        case .stop: actions.stop?()
        case .stopRewrite: actions.cancelRewrite?()
        case .cancel: actions.cancel?()
        case .copy:
            if versioned, let text = model.rewrite?.selectedVersion.text,
               model.rewrite?.canDeliverSelected == true {
                actions.copyVersion?(text)
            } else {
                actions.copy?()
            }
        case .paste:
            if versioned, let text = model.rewrite?.selectedVersion.text,
               model.rewrite?.canDeliverSelected == true {
                actions.pasteVersion?(text)
            } else {
                actions.paste?()
            }
        case .history: actions.history?()
        case .settings: actions.settings?()
        case .close: actions.close?()
        }
    }
}

/// The chip that names the grammar a transcript was written for.
///
/// It is a label, not a control: it answers "why is there no full stop" and it
/// can be read without being clicked.
private struct GrammarChip: View {
    let title: String
    let wasLong: Bool

    var body: some View {
        Text(wasLong ? "\(title) · length kept" : title)
            .font(HUDTheme.labelFont)
            .tracking(1.0)
            .hudInk(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                Capsule(style: .circular)
                    .fill(HUDTheme.actionFill)
            )
            .overlay(
                Capsule(style: .circular)
                    .strokeBorder(HUDTheme.actionBorder, lineWidth: 1)
            )
            .accessibilityLabel(
                Text(wasLong ? "Formatting: \(title). The words were not shortened." : "Formatting: \(title)")
            )
    }
}

/// The one titled button a message card can offer.
///
/// A message that reports shows only Close. A message that is asking for
/// something — a missing microphone or Accessibility permission — carries the
/// title and the work that fixes it, so the card can be acted on where it is
/// read instead of naming a place to go.
struct HUDMessageAction {
    /// The text on the button, e.g. "Open Settings".
    let title: String
    /// What choosing the button does.
    let handler: () -> Void
}

/// One icon of the card.
enum HUDAction: Hashable {
    case stop
    case stopRewrite
    case cancel
    case copy
    case paste
    case history
    case settings
    case close

    /// The actions that have a closure in `actions`.
    ///
    /// The card never draws a button whose action is missing: the transcript
    /// header shows Copy, Paste, Settings and Close, but no History until the
    /// History window exists. A card with versions uses the version-aware Copy
    /// and Paste closures instead of the transcript ones.
    static func available(
        _ items: [HUDAction],
        in actions: HUDActions,
        versioned: Bool = false
    ) -> [HUDAction] {
        items.filter { $0.isAvailable(in: actions, versioned: versioned) }
    }

    /// Whether the app handed the card a closure for this action.
    func isAvailable(in actions: HUDActions, versioned: Bool = false) -> Bool {
        switch self {
        case .stop: actions.stop != nil
        case .stopRewrite: actions.cancelRewrite != nil
        case .cancel: actions.cancel != nil
        case .copy: versioned ? actions.copyVersion != nil : actions.copy != nil
        case .paste: versioned ? actions.pasteVersion != nil : actions.paste != nil
        case .history: actions.history != nil
        case .settings: actions.settings != nil
        case .close: actions.close != nil
        }
    }

    /// The SF Symbol of the action.
    var symbol: String {
        switch self {
        case .stop, .stopRewrite: "stop.fill"
        case .cancel, .close: "xmark"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    /// The accessible name of the button.
    func label(versioned: Bool = false) -> String {
        switch self {
        case .stop: "Stop recording"
        case .stopRewrite: "Stop rewriting"
        case .cancel: "Cancel recording"
        case .copy: versioned ? "Copy selected version" : "Copy transcript"
        case .paste: versioned ? "Paste selected version at cursor" : "Paste again"
        case .history: "History"
        case .settings: "Settings"
        case .close: "Close"
        }
    }

    /// The tooltip of the button.
    func help(versioned: Bool = false) -> String {
        switch self {
        case .stop: "Stop and transcribe"
        case .stopRewrite: "Stop the rewrite and go back to the transcript"
        case .cancel: "Cancel without transcribing"
        case .copy: versioned ? "Copy the version on screen" : "Copy transcript"
        case .paste: versioned ? "Paste the version at the cursor" : "Paste the transcript again"
        case .history: "Open history"
        case .settings: "Open settings"
        case .close: "Dismiss"
        }
    }

    /// Whether the button delivers a version rather than acting on the card.
    var deliversVersion: Bool {
        self == .copy || self == .paste
    }

    /// The colour the icon is drawn in when the pointer is elsewhere.
    ///
    /// Every button of the card is quiet until it is reached, except the one
    /// that ends a request that is running: that one is the card's amber at rest,
    /// because it is the only control on the surface that answers something in
    /// flight.
    var restingColor: Color {
        self == .stopRewrite ? HUDTheme.recording : HUDTheme.ink3
    }

    var hoverColor: Color {
        switch self {
        case .stop, .stopRewrite: HUDTheme.recording
        case .cancel, .close: HUDTheme.ink
        case .copy, .paste, .history, .settings: HUDTheme.accent
        }
    }

    func restingStyle(useSystemInk: Bool) -> AnyShapeStyle {
        if self == .stopRewrite { return AnyShapeStyle(HUDTheme.recording) }
        return useSystemInk ? AnyShapeStyle(.tertiary) : AnyShapeStyle(HUDTheme.ink3)
    }

    /// The style the icon takes under the pointer.
    func hoverStyle(useSystemInk: Bool) -> AnyShapeStyle {
        switch self {
        case .stop, .stopRewrite: AnyShapeStyle(HUDTheme.recording)
        case .cancel, .close: useSystemInk
            ? AnyShapeStyle(.primary)
            : AnyShapeStyle(HUDTheme.ink)
        case .copy, .paste, .history, .settings: AnyShapeStyle(HUDTheme.accent)
        }
    }
}

/// A small, quiet button that names the work it does.
///
/// It exists for the messages that ask for something — a permission Dot cannot
/// grant itself — where an icon would be a guess and the title is the instruction.
private struct HUDMessageActionButton: View {
    let title: String
    let perform: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            Text(title)
                .font(HUDTheme.messageActionFont)
                .hudInk(.primary, when: !hovering, otherwise: HUDTheme.accentTip)
                .lineLimit(1)
                .padding(.horizontal, HUDTheme.messageActionHPadding)
                .frame(height: HUDTheme.messageActionHeight)
                .background(
                    Capsule(style: .circular)
                        .fill(hovering ? HUDTheme.actionFillHover : HUDTheme.actionFill)
                )
                .overlay(
                    Capsule(style: .circular)
                        .strokeBorder(
                            hovering ? HUDTheme.actionBorderHover : HUDTheme.actionBorder,
                            lineWidth: 0.75
                        )
                )
                .contentShape(Capsule(style: .circular))
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.14),
                    value: hovering
                )
        }
        .buttonStyle(HUDActionButtonStyle(reduceMotion: reduceMotion))
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(title))
    }
}

/// A small, quiet icon button.
///
/// It is deliberately not a stock bordered button: the card is one dark
/// surface, and a system bezel would cut a second shape out of it. The button
/// gains contrast, not a bezel, when the pointer is over it.
///
/// The Settings material tile draws the recording card's row itself, so the
/// buttons it shows are these buttons rather than a likeness of them.
struct HUDActionButton: View {
    let action: HUDAction
    var isHovered: Bool = false
    var versioned: Bool = false
    var isEnabled: Bool = true
    var feedback: HUDActionFeedback? = nil
    var onHoverChange: ((Bool) -> Void)? = nil
    let perform: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.hudUsesSystemInk) var usesSystemInk
    @State private var hovering = false

    private var reducesMotion: Bool {
        reduceMotion || DotMotion.reducesMotion
    }

    private var activeHover: Bool {
        isEnabled && (hovering || isHovered)
    }

    private var isConfirmed: Bool {
        feedback != nil
    }

    private var showsConfirmedSymbol: Bool {
        switch feedback?.outcome {
        case .copied, .pasted, .fallbackCopied:
            return true
        case .triggered, .none:
            return false
        }
    }

    private var confirmedSymbol: String {
        switch feedback?.outcome {
        case .fallbackCopied:
            return "doc.on.doc"
        case .copied, .pasted:
            return "checkmark"
        case .triggered, .none:
            return action.symbol
        }
    }

    private var confirmationAccent: Color {
        switch feedback?.outcome {
        case .copied, .pasted:
            if usesSystemInk {
                return colorScheme == .light
                    ? HUDTheme.arcOnPill
                    : HUDTheme.recordingGlass
            }
            return HUDTheme.recording
        case .fallbackCopied:
            if usesSystemInk, colorScheme == .light {
                return HUDTheme.arcOnPill
            }
            return HUDTheme.warning
        case .triggered, .none:
            return usesSystemInk ? Color.primary : HUDTheme.accentTip
        }
    }

    private var iconStyle: AnyShapeStyle {
        if isConfirmed {
            return AnyShapeStyle(confirmationAccent)
        }
        return activeHover
            ? action.hoverStyle(useSystemInk: usesSystemInk)
            : action.restingStyle(useSystemInk: usesSystemInk)
    }

    private var buttonFill: Color {
        if isConfirmed {
            let opacity = (usesSystemInk && colorScheme == .light) ? 0.16 : 0.18
            return confirmationAccent.opacity(opacity)
        }
        return activeHover ? HUDTheme.actionFillHover : HUDTheme.actionFill
    }

    private var borderColor: Color {
        if isConfirmed {
            return confirmationAccent.opacity(0.90)
        }
        return activeHover ? HUDTheme.actionBorderHover : HUDTheme.actionBorder
    }

    var body: some View {
        Button(action: perform) {
            ZStack {
                Image(systemName: action.symbol)
                    .font(HUDTheme.actionFont)
                    .opacity(showsConfirmedSymbol ? 0 : 1)
                    .scaleEffect(showsConfirmedSymbol ? 0.62 : 1)
                Image(systemName: confirmedSymbol)
                    .font(DotType.font(10, .bold))
                    .opacity(showsConfirmedSymbol ? 1 : 0)
                    .scaleEffect(showsConfirmedSymbol ? 1 : 0.62)
            }
            .foregroundStyle(iconStyle)
            .animation(
                reducesMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72),
                value: showsConfirmedSymbol
            )
            .frame(width: HUDTheme.actionSize, height: HUDTheme.actionSize)
            .background(
                Circle()
                    .fill(buttonFill)
            )
            .overlay(
                Circle()
                    .strokeBorder(borderColor, lineWidth: isConfirmed ? 1.25 : 0.75)
            )
            .overlay {
                if !reducesMotion, let feedback, feedback.outcome != .triggered {
                    HUDActionPulseRing(accent: confirmationAccent)
                        .id(feedback.id)
                }
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.45)
            .animation(
                reducesMotion ? nil : .easeOut(duration: 0.14),
                value: activeHover
            )
            .animation(
                reducesMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18),
                value: isConfirmed
            )
        }
        .buttonStyle(HUDActionButtonStyle(reduceMotion: reducesMotion))
        .disabled(!isEnabled)
        .onHover { inside in
            hovering = inside
            onHoverChange?(inside)
        }
        .accessibilityLabel(Text(action.label(versioned: versioned)))
        .accessibilityHint(Text(action.help(versioned: versioned)))
    }
}

/// Single expanding confirmation ripple emitted around a HUD action button on click.
private struct HUDActionPulseRing: View {
    let accent: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(accent, lineWidth: 1.25)
            .frame(width: HUDTheme.actionSize, height: HUDTheme.actionSize)
            .scaleEffect(expanded ? 1.48 : 1.0)
            .opacity(expanded ? 0 : 0.65)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.38), value: expanded)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                expanded = true
            }
    }
}

/// A themed floating tooltip pill that sits cleanly above the HUD island's top edge
/// when hovering over an action button, never overlapping the transcript text.
private struct HUDActionTooltip: View {
    let action: HUDAction
    var material: HUDMaterial = .glass
    var versioned: Bool = false
    var confirmation: HUDActionOutcome? = nil

    static func title(
        for action: HUDAction,
        versioned: Bool,
        confirmation: HUDActionOutcome?
    ) -> String {
        switch confirmation {
        case .copied:
            return "Copied"
        case .pasted:
            return "Pasted"
        case .fallbackCopied:
            return "Copied instead"
        case .triggered, .none:
            return action.help(versioned: versioned)
        }
    }

    static func estimatedWidth(for title: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: DotType.nsFont(11, .medium)]
        let textWidth = (title as NSString).size(withAttributes: attributes).width
        return ceil(textWidth) + 18 + 5 + 12
    }

    private var iconSymbol: String {
        switch confirmation {
        case .copied, .pasted:
            return "checkmark"
        case .fallbackCopied:
            return "doc.on.doc"
        case .triggered, .none:
            return action.symbol
        }
    }

    private var iconColor: Color {
        switch confirmation {
        case .copied, .pasted:
            return HUDTheme.recordingGlass
        case .fallbackCopied:
            return HUDTheme.warning
        case .triggered, .none:
            return action.hoverColor
        }
    }

    private var topBorderColor: Color {
        switch confirmation {
        case .copied, .pasted, .fallbackCopied:
            return iconColor.opacity(0.45)
        case .triggered, .none:
            return Color.white.opacity(0.32)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconSymbol)
                .font(DotType.font(9.5, .semibold))
                .foregroundStyle(iconColor)
            Text(Self.title(for: action, versioned: versioned, confirmation: confirmation))
                .font(DotType.font(11, .medium))
                .foregroundStyle(HUDTheme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .circular)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.14, green: 0.15, blue: 0.18).opacity(0.96),
                            Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.98),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            Capsule(style: .circular)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            topBorderColor,
                            Color.white.opacity(0.10),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.85
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 2)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The press state, in the app's one policy: a 2 per cent shrink on the strong
/// ease-out, and the fill's own dim when the motion is reduced.
private struct HUDActionButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        HUDActionButtonBody(configuration: configuration, reduceMotion: reduceMotion)
    }
}

private struct HUDActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let reduceMotion: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hudUsesSystemInk) var usesSystemInk

    private var reducesMotion: Bool {
        reduceMotion || systemReduceMotion || DotMotion.reducesMotion
    }

    var body: some View {
        configuration.label
            .scaleEffect(DotPressFeedback.scale(
                isPressed: configuration.isPressed,
                isEnabled: isEnabled,
                reduceMotion: reducesMotion
            ))
            .opacity(DotPressFeedback.opacity(
                isPressed: configuration.isPressed,
                isEnabled: isEnabled,
                reduceMotion: reducesMotion
            ))
            .animation(
                DotPressFeedback.animation(reduceMotion: reducesMotion),
                value: configuration.isPressed
            )
    }
}

/// Isolates appearance fade/scale/blur reads onto `HUDFrameSource` so steady
/// emergence/dismissal ticks do not re-evaluate `HUDView.body`.
@MainActor
private struct FrameFadingCard<Content: View, Tooltip: View>: View {
    let source: HUDFrameSource
    let cardSize: CGSize
    let material: HUDMaterial
    let cornerRadius: CGFloat
    let shadeColor: Color
    let shadeRadius: CGFloat
    let shadeY: CGFloat
    let content: Content
    let tooltip: Tooltip

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let presence = source.presence
        let contentAmount = source.content
        content
            .opacity(contentAmount)
            .scaleEffect(0.99 + 0.01 * contentAmount)
            .offset(y: (1 - contentAmount) * 6)
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(shape)
            .background(
                HUDSurface(material: material)
                    .clipShape(shape)
                    .shadow(color: shadeColor, radius: shadeRadius, x: 0, y: shadeY)
            )
            .overlay(alignment: .topTrailing) { tooltip }
            .opacity(presence)
            .scaleEffect(0.94 + 0.06 * presence)
            .offset(y: (1 - presence) * -10)
            .blur(radius: presence < 0.999 ? (1 - presence) * 7 : 0)
    }
}

/// Renders the emerging notch-pour surface during transit and switches to a
/// direct uncomposited clipped surface with shadow at rest.
@MainActor
private struct FramePouringSurface: View {
    let source: HUDFrameSource
    let scene: HUDEmergence.Scene
    let cardSize: CGSize
    let material: HUDMaterial
    let showsShadow: Bool
    let reduceMotion: Bool

    var body: some View {
        let rest = HUDEmergence.Rest(
            rect: CGRect(origin: .zero, size: cardSize),
            cornerRadius: HUDTheme.cornerRadius
        )
        let emergenceSource = scene.source(inCardOf: cardSize)
        let progress = HUDEmergence.progress(source.emergence, reduceMotion: reduceMotion)
        let piece = HUDEmergence.shape(progress: progress, source: emergenceSource, rest: rest)
        let shade = HUDView.shadow(for: material, showsShadow: showsShadow, mix: piece.mix)

        if piece.mix >= 0.999 {
            HUDSurface(material: material)
                .frame(width: piece.card.width, height: piece.card.height)
                .clipShape(RoundedRectangle(cornerRadius: piece.cornerRadius, style: .continuous))
                .offset(x: piece.card.minX, y: piece.card.minY)
                .shadow(color: shade.color, radius: shade.radius, x: 0, y: shade.y)
        } else {
            ZStack(alignment: .topLeading) {
                HUDEmergence.path(piece)
                    .fill(Color(red: 0, green: 0, blue: 0))
                    .opacity(1 - piece.mix)

                HUDSurface(material: material)
                    .opacity(piece.mix)
                    .frame(width: piece.card.width, height: piece.card.height)
                    .clipShape(RoundedRectangle(cornerRadius: piece.cornerRadius, style: .continuous))
                    .offset(x: piece.card.minX, y: piece.card.minY)
            }
            .compositingGroup()
            .shadow(color: shade.color, radius: shade.radius, x: 0, y: shade.y)
        }
    }
}

/// Isolates the pouring card content opacity/scale/offset on `HUDFrameSource`.
@MainActor
private struct FramePouringContent<Content: View>: View {
    let source: HUDFrameSource
    let reduceMotion: Bool
    let content: Content

    var body: some View {
        let progress = HUDEmergence.progress(source.emergence, reduceMotion: reduceMotion)
        let contentAmount = source.content
        content
            .opacity(HUDEmergence.contentOpacity(
                content: contentAmount,
                progress: progress
            ))
            .scaleEffect(0.99 + 0.01 * contentAmount)
            .offset(y: (1 - contentAmount) * 6)
    }
}

/// The waveform leaf. It is the only place the card reads the frame's history,
/// spectrum, level and reveal, so those writes redraw this canvas and nothing
/// else.
@MainActor
private struct FrameHUDWaveform: View {
    let source: HUDFrameSource
    let visualizer: HUDVisualizer
    let material: HUDMaterial
    let reduceMotion: Bool
    let glassRingLift: Double
    let glassRingInkGain: Double
    let onCanvasDraw: (@Sendable (CFTimeInterval, Double) -> Void)?

    var body: some View {
        switch source {
        case .frames(let frameModel):
            LiveVisualizerView(
                sink: frameModel.visualizerSink,
                makeInitialFrame: {
                    frameModel.currentVisualizerFrame(
                        visualizer: visualizer,
                        material: material,
                        reduceMotion: reduceMotion,
                        glassRingLift: glassRingLift,
                        glassRingInkGain: glassRingInkGain
                    )
                }
            )
        case .snapshot:
#if DEBUG
            let _ = FrameLeafProbe.captures ? { FrameLeafProbe.waveformBodies += 1 }() : ()
#endif
            HUDWaveform(
                visualizer: visualizer,
                halfHeights: source.halfHeights,
                history: source.history,
                spectrumHistory: source.spectrumHistory,
                phase: source.phase,
                time: source.time,
                level: source.level,
                pulse: source.pulse,
                ceiling: source.ceiling,
                reveal: source.reveal,
                reduceMotionOverride: reduceMotion,
                material: material,
                glassRingLift: glassRingLift,
                glassRingInkGain: glassRingInkGain,
                onCanvasDraw: onCanvasDraw
            )
        }
    }
}

/// Renders incoming live dictation text inside the recording drawer so partial
/// updates never invalidate `HUDView.body` or `FrameHUDWaveform`.
@MainActor
private struct FrameLiveTextBody: View {
    let source: HUDFrameSource
    let fallbackText: String
    let cardSize: CGSize

    private static let bottomAnchor = "hud.live.text"

    var body: some View {
        let liveText = source.liveText(fallback: fallbackText)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Text(liveText)
                    .font(HUDTheme.liveFont)
                    .lineSpacing(HUDTheme.liveLineSpacing)
                    .hudInk(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HUDTheme.padding)
                    .padding(.bottom, HUDTheme.liveBottomPadding)
                    .id(Self.bottomAnchor)
                    .background(DotScrollViewConfigurator(surface: "hud"))
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .frame(height: HUDState.liveHeight - HUDState.headerHeight)
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(
                        colors: [.black, .black.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 10)
                }
            }
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .onChange(of: liveText) { _, _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .onChange(of: cardSize) { _, _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
    }
}

/// The recording dot. Uses synchronous `LiveDotView` (`CALayer`) for live `.frames`
/// and keeps SwiftUI `LiveDot` for static `.snapshot` captures.
@MainActor
private struct FrameLiveDot: View {
    let source: HUDFrameSource
    let material: HUDMaterial
    let reduceMotion: Bool

    var body: some View {
#if DEBUG
        let _ = FrameLeafProbe.captures ? { FrameLeafProbe.liveDotBodies += 1 }() : ()
#endif
        switch source {
        case .frames(let frameModel):
            LiveDotView(
                sink: frameModel.liveDotSink,
                makeInitialFrame: {
                    frameModel.currentLiveDotFrame(material: material, reduceMotion: reduceMotion)
                }
            )
            .frame(width: 36, height: 36)
            .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)
        case .snapshot:
            LiveDot(level: source.level, pulse: source.pulse, material: material)
        }
    }
}

/// Renders the recording elapsed clock directly from the frame model so tick
/// updates never invalidate the outer card `HUDModel`.
@MainActor
private struct FrameRecordingClock: View {
    let source: HUDFrameSource
    let material: HUDMaterial
    let fallback: String
    let useSystemInk: Bool

    var body: some View {
        let elapsed = source.recordingElapsed(fallback: fallback)
        Text(elapsed)
            .font(HUDTheme.clockFont)
            .tracking(HUDTheme.clockTracking)
            .foregroundStyle(HUDTheme.clockInk(material, useSystemInk: useSystemInk))
    }
}

@MainActor
private struct FrameWorkingPulse: View {
    let source: HUDFrameSource

    var body: some View {
        Circle()
            .fill(HUDTheme.amber)
            .frame(width: 7, height: 7)
            .scaleEffect(0.85 + 0.3 * abs(sin(source.shimmer * .pi)))
            .shadow(color: HUDTheme.amber.opacity(0.5), radius: 4)
    }
}

@MainActor
private struct FrameSpinner: View {
    let source: HUDFrameSource

    var body: some View {
#if DEBUG
        let _ = FrameLeafProbe.captures ? { FrameLeafProbe.spinnerBodies += 1 }() : ()
#endif
        HUDSpinner(phase: source.shimmer)
    }
}

/// The badge, title and check of a transcript header.
///
/// The ring's angle and the tail of a finished arc come from the frame clock.
/// Keeping them here means a tick cannot rebuild the card's text or its buttons.
@MainActor
private struct FrameRewriteIdentity: View {
    let source: HUDFrameSource
    let card: RewriteCard?
    let delivery: HUDDelivery
    let material: HUDMaterial
    let reduceMotion: Bool
    let title: String
    let titleCap: CGFloat
    let accessibilityTitle: String
    let ringStyleTitle: String?
    let ending: RewriteEnding?
    let failed: Bool

    var body: some View {
#if DEBUG
        let _ = FrameLeafProbe.captures ? { FrameLeafProbe.rewriteBodies += 1 }() : ()
#endif
        let rewriting = card?.activeStyleTitle
        let activeTime = (rewriting != nil || ending != nil) ? source.rewriteTime : 0
        let teardownFade = ending.map { end in
            HUDRewriteActivity.arcFade(
                isRunning: false,
                endedAt: end.at,
                time: activeTime,
                reduceMotion: reduceMotion
            )
        } ?? 0
        let announcing = rewriting != nil || teardownFade > 0

        ZStack {
            if announcing {
                RewriteArcRing(
                    shape: Circle(),
                    head: reduceMotion
                        ? HUDRewriteActivity.reducedMotionHeadDegrees
                        : HUDRewriteActivity.arcHeadAngle(
                            time: activeTime,
                            reduceMotion: false
                        ),
                    trail: HUDRewriteActivity.arcTrail(reduceMotion: reduceMotion),
                    fade: rewriting != nil ? 1 : teardownFade,
                    showsGlow: false
                )
                .frame(width: HUDTheme.badgeSize, height: HUDTheme.badgeSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(HUDView.rewritingAccessibilityLabel(ringStyleTitle)))
            } else if failed {
                Circle()
                    .fill(HUDTheme.warning.opacity(0.14))
                    .frame(width: HUDTheme.badgeSize, height: HUDTheme.badgeSize)
                Image(systemName: "exclamationmark.triangle")
                    .font(DotType.font(10.5, .bold))
                    .foregroundStyle(HUDTheme.warning)
            } else {
                Circle()
                    .fill(delivery.color.opacity(0.14))
                    .frame(width: HUDTheme.badgeSize, height: HUDTheme.badgeSize)
                Image(systemName: delivery.glyph)
                    .font(DotType.font(10.5, .bold))
                    .foregroundStyle(HUDTheme.statusInk(
                        delivery.color,
                        material: material,
                        useSystemInk: material == .glass
                    ))
            }
        }

        if !announcing {
            Text(title)
                .font(HUDTheme.labelFont)
                .tracking(HUDTheme.labelTracking)
                .foregroundStyle(HUDTheme.statusInk(
                    failed ? HUDTheme.warning : delivery.color,
                    material: material,
                    useSystemInk: material == .glass
                ))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: titleCap, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(Text(accessibilityTitle))
        }

        if let card, !announcing, HUDView.showsCheckBadge(card) {
            RewriteCheckBadge(warning: card.warning)
        }
    }
}

/// The indeterminate ring of the transcribing state.
///
/// It is drawn rather than handed to `ProgressView` so the same geometry
/// renders in an `ImageRenderer` and on screen.
struct HUDSpinner: View {
    /// The phase of the rotation, from `0` to `1`.
    let phase: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(HUDTheme.amber.opacity(0.10), lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: 0.26)
                .stroke(
                    HUDTheme.amber,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .rotationEffect(.degrees(phase * 360 - 90))
                .shadow(color: HUDTheme.amber.opacity(0.45), radius: 3)
        }
        .frame(width: 15, height: 15)
    }
}

/// The live dot and its halo.
struct LiveDot: View {
    /// The level of the voice, from `0` to `1`.
    let level: Double
    /// The phase of the pulse, from `0` to `1`.
    let pulse: Double
    /// The card material the ring and shadow are drawn on.
    var material: HUDMaterial = .black

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How loud the dot is drawn, from `0` to `1`.
    ///
    /// The dot follows the voice rather than a clock: a whisper leaves a small
    /// warm dot and a word at the top of the person's range leaves a larger,
    /// brighter one. It never reaches zero, because the dot is also the answer
    /// to "is it recording", which has to be legible in silence.
    private var presence: Double {
        min(1, max(0, level))
    }

    private var core: Color {
        HUDTheme.meter(0.42 + 0.58 * presence, ceiling: 1, material: material)
    }

    var body: some View {
        let glowDiameter = HUDTheme.dotDiameter * (1 + presence * 0.26) + (5.0 + 9.0 * presence)
        let glowAlpha = 0.30 + 0.55 * presence
        let glowInk = HUDTheme.recordingInk(material)
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: glowInk.opacity(glowAlpha), location: 0.25),
                            .init(color: glowInk.opacity(glowAlpha * 0.35), location: 0.62),
                            .init(color: glowInk.opacity(0), location: 1.0),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: glowDiameter / 2
                    )
                )
                .frame(width: glowDiameter, height: glowDiameter)

            if !reduceMotion {
                Circle()
                    .stroke(HUDTheme.recordingInk(material).opacity((0.42 + 0.30 * presence) * (1 - pulse)), lineWidth: 1.5)
                    .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)
                    .scaleEffect(1 + pulse * (1.15 + 0.45 * presence))
            }

            Circle()
                .fill(core)
                .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)
                .scaleEffect(1 + presence * 0.26)
        }
        .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)
    }
}

extension HUDDelivery {
    /// The title of the delivery.
    var title: String {
        switch self {
        case .copied: "COPIED"
        case .pasted: "PASTED"
        case .failed: "FAILED"
        }
    }

    /// The colour of the delivery.
    var color: Color {
        switch self {
        case .copied, .pasted: HUDTheme.silver
        case .failed: HUDTheme.warning
        }
    }

    /// The symbol of the delivery.
    var glyph: String {
        switch self {
        case .copied: "checkmark"
        case .pasted: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// An inline-editable AppKit text view embedded in the HUD transcript body.
///
/// Clicking or double-clicking anywhere on the transcript text immediately
/// enables inline editing and places the cursor (or word selection) at that
/// exact character position. Pressing `Enter` concludes inline editing and
/// releases keyboard focus; pressing `Shift + Enter` inserts a newline.
private final class HUDTranscriptScrollView: NSScrollView {
    override func layout() {
        super.layout()
        syncDocumentWidthIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncDocumentWidthIfNeeded()
    }

    func syncDocumentWidthIfNeeded() {
        guard let textView = documentView as? NSTextView else { return }
        let targetWidth = contentView.bounds.width
        guard targetWidth > 1 else { return }
        let widthMismatch = abs(textView.frame.width - targetWidth) > 0.5
        let container = textView.textContainer
        let insetWidth = textView.textContainerInset.width * 2
        let targetContainerWidth = max(120, targetWidth - insetWidth)
        let containerMismatch = container.map {
            abs($0.containerSize.width - targetContainerWidth) > 0.5
        } ?? false
        guard widthMismatch || containerMismatch else { return }
        if widthMismatch {
            textView.setFrameSize(NSSize(width: targetWidth, height: textView.frame.height))
        }
        if let container {
            if containerMismatch {
                container.containerSize = NSSize(
                    width: targetContainerWidth,
                    height: .greatestFiniteMagnitude
                )
            }
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()
    }
}

struct HUDInlineTranscriptView: NSViewRepresentable {
    let text: String
    let isEditing: Bool
    let usesSystemInk: Bool
    var onBeginEditing: () -> Void
    var onEndEditing: () -> Void
    var onUpdateText: (String) -> Void

    /// The fixed cream on Black, or AppKit's adaptive label colour on Glass.
    private var inkColor: NSColor {
        usesSystemInk
            ? .labelColor
            : NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = HUDTranscriptScrollView(
            frame: NSRect(x: 0, y: 0, width: HUDState.transcriptWidth, height: 100)
        )
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // The body stops at its first and last line; it never pulls past them.
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let contentWidth = max(
            120,
            HUDState.transcriptWidth - (HUDTheme.padding - 5) * 2
        )
        let textView = HUDTranscriptNSTextView(
            frame: NSRect(x: 0, y: 0, width: HUDState.transcriptWidth, height: 100)
        )
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = DotType.nsFont(15, .regular)
        textView.textColor = inkColor
        textView.insertionPointColor = NSColor(red: 0.96, green: 0.62, blue: 0.14, alpha: 1.0)
        textView.textContainerInset = NSSize(
            width: HUDTheme.padding - 5,
            height: HUDTheme.verticalPadding
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: contentWidth,
            height: .greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 5

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = HUDTheme.transcriptLineSpacing
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: DotType.nsFont(15, .regular),
            .foregroundColor: inkColor,
            .paragraphStyle: paragraph,
        ]

        textView.onMouseDownStartEditing = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onBeginEditing()
        }
        textView.onFinishEditing = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEndEditing()
        }

        context.coordinator.applyAttributedText(text, to: textView)
        context.coordinator.hasShownText = !text.isEmpty
        scrollView.documentView = textView

        // The card opens on the first word. It used to scroll to its own end
        // as soon as it appeared, so the first line of every transcript that
        // did not fit was sliced in half by the top edge of the card, and the
        // reader started in the middle of a paragraph.
        DispatchQueue.main.async {
            Self.scrollToStart(scrollView: scrollView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? HUDTranscriptNSTextView else {
            (scrollView as? HUDTranscriptScrollView)?.syncDocumentWidthIfNeeded()
            return
        }
        // Where the reader is, read before a reflow or new text moves the end.
        let wasAtEnd = Self.isAtEnd(scrollView: scrollView, textView: textView)
        let wasAtStart = !wasAtEnd && scrollView.contentView.bounds.origin.y <= 2
        (scrollView as? HUDTranscriptScrollView)?.syncDocumentWidthIfNeeded()
        let textChanged = textView.string != text
        let inkChanged = context.coordinator.appliedUsesSystemInk != usesSystemInk
        if textChanged || inkChanged {
            let selectedRanges = textView.selectedRanges
            textView.textColor = inkColor
            textView.typingAttributes[.foregroundColor] = inkColor
            context.coordinator.isUpdatingProgrammatically = true
            context.coordinator.applyAttributedText(text, to: textView)
            if isEditing {
                textView.selectedRanges = selectedRanges
            } else if textChanged, context.coordinator.hasShownText {
                // Words that arrive while the card is open are the reason to
                // follow the end, but only for a reader already there: one who
                // scrolled back keeps their place.
                if wasAtEnd {
                    Self.scrollToBottomIfNeeded(scrollView: scrollView, textView: textView)
                } else if wasAtStart {
                    Self.scrollToStart(scrollView: scrollView)
                }
            } else if textChanged, wasAtStart {
                // A sentence that was already complete is read from its start,
                // unless the reader has already moved.
                Self.scrollToStart(scrollView: scrollView)
            }
            context.coordinator.hasShownText = !text.isEmpty
            context.coordinator.isUpdatingProgrammatically = false
        }
        if !isEditing, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    /// A transcript that still fits has no end to be at: a reader who has
    /// never scrolled stays on the first word when new text first overflows.
    private static func isAtEnd(scrollView: NSScrollView, textView: NSTextView) -> Bool {
        let maxOffset = textView.frame.height - scrollView.contentView.bounds.height
        return maxOffset > 2 && scrollView.contentView.bounds.origin.y >= maxOffset - 2
    }

    private static func scrollToStart(scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func scrollToBottomIfNeeded(scrollView: NSScrollView, textView: NSTextView) {
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        let docHeight = textView.frame.height
        let clipHeight = scrollView.contentView.bounds.height
        if docHeight > clipHeight {
            let bottomOffset = max(0, docHeight - clipHeight)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HUDInlineTranscriptView
        var isUpdatingProgrammatically = false
        /// Whether the card has already drawn text. The first text a transcript
        /// card receives is the whole take, and it is read from its first
        /// word; only text that arrives after that follows the end of the card.
        var hasShownText = false
        var appliedUsesSystemInk: Bool?

        init(_ parent: HUDInlineTranscriptView) {
            self.parent = parent
        }

        func applyAttributedText(_ string: String, to textView: NSTextView) {
            appliedUsesSystemInk = parent.usesSystemInk
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = HUDTheme.transcriptLineSpacing
            let attrs: [NSAttributedString.Key: Any] = [
                .font: DotType.nsFont(15, .regular),
                .foregroundColor: parent.inkColor,
                .paragraphStyle: paragraph,
            ]
            textView.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: attrs))
            if textView.bounds.width > 1, let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
                textView.sizeToFit()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingProgrammatically,
                  let textView = notification.object as? NSTextView else { return }
            parent.onUpdateText(textView.string)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard !isUpdatingProgrammatically else { return }
            parent.onEndEditing()
        }
    }
}

/// Custom `NSTextView` that activates inline editing on the very first click
/// or double-click right at the clicked character position, concludes editing
/// on `Enter` (`Return`), and inserts a newline on `Shift + Enter`.
final class HUDTranscriptNSTextView: NSTextView {
    var onMouseDownStartEditing: (() -> Void)?
    var onFinishEditing: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDownStartEditing?()
        if let panel = window as? HUDPanel {
            panel.allowsKey = true
            panel.makeKey()
        }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Return (36) or Keypad Enter (76)
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onFinishEditing?()
                window?.makeFirstResponder(nil)
                if let panel = window as? HUDPanel {
                    panel.allowsKey = false
                    panel.resignKey()
                }
            }
            return
        }
        // Escape (53) also concludes inline editing
        if event.keyCode == 53 {
            onFinishEditing?()
            window?.makeFirstResponder(nil)
            if let panel = window as? HUDPanel {
                panel.allowsKey = false
                panel.resignKey()
            }
            return
        }
        super.keyDown(with: event)
    }
}
