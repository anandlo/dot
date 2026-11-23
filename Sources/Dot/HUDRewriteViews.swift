import AppKit
import DotCore
import SwiftUI

/// The rewrite layer of the transcript card.
///
/// It is one section under the body: a note when a version went somewhere
/// else, the two capsules when the check refused a draft, and the version row
/// the person reviews and navigates with. Nothing here takes the keyboard: the
/// panel can never become key, so a chip is a click and only a click.
extension HUDView {
    /// The body of a versioned card: the status of a running rewrite, then the
    /// selected version alone.
    ///
    /// The status is drawn from the phase, not from the tokens: it names the
    /// style the moment the request is made, so the card says what it is doing
    /// while the service has not answered yet, and it disappears when the
    /// rewrite is no longer arriving. Nothing about the block moves: its height
    /// is a layout token, and the card's own height is computed from the words
    /// that were there before the request, so the arrival of a token cannot
    /// resize the surface under the reader.
    ///
    /// The original is not repeated above the draft. The words the person
    /// asked about are the words they just said, and drawing them again, cut to
    /// two dull lines, put a second copy of the transcript over the answer
    /// while it arrived.
    @ViewBuilder
    func rewriteBody(_ card: RewriteCard) -> some View {
        let motion = RewriteVersionMotion.insertionOffset(
            direction: card.lastNavigation,
            reduceMotion: reduceMotion
        )
        let transition: AnyTransition = reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .offset(x: motion, y: 0).combined(with: .opacity),
                removal: .opacity
            )
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.vertical) {
                        draftBody(card)
                            .font(HUDTheme.transcriptFont)
                            .lineSpacing(HUDTheme.transcriptLineSpacing)
                            .hudInk(.primary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, HUDTheme.padding)
                            .padding(.vertical, HUDTheme.verticalPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // A body that has no words yet is drawn at nothing, so
                            // the first line of a rewrite does not sit on the
                            // surface as a stray mark before the stream fills it.
                            .opacity(card.visibleBodyText.isEmpty ? 0 : 1)
                            .animation(
                                reduceMotion ? nil : .easeOut(duration: 0.16),
                                value: card.visibleBodyText.isEmpty
                            )
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    .defaultScrollAnchor(.top)
                    .accessibilityLabel(Text(card.selectedVersion.accessibilityLabel))
                    .accessibilityValue(Text(versionPosition(card)))
                }
                .id(card.selectedVersionID)
                .transition(transition)
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: RewriteVersionMotion.duration),
                value: card.selectedVersionID
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Transcript versions"))
    }

    /// The body's words, with the arrivals that are still coming up to the ink.
    ///
    /// The ramp is built from the chunk table the stream recorded, so it costs
    /// nothing once the last chunk is older than
    /// ``RewriteDraftRamp/duration``: the body is one `Text` again, and no frame
    /// carries a run that would only say "full ink". Before the first token the
    /// draft is empty and this is the selected version's words, unchanged and at
    /// full ink: the click does not take away the text the person was reading.
    ///
    /// - Parameter card: the layer the card is drawing.
    /// - Returns: the words, or the words in pieces while they arrive.
    @ViewBuilder
    func draftBody(_ card: RewriteCard) -> some View {
        let text = card.visibleBodyText
        FrameRewriteDraftBody(
            model: model,
            source: frameSource,
            text: text,
            chunks: card.draftChunks,
            reduceMotion: reduceMotion,
            content: { text, runs in
                AnyView(runs.isEmpty ? Text(text) : HUDView.rampedText(text, runs: runs, usesSystemInk: usesSystemInk))
            }
        )
    }

    /// One paragraph, with each arriving run drawn at its own strength.
    ///
    /// The pieces are concatenated `Text`, not an attributed string rebuilt per
    /// frame: the font, the line spacing and the colour are the ones the body
    /// already sets, and only the alpha of the newest words differs.
    ///
    /// - Parameters:
    ///   - text: the whole draft.
    ///   - runs: the character ranges that are still arriving, in ascending order.
    ///   - usesSystemInk: whether the arriving words take the semantic primary ink.
    /// - Returns: the paragraph in pieces.
    static func rampedText(
        _ text: String,
        runs: [RewriteDraftRamp.Run],
        usesSystemInk: Bool
    ) -> Text {
        var composed = Text("")
        var cursor = text.startIndex
        for run in runs {
            let lower = text.index(text.startIndex, offsetBy: run.range.lowerBound)
            let upper = text.index(text.startIndex, offsetBy: run.range.upperBound)
            guard lower >= cursor else { continue }
            if lower > cursor {
                composed = composed + Text(String(text[cursor ..< lower]))
            }
            composed = composed + Text(String(text[lower ..< upper]))
                .foregroundStyle(usesSystemInk
                    ? AnyShapeStyle(.primary.opacity(run.opacity))
                    : AnyShapeStyle(HUDTheme.ink.opacity(run.opacity)))
            cursor = upper
        }
        if cursor < text.endIndex {
            composed = composed + Text(String(text[cursor...]))
        }
        return composed
    }

    /// The position VoiceOver reads for the selected version.
    func versionPosition(_ card: RewriteCard) -> String {
        let index = card.selectedIndex + 1
        return "Version \(index) of \(card.versions.count)"
    }

    /// Everything under the body: the note, the refusal and the version row.
    @ViewBuilder
    func rewriteSection(_ card: RewriteCard) -> some View {
        let blocked: String? = {
            if case .blocked(_, let error) = card.phase { return error }
            return nil
        }()
        VStack(alignment: .leading, spacing: 0) {
            if let note = card.note {
                Text(note)
                    .font(DotType.font(HUDRewriteLayout.noteFontSize, .regular))
                    .hudInk(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HUDTheme.padding)
                    .padding(.top, HUDRewriteLayout.noteGap)
            }

            if let blocked {
                Text(blocked)
                    .font(DotType.font(HUDRewriteLayout.noteFontSize, .medium))
                    .foregroundStyle(HUDTheme.warning)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HUDTheme.padding)
                    .padding(.top, HUDRewriteLayout.noteGap)

                HStack(spacing: HUDRewriteLayout.actionGap) {
                    RewriteCapsuleButton(title: "Use anyway", isPrimary: true) {
                        actions.applyRewriteAnyway?()
                    }
                    RewriteCapsuleButton(title: "Keep original", isPrimary: false) {
                        actions.keepOriginal?()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, HUDTheme.padding)
                .padding(.top, HUDRewriteLayout.rowGap)
            }

            if card.showsChips {
                chipRow(card)
                    .padding(.horizontal, HUDTheme.padding)
                    .padding(.top, blocked == nil && card.note == nil
                        ? HUDRewriteLayout.rowTopGap
                        : HUDRewriteLayout.rowGap)
            }
        }
        .padding(.bottom, HUDRewriteLayout.extraHeight(
            showsChips: card.showsChips,
            showsActions: blocked != nil,
            noteLines: noteLineCount(card)
        ) > 0 ? HUDState.verticalPadding : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The pinned original, the scrollable style chips and the arrows, in one
    /// row, left-aligned with the body text.
    func chipRow(_ card: RewriteCard) -> some View {
        FrameRewriteChipRow(
            model: model,
            source: frameSource,
            card: card,
            reduceMotion: reduceMotion,
            ending: model.rewriteEnding,
            actions: actions
        )
    }

    /// How many lines the section under the body draws.
    func noteLineCount(_ card: RewriteCard) -> Int {
        var lines = card.note == nil ? 0 : 1
        if case .blocked = card.phase { lines += 1 }
        return lines
    }
}

/// The arriving body of a rewrite, driven by the frame clock.
@MainActor
private struct FrameRewriteDraftBody: View {
    @ObservedObject var model: HUDModel
    let source: HUDFrameSource
    let text: String
    let chunks: [RewriteDraftChunk]
    let reduceMotion: Bool
    let content: (String, [RewriteDraftRamp.Run]) -> AnyView

    var body: some View {
        let runs = RewriteDraftRamp.runs(
            chunks: chunks,
            length: text.count,
            time: source.time,
            reduceMotion: reduceMotion
        )
        content(text, runs)
    }
}

/// The style row, driven by the frame clock for its arc and fade.
@MainActor
private struct FrameRewriteChipRow: View {
    @ObservedObject var model: HUDModel
    let source: HUDFrameSource
    let card: RewriteCard
    let reduceMotion: Bool
    let ending: RewriteEnding?
    let actions: HUDActions

    var body: some View {
        RewriteChipRow(
            choices: card.choices,
            activeStyleID: card.activeStyleID,
            isStreaming: card.isStreaming,
            reduceMotion: reduceMotion,
            time: source.time,
            endedStyleID: ending?.styleID,
            endedAt: ending?.at,
            versions: card.versions,
            selectedVersionID: card.selectedVersionID,
            onOriginal: { actions.selectOriginal?() },
            onSelect: { style in
                if card.isStreaming && card.activeStyleID == style.id {
                    actions.cancelRewrite?()
                } else {
                    actions.rewrite?(style)
                }
            },
            onPrevious: { actions.previousVersion?() },
            onNext: { actions.nextVersion?() },
            onRerun: card.selectedVersion.styleID != nil
                && !card.isStreaming
                && !card.isBlocked
                ? { actions.rerunRewrite?() }
                : nil
        )
    }
}

/// One style the card offers, or the pinned original.
///
/// The label is drawn in every state: the chip names the style whether it is
/// idle, has produced versions, or is the one arriving. Clicking the running chip
/// cancels the request, so the chip keeps that second meaning without losing its
/// name; the header's Stop button is the explicit action.
///
/// The chip that is arriving says so where the click happened: a conic arc
/// travels the capsule's own rim, and a soft glow follows its head inside the
/// capsule. Nothing is added around the chip, no fill changes, and the label is
/// the card's amber — so the work is legible in a still frame, in the place the
/// person is looking, without the solid fill that would compete with the white
/// selected pill. The pill stays on the version the card is showing until another
/// version arrives: a highlight that jumped to a style on the click would claim an
/// answer the service has not sent.
struct RewriteChip: View {
    let title: String
    /// The id of the style this chip offers, or `nil` for the pinned original.
    var styleID: String? = nil
    /// Whether this chip is the version the card is showing.
    let isSelected: Bool
    /// How many versions this style has produced. Zero means it has never run.
    var versionCount: Int = 0
    /// Whether this chip's style is the one arriving.
    let isRunning: Bool
    let reduceMotion: Bool
    /// The card's clock, in seconds.
    let time: Double
    /// When this chip's style stopped running, on the card's clock.
    var endedAt: Double? = nil
    let perform: () -> Void

    @State private var hovering = false

    /// The label's ink.
    ///
    /// A selected chip is dark type on the light fill. Every unselected chip is
    /// ``HUDTheme/ink2``, which holds a label above 4.5:1 on the card's dark
    /// surface in both the never-run and the versioned state; the version count
    /// separates those two for VoiceOver rather than the colour. The chip that is
    /// arriving is the card's amber at full strength: the arc carries the
    /// movement, so the label is the one steady thing that names the work, and a
    /// label that also pulsed would be two movements saying one thing.
    @Environment(\.hudUsesSystemInk) private var usesSystemInk

    private var titleStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.black.opacity(0.86)) }
        if isRunning { return AnyShapeStyle(HUDTheme.recording) }
        return usesSystemInk ? AnyShapeStyle(.secondary) : AnyShapeStyle(HUDTheme.ink2)
    }

    /// Whether this chip is the one the service is answering.
    ///
    /// A chip that is both selected and running keeps the pill's dark ink but
    /// still draws the arc: a re-run of the style the person is already reading
    /// is the case where the work has to be loudest, because nothing else on the
    /// card changes.
    private var showsProcessing: Bool {
        isRunning
    }

    /// The head's angle, clockwise from the top of the capsule.
    ///
    /// Reduced motion parks the arc on the top-right quarter and the clock is
    /// not read at all: the arc is a still picture rather than a still frame of a
    /// moving one.
    private var headAngle: Double {
        reduceMotion
            ? HUDRewriteActivity.reducedMotionHeadDegrees
            : HUDRewriteActivity.arcHeadAngle(time: time, reduceMotion: false)
    }

    /// The trail behind the head, in degrees.
    private var trail: Double {
        HUDRewriteActivity.arcTrail(reduceMotion: reduceMotion)
    }

    /// How strongly the arc and the glow are drawn.
    ///
    /// One for the run, then the 140 ms the card gives the work to leave in.
    private var fade: Double {
        HUDRewriteActivity.arcFade(
            isRunning: isRunning,
            endedAt: endedAt,
            time: time,
            reduceMotion: reduceMotion
        )
    }

    /// The capsule's fill.
    ///
    /// The white of a selected chip, and the card's own control fill for every
    /// other state — the running one included, exactly like its neighbours. A
    /// running chip that tinted its fill amber mirrored the white pill's solid
    /// fill, so in stills only hue separated "working" from "selected"; the
    /// processing state is carried by the arc, the glow and the label alone.
    private var fill: Color {
        if isSelected { return HUDTheme.ink }
        return hovering ? HUDTheme.actionFillHover : HUDTheme.actionFill
    }

    var body: some View {
        Button(action: perform) {
            Text(title)
                .font(DotType.font(HUDRewriteLayout.chipFontSize, .medium))
                .foregroundStyle(titleStyle)
                .padding(.horizontal, HUDRewriteLayout.chipHPadding)
                .frame(height: HUDRewriteLayout.chipHeight)
                .background(Capsule(style: .circular).fill(fill))
                .overlay {
                    if showsProcessing || fade > 0 {
                        RewriteArcRing(
                            shape: Capsule(style: .circular),
                            head: headAngle,
                            trail: trail,
                            fade: fade,
                            glowOpacity: isSelected
                                ? HUDRewriteActivity.glowOpacityOnPill
                                : HUDRewriteActivity.glowOpacity,
                            tint: isSelected ? HUDTheme.arcOnPill : HUDTheme.recording
                        )
                    }
                }
                .contentShape(Capsule(style: .circular))
                .animation(hoverAnimation, value: hovering)
        }
        .buttonStyle(DotPressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The hover fade, which follows the system's reduced-motion setting.
    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    private var accessibilityLabel: String {
        if isRunning {
            return "\(title), rewriting. Click to stop."
        }
        if isSelected {
            return "\(title), selected"
        }
        if versionCount == 1 {
            return "\(title), one version"
        }
        if versionCount > 1 {
            return "\(title), \(versionCount) versions"
        }
        return title
    }
}

/// The arc that says a rewrite is running, on a shape's own rim.
///
/// It is one shape stroked twice: a hairline track round the whole perimeter, and
/// the amber of the card falling from its head to nothing over
/// ``HUDRewriteActivity/arcTrail(reduceMotion:)`` degrees. The falloff is a conic
/// gradient rather than a trimmed path because a trimmed stroke ends in two cut
/// caps, and a cap on a capsule's rim is a tick that reads as a glitch.
///
/// The glow is a radial light centred on the point where the head meets the rim.
/// It is clipped to the shape, so nothing is drawn outside the capsule: a halo
/// outside a shape is the one kind of light this card does not draw. Both the
/// light and the arc fade together when the run ends.
///
/// The view draws no glyph and no fill of its own, so the same component is the
/// chip's moving arc and the header's 20 point ring.
struct RewriteArcRing<S: InsettableShape>: View {
    /// The shape whose rim the arc travels.
    let shape: S
    /// The head's angle, in degrees clockwise from the top.
    let head: Double
    /// How far the trail reaches behind the head, in degrees.
    let trail: Double
    /// How strongly the arc and the glow are drawn, from `0` to `1`.
    let fade: Double
    /// The opacity of the glow at its centre.
    var glowOpacity: Double = HUDRewriteActivity.glowOpacity
    /// Whether the glow is drawn.
    var showsGlow: Bool = true
    /// The colour of the arc and its glow.
    ///
    /// The card's amber is the running colour on its own surface. On the
    /// selected chip's cream pill the same amber is a light-on-light ring at
    /// about 1.5:1, so that chip draws the darker ``HUDTheme/arcOnPill``.
    var tint: Color = HUDTheme.recording

    /// The gradient's stops, from the model's own falloff.
    private var stops: [Gradient.Stop] {
        HUDRewriteActivity.arcStops(head: head, trail: trail).map { stop in
            Gradient.Stop(
                color: tint.opacity(stop.opacity),
                location: stop.location
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                shape
                    .inset(by: HUDRewriteActivity.trackLineWidth / 2)
                    .stroke(
                        Color.white.opacity(HUDRewriteActivity.trackOpacity),
                        lineWidth: HUDRewriteActivity.trackLineWidth
                    )

                shape
                    .inset(by: HUDRewriteActivity.arcLineWidth / 2)
                    .stroke(
                        AngularGradient(stops: stops, center: .center),
                        lineWidth: HUDRewriteActivity.arcLineWidth
                    )
                    .opacity(fade)

                if showsGlow, fade > 0 {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    tint.opacity(glowOpacity * fade),
                                    tint.opacity(0),
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: HUDRewriteActivity.glowRadius
                            )
                        )
                        .frame(
                            width: HUDRewriteActivity.glowRadius * 2,
                            height: HUDRewriteActivity.glowRadius * 2
                        )
                        .position(
                            HUDRewriteActivity.capsuleRimPoint(
                                angleDegrees: head,
                                size: geometry.size
                            )
                        )
                }
            }
            .clipShape(shape)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The badge that says the mechanical check ran.
///
/// It is a dot and one word. "Checked" is not a promise of fidelity: the check
/// looks for changed numbers, dropped negations, added links, missing capitals
/// and a length outside the style's band, and it can miss a changed meaning
/// that keeps the same facts. A warning is shown as "Review", the tooltip
/// carries the first warning, and the person always keeps the choice.
struct RewriteCheckBadge: View {
    let warning: String?

    @Environment(\.hudUsesSystemInk) private var usesSystemInk

    private var isQuiet: Bool { warning == nil }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .hudInk(.secondary, when: isQuiet, otherwise: HUDTheme.warning)
                .frame(
                    width: HUDRewriteLayout.badgeDotSize,
                    height: HUDRewriteLayout.badgeDotSize
                )
            Text(isQuiet ? "Checked" : "Review")
                .font(DotType.font(HUDRewriteLayout.chipFontSize, .medium))
                .hudInk(.secondary, when: isQuiet, otherwise: HUDTheme.warning)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: HUDRewriteLayout.badgeHeight)
        .background(Capsule(style: .circular).fill(HUDTheme.actionFill))
        .help(warning ?? "Checked for changed numbers, dropped negations and added links.")
        .accessibilityLabel(Text(isQuiet ? "Checked" : "Review: \(warning ?? "")"))
        .accessibilityHint(Text(
            "The check looks for changed numbers, dropped negations and added links. It cannot prove the meaning is unchanged."
        ))
    }
}

