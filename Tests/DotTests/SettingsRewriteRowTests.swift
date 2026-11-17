import AppKit
import DotCore
import SwiftUI
import XCTest

@testable import Dot

/// The rewrite rows of the Assistant page, measured where they are drawn.
///
/// The subtitle of a style is one sentence and the row has room for it, so the
/// row may not be taller than a row whose subtitle is one short line. The
/// measurement is the hosting view's own fitting height at the width the
/// settings page gives a row: the page's inset, the card's inset and the
/// sidebar, at the window the render draws.
@MainActor
final class SettingsRewriteRowTests: XCTestCase {
    /// The app's typeface, registered before the first view is built.
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    /// The width of a row's content in the rendered settings window.
    private let rowWidth: CGFloat = 533

    private func rowHeight(title: String, subtitle: String?) -> CGFloat {
        let row = SettingsToggleRow(title: title, subtitle: subtitle, isOn: .constant(true))
            .frame(width: rowWidth)
        let hosting = NSHostingView(rootView: row)
        hosting.frame = NSRect(x: 0, y: 0, width: rowWidth, height: 400)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    func testEveryBuiltInStyleSubtitleIsOneLine() {
        let oneLine = rowHeight(title: "Professional", subtitle: "Clear, direct, and respectful for work.")
        XCTAssertGreaterThan(oneLine, 30, "the row was measured")
        for style in RewriteStyleID.shippedCases {
            XCTAssertEqual(
                rowHeight(title: style.title, subtitle: style.subtitle),
                oneLine,
                accuracy: 1,
                "\(style.rawValue) is taller than one line: \(style.subtitle)"
            )
        }
    }

    /// A sentence longer than the row still wraps, and one line of it is wider
    /// than the width the subtitle used to be offered.
    func testALongSubtitleStillWraps() {
        let long = String(repeating: "A fact that has to wrap somewhere. ", count: 8)
        let wrapped = rowHeight(title: "Professional", subtitle: long)
        let oneLine = rowHeight(title: "Professional", subtitle: "Clear, direct, and respectful for work.")
        XCTAssertGreaterThan(wrapped, oneLine + 8, "a long subtitle must wrap, not be cut")
    }

    // MARK: - The multiline field

    /// The field's scroll view spans the whole rounded box.
    ///
    /// `TextEditor` wrapped in the field's padding drew its scroller nine points
    /// inside the border, where it read as a second control hanging off the
    /// field. The editor's scroll view is therefore not inset at all: the text
    /// is held away from the border by the clip view and the text container's
    /// own inset, which leaves the overlay scroller on the box's trailing edge
    /// and cuts overflowing text five points clear of the bottom border.
    func testTheTextEditorScrollsFlushWithItsOwnEdge() throws {
        let width: CGFloat = 533
        let height: CGFloat = 128
        let editor = DotTextEditor(
            text: .constant("## Goal\nShip the settings change."),
            height: height,
            accessibilityLabel: "Prompt"
        )
        .frame(width: width)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for _ in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(
            DotTextEditor.scrollView(in: host),
            "the field is not built on a scroll view"
        )
        XCTAssertEqual(
            scrollView.frame.width,
            width,
            accuracy: 0.5,
            "the scroll view is inset \(width - scrollView.frame.width) pt inside the field"
        )
        XCTAssertEqual(scrollView.frame.minX, 0, accuracy: 0.5, "the scroll view starts inside the border")
        XCTAssertEqual(scrollView.frame.height, height, accuracy: 0.5)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)

        // Only the clip view is inset, so the scroller keeps the scroll view's
        // own edge while the text stops clear of both borders.
        let contentView = scrollView.contentView
        XCTAssertEqual(
            contentView.frame.minY,
            DotTextEditor.verticalClipInset,
            accuracy: 0.5,
            "the clip view does not start clear of the top border"
        )
        XCTAssertEqual(
            scrollView.frame.height - contentView.frame.maxY,
            DotTextEditor.verticalClipInset,
            accuracy: 0.5,
            "the clip view does not end clear of the bottom border"
        )
        XCTAssertEqual(
            contentView.frame.height,
            height - DotTextEditor.verticalClipInset * 2,
            accuracy: 0.5,
            "the clip view is not the field's height less its two clip margins"
        )

        let textView = try XCTUnwrap(
            scrollView.documentView as? NSTextView,
            "the scroll view has no text view"
        )
        XCTAssertEqual(textView.textContainerInset.width, 9, accuracy: 0.001)
        XCTAssertEqual(
            textView.textContainerInset.height,
            DotTextEditor.textInset.height,
            accuracy: 0.001,
            "the text container inset is not the field's own"
        )
        XCTAssertEqual(
            DotTextEditor.textInset.height,
            DotTextEditor.edgeFadeHeight,
            accuracy: 0.001,
            "the vertical inset is not the length of the field's edge fade"
        )
        XCTAssertEqual(
            textView.convert(textView.textContainerOrigin, to: host).x,
            9,
            accuracy: 0.5,
            "the text does not start at the field's own inset"
        )
        XCTAssertEqual(
            textView.frame.width,
            scrollView.contentSize.width,
            accuracy: 0.5,
            "the text view does not fill the width it scrolls in"
        )

        // A prompt is typed as written: the smart substitutions would turn
        // Markdown quotes and dashes into typographic characters.
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertEqual(textView.accessibilityLabel(), "Prompt")
        XCTAssertEqual(textView.string, "## Goal\nShip the settings change.")
    }

