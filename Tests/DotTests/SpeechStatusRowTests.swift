import AppKit
import DotCore
import SwiftUI
import XCTest

@testable import Dot

@MainActor
final class SpeechStatusRowTests: XCTestCase {
    private static let checkedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    /// The Service row's trailing edge lands where the API key row's trailing
    /// control lands. Both edges come from the same invisible AppKit anchors the
    /// rows own, so the assertion measures the rendered rows, not a class name.
    func testServiceRowTrailingIsOnlyTheSelect() throws {
        for preset in ProviderPreset.declared {
            let page = speechHost(preset: preset, status: .settled(.verified, checkedAt: Self.checkedAt))
            defer { page.window.close() }
            let service = try XCTUnwrap(
                anchor("speech.service", in: page.view),
                "\(preset.id) has no Service edge"
            )
            let key = try XCTUnwrap(
                anchor("speech.apiKey.trailing", in: page.view),
                "\(preset.id) has no API key trailing edge"
            )
            let delta = absoluteFrame(of: service, in: page.view).maxX
                - absoluteFrame(of: key, in: page.view).maxX
            print("SSR2-ALIGN \(preset.id) delta=\(String(format: "%.3f", delta)) pt")
            XCTAssertLessThanOrEqual(
                abs(delta),
                0.5,
                "\(preset.id): the Service picker ended \(delta) pt from the API key controls"
            )
        }
    }

    /// The Status row's accessible name and value, its chip title and its
    /// subtitle all come from one state, in every state the page can draw.
    func testStatusRowShowsTheTitleForEachState() {
        let checkedAt = Self.checkedAt
        let cases: [(SpeechCredentialStatus, String, Bool)] = [
            (.checking, "Checking", false),
            (.settled(.verified, checkedAt: checkedAt), "Verified", false),
            (.settled(.verifiedWithRestriction("Cannot list models"), checkedAt: checkedAt), "Verified", true),
            (.settled(.rejected(status: 401), checkedAt: checkedAt), "Key rejected", true),
            (.settled(.serviceError(status: 503, host: "the service"), checkedAt: checkedAt), "Service error", true),
            (.settled(.unreachable("Can't reach the service."), checkedAt: checkedAt), "Can't reach service", true),
            (.settled(.needsSetup("Add an API key for this service."), checkedAt: checkedAt), "Needs setup", true),
            (.settled(.unavailable("Needs macOS 26 or newer."), checkedAt: checkedAt), "Unavailable", true),
            (.notSaved("The Keychain did not give the key back."), "Key not saved", true),
        ]

        for (status, title, showsDetail) in cases {
            XCTAssertEqual(status.title, title, "the chip title changed for \(status)")
            XCTAssertEqual(status.statusAccessibilityLabel, "Status, \(title)")
            XCTAssertEqual(status.statusAccessibilityValue, status.message)
            if showsDetail {
                XCTAssertEqual(status.statusDetail, status.message, "the Status row lost its subtitle for \(title)")
            } else {
                XCTAssertNil(status.statusDetail, "the Status row repeated its message for \(title)")
            }
        }
    }

    /// Every service the page can present gets one Status row, and that row is
    /// drawn below the service and key rows of the same card. The list comes
    /// from the preset source of truth, so a newly declared service is covered.
    func testEveryPresetHostsOneStatusRowAtTheEndOfTheServiceCard() throws {
        let status: SpeechCredentialStatus = .settled(.verified, checkedAt: Self.checkedAt)
        for preset in ProviderPreset.declared {
            let page = speechHost(preset: preset, status: status)
            defer { page.window.close() }

            let elements = statusElements(in: page.view)
            XCTAssertEqual(
                elements.count,
                1,
                "\(preset.id) hosted \(elements.count) accessible Status rows"
            )
            let row = try XCTUnwrap(elements.first, "\(preset.id) hosted no Status row")
            XCTAssertEqual(row.accessibilityLabel() ?? "", status.statusAccessibilityLabel)
            XCTAssertEqual(row.accessibilityValue() as? String ?? "", status.statusAccessibilityValue)
            XCTAssertEqual(row.accessibilityHelp() ?? "", status.message)

            let rowFrame = absoluteFrame(of: row, in: page.view)
            let service = try XCTUnwrap(anchor("speech.service", in: page.view), "\(preset.id) has no Service row")
            let key = try XCTUnwrap(anchor("speech.apiKey.trailing", in: page.view), "\(preset.id) has no API key row")
            let serviceFrame = absoluteFrame(of: service, in: page.view)
            let keyFrame = absoluteFrame(of: key, in: page.view)
            XCTAssertGreaterThan(
                rowFrame.minY,
                serviceFrame.maxY,
                "\(preset.id) drew Status above the Service row"
            )
            XCTAssertGreaterThan(
                rowFrame.minY,
                keyFrame.maxY,
                "\(preset.id) drew Status above the API key row"
            )
        }
    }