/// A titled capsule: the two answers to a refused rewrite.
///
/// It is also the shape the legacy Undo control used, but no current paste
/// sets `canUndo`, so the card does not draw one.
struct RewriteCapsuleButton: View {
    let title: String
    let isPrimary: Bool
    let perform: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hudUsesSystemInk) private var usesSystemInk
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            Text(title)
                .font(DotType.font(HUDRewriteLayout.chipFontSize, .medium))
                .hudInk(.primary, when: !isPrimary, otherwise: Color.black.opacity(0.86))
                .lineLimit(1)
                .padding(.horizontal, HUDRewriteLayout.actionHPadding)
                .frame(height: HUDRewriteLayout.actionHeight)
                .background(
                    Capsule(style: .circular)
                        .fill(isPrimary
                            ? HUDTheme.ink
                            : (hovering ? HUDTheme.actionFillHover : HUDTheme.actionFill))
                )
                .overlay {
                    if !isPrimary {
                        Capsule(style: .circular)
                            .strokeBorder(HUDTheme.actionBorder, lineWidth: 0.75)
                    }
                }
                .contentShape(Capsule(style: .circular))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
        }
        .buttonStyle(DotPressStyle())
        .onHover { hovering = $0 }
    }
}

/// A version arrow's request to bring the style it selected into view.
///
/// Only the arrows ask for this. A chip click and a completed version also
/// change `selectedVersionID`, and neither may move the rail: the wheel's
/// position belongs to the person reading the row, and a completion that
/// recentred it would take that position away mid-gesture.
struct RewriteChipReveal {
    private(set) var targetVersionID: Int?