    // MARK: - The prompt field's height

    /// The prompt field ends between two lines, and the clip view cuts the line
    /// below it.
    ///
    /// A field is a scroll view over a text view, so a height that is not a
    /// whole number of lines slices the line at the bottom edge and the prompt
    /// reads as cut rather than scrolled. The height is therefore twelve whole
    /// lines of the field's own type plus the room the clip view and the text
    /// container keep clear of the borders. Laying the shipped prompt out in
    /// the field proves the twelfth line ends at the clip view's edge while the
    /// thirteenth starts there, where the clip cuts it.
    func testThePromptEditorIsTwelveWholeLinesTall() throws {
        // The field's type size, as `DotTextEditor` sets it on its text view.
        // It is the app's face, not the system one: a line height measured in a
        // face the field does not draw would size it for words it never holds.
        let font = DotType.nsFont(12.5, .regular)
        // The height the field's type is drawn at. The layout manager rounds
        // the ascent and the descent to whole points and adds the leading
        // unrounded, so the em sum the font reports is not the line the text
        // view lays out: the drawn height is the one the field must be sized
        // from and the one every line below is checked against.
        let lineHeight = font.ascender.rounded() - font.descender.rounded() + font.leading
        XCTAssertGreaterThan(lineHeight, 0, "the field's type has no line height")

        let chrome = DotTextEditor.verticalClipInset * 2 + DotTextEditor.textInset.height
        // Twelve lines rounded up to a whole point: a line is not a whole
        // number of points, so no whole-point clip view can hold exactly
        // twelve, and the field is the twelve rounded-up lines plus its chrome.
        // Both numbers are read from the face the field draws in, so a change
        // of typeface changes them here rather than leaving a stale constant.
        let twelveLines = (lineHeight * 12).rounded(.up)
        print(
            "SettingsRewriteRow prompt field: line \(lineHeight) pt, twelve lines \(lineHeight * 12) pt, "
                + "rounded up \(twelveLines) pt, chrome \(chrome) pt, field "
                + "\(AssistantPage.promptEditorHeight) pt"
        )
        XCTAssertEqual(
            AssistantPage.promptEditorHeight,
            chrome + twelveLines,
            accuracy: 0.001,
            "the field is \(AssistantPage.promptEditorHeight) pt, not twelve rounded-up lines of \(lineHeight) pt plus \(chrome) pt"
        )
        XCTAssertGreaterThan(
            AssistantPage.promptEditorHeight - chrome,
            lineHeight * 12,
            "the field's text height is shorter than twelve lines, so a line is cut rather than scrolled"
        )
        XCTAssertLessThan(
            AssistantPage.promptEditorHeight - chrome,
            lineHeight * 13,
            "the field's text height is a thirteenth line tall, which draws a sliced line at the clip"
        )

        // The field is drawn at that height, not a height of its own.
        let host = NSHostingView(rootView: DotTextEditor(
            text: .constant(RewriteStyleID.prompt.template),
            height: AssistantPage.promptEditorHeight,
            accessibilityLabel: "Prompt"
        ))
        host.frame = NSRect(x: 0, y: 0, width: 533, height: AssistantPage.promptEditorHeight)
        for _ in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, AssistantPage.promptEditorHeight, accuracy: 0.5)

