import AppKit
import DotCore
import SwiftUI
import XCTest

@testable import Dot

/// The chip row when the styles outgrow the card.
///
/// The row is hosted offscreen: no window and no display. The questions are
/// mechanical: does the row keep the 24 point height the card budgets, is it
/// built on a scroll view, is every style in its content, and does the fade at
/// its edge appear only when there is more to reach.
@MainActor
final class HUDRewriteChipRowTests: XCTestCase {
    /// The app's typeface, registered before the first view is built.
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    /// The card's content width: 560 minus the 16 point padding on each side.
    private let available: CGFloat = HUDState.transcriptWidth - HUDTheme.padding * 2

    /// The longest row the catalogue allows: every shipped style and six
    /// custom ones at the title cap.
    private func twelveStyles() -> [RewriteStyle] {
        let custom = (0 ..< 6).map { index in
            RewriteStyle(
                CustomRewriteStyle(
                    id: "custom-\(index)",
                    title: String(repeating: "W", count: CustomRewriteStyle.maximumTitleLength),
                    instruction: "Rewrite."
                )
            )
        }
        return RewriteStyle.builtIns + custom
    }

    /// A row of seven short styles: the five shipped ones and two custom labels.
    private func shortStyles() -> [RewriteStyle] {
        let custom = [
            CustomRewriteStyle(id: "haiku", title: "Haiku", instruction: "Rewrite as a haiku."),
            CustomRewriteStyle(id: "email", title: "Email", instruction: "Rewrite for email."),
        ]
        return RewriteStyle.builtIns + custom.map(RewriteStyle.init)
    }

    private func host(
        _ styles: [RewriteStyle],
        height: CGFloat = HUDRewriteLayout.chipHeight,
        activeStyleID: String? = nil,
        isStreaming: Bool = false,
        time: Double = 1.1,
        versions: [RewriteVersion] = [],
        selectedVersionID: Int = 0,
        onRerun: (() -> Void)? = nil,
        rowWidth: CGFloat? = nil,
        drawsOverflowFade: Bool = true
    ) -> NSHostingView<AnyView> {
        let width = rowWidth ?? available
        let row = RewriteChipRow(
            choices: styles,
            activeStyleID: activeStyleID,
            isStreaming: isStreaming,
            reduceMotion: true,
            time: time,
            versions: versions,
            selectedVersionID: selectedVersionID,
            drawsOverflowFade: drawsOverflowFade,
            onSelect: { _ in },
            onRerun: onRerun
        )
        .frame(width: width)
        let host = NSHostingView(rootView: AnyView(row))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// A hosted row once its own measurement has come back.
    ///
    /// The row measures the style viewport with a preference key and only then
    /// decides whether the chevron needs its slot, so the first layout pass
    /// draws it without one. The run loop is pumped here and no window is
    /// ordered anywhere: the second pass is the layout the card gets.
    private func settledHost(
        _ styles: [RewriteStyle],
        activeStyleID: String? = nil,
        isStreaming: Bool = false,
        time: Double = 1.1,
        versions: [RewriteVersion] = [],
        selectedVersionID: Int = 0,
        onRerun: (() -> Void)? = nil,
        rowWidth: CGFloat? = nil,
        drawsOverflowFade: Bool = true
    ) -> NSHostingView<AnyView> {
        let host = host(
            styles,
            activeStyleID: activeStyleID,
            isStreaming: isStreaming,
            time: time,
            versions: versions,
            selectedVersionID: selectedVersionID,
            onRerun: onRerun,
            rowWidth: rowWidth,
            drawsOverflowFade: drawsOverflowFade
        )
        for _ in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }

    /// Scrolls the row so a style past the first screen starts inside the
    /// viewport, which is how a frame of the long labels is taken.
    private func scrollRow(_ host: NSView, styles: [RewriteStyle], toStyleAt index: Int) throws {
        let before = RewriteChipMetrics.rowWidth(Array(styles.prefix(index).map(\.title)))
        let target = max(0, before + (index > 0 ? HUDRewriteLayout.chipGap : 0) - 8)
        try scrollRow(host, toContentX: target)
    }

    /// Scrolls the row's styles to a content offset, in points.
    private func scrollRow(_ host: NSView, toContentX x: CGFloat) throws {
        let scroll = try XCTUnwrap(scrollView(in: host), "the row has no scroll view")
        scroll.contentView.scroll(to: NSPoint(x: max(0, x), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
    }

    /// The row's pixels at the two pixels per point its assertions are written
    /// against, whatever scale the display the suite runs on has: a rep AppKit
    /// makes for the window comes back at the display's own scale, which is one
    /// pixel per point on a display that is not Retina.
    private func bitmap(of host: NSView) -> NSBitmapImageRep? {
        bitmap(of: host, scale: 2)
    }

    /// A view's pixels at a chosen scale, for a frame a reviewer will open.
    private func bitmap(of view: NSView, scale: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Non-transparent samples in the trailing strip the fade occupies.
    private func trailingInk(_ rep: NSBitmapImageRep) -> Int {
        let strip = Int((HUDRewriteLayout.chipOverflowWidth * 2).rounded())
        var inked = 0
        for x in max(0, rep.pixelsWide - strip) ..< rep.pixelsWide {
            for y in 0 ..< rep.pixelsHigh {
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.05 {
                    inked += 1
                }
            }
        }
        return inked
    }

    // MARK: - Fixtures and frames

    /// Where the row's frames are written, at two pixels per point.
    ///
    /// `DOT_HUD_FRAMES_DIR` keeps them somewhere a reviewer will look; a run
    /// without it gets its own directory under the system's temporary one.
    private static let evidence: URL = {
        if let override = ProcessInfo.processInfo.environment["DOT_HUD_FRAMES_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-chip-row-frames-\(UUID().uuidString)", isDirectory: true)
    }()

    private func write(_ bitmap: NSBitmapImageRep, named name: String) throws {
        try FileManager.default.createDirectory(
            at: Self.evidence,
            withIntermediateDirectories: true
        )
        let url = Self.evidence.appendingPathComponent("\(name).png")
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url, options: .atomic)
        print("HUDRewriteChipRowTests frame: \(url.path)")
    }

    /// A row that has produced a version: the selected chip, the rerun control
    /// and a count on the chip that ran.
    private func doneVersions() -> [RewriteVersion] {
        [
            RewriteVersion.original(text: "The words the styles were offered for."),
            RewriteVersion(
                id: 1,
                origin: .style(RewriteStyle.concise.id),
                title: RewriteStyle.concise.title,
                text: "The words, tightened.",
                ordinal: 1
            ),
        ]
    }

    /// The longest labels the catalogue allows, in the scripts a person writes.
    ///
    /// A chip is measured with the font it is drawn in, so a title the system
    /// font falls back for is the case that can outgrow the row without any
    /// Latin label showing it.
    private func longAndNonLatinStyles() -> [RewriteStyle] {
        let customs = [
            CustomRewriteStyle(
                id: "custom-long",
                title: "Zusammenfassung für Mail",
                instruction: "Rewrite."
            ),
            CustomRewriteStyle(id: "custom-ja", title: "正式な文体で要約", instruction: "Rewrite."),
            CustomRewriteStyle(id: "custom-zh", title: "正式书面语改写", instruction: "Rewrite."),
            CustomRewriteStyle(id: "custom-ar", title: "أسلوب رسمي", instruction: "Rewrite."),
            CustomRewriteStyle(id: "custom-ko", title: "공식적인 문체", instruction: "Rewrite."),
            CustomRewriteStyle(id: "custom-el", title: "Επίσημο ύφος", instruction: "Rewrite."),
        ]
        return RewriteStyle.builtIns + customs.map(RewriteStyle.init)
    }

    /// How many pixels two frames of the same size disagree about.
    private func differingPixels(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Int {
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else {
            return first.pixelsWide * first.pixelsHigh
        }
        var count = 0
        for y in 0 ..< first.pixelsHigh {
            for x in 0 ..< first.pixelsWide {
                guard let one = first.colorAt(x: x, y: y), let two = second.colorAt(x: x, y: y) else {
                    continue
                }
                let delta = abs(one.redComponent - two.redComponent)
                    + abs(one.greenComponent - two.greenComponent)
                    + abs(one.blueComponent - two.blueComponent)
                if delta > 0.01 { count += 1 }
            }
        }
        return count
    }

    /// How many pixels two frames disagree about outside one column range.
    ///
    /// It answers whether a change stayed inside the control it belongs to: a
    /// chip whose processing state reached a neighbour, a label or the row's
    /// height fails here even when its own pixels are right.
    private func differingPixels(
        _ first: NSBitmapImageRep,
        _ second: NSBitmapImageRep,
        leavingOut cols: Range<Int>,
        ofWidth width: Int
    ) -> Int {
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else {
            return width * first.pixelsHigh
        }
        var count = 0
        for y in 0 ..< first.pixelsHigh {
            for x in 0 ..< first.pixelsWide where !cols.contains(x) {
                guard let one = first.colorAt(x: x, y: y), let two = second.colorAt(x: x, y: y) else {
                    continue
                }
                let delta = abs(one.redComponent - two.redComponent)
                    + abs(one.greenComponent - two.greenComponent)
                    + abs(one.blueComponent - two.blueComponent)
                if delta > 0.01 { count += 1 }
            }
        }
        return count
    }

    /// The box the brightest ink of a rectangle covers.
    ///
    /// The label is the brightest thing in a chip, whatever colour it is drawn
    /// in, so the box of everything above a third of the way to white is the
    /// box of the name.
    private func inkBounds(
        in rows: Range<Int>,
        cols: Range<Int>,
        of bitmap: NSBitmapImageRep
    ) -> (rows: Range<Int>, cols: Range<Int>)? {
        var minRow = bitmap.pixelsHigh
        var maxRow = -1
        var minCol = bitmap.pixelsWide
        var maxCol = -1
        for y in rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in cols where x >= 0 && x < bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                let luminance = 0.2126 * Double(colour.redComponent)
                    + 0.7152 * Double(colour.greenComponent)
                    + 0.0722 * Double(colour.blueComponent)
                guard luminance > 0.30 else { continue }
                minRow = min(minRow, y)
                maxRow = max(maxRow, y)
                minCol = min(minCol, x)
                maxCol = max(maxCol, x)
            }
        }
        guard maxRow >= 0, maxCol >= 0 else { return nil }
        return (minRow ..< (maxRow + 1), minCol ..< (maxCol + 1))
    }

    /// How many pixels of a rectangle are a strong amber rather than a wash.
    private func brightAmberPixels(
        in rows: Range<Int>,
        cols: Range<Int>,
        of bitmap: NSBitmapImageRep
    ) -> Int {
        var count = 0
        for y in rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in cols where x >= 0 && x < bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                let red = Double(colour.redComponent)
                let green = Double(colour.greenComponent)
                let blue = Double(colour.blueComponent)
                if red > 0.55, red >= green, green >= blue, (red - blue) / red > 0.40 {
                    count += 1
                }
            }
        }
        return count
    }