    /// Asks the row to reveal the style of a version the arrow is selecting.
    mutating func request(versionID: Int?) {
        targetVersionID = versionID
    }

    /// Consumes the request once the selection has arrived.
    ///
    /// - Parameter selectedVersionID: the version the card now shows.
    /// - Returns: whether the selection is the one the arrow asked for.
    mutating func consume(selectedVersionID: Int) -> Bool {
        guard let target = targetVersionID else { return false }
        targetVersionID = nil
        return target == selectedVersionID
    }

    mutating func clear() {
        targetVersionID = nil
    }
}

/// The version row: a pinned Original, the scrollable style chips and the two
/// navigation arrows, all in the 24 points the card budgets.
///
/// Six built-in styles and the person's own can be wider than the card. The
/// style chips keep the row's height and scroll sideways instead of clipping
/// the last option, with the styles dissolving into the card over their last
/// points and a mark in its own slot past the clip to say so. The mark is a
/// sibling of the scroll view, not a layer over it: the styles end where its
/// slot begins, so it can never be drawn on a label, and it is an arrow rather
/// than the chevron of the next-version button, so the two never read as two of
/// the same control. The arrows and the original stay outside the scroll, so
/// the original is always one click away and the previous/next controls never
/// scroll off.
/// Every chip stays an accessible button; the row itself can take focus and
/// scroll with the arrow keys, and VoiceOver gets the same two actions by name.
/// The HUD panel never becomes key, so in the island the chips are a pointer and
/// an accessibility destination; where the row is hosted in a key window the
/// arrow keys reach every style.
struct RewriteChipRow: View {
    let choices: [RewriteStyle]
    let activeStyleID: String?
    let isStreaming: Bool
    let reduceMotion: Bool
    /// The card's clock, in seconds, shared by every chip's processing state.
    let time: Double
    /// The style whose run has just stopped, when one has.
    ///
    /// Only that chip draws the arc's fade-out: a completion moves the pill to a
    /// new version and a cancel moves it back to the original, and either way the
    /// work that is leaving belongs to the chip that was clicked.
    var endedStyleID: String?
    /// When that run stopped, on the card's clock.
    var endedAt: Double?
    let versions: [RewriteVersion]
    let selectedVersionID: Int
    let onOriginal: () -> Void
    let onSelect: (RewriteStyle) -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onRerun: (() -> Void)?
    /// Whether the row dissolves its trailing edge when the styles outgrow it.
    ///
    /// The fade is what keeps a cut label from ending on a hard edge. A test
    /// that proves the faded strip really held ink draws the same row twice,
    /// once with this off, so the control is the same chips at the same scroll
    /// position rather than a second copy of the layout. Nothing in the app
    /// turns it off.
    var drawsOverflowFade = true

