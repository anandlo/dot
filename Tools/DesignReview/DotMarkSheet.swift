import AppKit
import SwiftUI

// The review sheets.
//
// A direction is chosen from a rendered artifact, never from a description, so
// every sheet shows the same four things: the mark large enough to look at,
// the mark at the sizes it will actually live at, the mark on a light ground
// and on a dark one, and one line saying what the direction is.
//
// The grounds are neutral cardboard, not a mock desktop: a sheet that imitates
// a wallpaper starts arguing for the icon instead of showing it.

/// The colour the sheets are printed on.
enum SheetInk {
    static let ground = Color(.sRGB, red: 0.145, green: 0.149, blue: 0.157)
    static let groundDeep = Color(.sRGB, red: 0.086, green: 0.090, blue: 0.098)
    static let light = Color(.sRGB, red: 0.898, green: 0.890, blue: 0.873)
    static let ink = Color(.sRGB, red: 0.937, green: 0.933, blue: 0.925)
    static let ink2 = Color(.sRGB, red: 0.647, green: 0.643, blue: 0.635)
    static let ink3 = Color(.sRGB, red: 0.420, green: 0.420, blue: 0.420)
    static let rule = Color(.sRGB, red: 0.224, green: 0.227, blue: 0.235)
    static let accent = Color(.sRGB, red: 0.827, green: 0.690, blue: 0.392)
}

// MARK: - Overview

/// The sheet the direction is chosen from.
struct DotMarkOverviewSheet: View {
    struct Row: Identifiable {
        let direction: DotMarkDirection
        let index: Int
        let light: NSImage
        let dark: NSImage
        let small: [NSImage]
        let edge: NSImage
        var id: String { direction.rawValue }
    }

    let rows: [Row]
    let iconEdge: CGFloat

    static let size = CGSize(width: 1840, height: 2290)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(SheetInk.rule)
                        .frame(height: 1)
                }
                rowView(row)
            }
            footer
        }
        .padding(.horizontal, 60)
        .padding(.top, 52)
        .padding(.bottom, 34)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(SheetInk.ground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 12) {
                Text("DOT")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(SheetInk.accent)
                Text("The mark, in four directions")
                    .font(.system(size: 38, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(SheetInk.ink)
                Text("A white dot on a black plate. The same dot in all four; what changes is the plate's material, where the light falls, and whether the dot is printed on the plate, resting on it, domed over it, or the only light in the frame.")
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .foregroundStyle(SheetInk.ink2)
                    .frame(width: 830, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 6) {
                Text("1024 px master, drawn from geometry")
                Text("16 · 32 · 64 at their real size")
                Text("Light and dark ground, side by side")
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(SheetInk.ink3)
            .frame(width: 340, alignment: .trailing)
        }
        .padding(.bottom, 30)
    }

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: "%02d", row.index))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(SheetInk.ink3)
                Text(row.direction.name)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(SheetInk.ink)
                    .padding(.top, 2)
                Text(row.direction.material)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(SheetInk.ink2)
                    .frame(width: 420, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Text(row.direction.dot)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(SheetInk.ink2)
                    .frame(width: 420, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                Text(row.direction.difference)
                    .font(.system(size: 12, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(SheetInk.accent)
                    .frame(width: 420, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                HStack(alignment: .center, spacing: 11) {
                    Image(nsImage: row.edge)
                        .overlay(
                            Rectangle()
                                .strokeBorder(SheetInk.rule, lineWidth: 1)
                        )
                    Text("1:1, the seat")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(SheetInk.ink3)
                }
                .padding(.top, 18)
            }
            .frame(width: 430, alignment: .leading)

            panel(row.light, ground: .light)
            panel(row.dark, ground: .dark)
            strip(row.small)
        }
        .frame(height: 470)
    }

    private enum Ground {
        case light
        case dark
    }

    private func panel(_ image: NSImage, ground: Ground) -> some View {
        let box = DotIconPresentation.paddedSize(for: iconEdge)
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ground == .light ? SheetInk.light : SheetInk.groundDeep)
            Image(nsImage: image)
                .frame(width: box, height: box)
        }
        .frame(width: 420, height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.trailing, 14)
    }

    private func strip(_ images: [NSImage]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .bottom, spacing: 16) {
                    if images.count >= 3 {
                        labelled(images[0], caption: "64")
                        labelled(images[1], caption: "32")
                        labelled(images[2], caption: "16")
                    }
                }
                Text("real size")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SheetInk.ink3)
            }
            if let first = images.first {
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: first)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("16 px at 6×")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(SheetInk.ink3)
                }
            }
        }
        .frame(width: 380, alignment: .leading)
    }

    private func labelled(_ image: NSImage, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(nsImage: image)
            Text(caption)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SheetInk.ink3)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 30) {
            Text("The plate is a full square because macOS masks the icon itself: the corner in these panels is the system's continuous corner, not a clip baked into the master.")
                .frame(width: 700, alignment: .leading)
            Text("Nothing has been installed. Dot keeps its current mark until one of these is chosen.")
                .foregroundStyle(SheetInk.ink3)
                .frame(width: 520, alignment: .leading)
        }
        .font(.system(size: 11.5))
        .lineSpacing(3)
        .foregroundStyle(SheetInk.ink2)
        .padding(.top, 24)
    }
}

// MARK: - Detail

/// One direction, close enough to judge the material.
struct DotMarkDetailSheet: View {
    let direction: DotMarkDirection
    let light: NSImage
    let dark: NSImage
    let strip: [NSImage]
    let edge: NSImage
    let seat: NSImage

