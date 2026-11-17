import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// A style pill must end in a true half-circle.
///
/// A capsule's end is a circle of radius `height / 2`, and its border turns
/// through every row. A continuous corner style joins the two corner curves
/// with a step, which reads as a vertical tick where the curve meets the side.
/// The cause is the corner style, not the radius: the two are within half a
/// point of each other at the widest row.
///
/// The tests read the pixels the app draws. A pill is rendered offscreen at the
/// scale its window draws it, the border of each end is traced row by row, and
/// the trace is held to the circle a capsule has. The same probe runs against a
/// continuous capsule and a rounded rectangle, which must fail it: a probe that
/// cannot see the defect is not a regression test.
@MainActor
final class StylePillEndcapTests: XCTestCase {
    /// The points-to-pixels scale of every render here.
    private static let scale = 2
    /// The height of a style pill, in points, from the card's own layout.
    private static let pillHeight: CGFloat = 26
    /// The largest distance a drawn endcap may sit from its fitted circle.
    private static let maximumDeviation: CGFloat = 1.25
    /// The largest move the border may make between two neighbouring rows
    /// beyond what the curve's own rasterization explains.
    private static let maximumSeam: CGFloat = 1.75
    /// How far the fitted radius may sit from half the pill's height.
    private static let radiusTolerance: CGFloat = 1.0
    /// The directory the measured renders are written to, so a person can look
    /// at the pills a failure names. Nothing is read back from it.
    private static let evidence = URL(fileURLWithPath: "/tmp/dot-pill-endcaps", isDirectory: true)

    // MARK: - The shapes a pill can end in

    /// The endcap a fixture draws.
    private enum PillShape: String {
        /// The shape the card must use: `Capsule(style: .circular)`.
        case circular
        /// A continuous capsule, whose corner curves meet with a step.
        case continuous
        /// The other defect the same probe must catch: a rectangle's small radius.
        case roundedRectangle
    }

    /// A style pill with one endcap swapped, drawn as the card draws it.
    private struct PillFixture: View {
        let shape: PillShape