    /// The row a reader sees is the row the state drives. The spinner, the
    /// help and the subtitle are all read from the hosted view: a progress
    /// indicator appears only for a check in flight, and the row grows only
    /// when the state supplies a detail line.
    func testHostedStatusRowIsWiredToItsState() throws {
        let checkedAt = Self.checkedAt
        let verifying: SpeechCredentialStatus = .checking
        let verified: SpeechCredentialStatus = .settled(.verified, checkedAt: checkedAt)
        let restricted: SpeechCredentialStatus = .settled(
            .verifiedWithRestriction(
                "ElevenLabs accepted the key. It is not allowed to list models, which Dot does not use."
            ),
            checkedAt: checkedAt
        )
        let rejected: SpeechCredentialStatus = .settled(.rejected(status: 401), checkedAt: checkedAt)

        func measure(
            _ status: SpeechCredentialStatus,
            preset: ProviderPreset = .openAI
        ) throws -> (row: NSView, height: CGFloat, spinners: Int, service: String?) {
            let page = speechHost(preset: preset, status: status)
            defer { page.window.close() }
            let row = try XCTUnwrap(statusElements(in: page.view).first, "the hosted page has no Status row")
            XCTAssertEqual(row.accessibilityLabel() ?? "", status.statusAccessibilityLabel)
            XCTAssertEqual(row.accessibilityValue() as? String ?? "", status.statusAccessibilityValue)
            XCTAssertEqual(row.accessibilityHelp() ?? "", status.message)

            let spinners = allViews(in: page.view).filter { view in
                guard let indicator = view as? NSProgressIndicator else { return false }
                return indicator.accessibilityRole() == .busyIndicator
            }
            XCTAssertEqual(
                spinners.count,
                status.isChecking ? 1 : 0,
                "the \(status.title) row drew \(spinners.count) progress indicators"
            )
            let service = allViews(in: page.view).first { view in
                guard let select = view as? DotSelectAccessibilityView else { return false }
                return select.accessibilityLabel() == "Service"
            }
            return (
                row,
                absoluteFrame(of: row, in: page.view).height,
                spinners.count,
                service?.accessibilityValue() as? String
            )
        }

        let plain = try measure(verified)
        let cases: [(SpeechCredentialStatus, ProviderPreset)] = [
            (verifying, .openAI),
            (verified, .openAI),
            (restricted, .elevenLabs),
            (rejected, .openAI),
        ]
        for (status, preset) in cases {
            let hosted = try measure(status, preset: preset)
            if status == restricted {
                XCTAssertEqual(hosted.service, "ElevenLabs", "the restriction was not hosted on ElevenLabs")
            }
            print("SSR2-HEIGHT \(status.title) height=\(String(format: "%.1f", hosted.height)) plain=\(String(format: "%.1f", plain.height))")
            let hasDetail = status.statusDetail != nil
            XCTAssertEqual(
                hosted.height > plain.height + 8,
                hasDetail,
                "the \(status.title) row was \(hosted.height) pt tall against \(plain.height) pt without a subtitle"
            )
        }
        XCTAssertEqual(plain.spinners, 0)
    }