    @State private var viewportWidth: CGFloat = 0
    @State private var focus = RewriteChipFocus()
    @State private var reveal = RewriteChipReveal()

    init(
        choices: [RewriteStyle],
        activeStyleID: String?,
        isStreaming: Bool,
        reduceMotion: Bool,
        time: Double = 0,
        endedStyleID: String? = nil,
        endedAt: Double? = nil,
        versions: [RewriteVersion] = [],
        selectedVersionID: Int = 0,
        drawsOverflowFade: Bool = true,
        onOriginal: @escaping () -> Void = {},
        onSelect: @escaping (RewriteStyle) -> Void,
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {},
        onRerun: (() -> Void)? = nil
    ) {
        self.choices = choices
        self.activeStyleID = activeStyleID
        self.isStreaming = isStreaming
        self.reduceMotion = reduceMotion
        self.time = time
        self.endedStyleID = endedStyleID
        self.endedAt = endedAt
        self.versions = versions
        self.selectedVersionID = selectedVersionID
        self.drawsOverflowFade = drawsOverflowFade
        self.onOriginal = onOriginal
        self.onSelect = onSelect
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onRerun = onRerun
    }

    /// The width every style chip plus the trailing room needs, in points.
    static func contentWidth(for choices: [RewriteStyle]) -> CGFloat {
        RewriteChipMetrics.rowWidth(choices.map(\.title)) + HUDRewriteLayout.chipOverflowWidth
    }

