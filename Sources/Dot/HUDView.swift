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
    /// Whether the card casts its shadow. The corner test renders without it.
    var showsShadow = true
    /// Whether the frame is animated. The documentation renders are not.
    var animated = true
    /// What the island's buttons do. An action without a closure is not
    /// drawn; the app wires History, the preview leaves it out.
    var actions = HUDActions()
    /// Whether the person asked for reduced motion, as the environment says.
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// A value the documentation renders can set without a system preference.
    var reduceMotionOverride: Bool? = nil
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
        guard showsShadow else { return (.clear, 0, 0) }
        let alpha: Double
        let radius: CGFloat
        let offset: CGFloat
        if HUDSurface.drawsSystemGlass(model.material) {
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
        if let emergence {
            pouring(emergence)
        } else {
            fading
        }
    }

    /// The card that arrives by fading, drawn where it rests.
    ///
    /// This is the appearance of a card with no display to pour out of: a still,
    /// a documentation render, and the HUD the headless test keeps off the
    /// screens.
    private var fading: some View {
        let shade = shadow()
        return content
            .opacity(model.content)
            .scaleEffect(0.99 + 0.01 * model.content)
            .offset(y: (1 - model.content) * 6)
            .frame(width: model.cardSize.width, height: model.cardSize.height)
            .background(HUDSurface(material: model.material))
            .clipShape(shape)
            .overlay(alignment: .topTrailing) { tooltip }
            .compositingGroup()
            .shadow(color: shade.color, radius: shade.radius, x: 0, y: shade.y)
            .opacity(model.presence)
            .scaleEffect(0.94 + 0.06 * model.presence)
            .offset(y: (1 - model.presence) * -10)
            .blur(radius: (1 - model.presence) * 7)
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
        let rest = HUDEmergence.Rest(
            rect: CGRect(origin: .zero, size: model.cardSize),
            cornerRadius: HUDTheme.cornerRadius
        )
        let source = scene.source(inCardOf: model.cardSize)
        let progress = HUDEmergence.progress(model.emergence, reduceMotion: reduceMotion)
        let piece = HUDEmergence.shape(progress: progress, source: source, rest: rest)
        let shade = shadow(piece.mix)
        return ZStack(alignment: .topLeading) {
            HUDEmergence.path(piece)
                .fill(Color(red: 0, green: 0, blue: 0))
                .opacity(1 - piece.mix)

            HUDSurface(material: model.material)
                .opacity(piece.mix)
                .frame(width: piece.card.width, height: piece.card.height)
                .clipShape(clip(piece, rest: rest))
                .offset(x: piece.card.minX, y: piece.card.minY)

            content
                .opacity(HUDEmergence.contentOpacity(
                    content: model.content,
                    progress: progress
                ))
                .scaleEffect(0.99 + 0.01 * model.content)
                .offset(y: (1 - model.content) * 6)
                .frame(width: model.cardSize.width, height: model.cardSize.height)
                .clipShape(shape)
                .overlay(alignment: .topTrailing) { tooltip }
        }
        .frame(
            width: model.cardSize.width,
            height: model.cardSize.height,
            alignment: .topLeading
        )
        .compositingGroup()
        .shadow(color: shade.color, radius: shade.radius, x: 0, y: shade.y)
        .animation(animation(.shape), value: model.cardSize)
    }

    /// The clip of the card's material while the card is emerging.
    ///
    /// At rest it is the card's own shape, the continuous rounded rectangle the
    /// card has always been, so the last frame of the emergence is the card the
    /// product draws and nothing else. While the shape is travelling it is the
    /// shape's own rectangle, with the radius that rectangle can hold.
    ///
    /// - Parameters:
    ///   - piece: the shape at this moment.
    ///   - rest: the card at rest.
    /// - Returns: the shape the material is clipped to.
    private func clip(_ piece: HUDEmergence.Shape, rest: HUDEmergence.Rest) -> AnyShape {
        guard !piece.isRest(rest) else { return AnyShape(shape) }
        return AnyShape(Path(roundedRect: piece.card, cornerRadius: piece.cornerRadius))
    }

    /// The tooltip of the button under the pointer, when there is one.
    @ViewBuilder
    private var tooltip: some View {
        if let hovered = model.hoveredAction {
            HUDActionTooltip(
                action: hovered,
                material: model.material,
                versioned: model.rewrite != nil
            )
                .offset(x: tooltipOffsetX(for: hovered), y: -25)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
        }
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
        case .assistantRecording(let elapsed):
            assistantRecording(elapsed: elapsed)
        case .assistantThinking(let question):
            assistantLine(text: question, color: HUDTheme.ink2)
        case .assistantTool(let connectorName):
            assistantLine(text: "Using \(connectorName)", color: HUDTheme.ink)
        case .assistantAnswer(let text, let state):
            assistantAnswer(text: text, state: state)
        case .assistantConfirm(let request):
            assistantConfirm(request)
        }
    }

    // MARK: - Assistant

    /// The recording card, with the assistant's mark where the live dot is.
    ///
    /// Everything else is the recording card: the clock, the waveform, the two
    /// buttons. A question is spoken into the same microphone as a dictation, so
    /// the card that says it is recording is the same card.
    private func assistantRecording(elapsed: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "sparkle")
                    .font(DotType.font(11, .semibold))
                    .foregroundStyle(HUDTheme.live)
                    .opacity(0.55 + 0.45 * model.pulse)
                    .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)

                Color.clear.frame(width: 10)

                Text("REC")
                    .font(HUDTheme.labelFont)
                    .tracking(HUDTheme.labelTracking)
                    .foregroundStyle(HUDTheme.ink)

                Color.clear.frame(width: 10)

                Text(elapsed)
                    .font(HUDTheme.clockFont)
                    .tracking(HUDTheme.clockTracking)
                    .foregroundStyle(HUDTheme.clockInk(model.material))

                Color.clear.frame(width: 14)

                HUDWaveform(
                    visualizer: model.visualizer,
                    halfHeights: model.halfHeights,
                    history: model.history,
                    spectrumHistory: model.spectrumHistory,
                    phase: model.phase,
                    time: model.time,
                    level: model.level,
                    pulse: model.pulse,
                    ceiling: model.ceiling,
                    reveal: model.reveal,
                    material: model.material,
                    glassRingLift: glassRingLift,
                    glassRingInkGain: glassRingInkGain
                )
                .frame(maxWidth: .infinity)
                .frame(height: HUDTheme.waveformHeight)

                controlsSection([.stop, .cancel])
            }
            .padding(.horizontal, HUDTheme.padding)
            .frame(maxWidth: .infinity)
            .frame(height: HUDState.recordingHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// One line of the assistant at work: its mark, a sentence, and the dots.
    private func assistantLine(text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(DotType.font(11, .semibold))
                .foregroundStyle(HUDTheme.live)

            Text(text)
                .font(HUDTheme.assistantFont)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            AssistantPulseDots(time: model.time, reduceMotion: reduceMotion)
        }
        .padding(.horizontal, HUDTheme.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Assistant answer

    /// The answer, in the transcript's clothes: a labelled header and a body
    /// that grows to the limit and then scrolls.
    private func assistantAnswer(text: String, state: AssistantAnswerState) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(HUDHeader.title(for: state))
                    .font(HUDTheme.labelFont)
                    .tracking(HUDTheme.labelTracking)
                    .foregroundStyle(assistantLabelColor(state))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: HUDHeader.maximumTitleWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(Text(HUDHeader.accessibilityLabel(for: state)))

                if state == .speaking {
                    Image(systemName: "speaker.wave.2")
                        .font(DotType.font(11, .semibold))
                        .foregroundStyle(HUDTheme.live)
                        .opacity(0.55 + 0.45 * abs(sin(model.time * .pi * 1.6)))
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, HUDTheme.padding)
            .frame(height: HUDTheme.headerHeight)

            Rectangle()
                .fill(HUDTheme.hairline)
                .frame(height: 1)

            ScrollView(.vertical) {
                Text(text)
                    .font(HUDTheme.transcriptFont)
                    .lineSpacing(HUDTheme.transcriptLineSpacing)
                    .foregroundStyle(HUDTheme.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HUDTheme.padding)
                    .padding(.vertical, HUDTheme.verticalPadding)
                    .id(Self.assistantAnswerAnchor)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityLabel(Text("Answer"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func assistantLabelColor(_ state: AssistantAnswerState) -> Color {
        switch state {
        case .pasted, .copied: HUDTheme.mint
        case .speaking: HUDTheme.live
        case .streaming, .spoken: HUDTheme.ink2
        }
    }

    private static let assistantAnswerAnchor = "hud.assistant.answer"

    // MARK: - Assistant confirmation

    /// The card that asks before a connected app does something.
    ///
    /// It is not a dialog and it never takes the keyboard: the person is still
    /// typing into the application behind it, and a Return meant for that
    /// application must never approve this. The two buttons are the only way to
    /// answer other than Escape.
    private func assistantConfirm(_ request: ConfirmationRequest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: request.connectorID.symbol)
                    .font(DotType.font(14, .semibold))
                    .foregroundStyle(HUDTheme.ink2)

                Text(request.connectorName.uppercased())
                    .font(HUDTheme.labelFont)
                    .tracking(HUDTheme.labelTracking)
                    .foregroundStyle(HUDTheme.ink2)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(height: HUDConfirmLayout.headerHeight)

            Color.clear.frame(height: HUDConfirmLayout.rowGap)

            Text(request.summary)
                .font(DotType.font(14, .regular))
                .foregroundStyle(HUDTheme.ink)
                .lineLimit(HUDConfirmLayout.maximumSummaryLines)
                .lineSpacing(2)
                .frame(width: HUDConfirmLayout.summaryWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: HUDConfirmLayout.buttonGap) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    model.assistantCancel?()
                }
                .buttonStyle(HUDConfirmButtonStyle(isPrimary: false, isDestructive: false))

                Button(request.allowTitle) {
                    model.assistantAllow?()
                }
                .buttonStyle(HUDConfirmButtonStyle(
                    isPrimary: true,
                    isDestructive: request.isDestructive
                ))
            }
        }
        .padding(.horizontal, HUDState.padding)
        .padding(.vertical, HUDState.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Recording

    private func recording(elapsed: String) -> some View {
        let showsLiveText = !model.liveText.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                LiveDot(level: model.level, pulse: model.pulse)
                    .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)

                Color.clear.frame(width: 10)

                Text("REC")
                    .font(HUDTheme.labelFont)
                    .tracking(HUDTheme.labelTracking)
                    .foregroundStyle(HUDTheme.ink)

                Color.clear.frame(width: 10)

                Text(elapsed)
                    .font(HUDTheme.clockFont)
                    .tracking(HUDTheme.clockTracking)
                    .foregroundStyle(HUDTheme.clockInk(model.material))

                Color.clear.frame(width: 14)

                HUDWaveform(
                    visualizer: model.visualizer,
                    halfHeights: model.halfHeights,
                    history: model.history,
                    spectrumHistory: model.spectrumHistory,
                    phase: model.phase,
                    time: model.time,
                    level: model.level,
                    pulse: model.pulse,
                    ceiling: model.ceiling,
                    reveal: model.reveal,
                    material: model.material,
                    glassRingLift: glassRingLift,
                    glassRingInkGain: glassRingInkGain
                )
                .frame(maxWidth: .infinity)
                .frame(height: HUDTheme.waveformHeight)

                controlsSection([.stop, .cancel])
            }
            .padding(.horizontal, HUDTheme.padding)
            .frame(maxWidth: .infinity)
            .frame(height: showsLiveText ? HUDState.headerHeight : HUDState.recordingHeight)

            if showsLiveText {
                // The newest words matter while the user is speaking, so the
                // live body follows the end of the text. Truncating the head
                // showed two lines and hid the rest of a long dictation; the
                // body scrolls with the speech instead.
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        Text(model.liveText)
                            .font(HUDTheme.liveFont)
                            .lineSpacing(HUDTheme.liveLineSpacing)
                            .foregroundStyle(HUDTheme.ink2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, HUDTheme.padding)
                            .padding(.bottom, HUDTheme.liveBottomPadding)
                            .id(Self.liveTextAnchor)
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    .defaultScrollAnchor(.bottom)
                    .frame(height: HUDState.liveHeight - HUDState.headerHeight)
                    // The body follows the end of the sentence, so it is always
                    // mid line at the foot of the card. Without the fade the
                    // card ends in the bottom half of a line of text, which is
                    // the one thing a finished surface cannot look like.
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
                    .onAppear { followLiveText(proxy) }
                    .onChange(of: model.liveText) { _, _ in followLiveText(proxy) }
                    .onChange(of: model.cardSize) { _, _ in followLiveText(proxy) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Working

    private var working: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(HUDTheme.amber)
                .frame(width: 7, height: 7)
                .scaleEffect(0.85 + 0.3 * abs(sin(model.shimmer * .pi)))
                .shadow(color: HUDTheme.amber.opacity(0.5), radius: 4)

            Text("TRANSCRIBING")
                .font(HUDTheme.labelFont)
                .tracking(HUDTheme.labelTracking)
                .foregroundStyle(HUDTheme.ink2)

            // Which request of how many is in flight. A spinner alone cannot
            // tell "almost done" from "stuck", and the stop path is short
            // enough that the count is honest.
            if !model.workingDetail.isEmpty {
                Text(model.workingDetail)
                    .font(HUDTheme.clockFont)
                    .foregroundStyle(HUDTheme.ink3)
                    .accessibilityLabel(Text("Request \(model.workingDetail)"))
            }

            Spacer(minLength: 0)

            HUDSpinner(phase: model.shimmer)

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
        let rewriting = card?.activeStyleTitle
        // The arc outlives the phase by the 140 ms the card gives it to leave.
        // The header holds its in-progress face for those frames, because a
        // delivery mark drawn over a ring that is still on screen would name
        // the end while the card is still showing the work.
        let teardownFade = model.rewriteEnding.map { ending in
            HUDRewriteActivity.arcFade(
                isRunning: false,
                endedAt: ending.at,
                time: model.time,
                reduceMotion: reduceMotion
            )
        } ?? 0
        let announcing = rewriting != nil || teardownFade > 0
        let failed = card?.phase == .failed
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                // While a style runs the badge is the work: a ring drawn from the
                // same arc, the same clock and the same angle as the chip that
                // was clicked, with no fill and no glyph. The check mark belongs
                // to a delivery that has already happened, and drawing it over a
                // request that is still arriving claims an answer.
                ZStack {
                    if announcing {
                        RewriteArcRing(
                            shape: Circle(),
                            head: reduceMotion
                                ? HUDRewriteActivity.reducedMotionHeadDegrees
                                : HUDRewriteActivity.arcHeadAngle(
                                    time: model.time,
                                    reduceMotion: false
                                ),
                            trail: HUDRewriteActivity.arcTrail(reduceMotion: reduceMotion),
                            fade: rewriting != nil ? 1 : teardownFade,
                            showsGlow: false
                        )
                        .frame(width: HUDTheme.badgeSize, height: HUDTheme.badgeSize)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(Self.rewritingAccessibilityLabel(
                            ringStyleTitle(card: card, running: rewriting)
                        )))
                    } else if failed {
                        // A failure is not a delivery that happened and not a
                        // finished version to check: it is the request's own
                        // verdict, and it takes the badge until the card is
                        // closed or another style is asked for.
                        Circle()
                            .fill(HUDTheme.live.opacity(0.14))
                            .frame(width: HUDTheme.badgeSize, height: HUDTheme.badgeSize)
                        Image(systemName: "exclamationmark.triangle")
                            .font(DotType.font(10.5, .bold))
                            .foregroundStyle(HUDTheme.live)
                    } else {
                        Circle()
                            .fill(delivery.color.opacity(0.14))
                            .frame(width: HUDTheme.badgeSize, height: HUDTheme.badgeSize)
                        Image(systemName: delivery.glyph)
                            .font(DotType.font(10.5, .bold))
                            .foregroundStyle(HUDTheme.statusInk(
                                delivery.color,
                                material: model.material
                            ))
                    }
                }

                // The application the words went into, when there is one. The
                // title is already cut to the room the header has, so a long
                // name can never push the clock or the buttons out of the card.
                // Nothing is drawn in its slot while a style runs: the ring says
                // what the header used to have to spell out, and the caps row
                // that repeated it was a label over a control that already says
                // it.
                if !announcing {
                    Text(headerTitle(for: card, delivery: delivery, destination: destination))
                        .font(HUDTheme.labelFont)
                        .tracking(HUDTheme.labelTracking)
                        .foregroundStyle(HUDTheme.statusInk(
                            failed ? HUDTheme.live : delivery.color,
                            material: model.material
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: headerTitleCap(for: card), alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(Text(
                            headerAccessibilityLabel(
                                for: card,
                                delivery: delivery,
                                destination: destination
                            )
                        ))
                }

                if let card, !announcing, Self.showsCheckBadge(card) {
                    RewriteCheckBadge(warning: card.warning)
                }

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
                    .foregroundStyle(HUDTheme.clockInk(model.material))
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

    /// The anchors the two scrollable bodies follow.
    private static let liveTextAnchor = "hud.live.text"
    private static let transcriptAnchor = "hud.transcript"

    /// Keeps the live body on its newest words.
    ///
    /// The card is presented before the first words arrive, and it grows when
    /// they do, so the end of the text is what the person is watching. Without
    /// this the body sat at the top of a long partial and showed the beginning
    /// of a sentence the person had already finished.
    private func followLiveText(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.liveTextAnchor, anchor: .bottom)
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
                    ? HUDTheme.live
                    : HUDTheme.accent)

            Text(text)
                .font(HUDTheme.messageFont)
                .foregroundStyle(HUDTheme.ink)
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
                        .foregroundStyle(HUDTheme.ink2)
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
        case .recording, .assistantRecording:
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
        case .assistantThinking, .assistantTool, .assistantAnswer, .assistantConfirm:
            // The assistant's cards carry no buttons of their own: the shortcut
            // stops the turn and Escape backs out, and a confirmation draws its
            // own two.
            return []
        }
    }

    private func tooltipOffsetX(for action: HUDAction) -> CGFloat {
        let items = activeControlItems()
        guard let idx = items.firstIndex(of: action) else { return -HUDTheme.padding }
        let trailingIndex = items.count - 1 - idx
        let step = HUDTheme.actionSize + 4
        return -(HUDTheme.padding + CGFloat(trailingIndex) * step * 0.65)
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
            .foregroundStyle(HUDTheme.ink2)
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
        self == .stopRewrite ? HUDTheme.live : HUDTheme.ink3
    }

    /// The colour the icon takes under the pointer.
    var hoverColor: Color {
        switch self {
        case .stop, .stopRewrite: HUDTheme.live
        case .cancel, .close: HUDTheme.ink
        case .copy, .paste, .history, .settings: HUDTheme.accent
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
                .foregroundStyle(hovering ? HUDTheme.accentTip : HUDTheme.ink)
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
    var onHoverChange: ((Bool) -> Void)? = nil
    let perform: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var activeHover: Bool {
        isEnabled && (hovering || isHovered)
    }

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.symbol)
                .font(HUDTheme.actionFont)
                .foregroundStyle(activeHover ? action.hoverColor : action.restingColor)
                .frame(width: HUDTheme.actionSize, height: HUDTheme.actionSize)
                .background(
                    Circle()
                        .fill(activeHover ? HUDTheme.actionFillHover : HUDTheme.actionFill)
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            activeHover ? HUDTheme.actionBorderHover : HUDTheme.actionBorder,
                            lineWidth: 0.75
                        )
                )
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.14),
                    value: activeHover
                )
        }
        .buttonStyle(HUDActionButtonStyle(reduceMotion: reduceMotion))
        .disabled(!isEnabled)
        .onHover { inside in
            hovering = inside
            onHoverChange?(inside)
        }
        .accessibilityLabel(Text(action.label(versioned: versioned)))
        .accessibilityHint(Text(action.help(versioned: versioned)))
    }
}