        var body: some View {
            HStack(spacing: 6) {
                Circle()
                    .fill(DotTheme.switchOn)
                    .frame(width: 6, height: 6)
                Text("Concise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DotTheme.ink)
            }
            .padding(.horizontal, 10)
            .frame(height: StylePillEndcapTests.pillHeight)
            .background(background)
        }

        @ViewBuilder private var background: some View {
            switch shape {
            case .circular:
                Capsule(style: .circular)
                    .fill(DotTheme.secondaryFill)
                    .overlay(
                        Capsule(style: .circular)
                            .strokeBorder(DotTheme.secondaryBorder, lineWidth: 1)
                    )
            case .continuous:
                Capsule(style: .continuous)
                    .fill(DotTheme.secondaryFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(DotTheme.secondaryBorder, lineWidth: 1)
                    )
            case .roundedRectangle:
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DotTheme.secondaryFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(DotTheme.secondaryBorder, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - The tests

    /// The probe accepts the shape the card must draw.
    ///
    /// Without this, a probe that rejected every pill would pass the two tests
    /// below and prove nothing.
    func testACircularCapsuleEndIsRound() throws {
        let bitmap = try renderFixture(.circular, named: "fixture-circular")
        let pill = try XCTUnwrap(pill(in: bitmap), "the fixture's pill was not found")
        for end in [End.left, .right] {
            let measured = try XCTUnwrap(endcap(of: end, in: bitmap, pill: pill), "\(end.name) endcap")
            assertRound(measured, of: "the circular fixture")
        }
    }

    /// A continuous capsule's end is rejected by the probe.
    ///
    /// It is within a fraction of a point of a circular capsule at the widest
    /// row, so a check of the radius alone would not catch it. Its border
    /// leaves the corner curve and reaches the flat of the end in one row, and
    /// that step is the seam the probe measures.
    func testAContinuousCapsuleEndIsRejected() throws {
        let bitmap = try renderFixture(.continuous, named: "fixture-continuous")
        let pill = try XCTUnwrap(pill(in: bitmap), "the fixture's pill was not found")
        let failures = [End.left, .right].compactMap { end -> Endcap? in
            guard let measured = endcap(of: end, in: bitmap, pill: pill) else { return nil }
            print("continuous fixture: \(measured.report)")
            return isRound(measured) ? nil : measured
        }
        XCTAssertFalse(
            failures.isEmpty,
            """
            a Capsule(style: .continuous) end passed the probe a circular capsule passes; \
            the probe cannot see the seam it exists to catch
            """
        )
    }

    /// A rounded rectangle's small radius is not a capsule, and the probe says so.
    func testARoundedRectangleEndIsRejected() throws {
        let bitmap = try renderFixture(.roundedRectangle, named: "fixture-rounded")
        let pill = try XCTUnwrap(pill(in: bitmap), "the fixture's pill was not found")
        let failures = [End.left, .right].compactMap { end -> Endcap? in
            guard let measured = endcap(of: end, in: bitmap, pill: pill) else { return nil }
            print("rounded fixture: \(measured.report)")
            return isRound(measured) ? nil : measured
        }
        XCTAssertFalse(failures.isEmpty, "a nine-point rounded rectangle passed the capsule probe")
    }

    /// Every style pill the Assistant page draws ends in a half-circle.
    ///
    /// The page is hosted offscreen and its pills are found from the green dots
    /// they draw, so this measures the shipped view and not a copy of it: a card
    /// that drew another shape fails here.
    func testEveryStylePillEndOnTheAssistantPageIsRound() throws {
        var config = DotConfig.default
        config.assistant.isSetUp = true
        config.assistant.chat = AssistantSettings(
            providerID: AssistantSettings.defaultProviderID,
            model: "gpt-4o-mini"
        )
        config.assistant.rewrite.enabled = true
        XCTAssertEqual(
            AssistantAvailability.readiness(config: config.assistant, hasKey: true),
            .ready,
            "the fixture's record cannot draw the Styles card"
        )
        XCTAssertTrue(
            AssistantPage.cards(config: config.assistant, hasKey: true).contains(.styles),
            "the page would not draw the Styles card"
        )

        let page = AssistantPage(
            config: .constant(config),
            onChange: {},
            onSetKey: { _, _ in nil },
            onDeleteKey: { _ in nil }
        )
        .environment(\.settingsHeadless, true)
        .environment(\.assistantKeyedProviders, [config.assistant.chat.resolvedProviderID])
        .environment(\.assistantConnectionPreview, .connected)
        .environment(\.assistantStyleSelectionPreview, .builtIn(.prompt))

        let bitmap = try render(page, size: CGSize(width: 640, height: 1400), named: "assistant-page")
        // The page draws green in a switch and in the status dot as well, so a
        // green pixel is not a pill until its border is around it.
        let dots = greenDots(in: bitmap)
        let pills = dots.compactMap { pill(around: $0, in: bitmap) }
        XCTAssertEqual(
            pills.count,
            RewriteStyleID.shippedCases.count,
            "the Styles card draws one pill per shipped style; \(pills.count) were measured"
        )

        for (index, pill) in pills.enumerated() {
            for end in [End.left, .right] {
                let measured = try XCTUnwrap(
                    endcap(of: end, in: bitmap, pill: pill),
                    "the \(end.name) end of pill \(index)"
                )
                assertRound(measured, of: "pill \(index) at \(pill), \(end.name) end")
            }
        }
    }

    // MARK: - What a round end is

    /// One end of a pill, read from the pixels of its border.
    private struct Endcap {
        /// Which end this is, for a failure message.
        let end: End
        /// The height the border was traced over, in points.
        let height: CGFloat
        /// The radius of the circle that best fits the trace, in points.
        let fittedRadius: CGFloat
        /// The furthest the trace sits from that circle, in points.
        let deviation: CGFloat
        /// The largest move between two neighbouring rows of the trace, in points.
        let seam: CGFloat

        /// The numbers a failure needs, in points.
        var report: String {
            String(
                format: "%@ end: radius %.2f of %.2f, deviation %.2f, seam %.2f",
                end.name,
                fittedRadius,
                height / 2,
                deviation,
                seam
            )
        }
    }

    /// A side of the pill.
    private enum End {
        case left, right

        var name: String { self == .left ? "left" : "right" }
    }

    /// The rectangle one pill's border occupies, in pixels.
    private struct PillBox: CustomStringConvertible {
        let left: Int
        let right: Int
        let top: Int
        let bottom: Int

        var description: String {
            "\(right - left + 1)x\(bottom - top + 1) at (\(left), \(top))"
        }
    }

    /// Whether a measured end is the half-circle a capsule draws.
    private func isRound(_ endcap: Endcap) -> Bool {
        abs(endcap.fittedRadius - endcap.height / 2) <= Self.radiusTolerance
            && endcap.deviation <= Self.maximumDeviation
            && endcap.seam <= Self.maximumSeam
    }

    /// Fails with the measured numbers when an end is not a half-circle.
    private func assertRound(_ endcap: Endcap, of what: String) {
        print("\(what): \(endcap.report)")
        XCTAssertLessThanOrEqual(
            abs(endcap.fittedRadius - endcap.height / 2),
            Self.radiusTolerance,
            "\(what) is not a capsule: \(endcap.report)"
        )
        XCTAssertLessThanOrEqual(
            endcap.deviation,
            Self.maximumDeviation,
            "\(what) does not follow its circle: \(endcap.report)"
        )
        XCTAssertLessThanOrEqual(
            endcap.seam,
            Self.maximumSeam,
            "\(what) has a vertical seam at its end: \(endcap.report)"
        )
    }

    // MARK: - Reading the pixels

    /// A rendered view, as pixel colours.
    private struct Bitmap {
        let width: Int
        let height: Int
        /// Red, green, blue, alpha, row by row.
        let pixels: [UInt8]

        /// The luminance at a pixel, `0` dark to `1` paper; `1` outside the bitmap.
        ///
        /// An offscreen hosting view has no window behind it, so the pixels it
        /// does not draw are transparent. They are paper here: a probe that
        /// read them as ink would flood the whole bitmap from the first
        /// transparent pixel and never find a border.
        func luminance(x: Int, y: Int) -> Double {
            guard x >= 0, x < width, y >= 0, y < height else { return 1 }
            let index = (y * width + x) * 4
            let ink = (
                0.299 * Double(pixels[index])
                    + 0.587 * Double(pixels[index + 1])
                    + 0.114 * Double(pixels[index + 2])
            ) / 255
            let alpha = Double(pixels[index + 3]) / 255
            return ink * alpha + (1 - alpha)
        }

        /// How much greener than red and blue a pixel is, `0` for a grey.
        func greenness(x: Int, y: Int) -> Double {
            guard x >= 0, x < width, y >= 0, y < height else { return 0 }
            let index = (y * width + x) * 4
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            return min(green - red, green - blue)
        }
    }

    /// Renders a pill fixture on the card's paper.
    private func renderFixture(_ shape: PillShape, named name: String) throws -> Bitmap {
        try render(
            PillFixture(shape: shape)
                .padding(12)
                .frame(width: 200, height: 50)
                .background(Color.white),
            size: CGSize(width: 200, height: 50),
            named: name
        )
    }

    /// Renders a view through an offscreen hosting view at ``scale``.
    ///
    /// The view never enters a window: `cacheDisplay` draws it into a bitmap of
    /// the size the bitmap is told it has, which is how a hairline border
    /// resolves at two pixels per point.
    private func render(_ view: some View, size: CGSize, named name: String) throws -> Bitmap {
        let host = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                // The ends are read as dark ink on light paper, so the render
                // fixes the appearance instead of taking the Mac's: the same
                // pixels are measured in every run.
                .environment(\.colorScheme, .light)
                .environment(\.displayScale, CGFloat(Self.scale))
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        // A window the window server never draws on a display: an offscreen
        // hosting view alone does not always finish its first layout, and a
        // half-drawn bitmap would be measured as a defect.
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * Self.scale,
                pixelsHigh: Int(size.height) * Self.scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        rep.size = size
        host.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)

        try? FileManager.default.createDirectory(
            at: Self.evidence,
            withIntermediateDirectories: true
        )
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: Self.evidence.appendingPathComponent("\(name).png"))
        }

        let data = try XCTUnwrap(rep.bitmapData)
        var pixels = [UInt8](repeating: 0, count: rep.pixelsWide * rep.pixelsHigh * 4)
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                let source = row + x * 4
                let index = (y * rep.pixelsWide + x) * 4
                // The bitmap is premultiplied, and a page hosted without a
                // window paints a translucent paper: the colour of a pixel is
                // its channel over its alpha, which is what the eye reads.
                let alpha = source[3]
                let gain = alpha == 0 ? 0 : 255 / Double(alpha)
                for channel in 0..<3 {
                    pixels[index + channel] = UInt8(min(255, Double(source[channel]) * gain))
                }
                pixels[index + 3] = alpha
            }
        }
        window.orderOut(nil)
        return Bitmap(width: rep.pixelsWide, height: rep.pixelsHigh, pixels: pixels)
    }

