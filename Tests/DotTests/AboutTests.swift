import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Dot
@testable import DotCore

/// The version line the About window prints and the copy button hands over.
///
/// A bug report gets its build from that line, so its format is checked here
/// rather than left to the eye: a line that names the version but not the build
/// sends whoever reads the report to the wrong binary. The sample numbers are
/// deliberately not this product's: the version is written down once, in
/// `VERSION`, and a test that repeated it would be a second copy to keep.
@MainActor
final class AboutTests: XCTestCase {
    func testTheCopyLineCarriesTheVersionTheBuildAndTheSystem() {
        let line = AboutInfo.copyLine(version: "9.8.7-beta", build: "7", macOS: "14.5")
        XCTAssertEqual(line, "Dot 9.8.7-beta (7), macOS 14.5")
    }

    func testTheSystemVersionDropsAPatchOfZero() {
        XCTAssertEqual(
            AboutInfo.operatingSystem(
                OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
            ),
            "14.5"
        )
        XCTAssertEqual(
            AboutInfo.operatingSystem(
                OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 3)
            ),
            "14.5.3"
        )
    }

    /// The update row compares the newest tag with the running build, and a
    /// prerelease suffix must not change the numbers in front of it.
    func testANewerReleaseIsRecognisedAcrossAPrereleaseSuffix() {
        XCTAssertTrue(UpdateController.isVersion("9.8.8", newerThan: "9.8.7-beta"))
        XCTAssertTrue(UpdateController.isVersion("9.8.8", newerThan: "9.8"))
        // The final release of a beta is the newer build, not the same one.
        XCTAssertTrue(UpdateController.isVersion("9.8.7", newerThan: "9.8.7-beta"))
        XCTAssertFalse(UpdateController.isVersion("9.8.7-beta", newerThan: "9.8.7-beta"))
        XCTAssertFalse(UpdateController.isVersion("1.9.9", newerThan: "2.0.0"))
    }

    /// The colophon prints a value, not a sentence: the label beside it already
    /// says Version. An absent, blank or unknown build must not leave empty
    /// parentheses behind.
    func testTheColophonValueKeepsTheBuildSemantics() {
        XCTAssertEqual(
            AboutInfo.valueLine(version: "9.8.7-beta", build: "7031"),
            "9.8.7-beta (7031)"
        )
        XCTAssertEqual(AboutInfo.valueLine(version: "9.8.7-beta", build: nil), "9.8.7-beta")
        XCTAssertEqual(AboutInfo.valueLine(version: "9.8.7-beta", build: ""), "9.8.7-beta")
        XCTAssertEqual(
            AboutInfo.valueLine(version: "9.8.7-beta", build: ProductVersion.unknown),
            "9.8.7-beta"
        )
        XCTAssertEqual(
            AboutInfo.versionLine(version: "9.8.7-beta", build: "7031"),
            "Version 9.8.7-beta (7031)"
        )
        // The live copy path resolves an absent build to the bundle's own
        // before it writes the exact bug-report line.
        XCTAssertEqual(
            AboutInfo.copyLine(version: "1.0", build: AboutInfo.build, macOS: "14.5"),
            "Dot 1.0 (\(AboutInfo.build)), macOS 14.5"
        )
    }

    /// The control's name and state are one set of words in every state, and a
    /// check already in flight keeps the control out of a second fetch.
    func testTheUpdateControlNamesAndGuard() {
        XCTAssertEqual(AboutUpdateState.idle.controlLabel, "Check for updates")
        XCTAssertEqual(AboutUpdateState.checking.controlLabel, "Check for updates")
        XCTAssertEqual(AboutUpdateState.upToDate.controlLabel, "Check for updates")
        XCTAssertEqual(AboutUpdateState.unreachable.controlLabel, "Check for updates")
        XCTAssertEqual(
            AboutUpdateState.available(version: "9.9.0", page: nil).controlLabel,
            "View release"
        )
        XCTAssertEqual(AboutUpdateState.idle.statusText, "Not checked")
        XCTAssertEqual(AboutUpdateState.checking.statusText, "Checking...")
        XCTAssertEqual(AboutUpdateState.upToDate.statusText, "Up to date")
        XCTAssertEqual(
            AboutUpdateState.available(version: "9.9.0", page: nil).statusText,
            "Version 9.9.0 available"
        )
        XCTAssertEqual(AboutUpdateState.unreachable.statusText, "Could not reach GitHub")
        XCTAssertFalse(AboutUpdateState.checking.acceptsAnotherCheck)
        XCTAssertTrue(AboutUpdateState.idle.acceptsAnotherCheck)
    }

    /// Pressing the control in a preview counts the press and sends no request.
    func testAPreviewPressCountsWithoutARequest() {
        var presses = 0
        let page = AboutPage(
            version: "1.0",
            build: "1",
            previewUpdate: .idle,
            onPreviewUpdatePress: { presses += 1 }
        )
        page.activateUpdateForTesting()
        page.activateUpdateForTesting()
        XCTAssertEqual(presses, 2)
    }

    /// The approved plate, measured where SwiftUI lays it out off screen.
    ///
    /// The frame reader is the production seam the renderer's view already
    /// carries. Every state is hosted at the page's real width, so a change to
    /// the mark's geometry, the reserved column or the band heights fails here
    /// instead of surviving as a render nobody measures.
    func testTheDialPlateLaysOutAtTheApprovedGeometry() throws {
        let longVersion = "9.8.7-beta.3+release.candidate.20261120"
        let longBuild = "4812.7.19-nightly"
        let longRelease = "9.9.0-rc.1+release.candidate.20261120"
        let cases: [(name: String, version: String, build: String?, state: AboutUpdateState)] = [
            ("idle", "1.0", "1", .idle),
            ("checking", "1.0", "1", .checking),
            ("current", "1.0", "1", .upToDate),
            ("available", "1.0", "1", .available(version: "9.9.0", page: nil)),
            ("unreachable", "1.0", "1", .unreachable),
            ("long", longVersion, longBuild, .upToDate),
            ("long-combined", longVersion, longBuild, .available(version: longRelease, page: nil)),
            // The render sends an empty build for no-build. A nil would pick up
            // the preview's default build number instead.
            ("no-build", "1.0", "", .upToDate),
        ]

        for entry in cases {
            let box = FrameBox()
            _ = host(
                version: entry.version,
                build: entry.build,
                state: entry.state,
                box: box
            )
            if DotMigration.environment("ABOUT_LAYOUT_DUMP") != nil {
                print("ABOUT-FRAMES \(entry.name): \(box.frames)")
            }
            let plate = try frame("plate", in: box, entryName: entry.name)
            let upper = try frame("upper", in: box, entryName: entry.name)
            let rule = try frame("rule", in: box, entryName: entry.name)
            let lower = try frame("lower", in: box, entryName: entry.name)
            let title = try frame("title", in: box, entryName: entry.name)
            let control = try frame("control", in: box, entryName: entry.name)
            let status = try frame("status", in: box, entryName: entry.name)
            let disc = try frame("disc", in: box, entryName: entry.name)
            let versionCell = try frame("versionCell", in: box, entryName: entry.name)
            let versionLabel = try frame("versionLabel", in: box, entryName: entry.name)
            let versionValue = try frame("versionValue", in: box, entryName: entry.name)
            let separator = try frame("separator", in: box, entryName: entry.name)
            let systemCell = try frame("systemCell", in: box, entryName: entry.name)
            let systemLabel = try frame("systemLabel", in: box, entryName: entry.name)
            let systemValue = try frame("systemValue", in: box, entryName: entry.name)
            let copy = try frame("copy", in: box, entryName: entry.name)
            let actions = try frame("actions", in: box, entryName: entry.name)
            let openLog = try frame("openLog", in: box, entryName: entry.name)

            XCTAssertEqual(plate.width, 565, accuracy: 0.6, "\(entry.name): plate width")
            XCTAssertEqual(plate.minX, 0, accuracy: 0.6, "\(entry.name): plate origin")
            XCTAssertGreaterThanOrEqual(upper.height, 72, "\(entry.name): upper band")
            XCTAssertGreaterThanOrEqual(lower.height, 44, "\(entry.name): colophon")
            XCTAssertEqual(rule.minY, upper.maxY, accuracy: 1.1, "\(entry.name): rule position")
            XCTAssertEqual(rule.maxY, lower.minY, accuracy: 1.1, "\(entry.name): rule joins the colophon")
            XCTAssertEqual(lower.maxY, plate.maxY, accuracy: 1.1, "\(entry.name): plate foot")

            // The mark is the icon's clipped dial on a 100 pt square. The disc
            // is bigger than its corner of the plate, which is what makes the
            // plate's single mask the thing that draws its edge.
            XCTAssertEqual(disc.width, 66, accuracy: 0.6, "\(entry.name): disc diameter")
            XCTAssertEqual(disc.height, 66, accuracy: 0.6, "\(entry.name): disc height")
            XCTAssertEqual(
                disc.midX,
                plate.maxX - 25.5,
                accuracy: 0.6,
                "\(entry.name): disc centre x"
            )
            XCTAssertEqual(disc.midY, 25.5, accuracy: 0.6, "\(entry.name): disc centre y")
            XCTAssertGreaterThan(disc.maxX, plate.maxX, "\(entry.name): the disc is cropped at the right")
            XCTAssertLessThan(disc.minY, plate.minY, "\(entry.name): the disc is cropped at the top")

            XCTAssertLessThan(title.maxX, control.minX, "\(entry.name): title and control overlap")
            XCTAssertLessThan(
                control.maxX,
                disc.minX - 8,
                "\(entry.name): the control reaches into the mark"
            )
            XCTAssertLessThan(
                status.maxX,
                disc.minX - 8,
                "\(entry.name): the status reaches into the mark"
            )
            XCTAssertLessThanOrEqual(status.maxY, upper.maxY, "\(entry.name): the status left its band")
            XCTAssertGreaterThanOrEqual(control.height, 28, "\(entry.name): the label area is too short")

            XCTAssertEqual(versionCell.minX, plate.minX, accuracy: 1, "\(entry.name): version cell origin")
            XCTAssertEqual(systemCell.maxX, plate.maxX, accuracy: 1, "\(entry.name): macOS cell end")
            XCTAssertLessThanOrEqual(versionCell.maxX, separator.minX, "\(entry.name): version cell cross")
            XCTAssertLessThanOrEqual(separator.maxX, systemCell.minX, "\(entry.name): macOS cell cross")
            XCTAssertLessThanOrEqual(copy.maxX, versionCell.maxX, "\(entry.name): copy control outside cell")

            // The cells carry the inset themselves, so the macOS text starts a
            // full 16 pt past the centred separator rather than against it.
            XCTAssertGreaterThanOrEqual(
                versionLabel.minX,
                plate.minX + 15,
                "\(entry.name): Version label inset"
            )
            XCTAssertGreaterThanOrEqual(
                versionValue.minX,
                plate.minX + 15,
                "\(entry.name): version value inset"
            )
            XCTAssertLessThanOrEqual(
                versionLabel.maxX,
                separator.minX - 15,
                "\(entry.name): Version label reaches the separator"
            )
            XCTAssertLessThanOrEqual(
                versionValue.maxX,
                separator.minX - 15,
                "\(entry.name): version value reaches the separator"
            )
            XCTAssertGreaterThanOrEqual(
                systemLabel.minX,
                separator.maxX + 15,
                "\(entry.name): macOS label starts against the separator"
            )
            XCTAssertGreaterThanOrEqual(
                systemValue.minX,
                separator.maxX + 15,
                "\(entry.name): macOS value starts against the separator"
            )
            XCTAssertLessThanOrEqual(
                systemValue.maxX,
                plate.maxX - 15,
                "\(entry.name): macOS value outside the plate"
            )
            XCTAssertGreaterThanOrEqual(
                plate.maxY - versionValue.maxY,
                5,
                "\(entry.name): the version value touches the plate foot"
            )
            XCTAssertGreaterThanOrEqual(
                plate.maxY - systemValue.maxY,
                5,
                "\(entry.name): the macOS value touches the plate foot"
            )

            // The page's scroll viewport starts 65 pt into the window, after
            // the 64 pt header and its hairline, and holds 535 pt at 600. The
            // fade covers the last 22 pt of that viewport.
            XCTAssertLessThan(
                81 + openLog.maxY,
                578,
                "\(entry.name): Open log sits under the bottom fade"
            )
            XCTAssertLessThanOrEqual(
                16 + actions.maxY + 28,
                535,
                "\(entry.name): the page needs a vertical scroll at 600 pt"
            )
        }
    }

    /// The frames are collected from an offscreen hosting view, never from a
    /// window on screen.
    @MainActor
    private final class FrameBox {
        var frames: [String: CGRect] = [:]
    }

    private func host(
        version: String,
        build: String?,
        state: AboutUpdateState,
        box: FrameBox
    ) -> NSHostingView<AnyView> {
        let page = AboutPage(
            version: version,
            build: build,
            previewUpdate: state,
            onLayout: { box.frames = $0.frames }
        )
        let host = NSHostingView(
            rootView: AnyView(
                ScrollView(.vertical) {
                    page.frame(width: 565)
                }
                .frame(width: 565, height: 600)
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 565, height: 600)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return host
    }

    private func frame(
        _ name: String,
        in box: FrameBox,
        entryName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGRect {
        try XCTUnwrap(box.frames[name], "\(entryName): \(name) was not measured", file: file, line: line)
    }
}
