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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
    }

    private var motion: Bool {
        animated && !reduceMotion
    }

    var body: some View {
        content
            .opacity(model.content)
            .scaleEffect(0.99 + 0.01 * model.content)
            .offset(y: (1 - model.content) * 6)
            .frame(width: model.cardSize.width, height: model.cardSize.height)
            .background(HUDSurface(material: model.material))
            .clipShape(shape)
            .overlay {
                if model.visualizer == .haloEdge, case .recording = model.mode {
                    HaloEdgeBorder(time: model.time, pulse: model.pulse, level: model.level)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let hovered = model.hoveredAction {
                    HUDActionTooltip(action: hovered, material: model.material)
                        .offset(x: tooltipOffsetX(for: hovered), y: -25)
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
                }
            }
            .compositingGroup()
            .shadow(
                color: showsShadow ? Color.black.opacity(0.55) : .clear,
                radius: showsShadow ? 22 : 0,
                x: 0,
                y: showsShadow ? 10 : 0
            )
            .opacity(model.presence)
            .scaleEffect(0.94 + 0.06 * model.presence)
            .offset(y: (1 - model.presence) * -10)
            .blur(radius: (1 - model.presence) * 7)
            .animation(animation(.shape), value: model.cardSize)
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
                    .foregroundStyle(HUDTheme.ink2)

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
                    bars: model.bars,
                    reveal: model.reveal
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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(delivery.color.opacity(0.14))
                        .frame(width: HUDTheme.badgeSize, height: HUDTheme.badgeSize)
                    Image(systemName: delivery.glyph)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(delivery.color)
                }

                // The application the words went into, when there is one. The
                // title is already cut to the room the header has, so a long
                // name can never push the clock or the buttons out of the card.
                Text(HUDHeader.title(delivery: delivery, destination: destination))
                    .font(HUDTheme.labelFont)
                    .tracking(HUDTheme.labelTracking)
                    .foregroundStyle(delivery.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: HUDHeader.maximumTitleWidth, alignment: .leading)
                    .accessibilityLabel(Text(
                        HUDHeader.accessibilityLabel(
                            delivery: delivery,
                            destination: destination
                        )
                    ))

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

                Text(elapsed)
                    .font(HUDTheme.clockFont)
                    .foregroundStyle(HUDTheme.ink2)
                    .fixedSize()

                controlsSection([.copy, .paste, .history, .settings, .close])
            }
            .padding(.horizontal, HUDTheme.padding)
            .frame(height: HUDTheme.headerHeight)

            Rectangle()
                .fill(HUDTheme.hairline)
                .frame(height: 1)

            transcriptBody(text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The transcript itself: a body that grows with the words, then scrolls,
    /// and becomes directly editable inline at the clicked character position.
    @ViewBuilder
    private func transcriptBody(_ text: String) -> some View {
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
        .frame(height: transcriptBodyHeight)
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

    // MARK: - Message

    private func message(text: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
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
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(
            ofSize: 11.5, weight: .medium
        )]
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
    private func ready(shortcut: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeService.isEmpty ? "READY" : model.activeService.uppercased())
                    .font(HUDTheme.labelFont)
                    .tracking(HUDTheme.labelTracking)
                    .foregroundStyle(HUDTheme.accent)
                    .lineLimit(1)

                if !model.activeKeyHint.isEmpty {
                    Text(model.activeKeyHint)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
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
    private func controlsSection(_ items: [HUDAction]) -> some View {
        let available = HUDAction.available(items, in: actions)
        if !available.isEmpty {
            divider
            controls(available)
        }
    }

    private func controls(_ items: [HUDAction]) -> some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { action in
                HUDActionButton(
                    action: action,
                    isHovered: model.hoveredAction == action,
                    onHoverChange: { inside in
                        if inside {
                            model.hoveredAction = action
                        } else if model.hoveredAction == action {
                            model.hoveredAction = nil
                        }
                    }
                ) {
                    perform(action)
                }
            }
        }
    }

    private func activeControlItems() -> [HUDAction] {
        switch model.mode {
        case .recording:
            return HUDAction.available([.stop, .cancel], in: actions)
        case .working:
            return HUDAction.available([.cancel], in: actions)
        case .transcript:
            return HUDAction.available([.copy, .paste, .history, .settings, .close], in: actions)
        case .message:
            return HUDAction.available([.close], in: actions)
        case .ready:
            return HUDAction.available([.settings, .close], in: actions)
        }
    }

    private func tooltipOffsetX(for action: HUDAction) -> CGFloat {
        let items = activeControlItems()
        guard let idx = items.firstIndex(of: action) else { return -HUDTheme.padding }
        let trailingIndex = items.count - 1 - idx
        let step = HUDTheme.actionSize + 4
        return -(HUDTheme.padding + CGFloat(trailingIndex) * step * 0.65)
    }

    private func perform(_ action: HUDAction) {
        switch action {
        case .stop: actions.stop?()
        case .cancel: actions.cancel?()
        case .copy: actions.copy?()
        case .paste: actions.paste?()
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
        Text(wasLong ? "\(title) · long" : title)
            .font(HUDTheme.labelFont)
            .tracking(1.0)
            .foregroundStyle(HUDTheme.ink2)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                Capsule(style: .continuous)
                    .fill(HUDTheme.actionFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(HUDTheme.actionBorder, lineWidth: 1)
            )
            .accessibilityLabel(
                Text(wasLong ? "Rewritten for \(title), and longer than usual" : "Rewritten for \(title)")
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
    /// History window exists.
    static func available(_ items: [HUDAction], in actions: HUDActions) -> [HUDAction] {
        items.filter { $0.isAvailable(in: actions) }
    }

    /// Whether the app handed the card a closure for this action.
    func isAvailable(in actions: HUDActions) -> Bool {
        switch self {
        case .stop: actions.stop != nil
        case .cancel: actions.cancel != nil
        case .copy: actions.copy != nil
        case .paste: actions.paste != nil
        case .history: actions.history != nil
        case .settings: actions.settings != nil
        case .close: actions.close != nil
        }
    }

    /// The SF Symbol of the action.
    var symbol: String {
        switch self {
        case .stop: "stop.fill"
        case .cancel, .close: "xmark"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    /// The accessible name of the button.
    var label: String {
        switch self {
        case .stop: "Stop recording"
        case .cancel: "Cancel recording"
        case .copy: "Copy transcript"
        case .paste: "Paste again"
        case .history: "History"
        case .settings: "Settings"
        case .close: "Close"
        }
    }

    /// The tooltip of the button.
    var help: String {
        switch self {
        case .stop: "Stop and transcribe"
        case .cancel: "Cancel without transcribing"
        case .copy: "Copy transcript"
        case .paste: "Paste the transcript again"
        case .history: "Open history"
        case .settings: "Open settings"
        case .close: "Dismiss"
        }
    }

    /// The colour the icon takes under the pointer.
    var hoverColor: Color {
        switch self {
        case .stop: HUDTheme.live
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
                    Capsule(style: .continuous)
                        .fill(hovering ? HUDTheme.actionFillHover : HUDTheme.actionFill)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            hovering ? HUDTheme.actionBorderHover : HUDTheme.actionBorder,
                            lineWidth: 0.75
                        )
                )
                .contentShape(Capsule(style: .continuous))
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
private struct HUDActionButton: View {
    let action: HUDAction
    var isHovered: Bool = false
    var onHoverChange: ((Bool) -> Void)? = nil
    let perform: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var activeHover: Bool {
        hovering || isHovered
    }

    var body: some View {
        Button(action: perform) {
            Image(systemName: action.symbol)
                .font(HUDTheme.actionFont)
                .foregroundStyle(activeHover ? action.hoverColor : HUDTheme.ink3)
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
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.14),
                    value: activeHover
                )
        }
        .buttonStyle(HUDActionButtonStyle(reduceMotion: reduceMotion))
        .onHover { inside in
            hovering = inside
            onHoverChange?(inside)
        }
        .accessibilityLabel(Text(action.label))
        .accessibilityHint(Text(action.help))
    }
}

/// A themed floating tooltip pill that sits cleanly above the HUD island's top edge
/// when hovering over an action button, never overlapping the transcript text.
private struct HUDActionTooltip: View {    let action: HUDAction
    var material: HUDMaterial = .glass

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: action.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(action.hoverColor)
            Text(action.help)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HUDTheme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
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
            Capsule(style: .continuous)
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

/// The press state: a small scale, never a second surface.
private struct HUDActionButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
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
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular)
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
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
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

        DispatchQueue.main.async {
            Self.scrollToBottomIfNeeded(scrollView: scrollView, textView: textView)
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
            } else {
                Self.scrollToBottomIfNeeded(scrollView: scrollView, textView: textView)
            }
            context.coordinator.isUpdatingProgrammatically = false
        }
        if !isEditing, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
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

        init(_ parent: HUDInlineTranscriptView) {
            self.parent = parent
        }

        func applyAttributedText(_ string: String, to textView: NSTextView) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = HUDTheme.transcriptLineSpacing
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
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