    /// Whether the style chips have more than the card can show at once.
    ///
    /// - Parameters:
    ///   - contentWidth: what ``contentWidth(for:)`` measured.
    ///   - viewportWidth: the width the styles are clipped to. While the
    ///     chevron's slot is drawn this is the narrower viewport, and the
    ///     question only becomes more true of it, so the row cannot oscillate
    ///     between showing the chevron and hiding it.
    static func overflows(contentWidth: CGFloat, viewportWidth: CGFloat) -> Bool {
        guard viewportWidth > 0 else { return false }
        return contentWidth - HUDRewriteLayout.chipOverflowWidth > viewportWidth + 0.5
    }

    /// The width the pinned controls take from the row.
    static func pinnedWidth(showsRerun: Bool) -> CGFloat {
        let arrows = HUDRewriteLayout.versionArrowWidth * 2
        let original = RewriteChipMetrics.chipWidth("Original")
        let rerun = showsRerun ? HUDRewriteLayout.versionArrowWidth : 0
        let gaps = HUDRewriteLayout.chipGap * CGFloat(3 + (showsRerun ? 1 : 0))
        return arrows + original + rerun + gaps
    }

    /// Where the styles are clipped and where the overflow chevron is drawn.
    ///
    /// The row is an `HStack` of fixed parts and one flexible one, so these
    /// numbers are arithmetic the view cannot report and a test can. The styles
    /// are the only part that gives up width: the pinned controls keep theirs,
    /// and the chevron's slot comes out of the styles.
    ///
    /// - Parameters:
    ///   - rowWidth: the width the card gives the whole row.
    ///   - showsRerun: whether the rerun button is in the row.
    ///   - overflows: whether the styles have more than the row can show.
    /// - Returns: the viewport the styles are clipped to and the slot the
    ///   chevron is drawn in, the slot empty when every style fits.
    static func slots(rowWidth: CGFloat, showsRerun: Bool, overflows: Bool) -> RewriteChipRowSlots {
        let leading = HUDRewriteLayout.versionArrowWidth
            + HUDRewriteLayout.chipGap * 2
            + RewriteChipMetrics.chipWidth("Original")
        let trailing = HUDRewriteLayout.chipGap
            + HUDRewriteLayout.versionArrowWidth
            + (showsRerun ? HUDRewriteLayout.chipGap + HUDRewriteLayout.versionArrowWidth : 0)
        let slot = overflows
            ? HUDRewriteLayout.chipGap + HUDRewriteLayout.chipOverflowSlotWidth
            : 0
        return RewriteChipRowSlots(
            viewportOrigin: leading,
            viewportWidth: max(0, rowWidth - leading - trailing - slot),
            overflowWidth: overflows ? HUDRewriteLayout.chipOverflowSlotWidth : 0
        )
    }

