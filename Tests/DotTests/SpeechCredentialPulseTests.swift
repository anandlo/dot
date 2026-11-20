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

    /// The Service row's trailing view is the picker alone: its right edge lands
    /// where the API key row's rightmost control lands. When a status view is
    /// added after the picker, the picker stops short of that edge.
    func testServiceRowTrailingIsOnlyTheSelect() throws {
        let host = speechHost(status: .settled(.verified, checkedAt: Self.checkedAt))
        let views = allViews(in: host)
        let service = try XCTUnwrap(
            views.first { view in
                guard let select = view as? DotSelectAccessibilityView else { return false }
                return select.accessibilityLabel() == "Service"
            }
        )
        let keyField = try XCTUnwrap(views.first { $0 is NSSecureTextField })
        let keyFrame = absoluteFrame(of: keyField, in: host)
        let serviceFrame = absoluteFrame(of: service, in: host)

        let trailingEdges = views.compactMap { view -> CGFloat? in
            guard String(describing: type(of: view)).contains("FocusRing") else { return nil }
            let frame = absoluteFrame(of: view, in: host)
            guard abs(frame.midY - keyFrame.midY) < 24, frame.maxX > serviceFrame.maxX - 2 else {
                return nil
            }
            return frame.maxX
        }
        let apiKeyRightEdge = try XCTUnwrap(trailingEdges.max())

        XCTAssertEqual(
            serviceFrame.maxX,
            apiKeyRightEdge,
            accuracy: 1,
            "the Service picker ended at \(serviceFrame.maxX) but the API key controls ended at \(apiKeyRightEdge)"
        )
    }

    /// The Status row's accessible name and value, its chip title and its
    /// subtitle all come from one state, in every state the page can draw.
    func testStatusRowShowsTheTitleForEachState() {
        let checkedAt = Self.checkedAt
        let cases: [(SpeechCredentialStatus, String, Bool)] = [
            (.checking, "Checking", false),
            (.settled(.verified, checkedAt: checkedAt), "Verified", false),
            (.settled(.verifiedWithRestriction("Cannot list models"), checkedAt: checkedAt), "Verified", false),
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

    // MARK: - The headless page

    private func speechHost(status: SpeechCredentialStatus) -> NSHostingView<AnyView> {
        var config = DotConfig.default
        ProviderPreset.openAI.apply(to: &config)
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
        let host = NSHostingView(rootView: AnyView(page))
        host.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    private func absoluteFrame(of view: NSView, in host: NSView) -> NSRect {
        view.convert(view.bounds, to: host)
    }
}