/// A themed floating tooltip pill that sits cleanly above the HUD island's top edge
/// when hovering over an action button, never overlapping the transcript text.
private struct HUDActionTooltip: View {
    let action: HUDAction
    var material: HUDMaterial = .glass
    var versioned: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: action.symbol)
                .font(DotType.font(9.5, .semibold))
                .foregroundStyle(action.hoverColor)
            Text(action.help(versioned: versioned))
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
                            Color.white.opacity(0.32),
                            Color.white.opacity(0.10),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.85
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 3)
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
        HUDTheme.meter(0.42 + 0.58 * presence, ceiling: 1)
    }

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .stroke(HUDTheme.live.opacity((0.42 + 0.30 * presence) * (1 - pulse)), lineWidth: 1.5)
                    .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)
                    .scaleEffect(1 + pulse * (1.15 + 0.45 * presence))
            }

            Circle()
                .fill(core)
                .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)
                .scaleEffect(1 + presence * 0.26)
                .shadow(
                    color: HUDTheme.live.opacity(0.30 + 0.55 * presence),
                    radius: 2.5 + 4.5 * presence
                )
        }
        .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: presence)
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
        case .failed: HUDTheme.live
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
struct HUDInlineTranscriptView: NSViewRepresentable {
    let text: String
    let isEditing: Bool
    var onBeginEditing: () -> Void
    var onEndEditing: () -> Void
    var onUpdateText: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = HUDTranscriptNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = DotType.nsFont(15, .regular)
        textView.textColor = NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
        textView.insertionPointColor = NSColor(red: 0.96, green: 0.62, blue: 0.14, alpha: 1.0)
        textView.textContainerInset = NSSize(
            width: HUDTheme.padding - 5,
            height: HUDTheme.verticalPadding
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 5

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = HUDTheme.transcriptLineSpacing
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: DotType.nsFont(15, .regular),
            .foregroundColor: NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0),
            .paragraphStyle: paragraph,
        ]

        textView.onMouseDownStartEditing = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onBeginEditing()
        }
        textView.onFinishEditing = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEndEditing()
        }

        context.coordinator.applyAttributedText(text, to: textView)
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
        guard let textView = scrollView.documentView as? HUDTranscriptNSTextView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            context.coordinator.isUpdatingProgrammatically = true
            context.coordinator.applyAttributedText(text, to: textView)
            if isEditing {
                textView.selectedRanges = selectedRanges
            } else if context.coordinator.hasShownText {
                // Words that arrive while the card is open are the reason to
                // follow the end; a sentence that was already complete is read
                // from its start.
                Self.scrollToBottomIfNeeded(scrollView: scrollView, textView: textView)
            } else {
                Self.scrollToStart(scrollView: scrollView)
            }
            context.coordinator.hasShownText = !text.isEmpty
            context.coordinator.isUpdatingProgrammatically = false
        }
        if !isEditing, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    private static func scrollToStart(scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func scrollToBottomIfNeeded(scrollView: NSScrollView, textView: NSTextView) {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
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

        init(_ parent: HUDInlineTranscriptView) {
            self.parent = parent
        }

        func applyAttributedText(_ string: String, to textView: NSTextView) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = HUDTheme.transcriptLineSpacing
            let attrs: [NSAttributedString.Key: Any] = [
                .font: DotType.nsFont(15, .regular),
                .foregroundColor: NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0),
                .paragraphStyle: paragraph,
            ]
            textView.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: attrs))
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            textView.sizeToFit()
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