    /// The width of the mark in the overflow slot, in points.
    ///
    /// It is a frame, not the symbol's ink: the mark is centred in it, so the
    /// clearance the row can promise is measured from this box.
    static let overflowMarkWidth: CGFloat = 10
    /// The least clearance the overflow mark keeps on each side, in points.
    static let minimumOverflowClearance: CGFloat = 8
    /// The space between the overflow mark and its neighbours, in points.
    ///
    /// The mark is centred in its slot, so the row's gap plus half of what the
    /// slot leaves around the mark is what separates the mark's frame from the
    /// clip before it and from the next-version button after it. The card asks
    /// for at least ``minimumOverflowClearance`` on both sides.
    static var overflowClearance: CGFloat {
        HUDRewriteLayout.chipGap + (HUDRewriteLayout.chipOverflowSlotWidth - overflowMarkWidth) / 2
    }

    private var selectedVersion: RewriteVersion? {
        versions.first { $0.id == selectedVersionID }
    }

    private var canGoPrevious: Bool {
        guard let index = versions.firstIndex(where: { $0.id == selectedVersionID }) else {
            return false
        }
        return index > 0
    }

    private var canGoNext: Bool {
        guard let index = versions.firstIndex(where: { $0.id == selectedVersionID }) else {
            return false
        }
        return index < versions.count - 1
    }

    private var previousVersionID: Int? {
        guard let index = versions.firstIndex(where: { $0.id == selectedVersionID }),
              index > 0
        else { return nil }
        return versions[index - 1].id
    }

    private var nextVersionID: Int? {
        guard let index = versions.firstIndex(where: { $0.id == selectedVersionID }),
              index < versions.count - 1
        else { return nil }
        return versions[index + 1].id
    }

    /// Asks for the previous version and remembers that the arrow, not a chip
    /// click or a completion, moved the selection.
    private func requestPrevious() {
        reveal.request(versionID: previousVersionID)
        onPrevious()
    }

    /// Asks for the next version and remembers the arrow's intent.
    private func requestNext() {
        reveal.request(versionID: nextVersionID)
        onNext()
    }

    private var overflows: Bool {
        Self.overflows(
            contentWidth: Self.contentWidth(for: choices),
            viewportWidth: viewportWidth
        )
    }

