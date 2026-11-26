import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Dot

/// The live page, hosted in a window that is never ordered front.
///
/// The page keeps one store of motion state and one monotonic clock. These
/// tests inject that clock, a wake scheduler and an update result, drive the
/// real tracking view and the production row handlers, and read the plate's
/// pixels. The injected clock is observable, so moving it alone makes every
/// animated leaf re-evaluate at the new reading: no frame-time override and no
/// display link is used.
@MainActor
final class AboutLiveTests: XCTestCase {
    private let size = CGSize(width: 565, height: 600)
    private let start: Double = 1_000_000

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            FontFixture.register()
            DotMotion.reducesMotionOverride = false
            AboutEntranceGate.lastStartedAt = nil
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            DotMotion.reducesMotionOverride = nil
            AboutEntranceGate.lastStartedAt = nil
        }
        super.tearDown()
    }

    // MARK: Harness

    /// A main-actor clock the page reads. It is observable on purpose: a leaf
    /// that evaluates `now()` registers as a reader, so advancing the clock
    /// redraws the leaf even in an offscreen window with no display link.
    @Observable
    @MainActor
    final class TestClock {
        var current: Double
        @ObservationIgnored private(set) var calls = 0

        init(_ current: Double) { self.current = current }

        func read() -> Double {
            calls += 1
            return current
        }

        func advance(_ milliseconds: Double) {
            current += milliseconds
        }
    }

    @MainActor
    private final class UpdateGate {
        private var continuation: CheckedContinuation<AboutUpdateState, Never>?
        func check() async -> AboutUpdateState {
            await withCheckedContinuation { self.continuation = $0 }
        }
        func release(_ state: AboutUpdateState) {
            continuation?.resume(returning: state)
            continuation = nil
        }
    }

    /// A main-actor wake scheduler the test fires by hand.
    ///
    /// It records the deadline of every sleep in monotonic milliseconds and
    /// runs the loop's own wake closure when the test asks, so the production
    /// pause loop and the entrance's end are driven without sleeping or a
    /// display link.
    @MainActor
    private final class ManualWakeScheduler: AboutWakeScheduling {
        private final class Entry {
            let due: Double
            let fire: @MainActor () -> Void
            let token: AboutWakeToken
            init(due: Double, fire: @escaping @MainActor () -> Void, token: AboutWakeToken) {
                self.due = due
                self.fire = fire
                self.token = token
            }
        }

        private let clock: TestClock
        private var entries: [Entry] = []
        private(set) var scheduled = 0

        init(clock: TestClock) { self.clock = clock }

        func wake(
            afterMilliseconds milliseconds: Double,
            _ fire: @escaping @MainActor () -> Void
        ) -> AboutWakeToken {
            scheduled += 1
            let token = AboutWakeToken()
            let entry = Entry(due: clock.current + milliseconds, fire: fire, token: token)
            entries.append(entry)
            token.onCancel = { [weak self] in
                self?.entries.removeAll { $0.token === token }
            }
            return token
        }

        func cancel(_ token: AboutWakeToken) {
            token.onCancel?()
            token.onCancel = nil
        }

        var nextDue: Double? {
            entries.map(\.due).min()
        }

        func fireNext() {
            guard let index = entries.indices.min(by: { entries[$0].due < entries[$1].due }) else {
                return
            }
            let entry = entries.remove(at: index)
            entry.fire()
        }

        /// Fires every wake whose deadline has been reached, earliest first.
        func fire(upTo time: Double) {
            while let index = entries.indices
                .filter({ entries[$0].due <= time })
                .min(by: { entries[$0].due < entries[$1].due })
            {
                let entry = entries.remove(at: index)
                entry.fire()
            }
        }
    }

    @MainActor
    private final class FocusRequest: ObservableObject {
        @Published var row: Int?
    }

    @MainActor
    private final class ReduceSwitch: ObservableObject {
        @Published var on = false
    }

    /// A reader that returns the clock's current value on its first call and
    /// sixty milliseconds later on every call after it. The first call is the
    /// attach request; the first root evaluation is the delayed one.
    @MainActor
    private final class DelayedClock {
        let clock: TestClock
        private var reads = 0

        init(_ clock: TestClock) { self.clock = clock }

        func read() -> Double {
            reads += 1
            return clock.current + (reads == 1 ? 0 : 60)
        }
    }

    /// The page switch a settings sidebar performs with `.id(selected)`.
    @MainActor
    private final class PageSelection: ObservableObject {
        @Published var showAbout = true
        @Published var tab = 0
    }

    @MainActor
    private final class BridgeAttachBox {
        var attaches = 0
        weak var store: AboutMotionStore?
        weak var loop: AboutPauseLoop?
    }

    private struct BridgeOnlyView: View {
        let onChange: @MainActor (ObjectIdentifier?) -> Void
        let onTeardown: @MainActor () -> Void

        var body: some View {
            AboutHostWindow(
                onChange: onChange,
                onTeardown: onTeardown,
                onDismantle: {},
                reportsWindowMoves: true,
                windowQuery: 0,
                onKeyDown: {},
                onPress: {}
            )
            .frame(width: 120, height: 80)
        }
    }

    private struct RetainedPageSwitchHarness: View {
        let page: AboutPage
        @ObservedObject var selection: PageSelection
        let size: CGSize

        var body: some View {
            TabView(selection: $selection.tab) {
                ScrollView(.vertical) {
                    page.frame(width: size.width)
                }
                .frame(width: size.width, height: size.height)
                .tabItem { Text("About") }
                .tag(0)

                Color.clear
                    .frame(width: size.width, height: size.height)
                    .tabItem { Text("Other") }
                    .tag(1)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private struct PageSwitchHarness: View {
        let clock: TestClock
        let probe: AboutLiveProbe
        let scheduler: ManualWakeScheduler
        @ObservedObject var selection: PageSelection
        let size: CGSize

        var body: some View {
            Group {
                if selection.showAbout {
                    ScrollView(.vertical) {
                        AboutPage(
                            version: "1.0",
                            build: "1",
                            now: { clock.read() },
                            probe: probe,
                            wakeScheduler: scheduler
                        )
                        .frame(width: size.width)
                    }
                    .frame(width: size.width, height: size.height)
                } else {
                    Color.clear
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// Drives the page's focused-row value.
    ///
    /// A programmatic `@FocusState` assignment is refused by the focus system
    /// in a window that is never key (the value stays nil), so the hosted test
    /// supplies the value the focus state would hold. The page's own
    /// `onChange` handler, the one the real focus state calls, is what runs.
    private struct FocusDriver: View {
        let page: AboutPage
        @ObservedObject var request: FocusRequest

        var body: some View {
            var page = page
            page.rowFocusValue = request.row
            return page
        }
    }

    private struct ReduceDriver: View {
        let page: AboutPage
        @ObservedObject var toggle: ReduceSwitch

        var body: some View {
            page.environment(\.aboutReduceMotion, toggle.on)
        }
    }

    @MainActor
    private final class FrameBox {
        var frames: [String: CGRect] = [:]
    }

    private struct Live {
        let clock: TestClock
        let probe: AboutLiveProbe
        let hosting: NSHostingView<AnyView>
        let window: OffscreenWindow
        let tracker: AboutMarkTrackingView?
        let scheduler: ManualWakeScheduler
        let box: FrameBox
    }

    /// An offscreen window that can never become key, so the test runner's
    /// activation changes cannot post a key resignation the tracker would
    /// rightly answer. The tracker's key provider is overridden for events.
    private final class InertWindow: OffscreenWindow {
        override var canBecomeKey: Bool { false }
    }

    private func makeLive(
        clock: TestClock,
        probe: AboutLiveProbe = AboutLiveProbe(),
        updateCheck: (@MainActor () async -> AboutUpdateState)? = nil,
        wakeScheduler: ManualWakeScheduler? = nil,
        now: (@MainActor () -> Double)? = nil,
        root: ((AboutPage) -> AnyView)? = nil
    ) -> Live {
        let scheduler = wakeScheduler ?? ManualWakeScheduler(clock: clock)
        let box = FrameBox()
        let page = AboutPage(
            version: "1.0",
            build: "1",
            onLayout: { box.frames = $0.frames },
            now: now ?? { clock.read() },
            updateCheck: updateCheck,
            probe: probe,
            wakeScheduler: scheduler
        )
        let view = root?(page) ?? AnyView(
            ScrollView(.vertical) {
                page.frame(width: self.size.width)
            }
            .frame(width: self.size.width, height: self.size.height)
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = OffscreenWindow(size: size)
        window.contentView = hosting
        pump()
        let tracker = findTracker(in: hosting)
        tracker?.isActiveProvider = { true }
        tracker?.isKeyWindowProvider = { true }
        tracker?.ignoresRemoteResets = true
        pump()
        return Live(
            clock: clock,
            probe: probe,
            hosting: hosting,
            window: window,
            tracker: tracker,
            scheduler: scheduler,
            box: box
        )
    }

    @MainActor
    private func makeSwitch(
        clock: TestClock,
        probe: AboutLiveProbe,
        scheduler: ManualWakeScheduler,
        selection: PageSelection
    ) -> (hosting: NSHostingView<PageSwitchHarness>, window: OffscreenWindow) {
        let hosting = NSHostingView(
            rootView: PageSwitchHarness(
                clock: clock,
                probe: probe,
                scheduler: scheduler,
                selection: selection,
                size: size
            )
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = InertWindow(size: size)
        window.contentView = hosting
        pump()
        return (hosting, window)
    }

    private func pump(_ rounds: Int = 8) {
        for _ in 0..<rounds {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Moves the injected clock and lets the page redraw.
    ///
    /// Every wake whose deadline has been reached fires first, as time passing
    /// would. No frame time is supplied.
    private func render(_ live: Live, at time: Double) {
        live.clock.current = time
        live.scheduler.fire(upTo: time)
        pump(4)
        live.scheduler.fire(upTo: time)
        pump(2)
    }

    private func findPresenceView(in view: NSView) -> AboutHostWindow.PresenceView? {
        if let presence = view as? AboutHostWindow.PresenceView { return presence }
        for child in view.subviews {
            if let found = findPresenceView(in: child) { return found }
        }
        return nil
    }

    private func findTracker(in view: NSView) -> AboutMarkTrackingView? {
        if let tracker = view as? AboutMarkTrackingView { return tracker }
        for child in view.subviews {
            if let found = findTracker(in: child) { return found }
        }
        return nil
    }

    private func bitmap(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
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
        ) else { return nil }
        rep.size = size
        view.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
        return rep
    }

    private func png(_ rep: NSBitmapImageRep) throws -> Data {
        try XCTUnwrap(rep.representation(using: .png, properties: [:]), "no PNG")
    }

    /// A plate-local point's brightest channel. Plate ink is about 36; a dot
    /// at full energy is about 128; a half-faded patch is about 97.
    private func brightness(_ point: CGPoint, in rep: NSBitmapImageRep) -> Int {
        let c = rep.rawPixel(
            x: Int((point.x * 2).rounded()),
            y: Int((point.y * 2).rounded())
        )
        return max(c.0, c.1, c.2)
    }

    /// The x with the brightest pixel in a plate-local band.
    private func brightestX(
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        in rep: NSBitmapImageRep
    ) -> (x: Double, brightness: Int) {
        let x0 = max(0, Int(xRange.lowerBound * 2))
        let x1 = min(rep.pixelsWide - 1, Int(xRange.upperBound * 2))
        let y0 = max(0, Int(yRange.lowerBound * 2))
        let y1 = min(rep.pixelsHigh - 1, Int(yRange.upperBound * 2))
        var best = 0
        var bestX = xRange.lowerBound
        for x in x0...x1 {
            for y in y0...y1 {
                let c = rep.rawPixel(x: x, y: y)
                let value = max(c.0, c.1, c.2)
                if value > best {
                    best = value
                    bestX = Double(x) / 2
                }
            }
        }
        return (bestX, best)
    }

    private func hasLitPixel(
        in rect: CGRect,
        _ rep: NSBitmapImageRep,
        threshold: Int = 80
    ) -> Bool {
        let x0 = max(0, Int(rect.minX * 2))
        let x1 = min(rep.pixelsWide - 1, Int(rect.maxX * 2))
        let y0 = max(0, Int(rect.minY * 2))
        let y1 = min(rep.pixelsHigh - 1, Int(rect.maxY * 2))
        guard x0 <= x1, y0 <= y1 else { return false }
        for y in stride(from: y0, through: y1, by: 2) {
            for x in stride(from: x0, through: x1, by: 2) {
                let c = rep.rawPixel(x: x, y: y)
                if max(c.0, c.1, c.2) > threshold { return true }
            }
        }
        return false
    }

    private func peakBrightness(in rect: CGRect, _ rep: NSBitmapImageRep) -> Int {
        let x0 = max(0, Int(rect.minX * 2))
        let x1 = min(rep.pixelsWide - 1, Int(rect.maxX * 2))
        let y0 = max(0, Int(rect.minY * 2))
        let y1 = min(rep.pixelsHigh - 1, Int(rect.maxY * 2))
        guard x0 <= x1, y0 <= y1 else { return 0 }
        var peak = 0
        for y in y0...y1 {
            for x in x0...x1 {
                let c = rep.rawPixel(x: x, y: y)
                peak = max(peak, max(c.0, c.1, c.2))
            }
        }
        return peak
    }

    /// The first row, top down, that carries ink inside and just around a
    /// settled frame. An entrance offset is a render transform, so the frame
    /// itself does not move.
    private func topInkRow(
        in frame: CGRect,
        _ rep: NSBitmapImageRep,
        threshold: Int = 120
    ) -> Int? {
        let x0 = max(0, Int(frame.minX * 2))
        let x1 = min(rep.pixelsWide - 1, Int(frame.maxX * 2))
        let y0 = max(0, Int((frame.minY - 10) * 2))
        let y1 = min(rep.pixelsHigh - 1, Int((frame.maxY + 10) * 2))
        guard x0 <= x1, y0 <= y1 else { return nil }
        for y in y0...y1 {
            for x in x0...x1 {
                let c = rep.rawPixel(x: x, y: y)
                if max(c.0, c.1, c.2) > threshold { return y }
            }
        }
        return nil
    }

    private func sendMouseMoved(
        _ live: Live,
        to platePoint: CGPoint
    ) throws {
        let tracker = try XCTUnwrap(live.tracker, "no tracking view")
        let viewPoint = NSPoint(
            x: platePoint.x,
            y: tracker.bounds.height - platePoint.y
        )
        let windowPoint = tracker.convert(viewPoint, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: tracker.window?.windowNumber ?? live.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        tracker.mouseMoved(with: event)
    }

    private func sendMouseExited(_ live: Live) throws {
        let tracker = try XCTUnwrap(live.tracker, "no tracking view")
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: live.tracker?.window?.windowNumber ?? live.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        tracker.mouseExited(with: event)
    }

    /// A point on the entrance front's path at 200 ms, in clear plate below
    /// the colophon text. At rest it is plate ink.
    private var entranceFrontPoint: CGPoint { CGPoint(x: 410, y: 90) }
    private var entranceFrontRegion: CGRect {
        CGRect(x: 398, y: 80, width: 34, height: 24)
    }

    /// A point on a checking front's path 200 ms in, between the status
    /// reserve and the rule. At rest it is plate ink.
    private var checkingFrontAt200: CGRect {
        CGRect(x: 446, y: 62, width: 14, height: 14)
    }

    /// The entrance is suppressed through the real cooldown branch, so a test
    /// that is about the pause loop or the pointer starts from a still page.
    private func suppressEntrance(_ clock: TestClock) {
        AboutEntranceGate.lastStartedAt = clock.current
    }

    // MARK: Entrance

    /// The live entrance is drawn from the one store clock. The first
    /// evaluated frame stamps t = 0: the painted title is 6 points lower and
    /// its ink is at 65 percent. At 100 ms it is between the two, and at the
    /// deadline it is byte-identical to the settled capture.
    func testTheEntranceDrawsItsStartPoseFromTheOneClock() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        let live = makeLive(clock: clock, probe: probe)
        pump()

        XCTAssertEqual(probe.entranceStartedAt, start, "the first frame did not stamp the one clock")
        XCTAssertTrue(probe.entranceRunning, "the entrance is not running after attach")
        let startPose = try XCTUnwrap(probe.entrancePoses["title"], "no title pose at t=0")
        XCTAssertEqual(startPose.offsetY, AboutMotion.entranceRise, accuracy: 0.01, "the start pose is not 6 pt down")
        XCTAssertEqual(startPose.opacity, AboutMotion.entranceOpacity, accuracy: 0.001, "the start pose is not at 65 percent")

        let title = try XCTUnwrap(live.box.frames["title"], "the title frame was not measured")
        var rep = try XCTUnwrap(bitmap(live.hosting), "no start bitmap")
        let startTop = try XCTUnwrap(topInkRow(in: title, rep), "no title ink at the start")
        let startPeak = peakBrightness(in: title.insetBy(dx: -2, dy: -10), rep)

        render(live, at: start + 100)
        let midPose = try XCTUnwrap(probe.entrancePoses["title"], "no title pose at 100 ms")
        XCTAssertGreaterThan(midPose.offsetY, 0, "the title snapped to its end by 100 ms")
        XCTAssertLessThan(midPose.offsetY, AboutMotion.entranceRise, "the title did not move by 100 ms")
        XCTAssertGreaterThan(midPose.opacity, AboutMotion.entranceOpacity, "the title did not brighten by 100 ms")
        XCTAssertLessThan(midPose.opacity, 1, "the title reached full opacity by 100 ms")

        rep = try XCTUnwrap(bitmap(live.hosting), "no 100 ms bitmap")
        let midTop = try XCTUnwrap(topInkRow(in: title, rep), "no title ink at 100 ms")
        XCTAssertGreaterThan(startTop, midTop, "the title did not move up from the start")
        let midPeak = peakBrightness(in: title.insetBy(dx: -2, dy: -10), rep)
        XCTAssertGreaterThan(midPeak, startPeak, "the title did not brighten from the start")
        XCTAssertLessThan(midPeak, 250, "the title reached its settled ink by 100 ms")
        let midPNG = try png(rep)

        render(live, at: start + 700)
        XCTAssertNil(probe.entranceStartedAt, "the entrance did not settle at its deadline")
        XCTAssertFalse(probe.entranceRunning, "the entrance still draws after its deadline")
        XCTAssertEqual(probe.paused, true, "the settled page left the clock running")
        rep = try XCTUnwrap(bitmap(live.hosting), "no settled bitmap")
        let settledTop = try XCTUnwrap(topInkRow(in: title, rep), "no title ink at rest")
        XCTAssertGreaterThan(startTop, midTop, "the start and mid title are in the wrong order")
        XCTAssertGreaterThan(midTop, settledTop, "the title did not land above its 100 ms place")
        XCTAssertEqual(
            Double(startTop - settledTop) / 2,
            Double(AboutMotion.entranceRise),
            accuracy: 1,
            "the painted start pose is not 6 pt below the settled title"
        )

        let plate = brightness(CGPoint(x: 250, y: 95), in: rep)
        let startInk = Double(startPeak - plate)
        let settledInk = Double(peakBrightness(in: title.insetBy(dx: -2, dy: -10), rep) - plate)
        XCTAssertGreaterThan(settledInk, 100, "the settled title has no contrast to measure")
        XCTAssertEqual(
            startInk / settledInk,
            AboutMotion.entranceOpacity,
            accuracy: 0.08,
            "the painted start ink is not about 65 percent of the settled ink"
        )
        XCTAssertNotEqual(midPNG, try png(rep), "the 100 ms frame and the settled frame are identical")

        let settledPNG = try png(rep)
        render(live, at: start + 2_000)
        rep = try XCTUnwrap(bitmap(live.hosting), "no late settled bitmap")
        XCTAssertEqual(
            settledPNG,
            try png(rep),
            "the settled entrance is not identical to the settled page"
        )
    }

    /// The epoch belongs to the first frame the root actually samples, not to
    /// the attach. A window that takes 60 ms to present still paints the exact
    /// start pose on its first frame, and the matrix uses the same epoch.
    func testTheFirstRootFrameStampsTheEntranceEpoch() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        let delayed = DelayedClock(clock)
        let live = makeLive(clock: clock, probe: probe, now: { delayed.read() })
        pump()

        XCTAssertEqual(
            probe.entranceStartedAt,
            start + 60,
            "the first sampled frame did not stamp the entrance epoch"
        )
        XCTAssertTrue(probe.entranceRunning, "the entrance is not running")
        let pose = try XCTUnwrap(
            probe.entrancePoses["title"],
            "no title pose on the first sampled frame"
        )
        XCTAssertEqual(
            pose.offsetY,
            AboutMotion.entranceRise,
            accuracy: 0.0001,
            "the first sampled frame is not the entrance start"
        )
        XCTAssertEqual(
            pose.opacity,
            AboutMotion.entranceOpacity,
            accuracy: 0.0001,
            "the first sampled frame is not at the entrance start opacity"
        )
        let matrix = try XCTUnwrap(
            probe.matrixTitleOffset,
            "the matrix did not draw the first sampled frame"
        )
        XCTAssertEqual(
            matrix,
            pose.offsetY,
            accuracy: 0.0001,
            "the matrix used a different entrance epoch"
        )
        _ = live
    }

    /// The plate samples the entrance once per frame and hands the same time
    /// to the title and to the matrix knockouts. The applied title offset and
    /// the offset the lattice uses for its title hole are the same value.
    func testTheEntranceSamplesOneFrameForTextAndKnockouts() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        let live = makeLive(clock: clock, probe: probe)
        pump()
        XCTAssertEqual(probe.entranceStartedAt, start)

        for elapsed in [35.0, 85.0, 150.0] {
            render(live, at: start + elapsed)
            let pose = try XCTUnwrap(
                probe.entrancePoses["title"],
                "no title pose at \(elapsed) ms"
            )
            let knockout = try XCTUnwrap(
                probe.matrixTitleOffset,
                "the matrix did not report its title offset at \(elapsed) ms"
            )
            XCTAssertEqual(
                pose.offsetY,
                knockout,
                "text and knockouts sampled different frames at \(elapsed) ms"
            )
            XCTAssertGreaterThan(pose.offsetY, 0, "the title already settled at \(elapsed) ms")
            XCTAssertLessThanOrEqual(
                pose.offsetY,
                AboutMotion.entranceRise,
                "the title started below its start pose at \(elapsed) ms"
            )
            XCTAssertGreaterThanOrEqual(
                pose.opacity,
                AboutMotion.entranceOpacity,
                "the title is dimmer than its start pose at \(elapsed) ms"
            )
            XCTAssertLessThanOrEqual(
                pose.opacity,
                1,
                "the title is brighter than settled at \(elapsed) ms"
            )
        }
        _ = live
    }

    /// During the entrance the root closure samples only the shared timestamp
    /// and the entrance snapshot. Pointer moves redraw the matrix at that same
    /// timestamp but never re-evaluate the root content closure.
    func testPointerMovesDuringTheEntranceDoNotResampleTheRoot() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        probe.freezeRootClock = true
        let live = makeLive(clock: clock, probe: probe)
        pump()
        XCTAssertTrue(probe.entranceRunning, "the entrance is not running")

        // The first move writes the page's row intent; later moves write only
        // the store, which is the path this test measures.
        try sendMouseMoved(live, to: CGPoint(x: 196, y: 28))
        pump()
        let rootBefore = probe.rootSamples
        let matrixBefore = probe.matrixSamples
        XCTAssertGreaterThan(rootBefore, 0, "the root never sampled a frame")
        XCTAssertGreaterThan(matrixBefore, 0, "the matrix never drew a frame")

        for step in 0..<50 {
            let point = step.isMultiple(of: 2)
                ? CGPoint(x: 194, y: 26)
                : CGPoint(x: 196, y: 28)
            try sendMouseMoved(live, to: point)
        }
        pump()

        XCTAssertEqual(
            probe.rootSamples,
            rootBefore,
            "a pointer move re-evaluated the entrance root"
        )
        XCTAssertGreaterThan(
            probe.matrixSamples,
            matrixBefore,
            "the matrix did not redraw for the pointer moves"
        )
        XCTAssertTrue(probe.pointerActive, "the moves did not reach the store")
        let rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertTrue(
            hasLitPixel(
                in: CGRect(x: 186, y: 18, width: 18, height: 18),
                rep,
                threshold: 80
            ),
            "the matrix did not light the patch during the entrance"
        )
        _ = live
    }

    /// The entrance's settle must not rebuild the page subtree. The tracking
    /// view mounted at the start is still the window's tracker, and pointer
    /// events still reach the store once the entrance is over.
    func testTheEntranceSettleKeepsThePageSubtree() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        let live = makeLive(clock: clock, probe: probe)
        pump()
        let tracker = try XCTUnwrap(live.tracker, "no tracking view")
        XCTAssertTrue(
            tracker.window === live.window,
            "the tracker is not mounted during the entrance"
        )
        render(live, at: start + 700)
        XCTAssertTrue(
            tracker.window === live.window,
            "the entrance settle replaced the tracking view"
        )
        XCTAssertTrue(live.tracker === tracker, "the page no longer owns the mounted tracker")
        try sendMouseMoved(live, to: CGPoint(x: 196, y: 28))
        pump()
        render(live, at: start + 2_000)
        XCTAssertTrue(probe.pointerActive, "the settled page lost its pointer handling")
    }

    /// The cooldown gate still applies to a new page: an entrance that started
    /// less than 1.2 s ago is not replayed.
    func testASecondPageInsideTheCooldownSettlesItsEntrance() throws {
        let clock = TestClock(start)
        AboutEntranceGate.lastStartedAt = start
        let probe = AboutLiveProbe()
        _ = makeLive(clock: clock, probe: probe)
        XCTAssertNil(probe.entranceStartedAt, "the cooldown let a second entrance start")
        XCTAssertFalse(probe.entranceRunning, "the cooldown left the entrance running")
        XCTAssertEqual(probe.paused, true, "the cooldown left a clock running")
    }

    /// Reduce Motion switched on during the entrance lands settled, with no
    /// offset and no running clock.
    func testReduceMotionToggledMidEntranceLandsSettled() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        let toggle = ReduceSwitch()
        let live = makeLive(
            clock: clock,
            probe: probe,
            root: { page in
                AnyView(
                    ReduceDriver(page: page, toggle: toggle)
                        .frame(width: self.size.width, height: self.size.height)
                )
            }
        )
        pump()
        XCTAssertNotNil(probe.entranceStartedAt, "the entrance never started")

        toggle.on = true
        pump()

        let pose = try XCTUnwrap(probe.entrancePoses["title"], "no title pose")
        XCTAssertEqual(pose.offsetY, 0, accuracy: 0.01, "Reduce Motion left an offset")
        XCTAssertEqual(pose.opacity, 1, accuracy: 0.001, "Reduce Motion left a dimmed group")
        XCTAssertNil(probe.entranceStartedAt, "Reduce Motion left the clock running")
        XCTAssertFalse(probe.entranceRunning, "Reduce Motion left the entrance drawing")
        XCTAssertEqual(probe.paused, true, "Reduce Motion did not pause the leaf")
        _ = live
    }

    // MARK: Idle

    func testTheIdleLivePageIsDarkAndPaused() throws {
        let clock = TestClock(start)
        suppressEntrance(clock)
        let live = makeLive(clock: clock)
        render(live, at: start + 1_000)
        let rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertEqual(live.probe.updateText, "")
        XCTAssertFalse(hasLitPixel(in: entranceFrontRegion, rep), "a dot is lit at rest")
        XCTAssertFalse(hasLitPixel(in: frontRegion, rep), "the colophon has a dot at rest")
        XCTAssertEqual(live.probe.paused, true, "the clock runs at rest")
    }

    // MARK: Update

    func testACheckLightsTheFrontsAndTheResultDoesNotCutThem() throws {
        let clock = TestClock(start)
        let gate = UpdateGate()
        suppressEntrance(clock)
        let live = makeLive(clock: clock, updateCheck: { await gate.check() })
        render(live, at: start + 1_000)

        live.probe.requestUpdate?()
        pump()
        XCTAssertEqual(live.probe.updateText, "Checking...", "the label waited for the request")

        render(live, at: start + 1_200)
        XCTAssertEqual(live.probe.paused, false, "the fronts do not keep the clock")
        var rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertTrue(
            hasLitPixel(in: checkingFrontAt200, rep),
            "no checking front 200 ms in"
        )

        gate.release(.upToDate)
        pump()
        XCTAssertEqual(live.probe.updateText, "Up to date", "the result was delayed")

        render(live, at: start + 1_300)
        XCTAssertEqual(
            live.probe.paused,
            false,
            "the result cut the fronts instead of letting them finish"
        )
        rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertTrue(
            hasLitPixel(in: entranceFrontRegion, rep),
            "the result cut the fronts before their 300 ms place"
        )

        render(live, at: start + 2_000)
        rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertEqual(live.probe.paused, true, "the clock runs after the result settled")
        XCTAssertFalse(hasLitPixel(in: checkingFrontAt200, rep), "a dot survived the settled result")
        XCTAssertFalse(hasLitPixel(in: entranceFrontRegion, rep), "a dot survived the settled result")
    }

    /// The production pause loop is driven by its scheduler, not by a frame
    /// time: an early wake re-arms, the deadline wake pauses, and the running
    /// branch is visibly lit before the deadline.
    func testThePauseLoopRearmsOnAnEarlyWakeAndPausesOnTheDeadline() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        let scheduler = ManualWakeScheduler(clock: clock)
        let gate = UpdateGate()
        suppressEntrance(clock)
        let live = makeLive(
            clock: clock,
            probe: probe,
            updateCheck: { await gate.check() },
            wakeScheduler: scheduler
        )
        pump()
        XCTAssertEqual(probe.paused, true, "the settled page is not paused")

        live.probe.requestUpdate?()
        pump()
        XCTAssertEqual(probe.paused, false, "the checking fronts did not start the clock")
        XCTAssertEqual(
            scheduler.nextDue,
            start + AboutMotion.Matrix.checkingEnd,
            "the loop did not sleep to the checking deadline"
        )

        // Wake 100 ms in, before the deadline: the loop must re-read and sleep
        // again rather than pause.
        clock.advance(100)
        scheduler.fireNext()
        pump()
        XCTAssertEqual(probe.paused, false, "an early wake paused the leaf")
        XCTAssertEqual(
            scheduler.nextDue,
            start + AboutMotion.Matrix.checkingEnd,
            "the loop did not re-arm to the same deadline"
        )

        // The running canvas is not dark while the fronts travel.
        render(live, at: start + 200)
        var rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertTrue(
            hasLitPixel(in: checkingFrontAt200, rep),
            "the running branch drew no lit pixels"
        )

        clock.current = start + AboutMotion.Matrix.checkingEnd
        scheduler.fireNext()
        pump()
        XCTAssertEqual(probe.paused, true, "the deadline wake did not pause")
        rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertFalse(
            hasLitPixel(in: checkingFrontAt200, rep),
            "the paused terminal frame kept a checking dot"
        )
        XCTAssertEqual(probe.pauseLoop?.taskCount, 1, "the pause loop created more than one task")
        gate.release(.upToDate)
        pump()
    }

    // MARK: Tracking

    func testTrackingLightsThePatchAndTheExitFadesIt() throws {
        let clock = TestClock(start)
        suppressEntrance(clock)
        let live = makeLive(clock: clock)
        render(live, at: start + 2_000)

        // Enter away from the target, then retarget so the spring travels.
        clock.current = start + 2_000
        try sendMouseMoved(live, to: CGPoint(x: 300, y: 40))
        pump()
        clock.current = start + 2_010
        try sendMouseMoved(live, to: CGPoint(x: 100, y: 20))
        pump()
        render(live, at: start + 3_000)
        var rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertTrue(
            brightness(CGPoint(x: 100, y: 20), in: rep) > 80,
            "the patch did not centre on the tracking point"
        )
        XCTAssertEqual(live.probe.paused, true, "a settled patch keeps the clock")

        clock.current = start + 3_040
        try sendMouseExited(live)
        pump()
        render(live, at: start + 3_100)
        rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertTrue(
            brightness(CGPoint(x: 100, y: 20), in: rep) > 80,
            "the patch was gone 60 ms into the exit"
        )
        XCTAssertEqual(live.probe.paused, false, "the exit does not keep the clock")

        render(live, at: start + 3_340)
        rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertLessThanOrEqual(
            brightness(CGPoint(x: 100, y: 20), in: rep),
            80,
            "the patch survived the exit"
        )
        XCTAssertEqual(live.probe.paused, true, "the clock runs after the exit")
    }

    /// A retarget springs from the presented position: at 50 ms the patch is
    /// strictly between the two points, and it keeps moving toward the target.
    func testARetargetSpringsFromThePresentedPosition() throws {
        let clock = TestClock(start)
        suppressEntrance(clock)
        let live = makeLive(clock: clock)
        render(live, at: start + 2_000)
        try sendMouseMoved(live, to: CGPoint(x: 196, y: 28))
        pump()
        render(live, at: start + 3_000)
        var rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertGreaterThan(brightness(CGPoint(x: 196, y: 28), in: rep), 80)

        clock.current = start + 3_000
        try sendMouseMoved(live, to: CGPoint(x: 324, y: 28))
        pump()

        render(live, at: start + 3_050)
        rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        let early = brightestX(xRange: 190...340, yRange: 22...38, in: rep)
        XCTAssertGreaterThan(early.brightness, 80, "no patch at 50 ms")
        let travel = 128.0
        let remaining = 324 - early.x
        XCTAssertGreaterThan(remaining, travel * 0.20, "the patch snapped to the target at 50 ms")
        XCTAssertLessThan(remaining, travel * 0.95, "the patch did not move at 50 ms")

        render(live, at: start + 3_120)
        rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        let late = brightestX(xRange: 190...340, yRange: 22...38, in: rep)
        XCTAssertGreaterThan(late.brightness, 80, "no patch at 120 ms")
        XCTAssertGreaterThan(late.x - early.x, 4, "the patch did not move toward the target")
        XCTAssertLessThanOrEqual(late.x, 324.5, "the patch passed the target")
    }

    /// A detached host's loop is gone; reattaching the same page starts a new
    /// one. A pointer retarget then runs without a frame-time override: the
    /// leaf is unpaused, its patch is lit, and it pauses at the deadline.
    func testReattachingStartsTheLoopAndDrawsTheRetarget() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        suppressEntrance(clock)
        let live = makeLive(clock: clock, probe: probe)
        render(live, at: start + 1_000)
        try sendMouseMoved(live, to: CGPoint(x: 100, y: 20))
        pump()
        render(live, at: start + 2_000)
        XCTAssertEqual(probe.paused, true, "the settled patch did not pause")
        XCTAssertEqual(probe.pauseLoop?.taskCount, 1, "the first attach did not start one task")

        live.window.contentView = nil
        pump()
        XCTAssertEqual(probe.paused, true, "the detached host left its clock running")
        XCTAssertNil(probe.requestUpdate, "the detach did not clear the probe callbacks")

        let second = OffscreenWindow(size: size)
        second.contentView = live.hosting
        pump()
        XCTAssertTrue(live.tracker?.window === second, "the tracker did not move to the new window")
        XCTAssertNotNil(probe.requestUpdate, "the reattach did not reinstall the probe callbacks")
        XCTAssertEqual(probe.entranceRunning, false, "the reattach replayed the entrance")
        XCTAssertEqual(probe.paused, true, "the reattached page started unpaused before an event")
        XCTAssertEqual(
            probe.pauseLoop?.taskCount,
            1,
            "the reattach did not start a fresh loop"
        )

        // A first move lands a fresh patch, then a second retargets it: the
        // spring travels and the reattached loop must run until its deadline.
        clock.current = start + 2_900
        try sendMouseMoved(live, to: CGPoint(x: 100, y: 20))
        pump()
        clock.current = start + 3_000
        try sendMouseMoved(live, to: CGPoint(x: 196, y: 28))
        pump()
        XCTAssertEqual(probe.paused, false, "the retarget did not start the reattached loop")
        var rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertTrue(
            hasLitPixel(
                in: CGRect(x: 94, y: 14, width: 14, height: 14),
                rep,
                threshold: 80
            ),
            "the reattached leaf drew no patch at the event time"
        )

        // Fifty milliseconds in, the spring is between the two points.
        clock.current = start + 3_050
        pump()
        XCTAssertEqual(probe.paused, false, "the reattached loop paused mid-flight")
        rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertTrue(
            hasLitPixel(
                in: CGRect(x: 126, y: 16, width: 30, height: 24),
                rep,
                threshold: 80
            ),
            "the reattached patch was not lit between the two points"
        )

        // The first window no longer owns the tracker: its resignation must
        // not reset the patch the second window drives.
        live.tracker?.ignoresRemoteResets = false
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: live.window
        )
        pump()
        XCTAssertTrue(
            probe.pointerActive,
            "the first window's resignation reset the second window's patch"
        )

        clock.current = start + 3_400
        live.scheduler.fire(upTo: start + 3_400)
        pump()
        XCTAssertEqual(probe.paused, true, "the reattached loop did not pause at the deadline")
        rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertTrue(
            hasLitPixel(
                in: CGRect(x: 190, y: 22, width: 14, height: 14),
                rep,
                threshold: 80
            ),
            "the terminal frame is not the settled patch"
        )

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: second
        )
        pump()
        XCTAssertFalse(probe.pointerActive, "the owning window did not reset the patch")
        clock.current = start + 4_000
        live.scheduler.fire(upTo: start + 4_000)
        pump()
        XCTAssertEqual(probe.paused, true, "the exit after the reset kept the clock")
        rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertFalse(
            hasLitPixel(
                in: CGRect(x: 190, y: 22, width: 14, height: 14),
                rep,
                threshold: 80
            ),
            "the patch survived the owning window's resignation"
        )
    }

    // MARK: Window owner

    /// A direct move from window A to window B is not a reattach: the old
    /// owner's pointer and loop stop, a fresh loop starts for B, B's tracker
    /// drives the patch, and A's resignation has no authority.
    func testAWindowOwnerChangeResetsAndRestartsTheLoop() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        let live = makeLive(clock: clock, probe: probe)
        render(live, at: start + 700)
        XCTAssertNil(probe.entranceStartedAt, "the entrance did not settle before the move")
        try sendMouseMoved(live, to: CGPoint(x: 196, y: 28))
        pump()
        render(live, at: start + 2_000)
        XCTAssertTrue(probe.pointerActive, "the first owner never got a patch")
        let oldLoop = try XCTUnwrap(probe.pauseLoop, "the first owner had no loop")

        let second = InertWindow(size: size)
        second.contentView = live.hosting
        pump()
        XCTAssertTrue(live.tracker?.window === second, "the tracker did not follow the owner")
        XCTAssertFalse(probe.pointerActive, "the old owner's pointer survived the owner change")
        XCTAssertEqual(probe.paused, true, "the owner change left the old clock running")
        let newLoop = try XCTUnwrap(probe.pauseLoop, "the new owner has no loop")
        XCTAssertFalse(newLoop === oldLoop, "the old owner's loop was reused")
        XCTAssertNil(probe.entranceStartedAt, "the owner change replayed the entrance")
        XCTAssertEqual(probe.entranceRunning, false, "the owner change left the entrance drawing")
        XCTAssertEqual(
            AboutEntranceGate.lastStartedAt,
            start,
            "the owner change advanced the entrance gate"
        )
        // Let the window's queued key resignation from the move arrive before
        // the tracking event that is being tested.
        pump(3)

        // The window's own key resignation from the move can be delivered
        // after the first event; the second event lands after it.
        clock.current = start + 3_000
        try sendMouseMoved(live, to: CGPoint(x: 100, y: 20))
        pump()
        clock.current = start + 3_010
        try sendMouseMoved(live, to: CGPoint(x: 196, y: 28))
        pump()
        XCTAssertEqual(probe.paused, false, "the new owner's loop did not start")
        render(live, at: start + 3_400)
        let rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertGreaterThan(
            brightness(CGPoint(x: 196, y: 28), in: rep),
            80,
            "the new owner's tracker did not light its target"
        )

        live.tracker?.ignoresRemoteResets = false
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: live.window
        )
        pump()
        XCTAssertTrue(probe.pointerActive, "the old owner's resignation reset the new patch")

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: second
        )
        pump()
        XCTAssertFalse(probe.pointerActive, "the new owner's resignation did not reset the patch")
    }

    /// A report posted before the view moves to its next window must be
    /// revalidated when it is delivered. A stale nil would otherwise stop the
    /// loop that now owns the page.
    func testAStaleWindowReportRevalidatesAtDelivery() throws {
        let first = InertWindow(size: size)
        let second = InertWindow(size: size)
        var reports: [ObjectIdentifier?] = []
        let view = AboutHostWindow.PresenceView()
        view.onChange = { reports.append($0) }
        first.contentView = view
        pump()
        XCTAssertEqual(reports.last ?? nil, ObjectIdentifier(first))

        reports.removeAll()
        first.contentView = nil
        second.contentView = view
        pump()
        XCTAssertFalse(
            reports.contains(where: { $0 == nil }),
            "a stale nil report was delivered after the view moved"
        )
        XCTAssertEqual(reports.last ?? nil, ObjectIdentifier(second))
        view.stop()
    }

    /// The page-level invariant behind the bridge test: a nil report posted
    /// before the move and delivered after it leaves the new owner's loop
    /// running.
    func testAStaleReportDoesNotStopTheNewOwnersLoop() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        suppressEntrance(clock)
        let live = makeLive(clock: clock, probe: probe)
        render(live, at: start + 1_000)

        let second = InertWindow(size: size)
        probe.windowReports.removeAll()
        live.window.contentView = nil
        second.contentView = live.hosting
        pump()
        XCTAssertEqual(
            probe.windowReports,
            [ObjectIdentifier(second)],
            "the page accepted a stale window report after the move"
        )
        XCTAssertNotNil(probe.pauseLoop, "the new owner has no loop after the stale report")
        XCTAssertTrue(live.tracker?.window === second, "the tracker did not follow the owner")
        pump(3)

        clock.current = start + 2_000
        try sendMouseMoved(live, to: CGPoint(x: 100, y: 20))
        pump()
        clock.current = start + 2_010
        try sendMouseMoved(live, to: CGPoint(x: 196, y: 28))
        pump()
        XCTAssertEqual(probe.paused, false, "the new owner's loop is not running")
    }

    // MARK: Rows and focus

    /// Hover is driven through the production handler, focus through the
    /// value the real focus state would hold, and leaving the row returns
    /// intent to the focused row.
    func testFocusOnARowBeatsAHoverThatWasThereFirst() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        let request = FocusRequest()
        suppressEntrance(clock)
        let live = makeLive(
            clock: clock,
            probe: probe,
            root: { page in
                AnyView(
                    FocusDriver(page: page, request: request)
                        .frame(width: self.size.width, height: self.size.height)
                )
            }
        )
        render(live, at: start + 2_000)
        var engaged: [Int: Bool] = [:]
        probe.rowEngaged = { row, on in engaged[row] = on }

        probe.hoverRow?(0, .active(CGPoint(x: 10, y: 10)))
        pump()
        XCTAssertEqual(probe.activeRow, 0, "the hover did not engage row 0")
        XCTAssertEqual(engaged[0], true, "row 0 did not engage")

        request.row = 1
        pump()
        XCTAssertEqual(probe.lastFocusedRow, 1, "the page never saw the focus")
        XCTAssertEqual(probe.activeRow, 1, "the focus lost to a resting pointer")
        XCTAssertEqual(engaged[1], true, "row 1 did not engage")
        XCTAssertEqual(engaged[0], false, "row 0 stayed engaged")

        probe.hoverRow?(0, .active(CGPoint(x: 12, y: 10)))
        pump()
        XCTAssertEqual(probe.activeRow, 0, "a moved pointer did not take the intent")

        probe.hoverRow?(0, .ended)
        pump()
        XCTAssertEqual(probe.lastEndedIntent, .keyboard, "the ended handler did not return intent")
        XCTAssertEqual(probe.activeRow, 1, "leaving the row did not return intent to the focus")
        XCTAssertEqual(engaged[1], true, "the focused row did not engage again")
        _ = live
    }

    /// A late end from the row the pointer left after it had already moved to
    /// another row changes nothing.
    func testALateEndFromThePreviousRowIsIgnored() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        suppressEntrance(clock)
        let live = makeLive(clock: clock, probe: probe)
        render(live, at: start + 2_000)

        probe.hoverRow?(0, .active(CGPoint(x: 10, y: 10)))
        pump()
        XCTAssertEqual(probe.activeRow, 0, "row 0 did not engage")

        probe.hoverRow?(1, .active(CGPoint(x: 10, y: 10)))
        pump()
        XCTAssertEqual(probe.activeRow, 1, "row 1 did not take the pointer")

        probe.hoverRow?(0, .ended)
        pump()
        XCTAssertEqual(probe.activeRow, 1, "a late end from row 0 dropped row 1")
        XCTAssertEqual(probe.lastEndedIntent, nil, "a late end returned intent to the keyboard")
        _ = live
    }

    // MARK: Detach and probes

    /// A detached host drops the pointer, pauses its leaf, and comes back
    /// without a patch until the pointer moves again.
    func testDetachingTheHostResetsThePointerAndPauses() throws {
        let clock = TestClock(start)
        let probe = AboutLiveProbe()
        suppressEntrance(clock)
        let live = makeLive(clock: clock, probe: probe)
        render(live, at: start + 1_000)
        try sendMouseMoved(live, to: CGPoint(x: 196, y: 28))
        pump()
        clock.current = start + 1_010
        try sendMouseMoved(live, to: CGPoint(x: 60, y: 60))
        pump()
        XCTAssertEqual(probe.paused, false, "the retarget did not start the loop")
        XCTAssertNotNil(live.scheduler.nextDue, "the travelling spring left no pending wake")

        live.window.contentView = nil
        pump()
        XCTAssertNil(probe.requestUpdate, "the detach did not clear the probe callbacks")
        XCTAssertEqual(probe.paused, true, "the detached host left its clock running")
        XCTAssertFalse(probe.pointerActive, "the detached host kept its pointer")
        XCTAssertNil(live.scheduler.nextDue, "the detach did not cancel the pending wake")

        let second = OffscreenWindow(size: size)
        second.contentView = live.hosting
        render(live, at: start + 3_000)
        let rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        XCTAssertLessThanOrEqual(
            brightness(CGPoint(x: 196, y: 28), in: rep),
            80,
            "the pointer came back without a new move"
        )
    }

    /// An injected probe is not retained after the on-screen host goes away.
    func testAnInjectedProbeIsReleasedWithTheHost() throws {
        weak var weakHost: NSHostingView<AnyView>?
        var probe: AboutLiveProbe? = AboutLiveProbe()
        weak let weakProbe = probe
        var window: OffscreenWindow? = OffscreenWindow(size: size)
        autoreleasepool {
            let clock = TestClock(start)
            autoreleasepool {
                let page = AboutPage(
                    version: "1.0",
                    build: "1",
                    now: { clock.read() },
                    probe: probe
                )
                let created = NSHostingView(
                    rootView: AnyView(page.frame(width: self.size.width, height: self.size.height))
                )
                created.frame = NSRect(origin: .zero, size: size)
                weakHost = created
                window?.contentView = created
                pump()
            }
            window?.contentView = nil
            pump()
        }
        window = nil
        probe = nil
        pump()
        XCTAssertNil(weakHost, "the hosting view outlived its window")
        XCTAssertNil(weakProbe, "the probe outlived the page that used it")
    }

    // MARK: Teardown

    /// A report queued before the bridge is dismantled must not attach a
    /// store after teardown. The report re-checks the dismantled flag and
    /// calls the current callback when it is delivered.
    func testAQueuedWindowReportCannotAttachAfterDismantle() throws {
        let clock = TestClock(start)
        AboutEntranceGate.lastStartedAt = clock.current
        let scheduler = ManualWakeScheduler(clock: clock)
        let box = BridgeAttachBox()
        let view = BridgeOnlyView(
            onChange: { window in
                guard window != nil else { return }
                box.attaches += 1
                let store = AboutMotionStore(now: { clock.read() }, scheduler: scheduler)
                store.attach()
                box.store = store
                box.loop = store.loop
            },
            onTeardown: {}
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        let window = InertWindow(size: CGSize(width: 120, height: 80))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let presence = try XCTUnwrap(findPresenceView(in: hosting), "no bridge view")
        presence.viewDidMoveToWindow()
        AboutHostWindow.dismantleNSView(presence, coordinator: ())
        pump()

        XCTAssertEqual(box.attaches, 0, "the queued report attached after dismantle")
        XCTAssertNil(box.loop, "the queued report left a loop")
        XCTAssertNil(box.store, "the queued report left a store")
        _ = window
    }

    /// The bridge's explicit dismantle signals the page synchronously, once,
    /// through the dismantle path that writes no page state.
    func testTheBridgeDismantleSignalsTeardownSynchronously() {
        let view = AboutHostWindow.PresenceView()
        var calls = 0
        var stateTeardowns = 0
        view.onDismantle = { calls += 1 }
        view.onTeardown = { stateTeardowns += 1 }
        AboutHostWindow.dismantleNSView(view, coordinator: ())
        XCTAssertEqual(calls, 1, "the bridge dismantle did not signal teardown")
        view.dismantle()
        XCTAssertEqual(calls, 1, "a second dismantle signalled teardown again")
        XCTAssertEqual(stateTeardowns, 0, "the dismantle ran the state-writing teardown")
    }

    /// SwiftUI can dismantle the bridge while it invalidates the graph, when
    /// no `onDisappear` follows. The dismantle path alone must stop the
    /// page's clock and release the probe's hold on it, synchronously.
    func testTheDismantlePathAloneStopsThePageClock() throws {
        let clock = TestClock(start)
        suppressEntrance(clock)
        let probe = AboutLiveProbe()
        let scheduler = ManualWakeScheduler(clock: clock)
        let live = makeLive(clock: clock, probe: probe, wakeScheduler: scheduler)
        let presence = try XCTUnwrap(findPresenceView(in: live.hosting), "no bridge view")
        let store = try XCTUnwrap(probe.store, "the page did not attach a store")
        XCTAssertNotNil(store.loop, "no loop to observe")

        AboutHostWindow.dismantleNSView(presence, coordinator: ())

        XCTAssertNil(store.loop, "the dismantle left the loop running")
        XCTAssertTrue(store.paused, "the dismantle left the store unpaused")
        XCTAssertNil(scheduler.nextDue, "the dismantle left a wake")
        XCTAssertNil(probe.store, "the probe kept the store")
        XCTAssertNil(probe.requestUpdate, "the probe kept its page callbacks")
        _ = live
    }

    /// A settings page switch removes the page while its window stays. The
    /// parked pause loop must be cancelled and released, not left sleeping on
    /// its own continuation.
    func testAPageSwitchInAParkedLoopCancelsAndReleasesTheLoop() throws {
        let clock = TestClock(start)
        suppressEntrance(clock)
        let probe = AboutLiveProbe()
        let scheduler = ManualWakeScheduler(clock: clock)
        let selection = PageSelection()
        let (_, window) = makeSwitch(
            clock: clock,
            probe: probe,
            scheduler: scheduler,
            selection: selection
        )
        XCTAssertEqual(probe.paused, true, "the page did not park its loop")
        XCTAssertNil(scheduler.nextDue, "the parked loop left a wake")
        XCTAssertEqual(probe.pauseLoop?.taskCount, 1, "the page did not start one loop")
        weak let weakLoop = probe.pauseLoop
        weak let weakStore = probe.store
        XCTAssertNotNil(weakLoop, "no loop to observe")
        XCTAssertNotNil(weakStore, "no store to observe")

        selection.showAbout = false
        pump()

        XCTAssertNil(weakLoop, "the parked loop survived the page removal")
        XCTAssertNil(weakStore, "the store survived the page removal")
        _ = window
    }

    /// The same page switch while the loop is sleeping on a timer must cancel
    /// that timer and release the loop and store.
    func testAPageSwitchWhileTheLoopSleepsCancelsItsTimerAndLoop() throws {
        let clock = TestClock(start)
        suppressEntrance(clock)
        let probe = AboutLiveProbe()
        let scheduler = ManualWakeScheduler(clock: clock)
        let selection = PageSelection()
        let (_, window) = makeSwitch(
            clock: clock,
            probe: probe,
            scheduler: scheduler,
            selection: selection
        )
        XCTAssertNotNil(probe.movePointer, "the page did not install its pointer handler")
        clock.current = start + 100
        probe.movePointer?(CGPoint(x: 100, y: 20))
        pump()
        clock.current = start + 110
        probe.movePointer?(CGPoint(x: 196, y: 28))
        XCTAssertTrue(probe.pointerActive, "the pointer did not reach the store")
        pump()
        XCTAssertEqual(probe.paused, false, "the retarget did not start the loop")
        XCTAssertNotNil(scheduler.nextDue, "the loop is not sleeping on a wake")
        weak let weakLoop = probe.pauseLoop
        weak let weakStore = probe.store
        XCTAssertNotNil(weakLoop, "no loop to observe")
        XCTAssertNotNil(weakStore, "no store to observe")

        selection.showAbout = false
        pump()

        XCTAssertNil(weakLoop, "the sleeping loop survived the page removal")
        XCTAssertNil(weakStore, "the store survived the page removal")
        XCTAssertNil(scheduler.nextDue, "the sleeping loop's timer survived the removal")
        _ = window
    }

    /// A page that disappears and reappears in the same window keeps its
    /// store. Move reports are suppressed, so only the update-time report can
    /// restore the page's window state before a later handoff.
    func testAReappearingPageRestoresItsWindowBeforeAHandoff() throws {
        let clock = TestClock(start)
        suppressEntrance(clock)
        let probe = AboutLiveProbe()
        let selection = PageSelection()
        let live = makeLive(
            clock: clock,
            probe: probe,
            root: { page in
                AnyView(
                    RetainedPageSwitchHarness(
                        page: page,
                        selection: selection,
                        size: self.size
                    )
                )
            }
        )
        pump()
        let store = try XCTUnwrap(probe.store, "no store after the first attach")
        XCTAssertEqual(probe.windowPresent, true, "the first attach has no window state")
        XCTAssertEqual(
            probe.windowIdentity,
            ObjectIdentifier(live.window),
            "the first attach has the wrong owner"
        )
        XCTAssertEqual(probe.paused, true, "the first attach left the loop running")

        probe.suppressWindowMoves?(true)
        pump()
        let presence = try XCTUnwrap(
            findPresenceView(in: live.hosting),
            "no bridge before the disappear"
        )
        presence.reportsWindowMoves = false
        probe.windowReports.removeAll()
        selection.tab = 1
        pump()
        XCTAssertNil(probe.store, "the disappear left the probe store installed")
        XCTAssertEqual(probe.windowReports.count, 0, "the bridge moved on the tab switch: \(probe.windowReports)")
        XCTAssertEqual(probe.windowPresent, false, "the disappear left windowPresent set")
        XCTAssertNil(probe.windowIdentity, "the disappear left the owner set")

        selection.tab = 0
        pump()
        XCTAssertTrue(
            probe.store === store,
            "the page did not retain its store across the reappearance"
        )
        XCTAssertEqual(
            probe.windowPresent,
            true,
            "the reappearance did not restore windowPresent"
        )
        XCTAssertEqual(
            probe.windowIdentity,
            ObjectIdentifier(live.window),
            "the reappearance did not restore the owner"
        )
        XCTAssertNil(probe.entranceStartedAt, "the reappearance replayed the entrance")
        XCTAssertFalse(probe.entranceRunning, "the reappearance replayed the entrance")
        XCTAssertNotNil(probe.pauseLoop, "the reappearance left no loop")
        XCTAssertEqual(probe.paused, true, "the reappearance left the loop running")

        clock.current = start + 100
        probe.movePointer?(CGPoint(x: 100, y: 20))
        pump()
        clock.current = start + 110
        probe.movePointer?(CGPoint(x: 196, y: 28))
        pump()
        XCTAssertEqual(probe.paused, false, "the patch did not start the loop")
        XCTAssertTrue(probe.pointerActive, "the patch did not reach the store")
        let oldLoop = try XCTUnwrap(probe.pauseLoop, "no loop before the handoff")

        // Re-enable move reports for the handoff itself; the reappearance above
        // was restored only by the update-time report.
        let handoffPresence = try XCTUnwrap(
            findPresenceView(in: live.hosting),
            "no bridge before the handoff"
        )
        handoffPresence.reportsWindowMoves = true
        let second = InertWindow(size: size)
        second.contentView = live.hosting
        pump()
        let tracker = try XCTUnwrap(findTracker(in: live.hosting), "no tracker after the handoff")
        XCTAssertTrue(tracker.window === second, "the tracker did not follow the handoff")
        XCTAssertFalse(probe.pointerActive, "the handoff kept the old window's pointer")
        XCTAssertEqual(probe.paused, true, "the handoff left the old clock running")
        let newLoop = try XCTUnwrap(probe.pauseLoop, "the handoff left no loop")
        XCTAssertFalse(newLoop === oldLoop, "the handoff reused the old loop")
        XCTAssertEqual(
            probe.windowIdentity,
            ObjectIdentifier(second),
            "the handoff did not record the second owner"
        )
    }

    /// Two hundred real tracking events update the deadline on the one pause
    /// task; a pointer move never creates a task.
    func testPointerEventsCreateOnePauseTask() throws {
        let clock = TestClock(start)
        suppressEntrance(clock)
        let live = makeLive(clock: clock)
        XCTAssertEqual(probeTaskCount(live), 1, "the page did not start one pause task")
        for step in 0..<200 {
            clock.current += 8
            try sendMouseMoved(
                live,
                to: CGPoint(x: 60 + Double(step % 240), y: 24 + Double(step % 30))
            )
            if step % 40 == 0 { pump(2) }
        }
        pump()
        XCTAssertEqual(probeTaskCount(live), 1, "a pointer move created a second pause task")
    }

    /// A tracker move inside the plate writes the store and nothing on the
    /// page: two hundred moves leave the page's body untouched.
    func testPointerMovesDoNotEvaluateThePageBody() throws {
        let clock = TestClock(start)
        suppressEntrance(clock)
        let live = makeLive(clock: clock)
        pump()
        let before = live.probe.bodyEvaluations
        XCTAssertGreaterThan(before, 0, "the page body never ran")
        for step in 0..<200 {
            clock.current += 8
            try sendMouseMoved(
                live,
                to: CGPoint(x: 40 + Double(step % 300), y: 10 + Double(step % 90))
            )
        }
        pump()
        XCTAssertEqual(
            live.probe.bodyEvaluations,
            before,
            "a pointer move re-evaluated the page's body"
        )
        XCTAssertTrue(live.probe.pointerActive, "the moves did not reach the store")
        render(live, at: start + 2_000)
        let rep = try XCTUnwrap(bitmap(live.hosting), "no bitmap")
        let last = CGPoint(x: 40 + Double(199 % 300), y: 10 + Double(199 % 90))
        XCTAssertTrue(
            hasLitPixel(
                in: CGRect(x: last.x - 6, y: last.y - 6, width: 12, height: 12),
                rep,
                threshold: 80
            ),
            "the page drew no patch after the moves"
        )
    }

    /// Reports the cost of one real tracking event plus the layout it
    /// invalidates. The handler's own budget is asserted; the synchronous
    /// event plus a full page layout is a report only.
    func testTrackingEventCostStaysInsideTheBudget() throws {
        let clock = TestClock(start)
        suppressEntrance(clock)
        let live = makeLive(clock: clock)
        var handlers: [Double] = []
        var withLayout: [Double] = []
        // The handler alone, called through the probe's production hook.
        for step in 0..<300 {
            clock.current += 8
            let point = CGPoint(
                x: 80 + Double(step % 200),
                y: 30 + Double(step % 20)
            )
            let began = CFAbsoluteTimeGetCurrent()
            live.probe.movePointer?(point)
            handlers.append((CFAbsoluteTimeGetCurrent() - began) * 1000)
        }
        // One real tracking event plus the synchronous layout it invalidates.
        for step in 0..<300 {
            clock.current += 8
            let point = CGPoint(
                x: 80 + Double(step % 200),
                y: 30 + Double(step % 20)
            )
            let began = CFAbsoluteTimeGetCurrent()
            try sendMouseMoved(live, to: point)
            live.hosting.layoutSubtreeIfNeeded()
            withLayout.append((CFAbsoluteTimeGetCurrent() - began) * 1000)
            if step % 50 == 0 { pump(2) }
        }
        func report(_ name: String, _ samples: [Double]) {
            let sorted = samples.sorted()
            print(
                String(
                    format: "%@ p50 %.4f p95 %.4f max %.4f",
                    name,
                    sorted[sorted.count / 2],
                    sorted[Int(Double(sorted.count - 1) * 0.95)],
                    sorted.last ?? 0
                )
            )
        }
        report("MATRIX-EVENT-HANDLER", handlers)
        report("MATRIX-EVENT", withLayout)
        let sorted = handlers.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        XCTAssertLessThanOrEqual(
            p95,
            0.1,
            "a tracking handler's 95th percentile is over 0.1 ms"
        )
        XCTAssertEqual(probeTaskCount(live), 1, "a pointer event created a second pause task")
    }

    private func probeTaskCount(_ live: Live) -> Int {
        live.probe.pauseLoop?.taskCount ?? 0
    }

    private var frontRegion: CGRect {
        // Clear of the control, the status line and the colophon text.
        CGRect(x: 360, y: 76, width: 140, height: 26)
    }
}

private extension NSBitmapImageRep {
    /// The bytes the offscreen renderer wrote, before ColorSync applies the
    /// PNG's calibrated profile. The plate ink is 36, 33, 30 on this path.
    func rawPixel(x: Int, y: Int) -> (Int, Int, Int) {
        guard let colour = colorAt(x: x, y: y) else {
            return (0, 0, 0)
        }
        return (
            Int(colour.redComponent * 255),
            Int(colour.greenComponent * 255),
            Int(colour.blueComponent * 255)
        )
    }
}
