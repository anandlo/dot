import AppKit
import CryptoKit
@testable import Dot
import QuartzCore
import SwiftUI
import XCTest

/// The list as the panel draws it, read back as pixels.
///
/// The card's scrolling content is an `NSScrollView` whose layer carries the
/// rounded corners and the two fades, so the only honest proof of them is a
/// render of that layer tree. The tree lives in a window that is never ordered
/// front — the window server never learns it is there, and nothing is asked to
/// draw on a display — and the picture is drawn into a bitmap the test reads.
@MainActor
final class DotSelectCaptureTests: XCTestCase {
    func testTheListAsDrawn() throws {
        guard let path = ProcessInfo.processInfo.environment["DOT_SELECT_CAPTURE_DIR"],
              !path.isEmpty
        else {
            throw XCTSkip("Set DOT_SELECT_CAPTURE_DIR to write the list's pictures.")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            let page = try CapturePage(scheme: scheme)
            defer { page.close() }

            // Top: the first row, so only the bottom edge continues.
            let top = try page.openList()
            try write(top, directory, "live-top-\(suffix)")
            XCTAssertGreaterThan(top.pixelCount, 100_000, "the panel did not come back as pixels")
            XCTAssertTrue(top.isRounded, "the card's corner is square at the top of the list \(suffix)")
            XCTAssertEqual(
                top.fades,
                Fades(top: false, bottom: true, stops: 4, scrolling: true),
                "the top of the list fades where there is nothing beyond it \(suffix)"
            )

            // Mid: scrolled so a row is cut by both edges, which is where both
            // fades are drawn over rows.
            page.scrollList(to: 805)
            let mid = try page.capture()
            try write(mid, directory, "live-mid-\(suffix)")
            XCTAssertTrue(mid.isRounded, "the card's corner is square in the middle of the list \(suffix)")
            XCTAssertEqual(
                mid.fades,
                Fades(top: true, bottom: true, stops: 4, scrolling: true),
                "the edges of the scrolled list do not both fade \(suffix)"
            )

            // Bottom: the last row, so only the top edge continues.
            page.scrollList(to: 10_000)
            let bottom = try page.capture()
            try write(bottom, directory, "live-bottom-\(suffix)")
            XCTAssertTrue(bottom.isRounded, "the card's corner is square at the foot of the list \(suffix)")
            XCTAssertEqual(
                bottom.fades,
                Fades(top: true, bottom: false, stops: 4, scrolling: true),
                "the foot of the list fades where there is nothing beyond it \(suffix)"
            )

            // The bar leaves when the list rests.
            page.wait(1.3)
            let rested = try page.capture()
            try write(rested, directory, "live-rested-\(suffix)")
            XCTAssertGreaterThan(rested.pixelCount, 100_000)
            XCTAssertFalse(rested.fades.scrolling, "the scroller is still drawn once the list rests \(suffix)")
            // A list that fits has neither edge to fade and nothing to scroll.
            let shortPage = try CapturePage(scheme: scheme, rows: 3)
            defer { shortPage.close() }
            let short = try shortPage.openList()
            try write(short, directory, "live-short-\(suffix)")
            XCTAssertTrue(short.isRounded, "the short card's corner is square \(suffix)")
            XCTAssertEqual(
                short.fades,
                Fades(top: false, bottom: false, stops: 4, scrolling: true),
                "a list that fits fades at an edge \(suffix)"
            )
            XCTAssertLessThan(
                short.cardHeightInPixels,
                mid.cardHeightInPixels,
                "a three row list is not shorter than a sixty row one"
            )
        }
    }

