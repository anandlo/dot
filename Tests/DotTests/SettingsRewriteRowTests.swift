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
        let oneLine = rowHeight(title: "Formal", subtitle: "Clear and professional.")
        XCTAssertGreaterThan(oneLine, 30, "the row was measured")
        for style in RewriteStyleID.allCases {
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
        let wrapped = rowHeight(title: "Formal", subtitle: long)
        let oneLine = rowHeight(title: "Formal", subtitle: "Clear and professional.")
        XCTAssertGreaterThan(wrapped, oneLine + 8, "a long subtitle must wrap, not be cut")
    }

    func testTheWorkingRulesFieldIsFiveLinesTall() {
        let font = NSFont.systemFont(ofSize: 12.5)
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        XCTAssertEqual(WorkingRulesRow.height, lineHeight * 5 + 14, accuracy: 0.5)
    }
}
