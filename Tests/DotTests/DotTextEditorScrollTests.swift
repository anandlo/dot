import AppKit
import DotCore
import SwiftUI
import XCTest

@testable import Dot

/// The prompt field's wheel, its two ends, and the fades drawn at them.
///
/// The field is a scroll view inside the settings page's own scroll view, so a
/// wheel that reached the end of the text was handed to the page and scrolled
/// the page out from under the cursor. These tests put the field in a page that
/// can scroll both ways, drive synthesized wheel events into the field, and read
/// the page's offset beside it; then they read the mask the field draws its edge
/// fades from, and render the field to measure the ink at the edge it fades.
///
/// Every fixture is an off-screen window, so nothing is drawn on a display.
@MainActor
final class DotTextEditorScrollTests: XCTestCase {
    /// The app's typeface, registered before the first view is built.
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    // MARK: - The page the field sits in

    /// A field in a page that scrolls both ways, off every display.
    @MainActor
    private struct Fixture {
        let window: NSWindow
        let page: NSScrollView
        let editor: DotTextEditorScrollView
        let textView: NSTextView

        /// Where the page under the field is scrolled to.
        var pageOrigin: CGFloat { page.contentView.bounds.origin.y }
        /// Where the field is scrolled to.
        var editorOrigin: CGFloat { editor.contentView.bounds.origin.y }
        /// The height of the clip view the text scrolls in.
        var clipHeight: CGFloat { editor.contentView.bounds.height }
        /// The last offset the field can be scrolled to.
        var editorLimit: CGFloat { max(0, textView.frame.height - clipHeight) }
    }

    /// A document view that starts at its own top, as the settings page does.
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    /// The width the settings page gives the prompt field.
    private let fieldWidth: CGFloat = 533
    /// The room above and below the field in the page, so the page scrolls.
    private let pageMargin: CGFloat = 800
    /// The height of the page's viewport.
    private let pageHeight: CGFloat = 320

    /// Builds the page, the field in it, and the window they are drawn in.
    ///
    /// - Parameters:
    ///   - text: what the field holds.
    ///   - editorHeight: the height of the field, border included.
    /// - Returns: the fixture, whose window is ordered out by the caller.
    private func makeFixture(
        text: String,
        editorHeight: CGFloat = AssistantPage.promptEditorHeight
    ) throws -> Fixture {
        let content = VStack(spacing: 0) {
            Color.clear.frame(height: pageMargin)
            DotTextEditor(text: .constant(text), height: editorHeight, accessibilityLabel: "Prompt")
                .frame(width: fieldWidth)
            Color.clear.frame(height: pageMargin)
        }
        .frame(width: fieldWidth)
        let host = NSHostingView(rootView: content)
        let document = FlippedDocument(
            frame: NSRect(x: 0, y: 0, width: fieldWidth, height: pageMargin * 2 + editorHeight)
        )
        host.frame = document.bounds
        host.autoresizingMask = [.width, .height]
        document.addSubview(host)

        let page = NSScrollView(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: pageHeight))
        page.hasVerticalScroller = true
        page.drawsBackground = false
        page.documentView = document

        let window = OffscreenWindow(
            size: CGSize(width: fieldWidth, height: pageHeight),
            styleMask: [.borderless]
        )
        window.contentView = page
        window.orderFrontRegardless()
        settle(page)