    private func write(_ shot: PanelShot, _ directory: URL, _ name: String) throws {
        let data = try XCTUnwrap(shot.representation, "\(name) could not be encoded")
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - The row a list opens on

    /// The speech provider list, opened on its last row, at the three moments a
    /// person sees and at rest.
    ///
    /// The list must be in one place throughout. The card's clock is stopped and
    /// set by hand, so each frame is drawn at the moment it is named for rather
    /// than when a render happened to finish: the scale, the card's rectangle and
    /// the clip offset are read at that moment, and the file is hashed so the
    /// frames can be compared as bytes.
    func testTheProviderListOpensOnItsLastRow() throws {
        guard let path = ProcessInfo.processInfo.environment["DOT_SELECT_CAPTURE_DIR"],
              !path.isEmpty
        else {
            throw XCTSkip("Set DOT_SELECT_CAPTURE_DIR to write the list's pictures.")
        }
        _ = NSApplication.shared
        OffscreenScreen.install()
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let page = try ProviderPageWindow()
        defer { page.close() }
        let opened = try page.open()
        let viewport = opened.scroll.contentView.bounds.height
        let heights = page.rows.map { DotSelectPlacement.rowHeight(detail: $0.detail) }
        let expected = DotSelectPlacement.openOffset(
            rowHeights: heights,
            selected: page.rows.count - 1,
            viewport: viewport
        )

        let layer = try XCTUnwrap(opened.panel.contentView?.layer, "the card has no layer")
        let clock = layer.speed
        layer.speed = 0
        defer {
            layer.speed = clock
            layer.timeOffset = 0
        }

        var offsets: [CGFloat] = []
        var drawn: [CGFloat] = []
        var cards: [CGRect] = []
        for (name, moment) in [("0.00", 0.0), ("0.05", 0.05), ("0.14", 0.14), ("0.30", 0.30)] {
            layer.timeOffset = moment
            CATransaction.flush()
            let state = page.state(opened)
            let shot = try page.capture(opened)
            let file = "provider-last-\(name).png"
            try shot.data.write(to: directory.appendingPathComponent(file), options: .atomic)
            offsets.append(state.offset)
            drawn.append(state.scale)
            cards.append(shot.card)
            print(String(
                format: "PROVIDERFRAME %@ t%.2fs alpha %.2f scale %.4f clipOffset %.3f expected %.3f card %.1fx%.1f at y%.1f sha256 %@",
                file,
                moment,
                state.alpha,
                state.scale,
                state.offset,
                expected,
                shot.card.width,
                shot.card.height,
                shot.card.minY,
                Self.hash(shot.data)
            ))
        }

        for (index, offset) in offsets.enumerated() {
            XCTAssertEqual(
                offset,
                expected,
                accuracy: 0.5,
                "frame \(index) is \(offset), not the \(expected) the list opened on"
            )
        }
        XCTAssertEqual(
            offsets.first ?? 0,
            offsets.last ?? -1,
            accuracy: 0.5,
            "the list moved while the card opened"
        )
        XCTAssertLessThan(drawn.first ?? 1, 1, "the card did not start scaled")
        XCTAssertEqual(drawn.last ?? 0, 1, accuracy: 0.001, "the card did not finish at its own size")
        let first = try XCTUnwrap(cards.first, "the first frame has no card in it")
        let last = try XCTUnwrap(cards.last, "the last frame has no card in it")
        XCTAssertGreaterThan(last.height, first.height + 4, "the card is drawn at one size throughout")
        XCTAssertEqual(
            first.minY,
            last.minY,
            accuracy: 1,
            "the card grew away from the edge it hangs from"
        )
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The speech provider picker in a window off every display, opened through the
/// shipped trigger and the shipped panel.
@MainActor
private final class ProviderPageWindow {
    struct Row {
        let id: String
        let title: String
        let detail: String?
    }

    /// Eight services, every one with the line it carries in Settings, which is
    /// the list that opens a point short of its foot.
    let rows: [Row] = [
        Row(id: "apple", title: "Apple", detail: "On this Mac"),
        Row(id: "openai", title: "OpenAI", detail: "Requires API key"),
        Row(id: "assembly", title: "AssemblyAI", detail: "Requires API key"),
        Row(id: "deepgram", title: "Deepgram", detail: "Requires API key"),
        Row(id: "speechmatics", title: "Speechmatics", detail: "Requires API key"),
        Row(id: "azure", title: "Azure", detail: "Requires API key"),
        Row(id: "elevenlabs", title: "ElevenLabs", detail: "Requires API key"),
        Row(id: "custom", title: "Custom endpoint", detail: "Custom endpoint"),
    ]

    let window: NSWindow
    let host: NSHostingView<ProviderPage>

    init() throws {
        let size = CGSize(width: 460, height: 200)
        window = OffscreenWindow(size: size, styleMask: [.borderless])
        host = NSHostingView(rootView: ProviderPage(rows: rows))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(OffscreenWindow.origin)
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        DotSelectListController.shared.close()
        OffscreenScreen.restore()
        window.orderOut(nil)
        window.close()
    }

    /// Presses the trigger and hands back the list it drew, before the run loop
    /// turns again.
    func open() throws -> (panel: DotSelectPanel, scroll: NSScrollView) {
        let element = try XCTUnwrap(Self.element(in: host), "the trigger is not in the window")
        XCTAssertTrue(element.accessibilityPerformPress(), "the trigger did not open the list")
        let panel = try XCTUnwrap(DotSelectListController.shared.panel)
        XCTAssertLessThan(panel.frame.maxY, 0, "the panel was ordered onto a display")
        let scroll = try XCTUnwrap(
            DotSelectListController.shared.model?.scroll.reporter?.listScrollView,
            "the list did not exist when the open returned"
        )
        return (panel, scroll)
    }

    /// The numbers the card is being drawn with: where the list is scrolled to,
    /// the window's fade, and the scale the content's layer is presenting.
    struct State {
        let offset: CGFloat
        let alpha: CGFloat
        let scale: CGFloat
    }

    func state(_ opened: (panel: DotSelectPanel, scroll: NSScrollView)) -> State {
        let layer = opened.panel.contentView?.layer
        let presented = layer?.presentation()?.sublayerTransform
        return State(
            offset: opened.scroll.contentView.bounds.origin.y,
            alpha: opened.panel.alphaValue,
            scale: presented?.m11 ?? 1
        )
    }

    /// One frame of the panel's content, and the card's own rectangle in it.
    struct Shot {
        let data: Data
        let card: CGRect
    }

    func capture(_ opened: (panel: DotSelectPanel, scroll: NSScrollView)) throws -> Shot {
        let content = try XCTUnwrap(opened.panel.contentView, "the panel has no content")
        let layer = try XCTUnwrap(content.layer, "the panel's content has no layer")
        let scale: CGFloat = 2
        let width = Int(content.bounds.width * scale)
        let height = Int(content.bounds.height * scale)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // The layer tree draws from the bottom left; the PNG counts from the top.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        (layer.presentation() ?? layer).render(in: context)
        let image = try XCTUnwrap(context.makeImage(), "the layer tree did not render")
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]),
                                 "the frame could not be encoded")
        let box = Self.cardBox(rep) ?? .zero
        return Shot(
            data: data,
            card: CGRect(
                x: box.minX / scale,
                y: box.minY / scale,
                width: box.width / scale,
                height: box.height / scale
            )
        )
    }

