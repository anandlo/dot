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
    /// The layout assertions measure text, so they need the shipped face rather
    /// than a silent system fallback.
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

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

    func testSemVer200PrecedenceAndMetadata() {
        let ladder = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
        ]
        for index in 0..<(ladder.count - 1) {
            let older = ladder[index]
            let newer = ladder[index + 1]
            XCTAssertTrue(UpdateController.isVersion(newer, newerThan: older), "\(newer) > \(older)")
            XCTAssertFalse(UpdateController.isVersion(older, newerThan: newer), "\(older) < \(newer)")
        }
        XCTAssertFalse(UpdateController.isVersion("1.0.0+20130313", newerThan: "1.0.0+exp.sha"))
        XCTAssertTrue(UpdateController.isVersion("v1.0.1+build.1", newerThan: "1.0.0+build.99"))
        XCTAssertFalse(UpdateController.isVersion("invalid", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateController.isVersion("1.0.0", newerThan: "invalid"))
    }

    func testReleasePageURLValidationAcceptsOnlyTrustedGitHubReleases() {
        XCTAssertNotNil(
            UpdateController.validatedReleasePage("https://github.com/\(ProductLinks.repository)/releases/tag/v1.0.0")
        )
        XCTAssertNotNil(
            UpdateController.validatedReleasePage(" https://github.com/\(ProductLinks.repository)/releases/v1.2.3 ")
        )
        XCTAssertNil(
            UpdateController.validatedReleasePage("http://github.com/\(ProductLinks.repository)/releases/tag/v1.0.0")
        )
        XCTAssertNil(
            UpdateController.validatedReleasePage("https://evil.example/\(ProductLinks.repository)/releases/tag/v1.0.0")
        )
        XCTAssertNil(
            UpdateController.validatedReleasePage("https://github.com/other/repo/releases/tag/v1.0.0")
        )
        XCTAssertNil(
            UpdateController.validatedReleasePage("https://github.com/\(ProductLinks.repository)/issues/1")
        )
        XCTAssertNil(
            UpdateController.validatedReleasePage("https://github.com/\(ProductLinks.repository)/releases/../settings")
        )
        XCTAssertNil(UpdateController.validatedReleasePage("file:///Applications/Dot.app"))
        XCTAssertNil(UpdateController.validatedReleasePage(nil))
        XCTAssertNil(UpdateController.validatedReleasePage("   "))
    }

    /// The colophon prints the version as people read it, never the build
    /// number: the label beside it already says Version, and the build belongs
    /// to the copied bug-report line.
    func testTheColophonValueIsTheReadableVersionWithoutTheBuild() {
        XCTAssertEqual(AboutInfo.valueLine(version: "4.5.6-beta.1"), "4.5.6 Beta 1")
        XCTAssertEqual(AboutInfo.valueLine(version: "9.8.7"), "9.8.7")
        XCTAssertEqual(AboutInfo.valueLine(version: ProductVersion.unknown), ProductVersion.unknown)
        XCTAssertFalse(AboutInfo.valueLine(version: "4.5.6-beta.1").contains("("))
        XCTAssertEqual(
            AboutUpdateState.available(version: "4.5.6-beta.2", page: nil).statusText,
            "Version 4.5.6 Beta 2 available"
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
        XCTAssertEqual(AboutUpdateState.idle.statusText, "")
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
            let status = entry.state.statusText.isEmpty
                ? nil
                : try frame("status", in: box, entryName: entry.name)
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
            if let status {
                XCTAssertLessThan(
                    status.maxX,
                    disc.minX - 8,
                    "\(entry.name): the status reaches into the mark"
                )
                XCTAssertLessThanOrEqual(status.maxY, upper.maxY, "\(entry.name): the status left its band")
            } else {
                XCTAssertNil(box.frames["status"], "\(entry.name): idle should not reserve a status crater")
            }
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

    /// The tagline is part of the wordmark lockup, not another item in the
    /// update column. Its own frame is measured beside the title and the two
    /// controls, so a line that would cover either one fails here.
    func testTheTaglineSitsBelowTheWordmarkWithoutTouchingTheControls() throws {
        let box = FrameBox()
        _ = host(version: "1.0", build: "1", state: .upToDate, box: box)

        let title = try frame("title", in: box, entryName: "tagline")
        let tagline = try frame("tagline", in: box, entryName: "tagline")
        let control = try frame("control", in: box, entryName: "tagline")
        let status = try frame("status", in: box, entryName: "tagline")
        let upper = try frame("upper", in: box, entryName: "tagline")

        XCTAssertGreaterThan(tagline.width, 60, "the tagline frame has no visible width")
        XCTAssertGreaterThan(tagline.height, 8, "the tagline frame has no visible height")
        XCTAssertEqual(tagline.minY - title.maxY, 3, accuracy: 1.5, "the wordmark gap")
        XCTAssertFalse(tagline.intersects(control), "the tagline touches the update control")
        XCTAssertFalse(tagline.intersects(status), "the tagline touches the status line")
        XCTAssertLessThanOrEqual(tagline.maxY, upper.maxY, "the tagline left the upper band")
    }

    /// The 820 by 600 window leaves 565 points for the page. A long version,
    /// long build and long release together must still end above the fade with
    /// no vertical scroll; the extra line under the wordmark may not spend the
    /// page's remaining height.
    func testTheLongCombinedFixtureStillFitsTheLegalWindow() throws {
        let version = "9.8.7-beta.3+release.candidate.20261120"
        let build = "4812.7.19-nightly"
        let release = "9.9.0-rc.1+release.candidate.20261120"
        let box = FrameBox()
        _ = host(
            version: version,
            build: build,
            state: .available(version: release, page: nil),
            box: box
        )

        let plate = try frame("plate", in: box, entryName: "long-combined")
        let actions = try frame("actions", in: box, entryName: "long-combined")
        let openLog = try frame("openLog", in: box, entryName: "long-combined")

        XCTAssertEqual(plate.width, 565, accuracy: 0.6, "the 820 window's page width")
        XCTAssertLessThan(81 + openLog.maxY, 578, "Open log sits under the bottom fade")
        XCTAssertLessThanOrEqual(16 + actions.maxY + 28, 535, "the page needs a vertical scroll at 600 pt")
    }

    /// The control's rectangle is a promise to the eye and to the pointer: one
    /// size and one place in every state the About page can draw. The status
    /// column keeps a capped width and one two-line height so a longer answer
    /// cannot move the button above it.
    func testTheUpdateControlHoldsOneRectAcrossEveryFixture() throws {
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
            ("no-build", "1.0", "", .upToDate),
        ]

        var controls: [(name: String, rect: CGRect)] = []
        for entry in cases {
            let box = FrameBox()
            _ = host(version: entry.version, build: entry.build, state: entry.state, box: box)
            let plate = try frame("plate", in: box, entryName: entry.name)
            let control = try frame("control", in: box, entryName: entry.name)

            XCTAssertEqual(control.width, 132, accuracy: 0.6, "\(entry.name): control width")
            XCTAssertEqual(control.height, 28, accuracy: 0.6, "\(entry.name): control height")
            XCTAssertEqual(
                control.maxX,
                plate.maxX - 16 - 72,
                accuracy: 0.6,
                "\(entry.name): control trailing edge"
            )
            if let status = box.frames["status"] {
                XCTAssertLessThanOrEqual(status.width, 188.6, "\(entry.name): status exceeded compact cap")
            } else {
                XCTAssertTrue(entry.state.statusText.isEmpty, "\(entry.name): non-idle status missing")
            }
            controls.append((entry.name, control))
        }

        let first = controls[0].rect
        for entry in controls.dropFirst() {
            XCTAssertEqual(entry.rect.minX, first.minX, accuracy: 0.6, "\(entry.name): control x")
            XCTAssertEqual(entry.rect.minY, first.minY, accuracy: 0.6, "\(entry.name): control y")
        }
    }

    /// The pointer region is the whole plate, and it still never takes a
    /// click.
    ///
    /// A real click cannot be synthesised in an offscreen host, so the check is
    /// the mechanism: the region is exactly the plate, the tracking view
    /// refuses every hit test, and the control's action path is covered by
    /// `ControlPressCoverageTests` and `activateUpdateForTesting`.
    func testThePointerRegionIsThePlateAndNeverTakesAHit() throws {
        let box = FrameBox()
        let host = host(
            version: "1.0",
            build: "1",
            state: .available(version: "9.9.0", page: nil),
            box: box
        )
        let region = try frame("markRegion", in: box, entryName: "tracking")
        let plate = try frame("plate", in: box, entryName: "tracking")
        let control = try frame("control", in: box, entryName: "tracking")

        XCTAssertEqual(region.minX, plate.minX, accuracy: 0.6, "tracking origin x")
        XCTAssertEqual(region.minY, plate.minY, accuracy: 0.6, "tracking origin y")
        XCTAssertEqual(region.width, plate.width, accuracy: 0.6, "tracking width")
        XCTAssertEqual(region.height, plate.height, accuracy: 0.6, "tracking height")

        let tracker = try XCTUnwrap(trackingView(in: host), "the page mounted no tracking view")
        for point in [
            CGPoint.zero,
            CGPoint(x: control.midX, y: control.midY),
            CGPoint(x: region.maxX - 1, y: region.maxY - 1),
        ] {
            XCTAssertNil(
                tracker.hitTest(NSPoint(x: point.x, y: point.y)),
                "the tracker is a hit target at \(point)"
            )
            XCTAssertFalse(
                host.hitTest(NSPoint(x: point.x, y: point.y)) === tracker,
                "a click at \(point) landed on the tracker"
            )
        }

        var presses = 0
        let page = AboutPage(
            version: "1.0",
            build: "1",
            previewUpdate: .idle,
            onPreviewUpdatePress: { presses += 1 }
        )
        page.activateUpdateForTesting()
        XCTAssertEqual(presses, 1, "the control's action path did not run")
    }

    /// Pointer tracking belongs to the key window only, and the transparent
    /// tracking view must not be a hit target. Its source is checked because a
    /// headless host has no system pointer to move through the region.
    func testTheMarkTracksOnlyTheKeyWindowAndNeverTakesAHit() throws {
        let source = try aboutPageSource()
        XCTAssertTrue(source.contains(".activeInKeyWindow"), "the tracker is active without key")
        XCTAssertFalse(source.contains(".activeAlways"), "the tracker is active in background windows")
        XCTAssertTrue(source.contains("override func hitTest"), "the tracker did not refuse hit testing")
        XCTAssertTrue(source.contains("NSApp.isActive"), "inactive windows can still move the mark")
        XCTAssertTrue(source.contains("isKeyWindow"), "non-key windows can still move the mark")
        XCTAssertTrue(source.contains("object: window"), "the reset watches an unrelated window")
        XCTAssertTrue(source.contains("let controlCanHighlight"), "the highlight is not gated by state")
    }

    /// A control that cannot act must keep its resting fill even when a hover
    /// was left over from the state before the check started.
    func testADisabledUpdateButtonDoesNotTakeTheHighlight() throws {
        let source = try aboutPageSource()
        XCTAssertTrue(
            source.contains("currentUpdate.acceptsAnotherCheck && (controlHovered || controlFocused)"),
            "a disabled control still takes the hover or focus fill"
        )
        XCTAssertTrue(source.contains("controlHovered = false"), "stale hover was not cleared")
        XCTAssertTrue(source.contains("onChange(of: reducesMotion)"), "a stale mark target survives a motion toggle")
        XCTAssertTrue(source.contains("let enabled: Bool"), "the tracker has no enabled state")
    }

    /// A tracking event reports plate-local points with the y axis flipped
    /// from AppKit, the patch centres on that point, the disc does not move,
    /// and only the owning window's resignation resets the patch.
    func testTrackingEventsReportPlateLocalPointsAndOnlyItsWindowResetsThem() throws {
        let view = AboutMarkTrackingView()
        view.frame = NSRect(x: 0, y: 0, width: 565, height: 118)
        view.isActiveProvider = { true }
        view.isKeyWindowProvider = { true }
        var reported: CGPoint?
        view.onMove = { reported = $0 }
        XCTAssertNil(view.hitTest(.zero), "the tracker is a hit target")

        let lowInWindow = try event(at: NSPoint(x: 100, y: 20))
        view.mouseMoved(with: lowInWindow)
        XCTAssertEqual(reported?.x ?? -1, 100, accuracy: 0.001, "reported x")
        XCTAssertEqual(reported?.y ?? -1, 98, accuracy: 0.001, "the y axis is not flipped to plate-local")

        let highInWindow = try event(at: NSPoint(x: 100, y: 98))
        view.mouseMoved(with: highInWindow)
        XCTAssertEqual(reported?.x ?? -1, 100, accuracy: 0.001, "reported x")
        XCTAssertEqual(reported?.y ?? -1, 20, accuracy: 0.001, "the y axis is not flipped to plate-local")

        // The model's patch centres on the reported point, not its mirror.
        let size = CGSize(width: 565, height: 118)
        let input = AboutMotionInput(pointer: CGPoint(x: 100, y: 20))
        let atLow = AboutMotion.Matrix.energy(
            at: CGPoint(x: 100, y: 20),
            input: input,
            plateSize: size
        )
        let atHigh = AboutMotion.Matrix.energy(
            at: CGPoint(x: 100, y: 98),
            input: input,
            plateSize: size
        )
        XCTAssertEqual(atLow, 1, accuracy: 0.01, "patch centre")
        XCTAssertGreaterThan(atLow, atHigh, "the patch is not centred on the reported point")

        // The matrix never moves the disc, before or after a tracking event.
        let box = FrameBox()
        let host = host(version: "1.0", build: "1", state: .upToDate, box: box)
        let tracker = try XCTUnwrap(trackingView(in: host), "the page mounted no tracking view")
        tracker.isActiveProvider = { true }
        tracker.isKeyWindowProvider = { true }
        let rest = try frame("disc", in: box, entryName: "events")
        tracker.mouseEntered(with: lowInWindow)
        tracker.mouseMoved(with: lowInWindow)
        settle(host)
        let moved = try frame("disc", in: box, entryName: "events")
        XCTAssertEqual(moved.minX, rest.minX, accuracy: 0.6, "a tracking event moved the disc")
        XCTAssertEqual(moved.minY, rest.minY, accuracy: 0.6, "a tracking event moved the disc")

        tracker.isActiveProvider = { false }
        tracker.mouseMoved(with: lowInWindow)
        settle(host)
        let inactive = try frame("disc", in: box, entryName: "events")
        XCTAssertEqual(inactive.minX, rest.minX, accuracy: 0.6, "inactive app moved the disc")
        XCTAssertEqual(inactive.minY, rest.minY, accuracy: 0.6, "inactive app moved the disc")

        var resets = 0
        let coordinator = AboutMarkPointerRegion.Coordinator { point in
            if point == nil { resets += 1 }
        }
        let own = OffscreenWindow(size: CGSize(width: 40, height: 40))
        let foreign = OffscreenWindow(size: CGSize(width: 40, height: 40))
        let resetTracker = AboutMarkTrackingView()
        coordinator.watch(own)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: foreign)
        XCTAssertEqual(resets, 0, "a foreign window reset the patch")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: own)
        XCTAssertEqual(resets, 1, "the owning window did not reset the patch")
        coordinator.stop(in: resetTracker)
    }

    /// Disabling the tracker must not emit from SwiftUI's update pass and must
    /// not leave reset observers behind. Re-enabling installs the owner's
    /// observers again; a foreign window still has no authority to reset.
    func testDisablingTheTrackerStopsCallbacksAndObservers() throws {
        var resets = 0
        let coordinator = AboutMarkPointerRegion.Coordinator { point in
            if point == nil { resets += 1 }
        }
        let view = AboutMarkTrackingView()
        view.frame = NSRect(x: 0, y: 0, width: 72, height: 72)
        let window = OffscreenWindow(size: CGSize(width: 200, height: 200))
        window.contentView?.addSubview(view)
        coordinator.setEnabled(true, in: view)

        coordinator.setEnabled(false, in: view)
        XCTAssertEqual(resets, 0, "disabling emitted a synchronous reset")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(resets, 0, "disabled tracker still observed window or app events")

        coordinator.setEnabled(true, in: view)
        let foreign = OffscreenWindow(size: CGSize(width: 200, height: 200))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: foreign)
        XCTAssertEqual(resets, 0, "foreign window reset the tracker after re-enabling")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(resets, 1, "owning window did not reset after re-enabling")
        coordinator.stop(in: view)
    }

    /// The live clock pauses only when the model says every effect has
    /// finished, and it is driven by the model's own predicate.
    func testTheLiveClockPausesWhenThePresentationIsSettled() throws {
        let source = try aboutPageSource()
        let clockSource = try aboutClockSource()
        let leaf = try section(
            of: source,
            from: "private func running(_ store: AboutMotionStore) -> some View {",
            to: "private func canvas(input: AboutMotionInput) -> some View {"
        )
        let leafTimeline = try XCTUnwrap(
            leaf.range(of: "TimelineView(.animation)"),
            "the matrix leaf's running branch has no animation TimelineView"
        )
        let leafCanvas = try XCTUnwrap(
            leaf.range(of: "canvas(input: store.input(at: now()))"),
            "the matrix leaf's running branch does not draw the live canvas"
        )
        XCTAssertLessThan(
            leafTimeline.lowerBound,
            leafCanvas.lowerBound,
            "the matrix canvas is drawn outside the running TimelineView"
        )
        XCTAssertTrue(
            leaf[leafTimeline.upperBound..<leafCanvas.lowerBound].contains("{ _ in"),
            "the matrix canvas is not inside the running TimelineView's content"
        )

        let root = try section(
            of: source,
            from: "private struct AboutPageMotionRoot<Content: View>: View {",
            to: "/// Which of the three shared content groups"
        )
        let entranceTimeline = try XCTUnwrap(
            root.range(of: "TimelineView("),
            "the entrance plate has no TimelineView"
        )
        let entranceSchedule = try XCTUnwrap(
            root.range(of: ".animation(paused:"),
            "the entrance clock is not an animation schedule"
        )
        let entranceContent = try XCTUnwrap(
            root.range(of: "content(running ? sampled(store, at: context.now()) : context)"),
            "the entrance TimelineView does not wrap the page content"
        )
        XCTAssertLessThan(
            entranceTimeline.lowerBound,
            entranceSchedule.lowerBound,
            "the entrance schedule is not inside the TimelineView"
        )
        XCTAssertLessThan(
            entranceSchedule.upperBound,
            entranceContent.lowerBound,
            "the page content is drawn outside the entrance TimelineView"
        )
        XCTAssertTrue(
            root[entranceSchedule.upperBound..<entranceContent.lowerBound].contains("{ _ in"),
            "the page content is not inside the entrance TimelineView's content"
        )
        XCTAssertTrue(
            root.contains("frame.entrance = store.entranceInput(at: time)"),
            "the entrance sample is not entrance-only"
        )
        XCTAssertTrue(
            root.contains("store.stampEntrance(at: time)"),
            "the first root frame does not stamp the entrance epoch"
        )
        XCTAssertTrue(
            root.contains("frame.entranceTime = time"),
            "the matrix is not given the one shared timestamp"
        )
        XCTAssertFalse(
            root.contains("store.input(at: time)"),
            "the root reads the full frame instead of the matrix"
        )
        XCTAssertTrue(
            source.contains("canvas(input: store.input(at: entranceTime))"),
            "the matrix does not derive its full frame at the shared timestamp"
        )

        XCTAssertTrue(
            source.contains("store.paused"),
            "the leaf does not read the store's pause state"
        )
        let pausedStart = try XCTUnwrap(
            source.range(of: "if store.paused {"),
            "the leaf has no paused branch"
        )
        let pausedEnd = try XCTUnwrap(
            source.range(of: "} else {", range: pausedStart.upperBound..<source.endIndex),
            "the paused branch has no alternative"
        )
        let paused = source[pausedStart.upperBound..<pausedEnd.lowerBound]
        XCTAssertTrue(
            paused.contains("store.input(at: now())"),
            "the paused branch does not evaluate the clock at its own reading"
        )
        XCTAssertFalse(
            paused.contains("settleDeadline"),
            "the paused branch samples a future deadline instead of now"
        )
        XCTAssertTrue(
            clockSource.contains("clock.isSettled(at:"),
            "the pause predicate is not the model's"
        )
        XCTAssertTrue(
            clockSource.contains("clock.settleDeadline()"),
            "the loop has no settle deadline"
        )
        XCTAssertFalse(source.contains("Timer.scheduledTimer"), "the page has a timer")
        XCTAssertFalse(source.contains("private func advance(to"), "a per-tick clock survives")
        XCTAssertFalse(source.contains("liveMotion"), "per-frame page state survives")
        XCTAssertFalse(source.contains("CADisplayLink"), "the page has a display link")
        XCTAssertFalse(
            source.contains("frameTime"),
            "a frame-time override survives in the page"
        )

        XCTAssertTrue(AboutMotion.isSettled(AboutMotionInput()), "rest is not settled")
        XCTAssertFalse(
            AboutMotion.isSettled(AboutMotionInput(entranceElapsed: 0)),
            "the entrance did not hold the clock"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(entranceElapsed: 615)),
            "the settled entrance kept the clock"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(pointer: CGPoint(x: 100, y: 20))),
            "a settled held patch is not settled"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(
                AboutMotionInput(
                    pointer: CGPoint(x: 100, y: 20),
                    pointerSettled: false
                )
            ),
            "a travelling spring was called settled"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(AboutMotionInput(update: .checking(elapsed: 0))),
            "the checking fronts are not settled"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(AboutMotionInput(update: .checking(elapsed: 540))),
            "the finished fronts kept the clock"
        )
        XCTAssertFalse(
            AboutMotion.isSettled(
                AboutMotionInput(update: .unreachable(elapsed: 0, frontsElapsed: 250))
            ),
            "the failure fade is not settled"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(
                AboutMotionInput(update: .unreachable(elapsed: 120, frontsElapsed: 250))
            ),
            "the fade's end kept the clock"
        )
        XCTAssertTrue(
            AboutMotion.isSettled(
                AboutMotionInput(update: .unreachable(elapsed: 40, frontsElapsed: 500))
            ),
            "the short front's end kept the clock"
        )
    }

    /// The entrance belongs to a page mounted in a window, runs at most once
    /// per 1.2 s, and either a key or a press inside the page finishes it at
    /// once. The event monitors cannot be driven in a headless host, so the
    /// mechanism and the gate are checked in the page's source.
    func testAPressOrAKeyInsideThePageFinishesTheEntrance() throws {
        let source = try aboutPageSource()
        XCTAssertTrue(source.contains("matching: .keyDown"), "no key monitor")
        XCTAssertTrue(source.contains("matching: .leftMouseDown"), "no press monitor")
        XCTAssertTrue(
            source.contains("self.bounds.contains(self.convert(point, from: nil))"),
            "a press outside the page finishes the entrance"
        )
        XCTAssertTrue(source.contains("onPress?()"), "the press monitor does not finish the entrance")
        XCTAssertTrue(source.contains("onKeyDown?()"), "the key monitor does not finish the entrance")
        XCTAssertTrue(source.contains("finishEntrance()"), "the page cannot finish its entrance")
        XCTAssertTrue(
            source.contains("minimumGap: Double = 1200"),
            "the entrance has no 1.2 s gate"
        )
        XCTAssertTrue(
            try aboutClockSource().contains("time - last < AboutEntranceGate.minimumGap"),
            "the gate is not applied"
        )
        XCTAssertTrue(
            try aboutClockSource().contains("entranceFinished = true"),
            "the cooldown branch does not settle the entrance state"
        )
        XCTAssertTrue(
            source.contains("Task { @MainActor [weak self] in"),
            "window presence is not reported to the page"
        )
        XCTAssertTrue(
            source.contains("guard let self, !self.dismantled else { return }"),
            "the bridge does not re-check dismantle at delivery"
        )
        XCTAssertTrue(
            source.contains("self.onChange?(self.window.map(ObjectIdentifier.init))"),
            "the bridge does not call the current callback with the current window"
        )
        XCTAssertFalse(
            source.contains("let callback = onChange"),
            "the bridge captures a callback before posting"
        )
        XCTAssertFalse(
            source.contains("callback?(identity)"),
            "the bridge can deliver a stale window identity"
        )
        XCTAssertTrue(
            source.contains("windowIdentity != window"),
            "the attach is not guarded by the window's identity"
        )
    }

    /// Reduce Motion has no elapsed path and no movement: only the fill's
    /// opacity animates. The leaf's SwiftUI animation cannot be observed in a
    /// headless host, so the mechanism is checked in the source and the values
    /// in AboutMotionTests.
    func testReduceMotionRowsAnimateOnlyTheFill() throws {
        let source = try aboutPageSource()
        XCTAssertTrue(
            source.contains("if reduceMotion { return .easeOut(duration: 0.12) }"),
            "the fill has no 120 ms opacity animation"
        )
        XCTAssertTrue(
            source.contains("guard engaged, !reduceMotion else { return .zero }"),
            "the arrow still moves under Reduce Motion"
        )
        // The page must not disable animations for the whole Reduce Motion
        // subtree: that would also disable the one animation the mode keeps.
        // The sampled-preview branch is the only place that disables them.
        let disablingBranches = source
            .components(separatedBy: ".transaction { $0.disablesAnimations = true }")
            .count - 1
        XCTAssertEqual(
            disablingBranches,
            1,
            "the Reduce Motion page disables the row fill's animation"
        )
        XCTAssertTrue(
            source.contains("windowPresent && !reducesMotion ? .easeOut(duration: 0.12) : nil"),
            "the status line still animates under Reduce Motion"
        )
    }

    /// The production page allocates no probe and installs no callbacks; a
    /// probe exists only when someone passes one in.
    func testProductionAllocatesNoLiveProbe() throws {
        let source = try aboutPageSource()
        XCTAssertFalse(
            source.contains("@StateObject private var internalProbe"),
            "the page still allocates its own probe"
        )
        XCTAssertFalse(source.contains("liveProbe"), "the page still falls back to a probe")
        XCTAssertTrue(
            source.contains("var probe: AboutLiveProbe?"),
            "the probe is not an injected optional"
        )
        XCTAssertFalse(
            source.contains("internalProbe"),
            "the page allocates a probe of its own"
        )
        XCTAssertTrue(source.contains("clearProbe()"), "the probe callbacks are never cleared")
    }

    /// The softer rules keep their one-point geometry, and the control's fill
    /// still answers a highlight when movement is turned off.
    func testTheSoftenedRulesAndControlFillKeepTheirValues() throws {
        let box = FrameBox()
        _ = host(version: "1.0", build: "1", state: .idle, box: box)
        let rule = try frame("rule", in: box, entryName: "rules")
        let separator = try frame("separator", in: box, entryName: "rules")

        XCTAssertEqual(rule.height, 1, accuracy: 0.1, "the horizontal rule changed height")
        XCTAssertEqual(separator.width, 1, accuracy: 0.1, "the vertical rule changed width")
        XCTAssertEqual(AboutControlFill.opacity(isHighlighted: false), 0.08)
        XCTAssertEqual(AboutControlFill.opacity(isHighlighted: true), 0.13)

        let source = try aboutPageSource()
        XCTAssertTrue(source.contains("static let rule = edge.opacity(0.45)"))
    }

    /// The update alert reads versions as words, but two builds whose readable
    /// forms match are named exactly so the alert never offers a version itself.
    func testTheUpdateAlertNamesCollidingVersionsExactly() {
        XCTAssertEqual(
            UpdateController.updateAvailableText(latest: "4.5.6-beta.2", current: "4.5.6-beta.1"),
            "Dot 4.5.6 Beta 2 is available. This is 4.5.6 Beta 1."
        )
        XCTAssertEqual(
            UpdateController.updateAvailableText(latest: "4.5.6-rc1", current: "4.5.6-rc.1"),
            "Dot 4.5.6-rc1 is available. This is 4.5.6-rc.1."
        )
    }

    /// A status line can be visually capped without shortening the value the
    /// control hands to a screen reader.
    func testTheFullStatusRemainsTheAccessibilityValue() throws {
        let release = "9.9.0-rc.1.candidate.with.a.long.prerelease.name+build.20261120"
        XCTAssertEqual(
            AboutUpdateState.available(version: release, page: nil).statusText,
            "Version 9.9.0 RC 1 Candidate With A Long Prerelease Name available"
        )
        let source = try aboutPageSource()
        XCTAssertTrue(source.contains(".accessibilityValue(currentUpdate.statusText)"))
        XCTAssertTrue(source.contains(".buttonStyle(DotPressStyle())"))
    }

    /// Both row builders wire the same focus binding and the same continuous
    /// hover handler. The real focus engine cannot be driven in a window that
    /// is never key, so the shared handlers are also driven through the probe
    /// in `AboutLiveTests`; this checks the wiring those tests cannot reach.
    func testTheRowClosuresUseTheSharedFocusAndHoverHandlers() throws {
        let source = try aboutPageSource()
        func occurrences(_ needle: String) -> Int {
            source.components(separatedBy: needle).count - 1
        }
        XCTAssertEqual(
            occurrences(".focused($internalFocusedRow, equals: index)"),
            2,
            "a row does not bind the shared focus state"
        )
        XCTAssertEqual(
            occurrences(".onContinuousHover { phase in"),
            2,
            "a row has no continuous hover"
        )
        XCTAssertEqual(
            occurrences("handleRowHover(index, phase)"),
            2,
            "a row's hover closure does not call the shared handler"
        )
        XCTAssertEqual(
            occurrences(".onHover { inside in"),
            2,
            "a row has no entered/exited hover"
        )
        XCTAssertEqual(
            occurrences("rowHoverEnded(index)"),
            2,
            "a row's exit closure does not call the shared handler"
        )
    }

    /// The sampled frame a clip draws and the clock-driven content the live
    /// page draws are one model: the same input through both paths produces
    /// the same plate, byte for byte.
    func testThePreviewClockAndSampledFrameDrawTheSameModel() throws {
        FontFixture.register()
        let size = CGSize(width: 565, height: 600)
        let pointer = CGPoint(x: 300, y: 40)
        let input = AboutMotionInput(
            entranceElapsed: 100,
            pointer: pointer,
            update: .checking(elapsed: 200)
        )
        let clock = AboutMotionClock(
            entranceStartedAt: 0,
            pointer: AboutPointerTimeline(point: pointer, at: 0),
            update: .checking(startedAt: -100)
        )

        func plate(_ page: AboutPage) throws -> Data {
            let hosting = NSHostingView(
                rootView: ScrollView(.vertical) {
                    page.frame(width: size.width)
                }
                .frame(width: size.width, height: size.height)
            )
            hosting.frame = NSRect(origin: .zero, size: size)
            for _ in 0..<4 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            hosting.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * 2,
                pixelsHigh: Int(size.height) * 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), "no bitmap")
            rep.size = size
            hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]), "no PNG")
        }

        let sampled = try plate(
            AboutPage(version: "1.0", build: "1", previewMotion: input)
        )
        let clocked = try plate(
            AboutPage(
                version: "1.0",
                build: "1",
                previewClock: clock,
                previewTime: 100
            )
        )
        XCTAssertEqual(
            sampled,
            clocked,
            "the sampled frame and the clock-driven frame disagree"
        )
    }

    /// The frames are collected from an offscreen hosting view, never from a
    /// window on screen.
    @MainActor
    private final class FrameBox {
        var frames: [String: CGRect] = [:]
    }

    private func settle(_ host: NSView) {
        for _ in 0..<12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
    }

    private func event(at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )
    }

    private func trackingView(in view: NSView) -> AboutMarkTrackingView? {
        if let found = view as? AboutMarkTrackingView { return found }
        for child in view.subviews {
            if let found = trackingView(in: child) { return found }
        }
        return nil
    }

    private func aboutClockSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Dot/AboutClock.swift"),
            encoding: .utf8
        )
    }

    private func aboutPageSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Dot/AboutPage.swift"),
            encoding: .utf8
        )
    }

    /// The source between two markers, so a production check reads the one
    /// branch it is about instead of the whole file.
    private func section(
        of source: String,
        from start: String,
        to end: String
    ) throws -> Substring {
        let lower = try XCTUnwrap(
            source.range(of: start),
            "no source section starts at \(start)"
        )
        let upper = try XCTUnwrap(
            source.range(of: end, range: lower.upperBound..<source.endIndex),
            "no source section ends at \(end)"
        )
        return source[lower.lowerBound..<upper.lowerBound]
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

    func testUpdateControllerSemVerLeadingZeroAndURLHardeningEdgeCases() {
        XCTAssertTrue(UpdateController.isVersion("1.0.0-01.2", newerThan: "1.0.0-1.1"))
        XCTAssertFalse(UpdateController.isVersion("1.0.0-01", newerThan: "1.0.0-1"))
        XCTAssertNil(UpdateController.validatedReleasePage("https://evil@github.com/anandlo/dot/releases/tag/v1.0"))
        XCTAssertNil(UpdateController.validatedReleasePage("https://github.com:8443/anandlo/dot/releases/tag/v1.0"))
        XCTAssertNil(UpdateController.validatedReleasePage("https://github.com/anandlo/dot/releases/..%2Fsettings"))
    }

    func testPorcelainDiscHasNoInnerConcentricRing() throws {
        let source = try aboutPageSource()
        let drawDisc = try section(
            of: source,
            from: "private func drawDisc(",
            to: "/// The gap that keeps the entrance"
        )
        XCTAssertFalse(drawDisc.contains("innerRadius"))
        XCTAssertFalse(drawDisc.contains("innerRect"))

        let plateSize = CGSize(width: 509, height: 224)
        let box = FrameBox()
        let hosted = host(version: "9.8.7-beta", build: "1", state: .idle, box: box)
        _ = hosted
        let center = AboutMotion.Plate.discCentre(plateSize: plateSize)
        XCTAssertGreaterThan(center.x, plateSize.width * 0.7)
    }
}
