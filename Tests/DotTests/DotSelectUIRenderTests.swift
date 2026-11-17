import AppKit
@testable import Dot
import SwiftUI
import XCTest

/// The list as a picture: short, long at its top, long in the middle, long at
/// its foot, the row states, and the trigger at rest and open, in both
/// appearances.
///
/// Written only when asked for, because it needs a window and a drawing pass.
/// `DOT_SELECT_UI_DIR=/tmp/ddA-ui`.
@MainActor
final class DotSelectUIRenderTests: XCTestCase {
    private var windows: [NSWindow] = []

    func testTheListSheetRenders() throws {
        guard let value = ProcessInfo.processInfo.environment["DOT_SELECT_UI_DIR"], !value.isEmpty else {
            throw XCTSkip("Set DOT_SELECT_UI_DIR to render the list sheet.")
        }
        _ = NSApplication.shared
        OffscreenScreen.install()
        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let short = (0..<4).map { DotSelectRow(title: "OpenAI \($0)", detail: "Connected") }
        let long = (0..<30).map { index in
            DotSelectRow(title: index == 4 ? "AssemblyAI Universal Streaming" : "Voice \(index)")
        }
        let shortSize = DotSelectPlacement.size(
            triggerWidth: 240,
            widestRow: DotSelectListMetrics.widestRow(short),
            rowHeights: short.map { DotSelectPlacement.rowHeight(detail: $0.detail) }
        )
        let longSize = DotSelectPlacement.size(
            triggerWidth: 240,
            widestRow: DotSelectListMetrics.widestRow(long),
            rowHeights: Array(repeating: DotSelectPlacement.rowHeight, count: long.count)
        )

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            try write(
                snapshot(card(short, selected: 0, highlight: 1, size: shortSize), scheme: scheme),
                directory, "short-\(suffix)"
            )
            try write(
                snapshot(card(long, selected: 2, highlight: 2, size: longSize), scheme: scheme),
                directory, "long-top-\(suffix)"
            )
            try write(
                snapshot(
                    card(long, selected: 2, highlight: 3, size: longSize),
                    scheme: scheme,
                    scrollTo: 300
                ),
                directory, "long-mid-\(suffix)"
            )
            try write(
                snapshot(
                    card(long, selected: 2, highlight: 27, size: longSize),
                    scheme: scheme,
                    scrollTo: 10_000
                ),
                directory, "long-bottom-\(suffix)"
            )
            try write(snapshot(rows(short), scheme: scheme), directory, "rows-\(suffix)")
            try write(trigger(scheme: scheme, open: false), directory, "trigger-idle-\(suffix)")
            try write(trigger(scheme: scheme, open: true), directory, "trigger-open-\(suffix)")
        }
        DotSelectListController.shared.close()
        OffscreenScreen.restore()
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }

    private func card(
        _ rows: [DotSelectRow],
        selected: Int?,
        highlight: Int?,
        size: CGSize
    ) -> some View {
        DotSelectListCard(
            rows: rows,
            selectedIndex: selected,
            highlight: highlight,
            size: size,
            onHighlight: { _ in },
            onChoose: { _ in }
        )
    }

    /// A row at rest, the chosen row, a highlighted row and a held row, on the
    /// colours the card draws behind them.
    private func rows(_ rows: [DotSelectRow]) -> some View {
        VStack(spacing: 0) {
            DotSelectListRow(row: rows[0], isSelected: true, isHighlighted: false, reservesSymbol: false)
            DotSelectListRow(row: rows[1], isSelected: false, isHighlighted: true, reservesSymbol: false)
            DotSelectListRow(
                row: rows[2], isSelected: false, isHighlighted: true, isPressed: true, reservesSymbol: false
            )
            DotSelectListRow(row: rows[3], isSelected: false, isHighlighted: false, reservesSymbol: false)
        }
        .padding(DotSelectPlacement.inset)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(DotTheme.paper)
                RoundedRectangle(cornerRadius: 10).fill(DotTheme.cardFill)
            }
        )
        .frame(width: 280)
    }

    // MARK: - The trigger

    private func trigger(scheme: ColorScheme, open: Bool) throws -> NSBitmapImageRep {
        let size = CGSize(width: 300, height: 120)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        let host = NSHostingView(rootView: TriggerFixture())
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        windows.append(window)
        guard open else { return try cache(host) }
        let element = try XCTUnwrap(Self.element(in: host), "the trigger is not in the window")
        XCTAssertTrue(element.accessibilityPerformPress())
        settle(0.4)
        let rep = try cache(host)
        DotSelectListController.shared.close()
        settle(0.1)
        return rep
    }

    // MARK: - Drawing

    private func snapshot(
        _ view: some View,
        scheme: ColorScheme,
        scrollTo: CGFloat? = nil
    ) throws -> NSBitmapImageRep {
        let size = CGSize(width: 300, height: 340)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        settle(0.5)
        if let offset = scrollTo, let scroll = Self.scrollView(in: host) {
            let room = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset, room)))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(0.25)
        }
        window.displayIfNeeded()
        windows.append(window)
        return try cache(host)
    }

    /// The host's pixels at two pixels per point.
    ///
    /// A rep AppKit makes for the cache display comes back at the display's own
    /// scale, which is one pixel per point on a display that is not Retina, so
    /// the bitmap is made here at the scale the pictures are judged at.
    private func cache(_ host: NSView) throws -> NSBitmapImageRep {
        let bounds = host.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width) * 2,
            pixelsHigh: Int(bounds.height) * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the cache display could not be allocated")
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, _ directory: URL, _ name: String) throws {
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertGreaterThan((attributes[.size] as? Int) ?? 0, 4096, "\(name).png is too small to be a card")
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func element(in view: NSView) -> DotSelectAccessibilityView? {
        if let element = view as? DotSelectAccessibilityView { return element }
        for sub in view.subviews {
            if let found = element(in: sub) { return found }
        }
        return nil
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }
}

/// The real trigger on the page's paper, with nothing else in the window.
private struct TriggerFixture: View {
    @State private var selection: String? = "OpenAI"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DotSelect(
                label: "Service",
                options: ["OpenAI", "Azure", "AssemblyAI"].map { DotSelectOption(value: $0, title: $0) },
                selection: $selection,
                width: 220
            )
            Text("Service")
                .font(.system(size: 11))
                .foregroundStyle(DotTheme.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(DotTheme.paper)
    }
}