    /// Non-transparent samples of a row, sampled every other pixel.
    private func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        var inked = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.05 {
                    inked += 1
                }
            }
        }
        return inked
    }

    /// The strongest alpha in a column range of the row's whole height.
    ///
    /// The mask takes the content away rather than painting over it, so an
    /// alpha of zero is the only reading that means "nothing of the chip is
    /// drawn here". A single surviving pixel of a glyph fails it.
    private func strongestInk(
        _ bitmap: NSBitmapImageRep,
        from start: CGFloat,
        to end: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        var strongest: CGFloat = 0
        var points = start
        while points <= end {
            let x = min(max(Int((points * scale).rounded()), 0), bitmap.pixelsWide - 1)
            for y in 0 ..< bitmap.pixelsHigh {
                strongest = max(strongest, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
            points += 0.5
        }
        return strongest
    }

    /// The weakest column in a column range of the row's whole height.
    ///
    /// It answers whether a whole strip sits on drawn content rather than the
    /// card's surface: every sampled column has to carry some alpha, and the
    /// least of those columns is the strip's weakest point.
    private func minimumInk(
        _ bitmap: NSBitmapImageRep,
        from start: CGFloat,
        to end: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        var weakest: CGFloat = 1
        var points = start
        while points <= end {
            let x = min(max(Int((points * scale).rounded()), 0), bitmap.pixelsWide - 1)
            var strongest: CGFloat = 0
            for y in 0 ..< bitmap.pixelsHigh {
                strongest = max(strongest, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
            weakest = min(weakest, strongest)
            points += 0.5
        }
        return weakest
    }

    // MARK: - The row's width

    func testTheShippedChipsFitAndTheLongestRowDoesNot() {
        let shipped = RewriteStyle.builtIns
        XCTAssertEqual(
            shipped.map(\.title),
            ["Agent prompt", "Concise", "Professional", "Casual", "Gen Z"]
        )
        let builtIns = RewriteChipRow.contentWidth(for: shipped)
        XCTAssertFalse(
            RewriteChipRow.overflows(contentWidth: builtIns, viewportWidth: available),
            "the five shipped chips fit without a fade"
        )

        let longest = RewriteChipRow.contentWidth(for: twelveStyles())
        XCTAssertTrue(
            RewriteChipRow.overflows(contentWidth: longest, viewportWidth: available),
            "eleven chips fit in one row only if they were clipped"
        )
        XCTAssertFalse(RewriteChipRow.overflows(contentWidth: 0, viewportWidth: 0))
    }

    /// Seven short styles fit the card but not the room the pinned controls
    /// leave the styles, which is why the decision is measured against the
    /// viewport.
    func testSevenShortStylesFitTheCardAndOverflowTheStyleViewport() {
        let short = shortStyles()
        XCTAssertEqual(short.count, 7)
        let content = RewriteChipRow.contentWidth(for: short)
        XCTAssertLessThanOrEqual(content, available, "seven short styles fit the whole row")
        let viewport = available - RewriteChipRow.pinnedWidth(showsRerun: false)
        XCTAssertTrue(
            RewriteChipRow.overflows(contentWidth: content, viewportWidth: viewport),
            "seven styles fit the card only if the Original chip and the arrows took no room"
        )
    }

    /// Six custom labels at the 24 character cap alone are wider than the card.
    func testSixMaximumLengthCustomLabelsOverflowTheCard() {
        let customs = twelveStyles().suffix(6)
        XCTAssertEqual(customs.count, 6)
        XCTAssertTrue(customs.allSatisfy { $0.title.count == 24 })
        let needed = RewriteChipMetrics.rowWidth(customs.map(\.title))
        XCTAssertGreaterThan(
            needed,
            available,
            "six 24-character labels need \(needed) pt of a \(available) pt card"
        )
    }

    func testTheRowContentIncludesEveryStyleAndTheTrailingRoom() {
        let styles = twelveStyles()
        let chips = RewriteChipMetrics.rowWidth(styles.map(\.title))
        XCTAssertEqual(
            RewriteChipRow.contentWidth(for: styles),
            chips + HUDRewriteLayout.chipOverflowWidth,
            accuracy: 0.5,
            "the row's content is not every chip plus the room the last one needs"
        )
    }

    // MARK: - The real row, offscreen

    func testTheRowKeepsItsHeightAndIsScrollable() throws {
        let host = host(twelveStyles())
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            host.fittingSize.height,
            HUDRewriteLayout.chipHeight,
            accuracy: 1,
            "the scroll row spent the card's height"
        )
        XCTAssertNotNil(
            scrollView(in: host),
            "the chip row is not built on a scroll view, so a twelfth style would clip"
        )
    }

    func testTheFullRowRendersOffscreenWithInk() throws {
        let host = host(twelveStyles())
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(bitmap(of: host), "the row could not be drawn offscreen")
        XCTAssertEqual(bitmap.pixelsWide, Int(available * 2), "the row was not drawn at its width")
        XCTAssertEqual(
            bitmap.pixelsHigh,
            Int(HUDRewriteLayout.chipHeight * 2),
            "the row was drawn taller than one chip line"
        )

        var inked = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                if let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.05 {
                    inked += 1
                }
            }
        }
        XCTAssertGreaterThan(inked, 200, "the rendered row is blank")
    }

    /// A running chip keeps its name and says it is the one working.
    ///
    /// The chip that is arriving draws its own name in place, at the same width
    /// and the same height, and answers the click it already had. What changes
    /// is its colour: the card's amber label on a breathing amber outline. The
    /// row is compared pixel for pixel, so a label that was shortened, moved or
    /// replaced by dots fails here, and a change that spilled onto a neighbour
    /// fails too.
    func testTheRunningChipDrawsItsNameAndItsProcessingState() throws {
        let idle = try XCTUnwrap(bitmap(of: settledHost(RewriteStyle.builtIns)))
        let running = try XCTUnwrap(bitmap(of: settledHost(
            RewriteStyle.builtIns,
            activeStyleID: RewriteStyle.concise.id,
            isStreaming: true
        )))
        XCTAssertGreaterThan(
            inkedPixels(idle),
            200,
            "the row is blank, so the comparison proves nothing"
        )
        XCTAssertEqual(idle.pixelsWide, running.pixelsWide, "the row changed width")
        XCTAssertEqual(idle.pixelsHigh, running.pixelsHigh, "the row changed height")

        // The running chip is the second style in the scrolling content, one
        // gap after the first. The row is hosted on its own, so its leading
        // edge is the host's zero: the card's horizontal padding is applied
        // outside this view and is not part of this frame. The pinned controls
        // come from the row's own slot arithmetic rather than from a copy of
        // it, and the chevron's slot comes out of the viewport's width, not
        // out of its origin.
        let slots = RewriteChipRow.slots(
            rowWidth: available,
            showsRerun: false,
            overflows: false
        )
        let leading = slots.viewportOrigin
            + RewriteChipMetrics.chipWidth(RewriteStyle.builtIns[0].title)
            + HUDRewriteLayout.chipGap
        let chipLeft = Int((leading * 2).rounded())
        let chipRight = Int(((leading + RewriteChipMetrics.chipWidth(
            RewriteStyle.builtIns[1].title
        )) * 2).rounded())
        let chip = chipLeft ..< chipRight
        let inner = (chipLeft + 4) ..< (chipRight - 4)
        let rows = 0 ..< running.pixelsHigh

        // The name is measured in both frames. The rect is arithmetic, so it is
        // pinned to the drawn chip first: the capsule's fill is the first ink
        // before the name and its left edge is the chip's own left edge, which
        // is why the window starts inside the gap and not at the chip. A rect
        // that drifted onto a neighbour fails here rather than satisfying every
        // comparison below and proving nothing.
        let idleLabel = try XCTUnwrap(
            inkBounds(in: rows, cols: inner, of: idle),
            "the style's name is not drawn at all"
        )
        let capsuleLeft = try XCTUnwrap(
            inkBounds(in: rows, cols: (chipLeft - 6) ..< (chipRight - 4), of: idle)?
                .cols.lowerBound,
            "no chip is drawn where the running one is measured"
        )
        XCTAssertEqual(
            capsuleLeft,
            chipLeft,
            accuracy: 2,
            "the measured chip rect is not where the row draws the chip"
        )
        let runningLabel = try XCTUnwrap(
            inkBounds(in: rows, cols: inner, of: running),
            "the running chip draws no name"
        )
        // The name is the same glyphs in the same place: the ink covers the
        // same box whether the chip is idle or running, so the processing state
        // changed its colour and not its words.
        XCTAssertEqual(
            runningLabel.cols.lowerBound,
            idleLabel.cols.lowerBound,
            accuracy: 2,
            "the running chip's name moved"
        )
        XCTAssertEqual(
            runningLabel.cols.upperBound,
            idleLabel.cols.upperBound,
            accuracy: 2,
            "the running chip's name is a different width"
        )
        XCTAssertEqual(
            runningLabel.rows.lowerBound,
            idleLabel.rows.lowerBound,
            accuracy: 2,
            "the running chip's name is a different height"
        )
        XCTAssertEqual(
            runningLabel.rows.upperBound,
            idleLabel.rows.upperBound,
            accuracy: 2,
            "the running chip's name is a different height"
        )

        // The amber is the running chip's, and the card's other labels keep
        // theirs.
        XCTAssertGreaterThan(
            brightAmberPixels(in: rows, cols: chip, of: running),
            40,
            "the running chip is not drawn in the card's amber"
        )
        XCTAssertEqual(
            brightAmberPixels(in: rows, cols: chip, of: idle),
            0,
            "an idle chip is drawn in the card's amber"
        )
        try write(idle, named: "evidence-running-chip-idle")
        try write(running, named: "evidence-running-chip-live")
        let outside = differingPixels(
            idle,
            running,
            leavingOut: chip,
            ofWidth: idle.pixelsWide
        )
        XCTAssertEqual(
            outside,
            0,
            "the processing state changed \(outside) pixels outside the running chip"
        )
    }

    /// The row keeps its one line, and the pinned original and arrows still
    /// leave a style viewport wide enough to be usable.
    func testThePinnedControlsLeaveAResolvableStyleViewport() {
        let pinned = RewriteChipRow.pinnedWidth(showsRerun: false)
        let viewport = available - pinned
        XCTAssertGreaterThan(viewport, 240, "the pinned controls left \(viewport) pt for styles")
        XCTAssertEqual(
            RewriteChipRow.pinnedWidth(showsRerun: true) - pinned,
            HUDRewriteLayout.versionArrowWidth + HUDRewriteLayout.chipGap,
            accuracy: 0.5,
            "the rerun control changed the row by more than its own width"
        )
    }

    /// A six-style row and the longest row both make the same decision from the
    /// measured viewport, not from a guess about what SwiftUI clipped.
    func testTheOverflowDecisionIsMadeAgainstTheStyleViewport() {
        let viewport = available - RewriteChipRow.pinnedWidth(showsRerun: false)
        XCTAssertTrue(
            RewriteChipRow.overflows(
                contentWidth: RewriteChipRow.contentWidth(for: shortStyles()),
                viewportWidth: viewport
            ),
            "the pinned controls did not take any room from the scrolling styles"
        )
        XCTAssertTrue(
            RewriteChipRow.overflows(
                contentWidth: RewriteChipRow.contentWidth(for: twelveStyles()),
                viewportWidth: viewport
            )
        )
        XCTAssertFalse(
            RewriteChipRow.overflows(
                contentWidth: RewriteChipRow.contentWidth(for: RewriteStyle.builtIns),
                viewportWidth: viewport
            ),
            "the five shipped chips claimed they had more to show"
        )
        XCTAssertFalse(
            RewriteChipRow.overflows(contentWidth: 0, viewportWidth: viewport),
            "an empty row claimed it had more to show"
        )
    }

    // MARK: - The overflow slot

    /// The chevron is drawn in its own slot: the styles are clipped before it,
    /// so the label of the last visible chip cannot run under the mark.
    func testTheOverflowSlotStartsWhereTheChipsClipEnds() {
        let slots = RewriteChipRow.slots(rowWidth: available, showsRerun: false, overflows: true)
        XCTAssertEqual(
            slots.overflowWidth,
            HUDRewriteLayout.chipOverflowSlotWidth,
            "an overflowing row drew no slot for the chevron"
        )
        XCTAssertGreaterThan(slots.viewportWidth, 240, "the slot ate the styles' room")
        XCTAssertLessThanOrEqual(
            slots.viewportMaxX,
            slots.overflowOrigin,
            "the chevron's slot starts at \(slots.overflowOrigin) pt, inside the clip that ends at \(slots.viewportMaxX) pt"
        )
        XCTAssertEqual(
            slots.overflowOrigin - slots.viewportMaxX,
            HUDRewriteLayout.chipGap,
            accuracy: 0.001,
            "the slot does not start one row gap after the clip"
        )
        XCTAssertEqual(
            slots.overflowMaxX,
            available - HUDRewriteLayout.chipGap - HUDRewriteLayout.versionArrowWidth,
            accuracy: 0.5,
            "the slot did not end one row gap before the next-version arrow"
        )
    }

    /// The slot comes out of the styles, not out of the pinned controls: the
    /// arrows and the rerun keep their width and their place at the trailing
    /// edge whether or not the chevron is drawn.
    func testTheOverflowSlotIsTakenFromTheStylesOnly() {
        let fitting = RewriteChipRow.slots(rowWidth: available, showsRerun: true, overflows: false)
        let wide = RewriteChipRow.slots(rowWidth: available, showsRerun: true, overflows: true)
        XCTAssertEqual(fitting.overflowWidth, 0, "a row that fits reserved a slot for nothing")
        XCTAssertEqual(
            fitting.viewportOrigin,
            wide.viewportOrigin,
            accuracy: 0.001,
            "the slot moved the original or the previous-version arrow"
        )
        XCTAssertEqual(
            fitting.viewportWidth,
            available - RewriteChipRow.pinnedWidth(showsRerun: true),
            accuracy: 0.5,
            "the row without the chevron does not start the styles where the pinned controls end"
        )
        XCTAssertEqual(
            fitting.viewportWidth - wide.viewportWidth,
            HUDRewriteLayout.chipGap + HUDRewriteLayout.chipOverflowSlotWidth,
            accuracy: 0.001,
            "the slot did not come out of the style viewport"
        )
        XCTAssertLessThanOrEqual(
            wide.overflowMaxX,
            available - HUDRewriteLayout.chipGap - HUDRewriteLayout.versionArrowWidth,
            "the slot reaches under the next-version arrow"
        )
    }

    /// The real row, laid out offscreen: the styles are clipped one row gap
    /// before the chevron's slot, which is where it is drawn.
    func testTheLaidOutRowClipsTheStylesBeforeTheChevronSlot() throws {
        let host = settledHost(twelveStyles())
        let scroll = try XCTUnwrap(
            scrollView(in: host),
            "the chip row has no scroll view, so nothing clips the styles"
        )
        let clip = scroll.convert(scroll.bounds, to: host)
        let slots = RewriteChipRow.slots(rowWidth: available, showsRerun: false, overflows: true)
        XCTAssertEqual(
            clip.minX,
            slots.viewportOrigin,
            accuracy: 1,
            "the styles do not start where the original ends"
        )
        XCTAssertEqual(
            clip.width,
            slots.viewportWidth,
            accuracy: 1,
            "the styles are not clipped to the width the slot leaves them"
        )
        XCTAssertLessThanOrEqual(
            clip.maxX,
            slots.overflowOrigin + 0.5,
            "the styles are still laid out under the chevron's slot"
        )
        XCTAssertEqual(
            clip.maxX,
            slots.viewportMaxX,
            accuracy: 1,
            "the clip ends somewhere other than the slot's leading edge"
        )
    }

    /// The overflow mark keeps its distance from both sides.
    ///
    /// The mark is centred in its slot, so the clearance is the row's gap plus
    /// the room the slot leaves around the mark's frame. It has to stay clear of
    /// the clip it points past and of the next-version button after it.
    func testTheOverflowMarkKeepsItsDistanceFromTheClipAndTheArrow() {
        let slots = RewriteChipRow.slots(rowWidth: available, showsRerun: false, overflows: true)
        let markOrigin = slots.overflowOrigin
            + (slots.overflowWidth - RewriteChipRow.overflowMarkWidth) / 2
        let markEnd = markOrigin + RewriteChipRow.overflowMarkWidth
        let arrowOrigin = slots.overflowMaxX + HUDRewriteLayout.chipGap

        XCTAssertLessThanOrEqual(
            RewriteChipRow.overflowMarkWidth,
            slots.overflowWidth,
            "the mark is wider than the slot it is drawn in"
        )
        XCTAssertEqual(
            RewriteChipRow.overflowClearance,
            markOrigin - slots.viewportMaxX,
            accuracy: 0.001,
            "the clearance the row promises is not the clearance it draws"
        )
        XCTAssertGreaterThanOrEqual(
            markOrigin - slots.viewportMaxX,
            RewriteChipRow.minimumOverflowClearance,
            "the overflow mark starts \(markOrigin - slots.viewportMaxX) pt from the clip"
        )
        XCTAssertGreaterThanOrEqual(
            arrowOrigin - markEnd,
            RewriteChipRow.minimumOverflowClearance,
            "the overflow mark ends \(arrowOrigin - markEnd) pt before the next-version arrow"
        )
    }

    /// The clip does not cut a label.
    ///
    /// The styles are masked to clear over their last points, so a column at
    /// the edge of the viewport carries less of the row than the same column
    /// 24 points inside it, and less again than one at the start of the fade.
    /// A row that hard-clipped its content would report the same column at all
    /// three places.
    ///
    /// The reading is the mean alpha of the column over the row's whole height,
    /// which is the capsule's fill plus whatever of the label crosses it: it
    /// does not depend on which way the bitmap is stored, and taking the
    /// strongest column in a short window keeps a glyph edge or the gap between
    /// two chips from being mistaken for the fade.
    func testTheMaskDissolvesTheStylesBeforeTheClip() throws {
        let host = settledHost(twelveStyles())
        let bitmap = try XCTUnwrap(bitmap(of: host), "the row could not be drawn offscreen")
        let slots = RewriteChipRow.slots(rowWidth: available, showsRerun: false, overflows: true)
        let scale = CGFloat(bitmap.pixelsWide) / available

        /// The mean alpha of one column, over the row's whole height.
        func columnInk(at points: CGFloat) -> CGFloat {
            let x = min(max(Int((points * scale).rounded()), 0), bitmap.pixelsWide - 1)
            var total: CGFloat = 0
            for y in 0 ..< bitmap.pixelsHigh {
                total += bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
            }
            return total / CGFloat(bitmap.pixelsHigh)
        }

        /// The most inked column of a window that ends `from` points before
        /// the clip.
        func strongestColumn(from: CGFloat, width: CGFloat = 4) -> CGFloat {
            var strongest: CGFloat = 0
            var offset: CGFloat = 0
            while offset < width {
                strongest = max(strongest, columnInk(at: slots.viewportMaxX - from + offset))
                offset += 1
            }
            return strongest
        }

        let atTheClip = strongestColumn(from: 6)
        let midFade = strongestColumn(from: 16)
        let atTheFadeStart = strongestColumn(from: HUDRewriteLayout.chipOverflowWidth)

        XCTAssertGreaterThan(atTheFadeStart, 0.02, "the chips are not drawn at all")
        XCTAssertLessThan(
            atTheClip,
            midFade,
            "the last six points before the clip are as inked as the middle of the fade"
        )
        XCTAssertLessThan(
            midFade,
            atTheFadeStart,
            "the fade does not fall towards the clip"
        )
        XCTAssertLessThan(
            atTheClip,
            atTheFadeStart * 0.4,
            "the clip still ends the styles at full opacity: \(atTheClip) at the edge against \(atTheFadeStart) at the fade's start"
        )
    }

    /// Nothing of the cut label survives beside the overflow mark.
    ///
    /// The row is the widest the card draws: twelve labels, a version on one of
    /// them and the rerun control in the row. The mask is clear from its halfway
    /// point, so the last 13 points of the viewport carry no ink at all, and the
    /// gap between the clip and the mark's slot carries none either. The reading
    /// is the strongest alpha of a column over the row's whole height, so one
    /// surviving pixel of a glyph fails it.
    ///
    /// A cleared strip proves nothing unless something was in it, and the row's
    /// advances decide which chip the clip lands on. The test therefore draws
    /// the same row twice at the same offset, once with the fade off and wide
    /// enough to show the label past the clip: the control shows a glyph cut by
    /// the clip, and the masked row must lose exactly that ink. The offset is
    /// chosen from the measured chip widths so the clip falls inside one of the
    /// 24-character labels rather than in a gap, whatever the typeface's
    /// advances are.
    func testTheFadeLeavesNoFragmentOfTheCutLabel() throws {
        let styles = twelveStyles()
        let slots = RewriteChipRow.slots(rowWidth: available, showsRerun: false, overflows: true)
        let fadeStart = slots.viewportMaxX - HUDRewriteLayout.chipOverflowWidth
        let halfFade = slots.viewportMaxX - HUDRewriteLayout.chipOverflowWidth / 2
        let clip = slots.viewportMaxX

        // The first 24-character label is wider than the fade, so with its
        // middle on the clip the whole strip is over the chip; its repeated
        // glyphs leave no word space for the clip to fall into.
        let wideIndex = 5
        let wideWidth = RewriteChipMetrics.chipWidth(styles[wideIndex].title)
        let wideStart = RewriteChipMetrics.rowWidth(styles.prefix(wideIndex).map(\.title))
            + CGFloat(wideIndex) * HUDRewriteLayout.chipGap
        XCTAssertGreaterThan(
            wideWidth,
            2 * HUDRewriteLayout.chipOverflowWidth,
            "the chip chosen for the cut is not wider than the fade"
        )
        let offset = (wideStart + wideWidth / 2 - (clip - slots.viewportOrigin)).rounded()
        XCTAssertGreaterThanOrEqual(offset, 0, "the wide chip cannot reach the clip")
        XCTAssertLessThanOrEqual(
            offset,
            RewriteChipRow.contentWidth(for: styles) - slots.viewportWidth,
            "the wide chip cannot be scrolled to the clip"
        )

        // The control is the same row at the same offset, with only the fade
        // off, drawn wide enough that the label's continuation past the clip is
        // visible: the cut is a measurement, not an assumption.
        let controlWidth = available + 3 * HUDRewriteLayout.chipOverflowWidth
        let controlHost = settledHost(styles, rowWidth: controlWidth, drawsOverflowFade: false)
        let host = settledHost(styles)
        try scrollRow(controlHost, toContentX: offset)
        try scrollRow(host, toContentX: offset)
        let control = try XCTUnwrap(
            bitmap(of: controlHost),
            "the control row could not be drawn offscreen"
        )
        try write(control, named: "chip-row-fade-control")
        let row = try XCTUnwrap(bitmap(of: host), "the row could not be drawn offscreen")
        try write(row, named: "chip-row-twelve-styles")
        let scale = CGFloat(row.pixelsWide) / available
        let controlScale = CGFloat(control.pixelsWide) / controlWidth
        XCTAssertEqual(scale, controlScale, "the two frames were drawn at different scales")
        XCTAssertEqual(control.pixelsHigh, row.pixelsHigh, "the two frames are different heights")

        let controlStrip = minimumInk(control, from: fadeStart, to: clip - 0.5, scale: controlScale)
        let glyphBefore = strongestInk(control, from: clip - 3, to: clip - 0.5, scale: controlScale)
        let glyphAfter = strongestInk(control, from: clip + 0.5, to: clip + 3, scale: controlScale)
        print(
            "chip row fade control: offset \(offset) pt, strip alpha \(controlStrip), "
                + "glyph ink \(glyphBefore) before the clip and \(glyphAfter) past it"
        )
        XCTAssertGreaterThan(
            controlStrip,
            0.02,
            "the control draws the card's surface under the faded strip, so the mask had nothing to dissolve"
        )
        // An idle chip draws its label at `HUDTheme.ink2` (alpha 0.55) over a
        // fill of alpha 0.055, so a column through a glyph reads about 0.54 and
        // a column through the fill reads 0.055. Four tenths is glyph ink.
        XCTAssertGreaterThan(
            glyphBefore,
            0.4,
            "no glyph reaches the clip in the control, so no label is cut there"
        )
        XCTAssertGreaterThan(
            glyphAfter,
            0.4,
            "the control's label ends before the clip, so the clip cuts no glyph"
        )

        // Same chips, same offset: the two frames agree everywhere the mask is
        // still opaque. A control drawn at another offset would fail this, so
        // the strip measured below is the strip the control inked.
        let compared = min(Int(((fadeStart - 2) * scale).rounded()), row.pixelsWide)
        var moved = 0
        for y in 0 ..< min(control.pixelsHigh, row.pixelsHigh) {
            for x in 0 ..< compared where x < control.pixelsWide {
                guard let one = control.colorAt(x: x, y: y),
                      let two = row.colorAt(x: x, y: y)
                else { continue }
                let delta = abs(one.redComponent - two.redComponent)
                    + abs(one.greenComponent - two.greenComponent)
                    + abs(one.blueComponent - two.blueComponent)
                if delta > 0.01 { moved += 1 }
            }
        }
        XCTAssertEqual(
            moved,
            0,
            "the control and the masked row are not the same chips at the same offset"
        )

        XCTAssertGreaterThan(
            strongestInk(row, from: fadeStart, to: fadeStart + 2, scale: scale),
            0.02,
            "the styles are not drawn at the start of the fade, so the readings below prove nothing"
        )
        let lastThirteen = strongestInk(
            row,
            from: halfFade,
            to: clip - 0.5,
            scale: scale
        )
        let gapBesideMark = strongestInk(
            row,
            from: clip + 0.5,
            to: slots.overflowOrigin - 0.5,
            scale: scale
        )
        print(
            "chip row fade: \(HUDRewriteLayout.chipOverflowWidth) pt wide, "
                + "last \(HUDRewriteLayout.chipOverflowWidth / 2) pt alpha \(lastThirteen), "
                + "gap beside the mark alpha \(gapBesideMark)"
        )
        XCTAssertLessThan(
            lastThirteen,
            0.01,
            "the last \(HUDRewriteLayout.chipOverflowWidth / 2) pt before the clip still draw ink: the cut label is not dissolved"
        )
        XCTAssertLessThan(
            gapBesideMark,
            0.01,
            "a fragment of the clipped label is drawn in the gap before the overflow mark"
        )
        XCTAssertGreaterThan(
            strongestInk(row, from: slots.overflowOrigin, to: slots.overflowMaxX, scale: scale),
            0.02,
            "the overflow mark is not drawn in its slot"
        )

        // The done row keeps the same promise with its rerun control in place,
        // and the card's own surface is what the gap beside the mark sits on.
        let done = settledHost(
            styles,
            versions: doneVersions(),
            selectedVersionID: 1,
            onRerun: {}
        )
        let doneRow = try XCTUnwrap(bitmap(of: done), "the done row could not be drawn")
        try write(doneRow, named: "chip-row-twelve-styles-done")
        let doneSlots = RewriteChipRow.slots(rowWidth: available, showsRerun: true, overflows: true)
        let doneScale = CGFloat(doneRow.pixelsWide) / available
        XCTAssertLessThan(
            strongestInk(
                doneRow,
                from: doneSlots.viewportMaxX - HUDRewriteLayout.chipOverflowWidth / 2,
                to: doneSlots.viewportMaxX - 0.5,
                scale: doneScale
            ),
            0.01,
            "the done row leaves ink in the last half of its fade"
        )
        XCTAssertLessThan(
            strongestInk(
                doneRow,
                from: doneSlots.viewportMaxX + 0.5,
                to: doneSlots.overflowOrigin - 0.5,
                scale: doneScale
            ),
            0.01,
            "the done row leaves a fragment beside the overflow mark"
        )

        var card = RewriteCard(original: HUDPreview.longTranscript, choices: styles)
        card.versions = doneVersions()
        card.selectedVersionID = 1
        let fixture = cardFixture(card)
        defer { fixture.panel.orderOut(nil) }
        for _ in 0 ..< 3 {
            fixture.host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let drawn = try XCTUnwrap(bitmap(of: fixture.host, scale: 2), "the card could not be drawn")
        try write(drawn, named: "card-twelve-styles-done")
    }

    // MARK: - The row's targets

    /// Every control in the row is a 24 point target, and the mark's slot keeps
    /// the width of the arrows it sits between.
    func testEveryRowControlIsATwentyFourPointTarget() {
        XCTAssertEqual(HUDRewriteLayout.versionArrowWidth, 24, "a version arrow is not 24 points wide")
        XCTAssertEqual(HUDRewriteLayout.chipHeight, 24, "the row is not 24 points tall")
        XCTAssertGreaterThanOrEqual(
            HUDRewriteLayout.chipOverflowSlotWidth,
            RewriteChipRow.overflowMarkWidth
                + 2 * (RewriteChipRow.minimumOverflowClearance - HUDRewriteLayout.chipGap),
            "the mark's slot is narrower than the mark and its clearance"
        )
        XCTAssertEqual(
            HUDTheme.actionSize,
            HUDRewriteLayout.versionArrowWidth,
            "the Stop control in the header is not the size of the row's arrows"
        )
        XCTAssertEqual(
            HUDAction.stopRewrite.label(),
            "Stop rewriting",
            "the Stop control is named something other than what it does"
        )
        XCTAssertGreaterThanOrEqual(
            RewriteChipMetrics.chipWidth("Gen Z"),
            24,
            "the shortest chip is not a 24 point target"
        )
    }

    // MARK: - Long labels and other scripts

    /// The longest labels the catalogue allows, in the scripts the card is used
    /// in, drawn at two pixels per point.
    ///
    /// The row opens on the original, so the labels the catalogue's cap allows
    /// are the ones the fade cuts, and the second frame opens on a non-Latin
    /// version, so a chip is drawn with the glyphs it will be read in.
    func testTheLongestAndNonLatinLabelsRenderInTheRow() throws {
        let styles = longAndNonLatinStyles()
        let long = try XCTUnwrap(
            styles.first { $0.title.count == CustomRewriteStyle.maximumTitleLength }
        )
        XCTAssertGreaterThan(
            RewriteChipMetrics.chipWidth(long.title),
            3 * RewriteChipMetrics.chipWidth("Gen Z"),
            "the longest label is not the widest thing in the row"
        )
        let offered = settledHost(styles)
        let longIndex = RewriteStyle.builtIns.count
        try scrollRow(offered, styles: styles, toStyleAt: longIndex)
        let offeredRow = try XCTUnwrap(bitmap(of: offered), "the row could not be drawn offscreen")
        XCTAssertEqual(
            offeredRow.pixelsWide,
            Int(available * 2),
            "the row was not drawn at two pixels per point"
        )
        XCTAssertEqual(offeredRow.pixelsHigh, Int(HUDRewriteLayout.chipHeight * 2))
        XCTAssertGreaterThan(
            inkedPixels(offeredRow),
            200,
            "the row with the long and non-Latin labels is blank"
        )
        let slots = RewriteChipRow.slots(rowWidth: available, showsRerun: false, overflows: true)
        XCTAssertTrue(
            RewriteChipRow.overflows(
                contentWidth: RewriteChipRow.contentWidth(for: styles),
                viewportWidth: slots.viewportWidth
            ),
            "the longest labels fit the row, so the fixture shows nothing"
        )
        try write(offeredRow, named: "chip-row-long-nonlatin")

        var card = RewriteCard(original: HUDPreview.longTranscript, choices: styles)
        let japanese = try XCTUnwrap(styles.first { $0.id == "custom-ja" })
        card.versions = [
            RewriteVersion.original(text: card.original),
            RewriteVersion(
                id: 1,
                origin: .style(japanese.id),
                title: japanese.title,
                text: HUDPreview.rewrite,
                ordinal: 1
            ),
        ]
        card.selectedVersionID = 1
        let selected = settledHost(
            styles,
            versions: card.versions,
            selectedVersionID: 1,
            onRerun: {}
        )
        try scrollRow(selected, styles: styles, toStyleAt: longIndex)
        let chosen = try XCTUnwrap(bitmap(of: selected), "the selected row could not be drawn")
        XCTAssertGreaterThan(
            differingPixels(offeredRow, chosen),
            200,
            "the selected version is not drawn as a selection"
        )
        try write(chosen, named: "chip-row-long-nonlatin-selected")
    }

    // MARK: - The keyboard
    func testTheArrowKeysReachTheLastChipAndStopThere() {
        var focus = RewriteChipFocus()
        focus.update(ids: ["a", "b", "c"])
        XCTAssertEqual(focus.target, "a")
        XCTAssertEqual(focus.move(.right), "b")
        XCTAssertEqual(focus.move(.right), "c")
        XCTAssertEqual(focus.move(.right), "c", "the focus moved past the last chip")
        XCTAssertEqual(focus.move(.left), "b")
        XCTAssertEqual(focus.move(.left), "a")
        XCTAssertEqual(focus.move(.left), "a", "the focus moved past the first chip")
        XCTAssertNil(focus.move(.up), "a vertical key is not a scroll")
        XCTAssertEqual(focus.target, "a")
    }

    func testTheArrowKeysReachTheLastStyle() {
        let ids = twelveStyles().map(\.id)
        var focus = RewriteChipFocus()
        focus.update(ids: ids)
        for _ in 1 ..< ids.count {
            _ = focus.move(.right)
        }
        XCTAssertEqual(focus.target, ids.last, "the keyboard cannot reach the last style")
        XCTAssertEqual(focus.move(.right), ids.last)
    }

    func testTheFocusStaysInsideAShorterRow() {
        var focus = RewriteChipFocus()
        focus.update(ids: ["a", "b", "c"])
        _ = focus.move(.right)
        _ = focus.move(.right)
        focus.update(ids: ["a"])
        XCTAssertEqual(focus.target, "a", "a shorter row left the focus outside it")
    }

    func testAnEmptyRowHasNoTarget() {
        var focus = RewriteChipFocus()
        XCTAssertNil(focus.target)
        XCTAssertNil(focus.move(.right))
        focus.update(ids: [])
        XCTAssertNil(focus.target)
    }

    // MARK: - The rail on the card

    /// A whole card with the style rail in it, off every display.
    ///
    /// The wheel is read in a band of the card the island computes from the
    /// card's frame, not from the view tree, because the panel floats over
    /// another application, so AppKit never hit-tests the chip row there. This
    /// fixture is what says the band and the row agree.
    private func cardFixture(
        _ styles: [RewriteStyle],
        original: String = "The words the styles were offered for, one line of them."
    ) -> (panel: OffscreenHUDPanel, host: HUDHostingView, card: RewriteCard, size: CGSize) {
        cardFixture(RewriteCard(original: original, choices: styles))
    }

    /// The card a prepared layer draws, off every display.
    private func cardFixture(
        _ card: RewriteCard
    ) -> (panel: OffscreenHUDPanel, host: HUDHostingView, card: RewriteCard, size: CGSize) {
        let size = HUD.transcriptSize(text: card.original, rewrite: card)
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.cardSize = size
        model.mode = .transcript(text: card.original, delivery: .copied, elapsed: "0:04")
        model.rewrite = card

        let root = AnyView(
            HUDView(
                model: model,
                showsShadow: false,
                animated: false,
                actions: HUDActions()
            )
            .frame(width: size.width, height: size.height)
        )

        let panel = OffscreenHUDPanel(size: size)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false

        let host = HUDHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return (panel, host, card, size)
    }

    /// A rectangle in a view whose y axis runs from the bottom up.
    ///
    /// The island's geometry is measured in AppKit's screen coordinates, from
    /// the bottom of the card up; a hosting view is flipped. The two only meet
    /// after the rectangle is turned over.
    private func bottomUp(_ rect: CGRect, in view: NSView) -> CGRect {
        guard view.isFlipped else { return rect }
        return CGRect(
            x: rect.minX,
            y: view.bounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// The styles as the card lays them out, once the row has measured itself.
    private func settledCardFixture(
        _ styles: [RewriteStyle],
        original: String = "The words the styles were offered for, one line of them."
    ) -> (panel: OffscreenHUDPanel, host: HUDHostingView, card: RewriteCard, size: CGSize) {
        let fixture = cardFixture(styles, original: original)
        for _ in 0 ..< 3 {
            fixture.host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        fixture.host.layoutSubtreeIfNeeded()
        return fixture
    }

    /// The rail is found by the island's own lookup, not by the test's.
    func testTheIslandFindsTheStyleRailAndNotTheTranscript() throws {
        let fixture = settledCardFixture(twelveStyles(), original: HUDPreview.longTranscript)
        defer { fixture.panel.orderOut(nil) }

        let rail = try XCTUnwrap(
            HUD.chipRowScrollView(in: fixture.host),
            "the island did not find the style rail in the card"
        )
        XCTAssertLessThanOrEqual(
            rail.frame.height,
            HUD.maximumRailHeight,
            "the rail is taller than one chip line"
        )
        XCTAssertEqual(rail.frame.height, HUDRewriteLayout.chipHeight, accuracy: 0.5)

        let document = try XCTUnwrap(rail.documentView)
        XCTAssertGreaterThan(
            document.frame.width,
            rail.contentView.bounds.width,
            "twelve styles fit in the rail without scrolling"
        )

        // The transcript body is the other scroll view: it is taller than one
        // chip line and it is never the rail.
        let body = try XCTUnwrap(
            HUD.transcriptScrollView(in: fixture.host),
            "the card has no transcript body scroll view"
        )
        XCTAssertFalse(body === rail, "the island read the transcript as the rail")
        XCTAssertGreaterThan(body.frame.height, HUD.maximumRailHeight)
    }

    /// The band the island reads the wheel in is where the row is drawn, from
    /// the card's bottom edge to the chips' top, and it starts after the
    /// previous-version arrow and ends before the next one.
    func testTheRailBandCoversTheDrawnChipsAndNotTheArrows() throws {
        let fixture = settledCardFixture(twelveStyles())
        defer { fixture.panel.orderOut(nil) }

        let cardFrame = CGRect(origin: .zero, size: fixture.size)
        let band = HUD.rewriteChipRowFrame(cardFrame: cardFrame, card: fixture.card)
        XCTAssertFalse(band.isEmpty, "the card draws no band for its chips")
        XCTAssertEqual(band.height, HUDRewriteLayout.chipHeight, accuracy: 0.001)

        // The band is the bottom padding above the card's edge, whichever way
        // the hosting view measures its y axis.
        let fromCardEdge = min(band.minY - cardFrame.minY, cardFrame.maxY - band.maxY)
        XCTAssertEqual(
            fromCardEdge,
            HUDState.verticalPadding,
            accuracy: 0.001,
            "the band does not start at the card's own padding"
        )

        // The band is measured from the bottom of the card up, the way the
        // card itself is drawn; the hosting view may measure its y the other
        // way, so the row's frame is turned the same way before they meet.
        let rail = try XCTUnwrap(HUD.chipRowScrollView(in: fixture.host))
        let railRect = bottomUp(
            rail.convert(rail.bounds, to: fixture.host),
            in: fixture.host
        )
        XCTAssertGreaterThanOrEqual(
            railRect.minX,
            band.minX - 0.5,
            "the chips start left of the band"
        )
        XCTAssertLessThanOrEqual(
            railRect.maxX,
            band.maxX + 0.5,
            "the chips run under the band's trailing edge"
        )
        XCTAssertGreaterThanOrEqual(
            railRect.minY,
            band.minY - 0.5,
            "the chips are drawn below the band"
        )
        XCTAssertLessThanOrEqual(
            railRect.maxY,
            band.maxY + 0.5,
            "the chips are drawn above the band"
        )

        // The two arrows are controls, and a scroll over one of them is not a
        // scroll of the chips.
        let arrow = HUDRewriteLayout.versionArrowWidth
        XCTAssertGreaterThanOrEqual(
            band.minX,
            cardFrame.minX + HUDTheme.padding + arrow,
            "the band starts on the previous-version arrow"
        )
        XCTAssertLessThanOrEqual(
            band.maxX,
            cardFrame.maxX - HUDTheme.padding - arrow,
            "the band reaches the next-version arrow"
        )
    }

    /// A card without chips has no band, and a note line above the chips does
    /// not move it: the layer is drawn from the bottom of the card up, so the
    /// row is always the same 24 points above the card's padding.
    func testTheBandIsEmptyWithoutChipsAndDoesNotMoveUnderANote() throws {
        let plain = RewriteCard(original: "Words.", choices: twelveStyles())
        let noted = RewriteCard(
            original: "Words.",
            choices: twelveStyles(),
            note: "This version is on the clipboard."
        )

        let cardFrame = CGRect(x: 120, y: 300, width: 560, height: 274)
        let plainBand = HUD.rewriteChipRowFrame(cardFrame: cardFrame, card: plain)
        let notedBand = HUD.rewriteChipRowFrame(
            cardFrame: CGRect(x: 120, y: 300, width: 560, height: 291),
            card: noted
        )
        XCTAssertEqual(notedBand.minY, plainBand.minY, accuracy: 0.001, "the note moved the chips")
        XCTAssertEqual(notedBand.width, plainBand.width, accuracy: 0.001)

        XCTAssertTrue(
            HUD.rewriteChipRowFrame(cardFrame: cardFrame, card: nil).isEmpty,
            "a plain transcript has a chip band"
        )
        var blocked = RewriteCard(original: "Words.", choices: twelveStyles())
        blocked.phase = .blocked(styleID: "concise", error: "The draft dropped a fact.")
        XCTAssertFalse(blocked.showsChips)
        XCTAssertTrue(
            HUD.rewriteChipRowFrame(cardFrame: cardFrame, card: blocked).isEmpty,
            "a refused rewrite drew a band for chips it does not draw"
        )
        XCTAssertTrue(
            HUD.rewriteChipRowFrame(
                cardFrame: CGRect(x: 0, y: 0, width: 60, height: 100),
                card: plain
            ).isEmpty,
            "a card narrower than its own controls was given a band"
        )
    }

    /// The wheel moves the rail by its own travel, one gesture at a time, and
    /// neither end goes past itself.
    func testTheRailTakesTheWheelDeltasAndStopsAtBothEnds() throws {
        let fixture = settledCardFixture(twelveStyles())
        defer { fixture.panel.orderOut(nil) }

        let rail = try XCTUnwrap(HUD.chipRowScrollView(in: fixture.host))
        let clip = rail.contentView
        let maximum = max(0, (rail.documentView?.frame.width ?? 0) - clip.bounds.width)
        XCTAssertGreaterThan(maximum, 200, "the fixture rail has no room to scroll")
        XCTAssertEqual(clip.bounds.origin.x, 0, accuracy: 0.5)

        // A trackpad's horizontal travel is applied as it comes: fingers left
        // reveal what is on the right, so the origin grows.
        XCTAssertTrue(HUD.scrollRail(scrollView: rail, step: -60))
        XCTAssertEqual(clip.bounds.origin.x, 60, accuracy: 0.5)

        XCTAssertTrue(HUD.scrollRail(scrollView: rail, step: -40))
        XCTAssertEqual(clip.bounds.origin.x, 100, accuracy: 0.5)

        // The other way comes back, and the left end is zero.
        XCTAssertTrue(HUD.scrollRail(scrollView: rail, step: 60))
        XCTAssertEqual(clip.bounds.origin.x, 40, accuracy: 0.5)
        for _ in 0 ..< 4 {
            _ = HUD.scrollRail(scrollView: rail, step: 400)
        }
        XCTAssertEqual(clip.bounds.origin.x, 0, accuracy: 0.5, "the rail scrolled past its start")

        // And the right end is the content that is left over.
        for _ in 0 ..< 8 {
            _ = HUD.scrollRail(scrollView: rail, step: -400)
        }
        XCTAssertEqual(
            clip.bounds.origin.x,
            maximum,
            accuracy: 0.5,
            "the rail did not come to rest at the end of its styles"
        )
    }

    /// A wheel with no horizontal axis spends its notch on the rail, and a
    /// vertical trackpad gesture is mapped onto the same sideways travel.
    func testTheRailTakesAWheelNotchAndAVerticalTrackpadGesture() throws {
        let fixture = settledCardFixture(twelveStyles())
        defer { fixture.panel.orderOut(nil) }

        let rail = try XCTUnwrap(HUD.chipRowScrollView(in: fixture.host))
        let clip = rail.contentView

        // Two fingers down the page: the gesture is vertical, and the row
        // takes the travel as its own because it has no vertical travel.
        let vertical = try XCTUnwrap(
            HUDWheelAxis.beginning(deltaX: 3, deltaY: -90),
            "a gesture with travel has no axis"
        )
        XCTAssertEqual(vertical, .vertical)
        XCTAssertTrue(
            HUD.scrollRail(
                scrollView: rail,
                step: vertical.step(deltaX: 3, deltaY: -90)
            )
        )
        XCTAssertEqual(clip.bounds.origin.x, 90, accuracy: 0.5)

        // One notch of a wheel: no horizontal axis at all, and the row takes it.
        let notch = try XCTUnwrap(HUDWheelAxis.beginning(deltaX: 0, deltaY: -3))
        XCTAssertEqual(notch, .vertical)
        XCTAssertTrue(HUD.scrollRail(scrollView: rail, step: notch.step(deltaX: 0, deltaY: -3)))
        XCTAssertEqual(clip.bounds.origin.x, 93, accuracy: 0.5)

        // A row that fits has no travel to apply.
        let fitting = cardFixture(Array(RewriteStyle.builtIns.prefix(2)))
        defer { fitting.panel.orderOut(nil) }
        fitting.host.layoutSubtreeIfNeeded()
        let fits = try XCTUnwrap(HUD.chipRowScrollView(in: fitting.host))
        XCTAssertLessThanOrEqual(
            fits.documentView?.frame.width ?? 0,
            fits.contentView.bounds.width + 0.5,
            "two styles do not fit the test card's rail"
        )
        XCTAssertFalse(
            HUD.scrollRail(scrollView: fits, step: -60),
            "a row that fits claimed the travel"
        )
        XCTAssertEqual(fits.contentView.bounds.origin.x, 0, accuracy: 0.5)
    }
}

