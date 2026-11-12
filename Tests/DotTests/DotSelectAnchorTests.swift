import AppKit
@testable import Dot
import SwiftUI
import XCTest

/// Where the list opens when the page under it has moved.
///
/// The trigger is a `SwiftUI` drawing and the list is a window, so the position
/// has to be read when the list opens: a page that scrolled moves the trigger on
/// the screen without laying the trigger out again. A frame remembered from the last layout is the
/// frame of the place the trigger used to be, and a list placed from it opens
/// far below the click.
@MainActor
final class DotSelectAnchorTests: XCTestCase {
    private var fixture: AnchorPage?

    /// The owner's report: a list opened on a page scrolled to the bottom of a
    /// forty row page, with the picker thirty rows down.
    func testRegressionTheListOpensUnderTheTriggerAfterThePageScrolled() throws {
        let page = try makePage()
        page.scroll(to: 10_000)
        try assertListOpensUnderItsTrigger(page, "after scrolling to the foot of the page")
    }

    /// The same after the window itself has moved, which is how a page ends up
    /// on another display.
    func testRegressionTheListOpensUnderTheTriggerAfterTheWindowMoved() throws {
        let page = try makePage()
        page.scroll(to: 1_150)
        page.moveWindow(by: CGSize(width: 120, height: -40))
        try assertListOpensUnderItsTrigger(page, "after the window moved")
    }

    /// Two opens at two different scroll positions, one after the other.
    func testRegressionTwoOpensAtDifferentScrollOffsetsBothLandOnTheTrigger() throws {
        let page = try makePage()
        page.scroll(to: 1_180)
        try assertListOpensUnderItsTrigger(page, "at the first offset")
        page.scroll(to: 1_282)
        try assertListOpensUnderItsTrigger(page, "at the second offset")
    }

    // MARK: - Helpers

    private func assertListOpensUnderItsTrigger(_ page: AnchorPage, _ what: String) throws {
        let trigger = try XCTUnwrap(page.trigger)
        let before = page.screenFrame(of: trigger)
        XCTAssertGreaterThan(trigger.frame.height, 0)
        XCTAssertGreaterThan(
            before.minY - page.unscrolledTriggerY,
            500,
            "the page did not scroll: the trigger did not move (\(what))"
        )

        XCTAssertTrue(trigger.accessibilityPerformPress(), "the trigger did not open (\(what))")

        let card = try XCTUnwrap(page.cardFrame, "no list opened (\(what))")
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let expected = DotSelectPlacement.frame(anchor: before, size: card.size, visibleFrame: visible)
        XCTAssertEqual(card.minX, before.minX, accuracy: 1, "the list is beside its trigger (\(what))")
        XCTAssertEqual(
            card.minY,
            expected.minY,
            accuracy: 1,
            "the list is \(Int(card.minY - expected.minY)) points from where the trigger is (\(what))"
        )
        XCTAssertEqual(card.size, expected.size)
        DotSelectListController.shared.close()
    }

    private func makePage() throws -> AnchorPage {
        _ = NSApplication.shared
        DotSelectListController.shared.close()
        let page = try AnchorPage(rows: 40, pickerRow: 30)
        fixture = page
        return page
    }
}

/// A window holding a forty row settings page with a picker thirty rows down.
@MainActor
final class AnchorPage {
    let window: NSWindow
    let host: NSHostingView<AnchorPageView>

    init(rows: Int, pickerRow: Int) throws {
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 120, width: 820, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnchorPageView(rows: rows, pickerRow: pickerRow))
        host.frame = NSRect(origin: .zero, size: window.frame.size)
        window.contentView = host
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        window.setFrameOrigin(NSPoint(x: screen.minX + 20, y: screen.minY + 20))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        settle(0.1)
        unscrolledTriggerY = trigger.map { screenFrame(of: $0).minY } ?? .infinity
    }

    deinit {
        let window = self.window
        MainActor.assumeIsolated {
            window.orderOut(nil)
            window.close()
        }
    }

    var trigger: DotSelectAccessibilityView? {
        Self.find(label: "Row 30", in: host)
    }

    /// The card the list is drawn in, without the room its shadow needs.
    var cardFrame: CGRect? {
        let panel = NSApp.windows.compactMap { $0 as? DotSelectPanel }.last
        return panel.map {
            $0.frame.insetBy(dx: DotSelectPlacement.shadowInset, dy: DotSelectPlacement.shadowInset)
        }
    }

    /// Where the trigger sits before the page is scrolled.
    private(set) var unscrolledTriggerY: CGFloat = 0

    var offset: CGFloat? {
        Self.scrollView(in: host).map { $0.contentView.bounds.origin.y }
    }

    var docHeight: CGFloat? {
        Self.scrollView(in: host).flatMap { $0.documentView?.frame.height }
    }

    func screenFrame(of view: NSView) -> CGRect {
        window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// Moves the page the way a wheel does, without letting the run loop lay
    /// anything out: a list opened next must read the trigger, not remember it.
    func scroll(to offset: CGFloat) {
        guard let scroll = Self.scrollView(in: host) else { return }
        let room = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, offset), room)))
        scroll.reflectScrolledClipView(scroll.contentView)
        window.displayIfNeeded()
    }

    func moveWindow(by delta: CGSize) {
        var frame = window.frame
        frame.origin.x += delta.width
        frame.origin.y += delta.height
        window.setFrame(frame, display: true)
        host.layoutSubtreeIfNeeded()
    }

    func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    static func find(label: String, in view: NSView) -> DotSelectAccessibilityView? {
        if let element = view as? DotSelectAccessibilityView, element.accessibilityLabel() == label {
            return element
        }
        for sub in view.subviews {
            if let found = find(label: label, in: sub) { return found }
        }
        return nil
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }
}

struct AnchorPageView: View {
    let rows: Int
    let pickerRow: Int
    @State private var selection: String = "Ava"

    var body: some View {
        VStack(spacing: 0) {
            Text("Provider").frame(height: 40).frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(0..<rows, id: \.self) { index in
                        HStack(spacing: 12) {
                            Text(index == pickerRow ? "Row \(index)" : "Row \(index)")
                                .frame(width: 140, alignment: .leading)
                            if index == pickerRow {
                                DotSelect(
                                    label: "Row \(index)",
                                    options: ["Ava", "Daniel", "George"].map {
                                        DotSelectOption(value: $0, title: $0)
                                    },
                                    selection: $selection,
                                    width: 220
                                )
                            }
                        }
                        .frame(height: 29)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