    /// The card's rectangle in pixels, read from the picture: the card is opaque
    /// and its shadow is not, so the pixels that are nearly solid are the card.
    /// The picture counts from the top left.
    private static func cardBox(_ rep: NSBitmapImageRep) -> CGRect? {
        guard let data = rep.bitmapData, rep.samplesPerPixel > 3 else { return nil }
        var first = rep.pixelsWide
        var last = -1
        var top = rep.pixelsHigh
        var bottom = -1
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide where row[x * rep.samplesPerPixel + 3] > 230 {
                first = min(first, x)
                last = max(last, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        guard last >= first, bottom >= top else { return nil }
        return CGRect(
            x: CGFloat(first),
            y: CGFloat(top),
            width: CGFloat(last - first + 1),
            height: CGFloat(bottom - top + 1)
        )
    }

    private static func element(in view: NSView) -> DotSelectAccessibilityView? {
        if let element = view as? DotSelectAccessibilityView { return element }
        for sub in view.subviews {
            if let found = element(in: sub) { return found }
        }
        return nil
    }
}

/// The page the provider picker sits on, with the last service chosen.
private struct ProviderPage: View {
    let rows: [ProviderPageWindow.Row]
    @State private var selection: String? = "custom"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speech")
                .font(.system(size: 12, weight: .semibold))
            DotSelect(
                label: "Speech provider",
                options: rows.map {
                    DotSelectOption(value: $0.id, title: $0.title, detail: $0.detail)
                },
                selection: $selection,
                width: 260
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(DotTheme.paper)
    }
}

/// The panel's content in a window that is never shown, and its picture.
///
/// The window is the size the panel's window would be, so the card sits in it
/// where the panel puts it, and the tree is laid out and left alone: nothing
/// orders it front and nothing draws it.
@MainActor
final class CapturePage {
    let window: NSWindow
    let host: NSHostingView<DotSelectListHost>
    let cardSize: CGSize
    let shadowInset: CGFloat
    private let model: DotSelectListModel

    init(scheme: ColorScheme, rows: Int = 60) throws {
        let titles = (0..<rows).map { index in
            DotSelectRow(title: "Voice \(index)", detail: index == 0 ? "Selected" : nil)
        }
        cardSize = DotSelectPlacement.size(
            triggerWidth: 220,
            widestRow: DotSelectListMetrics.widestRow(titles),
            rowHeights: titles.map { DotSelectPlacement.rowHeight(detail: $0.detail) }
        )
        shadowInset = DotSelectPlacement.shadowInset
        let size = CGSize(
            width: cardSize.width + 2 * shadowInset,
            height: cardSize.height + 2 * shadowInset
        )
        model = DotSelectListModel(highlight: 0)
        window = OffscreenWindow(size: size, styleMask: [.borderless])
        host = NSHostingView(rootView: DotSelectListHost(
            generation: 1,
            rows: titles,
            title: "Voice",
            selectedIndex: 0,
            model: model,
            cardSize: cardSize,
            scaleAnchor: .top,
            scheme: scheme,
            onHighlight: { _ in },
            onChoose: { _ in }
        ))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // The only reason the tree is in a window at all: the scroll reporting
        // view rounds and masks the layer of the scroll view it finds itself in,
        // which needs the view to have a window. The window is never ordered
        // front, so the window server never draws it.
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        wait(0.2)
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    /// Lays the card out where the panel would, and reads its layer back.
    func openList() throws -> PanelShot {
        host.layoutSubtreeIfNeeded()
        wait(0.2)
        return try capture()
    }

    /// The bar's height and how far down the card it has travelled, as the
    /// card's own model reports them.
    var thumb: (height: CGFloat, offset: CGFloat)? { model.scroll.thumb }

    /// What the card is drawing its edges from: the two fades, the stops on the
    /// layer mask that carries them, and whether the scroller is up.
    var fades: Fades {
        let scroll = Self.scrollView(in: host)
        let stops = (scroll?.layer?.mask as? CAGradientLayer)?.colors?.count ?? 0
        return Fades(
            top: model.scroll.showsTopFade,
            bottom: model.scroll.showsBottomFade,
            stops: stops,
            scrolling: model.scroll.isScrolling
        )
    }

    func scrollList(to offset: CGFloat) {
        guard let scroll = Self.scrollView(in: host) else { return }
        let room = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, offset), room)))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        wait(0.3)
    }

    func capture() throws -> PanelShot {
        host.layoutSubtreeIfNeeded()
        let card = CGRect(origin: CGPoint(x: shadowInset, y: shadowInset), size: cardSize)
        let scale: CGFloat = 2
        let width = Int(host.bounds.width * scale)
        let height = Int(host.bounds.height * scale)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // The layer tree draws from the bottom left; the PNG counts from the top.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        if let layer = host.layer {
            layer.render(in: context)
        } else {
            throw XCTSkip("the card has no layer tree to render")
        }
        let image = try XCTUnwrap(context.makeImage(), "the layer tree did not render")
        let rep = NSBitmapImageRep(cgImage: image)
        return PanelShot(
            representation: rep.representation(using: .png, properties: [:]),
            rep: rep,
            cardInWindow: card,
            windowHeight: host.bounds.height,
            scale: scale,
            fades: fades
        )
    }

    func wait(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }
}

