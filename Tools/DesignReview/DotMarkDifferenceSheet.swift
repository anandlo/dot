import AppKit
import SwiftUI

// The differentiation sheet.
//
// The question this sheet answers is not "which mark is handsomest" but "would
// this one be confused with, or lost among, the icons the category already
// ships". That is why every row ends in the same in-category strip, with the
// real App Store artwork at one size and ours in the same place among them.

/// The colour the sheet is printed on.
private enum DiffInk {
    static let ground = Color(.sRGB, red: 0.145, green: 0.149, blue: 0.157)
    static let groundDeep = Color(.sRGB, red: 0.086, green: 0.090, blue: 0.098)
    static let light = Color(.sRGB, red: 0.898, green: 0.890, blue: 0.873)
    static let ink = Color(.sRGB, red: 0.937, green: 0.933, blue: 0.925)
    static let ink2 = Color(.sRGB, red: 0.647, green: 0.643, blue: 0.635)
    static let ink3 = Color(.sRGB, red: 0.420, green: 0.420, blue: 0.420)
    static let rule = Color(.sRGB, red: 0.224, green: 0.227, blue: 0.235)
    static let accent = Color(.sRGB, red: 0.827, green: 0.690, blue: 0.392)
}

struct DotMarkDifferenceSheet: View {
    /// One real icon from the category, as Apple serves it.
    struct Cast: Identifiable {
        let name: String
        let image: NSImage
        var id: String { name }
    }

    struct Row: Identifiable {
        let dial: DotMarkDial
        /// "01".."04", or nil for the control row.
        let number: String?
        let masterLight: NSImage
        let masterDark: NSImage
        /// 16, 32 and 64 pixels, each drawn at its own size.
        let strip: [NSImage]
        /// Five tiles: the cast in fixed order with ours inserted.
        let categoryLight: [NSImage]
        let categoryDark: [NSImage]
        var id: String { dial.rawValue }
    }

    let cast: [Cast]
    let control: Row
    let rows: [Row]
    /// Where ours sits in the category row, counted from zero.
    let ourSlot: Int

    static let size = CGSize(width: 2240, height: 3040)

    private static let textColumn: CGFloat = 300
    private static let stripColumn: CGFloat = 208
    /// The edge of one icon in the in-category row.
    static let tileSize: CGFloat = 88

