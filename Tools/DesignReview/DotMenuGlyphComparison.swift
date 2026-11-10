import AppKit
import SwiftUI

// The menu bar sheet for the Clipped mark.
//
// The icon's cut is 7.5% of the plate, which is 1.35 px at eighteen points. A
// sheet that showed the glyph alone at 8x would answer "is the shape right" and
// not "is the weight right", and weight is the only thing a template has. So
// each candidate is drawn at its real size between the system's own menu bar
// items, on a light bar and on a dark one, at 1x and at 2x, and the pixel
// evidence follows underneath.
//
// The neighbours are the system's symbols - the same artwork the menu bar draws
// - because this session cannot capture the live bar: Screen Recording is not
// granted to the process that runs the renderer, and a capture is not worth
// asking for when the symbols are the same file the bar loads.

/// The menu bar glyph comparison: candidates at their real size, in the bar.
struct DotMenuGlyphComparison: View {
    /// The candidate at 18 points, keyed by kind.
    let glyphs: [DotMenuGlyph.Kind: NSImage]
    /// The same candidate at 36 points.
    let doubles: [DotMenuGlyph.Kind: NSImage]
    /// The ink's bounding box in the eighteen point render, in points.
    let extents: [DotMenuGlyph.Kind: CGSize]

    static let size = CGSize(width: 1720, height: 880)

