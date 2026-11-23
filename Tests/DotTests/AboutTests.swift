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
        var statuses: [(name: String, rect: CGRect)] = []
        for entry in cases {
            let box = FrameBox()
            _ = host(version: entry.version, build: entry.build, state: entry.state, box: box)
            let plate = try frame("plate", in: box, entryName: entry.name)
            let control = try frame("control", in: box, entryName: entry.name)
            let status = try frame("status", in: box, entryName: entry.name)

            XCTAssertEqual(control.width, 132, accuracy: 0.6, "\(entry.name): control width")
            XCTAssertEqual(control.height, 28, accuracy: 0.6, "\(entry.name): control height")
            XCTAssertEqual(
                control.maxX,
                plate.maxX - 16 - 72,
                accuracy: 0.6,
                "\(entry.name): control trailing edge"
            )
            XCTAssertEqual(status.width, 200, accuracy: 0.6, "\(entry.name): status column width")
            controls.append((entry.name, control))
            statuses.append((entry.name, status))
        }

        let first = controls[0].rect
        for entry in controls.dropFirst() {
            XCTAssertEqual(entry.rect.minX, first.minX, accuracy: 0.6, "\(entry.name): control x")
            XCTAssertEqual(entry.rect.minY, first.minY, accuracy: 0.6, "\(entry.name): control y")
        }
        let statusHeight = statuses[0].rect.height
        XCTAssertGreaterThanOrEqual(statusHeight, 24, "the status reserve is not two lines")
        for entry in statuses {
            XCTAssertEqual(entry.rect.height, statusHeight, accuracy: 0.6, "\(entry.name): status height")
        }
    }

    /// The pointer region belongs to the disc corner alone. Its frame is
    /// measured beside the control and the status, so a wider tracking area
    /// cannot quietly take their clicks.
    func testTheMarkTrackingRegionStaysClearOfTheUpdateColumn() throws {
        let box = FrameBox()
        _ = host(version: "1.0", build: "1", state: .available(version: "9.9.0", page: nil), box: box)
        let region = try frame("markRegion", in: box, entryName: "tracking")
        let control = try frame("control", in: box, entryName: "tracking")
        let status = try frame("status", in: box, entryName: "tracking")
        let plate = try frame("plate", in: box, entryName: "tracking")

        XCTAssertEqual(region.width, 72, accuracy: 0.6, "tracking width")
        XCTAssertEqual(region.height, 72, accuracy: 0.6, "tracking height")
        XCTAssertEqual(region.maxX, plate.maxX, accuracy: 0.6, "tracking corner")
        XCTAssertEqual(region.minY, plate.minY, accuracy: 0.6, "tracking top")
        XCTAssertFalse(region.intersects(control), "the tracking region covers the control")
        XCTAssertFalse(region.intersects(status), "the tracking region covers the status")
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

    /// The tracker is driven by real AppKit mouse methods on the same
    /// offscreen view the page mounted. No system pointer moves and no window
    /// is placed on a display. The callback is read back through the hosted
    /// disc frame, then inactive input and a foreign window's reset are
    /// checked through the same view.
    func testTrackingEventsMoveTheHostedMarkAndOnlyItsWindowResetsIt() throws {
        let box = FrameBox()
        let host = host(version: "1.0", build: "1", state: .upToDate, box: box)
        let tracker = try XCTUnwrap(trackingView(in: host), "the page mounted no tracking view")
        tracker.isActiveProvider = { true }
        tracker.isKeyWindowProvider = { true }
        XCTAssertNil(tracker.hitTest(.zero), "the tracker is a hit target")

        let rest = try frame("disc", in: box, entryName: "events")
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 72, y: 0),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )
        tracker.mouseEntered(with: event)
        tracker.mouseMoved(with: event)
        settle(host)
        let engaged = try frame("disc", in: box, entryName: "events")
        XCTAssertEqual(engaged.minX, rest.minX + 6, accuracy: 0.6, "entered pointer x")
        XCTAssertEqual(engaged.minY, rest.minY + 4, accuracy: 0.6, "moved pointer y")

        tracker.isActiveProvider = { false }
        tracker.mouseMoved(with: event)
        settle(host)
        let inactive = try frame("disc", in: box, entryName: "events")
        XCTAssertEqual(inactive.minX, rest.minX, accuracy: 0.6, "inactive app moved the mark")
        XCTAssertEqual(inactive.minY, rest.minY, accuracy: 0.6, "inactive app moved the mark")

        tracker.isActiveProvider = { true }
        tracker.mouseMoved(with: event)
        settle(host)
        tracker.mouseExited(with: event)
        settle(host)
        let exited = try frame("disc", in: box, entryName: "events")
        XCTAssertEqual(exited.minX, rest.minX, accuracy: 0.6, "exit did not return the mark")
        XCTAssertEqual(exited.minY, rest.minY, accuracy: 0.6, "exit did not return the mark")

        var resets = 0
        let coordinator = AboutMarkPointerRegion.Coordinator { point in
            if point == nil { resets += 1 }
        }
        let own = OffscreenWindow(size: CGSize(width: 40, height: 40))
        let foreign = OffscreenWindow(size: CGSize(width: 40, height: 40))
        let resetTracker = AboutMarkTrackingView()
        coordinator.watch(own)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: foreign)
        XCTAssertEqual(resets, 0, "a foreign window reset the mark")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: own)
        XCTAssertEqual(resets, 1, "the owning window did not reset the mark")
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

    /// The motion target is bounded, returns to the printed position and is
    /// still when motion is reduced. No pointer, timer or idle animation is
    /// needed to check the answer the view applies to the disc.
    func testTheMarkMotionTargetIsBoundedAndStill() throws {
        XCTAssertEqual(AboutMarkMotion.horizontalLimit, 6)
        XCTAssertEqual(AboutMarkMotion.verticalLimit, 4)
        XCTAssertEqual(AboutMarkMotion.engagedResponse, 0.24)
        XCTAssertEqual(AboutMarkMotion.engagedDamping, 0.82)
        XCTAssertEqual(AboutMarkMotion.returnResponse, 0.28)
        XCTAssertEqual(AboutMarkMotion.returnDamping, 0.86)

        let rest = AboutMarkMotion.target(x: 0, y: 0, reduceMotion: false)
        XCTAssertEqual(rest.x, 0, accuracy: 0.001)
        XCTAssertEqual(rest.y, 0, accuracy: 0.001)

        let lowerRight = AboutMarkMotion.target(x: 4, y: -4, reduceMotion: false)
        XCTAssertEqual(lowerRight.x, 6, accuracy: 0.001, "horizontal target is not clamped")
        XCTAssertEqual(lowerRight.y, -4, accuracy: 0.001, "vertical target is not clamped")

        let upperLeft = AboutMarkMotion.target(x: -1, y: 1, reduceMotion: false)
        XCTAssertEqual(upperLeft.x, -6, accuracy: 0.001)
        XCTAssertEqual(upperLeft.y, 4, accuracy: 0.001)

        let still = AboutMarkMotion.target(x: 1, y: -1, reduceMotion: true)
        XCTAssertEqual(still.x, 0, accuracy: 0.001, "reduced motion moved the disc")
        XCTAssertEqual(still.y, 0, accuracy: 0.001, "reduced motion moved the disc")
        XCTAssertNil(
            AboutMarkMotion.animation(returning: false, reduceMotion: true),
            "reduced motion gave the disc a spring"
        )
        XCTAssertNotNil(AboutMarkMotion.animation(returning: false, reduceMotion: false))
        XCTAssertNotNil(AboutMarkMotion.animation(returning: true, reduceMotion: false))

        let source = try aboutPageSource()
        XCTAssertFalse(source.contains("Timer.scheduledTimer"), "the mark has a timer")
        XCTAssertFalse(source.contains("CADisplayLink"), "the mark has a display link")
        XCTAssertFalse(source.contains("TimelineView"), "the mark moves on its own clock")
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

    /// A status line can be visually capped without shortening the value the
    /// control hands to a screen reader.
    func testTheFullStatusRemainsTheAccessibilityValue() throws {
        let release = "9.9.0-rc.1+release.candidate.20261120"
        XCTAssertEqual(
            AboutUpdateState.available(version: release, page: nil).statusText,
            "Version \(release) available"
        )
        let source = try aboutPageSource()
        XCTAssertTrue(source.contains(".accessibilityValue(currentUpdate.statusText)"))
        XCTAssertTrue(source.contains(".buttonStyle(DotPressStyle())"))
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

    private func trackingView(in view: NSView) -> AboutMarkTrackingView? {
        if let found = view as? AboutMarkTrackingView { return found }
        for child in view.subviews {
            if let found = trackingView(in: child) { return found }
        }
        return nil
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
