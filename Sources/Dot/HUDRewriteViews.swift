import DotCore
import SwiftUI

/// The rewrite layer of the transcript card.
///
/// It is one section under the body: a note when the rewrite went somewhere
/// else, the two capsules when the check refused it, and the chip row the
/// person picks a style with. Nothing here takes the keyboard: the panel can
/// never become key, so a chip is a click and only a click.
extension HUDView {
    /// The body of a rewritten card: the original faded to two lines while the
    /// rewrite streams, then the rewrite alone.
    @ViewBuilder
    func rewriteBody(_ card: RewriteCard) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: HUDRewriteLayout.dimmedGap) {
                if card.dimsOriginal {
                    Text(card.original)
                        .font(.system(size: HUDRewriteLayout.dimmedFontSize))
                        .foregroundStyle(HUDTheme.ink3)
                        .lineLimit(HUDRewriteLayout.dimmedOriginalLines)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(card.rewrite)
                    .font(HUDTheme.transcriptFont)
                    .lineSpacing(HUDTheme.transcriptLineSpacing)
                    .foregroundStyle(HUDTheme.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, HUDTheme.padding)
            .padding(.vertical, HUDTheme.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.top)
        .accessibilityLabel(Text("Rewrite"))
    }

    /// Everything under the body: the note, the refusal and the chips.
    @ViewBuilder
    func rewriteSection(_ card: RewriteCard) -> some View {
        let blocked: String? = {
            if case .blocked(_, let error) = card.phase { return error }
            return nil
        }()
        VStack(alignment: .leading, spacing: 0) {
            if let note = card.note {
                Text(note)
                    .font(.system(size: HUDRewriteLayout.noteFontSize))
                    .foregroundStyle(HUDTheme.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HUDTheme.padding)
                    .padding(.top, HUDRewriteLayout.noteGap)
            }

            if let blocked {
                Text(blocked)
                    .font(.system(size: HUDRewriteLayout.noteFontSize, weight: .medium))
                    .foregroundStyle(HUDTheme.live)
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

    /// The chips, in one row, left-aligned with the body text.
    func chipRow(_ card: RewriteCard) -> some View {
        HStack(spacing: HUDRewriteLayout.chipGap) {
            ForEach(card.choices) { style in
                RewriteChip(
                    title: style.title,
                    isActive: card.isStreaming && card.activeStyleID == style.id,
                    time: model.time,
                    reduceMotion: reduceMotion
                ) {
                    if card.isStreaming && card.activeStyleID == style.id {
                        actions.cancelRewrite?()
                    } else {
                        actions.rewrite?(style)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How many lines the section under the body draws.
    func noteLineCount(_ card: RewriteCard) -> Int {
        var lines = card.note == nil ? 0 : 1
        if case .blocked = card.phase { lines += 1 }
        return lines
    }
}

/// One style the card offers.
///
/// The active chip keeps its label's width and shows three dots instead: a
/// chip that changed width mid-stream would move every chip after it, and the
/// card would twitch once per rewrite.
struct RewriteChip: View {
    let title: String
    let isActive: Bool
    let time: Double
    let reduceMotion: Bool
    let perform: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            ZStack {
                Text(title)
                    .font(.system(size: HUDRewriteLayout.chipFontSize, weight: .medium))
                    .opacity(isActive ? 0 : 1)
                if isActive {
                    RewriteChipDots(time: time, reduceMotion: reduceMotion)
                }
            }
            .foregroundStyle(HUDTheme.ink2)
            .padding(.horizontal, HUDRewriteLayout.chipHPadding)
            .frame(height: HUDRewriteLayout.chipHeight)
            .background(
                Capsule(style: .circular)
                    .fill(hovering ? HUDTheme.actionFillHover : HUDTheme.actionFill)
            )
            .contentShape(Capsule(style: .circular))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(isActive ? "\(title), rewriting. Click to stop." : title))
    }
}

/// The three dots of a chip that is running.
struct RewriteChipDots: View {
    let time: Double
    let reduceMotion: Bool

    static let diameter: CGFloat = 3
    static let gap: CGFloat = 2
    static let cycle: Double = 1.2

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(HUDTheme.ink2)
                    .frame(width: Self.diameter, height: Self.diameter)
                    .opacity(alpha(index))
            }
        }
        .accessibilityHidden(true)
    }

    private func alpha(_ index: Int) -> Double {
        guard !reduceMotion else { return 0.6 }
        let phase = (time / Self.cycle + Double(index) * 0.18)
            .truncatingRemainder(dividingBy: 1)
        let wave = max(0, 1 - abs(phase - 0.5) * 2)
        return 0.25 + 0.75 * wave
    }
}

/// The badge that says whether the facts survived.
///
/// It is a dot and one word. A card that only said "Rewritten" would not tell
/// the person whether to read the rewrite or trust it; the tooltip carries the
/// first warning, and the check itself never blocks a warning-only rewrite.
struct RewriteFaithfulBadge: View {
    let warning: String?

    private var isFaithful: Bool { warning == nil }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isFaithful ? HUDTheme.faithful : HUDTheme.live)
                .frame(
                    width: HUDRewriteLayout.badgeDotSize,
                    height: HUDRewriteLayout.badgeDotSize
                )
            Text(isFaithful ? "Faithful" : "Check")
                .font(.system(size: HUDRewriteLayout.chipFontSize, weight: .medium))
                .foregroundStyle(isFaithful ? HUDTheme.ink2 : HUDTheme.live)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: HUDRewriteLayout.badgeHeight)
        .background(Capsule(style: .circular).fill(HUDTheme.actionFill))
        .help(warning ?? "")
        .accessibilityLabel(Text(isFaithful ? "Faithful" : "Check: \(warning ?? "")"))
    }
}

/// A titled capsule: Undo, and the two answers to a refused rewrite.
struct RewriteCapsuleButton: View {
    let title: String
    let isPrimary: Bool
    let perform: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            Text(title)
                .font(.system(size: HUDRewriteLayout.chipFontSize, weight: .medium))
                .foregroundStyle(isPrimary ? Color.black.opacity(0.86) : HUDTheme.ink)
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
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
