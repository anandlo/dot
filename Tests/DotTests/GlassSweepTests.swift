import AppKit
import DotCore
import SwiftUI
import XCTest
@testable import Dot

/// The measured sweep of the recording card's glass.
///
/// The card's fill is a window-server material, so the only picture that can
/// judge it is a capture of the window. This suite draws the real card over the
/// five backdrops the glass was decided on, measures what the owner asked for,
/// and records every capture and every number into a directory: how the ink
/// reads, how much of the backdrop's colour survives the glass, how far the
/// glass bends one backdrop toward another, and how bright its top rim is.
///
/// The design it draws is the shipped one, read from ``HUDTheme`` rather than
/// written here a second time: the clear variant, the 0.30 scrim, the clock's
/// measured ink. It asserts nothing about taste; it records measurements, and
/// it runs only when `DOT_GLASS_SWEEP` names a directory.
@MainActor
final class GlassSweepTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    // MARK: - The shipped design

    /// The values the card ships, as one record.
    private struct Design {
        var variant: HUDGlassVariant
        var scrim: Double
        var clock: Double
    }

    /// The design the sweep draws, read from the tokens the app draws it with.
    private static var design: Design {
        Design(
            variant: HUDTheme.glassVariant,
            scrim: HUDTheme.glassScrimOpacity,
            clock: HUDTheme.clockInkOpacity
        )
    }

    /// What the card is drawn over.
    private enum Backdrop: String, CaseIterable {
        /// The reference photograph's blue wave.
        case wave
        /// The reference photograph's pale sky and light wave.
        case waveBright = "wave-bright"
        /// A white page, luma 0.92.
        case white
        /// A dark page, luma 0.12.
        case dark
        /// The twelve saturated bands the capture tests draw.
        case bands
    }

    /// The script's loudest moment, where the meter is lit.
    private static let moment: Double = 6.96

    // MARK: - The canvas

    /// The card's own size, in points.
    private static let cardSize = CGSize(
        width: HUDState.recordingWidth,
        height: HUDState.recordingHeight
    )
    /// The backdrop's margin around the card, in points, on every side.
    private static let margin: CGFloat = 60
    /// The window the card and its backdrop are drawn in, in points.
    private static let canvas = CGSize(
        width: cardSize.width + 2 * margin,
        height: cardSize.height + 2 * margin
    )
    /// The card's rect inside the canvas, in points.
    private static var cardRect: CGRect {
        CGRect(x: margin, y: margin, width: cardSize.width, height: cardSize.height)
    }
    /// The reference photograph the two photographic backdrops are cut from.
    private static let referenceURL = URL(fileURLWithPath: "/tmp/dot-ref-glass.png")

    // MARK: - The sweep

    /// Draws, captures, measures and writes the shipped card over every backdrop.
    ///
    /// Five captures, one per backdrop, plus the bare backdrop each is measured
    /// against and the one surface-only picture the content mask is read from.
    /// Every capture is written as a PNG, every measurement to `sweep.csv`, and
    /// one contact sheet shows the five backdrops beside each other.
    func testTheSweepMeasuresTheGlass() throws {
        let directory = try sweepDirectory()
        let reference = try referenceImage()
        let scale = try captureScale(reference)
        let design = Self.design

        let voice = HUDPreview.voiceSample(at: Self.moment)
        print(String(
            format: "SWEEP voice at %.2f s: the script's still moment is %.3f s, level %.3f, "
                + "ceiling %.3f, %d history samples peaking at %.3f, capture scale %.2fx, canvas %.0fx%.0f pt",
            Self.moment,
            DictationScript.stillTime,
            voice.level,
            voice.ceiling,
            voice.history.count,
            voice.history.max() ?? 0,
            scale,
            Self.canvas.width,
            Self.canvas.height
        ))

        let bare = try bareBackdrops(reference)
        let mask = try contentMask(scale: scale, reference: reference)
        let clockBox = try glyphBoxes(scale: scale)

        var rows: [Row] = []
        var cells: [(label: String, image: CGImage)] = []

        for backdrop in Backdrop.allCases {
            let picture = try capture(
                canvasView(backdrop, reference: reference),
                size: Self.canvas,
                requiresContent: true
            )
            let box = cardBox(picture)
            let stem = fileStem(backdrop)
            XCTAssertTrue(
                WindowCapture.write(picture, to: directory.appendingPathComponent("\(stem).png")),
                "\(stem).png was not written"
            )
            let rec = WindowCapture.glyphContrast(picture, box: recBox(box))
            let clock = WindowCapture.glyphContrast(picture, box: clockBox(box))
            let interior = inset(box, points: 2, scale: scale)
            let cardChroma = meanChroma(picture, interior, mask: mask)
            let bareChroma = meanChroma(
                try XCTUnwrap(bare[backdrop], "no bare picture for \(backdrop)"),
                interior,
                mask: mask
            )
            let rim = rimMeasure(picture, box: box, mask: mask, scale: scale)
            if let image = WindowCapture.image(picture), let thumb = thumbnail(image, box: box) {
                cells.append((backdrop.rawValue, thumb))
            }
            rows.append(Row(
                backdrop: backdrop,
                width: picture.width,
                height: picture.height,
                scale: scale,
                rec: rec.ratio,
                clock: clock.ratio,
                vividness: bareChroma > 1 ? cardChroma / bareChroma : .nan,
                cardChroma: cardChroma,
                bareChroma: bareChroma,
                refraction: .nan,
                rim: rim.maximum - rim.interior,
                interior: rim.interior,
                excluded: rim.excluded,
                alpha: meanAlpha(picture, interior)
            ))
        }

        measureRefraction(&rows, scale: scale, directory: directory)
        try writeCSV(rows, to: directory, design: design)
        let sheet = directory.appendingPathComponent("sheet-backdrops.png")
        XCTAssertTrue(writeSheet(cells, to: sheet), "sheet-backdrops.png was not written")
        report(rows, design: design, directory: directory)
    }

    /// Reports how the card's own window behaves when the backdrop is a window
    /// behind it.
    ///
    /// The capture harness the glass tests use draws the backdrop and the card in
    /// one window, so the material samples content the app itself drew. The
    /// island's card samples the person's desktop through its window instead, and
    /// whether an offscreen window behind the card can stand in for that is a
    /// question only a capture answers. This draws the same bands both ways and
    /// prints what the card's own pixels came back as: the one-window picture
    /// carried the bands at a chroma of 42.1, the two-window picture came back a
    /// near-neutral 0.9, which is a material with no backdrop to sample. Every
    /// measurement here is therefore taken in one window.
    func testTheBackdropWindowProbe() throws {
        let directory = try sweepDirectory()
        let reference = try referenceImage()

        let oneWindow = try capture(
            canvasView(.bands, reference: reference),
            size: Self.canvas,
            requiresContent: true
        )
        let oneWindowBox = cardBox(oneWindow)

        let behind = WindowCapture.show(
            backdropView(.bands, reference: reference),
            size: Self.canvas
        )
        behind.setFrameOrigin(OffscreenWindow.origin)
        let front = WindowCapture.show(card(), size: Self.cardSize)
        front.setFrameOrigin(NSPoint(
            x: OffscreenWindow.origin.x + Self.margin,
            y: OffscreenWindow.origin.y + Self.margin
        ))
        WindowCapture.spin(0.3)
        let twoWindow = try XCTUnwrap(
            WindowCapture.capture(front),
            "the window server returned no picture of the card's window"
        )
        try WindowCapture.requireUsableCapture(twoWindow)
        WindowCapture.hide(front)
        WindowCapture.hide(behind)

        let scale = captureScale(of: oneWindow)
        print(String(
            format: "SWEEP probe one window: %dx%d, interior mean (%@) alpha %.1f, chroma %.4f",
            oneWindow.width, oneWindow.height,
            describe(oneWindow, oneWindowBox),
            meanAlpha(oneWindow, inset(oneWindowBox, points: 2, scale: scale)),
            meanChroma(oneWindow, inset(oneWindowBox, points: 2, scale: scale), mask: nil)
        ))
        let twoBox = WindowCapture.Rect(x: 0, y: 0, width: twoWindow.width, height: twoWindow.height)
        print(String(
            format: "SWEEP probe two windows: %dx%d, card mean (%@) alpha %.1f, chroma %.4f",
            twoWindow.width, twoWindow.height,
            describe(twoWindow, twoBox),
            meanAlpha(twoWindow, twoBox),
            meanChroma(twoWindow, twoBox, mask: nil)
        ))
        WindowCapture.write(
            oneWindow,
            to: directory.appendingPathComponent("probe-one-window.png")
        )
        WindowCapture.write(
            twoWindow,
            to: directory.appendingPathComponent("probe-two-windows.png")
        )
    }

    // MARK: - The evidence directory

    /// Writes the shipped card, and the cards it becomes, for review.
    ///
    /// The set is the five backdrops the glass was decided on, the recording
    /// card over the two that bound its contrast, the recording card with a live
    /// partial under it, and the transcript card over the same two. The window
    /// server's captures are at the display's own scale, 2x on this Mac, so they
    /// show the refraction a `cacheDisplay` render cannot.
    func testTheShippedGlassIsCapturedWhenAsked() throws {
        guard let value = DotMigration.environment("GLASS_FINAL") else {
            throw XCTSkip("Set DOT_GLASS_FINAL to capture the shipped glass.")
        }
        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reference = try referenceImage()

        for backdrop in Backdrop.allCases {
            let picture = try capture(
                canvasView(backdrop, reference: reference),
                size: Self.canvas,
                requiresContent: true
            )
            XCTAssertTrue(
                WindowCapture.write(
                    picture,
                    to: directory.appendingPathComponent("final-\(backdrop.rawValue).png")
                ),
                "final-\(backdrop.rawValue).png was not written"
            )
        }

        let states: [(HUDPreview.State, String)] = [
            (.recording, "recording"),
            (.live, "live"),
            (.transcript, "transcript"),
        ]
        for state in states {
            for backdrop in [Backdrop.wave, .white] {
                try captureState(state.0, backdrop: backdrop, reference: reference, name: state.1, into: directory)
            }
        }
        print("SWEEP evidence in \(directory.path)")
    }

    /// Writes one preview state over one backdrop, at its own card size.
    private func captureState(
        _ state: HUDPreview.State,
        backdrop: Backdrop,
        reference: CGImage,
        name: String,
        into directory: URL
    ) throws {
        let model = HUDPreview.makeModel(state: state)
        let size = model.cardSize
        let canvas = CGSize(
            width: size.width + 2 * Self.margin,
            height: size.height + 2 * Self.margin
        )
        let view = ZStack {
            backdropView(backdrop, reference: reference, size: canvas)
            HUDView(
                model: model,
                showsShadow: false,
                animated: false,
                actions: HUDPreview.previewActions
            )
            .frame(width: size.width, height: size.height)
        }
        .frame(width: canvas.width, height: canvas.height)
        let picture = try capture(view, size: canvas, requiresContent: true)
        let url = directory.appendingPathComponent("\(name)-\(backdrop.rawValue).png")
        XCTAssertTrue(WindowCapture.write(picture, to: url), "\(name)-\(backdrop.rawValue).png was not written")
        print(String(
            format: "SWEEP evidence %@ over %@: %dx%d at %.2fx, card %.0fx%.0f pt",
            name, backdrop.rawValue, picture.width, picture.height,
            Double(picture.width) / Double(canvas.width),
            size.width, size.height
        ))
    }

    // MARK: - The sweep directory

    /// The directory `DOT_GLASS_SWEEP` names, or a skip.
    private func sweepDirectory() throws -> URL {
        guard let value = DotMigration.environment("GLASS_SWEEP") else {
            throw XCTSkip("Set DOT_GLASS_SWEEP to a directory to run the glass sweep.")
        }
        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The reference photograph.
    private func referenceImage() throws -> CGImage {
        guard let image = NSImage(contentsOf: Self.referenceURL) else {
            throw XCTSkip("The reference photograph is not at \(Self.referenceURL.path)")
        }
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else {
            throw XCTSkip("The reference photograph could not be read as pixels")
        }
        XCTAssertEqual(cgImage.width, 1600, "the reference photograph is not 1600 px wide")
        XCTAssertEqual(cgImage.height, 1200, "the reference photograph is not 1200 px tall")
        return cgImage
    }

    /// The scale the window server captures at, which every measurement is
    /// converted with.
    private func captureScale(_ reference: CGImage) throws -> Double {
        let picture = try capture(
            backdropView(.bands, reference: reference),
            size: Self.canvas,
            requiresContent: false
        )
        return captureScale(of: picture)
    }

    /// The scale of one capture against the canvas it was asked for.
    private func captureScale(of picture: WindowCapture.Pixels) -> Double {
        Double(picture.width) / Double(Self.canvas.width)
    }

    // MARK: - The backdrops

    /// One backdrop at the canvas's size.
    @ViewBuilder
    private func backdropView(
        _ backdrop: Backdrop,
        reference: CGImage,
        size: CGSize? = nil
    ) -> some View {
        let size = size ?? Self.canvas
        Group {
            switch backdrop {
            case .wave:
                photograph(reference, crop: CGRect(x: 0, y: 520, width: 560, height: 460))
            case .waveBright:
                photograph(reference, crop: CGRect(x: 1000, y: 0, width: 600, height: 300))
            case .white:
                Color(red: 0.92, green: 0.92, blue: 0.92)
            case .dark:
                Color(red: 0.12, green: 0.12, blue: 0.12)
            case .bands:
                GlassBackdrop.colour
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// One crop of the reference photograph, scaled to fill the canvas.
    @ViewBuilder
    private func photograph(_ reference: CGImage, crop: CGRect) -> some View {
        if let cropped = reference.cropping(to: crop) {
            Image(decorative: cropped, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            Color.black
        }
    }

    // MARK: - The card

    /// The recording card, exactly as the island draws it.
    ///
    /// The model is the renderer's own recording state, fed the script's voice
    /// at ``moment`` so the meter is lit, with the Stretch visualiser the card
    /// ships. The card draws the fill, the scrim and the clock ink the app
    /// ships: there is no parameter here that the app does not have.
    private func card() -> some View {
        let model = HUDPreview.makeModel(state: .recording)
        let voice = HUDPreview.voiceSample(at: Self.moment)
        model.visualizer = .stretch
        model.time = Self.moment
        model.level = voice.level
        model.ceiling = voice.ceiling
        model.history = voice.history
        model.halfHeights = voice.halfHeights
        model.spectrumHistory = voice.spectrum
        return HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions
        )
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
    }

    /// The card over one backdrop, both inside the one window.
    private func canvasView(_ backdrop: Backdrop, reference: CGImage) -> some View {
        ZStack {
            backdropView(backdrop, reference: reference)
            card()
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
    }

    /// A picture of a view in an offscreen window.
    private func capture(
        _ view: some View,
        size: CGSize,
        requiresContent: Bool
    ) throws -> WindowCapture.Pixels {
        let window = WindowCapture.show(view, size: size)
        defer { WindowCapture.hide(window) }
        let picture = try XCTUnwrap(
            WindowCapture.capture(window),
            "the window server returned no picture of the window"
        )
        try WindowCapture.requireUsableCapture(picture, requiresContent: requiresContent)
        return picture
    }

    /// Every backdrop with no card on it, at the scale of the capture.
    ///
    /// The pictures are what the card is measured against and are written to the
    /// sweep's directory, so a reviewer sees the exact backdrop each cell of the
    /// sheet was drawn over.
    private func bareBackdrops(_ reference: CGImage) throws -> [Backdrop: WindowCapture.Pixels] {
        var pictures: [Backdrop: WindowCapture.Pixels] = [:]
        let directory = try sweepDirectory()
        for backdrop in Backdrop.allCases {
            let picture = try capture(
                backdropView(backdrop, reference: reference),
                size: Self.canvas,
                requiresContent: backdrop == .wave || backdrop == .waveBright
            )
            pictures[backdrop] = picture
            WindowCapture.write(
                picture,
                to: directory.appendingPathComponent("backdrop-\(backdrop.rawValue).png")
            )
        }
        return pictures
    }

    // MARK: - The content mask

    /// A mask of the pixels the card's content draws on.
    ///
    /// The mask is measured rather than assumed: the same card is captured with
    /// its content and with only the surface, and every pixel the content
    /// changed is masked out, then the mask is dilated so an antialiased edge is
    /// excluded too. The bands are the backdrop because they give the content
    /// the most contrast to be found against.
    private func contentMask(scale: Double, reference: CGImage) throws -> [Bool] {
        let full = try capture(
            canvasView(.bands, reference: reference),
            size: Self.canvas,
            requiresContent: true
        )
        let surface = try capture(
            ZStack {
                backdropView(.bands, reference: reference)
                HUDSurface(material: .glass)
                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            }
            .frame(width: Self.canvas.width, height: Self.canvas.height),
            size: Self.canvas,
            requiresContent: true
        )
        return mask(full, surface, dilation: Int((2 * scale).rounded()))
    }

    /// The pixels one picture differs from another in, dilated.
    private func mask(
        _ first: WindowCapture.Pixels,
        _ second: WindowCapture.Pixels,
        dilation: Int
    ) -> [Bool] {
        var changed = [Bool](repeating: false, count: first.width * first.height)
        guard first.width == second.width, first.height == second.height else { return changed }
        for y in 0 ..< first.height {
            for x in 0 ..< first.width {
                let a = first.pixel(x, y)
                let b = second.pixel(x, y)
                let difference = abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
                if difference > 2 {
                    changed[y * first.width + x] = true
                }
            }
        }
        guard dilation > 0 else { return changed }
        var dilated = changed
        for y in 0 ..< first.height {
            for x in 0 ..< first.width where changed[y * first.width + x] {
                for dy in -dilation ... dilation {
                    for dx in -dilation ... dilation {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, ny >= 0, nx < first.width, ny < first.height else { continue }
                        dilated[ny * first.width + nx] = true
                    }
                }
            }
        }
        return dilated
    }

    // MARK: - Geometry

    /// The card's rect in one capture.
    private func cardBox(_ picture: WindowCapture.Pixels) -> WindowCapture.Rect {
        WindowCapture.Rect.points(
            Self.cardRect,
            scaleX: CGFloat(picture.width) / Self.canvas.width,
            scaleY: CGFloat(picture.height) / Self.canvas.height
        )
    }

    /// A rect inset on every side by a distance in points.
    private func inset(
        _ rect: WindowCapture.Rect,
        points: Double,
        scale: Double
    ) -> WindowCapture.Rect {
        let inset = Int((points * scale).rounded())
        return WindowCapture.Rect(
            x: rect.x + inset,
            y: rect.y + inset,
            width: max(1, rect.width - 2 * inset),
            height: max(1, rect.height - 2 * inset)
        )
    }

    /// The box the REC label is read in, at the capture's scale.
    ///
    /// The same fractions of the card the capture tests read the label in, so a
    /// ratio measured here is comparable with the ratios ``HUDTheme`` records.
    private func recBox(_ box: WindowCapture.Rect) -> WindowCapture.Rect {
        let x0 = box.x + Int(Double(box.width) * 0.12)
        let x1 = box.x + Int(Double(box.width) * 0.23)
        let y0 = box.y + Int(Double(box.height) * 0.32)
        let y1 = box.y + Int(Double(box.height) * 0.68)
        return WindowCapture.Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The clock's box, measured from one capture of the card.
    ///
    /// The clock is not at a fraction of the card that can be written down
    /// without the font: it starts after the label and the gap that follows it.
    /// One capture over the dark backdrop is read for its ink, the label and the
    /// clock at the two gaps a font cannot close, and the clock's own ink becomes
    /// the box, widened by the room the label's box keeps around its glyphs.
    private func glyphBoxes(scale: Double) throws -> (WindowCapture.Rect) -> WindowCapture.Rect {
        let reference = try referenceImage()
        let picture = try capture(
            canvasView(.dark, reference: reference),
            size: Self.canvas,
            requiresContent: true
        )
        let box = cardBox(picture)
        let clusters = inkGroups(picture, box: box, scale: scale)
        XCTAssertEqual(
            clusters.count,
            2,
            "the card's left side holds \(clusters.count) ink groups where the label and the clock "
                + "are two"
        )
        let label = try XCTUnwrap(clusters.first, "the label's ink was not found")
        let clock = try XCTUnwrap(clusters.last, "the clock's ink was not found")
        let pad = Int((4 * scale).rounded())
        let y0 = box.y + Int(Double(box.height) * 0.32)
        let y1 = box.y + Int(Double(box.height) * 0.68)
        let clockOffset = clock.x - box.x - pad
        let clockWidth = clock.width + 2 * pad
        let labelBox = recBox(box)
        print(String(
            format: "SWEEP boxes at %.2fx: card (%d, %d, %d, %d), label ink (%d, %d, %d, %d) in the "
                + "box (%d, %d, %d, %d), clock ink (%d, %d, %d, %d) in (%d, %d, %d, %d)",
            scale,
            box.x, box.y, box.width, box.height,
            label.x, label.y, label.width, label.height,
            labelBox.x, labelBox.y, labelBox.width, labelBox.height,
            clock.x, clock.y, clock.width, clock.height,
            box.x + clockOffset, y0, clockWidth, y1 - y0
        ))
        XCTAssertLessThan(
            Double(clockOffset + clockWidth),
            Double(box.width) * 0.34,
            "the clock's box runs into the waveform"
        )
        return { card in
            WindowCapture.Rect(
                x: card.x + clockOffset,
                y: card.y + y0 - box.y,
                width: clockWidth,
                height: y1 - y0
            )
        }
    }

    /// The ink groups on the card's left side, left to right.
    ///
    /// A column holds ink when any of its pixels is brighter than the card's
    /// own surface; columns are grouped across a gap wide enough to be the
    /// space between the label and the clock and too wide for the space a font
    /// leaves between two glyphs. The search starts past the live dot and stops
    /// short of the waveform, so the dot's glow and the meter's bars are not
    /// read as glyphs.
    private func inkGroups(
        _ picture: WindowCapture.Pixels,
        box: WindowCapture.Rect,
        scale: Double
    ) -> [WindowCapture.Rect] {
        let base = box.x + Int((30 * scale).rounded())
        let end = min(box.x + Int((108 * scale).rounded()), picture.width)
        let top = box.y + Int((8 * scale).rounded())
        let bottom = min(box.y + Int((46 * scale).rounded()), picture.height)
        var columns: [Bool] = []
        for x in base ..< end {
            var found = false
            for y in top ..< bottom where WindowCapture.luminance(picture.pixel(x, y)) > 0.05 {
                found = true
                break
            }
            columns.append(found)
        }
        let gap = max(1, Int((6 * scale).rounded()))
        var groups: [WindowCapture.Rect] = []
        var runStart: Int? = nil
        var empty = 0
        for (offset, hasInk) in columns.enumerated() {
            if hasInk {
                if runStart == nil { runStart = offset }
                empty = 0
            } else if let start = runStart {
                empty += 1
                if empty >= gap {
                    groups.append(group(
                        base + start ..< base + offset - empty + 1,
                        picture: picture,
                        top: top,
                        bottom: bottom
                    ))
                    runStart = nil
                    empty = 0
                }
            }
        }
        if let start = runStart {
            groups.append(group(
                base + start ..< base + columns.count,
                picture: picture,
                top: top,
                bottom: bottom
            ))
        }
        return groups
    }

    /// The rect one run of ink columns covers, in the capture.
    private func group(
        _ range: Range<Int>,
        picture: WindowCapture.Pixels,
        top: Int,
        bottom: Int
    ) -> WindowCapture.Rect {
        var minY = Int.max
        var maxY = Int.min
        for x in range {
            for y in top ..< bottom {
                if WindowCapture.luminance(picture.pixel(x, y)) > 0.05 {
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        let height = maxY >= minY ? maxY - minY + 1 : 1
        return WindowCapture.Rect(
            x: range.lowerBound,
            y: minY == Int.max ? top : minY,
            width: range.count,
            height: height
        )
    }

    // MARK: - Measuring

    /// The mean chroma of a rect, excluding the pixels a content mask covers.
    ///
    /// Chroma is CIE LCh's C*, from the pixel's sRGB value through the D65
    /// white, so a backdrop's colour is measured as it looks rather than as its
    /// channel spread.
    private func meanChroma(
        _ picture: WindowCapture.Pixels,
        _ rect: WindowCapture.Rect,
        mask: [Bool]?
    ) -> Double {
        var sum = 0.0
        var count = 0
        for y in max(0, rect.y) ..< min(picture.height, rect.y + rect.height) {
            for x in max(0, rect.x) ..< min(picture.width, rect.x + rect.width) {
                if let mask, mask[y * picture.width + x] { continue }
                sum += chroma(picture.unpremultiplied(x, y))
                count += 1
            }
        }
        return count == 0 ? .nan : sum / Double(count)
    }

    /// The share of a rect the content mask covers.
    private func excluded(
        _ rect: WindowCapture.Rect,
        mask: [Bool],
        width: Int,
        height: Int
    ) -> Double {
        var masked = 0
        var count = 0
        for y in max(0, rect.y) ..< min(height, rect.y + rect.height) {
            for x in max(0, rect.x) ..< min(width, rect.x + rect.width) {
                if mask[y * width + x] { masked += 1 }
                count += 1
            }
        }
        return count == 0 ? .nan : Double(masked) / Double(count)
    }

    /// The mean alpha of a rect, which says whether the capture is opaque.
    private func meanAlpha(_ picture: WindowCapture.Pixels, _ rect: WindowCapture.Rect) -> Double {
        var sum = 0.0
        var count = 0
        for y in max(0, rect.y) ..< min(picture.height, rect.y + rect.height) {
            for x in max(0, rect.x) ..< min(picture.width, rect.x + rect.width) {
                sum += picture.rgba(x, y).3
                count += 1
            }
        }
        return count == 0 ? .nan : sum / Double(count)
    }

    /// The brightest pixel of the card's top edge band and the interior's mean.
    ///
    /// The band is the two points inside the shape's top edge, along the run the
    /// rounded corners leave straight. The interior is the card inset six points,
    /// which is below the band and inside every edge, with the content masked out
    /// so the ink and the meter do not lift it.
    private func rimMeasure(
        _ picture: WindowCapture.Pixels,
        box: WindowCapture.Rect,
        mask: [Bool],
        scale: Double
    ) -> (maximum: Double, interior: Double, excluded: Double) {
        let radius = Int((HUDTheme.cornerRadius * scale).rounded())
        let band = WindowCapture.Rect(
            x: box.x + radius,
            y: box.y,
            width: max(1, box.width - 2 * radius),
            height: max(1, Int((2 * scale).rounded()))
        )
        var maximum = -Double.infinity
        for y in band.y ..< min(picture.height, band.y + band.height) {
            for x in band.x ..< min(picture.width, band.x + band.width) {
                maximum = max(maximum, WindowCapture.luminance(picture.unpremultiplied(x, y)))
            }
        }
        let interior = inset(box, points: 6, scale: scale)
        var sum = 0.0
        var count = 0
        for y in interior.y ..< min(picture.height, interior.y + interior.height) {
            for x in interior.x ..< min(picture.width, interior.x + interior.width) {
                if mask[y * picture.width + x] { continue }
                sum += WindowCapture.luminance(picture.unpremultiplied(x, y))
                count += 1
            }
        }
        return (
            maximum,
            count == 0 ? .nan : sum / Double(count),
            excluded(interior, mask: mask, width: picture.width, height: picture.height)
        )
    }

    /// The sRGB values of one pixel as CIE LCh's chroma, D65.
    private func chroma(_ colour: (Double, Double, Double)) -> Double {
        func linear(_ channel: Double) -> Double {
            let value = channel / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(colour.0)
        let g = linear(colour.1)
        let b = linear(colour.2)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        let white = (x: 0.95047, y: 1.0, z: 1.08883)
        func f(_ value: Double) -> Double {
            let epsilon = 216.0 / 24389.0
            return value > epsilon ? pow(value, 1.0 / 3.0) : (841.0 / 108.0) * value + 4.0 / 29.0
        }
        let fx = f(x / white.x)
        let fy = f(y / white.y)
        let fz = f(z / white.z)
        let a = 500 * (fx - fy)
        let bStar = 200 * (fy - fz)
        return (a * a + bStar * bStar).squareRoot()
    }

    /// One pixel as red, green and blue, unpremultiplied, for a log line.
    private func describe(_ picture: WindowCapture.Pixels, _ rect: WindowCapture.Rect) -> String {
        let x = min(picture.width - 1, rect.midX)
        let y = min(picture.height - 1, rect.midY)
        let colour = picture.unpremultiplied(x, y)
        return String(format: "%.1f, %.1f, %.1f", colour.0, colour.1, colour.2)
    }

    // MARK: - The contact sheet

    /// One cell of the sheet: the card on its backdrop, at 1x.
    private func thumbnail(_ image: CGImage, box: WindowCapture.Rect) -> CGImage? {
        guard let cropped = image.cropping(to: CGRect(
            x: box.x,
            y: box.y,
            width: box.width,
            height: box.height
        )) else { return nil }
        let width = Int(Self.cardSize.width)
        let height = Int(Self.cardSize.height)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        return buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
    }

    /// The five backdrops side by side, labelled under each cell.
    private func writeSheet(_ cells: [(label: String, image: CGImage)], to url: URL) -> Bool {
        let cardWidth = Self.cardSize.width
        let cardHeight = Self.cardSize.height
        let gap = 12.0
        let margin = 12.0
        let titleHeight = 20.0
        let labelHeight = 12.0
        let labelGap = 5.0
        let cellHeight = cardHeight + labelGap + labelHeight
        let width = Int(margin * 2 + Double(cells.count) * (cardWidth + gap) - gap)
        let height = Int(margin * 2 + titleHeight + cellHeight)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else { return false }
        rep.size = NSSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let design = Self.design
        let title = "the shipped card: \(design.variant.rawValue) variant, scrim "
            + "\(decimal(design.scrim)), clock ink \(decimal(design.clock)), every cell at 1x"
        NSString(string: title).draw(
            in: NSRect(
                x: margin,
                y: Double(height) - margin - titleHeight,
                width: Double(width) - 2 * margin,
                height: titleHeight
            ),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(white: 0.2, alpha: 1),
            ]
        )
        for (index, cell) in cells.enumerated() {
            let x = margin + Double(index) * (cardWidth + gap)
            let bottom = margin
            let cardRect = NSRect(
                x: x,
                y: bottom + labelGap + labelHeight,
                width: cardWidth,
                height: cardHeight
            )
            NSImage(cgImage: cell.image, size: NSSize(width: cardWidth, height: cardHeight))
                .draw(in: cardRect)
            NSColor(white: 0.82, alpha: 1).setStroke()
            NSBezierPath(rect: cardRect.insetBy(dx: 0.25, dy: 0.25)).stroke()
            NSString(string: cell.label).draw(
                in: NSRect(x: x, y: bottom, width: cardWidth, height: labelHeight),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor(white: 0.32, alpha: 1),
                ]
            )
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url, options: .atomic)) != nil
    }

    /// A parameter as the file names and the sheet write it.
    private func decimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// The stem every file of one backdrop starts with.
    ///
    /// The layers that are no longer drawn keep their place in the name: the dim
    /// layer at 0.00 and the ink shadow at plain, so a capture from the decision
    /// sweep and a capture of the shipped card can be put side by side.
    private func fileStem(_ backdrop: Backdrop) -> String {
        let design = Self.design
        return "\(backdrop.rawValue)-\(design.variant.rawValue)-under0.00"
            + "-over\(decimal(design.scrim))-plain"
    }

    // MARK: - The record

    /// One row of the sweep's table.
    private struct Row {
        var backdrop: Backdrop
        var width: Int
        var height: Int
        var scale: Double
        var rec: Double
        var clock: Double
        var vividness: Double
        var cardChroma: Double
        var bareChroma: Double
        var refraction: Double
        var rim: Double
        var interior: Double
        var excluded: Double
        var alpha: Double
    }

    /// The card interior's mean absolute difference between the wave and the
    /// white page.
    ///
    /// The two pictures are read back from the files the sweep wrote, so the
    /// measurement is of exactly the pixels a reviewer opens rather than of a
    /// second render.
    private func measureRefraction(
        _ rows: inout [Row],
        scale: Double,
        directory: URL
    ) {
        for index in rows.indices where [.wave, .white].contains(rows[index].backdrop) {
            guard let wave = readPixels(directory.appendingPathComponent("\(fileStem(.wave)).png")),
                  let white = readPixels(directory.appendingPathComponent("\(fileStem(.white)).png"))
            else { continue }
            let box = WindowCapture.Rect.points(
                Self.cardRect,
                scaleX: CGFloat(wave.width) / Self.canvas.width,
                scaleY: CGFloat(wave.height) / Self.canvas.height
            )
            rows[index].refraction = WindowCapture.mad(wave, white, rect: inset(box, points: 2, scale: scale))
        }
    }

    /// A picture read back from a PNG, in the capture's own layout.
    private func readPixels(_ url: URL) -> WindowCapture.Pixels? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { return nil }
        return WindowCapture.pixels(from: cgImage)
    }

    /// The sweep's table, one row per backdrop.
    private func writeCSV(_ rows: [Row], to directory: URL, design: Design) throws {
        var text = "backdrop,variant,dim_below,scrim_above,ink_shadow,width_px,height_px,scale,"
            + "m1_rec,m1_clock,m2_vividness,m2_chroma_card,m2_chroma_backdrop,"
            + "m3_refraction,m4_rim,m4_interior,content_excluded,mean_alpha\n"
        for row in rows {
            text += String(
                format: "%@,%@,0.00,%.2f,no,%d,%d,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.1f\n",
                row.backdrop.rawValue,
                design.variant.rawValue,
                design.scrim,
                row.width,
                row.height,
                row.scale,
                row.rec,
                row.clock,
                row.vividness,
                row.cardChroma,
                row.bareChroma,
                row.refraction,
                row.rim,
                row.interior,
                row.excluded,
                row.alpha
            )
        }
        try text.write(
            to: directory.appendingPathComponent("sweep.csv"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Prints the table a reader compares against the tokens.
    private func report(_ rows: [Row], design: Design, directory: URL) {
        print("SWEEP wrote \(rows.count) captures and sweep.csv to \(directory.path)")
        print("SWEEP m1 is the REC label's WCAG ratio, m1_clock the clock's; m2 is the card "
            + "interior's chroma over the backdrop's own, 1.0 meaning the colour is fully preserved "
            + "and undefined for a backdrop with no chroma")
        print(String(
            format: "SWEEP variant %@, scrim %.2f, clock ink %.2f",
            design.variant.rawValue,
            design.scrim,
            design.clock
        ))
        print("SWEEP backdrop | m1 rec | m1 clock | m2 vividness | m3 refraction | m4 rim")
        for row in rows {
            print(String(
                format: "SWEEP %-12@ | %6.2f | %8.2f | %12@ | %13@ | %6.3f",
                row.backdrop.rawValue,
                row.rec,
                row.clock,
                row.vividness.isNaN ? "undefined" : String(format: "%.3f", row.vividness),
                row.refraction.isNaN ? "undefined" : String(format: "%.2f", row.refraction),
                row.rim
            ))
        }
    }
}