    /// The Status chip ends on the same trailing edge as the Service picker, in
    /// every state, so the indicator and its words line up with the control above.
    func testStatusChipTrailingMatchesTheServicePicker() throws {
        let states: [SpeechCredentialStatus] = [
            .checking,
            .settled(.verified, checkedAt: Self.checkedAt),
            .settled(.rejected(status: 401), checkedAt: Self.checkedAt),
        ]
        for preset in ProviderPreset.declared {
            for status in states {
                let page = speechHost(preset: preset, status: status)
                defer { page.window.close() }
                let service = try XCTUnwrap(anchor("speech.service", in: page.view), "\(preset.id) has no Service edge")
                let chip = try XCTUnwrap(
                    anchor("speech.status.trailing", in: page.view),
                    "\(preset.id) has no Status chip edge"
                )
                let delta = absoluteFrame(of: chip, in: page.view).maxX
                    - absoluteFrame(of: service, in: page.view).maxX
                print("SSR3-CHIP \(preset.id) \(status.title) delta=\(String(format: "%.3f", delta)) pt")
                XCTAssertLessThanOrEqual(
                    abs(delta),
                    0.5,
                    "\(preset.id) \(status.title): the Status chip ended \(delta) pt from the Service picker"
                )
            }
        }
    }

    /// With less motion asked for, a check in flight draws a still dot instead of
    /// the turning system spinner, and the row still says it is checking.
    func testCheckingHoldsStillWhenMotionIsReduced() throws {
        for reduced in [false, true] {
            let page = speechHost(preset: .openAI, status: .checking, reduceMotion: reduced)
            defer { page.window.close() }
            let spinners = allViews(in: page.view).filter { $0 is NSProgressIndicator }
            XCTAssertEqual(
                spinners.count,
                reduced ? 0 : 1,
                "reduce motion \(reduced): the checking row drew \(spinners.count) spinners"
            )
            let row = try XCTUnwrap(statusElements(in: page.view).first, "the hosted page has no Status row")
            XCTAssertEqual(row.accessibilityLabel() ?? "", SpeechCredentialStatus.checking.statusAccessibilityLabel)
        }
    }

    // MARK: - The headless page

    private struct HostedSpeechPage {
        let window: OffscreenWindow
        let view: NSHostingView<AnyView>
    }

    private func speechHost(
        preset: ProviderPreset,
        status: SpeechCredentialStatus,
        reduceMotion: Bool? = nil
    ) -> HostedSpeechPage {
        var config = DotConfig.default
        preset.apply(to: &config)
        if preset.id == ProviderPreset.custom.id {
            // The custom row is the one a stored, unrecognised endpoint takes.
            var settings = config.settings(for: preset.providerID)
            settings.baseURL = "http://127.0.0.1:1/v1"
            config.providers[preset.providerID] = settings
        }
        config.appearance = .light
        let store = ConfigStore(config: config)
        let page = SettingsView(
            store: store,
            providers: MenuBuilder.providerRows(config: config) { _ in false },
            tab: 1,
            onChange: {},
            onSetAPIKey: { _, _ in nil },
            onChangeShortcut: {}
        )
        .environment(\.settingsHeadless, true)
        .environment(\.settingsCredentialPreview, status)
        .environment(\.statusChipReduceMotion, reduceMotion)
        let host = NSHostingView(rootView: AnyView(page))
        host.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        let window = OffscreenWindow(size: CGSize(width: 820, height: 900))
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return HostedSpeechPage(window: window, view: host)
    }

    private func anchor(_ identifier: String, in view: NSView) -> NSView? {
        allViews(in: view).first { $0.identifier?.rawValue == identifier }
    }

    private func statusElements(in view: NSView) -> [NSView] {
        allViews(in: view).filter { element in
            guard element.isAccessibilityElement() else { return false }
            return (element.accessibilityLabel() ?? "").hasPrefix("Status, ")
        }
    }

    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    private func absoluteFrame(of view: NSView, in host: NSView) -> NSRect {
        view.convert(view.bounds, to: host)
    }
}
