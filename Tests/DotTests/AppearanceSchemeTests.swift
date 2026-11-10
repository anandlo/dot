import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// Which palette a window draws, and when it redraws.
///
/// The theme tile was reported as taking seconds, and later as doing nothing at
/// all, while the model changed in tens of milliseconds. The reason was here:
/// SwiftUI resolves a dynamic `NSColor` against the scheme in its own
/// environment and keeps the answer, so a window whose AppKit appearance moved
/// but whose environment did not went on drawing the old paper. These tests
/// pin the mechanism rather than the appearance, because that is what broke.
@MainActor
final class AppearanceSchemeTests: XCTestCase {
    /// A window whose *appearance* is light draws dark paper when the view says
    /// dark. That is the whole fix: the view carries the choice.
    func testTheViewDecidesThePaperNotTheWindow() throws {
        let light = try luminance(of: swatch(.light), window: .aqua)
        let dark = try luminance(of: swatch(.dark), window: .aqua)

        XCTAssertGreaterThan(light, 0.75, "light paper is \(light)")
        XCTAssertLessThan(dark, 0.25, "dark paper is \(dark)")
    }

    /// The other half of the rule: `system` pins nothing, so the window decides.
    func testTheSystemChoiceFollowsTheWindow() throws {
        let light = try luminance(of: swatch(.system), window: .aqua)
        let dark = try luminance(of: swatch(.system), window: .darkAqua)

        XCTAssertGreaterThan(light, 0.75, "light paper is \(light)")
        XCTAssertLessThan(dark, 0.25, "dark paper is \(dark)")
    }

    // MARK: - Measuring

    /// The paper of one appearance, in a hosting view that was told the
    /// opposite.
    private func swatch(_ mode: AppearanceMode) -> some View {
        DotTheme.paper
            .frame(width: 40, height: 40)
            .dotAppearance(mode)
    }

    private func luminance(of view: some View, window: NSAppearance.Name) throws -> Double {
        let size = CGSize(width: 40, height: 40)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        // The window's own appearance is what the choice may not depend on,
        // except in the `system` case where it is the only input.
        hosting.appearance = NSAppearance(named: window)
        hosting.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = size
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)

        let centre = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        let colour = try XCTUnwrap(centre.usingColorSpace(.deviceRGB))
        return 0.2126 * colour.redComponent
            + 0.7152 * colour.greenComponent
            + 0.0722 * colour.blueComponent
    }
}
