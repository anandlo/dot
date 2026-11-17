import AppKit
@testable import Dot
import QuartzCore
import SwiftUI
import XCTest

/// How a long list behaves under a wheel, and under a pointer that does not move.
///
/// A menu's wheel has to move the rows and nothing else. Two costs are measured
/// on a real panel: the time one scroll step takes, and whether a hover report
/// moves the list at all. Run with `DOT_SELECT_BENCH=1`.
@MainActor
final class DotSelectScrollBenchmarkTests: XCTestCase {
    private let rowCount = 60
    private let steps = 300

    func testScrollingALongList() throws {
        guard let gate = ProcessInfo.processInfo.environment["DOT_SELECT_BENCH"], gate == "1" else {
            throw XCTSkip("Set DOT_SELECT_BENCH=1 to measure the list.")
        }
        _ = NSApplication.shared
        OffscreenScreen.install()

        let names = (0..<rowCount).map { "Voice \($0)" }
        let model = BenchmarkModel(names: names)
        let window = OffscreenWindow(size: CGSize(width: 820, height: 600), styleMask: [.titled])
        let host = NSHostingView(rootView: BenchmarkPage(model: model))
        host.frame = NSRect(origin: .zero, size: window.frame.size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer {
            DotSelectListController.shared.close()
            OffscreenScreen.restore()
            window.orderOut(nil)
            window.close()
        }

        guard let trigger = Self.find(in: host) else { throw XCTSkip("no trigger") }
        XCTAssertTrue(trigger.accessibilityPerformPress())
        settle(0.3)
        guard let panel = NSApp.windows.compactMap({ $0 as? DotSelectPanel }).last,
              let scroll = Self.scrollView(in: panel.contentView)
        else { throw XCTSkip("the list did not open") }
        settle(0.3)

        let clip = scroll.contentView
        let content = scroll.documentView?.frame.height ?? 0
        let viewport = clip.bounds.height
        print("BENCH rows=\(rowCount) content=\(Int(content)) viewport=\(Int(viewport))")

        // (A) The wheel: every step moves the document and lets it draw.
        var samples: [Double] = []
        samples.reserveCapacity(steps)
        for step in 0..<steps {
            let sweep = CGFloat(step) / CGFloat(steps - 1)
            let target = (content - viewport) * (sweep < 0.5 ? sweep * 2 : (1 - sweep) * 2)
            let start = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(clip)
            panel.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date())
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        report("wheel", samples)

        // (B) The pointer: rows arrive under a cursor that has not moved. The
        // old list re-centred itself on every one of these.
        let before = clip.bounds.origin.y
        var shifts: [Int] = []
        for index in stride(from: 0, to: rowCount, by: 7) {
            let from = clip.bounds.origin.y
            DotSelectListController.shared.session?.hover(index)
            panel.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date())
            let to = clip.bounds.origin.y
            if abs(to - from) > 0.5 { shifts.append(index) }
        }
        print("BENCH hoverScrolledList=\(shifts.count) of \((rowCount + 6) / 7) start=\(Int(before))")

        // (C) The same six hovers, timed, so a hover that re-draws the whole
        // card shows up as a cost even when it no longer moves the list.
        var hoverSamples: [Double] = []
        for index in stride(from: 0, to: rowCount, by: 7) {
            let start = CACurrentMediaTime()
            DotSelectListController.shared.session?.hover(index)
            panel.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date())
            hoverSamples.append((CACurrentMediaTime() - start) * 1000)
        }
        report("hover", hoverSamples)

        // (D) The keys: the model still scrolls for the keyboard.
        var keySamples: [Double] = []
        for _ in 0..<20 {
            let start = CACurrentMediaTime()
            _ = DotSelectListController.shared.session?.handleKey(Self.down())
            panel.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date())
            keySamples.append((CACurrentMediaTime() - start) * 1000)
        }
        report("key", keySamples)
        let afterKeys = clip.bounds.origin.y
        print("BENCH keysScrolledList=\(afterKeys > 0.5)")
    }

    private func report(_ name: String, _ samples: [Double]) {
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let over = samples.filter { $0 > 16.7 }.count
        print(String(
            format: "BENCH %@ n=%d median=%.2fms p95=%.2fms p99=%.2fms max=%.2fms over16.7=%d",
            name, samples.count, median, p95, p99, sorted.last ?? 0, over
        ))
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func down() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125
        )!
    }

    private static func find(in view: NSView) -> DotSelectAccessibilityView? {
        if let element = view as? DotSelectAccessibilityView { return element }
        for sub in view.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }

    private static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }
}

private struct BenchmarkPage: View {
    @ObservedObject var model: BenchmarkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Voice").font(.system(size: 12))
            DotSelect(
                label: "Voice",
                options: model.names.map { DotSelectOption(value: $0, title: $0) },
                selection: Binding(get: { model.names.first }, set: { _ in }),
                width: 220
            )
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
private final class BenchmarkModel: ObservableObject {
    let names: [String]

    init(names: [String]) {
        self.names = names
    }
}