    /// The glyphs the bars draw, left to right: the three reductions, then the
    /// mark that shipped before them.
    static let candidates: [DotMenuGlyph.Kind] = DotMenuGlyph.Kind.clipped + [.disc]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            bar(dark: false, scale: 1)
            bar(dark: true, scale: 2)
            order
            cards
            verdict
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 56)
        .padding(.top, 44)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(SheetInk.ground)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 10) {
                Text("DOT · MENU BAR")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(3.4)
                    .foregroundStyle(SheetInk.accent)
                Text("The cut at eighteen points")
                    .font(.system(size: 32, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(SheetInk.ink)
                Text("A template keeps alpha and throws colour away, so the glyph is only a silhouette and a weight. The icon's cut is 7.5% of the plate — 1.35 px at 18, 2.7 px at 36 — and the question is whether that is enough of a cut to read, or whether the dot has to be pushed further out for the flats to survive the render. Each candidate is drawn at its real size between the system's own menu bar items, on a light bar and on a dark one, then at 1x and at 2x.")
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(SheetInk.ink2)
                    .frame(width: 980, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text("Template: black ink, alpha only")
                Text("Bars at 1x and 2x, real size")
                Text("Neighbours: the system's symbols")
                Text("Zooms: nearest neighbour, no resample")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(SheetInk.ink3)
            .frame(width: 330, alignment: .trailing)
        }
        .padding(.bottom, 28)
    }

    // MARK: Bars

    /// One menu bar, at 1x or at 2x.
    ///
    /// `scale` 1 draws the 18 point images in a 26 point bar; `scale` 2 draws
    /// the 36 point images in a 52 point bar. Nothing is scaled by the layout:
    /// a 2x bar is the same bar at twice the pixels, which is what makes the
    /// second strip evidence about a retina display and not about a bigger
    /// drawing.
    private func bar(dark: Bool, scale: CGFloat) -> some View {
        let ground = dark
            ? Color(.sRGB, red: 0.106, green: 0.106, blue: 0.114)
            : Color(.sRGB, red: 0.914, green: 0.914, blue: 0.918)
        let ink = dark
            ? Color(.sRGB, red: 0.929, green: 0.929, blue: 0.937)
            : Color(.sRGB, red: 0.114, green: 0.114, blue: 0.122)
        let item = 18 * scale

        return HStack(spacing: 0) {
            symbol("wifi", item: item, ink: ink)
            gap(scale)
            symbol("battery.100", item: item, ink: ink)
            gap(scale)
            symbol("switch.2", item: item, ink: ink)
            gap(scale)
            separator(ink: ink, scale: scale)
            ForEach(Self.candidates, id: \.rawValue) { kind in
                glyph(kind, size: item, scale: scale, ink: ink)
                gap(scale)
            }
            Text("9:41")
                .font(.system(size: 12.5 * scale, weight: .regular))
                .foregroundStyle(ink.opacity(0.92))
                .padding(.leading, 6 * scale)
            Spacer(minLength: 0)
        }
        .frame(height: 26 * scale)
        .padding(.horizontal, 16 * scale)
        .background(ground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.bottom, 10)
    }

    private func gap(_ scale: CGFloat) -> some View {
        Color.clear.frame(width: 16 * scale, height: 1)
    }

    private func separator(ink: Color, scale: CGFloat) -> some View {
        Rectangle()
            .fill(ink.opacity(0.18))
            .frame(width: max(1, scale), height: 14 * scale)
            .padding(.horizontal, 8 * scale)
    }

    private func symbol(_ name: String, item: CGFloat, ink: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: item * 0.86, weight: .regular))
            .foregroundStyle(ink)
            .frame(width: item, height: item)
    }

    private func glyph(
        _ kind: DotMenuGlyph.Kind,
        size: CGFloat,
        scale: CGFloat,
        ink: Color
    ) -> some View {
        Group {
            if let image = scale > 1 ? doubles[kind] : glyphs[kind] {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
                    .foregroundStyle(ink)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }

    /// Which glyph is which, because the bars carry no labels.
    /// The bars carry no labels, so the order is spelled out from the list
    /// the bars are drawn from.
    private var slotList: String {
        Self.candidates.enumerated()
            .map { String(format: "%02d %@", $0.offset + 1, $0.element.rawValue) }
            .joined(separator: " · ")
    }

    private var order: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Left to right: Wi-Fi, battery and control centre · \(slotList) · the clock.")
            Text("The bars are drawn at menu bar metrics. A capture of the live bar needs Screen Recording, which the renderer does not have, so the neighbours are the symbols the bar itself draws.")
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(SheetInk.ink3)
        .padding(.top, 6)
        .padding(.bottom, 24)
    }

    // MARK: Cards

    private var cards: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(Array(Self.candidates.enumerated()), id: \.element.rawValue) { index, kind in
                card(kind, number: index + 1)
            }
            Spacer(minLength: 0)
        }
    }

    private func card(_ kind: DotMenuGlyph.Kind, number: Int) -> some View {
        let shipped = kind == DotMenuGlyph.Kind.shipped
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(SheetInk.ink3)
                Text(kind.rawValue)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SheetInk.ink)
                if shipped {
                    Text("INSTALLED")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(SheetInk.ground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SheetInk.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            HStack(alignment: .top, spacing: 8) {
                zoom(kind, ground: SheetInk.light, ink: Color(.sRGB, red: 0.106, green: 0.106, blue: 0.114))
                zoom(kind, ground: SheetInk.groundDeep, ink: SheetInk.ink)
            }
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(SheetInk.groundDeep)
                    if let image = doubles[kind] {
                        Image(nsImage: image)
                            .renderingMode(.template)
                            .interpolation(.none)
                            .foregroundStyle(SheetInk.ink)
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("36 px · 1:1")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(SheetInk.ink3)
                    Text(measure(kind))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(SheetInk.ink3)
                }
            }
            Text(kind.note)
                .font(.system(size: 11))
                .lineSpacing(2.5)
                .foregroundStyle(shipped ? SheetInk.ink2 : SheetInk.ink3)
                .frame(width: 352, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(SheetInk.groundDeep.opacity(shipped ? 0.55 : 0.28))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    shipped ? SheetInk.accent.opacity(0.55) : SheetInk.rule,
                    lineWidth: 1
                )
        )
    }

    /// The ink's own box at eighteen points, so "weight" is a number.
    private func measure(_ kind: DotMenuGlyph.Kind) -> String {
        guard let extent = extents[kind] else { return "ink —" }
        return String(
            format: "ink %.1f × %.1f of 18",
            extent.width,
            extent.height
        )
    }

    /// The 18 pixel render, blown up by whole pixels so no edge is invented.
    private func zoom(
        _ kind: DotMenuGlyph.Kind,
        ground: Color,
        ink: Color
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(ground)
            if let image = glyphs[kind] {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 160, height: 160)
                    .foregroundStyle(ink)
            }
        }
        .frame(width: 169, height: 169)
    }

    // MARK: Verdict

    private var verdict: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT SHIPS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(SheetInk.accent)
                Text(DotMenuGlyph.Kind.shipped.rawValue)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SheetInk.ink)
                Text("MenuGlyph.png · 18")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SheetInk.ink3)
                Text("MenuGlyph@2x.png · 36")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SheetInk.ink3)
            }
            .frame(width: 200, alignment: .leading)

            Text(verdictText)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(SheetInk.ink2)
                .frame(width: 760, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.top, 24)
    }

    private var verdictText: String {
        switch DotMenuGlyph.Kind.shipped {
        case .bleed:
            "The icon's own numbers, unaltered: d 0.660 of the slot, and each flat takes the 23% of the dot's radius that the plate's 7.5% bleed comes to. At 36 — what a retina bar draws, and therefore what this app is actually seen at — the two flats are 2.7 px and read as the plate's edge crossing the dot. At 18 they are 1.4 px, and the two 90 degree corners at the rim start to compete with the arc: the silhouette squares off. That is the honest residual, and it is the same shape the icon's own dot has, so the bar and the Dock cannot disagree. The two ways of avoiding it were built and rejected: a corner bitten out of the dot (an inward corner, on the theory that a subtraction reads differently from a chord) and the quadrant. A bite shallow enough to leave the disc round is a half-pixel step; a bite deep enough to see squares the disc off exactly as the chord does; and the quadrant stops being a dot at all."
        case .quarter:
            "The centre on the corner, so only one quadrant of the dot is inside the frame. The arc reads clearly at both sizes, and it is the only candidate that keeps the bleed's geometry exactly — but the shape is a corner wedge, not a dot, and at eighteen points it sits in the bar like a rounded square's corner. That is the one reading the brief rules out. Reserved for the icon, where the disc is large enough to stay a disc."
        default:
            "No reduction of the Clipped mark."
        }
    }
}