/// The three dots that say the assistant is working.
///
/// They pulse in sequence on a 1.2 second cycle, in the amber of the live dot.
/// A person who asked for reduced motion gets the three of them at rest: the
/// state is still readable from the mark and the sentence, and nothing on the
/// card moves.
struct AssistantPulseDots: View {
    /// The seconds the card has been on screen.
    var time: Double
    /// Whether the motion is reduced.
    var reduceMotion: Bool

    /// The length of one pulse, in seconds.
    static let cycle: Double = 1.2
    /// The diameter of one dot, in points.
    static let diameter: CGFloat = 4
    /// The distance between two dots, in points.
    static let gap: CGFloat = 4

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(HUDTheme.live)
                    .frame(width: Self.diameter, height: Self.diameter)
                    .opacity(alpha(index))
            }
        }
        .frame(height: HUDTheme.dotDiameter)
        .accessibilityHidden(true)
    }

    private func alpha(_ index: Int) -> Double {
        guard !reduceMotion else { return 0.55 }
        let phase = (time / Self.cycle + Double(index) * 0.18)
            .truncatingRemainder(dividingBy: 1)
        let wave = max(0, 1 - abs(phase - 0.5) * 2)
        return 0.25 + 0.75 * wave
    }
}

/// The two capsules of the confirmation card.
///
/// The primary one is the porcelain of the card's ink, unreadable nowhere and
/// unmistakable; a call that destroys something fills it with the system's red
/// instead, so the button that deletes does not look like the button that
/// allows.
private struct HUDConfirmButtonStyle: ButtonStyle {
    /// Whether this is the button that allows the call.
    var isPrimary: Bool
    /// Whether the call destroys something.
    var isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        HUDConfirmButtonBody(
            configuration: configuration,
            isPrimary: isPrimary,
            isDestructive: isDestructive
        )
    }
}

private struct HUDConfirmButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isPrimary: Bool
    let isDestructive: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reducesMotion: Bool {
        reduceMotion || DotMotion.reducesMotion
    }

    var body: some View {
        configuration.label
            .font(DotType.font(12, .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: HUDConfirmLayout.buttonHeight)
            .background(Capsule(style: .circular).fill(background))
            .overlay {
                if !isPrimary {
                    Capsule(style: .circular).strokeBorder(HUDTheme.actionBorderHover, lineWidth: 1)
                }
            }
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
            .contentShape(Capsule(style: .circular))
    }

    private var foreground: Color {
        guard isPrimary else { return HUDTheme.ink }
        return isDestructive ? .white : Color.black.opacity(0.86)
    }

    private var background: Color {
        guard isPrimary else { return HUDTheme.actionFill }
        return isDestructive ? Color(nsColor: .systemRed) : HUDTheme.ink
    }
}