    /// The ink of a pill's border: the only dark hairline its ends have.
    private static let borderInk = 0.87

    private func isBorder(_ bitmap: Bitmap, _ x: Int, _ y: Int) -> Bool {
        // The dot is dark enough to pass for ink; it is not the border, and a
        // search that stopped on it would measure the dot instead of the pill.
        bitmap.luminance(x: x, y: y) < Self.borderInk
            && bitmap.greenness(x: x, y: y) < 0.15
    }

    /// The first border pixel walking from `from` towards `to`.
    private func firstBorder(
        _ bitmap: Bitmap,
        from: Int,
        to: Int,
        at fixed: Int,
        horizontal: Bool
    ) -> Int? {
        guard from != to else { return nil }
        let step = from < to ? 1 : -1
        var position = from
        while position != to {
            let x = horizontal ? position : fixed
            let y = horizontal ? fixed : position
            if isBorder(bitmap, x, y) { return position }
            position += step
        }
        return nil
    }

    /// The pill a green dot belongs to, when the dot is one of the card's.
    ///
    /// The dot sits ten points from the pill's leading edge, in the middle of
    /// its height, so the border is a short walk away on three sides. The
    /// fourth is found from the top border's own end: the horizontal hairline
    /// stops one radius short of the pill's right edge, which is where the
    /// trace of that end has to start from.
    private func pill(around dot: (x: Int, y: Int), in bitmap: Bitmap) -> PillBox? {
        // The walks start outside the dot's own antialiased rim, which is dark
        // enough to pass for ink, and stop short of anything but the border.
        guard let left = firstBorder(bitmap, from: dot.x - 12, to: dot.x - 44, at: dot.y, horizontal: true),
              let top = firstBorder(bitmap, from: dot.y - 12, to: dot.y - 44, at: dot.x, horizontal: false),
              let bottom = firstBorder(bitmap, from: dot.y + 12, to: dot.y + 44, at: dot.x, horizontal: false)
        else { return nil }
        let height = bottom - top + 1
        guard height >= 44, height <= 60 else { return nil }

        // The row of the top border's inner edge carries the horizontal
        // hairline across the pill, so its rightmost ink is one radius short of
        // the pill's right edge.
        let topRow = top
        // The horizontal hairline of this pill, up to the gap the next pill
        // leaves: the pills sit six points apart, so a light run of three
        // points is the end of this pill and not a hairline's antialiasing.
        var topRight = dot.x
        var x = dot.x + 8
        var gap = 0
        while x < min(bitmap.width - 1, dot.x + 500) {
            if isBorder(bitmap, x, topRow) {
                topRight = x
                gap = 0
            } else {
                gap += 1
                if gap > 6 { break }
            }
            x += 1
        }
        guard topRight > dot.x + 20 else { return nil }
        let radius = height / 2
        let right = topRight + radius + 4
        guard right < bitmap.width else { return nil }
        return PillBox(left: left, right: right, top: topRow, bottom: bottom)
    }