    static let size = CGSize(width: 1560, height: 810)

    private static let panel: CGFloat = 430

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text(direction.name.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(3.4)
                    .foregroundStyle(SheetInk.accent)
                Text(direction.difference)
                    .font(.system(size: 23, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(SheetInk.ink)
            }
            .padding(.bottom, 22)

            HStack(alignment: .top, spacing: 18) {
                platePanel(light, ground: SheetInk.light, caption: "Light ground")
                platePanel(dark, ground: SheetInk.groundDeep, caption: "Dark ground")
                materialPanel
            }

            HStack(alignment: .bottom, spacing: 26) {
                ForEach(Array(strip.enumerated()), id: \.offset) { index, image in
                    VStack(alignment: .leading, spacing: 7) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 96, height: 96)
                        Text(["16 px at 6×", "32 px at 3×", "64 px at 1.5×"][min(index, 2)])
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(SheetInk.ink3)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(Array(strip.prefix(3).enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image)
                        }
                    }
                    .frame(height: 64, alignment: .bottom)
                    Text("16 · 32 · 64, real size")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SheetInk.ink3)
                }
                .padding(.leading, 16)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 5) {
                    Text("DOT")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(2.2)
                        .foregroundStyle(SheetInk.ink3)
                    Text(direction.dot)
                        .font(.system(size: 11.5))
                        .lineSpacing(3)
                        .foregroundStyle(SheetInk.ink2)
                        .frame(width: 470, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 470, alignment: .leading)
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 46)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(SheetInk.ground)
    }

    private func platePanel(_ image: NSImage, ground: Color, caption: String) -> some View {
        let box = DotIconPresentation.paddedSize(for: 328)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ground)
                Image(nsImage: image)
                    .frame(width: box, height: box)
            }
            .frame(width: Self.panel, height: Self.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(caption)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(SheetInk.ink3)
        }
    }

    /// Two crops at one to one, where a material either holds up or does not.
    private var materialPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 14) {
                cropBox(edge, caption: "the dot's edge, 1:1")
                cropBox(seat, caption: "the dot's seat, 1:1")
            }
            Text("PLATE")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(SheetInk.ink3)
                .padding(.top, 2)
            Text(direction.material)
                .font(.system(size: 11.5))
                .lineSpacing(3)
                .foregroundStyle(SheetInk.ink2)
                .frame(width: Self.panel, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.panel, alignment: .leading)
    }

    private func cropBox(_ image: NSImage, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(nsImage: image)
                .overlay(
                    Rectangle()
                        .strokeBorder(SheetInk.rule, lineWidth: 1)
                )
            Text(caption)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(SheetInk.ink3)
        }
    }
}

// MARK: - Menu bar glyph

/// The menu bar mark at 18 and 36, on both bars, beside system symbols.
struct DotMenuGlyphSheet: View {
    let glyphs: [DotMenuGlyph.Kind: NSImage]
    let doubles: [DotMenuGlyph.Kind: NSImage]

    static let size = CGSize(width: 1440, height: 660)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text("MENU BAR")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(3.4)
                    .foregroundStyle(SheetInk.accent)
                Text("One drawing, not the icon at eighteen points")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(SheetInk.ink)
                Text("A template survives only on geometry and weight, so the glyph is a dot on the baseline of the word it punctuates. It is drawn as ink on transparent and the system inverts it on a dark bar. The system symbols sit beside it for weight, not for style.")
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(SheetInk.ink2)
                    .frame(width: 820, alignment: .leading)
            }
            .padding(.bottom, 24)

            bar(dark: false)
            bar(dark: true)
            closeUps
        }
        .padding(.horizontal, 46)
        .padding(.top, 38)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(SheetInk.ground)
    }

    private func bar(dark: Bool) -> some View {
        let ground = dark ? SheetInk.groundDeep : SheetInk.light
        let ink = dark ? SheetInk.light : Color(.sRGB, red: 0.110, green: 0.110, blue: 0.118)
        return HStack(spacing: 30) {
            cell(.disc, ink: ink, label: "disc")
            cell(.dot, ink: ink, label: "dot")
            cell(.barred, ink: ink, label: "barred")
            cell(nil, ink: ink, label: "mic")
            cell(nil, ink: ink, label: "waveform")
            HStack(spacing: 22) {
                if let image = doubles[.dot] {
                    Image(nsImage: image)
                        .foregroundStyle(ink)
                }
            }
            .padding(.leading, 26)
            Text("36 px · 2×")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(ink.opacity(0.45))
                .padding(.leading, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .frame(height: 88)
        .background(ground)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.bottom, 12)
    }

    private func cell(_ kind: DotMenuGlyph.Kind?, ink: Color, label: String) -> some View {
        VStack(spacing: 8) {
            Group {
                if let kind, let image = glyphs[kind] {
                    Image(nsImage: image)
                        .foregroundStyle(ink)
                } else {
                    Image(systemName: label)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(ink)
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: 18, height: 18)
            Text(label)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(ink.opacity(0.55))
        }
        .frame(width: 62)
    }

    private var closeUps: some View {
        HStack(alignment: .top, spacing: 26) {
            ForEach(DotMenuGlyph.Kind.legacy, id: \.rawValue) { kind in
                VStack(alignment: .leading, spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(SheetInk.groundDeep)
                        if let image = glyphs[kind] {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 126, height: 126)
                                .colorInvert()
                        }
                    }
                    .frame(width: 160, height: 160)
                    Text("\(kind.rawValue) · 18 px at 7×")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SheetInk.ink3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }
}