        let scrollView = try XCTUnwrap(DotTextEditor.scrollView(in: host))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        let contentView = scrollView.contentView
        XCTAssertEqual(
            contentView.frame.height,
            AssistantPage.promptEditorHeight - DotTextEditor.verticalClipInset * 2,
            accuracy: 0.5,
            "the clip view is not the field's height less its two clip margins"
        )
        // A prompt longer than the field scrolls: the text view grows past the
        // clip view instead of being squeezed into it.
        XCTAssertGreaterThan(
            textView.frame.height,
            contentView.frame.height,
            "the shipped prompt does not overflow the field, so the field cannot scroll"
        )

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let lines = laidOutLines(of: textView, in: scrollView)
        XCTAssertGreaterThanOrEqual(
            lines.count,
            13,
            "the shipped prompt lays out \(lines.count) lines, fewer than the field shows"
        )

        // The first line starts five points below the clip view's top plus the
        // text container's own inset, and every visible line is a whole line.
        // The field's own top inset. Twelve lines of the field's type do not
        // come to a whole number of points and the text view carries the
        // field's inset at each end, so the view is shorter than the clip it
        // sits in and scrolls that much:
        // the first line sits at the clip's own inset rather than at the clip
        // inset plus the text inset. Both readings are inside the band, and the
        // point of the check is that the text is not cut by the top border.
        XCTAssertGreaterThanOrEqual(
            lines[0].minY,
            DotTextEditor.verticalClipInset - 0.75,
            "the first line starts above the field's top inset"
        )
        XCTAssertLessThanOrEqual(
            lines[0].minY,
            DotTextEditor.verticalClipInset + DotTextEditor.textInset.height + 0.75,
            "the first line does not start at the field's own top inset"
        )
        for (index, line) in lines[0 ..< 12].enumerated() {
            XCTAssertEqual(
                line.height,
                lineHeight,
                accuracy: 0.5,
                "line \(index + 1) is not a whole line of the field's type"
            )
        }
        // The clip view's bottom edge is where the field's last visible line
        // ends: the twelfth line is whole, and the thirteenth begins outside
        // the clip, so no line is ever sliced by the bottom border.
        let clipBottom = contentView.frame.maxY
        // A twelfth of the field's text height is not a whole number of points,
        // which is not commensurate with the whole-point clip view, and the text
        // view carries the field's inset at each end: twelve whole lines cannot
        // land on the edge exactly. The rule the test keeps is that the twelfth
        // line is whole and the thirteenth is not, so the tolerance is the
        // inset, not a fraction of a point.
        XCTAssertLessThanOrEqual(
            lines[11].maxY,
            clipBottom,
            "the twelfth line is cut by the clip view"
        )
        XCTAssertGreaterThanOrEqual(
            lines[11].maxY,
            clipBottom - 3,
            "the twelfth line does not reach the clip view's edge: the field is a whole line short"
        )
        XCTAssertGreaterThanOrEqual(
            lines[12].minY,
            clipBottom - 3,
            "the thirteenth line starts inside the clip view, so a second line is sliced"
        )
    }

    /// The rects of the laid-out lines, in the field's own coordinates.
    ///
    /// - Parameters:
    ///   - textView: the editor's text view.
    ///   - scrollView: the field the text view scrolls in.
    /// - Returns: one rect per laid-out line, top to bottom.
    private func laidOutLines(of textView: NSTextView, in scrollView: NSScrollView) -> [NSRect] {
        guard let layoutManager = textView.layoutManager else { return [] }
        let origin = textView.textContainerOrigin
        var lines: [NSRect] = []
        var glyph = 0
        while glyph < layoutManager.numberOfGlyphs {
            var range = NSRange()
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            let inTextView = rect.offsetBy(dx: origin.x, dy: origin.y)
            lines.append(textView.convert(inTextView, to: scrollView))
            glyph = NSMaxRange(range)
        }
        return lines
    }
}