/// The fades the card is drawing, as the card itself reports them.
struct Fades: Equatable {
    let top: Bool
    let bottom: Bool
    let stops: Int
    let scrolling: Bool
}

/// One captured window, and what its pixels say.
struct PanelShot {
    let representation: Data?
    let rep: NSBitmapImageRep
    /// The card inside the captured window, in window coordinates.
    let cardInWindow: CGRect
    /// The captured window's height, for turning a window y into an image row.
    let windowHeight: CGFloat
    let scale: CGFloat
    /// The answer the card gave about its edges when the picture was taken.
    let fades: Fades

    /// The card in image rows, which count from the top.
    var card: CGRect {
        CGRect(
            x: cardInWindow.minX * scale,
            y: (windowHeight - cardInWindow.maxY) * scale,
            width: cardInWindow.width * scale,
            height: cardInWindow.height * scale
        )
    }

    var pixelCount: Int { rep.pixelsWide * rep.pixelsHigh }

    /// The card's height in pixels, which grows until the list caps.
    var cardHeightInPixels: Int { Int(card.height) }

    /// The card's height in points.
    var cardHeightInPoints: CGFloat { card.height / scale }

    /// The card's top-left pixel must be outside the rounded corner: the window
    /// is transparent there.
    var isRounded: Bool {
        let corner = sample(x: Int(card.minX) + 1, y: Int(card.minY) + 1)
        let inside = sample(x: Int(card.midX), y: Int(card.midY) - Int(40 * scale))
        return corner.alpha < 0.6 && inside.alpha > 0.6
    }

