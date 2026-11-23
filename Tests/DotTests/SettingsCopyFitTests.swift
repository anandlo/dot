import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Dot
import DotCore

/// Every General row, Standing rules and the long-recordings row keep one
/// complete line at the window's minimum width.
///
/// The settings window is fixed at 820 points. Its 198 point sidebar and one
/// point divider leave 621 points; the page takes 28 points on each side and
/// the card takes 16, leaving a 533 point row. Each row below is the real
/// `SettingsRow` with the control kind the page uses, laid out offscreen in an
/// `NSHostingView`. A subtitle that wraps makes the row taller than the same
/// row carrying a one-word subtitle.
@MainActor
final class SettingsCopyFitTests: XCTestCase {
    private enum ControlKind {
        case toggle
        /// A `DotSelect` showing its widest title, at the page's width (nil sizes to fit).
        case select(String, width: CGFloat?)
        case button(String)
        /// A control drawn at a fixed width: the dwell slider and its readout.
        case fixed(CGFloat)
    }

    private struct RowFixture {
        let title: String
        let subtitle: String
        let control: ControlKind
    }

    /// From SettingsView's window frame, sidebar frame and page inset, and
    /// DotCard's horizontal inset. `testMinimumWidthMatchesLayoutSource`
    /// pins those four numbers to the source.
    private static let windowWidth: CGFloat = 820
    private static let sidebarWidth: CGFloat = 198
    private static let dividerWidth: CGFloat = 1
    private static let pageInset: CGFloat = 28
    private static let cardInset: CGFloat = 16
    private static let rowWidth: CGFloat =
        windowWidth - sidebarWidth - dividerWidth - 2 * pageInset - 2 * cardInset

    /// The old two-sentence copy, used only to prove the height check can see a
    /// wrapped subtitle.
    private static let knownBadSubtitle =
        "The longest stretch of audio sent in one request. A longer recording is sent in parts of this length."

    private static var widestRecordingMode: String {
        RecordingMode.allCases.map(\.title).max { $0.count < $1.count } ?? ""
    }

    /// Every General row, Standing rules and the long-recordings row, with the
    /// strings the pages draw and the widest value each control can show.
    private static var fixtures: [RowFixture] {
        [
            RowFixture(
                title: "Recording mode",
                subtitle: SettingsExplanation.recordingModeSubtitle,
                control: .select(widestRecordingMode, width: nil)
            ),
            RowFixture(title: "Paste into the active app", subtitle: SettingsExplanation.pasteSubtitle, control: .toggle),
            RowFixture(
                title: "Record from the menu bar icon",
                subtitle: SettingsExplanation.menuBarRecordSubtitle,
                control: .toggle
            ),
            RowFixture(title: "Open at login", subtitle: SettingsExplanation.launchSubtitle, control: .toggle),
            RowFixture(
                title: "Keep result on screen",
                subtitle: SettingsExplanation.dwellSubtitle,
                control: .fixed(155 + 12 + 44)
            ),
            RowFixture(
                title: "Include transcripts in the log",
                subtitle: SettingsExplanation.logTranscriptsSubtitle,
                control: .toggle
            ),
            RowFixture(
                title: "Transcripts to keep",
                subtitle: SettingsExplanation.historySubtitle,
                control: .select(String(SettingsView.historyLimitOptions.max() ?? 0), width: nil)
            ),
            RowFixture(
                title: "Microphone",
                subtitle: SettingsExplanation.microphoneSubtitle,
                control: .select("System default", width: nil)
            ),
            RowFixture(
                title: "Microphone noise profile",
                subtitle: SettingsExplanation.calibrationSubtitle,
                control: .button("Reset")
            ),
            RowFixture(title: "Format for each app", subtitle: SettingsExplanation.formatSubtitle, control: .toggle),
            RowFixture(
                title: AssistantPage.standingRulesTitle,
                subtitle: SettingsExplanation.standingRulesSubtitle,
                control: .toggle
            ),
            RowFixture(
                title: "Send long recordings in parts of",
                subtitle: SettingsExplanation.segmentSubtitle,
                control: .select("Service default", width: 220)
            ),
        ]
    }

    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    private func control(_ kind: ControlKind, title: String) -> AnyView {
        switch kind {
        case .toggle:
            AnyView(
                Toggle("", isOn: .constant(true))
                    .labelsHidden()
                    .toggleStyle(DotToggleStyle())
                    .accessibilityLabel(title)
            )
        case let .select(shown, width):
            AnyView(
                DotSelect(
                    label: title,
                    options: [DotSelectOption(value: 0, title: shown)],
                    selection: .constant(0),
                    width: width
                )
            )
        case let .button(label):
            AnyView(Button(label) {}.buttonStyle(DotSecondaryButtonStyle()))
        case let .fixed(width):
            AnyView(Color.clear.frame(width: width, height: 20))
        }
    }

    private func rowHeight(title: String, subtitle: String, control: ControlKind) -> CGFloat {
        let row = SettingsRow(title, subtitle: subtitle) {
            self.control(control, title: title)
        }
        .frame(width: Self.rowWidth)
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: Self.rowWidth, height: 400)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func assertOneLine(
        _ fixture: RowFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = rowHeight(
            title: fixture.title,
            subtitle: fixture.subtitle,
            control: fixture.control
        )
        let baseline = rowHeight(
            title: fixture.title,
            subtitle: "One",
            control: fixture.control
        )
        XCTAssertGreaterThan(baseline, 30, "the row was not measured", file: file, line: line)
        XCTAssertEqual(
            actual,
            baseline,
            accuracy: 1,
            "\(fixture.title) wraps at \(Self.rowWidth) pt: \(fixture.subtitle)",
            file: file,
            line: line
        )
    }

    func testEveryRowSubtitleFitsOnOneLine() {
        XCTAssertEqual(Self.rowWidth, 533)
        for fixture in Self.fixtures {
            assertOneLine(fixture)
        }
    }

    /// A known two-line string must fail this measurement; without this guard
    /// an always-equal height check could pass without seeing any text.
    func testKnownBadFixtureIsDetectedAsTwoLines() {
        let wrapped = rowHeight(
            title: "Send long recordings in parts of",
            subtitle: Self.knownBadSubtitle,
            control: .select("Service default", width: 220)
        )
        let oneLine = rowHeight(
            title: "Send long recordings in parts of",
            subtitle: "One",
            control: .select("Service default", width: 220)
        )
        XCTAssertGreaterThan(wrapped, oneLine + 8, "the height check cannot see a wrapped subtitle")
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func settingsSource() throws -> String {
        try source("Sources/Dot/SettingsView.swift")
    }

    func testMinimumWidthMatchesLayoutSource() throws {
        let settings = try settingsSource()
        let theme = try source("Sources/Dot/DotTheme.swift")
        XCTAssertTrue(settings.contains(".frame(width: 820, height: heightOverride ?? 600)"))
        XCTAssertTrue(settings.contains(".frame(width: 198)"))
        XCTAssertTrue(settings.contains(".padding(.horizontal, 28)"))
        XCTAssertTrue(theme.contains(".padding(.horizontal, 16)"))
    }

    func testGeneralHasExactlyItsFourSections() {
        XCTAssertEqual(
            SettingsView.GeneralSection.allCases.map(\.title),
            ["Recording", "Output", "Microphone", "Formatting"]
        )
    }
}