    var body: some View {
        HStack(spacing: HUDRewriteLayout.chipGap) {
            RewriteArrowButton(
                symbol: "chevron.left",
                label: "Previous version",
                isEnabled: canGoPrevious,
                reduceMotion: reduceMotion,
                perform: requestPrevious
            )

            RewriteChip(
                title: "Original",
                isSelected: selectedVersion?.isOriginal ?? true,
                versionCount: 1,
                isRunning: false,
                reduceMotion: reduceMotion,
                time: time
            ) {
                reveal.clear()
                onOriginal()
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: HUDRewriteLayout.chipGap) {
                        ForEach(choices) { style in
                            RewriteChip(
                                title: style.title,
                                styleID: style.id,
                                isSelected: selectedVersion?.styleID == style.id,
                                versionCount: versions.filter { $0.styleID == style.id }.count,
                                isRunning: isStreaming && activeStyleID == style.id,
                                reduceMotion: reduceMotion,
                                time: time,
                                endedAt: endedStyleID == style.id ? endedAt : nil
                            ) {
                                reveal.clear()
                                onSelect(style)
                            }
                            .id(style.id)
                        }
                    }
                    // Room for the last chip to scroll clear of the fade.
                    .padding(.trailing, HUDRewriteLayout.chipOverflowWidth)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ChipViewportWidthKey.self,
                            value: geometry.size.width
                        )
                    }
                )
                .onPreferenceChange(ChipViewportWidthKey.self) { viewportWidth = $0 }
                .mask {
                    ChipViewportMask(fadesTrailingEdge: overflows && drawsOverflowFade)
                }
                .frame(height: HUDRewriteLayout.chipHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusable()
                .onMoveCommand { direction in scroll(direction, proxy: proxy) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Transcript versions"))
                .accessibilityHint(Text("Scroll sideways to reach every style."))
                .accessibilityAction(named: Text("Scroll left")) {
                    scroll(.left, proxy: proxy)
                }
                .accessibilityAction(named: Text("Scroll right")) {
                    scroll(.right, proxy: proxy)
                }
                .accessibilityAction(named: Text("Previous version")) {
                    if canGoPrevious { requestPrevious() }
                }
                .accessibilityAction(named: Text("Next version")) {
                    if canGoNext { requestNext() }
                }
                .onAppear {
                    focus.update(ids: choices.map(\.id))
                    guard let styleID = selectedVersion?.styleID else { return }
                    // The selected version may be far down a long row. Opening
                    // the card on a scroll position that hides it would make the
                    // review start on the wrong version.
                    DispatchQueue.main.async {
                        proxy.scrollTo(styleID, anchor: .center)
                    }
                }
                .onChange(of: choices.map(\.id)) { _, ids in focus.update(ids: ids) }
                .onChange(of: selectedVersionID) { _, newValue in
                    // Only an arrow asks for a reveal. A chip click and a
                    // completed version also move the selection, and the rail
                    // must stay where the wheel put it for both.
                    guard reveal.consume(selectedVersionID: newValue),
                          let styleID = selectedVersion?.styleID
                    else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        proxy.scrollTo(styleID, anchor: .center)
                    }
                }
            }

            // The mark's own slot, after the clip. It is a sibling of the
            // scrolling styles rather than a layer over them, so the last chip
            // is cut at the clip and the mark is drawn on the card's surface.
            if overflows {
                ChipOverflowMark()
            }

            RewriteArrowButton(
                symbol: "chevron.right",
                label: "Next version",
                isEnabled: canGoNext,
                reduceMotion: reduceMotion,
                perform: requestNext
            )

            if let onRerun, let styleID = selectedVersion?.styleID,
               !isStreaming,
               let style = choices.first(where: { $0.id == styleID }) {
                RewriteRerunButton(
                    title: style.title,
                    reduceMotion: reduceMotion,
                    perform: onRerun
                )
            }
        }
        .frame(height: HUDRewriteLayout.chipHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Moves the row's focus by one chip and brings it into view.
    private func scroll(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        guard let target = focus.move(direction) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            proxy.scrollTo(target, anchor: .center)
        }
    }
}

/// The horizontal slots the style viewport and the overflow chevron take.
///
/// It is a value so the row's geometry can be checked without a display: the
/// chips are clipped where ``viewportWidth`` ends, and the chevron is drawn
/// from ``overflowOrigin``, after the row's gap. The two never overlap.
struct RewriteChipRowSlots: Equatable {
    /// The x the style viewport starts at, from the row's leading edge.
    let viewportOrigin: CGFloat
    /// The width the styles are clipped to.
    let viewportWidth: CGFloat
    /// The width of the chevron's slot, or zero when every style fits.
    let overflowWidth: CGFloat

    /// The x the style viewport ends at, from the row's leading edge.
    var viewportMaxX: CGFloat { viewportOrigin + viewportWidth }

    /// The x the chevron's slot starts at, from the row's leading edge.
    var overflowOrigin: CGFloat {
        viewportMaxX + (overflowWidth > 0 ? HUDRewriteLayout.chipGap : 0)
    }

    /// The x the chevron's slot ends at, from the row's leading edge.
    var overflowMaxX: CGFloat { overflowOrigin + overflowWidth }
}

/// A small chevron that moves through the versions, disabled at the ends.
struct RewriteArrowButton: View {
    let symbol: String
    let label: String
    let isEnabled: Bool
    let reduceMotion: Bool
    let perform: () -> Void

    @Environment(\.hudUsesSystemInk) private var usesSystemInk
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(DotType.font(9.5, .semibold))
                .hudInk(isEnabled ? .secondary : .tertiary, opacity: isEnabled ? 1 : 0.55)
                .frame(
                    width: HUDRewriteLayout.versionArrowWidth,
                    height: HUDRewriteLayout.chipHeight
                )
                .background(
                    Capsule(style: .circular)
                        .fill(hovering && isEnabled ? HUDTheme.actionFillHover : HUDTheme.actionFill)
                )
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
        }
        .buttonStyle(DotPressStyle())
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text(isEnabled ? "" : "No version in that direction."))
    }
}