    /// Where the bar is drawn, in points from the card's top edge.
    ///
    /// The bar is the strongest ink in the few points it occupies at the
    /// trailing edge, and the longest run of rows there that differs from the
    /// card's fill twenty points in is the bar. The track under it is quieter
    /// than this threshold, so a bar is measured even while the track is drawn;
    /// the card's own edge is a row or two of antialiasing and is not.
    func scrollerSpan() -> (top: CGFloat, bottom: CGFloat)? {
        let x = Int(card.maxX - 6 * scale)
        let behind = Int(card.maxX - 20 * scale)
        var rows: [Int] = []
        for y in Int(card.minY)..<Int(card.maxY) {
            let ink = sample(x: x, y: y)
            let fill = sample(x: behind, y: y)
            guard ink.alpha > 0.2, fill.alpha > 0.2 else { continue }
            if abs(ink.luminance - fill.luminance) > 0.12 { rows.append(y) }
        }
        var best: (start: Int, end: Int)?
        var start: Int?
        var previous: Int?
        for row in rows {
            if let last = previous, row - last > 2 {
                if let start, let last = previous { best = longest(best, (start, last)) }
                start = row
            } else if start == nil {
                start = row
            }
            previous = row
        }
        if let start, let last = previous { best = longest(best, (start, last)) }
        guard let best, best.end - best.start >= Int(8 * scale) else { return nil }
        return (
            (CGFloat(best.start) - card.minY) / scale,
            (CGFloat(best.end + 1) - card.minY) / scale
        )
    }

    /// Where the track is drawn, in points from the card's top edge.
    ///
    /// The track is quieter than the bar and runs the length of the list, so
    /// the run of ink at the trailing edge that reaches from the first few
    /// points of the card to the last few is the track. The threshold is low
    /// because the track is meant to be almost not there; the bar is read back
    /// by ``scrollerSpan()``, which asks for a stronger difference.
    func trackSpan() -> (top: CGFloat, bottom: CGFloat)? {
        let x = Int(card.maxX - 6 * scale)
        let behind = Int(card.maxX - 20 * scale)
        var run: (start: Int, end: Int)?
        var start: Int?
        var previous: Int?
        for y in Int(card.minY)..<Int(card.maxY) {
            let ink = sample(x: x, y: y)
            let fill = sample(x: behind, y: y)
            var detected = false
            if ink.alpha > 0.2, fill.alpha > 0.2 {
                detected = abs(ink.luminance - fill.luminance) > 0.02
            }
            if detected {
                if let last = previous, y - last > 2 {
                    if let start, let last = previous { run = longest(run, (start, last)) }
                    start = y
                } else if start == nil {
                    start = y
                }
                previous = y
            }
        }
        if let start, let last = previous { run = longest(run, (start, last)) }
        // A track reaches from the first few points of the card to the last
        // few; anything shorter is an edge or a row, not a track.
        guard let run, run.end - run.start >= Int(card.height * 0.6) else { return nil }
        return ((CGFloat(run.start) - card.minY) / scale, (CGFloat(run.end + 1) - card.minY) / scale)
    }

    private func longest(_ a: (start: Int, end: Int)?, _ b: (start: Int, end: Int)) -> (start: Int, end: Int) {
        guard let a else { return b }
        return b.end - b.start > a.end - a.start ? b : a
    }

    func sample(x: Int, y: Int) -> (luminance: CGFloat, alpha: CGFloat) {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let data = rep.bitmapData else {
            return (0, 0)
        }
        let offset = y * rep.bytesPerRow + x * rep.samplesPerPixel
        let alpha = rep.samplesPerPixel > 3 ? CGFloat(data[offset + 3]) / 255 : 1
        let luminance = (CGFloat(data[offset]) * 0.21
            + CGFloat(data[offset + 1]) * 0.72
            + CGFloat(data[offset + 2]) * 0.07) / 255
        return (luminance, alpha)
    }
}
