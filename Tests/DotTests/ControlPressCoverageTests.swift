import Foundation
import XCTest

/// The press every surface answers with.
///
/// The app has one press policy, ``DotPressFeedback``, and one style that draws
/// it, ``DotPressStyle``. A surface that kept `.plain`, or that grew a private
/// `ButtonStyle` with its own scale and its own animation, would be a second
/// policy - and its reduced-motion answer is the part that drifts first, because
/// nothing on screen shows the difference until someone asks the system to still
/// motion.
///
/// The scan reads the files the press was moved into. It is a contract test: the
/// table below is the coverage the migration promised, so a control that loses
/// the shared press is a failing test rather than a button that quietly stopped
/// moving.
final class ControlPressCoverageTests: XCTestCase {
    /// A surface that takes the shared press, and how many controls on it do.
    private struct Surface {
        let path: String
        let controls: Int
    }

    /// The surfaces the shared press owns.
    ///
    /// A surface with a specialised style - the primary and secondary buttons of
    /// the settings pages - is not listed: those styles draw their own chrome and
    /// take the shared feedback from ``DotPressFeedback`` instead.
    private static let surfaces = [
        Surface(path: "Sources/Dot/HistoryView.swift", controls: 3),
        Surface(path: "Sources/Dot/Palette.swift", controls: 2),
        Surface(path: "Sources/Dot/SettingsView.swift", controls: 8),
        Surface(path: "Sources/Dot/Settings/AssistantPage.swift", controls: 5),
        Surface(path: "Sources/Dot/AboutPage.swift", controls: 5),
        Surface(path: "Sources/Dot/WelcomeView.swift", controls: 1),
        Surface(path: "Sources/Dot/WelcomeTour.swift", controls: 1),
    ]

    /// The package root, found from this file.
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(of path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testEveryMappedControlTakesTheSharedPress() throws {
        for surface in Self.surfaces {
            let text = try text(of: surface.path)
            XCTAssertGreaterThanOrEqual(
                occurrences(of: "buttonStyle(DotPressStyle())", in: text),
                surface.controls,
                "\(surface.path) has fewer controls on the shared press than the migration mapped"
            )
        }
    }

    func testNoMappedSurfaceDrawsAPlainButtonOrItsOwnPress() throws {
        for surface in Self.surfaces {
            let text = try text(of: surface.path)
            XCTAssertFalse(
                text.contains("buttonStyle(.plain)"),
                "\(surface.path) still draws a plain button, which takes no press at all"
            )
            XCTAssertFalse(
                text.contains(": ButtonStyle"),
                "\(surface.path) declares its own press; the app has one press, in DotTheme"
            )
        }
    }

    func testTheDropdownTriggerAnswersWithItsFillAndNeverWithItsGeometry() throws {
        let text = try text(of: "Sources/Dot/DotSelect.swift")
        XCTAssertFalse(
            text.contains("scaleEffect"),
            "the trigger's anchor is its frame: a scaled field would open the list off the control"
        )
        XCTAssertTrue(
            text.contains("DotPressFeedback.animation("),
            "the held trigger takes the shared press timing rather than a curve of its own"
        )
    }
}