    /// The box a 1024 master is drawn into on the sheet.
    ///
    /// The master is rendered at its own 1024 pixels and only scaled down for
    /// the sheet, so the panel shows the master's detail rather than a 440 pixel
    /// redraw of it.
    static let masterBox: CGFloat = 440
    private static let rowGap: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            legend
            controlBlock
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index == 0 {
                    Rectangle().fill(DiffInk.rule).frame(height: 1)
                        .padding(.vertical, 26)
                }
                rowView(row)
            }
            footer
        }
        .padding(.horizontal, 56)
        .padding(.top, 52)
        .padding(.bottom, 30)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(DiffInk.ground)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 12) {
                Text("DOT  ·  MARK DIFFERENTIATION")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(DiffInk.accent)
                Text("Four ways to stop being Aqua Voice's icon")
                    .font(.system(size: 40, weight: .semibold))
                    .tracking(-0.7)
                    .foregroundStyle(DiffInk.ink)
                Text("Porcelain's plate is held constant: the same warm graphite, the same floor, the same measured system corner, the same shadow. Only the dot's geometry and placement change, and each candidate holds the same optical weight so that a row is a choice about form rather than about which mark is biggest. Every row ends in the category it has to live in. The question is not whether a mark is handsome; it is whether it is still this mark or that one.")
                    .font(.system(size: 14.5))
                    .lineSpacing(4.5)
                    .foregroundStyle(DiffInk.ink2)
                    .frame(width: 980, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 7) {
                Text("Plate  Porcelain, unchanged")
                Text("Master  1024 px, drawn from geometry")
                Text("Sizes   16 · 32 · 64 at their own pixels")
                Text("Row     real App Store art at 88 px")
                Text("Ground  light and dark, side by side")
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(DiffInk.ink3)
            .frame(width: 400, alignment: .trailing)
        }
        .padding(.bottom, 30)
    }

    // MARK: Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 24) {
                HStack(spacing: 10) {
                    castSlot(0)
                    castSlot(1)
                    ourSlotMarker
                    castSlot(2)
                    castSlot(3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("THE ROW")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(2.6)
                        .foregroundStyle(DiffInk.ink3)
                    Text("Aqua Voice is the icon this mark currently duplicates: one filled disc, dead centre, on a rounded-square plate. The other three spend their contrast elsewhere - bars, a loop, a letter - so the category is one duplicated structure and three unrelated marks. Ours sits third in every row, on both grounds, at the same 88 px.")
                        .font(.system(size: 12.5))
                        .lineSpacing(3.5)
                        .foregroundStyle(DiffInk.ink2)
                        .frame(width: 900, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 26)
    }

    private func castSlot(_ index: Int) -> some View {
        Group {
            if index < cast.count {
                VStack(spacing: 7) {
                    Image(nsImage: cast[index].image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                    Text(cast[index].name)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(DiffInk.ink2)
                        .frame(width: 84)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The slot ours occupies: an outline, because which dial fills it is the
    /// subject of the sheet and not a fact of the legend.
    private var ourSlotMarker: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DiffInk.accent.opacity(0.55), lineWidth: 1)
                .frame(width: 72, height: 72)
                .overlay(
                    Text("DOT")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(DiffInk.accent)
                )
            Text("this direction")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(DiffInk.accent)
                .frame(width: 84)
        }
    }

    // MARK: Rows

    private var controlBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text("CONTROL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(2.6)
                    .foregroundStyle(DiffInk.ink3)
                Text("what ships today - the mark the four have to beat")
                    .font(.system(size: 12))
                    .foregroundStyle(DiffInk.ink3)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 8)
            rowView(control)
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: Self.rowGap) {
            textColumn(row)
                .frame(width: Self.textColumn, alignment: .leading)
            panel(row.masterLight, ground: DiffInk.light, caption: "1024 master · light ground")
            panel(row.masterDark, ground: DiffInk.groundDeep, caption: "1024 master · dark ground")
            strip(row.strip)
            categoryBlock(row)
            Spacer(minLength: 0)
        }
        .frame(height: 470, alignment: .top)
        .padding(.bottom, 26)
    }

    private func textColumn(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let number = row.number {
                    Text(number)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(DiffInk.ink3)
                }
                Text(row.dial.name)
                    .font(.system(size: 27, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(row.number == nil ? DiffInk.ink2 : DiffInk.ink)
            }
            Text(row.dial.headline)
                .font(.system(size: 12.5, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(DiffInk.accent)
                .frame(width: Self.textColumn - 4, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
            Text(row.dial.detail)
                .font(.system(size: 11.5))
                .lineSpacing(3.2)
                .foregroundStyle(DiffInk.ink2)
                .frame(width: Self.textColumn - 4, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)
            Text("GEOMETRY")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(DiffInk.ink3)
                .padding(.top, 12)
            Text(row.dial.spec)
                .font(.system(size: 10, design: .monospaced))
                .lineSpacing(2)
                .foregroundStyle(DiffInk.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
    }

    private func panel(_ image: NSImage, ground: Color, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ground)
                Image(nsImage: image)
            }
            .frame(width: Self.masterBox, height: Self.masterBox)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(caption)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(DiffInk.ink3)
        }
    }

    private func strip(_ images: [NSImage]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 12) {
                    if images.count >= 3 {
                        labelled(images[2], caption: "64")
                        labelled(images[1], caption: "32")
                        labelled(images[0], caption: "16")
                    }
                }
                Text("real size")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(DiffInk.ink3)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let first = images.first {
                    Image(nsImage: first)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 128, height: 128)
                        .overlay(
                            Rectangle().strokeBorder(DiffInk.rule, lineWidth: 1)
                        )
                }
                Text("16 px at 8×, nearest")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(DiffInk.ink3)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.stripColumn, alignment: .leading)
    }

    private func labelled(_ image: NSImage, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(nsImage: image)
            Text(caption)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(DiffInk.ink3)
        }
    }

    private func categoryBlock(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            groundRow(row.categoryLight, ground: DiffInk.light)
            groundRow(row.categoryDark, ground: DiffInk.groundDeep)
            Text("in category · ours third")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(DiffInk.ink3)
            Spacer(minLength: 0)
        }
    }

    private func groundRow(_ images: [NSImage], ground: Color) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                VStack(spacing: 5) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: Self.tileSize, height: Self.tileSize)
                    Rectangle()
                        .fill(index == ourSlot ? DiffInk.accent : Color.clear)
                        .frame(width: Self.tileSize, height: 2)
                }
            }
        }
        .padding(12)
        .background(ground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(DiffInk.rule)
                .frame(height: 1)
                .padding(.bottom, 6)
            HStack(alignment: .top, spacing: 40) {
                Text("The category art is Apple's own, fetched at 512 px from the iTunes lookup API and shown unmodified at 88 px: Aqua Voice 6759074969, Wispr Flow 6497229487, superwhisper 6471464415, Monologue 6755956193. Two of the ids in the brief - Aqua Voice 6479816856 and superwhisper 6499424742 - return no results from that API in any storefront; the live ids above were found by the same API's name search, and no icon here is a redrawing.")
                    .frame(width: 980, alignment: .leading)
                Text("No shadow in the category rows: the App Store serves these four without one, so ours is drawn flat there too and the only variable left is the mark. The master panels carry the approved Dock shadow.\n\nNothing is installed. Dot still ships Porcelain's centred dot in Resources/ until one of these is chosen.")
                    .foregroundStyle(DiffInk.ink3)
                    .frame(width: 620, alignment: .leading)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .lineSpacing(3)
            .foregroundStyle(DiffInk.ink2)
        }
        .padding(.top, 6)
    }
}
