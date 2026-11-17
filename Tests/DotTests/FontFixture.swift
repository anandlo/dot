import AppKit
import XCTest
@testable import Dot

/// Registers the app's typeface for the test process.
///
/// The packaged app is covered by `ATSApplicationFontsPath`, which the build
/// script writes into the bundle, and a test bundle has no such plist entry and
/// no font directory of its own. Without this a rendering test would draw the
/// system font, pass, and prove nothing about the face the app ships: the
/// resolver falls back silently, so the failure would be invisible rather than
/// loud.
enum FontFixture {
    /// The repository's font directory, found from this file.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts")
    }

    /// Registers the repository's fonts, and is safe to call from every suite.
    @discardableResult
    static func register() -> Bool {
        DotType.registerFonts(at: directory)
    }
}