        let editor = try XCTUnwrap(
            DotTextEditor.scrollView(in: host),
            "the field is not built on a scroll view"
        )
        let textView = try XCTUnwrap(
            editor.documentView as? NSTextView,
            "the field has no text view"
        )
        return Fixture(window: window, page: page, editor: editor, textView: textView)
    }

    /// Runs the layout and the run loop until the hierarchy has settled.
    private func settle(_ view: NSView) {
        for _ in 0 ..< 3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        view.layoutSubtreeIfNeeded()
    }

    // MARK: - The wheel

    /// A wheel that reaches the field's last line does not scroll the page.
    ///
    /// The wheel is kept for the field at every phase, so the page under it
    /// never sees the gesture. The field records that it kept the wheel, which
    /// is the half of the reading AppKit would show: a wheel built here carries
    /// no window, so the window that chains it to the page never runs.
    func testWheelDownThroughTheBottomNeverMovesThePage() throws {
        let fixture = try makeFixture(text: sixtyLines())
        defer { fixture.window.orderOut(nil) }
        XCTAssertGreaterThan(fixture.editorLimit, 40, "the text does not overflow the field")

        fixture.editor.contentView.scroll(to: NSPoint(x: 0, y: fixture.editorLimit))
        settle(fixture.page)
        let limit = fixture.editorLimit
        let pageBefore = fixture.pageOrigin
        for _ in 0 ..< 20 {
            fixture.editor.scrollWheel(with: try wheel(-12))
        }
        XCTAssertTrue(
            fixture.editor.keptTheLastWheel,
            "the field handed a wheel on that it had text to scroll with"
        )
        XCTAssertEqual(
            fixture.pageOrigin,
            pageBefore,
            "the page scrolled \(fixture.pageOrigin - pageBefore) pt under a wheel that had reached the field's last line"
        )
        XCTAssertEqual(
            fixture.editorOrigin,
            limit,
            accuracy: 0.001,
            "the field left its last line for \(fixture.editorOrigin)"
        )
    }

    /// A wheel that reaches the field's first line does not scroll the page.
    ///
    /// The page is scrolled away from its own top first: a page already at its
    /// top could not move, so a forwarded wheel would leave it where it was and
    /// the reading would prove nothing.
    func testWheelUpThroughTheTopNeverMovesThePage() throws {
        let fixture = try makeFixture(text: sixtyLines())
        defer { fixture.window.orderOut(nil) }
        fixture.page.contentView.scroll(to: NSPoint(x: 0, y: 400))
        settle(fixture.page)
        let pageBefore = fixture.pageOrigin
        XCTAssertGreaterThan(pageBefore, 100, "the page could not be scrolled away from its top")
        XCTAssertEqual(fixture.editorOrigin, 0, accuracy: 0.001, "the field did not open on its first line")

        for _ in 0 ..< 20 {
            fixture.editor.scrollWheel(with: try wheel(12))
        }
        XCTAssertTrue(
            fixture.editor.keptTheLastWheel,
            "the field handed a wheel on that it had text to scroll with"
        )
        XCTAssertEqual(
            fixture.pageOrigin,
            pageBefore,
            "the page scrolled \(pageBefore - fixture.pageOrigin) pt under a wheel that had reached the field's first line"
        )
        XCTAssertEqual(
            fixture.editorOrigin,
            0,
            accuracy: 0.001,
            "the field left its first line for \(fixture.editorOrigin)"
        )
    }

    /// Within its range the field moves by the wheel's own delta.
    func testTheEditorStillScrollsWithinItsRange() throws {
        let fixture = try makeFixture(text: sixtyLines())
        defer { fixture.window.orderOut(nil) }
        let limit = fixture.editorLimit
        XCTAssertGreaterThan(limit, 100, "the text does not overflow the field")

        // The sign is read from the events rather than assumed: a finger
        // dragged down reports a positive delta, and the text must move toward
        // its first line, which is the origin going down.
        let down = try wheel(-12)
        XCTAssertLessThan(down.scrollingDeltaY, 0, "an upward finger drag does not report a negative delta")
        let up = try wheel(30)
        XCTAssertGreaterThan(up.scrollingDeltaY, 0, "a downward finger drag does not report a positive delta")

        fixture.editor.scrollWheel(with: down)
        XCTAssertEqual(
            fixture.editorOrigin,
            12,
            accuracy: 0.001,
            "the field did not move by the wheel's own delta"
        )
        fixture.editor.scrollWheel(with: try wheel(5))
        XCTAssertEqual(
            fixture.editorOrigin,
            7,
            accuracy: 0.001,
            "the field did not move back by the wheel's own delta"
        )
        fixture.editor.scrollWheel(with: up)
        XCTAssertEqual(fixture.editorOrigin, 0, accuracy: 0.001, "the field scrolled past its first line")

        // A wheel that is not precise reports lines, and the field converts
        // them with its own line scroll.
        let lines = try wheel(-4, units: .line)
        XCTAssertFalse(lines.hasPreciseScrollingDeltas, "a line wheel reports precise deltas")
        fixture.editor.scrollWheel(with: lines)
        XCTAssertEqual(
            fixture.editorOrigin,
            min(4 * fixture.editor.verticalLineScroll, limit),
            accuracy: 0.001,
            "the field did not scroll by the lines the wheel reported"
        )

        for _ in 0 ..< 40 {
            fixture.editor.scrollWheel(with: try wheel(-40))
        }
        XCTAssertEqual(
            fixture.editorOrigin,
            limit,
            accuracy: 0.001,
            "the field scrolled past its last line for \(fixture.editorOrigin)"
        )
    }

    /// A field whose text fits has nothing to consume and hands the wheel on.
    ///
    /// The hand-off is read in two steps, because AppKit chains a wheel in the
    /// window that dispatches it and a wheel built here carries no window: the
    /// field says it did not keep the wheel, and the next responder in its own
    /// chain, which is the page, takes it and scrolls. The one hand-off the
    /// window would make is made here instead.
    func testAnEditorThatFitsForwardsTheWheel() throws {
        let fixture = try makeFixture(text: "A prompt that fits in the field.")
        defer { fixture.window.orderOut(nil) }
        XCTAssertLessThanOrEqual(
            fixture.textView.frame.height,
            fixture.clipHeight + 0.5,
            "the text overflows the field, so the field would keep the wheel"
        )
        let event = try wheel(-40)
        fixture.editor.scrollWheel(with: event)
        XCTAssertFalse(
            fixture.editor.keptTheLastWheel,
            "the field kept a wheel it had nothing to scroll with"
        )
        XCTAssertEqual(fixture.editorOrigin, 0, accuracy: 0.001, "a field the text fits in scrolled")

        let pageBefore = fixture.pageOrigin
        fixture.editor.nextResponder?.scrollWheel(with: event)
        XCTAssertGreaterThan(
            fixture.pageOrigin,
            pageBefore,
            "the page above the field did not take the wheel the field handed on"
        )
    }

    /// No wheel drags the text past either end of the field.
    func testThereIsNoElasticOvershoot() throws {
        let fixture = try makeFixture(text: sixtyLines())
        defer { fixture.window.orderOut(nil) }
        XCTAssertEqual(
            fixture.editor.verticalScrollElasticity,
            NSScrollView.Elasticity.none,
            "the field can rubber-band its own text"
        )
        XCTAssertEqual(
            fixture.editor.horizontalScrollElasticity,
            NSScrollView.Elasticity.none,
            "the field can rubber-band its own text sideways"
        )
        let limit = fixture.editorLimit
        XCTAssertGreaterThan(limit, 40, "the text does not overflow the field")

        for step in 0 ..< 60 {
            let delta: Int32 = step % 3 == 2 ? 120 : -90
            fixture.editor.scrollWheel(with: try wheel(delta))
            let origin = fixture.editorOrigin
            XCTAssertGreaterThanOrEqual(
                origin,
                0,
                "step \(step) pulled the text above its first line to \(origin)"
            )
            XCTAssertLessThanOrEqual(
                origin,
                limit,
                "step \(step) pushed the text past its last line to \(origin)"
            )
        }
    }

    // MARK: - The fades at the ends

    /// The fades follow the clip view's position.
    ///
    /// An edge the text runs past its padding is faded and an edge the text
    /// stops at is opaque, so the two readings swap as the field is scrolled
    /// from one end to the other, and both are faded in between. The fade is 12
    /// points long and its stop is read from the clip view's own height, so it
    /// is the same distance whatever the field's height is.
    ///
    /// The padding at either end of the text is not text, so the fade is still
    /// nothing while only the padding has been scrolled past, and it reaches its
    /// whole length a padding plus a fade in.
    ///
    /// The mask is read from the layer rather than from a picture. A
    /// window-server capture of the offscreen field is pixel-identical with the
    /// mask, with the mask taken off and with every stop of it clear, and a
    /// layer render composites the mask in the clip view's space while it draws
    /// the text in the window's, so neither picture carries the fade a reader
    /// sees.
    func testTheEdgeFadeFollowsTheScrollPosition() throws {
        let fixture = try makeFixture(text: sixtyLines())
        defer { fixture.window.orderOut(nil) }
        let clipHeight = fixture.clipHeight
        let fade = DotTextEditor.edgeFadeHeight
        let pad = DotTextEditor.textInset.height
        let limit = fixture.editorLimit
        XCTAssertGreaterThan(
            limit,
            pad + 2 * fade,
            "the text does not overflow the field far enough to fade both ends"
        )

        // The first line is at the top edge: nothing but its own padding is
        // above it, so the top is opaque and the text runs past the bottom
        // edge, which fades.
        fixture.editor.contentView.scroll(to: .zero)
        settle(fixture.page)
        var mask = try fadeMask(of: fixture.editor)
        var edges = try edgeAlphas(mask)
        var lengths = fadeLengths(mask, clipHeight: clipHeight)
        XCTAssertEqual(edges.top, 1, accuracy: 0.001, "the field fades its first line at the top edge")
        XCTAssertEqual(edges.bottom, 0, accuracy: 0.001, "the field does not fade the text past its bottom edge")
        // The clear stop is the first one, and the first one is the layer's own
        // top, which is what puts the fade a reader sees at the top edge.
        let layer = try XCTUnwrap(fixture.editor.contentView.layer, "the clip view has no layer")
        XCTAssertFalse(layer.isGeometryFlipped, "the clip view's layer is drawn the other way up")
        XCTAssertEqual(mask.startPoint.y, 1, accuracy: 0.001, "the first stop is not the layer's top")
        XCTAssertEqual(mask.endPoint.y, 0, accuracy: 0.001, "the last stop is not the layer's foot")
        XCTAssertEqual(lengths.top, 0, accuracy: 0.001, "the top fade is \(lengths.top) pt at the first line")
        XCTAssertEqual(lengths.bottom, fade, accuracy: 0.001, "the bottom fade is \(lengths.bottom) pt, not \(fade)")

        // A padding of the text scrolled past is still no text past the edge, so
        // the top stays opaque.
        fixture.editor.contentView.scroll(to: NSPoint(x: 0, y: pad))
        settle(fixture.page)
        mask = try fadeMask(of: fixture.editor)
        edges = try edgeAlphas(mask)
        lengths = fadeLengths(mask, clipHeight: clipHeight)
        XCTAssertEqual(edges.top, 1, accuracy: 0.001, "the field fades the padding above its first line")
        XCTAssertEqual(
            lengths.top,
            0,
            accuracy: 0.001,
            "the top fade is \(lengths.top) pt with only the padding above the clip"
        )

        // The last line is at the bottom edge: the reading swaps, and only the
        // padding is past the foot.
        fixture.editor.contentView.scroll(to: NSPoint(x: 0, y: limit))
        settle(fixture.page)
        mask = try fadeMask(of: fixture.editor)
        edges = try edgeAlphas(mask)
        lengths = fadeLengths(mask, clipHeight: clipHeight)
        XCTAssertEqual(edges.top, 0, accuracy: 0.001, "the field does not fade the text past its top edge")
        XCTAssertEqual(edges.bottom, 1, accuracy: 0.001, "the field fades its last line at the bottom edge")
        XCTAssertEqual(lengths.top, fade, accuracy: 0.001, "the top fade is \(lengths.top) pt, not \(fade)")
        XCTAssertEqual(lengths.bottom, 0, accuracy: 0.001, "the bottom fade is \(lengths.bottom) pt at the last line")

        fixture.editor.contentView.scroll(to: NSPoint(x: 0, y: limit - pad))
        settle(fixture.page)
        mask = try fadeMask(of: fixture.editor)
        edges = try edgeAlphas(mask)
        lengths = fadeLengths(mask, clipHeight: clipHeight)
        XCTAssertEqual(edges.bottom, 1, accuracy: 0.001, "the field fades the padding below its last line")
        XCTAssertEqual(
            lengths.bottom,
            0,
            accuracy: 0.001,
            "the bottom fade is \(lengths.bottom) pt with only the padding below the clip"
        )

        // A padding plus a fade scrolled past the foot is the point at which a
        // line is a whole fade clear of the clip, so that is where the fade is
        // at its full length.
        fixture.editor.contentView.scroll(to: NSPoint(x: 0, y: limit - pad - fade))
        settle(fixture.page)
        lengths = fadeLengths(try fadeMask(of: fixture.editor), clipHeight: clipHeight)
        XCTAssertEqual(
            lengths.bottom,
            fade,
            accuracy: 0.001,
            "the bottom fade is \(lengths.bottom) pt a padding and a fade past the last line"
        )

        // In between the text runs past both padding bands.
        fixture.editor.contentView.scroll(to: NSPoint(x: 0, y: limit / 2))
        settle(fixture.page)
        mask = try fadeMask(of: fixture.editor)
        edges = try edgeAlphas(mask)
        lengths = fadeLengths(mask, clipHeight: clipHeight)
        XCTAssertEqual(edges.top, 0, accuracy: 0.001, "the text past the top edge is not faded")
        XCTAssertEqual(edges.bottom, 0, accuracy: 0.001, "the text past the bottom edge is not faded")
        XCTAssertEqual(lengths.top, fade, accuracy: 0.001)
        XCTAssertEqual(lengths.bottom, fade, accuracy: 0.001)

        // Text that fits is not faded at either end.
        let short = try makeFixture(text: "A prompt that fits in the field.")
        defer { short.window.orderOut(nil) }
        mask = try fadeMask(of: short.editor)
        edges = try edgeAlphas(mask)
        XCTAssertEqual(edges.top, 1, accuracy: 0.001, "a field the text fits in fades its top edge")
        XCTAssertEqual(edges.bottom, 1, accuracy: 0.001, "a field the text fits in fades its bottom edge")
    }

    /// The padding stands between an end line and the fade.
    ///
    /// The owner's rule is that a line at either end of the text is never under
    /// the fade, and the padding is what holds it clear: the text container's
    /// inset at both ends is the fade's own length. The reading is exact rather
    /// than a picture, for the reason ``testTheEdgeFadeFollowsTheScrollPosition``
    /// gives: the layout places the two end lines, and the mask's own stops say
    /// where it is solid, so the two together say the end lines are drawn whole.
    func testThePaddingStandsBetweenTheEndLinesAndTheFade() throws {
        let fixture = try makeFixture(text: denseLines(60))
        defer { fixture.window.orderOut(nil) }
        let pad = DotTextEditor.textInset.height
        let clipHeight = fixture.clipHeight
        let limit = fixture.editorLimit
        let document = fixture.textView.frame.height
        let bands = try lineBands(of: fixture)
        let first = try XCTUnwrap(bands.first, "the fixture lays out no lines")
        let last = try XCTUnwrap(bands.last, "the fixture lays out no lines")

        XCTAssertEqual(
            first.top,
            pad,
            accuracy: 0.001,
            "the first line's box starts \(first.top) pt below the clip's top edge, which is not the field's padding"
        )
        XCTAssertLessThanOrEqual(
            last.bottom,
            document - pad + 0.5,
            "the last line's box ends \(document - last.bottom) pt above the clip's foot, inside the fade"
        )

        // The first line at its own end: the top fade is nothing, so every row
        // of the line sits in the mask's solid part.
        fixture.editor.contentView.scroll(to: .zero)
        settle(fixture.page)
        var mask = try fadeMask(of: fixture.editor)
        var lengths = fadeLengths(mask, clipHeight: clipHeight)
        XCTAssertEqual(lengths.top, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            lengths.top,
            first.top,
            "the top fade runs \(lengths.top) pt into a first line that starts at \(first.top) pt"
        )

        // The last line at its own end: the foot fade is nothing, so every row
        // of the line sits in the mask's solid part.
        fixture.editor.contentView.scroll(to: NSPoint(x: 0, y: limit))
        settle(fixture.page)
        mask = try fadeMask(of: fixture.editor)
        lengths = fadeLengths(mask, clipHeight: clipHeight)
        XCTAssertEqual(lengths.bottom, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            clipHeight - lengths.bottom,
            last.bottom - limit,
            "the foot fade starts \(clipHeight - lengths.bottom) pt down a clip whose last line ends at \(last.bottom - limit) pt"
        )
    }

    /// The bands the field's laid-out lines fill, in the text's own coordinates.
    ///
    /// The reading is taken from the layout rather than from a fixed offset: the
    /// field's type fills only part of a line box, so a row picked at a fixed
    /// offset can fall in the blank between two lines and read as no ink at all.
    ///
    /// - Parameter fixture: the field the lines are laid out in.
    /// - Returns: one band per laid-out line, top to bottom, in points from the
    ///   top of the text view's frame.
    private func lineBands(of fixture: Fixture) throws -> [(top: CGFloat, bottom: CGFloat)] {
        let textView = fixture.textView
        let layoutManager = try XCTUnwrap(textView.layoutManager, "the text view has no layout manager")
        let container = try XCTUnwrap(textView.textContainer, "the text view has no text container")
        layoutManager.ensureLayout(for: container)
        let origin = textView.textContainerOrigin.y
        var bands: [(top: CGFloat, bottom: CGFloat)] = []
        var glyph = 0
        while glyph < layoutManager.numberOfGlyphs {
            var range = NSRange()
            _ = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            let box = layoutManager.boundingRect(forGlyphRange: range, in: container)
            bands.append((origin + box.minY, origin + box.maxY))
            glyph = NSMaxRange(range)
        }
        return bands
    }

    // MARK: - Frames for a reviewer

    /// Writes the field at four positions, as the window server composited it.
    ///
    /// Skipped unless `DOT_SCROLL_CAPTURE_DIR` names a directory: a run of the
    /// suite writes no files. The picture is the window's own, so it carries the
    /// text, the padding around it and the field's chrome. It does not carry the
    /// mask the fades are drawn with: the same window captured with the mask,
    /// with the mask taken off and with every stop of it clear is one picture, so
    /// the fades are read from the mask's own stops in
    /// `testTheEdgeFadeFollowsTheScrollPosition` instead. The window is the field
    /// alone, at two pixels per point on a display that draws at that scale. The
    /// third position is six points above the last one, inside the padding the
    /// fade keeps clear at the foot.
    func testTheFieldIsRenderedAtEachScrollPosition() throws {
        guard let directory = ProcessInfo.processInfo.environment["DOT_SCROLL_CAPTURE_DIR"],
              !directory.isEmpty
        else {
            throw XCTSkip("DOT_SCROLL_CAPTURE_DIR is not set, so no frame is written")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let height = AssistantPage.promptEditorHeight
        let field = DotTextEditor(
            text: .constant(RewriteStyleID.prompt.template),
            height: height,
            accessibilityLabel: "Prompt"
        )
        .frame(width: fieldWidth)
        let host = NSHostingView(rootView: field)
        host.frame = NSRect(x: 0, y: 0, width: fieldWidth, height: height)
        let window = OffscreenWindow(
            size: CGSize(width: fieldWidth, height: height),
            styleMask: [.borderless]
        )
        // The field's own fill is a veil, so what the picture shows behind it is
        // this window. A white window drew the dark appearance's bone ink as a
        // page of white; the page the field sits on is the Settings paper in the
        // appearance it is drawn in, resolved here so the frame reads the same
        // whatever appearance the Mac running it is set to.
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        window.appearance = appearance
        var paper = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            paper = NSColor(DotTheme.paper)
        }
        window.backgroundColor = paper
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let editor = try XCTUnwrap(
            DotTextEditor.scrollView(in: host),
            "the field is not built on a scroll view"
        )
        let limit = max(0, (editor.documentView?.frame.height ?? 0) - editor.contentView.bounds.height)
        XCTAssertGreaterThan(limit, 100, "the shipped Agent prompt does not overflow the field")
        let positions: [(String, CGFloat)] = [
            ("agent-prompt-field-top", 0),
            ("agent-prompt-field-mid", 100),
            ("agent-prompt-field-near-bottom", max(0, limit - 6)),
            ("agent-prompt-field-bottom", limit),
        ]
        for (name, origin) in positions {
            editor.contentView.scroll(to: NSPoint(x: 0, y: origin))
            editor.reflectScrolledClipView(editor.contentView)
            WindowCapture.spin(0.2)
            window.display()
            let pixels = try XCTUnwrap(
                WindowCapture.capture(window),
                "the field's window could not be captured"
            )
            try WindowCapture.requireUsableCapture(pixels)
            let url = folder.appendingPathComponent("\(name).png")
            XCTAssertTrue(WindowCapture.write(pixels, to: url), "the frame could not be written")
            print(
                "DotTextEditorScrollTests frame: \(url.path) at \(editor.contentView.bounds.origin.y) "
                    + "of \(limit), \(pixels.width)x\(pixels.height) px"
            )
        }
    }

    // MARK: - The text the fixtures hold

    /// Sixty lines, more than the field shows.
    private func sixtyLines() -> String {
        (1 ... 60).map { "Line \($0) of the prompt the field holds." }.joined(separator: "\n")
    }

    /// Lines of one wide capital, with no word space and no descender.
    ///
    /// A row can only be read for ink where a glyph is drawn, and a capital's
    /// band is the tallest the field's type has that is also the same on every
    /// line: the reading picks its offset from the band the layout reports.
    private func denseLines(_ count: Int) -> String {
        let font = DotType.nsFont(12.5, .regular)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let glyphs = max(1, Int(((fieldWidth - 40) / max(advance, 0.1)).rounded(.down)))
        let line = String(repeating: "M", count: glyphs)
        return Array(repeating: line, count: count).joined(separator: "\n")
    }

    // MARK: - Synthesized wheels

    /// A wheel event as the window server delivers one.
    ///
    /// - Parameters:
    ///   - delta: the wheel's own count, in the units given.
    ///   - units: pixels for a trackpad, lines for a legacy wheel.
    /// - Returns: the event, ready for `scrollWheel(with:)`.
    private func wheel(_ delta: Int32, units: CGScrollEventUnit = .pixel) throws -> NSEvent {
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: units,
                wheelCount: 1,
                wheel1: delta,
                wheel2: 0,
                wheel3: 0
            ),
            "the wheel event could not be made"
        )
        return try XCTUnwrap(NSEvent(cgEvent: event), "the wheel event could not be read as an NSEvent")
    }

    // MARK: - Reading the mask

    /// The mask the field fades its edges with.
    private func fadeMask(of editor: DotTextEditorScrollView) throws -> CAGradientLayer {
        let layer = try XCTUnwrap(editor.contentView.layer, "the clip view has no layer")
        return try XCTUnwrap(
            layer.mask as? CAGradientLayer,
            "the clip view has no fade mask"
        )
    }

    /// The alpha of the two ends of the gradient, the clip view's top first.
    ///
    /// The field puts its first stop on the clip view's top edge and its last on
    /// the bottom one, whatever way round the clip view's layer is. Which of the
    /// two a reader sees at the top is the layer's own reading of that, which the
    /// fade test asserts beside the stop that is clear.
    private func edgeAlphas(_ mask: CAGradientLayer) throws -> (top: CGFloat, bottom: CGFloat) {
        let colors = try XCTUnwrap(mask.colors as? [CGColor], "the mask has no colours")
        XCTAssertEqual(colors.count, 4, "the mask is not a two-ended fade")
        return (colors[0].alpha, colors[colors.count - 1].alpha)
    }

    /// The length of each fade in points, the clip view's top first.
    private func fadeLengths(
        _ mask: CAGradientLayer,
        clipHeight: CGFloat
    ) -> (top: CGFloat, bottom: CGFloat) {
        let locations = (mask.locations ?? []).map { CGFloat($0.doubleValue) }
        guard locations.count == 4 else { return (-1, -1) }
        return (locations[1] * clipHeight, (1 - locations[2]) * clipHeight)
    }
}