    /// The pill a green dot belongs to, when the dot is one of the card's.
    private func pill(in bitmap: Bitmap) -> PillBox? {
        guard let dot = greenDots(in: bitmap).first else { return nil }
        return pill(around: dot, in: bitmap)
    }

    /// The green dots the pills draw, in pixels.
    private func greenDots(in bitmap: Bitmap) -> [(x: Int, y: Int)] {
        var seen = [Bool](repeating: false, count: bitmap.width * bitmap.height)
        var centres: [(x: Int, y: Int)] = []
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let index = y * bitmap.width + x
                guard !seen[index], isGreen(bitmap, x, y) else { continue }
                var stack = [(x, y)]
                seen[index] = true
                var minX = x, maxX = x, minY = y, maxY = y, count = 0
                while let (px, py) = stack.popLast() {
                    count += 1
                    minX = min(minX, px)
                    maxX = max(maxX, px)
                    minY = min(minY, py)
                    maxY = max(maxY, py)
                    for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)] {
                        guard nx >= 0, nx < bitmap.width, ny >= 0, ny < bitmap.height else { continue }
                        let neighbour = ny * bitmap.width + nx
                        guard !seen[neighbour], isGreen(bitmap, nx, ny) else { continue }
                        seen[neighbour] = true
                        stack.append((nx, ny))
                    }
                }
                let w = maxX - minX + 1
                let h = maxY - minY + 1
                // A pill's dot is six points: twelve pixels across at this scale.
                if count >= 40, w >= 8, w <= 18, h >= 8, h <= 18, abs(w - h) <= 3 {
                    centres.append((x: (minX + maxX) / 2, y: (minY + maxY) / 2))
                }
            }
        }
        return centres
    }

    /// Whether a pixel is the colour of a style pill's dot.
    private func isGreen(_ bitmap: Bitmap, _ x: Int, _ y: Int) -> Bool {
        bitmap.greenness(x: x, y: y) > 0.15 && bitmap.luminance(x: x, y: y) < 0.8
    }

    // MARK: - The measurement

    /// Traces one end of the pill and fits the circle a capsule draws there.
    ///
    /// For every row the pill occupies, the trace is the first border pixel
    /// walking in from outside the end. A capsule's trace is `x = cx - sqrt(r² -
    /// dy²)` with `r` half the height; a rounded rectangle's is a smaller circle
    /// joined to a vertical side; a continuous capsule's is the circle with a
    /// step where its two corner curves meet.
    private func endcap(of end: End, in bitmap: Bitmap, pill: PillBox) -> Endcap? {
        let reach = Int(Self.pillHeight) * Self.scale
        var trace: [(row: Int, x: Int)] = []
        let firstRow = max(0, pill.top - 3)
        let lastRow = min(bitmap.height - 1, pill.bottom + 3)
        for y in firstRow...lastRow {
            var found = -1
            switch end {
            case .left:
                var x = max(0, pill.left - 3)
                while x <= min(bitmap.width - 1, pill.left + reach) {
                    if isBorder(bitmap, x, y) { found = x; break }
                    x += 1
                }
            case .right:
                var x = min(bitmap.width - 1, pill.right)
                while x >= max(0, pill.right - reach) {
                    if isBorder(bitmap, x, y) { found = x; break }
                    x -= 1
                }
            }
            if found >= 0 { trace.append((row: y, x: found)) }
        }
        guard trace.count >= 40 else { return nil }
        // The trace is the outer edge of the border, so it is the whole height
        // of the pill: the circle's centre is half-way between its first and
        // last row, and its radius is half of that span.
        let height = CGFloat(trace.count) / CGFloat(Self.scale)
        let centreRow = (CGFloat(trace[0].row) + CGFloat(trace[trace.count - 1].row)) / 2

        // A circle centred on the pill's vertical axis, fitted by least squares:
        // z² + t² = 2·cx·z + (r² - cx²), with `t` the row's distance from the
        // centre. Solving for (cx, r² - cx²) is a two-column regression.
        let z = trace.map { CGFloat($0.x) }
        let t = trace.map { CGFloat($0.row) - CGFloat(centreRow) }
        var szz = 0.0, sz = 0.0, szb = 0.0, s1b = 0.0
        let n = Double(trace.count)
        for index in trace.indices {
            let zi = z[index]
            let bi = zi * zi + t[index] * t[index]
            szz += zi * zi
            sz += zi
            szb += zi * bi
            s1b += bi
        }
        let determinant = szz * n - sz * sz
        guard abs(determinant) > 0.0001 else { return nil }
        let centreX = ((szb * n - sz * s1b) / determinant) / 2
        let constant = (s1b * szz - szb * sz) / determinant
        let squaredRadius = constant + centreX * centreX
        guard squaredRadius > 0 else { return nil }
        let radius = sqrt(squaredRadius)

        var deviation = 0.0
        var seam = 0.0
        for index in trace.indices {
            let distance = hypot(z[index] - centreX, t[index])
            deviation = max(deviation, abs(distance - radius))
            // The two rows at each apex move three pixels on a true circle,
            // because the tangent is vertical there; a seam is a step anywhere
            // else, so the apex rows are not where it is looked for.
            guard index > 2, index < trace.count - 2 else { continue }
            seam = max(seam, abs(z[index] - z[index - 1]))
        }
        let points = CGFloat(Self.scale)
        return Endcap(
            end: end,
            height: height,
            fittedRadius: radius / points,
            deviation: deviation / points,
            seam: seam / points
        )
    }
}