/// The one-click rerun of the selected style, appended as another version.
struct RewriteRerunButton: View {
    let title: String
    let reduceMotion: Bool
    let perform: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            Image(systemName: "arrow.clockwise")
                .font(DotType.font(9.5, .semibold))
                .hudInk(.secondary)
                .frame(
                    width: HUDRewriteLayout.versionArrowWidth,
                    height: HUDRewriteLayout.chipHeight
                )
                .background(
                    Capsule(style: .circular)
                        .fill(hovering ? HUDTheme.actionFillHover : HUDTheme.actionFill)
                )
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
        }
        .buttonStyle(DotPressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(Text("Run \(title) again"))
        .accessibilityHint(Text("Adds another version without changing the one on screen."))
        .help("Run \(title) again")
    }
}

/// Where the arrow keys of a chip row point.
///
/// It is a value so the reach of the keyboard can be checked without a window:
/// the last chip is always reachable, and neither end moves past itself.
struct RewriteChipFocus: Equatable {
    private(set) var ids: [String] = []
    private(set) var index = 0

    /// The id the focus points at, when the row has one.
    var target: String? {
        ids.indices.contains(index) ? ids[index] : nil
    }

    /// Takes the row's ids, keeping the focus inside them.
    mutating func update(ids: [String]) {
        self.ids = ids
        index = min(index, max(ids.count - 1, 0))
    }

    /// Moves one chip, clamped at both ends.
    ///
    /// - Parameter direction: the arrow that was pressed.
    /// - Returns: the id to bring into view, or `nil` when there is nothing to
    ///   move to.
    @discardableResult
    mutating func move(_ direction: MoveCommandDirection) -> String? {
        switch direction {
        case .right:
            index = min(index + 1, max(ids.count - 1, 0))
        case .left:
            index = max(index - 1, 0)
        case .up, .down:
            return nil
        @unknown default:
            return nil
        }
        return target
    }
}

/// The width of a chip's label, measured with the font it is drawn in.
///
/// The row's overflow decision is made from the same measurement the layout
/// test uses, so "is there more than fits" is a number rather than a guess at
/// what SwiftUI did inside a scroll view.
enum RewriteChipMetrics {
    /// The width of one chip, padding included.
    static func chipWidth(_ title: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DotType.nsFont(HUDRewriteLayout.chipFontSize, .medium),
        ]
        return ceil((title as NSString).size(withAttributes: attributes).width)
            + HUDRewriteLayout.chipHPadding * 2
    }

    /// The width of a row of titles, gaps included.
    static func rowWidth(_ titles: [String]) -> CGFloat {
        let widths = titles.map(chipWidth)
        return widths.reduce(0, +)
            + CGFloat(max(0, widths.count - 1)) * HUDRewriteLayout.chipGap
    }
}

/// The mask that dissolves the styles into the card before the clip.
///
/// It is opaque for the whole viewport and falls to clear over the last
/// ``HUDRewriteLayout/chipOverflowWidth`` points. A label or a capsule the clip
/// cuts has already faded out by then, so the row ends on the card's surface
/// rather than on the hard edge of a half-drawn glyph. A fade painted *over*
/// the chips could only lay the card's colour on top of them; a mask takes the
/// content away and leaves the surface the row really sits on.
///
/// The mask only fades while the styles have more than the row can show. A row
/// that fits is drawn exactly as it was.
private struct ChipViewportMask: View {
    let fadesTrailingEdge: Bool

    /// The opacity ramp, as fractions of the fade's width.
    ///
    /// A straight line leaves a quarter of the ink on the last few points,
    /// which reads as a broken glyph rather than as a row that continues. This
    /// ramp is gone by the halfway point: at 26 points wide, the last 13 points
    /// of the viewport are fully clear, so a label the clip cuts leaves nothing
    /// beside the overflow mark, no fragment of a letter and no cut edge of a
    /// capsule. The first quarter still carries a soft edge, so no seam shows
    /// inside the chips that are whole.
    static let fadeStops: [Gradient.Stop] = [
        .init(color: .black, location: 0),
        .init(color: .black.opacity(0.25), location: 0.25),
        .init(color: .clear, location: 0.5),
        .init(color: .clear, location: 1),
    ]

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(.black)
            if fadesTrailingEdge {
                LinearGradient(
                    stops: Self.fadeStops,
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: HUDRewriteLayout.chipOverflowWidth)
            }
        }
    }
}

/// The mark that says the chip row continues, in its own slot.
///
/// The slot is a sibling of the scrolling styles, past the clip, so the mark is
/// drawn on the card's surface. It is an arrow, not the chevron of the
/// next-version button beside it: the row's other rightward mark is a control
/// with a capsule, and two chevrons a few points apart read as two of the same
/// thing. Its frame is the width ``RewriteChipRow/overflowMarkWidth`` promises,
/// centred in the slot, so it keeps ``RewriteChipRow/overflowClearance`` points
/// from the clip and from the button.
private struct ChipOverflowMark: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(DotType.font(8.5, .semibold))
            .hudInk(.tertiary)
            .frame(
                width: RewriteChipRow.overflowMarkWidth,
                height: RewriteChipRow.overflowMarkWidth
            )
            .frame(
                width: HUDRewriteLayout.chipOverflowSlotWidth,
                height: HUDRewriteLayout.chipHeight
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ChipViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
