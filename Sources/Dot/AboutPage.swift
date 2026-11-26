import AppKit
import DotCore
import SwiftUI

// MARK: - This build

/// What the About page says about the build it is drawn in.
///
/// The version comes from ``ProductVersion`` and the build number from the
/// bundle, so the page cannot disagree with the binary or with the update
/// check. A binary that was not assembled into a bundle reports the version
/// type's own `unknown` rather than a number nobody can check.
enum AboutInfo {
    /// The build number the bundle declares.
    static var build: String {
        let declared = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let trimmed = declared?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? ProductVersion.unknown : trimmed
    }

    /// The macOS version running the app.
    static var operatingSystem: String {
        operatingSystem(ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// A system version as the line writes it, with the patch number only when
    /// it says something.
    static func operatingSystem(_ version: OperatingSystemVersion) -> String {
        guard version.patchVersion != 0 else {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The line someone pastes into a bug report.
    static func copyLine(version: String, build: String, macOS: String) -> String {
        "Dot \(version) (\(build)), macOS \(macOS)"
    }

    /// The colophon's value: the version as people read it. The build number
    /// appears only in the copied bug-report line.
    static func valueLine(version: String) -> String {
        ProductVersion.displayName(version)
    }
}

/// What the update control is showing.
enum AboutUpdateState: Equatable, Sendable {
    /// Nothing has been asked yet.
    case idle
    /// A request is in flight.
    case checking
    /// The running build is the newest release.
    case upToDate
    /// A newer release exists, with its page when the response named one.
    case available(version: String, page: URL?)
    /// The request did not produce a release.
    case unreachable

    /// The control's name, which changes once a release exists to open.
    var controlLabel: String {
        switch self {
        case .available: "View release"
        case .idle, .checking, .upToDate, .unreachable: "Check for updates"
        }
    }

    /// The line under the control, set in words rather than in colour alone.
    var statusText: String {
        switch self {
        case .idle: ""
        case .checking: "Checking..."
        case .upToDate: "Up to date"
        case .available(let version, _): "Version \(ProductVersion.displayName(version)) available"
        case .unreachable: "Could not reach GitHub"
        }
    }

    /// A check already in flight owns the control until it answers.
    var acceptsAnotherCheck: Bool { self != .checking }
}

/// The update control's fill, kept separate from its press feedback.
///
/// The highlight is a colour change rather than movement: it still answers a
/// hover or a keyboard focus when motion is reduced, and the shared press is
/// left to ``DotPressStyle``.
enum AboutControlFill {
    static let rest: Double = 0.08
    static let highlighted: Double = 0.13

    static func opacity(isHighlighted: Bool) -> Double {
        isHighlighted ? highlighted : rest
    }
}

/// A transparent view that reports the pointer over the plate.
///
/// It installs only a key-window tracking area and never becomes a hit target.
/// The point it reports is local to this view, which the page sizes to the
/// plate, so the model always receives plate-local points no matter where the
/// pointer is over the plate. When motion is reduced the coordinator removes
/// the area, so no pointer event can reach the plate.
struct AboutMarkPointerRegion: NSViewRepresentable {
    let enabled: Bool
    let onMove: (CGPoint?) -> Void
    var onClick: (CGPoint) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onMove: onMove, onClick: onClick) }

    func makeNSView(context: Context) -> AboutMarkTrackingView {
        let view = AboutMarkTrackingView()
        view.wantsLayer = false
        return view
    }

    func updateNSView(_ nsView: AboutMarkTrackingView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.onClick = onClick
        context.coordinator.setEnabled(enabled, in: nsView)
    }

    static func dismantleNSView(_ nsView: AboutMarkTrackingView, coordinator: Coordinator) {
        coordinator.stop(in: nsView)
    }

    @MainActor
    final class Coordinator {
        var onMove: (CGPoint?) -> Void
        var onClick: (CGPoint) -> Void
        private var area: NSTrackingArea?
        private var clickMonitor: Any?
        /// The owner's identity, not a weak window. AppKit can hand back a
        /// window that is already deallocating while a teardown transaction
        /// flushes; forming a weak reference to it aborts the process.
        private var windowIdentity: ObjectIdentifier?
        private weak var view: AboutMarkTrackingView?
        private var observers: [NSObjectProtocol] = []

        init(onMove: @escaping (CGPoint?) -> Void, onClick: @escaping (CGPoint) -> Void = { _ in }) {
            self.onMove = onMove
            self.onClick = onClick
        }

        func setEnabled(_ enabled: Bool, in view: AboutMarkTrackingView) {
            guard enabled else {
                stop(in: view)
                return
            }
            self.view = view
            view.onMove = { [weak self] point in self?.onMove(point) }
            view.onClick = { [weak self] point in self?.onClick(point) }
            view.onWindowChange = { [weak self] window in self?.watch(window) }
            install(in: view)
            watch(view.window)
        }

        func stop(in view: AboutMarkTrackingView) {
            remove(from: view)
            watch(nil)
        }

        private func install(in view: AboutMarkTrackingView) {
            if area == nil {
                let area = NSTrackingArea(
                    rect: view.bounds,
                    options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                    owner: view,
                    userInfo: ["AboutMarkPointerRegion": true]
                )
                self.area = area
                view.addTrackingArea(area)
            }
            if clickMonitor == nil {
                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak view] event in
                    let location = event.locationInWindow
                    let eventWindow = event.windowNumber
                    MainActor.assumeIsolated {
                        view?.handleLocalClick(locationInWindow: location, windowNumber: eventWindow)
                    }
                    return event
                }
            }
        }

        func watch(_ window: NSWindow?) {
            let identity = window.map(ObjectIdentifier.init)
            guard windowIdentity != identity else { return }
            clearObservers()
            windowIdentity = identity
            guard let window else { return }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                let owner = note.object as? NSWindow
                MainActor.assumeIsolated { self?.reset(from: owner) }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reset(from: nil) }
            })
        }

        private func clearObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        /// Clears the patch for a window notification. A queued resignation
        /// from an owner that has already been replaced is ignored.
        func reset(from window: NSWindow?) {
            if view?.ignoresRemoteResets == true { return }
            if let window, windowIdentity != ObjectIdentifier(window) { return }
            onMove(nil)
        }

        private func remove(from view: AboutMarkTrackingView) {
            if let area { view.removeTrackingArea(area) }
            area = nil
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            view.onMove = nil
            view.onClick = nil
            view.onWindowChange = nil
        }
    }
}

/// The tracking view's one job is to turn an AppKit mouse event into a local
/// point. It never draws, never becomes first responder and never answers a
/// click with an action of its own.
final class AboutMarkTrackingView: NSView {
    var onMove: ((CGPoint?) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onWindowChange: ((NSWindow?) -> Void)?
    var isActiveProvider: () -> Bool = { NSApp.isActive }
    lazy var isKeyWindowProvider: () -> Bool = { [weak self] in self?.window?.isKeyWindow ?? false }
    /// A hosted test that supplies its own key and active answers also opts
    /// out of the window's real resignations, which the test runner's own
    /// activation changes can post. The tests that check resignation set it
    /// back to false and post the notification themselves.
    var ignoresRemoteResets = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onMove?(nil) }

    func handleLocalClick(locationInWindow: NSPoint, windowNumber: Int) {
        guard isActiveProvider(), isKeyWindowProvider(),
              let window, window.windowNumber == windowNumber,
              bounds.width > 0, bounds.height > 0
        else { return }
        let point = convert(locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?(CGPoint(x: point.x, y: bounds.height - point.y))
    }

    private func report(_ event: NSEvent) {
        guard isActiveProvider(), isKeyWindowProvider() else {
            onMove?(nil)
            return
        }
        let point = window == nil ? event.locationInWindow : convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        // AppKit's view origin is the bottom-left; the plate's is the top-left.
        onMove?(CGPoint(x: point.x, y: bounds.height - point.y))
    }
}

/// The frames a headless host reads back from the page.
///
/// The renderer draws these views off screen, where AppKit exposes no
/// accessibility tree for a SwiftUI button. A geometry reader in each named
/// region reports its own frame instead, so the plate and its contents are
/// measured where they are laid out rather than guessed from a picture.
struct AboutLayoutSnapshot: Equatable {
    var frames: [String: CGRect] = [:]
}

private struct AboutFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct AboutLayoutReportingKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var aboutLayoutReporting: Bool {
        get { self[AboutLayoutReportingKey.self] }
        set { self[AboutLayoutReportingKey.self] = newValue }
    }
}

private struct AboutFrameReporter: ViewModifier {
    @Environment(\.aboutLayoutReporting) private var reports

    let name: String

    func body(content: Content) -> some View {
        if reports {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: AboutFrameKey.self,
                        value: [name: geometry.frame(in: .named(AboutPage.layoutSpace))]
                    )
                }
            }
        } else {
            content
        }
    }
}

private extension View {
    func aboutFrame(_ name: String) -> some View {
        modifier(AboutFrameReporter(name: name))
    }
}

// MARK: - The page

/// The About page inside Settings.
///
/// Dot has one About surface. It is this page: the name and the build, the one
/// place the update check can be run from, and the places Dot lives. The menu
/// bar's About Dot opens Settings here rather than a second window that would
/// have to be kept in step with this one.
///
/// The plate's motion is a pure function of ``AboutMotionInput``. A live page
/// keeps the clock, the pointer spring and the engagement timestamps outside
/// the model and asks it for a frame; a render supplies the same input with
/// animations disabled, so a sampled strip and the running page draw from one
/// set of values.
/// The state a hosted live-path test reads without touching the page's
/// private state. It is inert in production: the page allocates none unless a
/// test injects one, and every callback is optional.
///
/// The published values drive the test's rendering or are read after a pump;
/// the plain values are snapshots the test reads without causing a re-render.
@MainActor
final class AboutLiveProbe: ObservableObject {
    /// Whether the leaf's clock is paused.
    @Published var paused: Bool?
    /// The status text the page currently shows.
    @Published var updateText: String?
    /// The row the arbitration engaged.
    @Published var activeRow: Int?

    /// The presented entrance pose of every group, keyed by its frame name.
    var entrancePoses: [String: AboutEntrancePose] = [:]
    /// The monotonic millisecond the live entrance was stamped with.
    var entranceStartedAt: Double?
    /// Whether the entrance is still drawing.
    var entranceRunning = false
    /// The title offset the matrix last used to move its knockouts. A hosted
    /// test compares it with the offset the title view applied in the same
    /// sampled frame.
    var matrixTitleOffset: CGFloat?
    /// How many times the root entrance closure sampled a frame.
    var rootSamples = 0
    /// A hosted test that isolates pointer work pauses the root schedule after
    /// its first evaluation; production leaves this false.
    var freezeRootClock = false
    /// How many times the matrix leaf evaluated its canvas.
    var matrixSamples = 0
    /// The store this page created, held weakly so a teardown test can prove
    /// it was released.
    weak var store: AboutMotionStore?
    /// How many times the page's own body ran. A pointer move is expected to
    /// leave this unchanged.
    var bodyEvaluations = 0
    /// Whether the matrix currently has a pointer patch to draw.
    var pointerActive = false
    /// The last focused-row value the page saw, for diagnosis in hosted tests.
    var lastFocusedRow: Int?
    var lastEndedIntent: AboutRowInput?
    /// The page's window state. A hosted test reads these after a pump.
    var windowPresent: Bool?
    var windowIdentity: ObjectIdentifier?
    /// The window identity of every owner change the page accepted, so a test
    /// can prove a stale report never reached it.
    var windowReports: [ObjectIdentifier?] = []

    /// The pause loop the store created, so a test can inspect its task count.
    weak var pauseLoop: AboutPauseLoop?

    /// Test triggers, installed by the page when it appears. They call the
    /// same production handlers the views call.
    var requestUpdate: (() -> Void)?
    var hoverRow: ((Int, HoverPhase) -> Void)?
    var movePointer: ((CGPoint?) -> Void)?
    /// Reports a leaf row's engaged state.
    var rowEngaged: ((Int, Bool) -> Void)?
    /// Turns the bridge's move reports off or on. Installed only for a
    /// hosted test that isolates the update-time report.
    var suppressWindowMoves: ((Bool) -> Void)?

    func countBodyEvaluation() {
        bodyEvaluations += 1
    }
}

/// The offset and opacity a group is actually drawn with at this instant.
struct AboutEntrancePose: Equatable {
    var offsetY: CGFloat
    var opacity: Double
}

/// A reduce-motion answer a host can set, in addition to the system setting and
/// Dot's own preference. A preview or a hosted test uses it to change the value
/// without changing the Mac's accessibility setting.
struct AboutReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var aboutReduceMotion: Bool {
        get { self[AboutReduceMotionKey.self] }
        set { self[AboutReduceMotionKey.self] = newValue }
    }
}

@MainActor
struct AboutPage: View {
    /// The version to show, exactly as the bundle declares it.
    let version: String
    /// The build number, or `nil` outside a bundle that declares one.
    var build: String?
    /// A state to draw instead of asking GitHub. Renders pass one.
    var previewUpdate: AboutUpdateState?
    /// Opens the welcome window.
    var onOpenWelcome: () -> Void = {}
    /// Reveals the log file in Finder.
    var onOpenLog: () -> Void = {}
    /// Counts a press made in a preview, where no request may be sent.
    var onPreviewUpdatePress: (() -> Void)?
    /// Reads the laid-out frames in a headless host.
    var onLayout: ((AboutLayoutSnapshot) -> Void)?
    /// A sampled frame a render asks the page to draw. When present the page
    /// draws exactly this input and turns every animation off.
    var previewMotion: AboutMotionInput?
    /// A clock a clip drives frame by frame. The content groups and the matrix
    /// evaluate it at `previewTime`, the same model call the live leaves make;
    /// row engagement still arrives through `previewMotion`.
    var previewClock: AboutMotionClock?
    /// The frame time the preview clock is evaluated at, in monotonic ms.
    var previewTime: Double?
    /// Holds the control's highlight for an offscreen disabled-state sample.
    var previewControlHighlighted: Bool?
    /// Reports the whole per-frame matrix leaf work, for the frame budget check.
    var onCanvasDraw: ((Double) -> Void)?
    /// The monotonic clock events are anchored on, in milliseconds.
    /// Production reads seconds since boot; a hosted test injects its own.
    var now: @MainActor @Sendable () -> Double = AboutTimebase.now
    /// The update request. Production asks GitHub; a hosted test releases a
    /// result it controls.
    var updateCheck: (@MainActor () async -> AboutUpdateState)?
    /// The live-path probe a hosted test reads. Production passes none.
    var probe: AboutLiveProbe?
    /// The scheduler the pause loop waits on. Production uses a run-loop
    /// timer; a hosted test injects a manual one.
    var wakeScheduler: AboutWakeScheduling?
    /// The focused row a host reports. Production leaves it nil and the page
    /// uses its own focus state; a hosted test passes the value the focus
    /// system would hold, because the focus engine refuses a programmatic
    /// assignment in a window that is never key.
    var rowFocusValue: Int?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.aboutReduceMotion) private var forcedReduceMotion
    @FocusState private var controlFocused: Bool
    @FocusState private var copyFocused: Bool
    @FocusState private var internalFocusedRow: Int?
    @State private var focusedRowState: Int?
    @State private var copied = false
    @State private var update: AboutUpdateState = .idle
    @State private var copyReset: Task<Void, Never>?
    @State private var statusDismissTask: Task<Void, Never>?
    @State private var controlHovered = false
    @State private var hoveredRow: Int?
    @State private var lastRowInput: AboutRowInput = .pointer
    @State private var motionFrames: [String: CGRect] = [:]
    @State private var store: AboutMotionStore?
    @State private var windowPresent = false
    @State private var windowIdentity: ObjectIdentifier?
    @Namespace private var destinationsHighlight
    @Namespace private var actionsHighlight
    /// Bumped on appear so the bridge is updated and reports its current
    /// window even when it did not move.
    @State private var windowQuery = 0
    /// A hosted test turns off move reports after the first attach so the
    /// reappearance can only be restored by the update-time report.
    @State private var suppressWindowMoveReports = false

    /// The coordinate space every reported frame is measured in.
    static let layoutSpace = "AboutPage.content"
    /// The coordinate space the matrix knockouts are measured in.
    static let plateSpace = "AboutPage.plate"
    /// The mark is drawn from the approved icon geometry on an imaginary 100 pt
    /// square pinned to the plate's top right corner.
    private static let markSquare: CGFloat = 100
    private static let markDiameter: CGFloat = markSquare * DotMarkDial.clipped.diameter
    private static let markRightInset: CGFloat = markSquare * (1 - DotMarkDial.clipped.centre.x)
    private static let markTopInset: CGFloat = markSquare * DotMarkDial.clipped.centre.y
    /// The trailing room the control leaves for the cropped disc.
    private static let markReserve: CGFloat = 72

    private var reducesMotion: Bool {
        forcedReduceMotion || systemReduceMotion || DotMotion.reducesMotion
    }

    private var shouldReportMotionFrames: Bool {
        if previewMotion != nil || previewClock != nil || onLayout != nil {
            return true
        }
        if motionFrames.count < 8 {
            return true
        }
        if currentUpdate != .idle {
            return true
        }
        return store?.entranceRunning ?? true
    }

    var body: some View {
        probe?.countBodyEvaluation()
        return Group {
            if let previewMotion {
                pageBody(sample: previewMotion)
                    .transaction { $0.disablesAnimations = true }
            } else {
                pageBody(sample: nil)
            }
        }
        .frame(maxWidth: .infinity)
        // An offscreen host draws a settled frame: its implicit transitions
        // would otherwise be caught at whatever opacity the pump reached. The
        // live page keeps them once it is in a window.
        .transaction { transaction in
            if !windowPresent { transaction.disablesAnimations = true }
        }
        .environment(\.aboutLayoutReporting, onLayout != nil)
        .environment(\.aboutMotionReporting, shouldReportMotionFrames)
        .coordinateSpace(name: Self.layoutSpace)
        .onPreferenceChange(AboutFrameKey.self) { frames in
            onLayout?(AboutLayoutSnapshot(frames: frames))
        }
        .onPreferenceChange(AboutMotionFrameKey.self) { frames in
            guard shouldReportMotionFrames, !frames.isEmpty else { return }
            if motionFrames != frames { motionFrames = frames }
        }
        .onPreferenceChange(AboutEntrancePoseKey.self) { poses in
            probe?.entrancePoses = poses
        }
        .background(
            AboutHostWindow(
                onChange: { window in windowChanged(window) },
                onTeardown: { teardownWindow() },
                reportsWindowMoves: !suppressWindowMoveReports,
                windowQuery: windowQuery,
                onKeyDown: { finishEntrance() },
                onPress: { finishEntrance() }
            )
        )
        .onAppear {
            windowQuery &+= 1
            installProbe()
            if let store { attach(store) }
        }
        .onDisappear {
            // A page switch removes this view while its window stays. The
            // bridge may already be gone by the time its posted report would
            // run, so the page detaches synchronously here as well. Both
            // paths are idempotent, and a surviving bridge's delivery-time
            // report still reattaches a move to another window.
            teardownWindow()
        }
        .onChange(of: currentUpdate.statusText) { _, text in
            probe?.updateText = text
        }
        .onChange(of: activeRow) { _, row in
            probe?.activeRow = row
        }
        .onChange(of: focusedRowValue) { _, row in
            focusedRowState = row
            probe?.lastFocusedRow = row
            handleKeyboardFocus(row)
        }
        .onChange(of: focusTarget) { _, target in
            focusChanged(target)
        }
        .onChange(of: reducesMotion) { resetMotion() }
    }

    // MARK: The drawn page

    private func pageBody(sample: AboutMotionInput?) -> some View {
        let base = AboutMotionContext(
            store: store,
            sample: sample,
            clock: previewClock,
            time: previewTime,
            now: now,
            probe: probe
        )
        return AboutPageMotionRoot(context: base) { context in
            VStack(spacing: 14) {
                plate(context: context)
                destinations(context: context)
                actions(context: context)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The text and control frames the lattice keeps clear of, in plate-local
    /// points. Every one travels with its own group's entrance offset.
    private var knockoutFrames: [String: CGRect] {
        var names: Set<String> = [
            "title", "tagline", "control",
            "versionLabel", "versionValue", "copy",
            "systemLabel", "systemValue",
        ]
        if !currentUpdate.statusText.isEmpty {
            names.insert("status")
        }
        var result: [String: CGRect] = [:]
        for (key, rect) in motionFrames where names.contains(key) {
            if key == "title", rect.height > 14 {
                // Trim Satoshi 30 pt's oversized ascender box so dots reach above the glyphs.
                result[key] = CGRect(
                    x: rect.minX,
                    y: rect.minY + 8,
                    width: rect.width,
                    height: rect.height - 11
                )
            } else {
                result[key] = rect
            }
        }
        return result
    }

    // MARK: Dial plate

    /// The matte plate carries the name, the update control and the colophon.
    ///
    /// The white disc and the lattice are one matrix leaf behind the text, so
    /// the hole and the disc can never disagree: both are placed from the same
    /// presented offset. Each content group reads the same store clock through
    /// its own entrance wrapper.
    private func plate(context: AboutMotionContext) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                .fill(AboutDialInk.plate)
            matrixLayer(context: context)
            VStack(spacing: 0) {
                upperBand(context: context)
                Rectangle()
                    .fill(AboutDialInk.rule)
                    .frame(height: 1)
                    .aboutFrame("rule")
                colophon(context: context)
            }
            markReporter(context: context)
        }
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: Self.plateSpace)
        .clipShape(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                .strokeBorder(AboutDialInk.edge, lineWidth: 1)
        )
        .overlay {
            platePointerRegion
        }
        .aboutFrame("plate")
    }

    /// A pointer region over the whole plate.
    ///
    /// It is transparent, passive when the window is not key, and invisible to
    /// the accessibility tree. It reports plate-local points.
    private var platePointerRegion: some View {
        AboutMarkPointerRegion(
            enabled: !reducesMotion,
            onMove: { point in handlePointer(point) },
            onClick: { point in handlePlateClick(point) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aboutFrame("markRegion")
        .allowsHitTesting(true)
        .accessibilityHidden(true)
    }

    // MARK: The mark

    /// Reports the disc frame for the layout tests. The disc itself is drawn
    /// by the matrix leaf, so the hole and the disc share one offset.
    @ViewBuilder
    private func markReporter(context: AboutMotionContext) -> some View {
        if onLayout != nil {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: AboutFrameKey.self,
                    value: ["disc": discFrame(in: geometry, offset: reportedDiscOffset(context))]
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The disc's settled offset. A layout frame is geometry; the entrance's
    /// render offset is not part of it. A sampled frame still reports the pose
    /// it draws.
    private func reportedDiscOffset(_ context: AboutMotionContext) -> CGPoint {
        if let sample = context.sample { return AboutMotion.Matrix.discOffset(sample) }
        if let clock = context.clock, let time = context.time {
            return AboutMotion.Matrix.discOffset(clock.input(at: time))
        }
        return .zero
    }

    private func discFrame(in geometry: GeometryProxy, offset: CGPoint) -> CGRect {
        let plate = geometry.frame(in: .named(Self.layoutSpace))
        return CGRect(
            x: plate.minX + geometry.size.width - Self.markRightInset - Self.markDiameter / 2,
            y: plate.minY + Self.markTopInset - Self.markDiameter / 2,
            width: Self.markDiameter,
            height: Self.markDiameter
        )
        .offsetBy(dx: offset.x, dy: offset.y)
    }

    // MARK: The matrix

    private func matrixLayer(context: AboutMotionContext) -> some View {
        AboutMatrixLeaf(
            store: context.store,
            entranceTime: context.entranceTime,
            probe: probe,
            preview: context.clock == nil ? context.sample : nil,
            previewClock: context.clock,
            previewTime: context.time,
            frames: knockoutFrames,
            now: context.now,
            onCanvasDraw: onCanvasDraw
        )
    }

    // MARK: The upper band

    private func upperBand(context: AboutMotionContext) -> some View {
        let controlCanHighlight = currentUpdate.acceptsAnotherCheck && (controlHovered || controlFocused)
        let fillHighlighted = currentUpdate.acceptsAnotherCheck
            && (previewControlHighlighted ?? controlCanHighlight)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Dot")
                    .font(DotTheme.displayFont(30))
                    .tracking(-0.4)
                    .foregroundStyle(AboutDialInk.value)
                    .accessibilityAddTraits(.isHeader)
                    .aboutContentEntrance(context, group: .title, name: "title")
                    .aboutMotionFrame("title")
                    .aboutFrame("title")

                Text(ProductLinks.tagline)
                    .font(DotType.font(12, .medium))
                    .foregroundStyle(AboutDialInk.status)
                    .fixedSize(horizontal: true, vertical: true)
                    .aboutContentEntrance(context, group: .title, name: "tagline")
                    .aboutMotionFrame("tagline")
                    .aboutFrame("tagline")
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 6) {
                Button(action: performUpdate) {
                    Text(currentUpdate.controlLabel)
                        .font(DotType.font(12, .semibold))
                        .foregroundStyle(
                            currentUpdate.acceptsAnotherCheck ? AboutDialInk.value : AboutDialInk.status
                        )
                        .frame(width: 132, height: 28)
                        .background(
                            Capsule(style: .circular)
                                .fill(AboutDialInk.value.opacity(
                                    AboutControlFill.opacity(
                                        isHighlighted: fillHighlighted
                                    )
                                ))
                        )
                        .overlay(
                            Capsule(style: .circular)
                                .strokeBorder(
                                    AboutDialInk.buttonEdge.opacity(currentUpdate.acceptsAnotherCheck ? 0.9 : 0.45),
                                    lineWidth: 1
                                )
                        )
                        .overlay {
                            if currentUpdate == .checking {
                                AboutUpdateCheckingRim(
                                    reduceMotion: reducesMotion,
                                    isStaticPreview: previewUpdate != nil
                                )
                            }
                        }
                        .aboutContentEntrance(context, group: .update, name: "control")
                        .contentShape(Capsule(style: .circular))
                }
                .buttonStyle(DotPressStyle())
                .disabled(!currentUpdate.acceptsAnotherCheck)
                .focused($controlFocused)
                .onHover { hovering in
                    if DotScrollInteraction.isScrolling {
                        if controlHovered { controlHovered = false }
                        return
                    }
                    controlHovered = hovering
                }
                .onChange(of: currentUpdate.acceptsAnotherCheck) { _, accepts in
                    if !accepts { controlHovered = false }
                }
                .accessibilityLabel(currentUpdate.controlLabel)
                .accessibilityValue(currentUpdate.statusText)
                .aboutMotionFrame("control")
                .aboutFrame("control")

                if !currentUpdate.statusText.isEmpty {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(updateStatusTone)
                            .frame(width: 5, height: 5)
                        Text(currentUpdate.statusText)
                            .font(DotType.font(11, .medium))
                            .foregroundStyle(AboutDialInk.status)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityHidden(true)
                    .fixedSize(horizontal: false, vertical: true)
                    .aboutMotionFrame("status")
                    .aboutFrame("status")
                    .frame(maxWidth: 188, alignment: .trailing)
                    .id(currentUpdate.statusText)
                    .transition(windowPresent ? .opacity : .identity)
                    .aboutContentEntrance(context, group: .update, name: "status")
                }
            }
            .animation(
                windowPresent && !reducesMotion ? .easeOut(duration: 0.12) : nil,
                value: currentUpdate.statusText
            )
            .padding(.trailing, Self.markReserve)
        }
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(minHeight: 84, alignment: .top)
        .padding(.horizontal, 16)
        .aboutFrame("upper")
    }

    private var updateStatusTone: Color {
        switch currentUpdate {
        case .idle: .clear
        case .checking: DotTheme.amber
        case .upToDate: DotTheme.mint
        case .available: DotTheme.accent
        case .unreachable: DotTheme.coral
        }
    }

    // MARK: The colophon

    private func colophon(context: AboutMotionContext) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Version")
                    .font(DotType.font(11, .medium))
                    .foregroundStyle(AboutDialInk.status)
                    .aboutContentEntrance(context, group: .colophon, name: "versionLabel")
                    .aboutMotionFrame("versionLabel")
                    .aboutFrame("versionLabel")
                HStack(spacing: 6) {
                    Text(AboutInfo.valueLine(version: version))
                        .font(DotType.tabularFont(12, .medium))
                        .foregroundStyle(AboutDialInk.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .aboutContentEntrance(context, group: .colophon, name: "versionValue")
                        .aboutMotionFrame("versionValue")
                    .aboutFrame("versionValue")
                    copyButton(context: context)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aboutFrame("versionCell")

            Rectangle()
                .fill(AboutDialInk.rule)
                .frame(width: 1)
                .aboutFrame("separator")

            VStack(alignment: .leading, spacing: 3) {
                Text("macOS")
                    .font(DotType.font(11, .medium))
                    .foregroundStyle(AboutDialInk.status)
                    .aboutContentEntrance(context, group: .colophon, name: "systemLabel")
                    .aboutMotionFrame("systemLabel")
                    .aboutFrame("systemLabel")
                Text(AboutInfo.operatingSystem)
                    .font(DotType.tabularFont(12, .medium))
                    .foregroundStyle(AboutDialInk.value)
                    .fixedSize(horizontal: false, vertical: true)
                    .aboutContentEntrance(context, group: .colophon, name: "systemValue")
                    .aboutMotionFrame("systemValue")
                    .aboutFrame("systemValue")
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aboutFrame("systemCell")
        }
        .frame(minHeight: 46, alignment: .center)
        .aboutFrame("lower")
    }

    private func copyButton(context: AboutMotionContext) -> some View {
        Button(action: copyVersion) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(DotType.font(11, .semibold))
                .foregroundStyle(copied ? AboutDialInk.value : AboutDialInk.status)
                .frame(width: 18, height: 18)
                .aboutContentEntrance(context, group: .colophon, name: "copy")
                .contentShape(Rectangle())
        }
        .buttonStyle(DotPressStyle())
        .focused($copyFocused)
        .accessibilityLabel("Copy version information")
        .accessibilityValue(copied ? "Copied" : "")
        .accessibilityHint("Copies the version, the build and the macOS version.")
        .aboutMotionFrame("copy")
        .aboutFrame("copy")
    }

    private func copyVersion() {
        finishEntrance()
        let line = AboutInfo.copyLine(
            version: version,
            build: build ?? AboutInfo.build,
            macOS: AboutInfo.operatingSystem
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(line, forType: .string)

        copied = true
        copyReset?.cancel()
        copyReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    // MARK: Update control

    /// The state the control draws: the preview's when one was supplied,
    /// otherwise what the last check found.
    private var currentUpdate: AboutUpdateState {
        previewUpdate ?? update
    }

    /// Runs the update button's own action in a headless host, where AppKit
    /// exposes no accessibility press target for a SwiftUI button.
    func activateUpdateForTesting() {
        performUpdate()
    }

    private func performUpdate() {
        finishEntrance()
        guard previewUpdate == nil else {
            onPreviewUpdatePress?()
            return
        }
        if case .available(_, let page) = currentUpdate {
            NSWorkspace.shared.open(page ?? ProductLinks.website)
            return
        }
        guard update != .checking else { return }
        statusDismissTask?.cancel()
        statusDismissTask = nil
        let start = now()
        update = .checking
        store?.beginCheck(at: start)
        Task { @MainActor in
            let result: AboutUpdateState
            if let updateCheck {
                result = await updateCheck()
            } else {
                switch await UpdateController.shared.check() {
                case .upToDate:
                    result = .upToDate
                case .newer(let version, let page):
                    result = .available(version: version, page: page)
                case .failed:
                    result = .unreachable
                }
            }
            let at = now()
            let fronts = store?.checkingElapsed(at: at)
            update = result
            let timeline: AboutUpdateTimeline
            switch result {
            case .idle:
                timeline = .idle
            case .checking:
                timeline = .checking(startedAt: at)
            case .upToDate:
                timeline = .upToDate(at: at, frontsElapsed: fronts)
            case .available:
                timeline = .available(at: at, frontsElapsed: fronts)
            case .unreachable:
                timeline = .unreachable(at: at, frontsElapsed: fronts)
            }
            store?.finishCheck(timeline)
            if result == .unreachable || result == .upToDate {
                statusDismissTask?.cancel()
                statusDismissTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    if update == .unreachable || update == .upToDate {
                        update = .idle
                    }
                }
            }
        }
    }

    // MARK: Destinations

    /// The five places Dot lives, inside an edge-to-edge card-clipped container.
    private func destinations(context: AboutMotionContext) -> some View {
        AboutFlushCard {
            VStack(spacing: 0) {
                linkRow(
                    "Website",
                    detail: ProductLinks.displayWebsite,
                    symbol: "globe",
                    url: ProductLinks.website,
                    index: 0,
                    context: context
                )
                SettingsDivider()
                    .padding(.horizontal, 16)
                linkRow(
                    "GitHub",
                    detail: ProductLinks.displayGitHub,
                    symbol: "chevron.left.forwardslash.chevron.right",
                    url: ProductLinks.github,
                    index: 1,
                    context: context
                )
                SettingsDivider()
                    .padding(.horizontal, 16)
                linkRow(
                    "Report an issue",
                    detail: ProductLinks.displayIssues,
                    symbol: "exclamationmark.bubble",
                    url: ProductLinks.newIssue,
                    index: 2,
                    context: context
                )
                SettingsDivider()
                    .padding(.horizontal, 16)
                linkRow(
                    "Support Dot",
                    detail: ProductLinks.displaySupport,
                    symbol: "cup.and.saucer",
                    url: ProductLinks.support,
                    index: 3,
                    context: context
                )
                SettingsDivider()
                    .padding(.horizontal, 16)
                linkRow(
                    "Licence",
                    detail: ProductLinks.licenceName,
                    symbol: "doc.text",
                    url: ProductLinks.licence,
                    index: 4,
                    context: context
                )
            }
        }
        .animation(
            windowPresent && context.sample == nil && context.clock == nil
                ? (reducesMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.86))
                : nil,
            value: activeRow
        )
    }

    /// A row that leaves Dot for the browser.
    private func linkRow(
        _ title: String,
        detail: String?,
        symbol: String,
        url: URL,
        index: Int,
        context: AboutMotionContext
    ) -> some View {
        Button {
            finishEntrance()
            NSWorkspace.shared.open(url)
        } label: {
            AboutRowFeedback(
                index: index,
                isActive: activeRow == index,
                context: context,
                reduceMotion: reducesMotion,
                highlightNamespace: destinationsHighlight,
                onEngaged: { engaged in probe?.rowEngaged?(index, engaged) }
            ) { values in
                SettingsRow(title, symbol: symbol) {
                    HStack(spacing: 8) {
                        if let detail {
                            Text(detail)
                                .font(DotType.font(11, .medium))
                                .foregroundStyle(DotTheme.ink2)
                                .lineLimit(1)
                        }
                        Image(systemName: "arrow.up.right")
                            .font(DotType.font(10, .semibold))
                            .foregroundStyle(DotTheme.ink3)
                            .offset(x: values.accentOffset.x, y: values.accentOffset.y)
                            .opacity(values.accentOpacity)
                            .animation(values.accentAnimation, value: values.engaged)
                    }
                }
            }
        }
        .buttonStyle(DotPressStyle())
        .focused($internalFocusedRow, equals: index)
        .onHover { inside in
            if DotScrollInteraction.isScrolling {
                if hoveredRow == index { hoveredRow = nil }
                return
            }
            if inside {
                hoveredRow = index
            } else {
                rowHoverEnded(index)
            }
        }
        .onContinuousHover { phase in
            guard !DotScrollInteraction.isScrolling else { return }
            handleRowHover(index, phase)
        }
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }

    // MARK: Actions inside Dot

    /// The two rows that act on Dot itself rather than on the network.
    private func actions(context: AboutMotionContext) -> some View {
        AboutFlushCard {
            VStack(spacing: 0) {
                actionRow(
                    "Show welcome tour",
                    symbol: "sparkles",
                    index: 5,
                    context: context,
                    action: onOpenWelcome
                )
                .buttonStyle(DotPressStyle())
                SettingsDivider()
                    .padding(.horizontal, 16)
                actionRow(
                    "Open log",
                    symbol: "doc.text.magnifyingglass",
                    index: 6,
                    context: context,
                    action: onOpenLog
                )
                .buttonStyle(DotPressStyle())
                .aboutFrame("openLog")
            }
        }
        .animation(
            windowPresent && context.sample == nil && context.clock == nil
                ? (reducesMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.86))
                : nil,
            value: activeRow
        )
        .aboutFrame("actions")
    }

    private func actionRow(
        _ title: String,
        symbol: String,
        index: Int,
        context: AboutMotionContext,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            finishEntrance()
            action()
        } label: {
            AboutRowFeedback(
                index: index,
                isActive: activeRow == index,
                context: context,
                reduceMotion: reducesMotion,
                highlightNamespace: actionsHighlight,
                onEngaged: { engaged in probe?.rowEngaged?(index, engaged) }
            ) { values in
                SettingsRow(title, symbol: symbol) {
                    Image(systemName: "chevron.right")
                        .font(DotType.font(10, .semibold))
                        .foregroundStyle(DotTheme.ink3)
                        .offset(x: values.accentOffset.x, y: values.accentOffset.y)
                        .opacity(values.accentOpacity)
                        .animation(values.accentAnimation, value: values.engaged)
                }
            }
        }
        .focused($internalFocusedRow, equals: index)
        .onHover { inside in
            if DotScrollInteraction.isScrolling {
                if hoveredRow == index { hoveredRow = nil }
                return
            }
            if inside {
                hoveredRow = index
            } else {
                rowHoverEnded(index)
            }
        }
        .onContinuousHover { phase in
            guard !DotScrollInteraction.isScrolling else { return }
            handleRowHover(index, phase)
        }
    }

    // MARK: Row feedback

    private struct AboutRowFeedbackValues {
        let index: Int
        let engaged: Bool
        let sample: AboutRowMotion?
        let reduceMotion: Bool

        var fillOpacity: Double {
            sample?.fillOpacity ?? (engaged ? AboutMotion.rowFillOpacity : 0)
        }

        var accentOffset: CGPoint {
            if let sample { return sample.accentOffset }
            guard engaged, !reduceMotion else { return .zero }
            return AboutMotion.accentOffset(forRow: index)
        }

        var accentAnimation: Animation? {
            guard sample == nil else { return nil }
            if reduceMotion { return .easeOut(duration: 0.12) }
            return engaged
                ? .spring(response: 0.22, dampingFraction: 0.88)
                : .spring(response: 0.28, dampingFraction: 0.92)
        }

        var accentOpacity: Double {
            reduceMotion ? (engaged ? 1 : 0.55) : 1
        }
    }

    private struct AboutUpdateCheckingRim: View {
        let reduceMotion: Bool
        let isStaticPreview: Bool
        @State private var startedAt = Date()

        var body: some View {
            if reduceMotion {
                rim(
                    head: HUDRewriteActivity.reducedMotionHeadDegrees,
                    trail: HUDRewriteActivity.reducedMotionTrailDegrees
                )
            } else if isStaticPreview {
                rim(head: 35, trail: 110)
            } else {
                TimelineView(.animation) { timeline in
                    let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                    let head = (elapsed * 290).truncatingRemainder(dividingBy: 360)
                    rim(head: head, trail: 110)
                }
            }
        }

        private func rim(head: Double, trail: Double) -> some View {
            RewriteArcRing(
                shape: Capsule(style: .circular),
                head: head,
                trail: trail,
                fade: 1,
                glowOpacity: 0.42,
                showsGlow: !reduceMotion,
                tint: AboutDialInk.value
            )
        }
    }

    private struct AboutFlushCard<Content: View>: View {
        @ViewBuilder var content: Content

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(DotTheme.cardFill))
                .clipShape(shape)
                .overlay(shape.strokeBorder(DotTheme.cardBorder, lineWidth: 1))
        }
    }

    private struct AboutRowFeedback<Content: View>: View {
        let index: Int
        let isActive: Bool
        let context: AboutMotionContext
        let reduceMotion: Bool
        let highlightNamespace: Namespace.ID
        let onEngaged: (Bool) -> Void
        @ViewBuilder let content: (AboutRowFeedbackValues) -> Content

        @State private var engaged = false

        var body: some View {
            Group {
                if let sample = context.sample {
                    row(AboutMotion.rowMotion(sample)[index], sampled: true)
                } else if let clock = context.clock, let time = context.time {
                    row(AboutMotion.rowMotion(clock.input(at: time))[index], sampled: true)
                } else if let entrance = context.entrance {
                    row(AboutMotion.rowMotion(entrance)[index], sampled: false)
                } else {
                    row(.settled, sampled: false)
                }
            }
            .onAppear {
                engaged = isActive
                onEngaged(engaged)
            }
            .onChange(of: isActive) { _, active in
                engaged = active
                onEngaged(engaged)
            }
        }

        private func row(_ motion: AboutRowMotion, sampled: Bool) -> some View {
            let values = AboutRowFeedbackValues(
                index: index,
                engaged: engaged,
                sample: sampled ? motion : nil,
                reduceMotion: reduceMotion
            )
            let indicatorStrength = sampled
                ? min(1, values.fillOpacity / max(AboutMotion.rowFillOpacity, 0.001))
                : (engaged ? 1 : 0)
            return ZStack {
                content(values)
                    .padding(.horizontal, 16)
                    .offset(y: motion.contentOffset.y)
                    .opacity(motion.contentOpacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if sampled {
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(DotTheme.ink.opacity(values.fillOpacity))
                        Capsule()
                            .fill(DotTheme.accent.opacity(0.75 * indicatorStrength))
                            .frame(width: 2.5, height: 18)
                            .padding(.leading, 4)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                } else if engaged {
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(DotTheme.ink.opacity(AboutMotion.rowFillOpacity))
                        Capsule()
                            .fill(DotTheme.accent.opacity(0.75))
                            .frame(width: 2.5, height: 18)
                            .padding(.leading, 4)
                    }
                    .matchedGeometryEffect(id: "activeRowHighlight", in: highlightNamespace)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: Rows, pointer and the one clock

    /// The row the arbitration engaged.
    private var activeRow: Int? {
        AboutRowArbiter.activeRow(
            lastInput: lastRowInput,
            hovered: hoveredRow,
            focused: focusedRowState
        )
    }

    /// The point a focused control answers at.
    private var focusTarget: AboutFocusTarget? {
        if controlFocused { return .update }
        if copyFocused { return .copy }
        return nil
    }

    /// The row's continuous hover, the one handler both row leaves call.
    ///
    /// A location change is the pointer moving; the row it lands on wins the
    /// arbitration. Leaving the row clears it and returns intent to a focused
    /// row, so a resting cursor cannot keep a keyboard focus from engaging.
    private func handleRowHover(_ row: Int, _ phase: HoverPhase) {
        switch phase {
        case .active(let point):
            if store?.lastHoverPoint != point {
                store?.lastHoverPoint = point
                if lastRowInput != .pointer { lastRowInput = .pointer }
            }
            if hoveredRow != row { hoveredRow = row }
        case .ended:
            rowHoverEnded(row)
        }
    }

    /// A late end from a row that is no longer hovered changes nothing: the
    /// pointer has already moved to another row, and that row keeps the intent.
    private func rowHoverEnded(_ row: Int) {
        guard hoveredRow == row else { return }
        hoveredRow = nil
        store?.lastHoverPoint = nil
        returnRowIntentToKeyboard()
        probe?.lastEndedIntent = lastRowInput
    }

    private var focusedRowValue: Int? {
        rowFocusValue ?? internalFocusedRow
    }

    /// A pointer that leaves the rows hands intent back to the keyboard. If
    /// no row is focused the arbiter then finds no row, which is the same
    /// result the pointer's empty hover would give.
    private func returnRowIntentToKeyboard() {
        if lastRowInput != .keyboard { lastRowInput = .keyboard }
    }

    /// The production keyboard handler, called by the focus state and by the
    /// control focus changes.
    private func handleKeyboardFocus(_ row: Int?) {
        if row != nil, lastRowInput != .keyboard { lastRowInput = .keyboard }
    }

    /// A pointer event writes the store and nothing on the page.
    ///
    /// A move captures the presented spring and retargets from there; an exit
    /// ramps the amplitude to zero; a re-entry during the fade ramps it back
    /// up from where it was. The page's body reads none of it.
    private func handlePointer(_ point: CGPoint?) {
        guard !reducesMotion else { return }
        let time = now()
        if let point {
            if lastRowInput != .pointer { lastRowInput = .pointer }
            store?.movePointer(point, at: time)
        } else {
            // The pointer left the plate: no row is hovered, and a focused row
            // takes the intent back.
            if hoveredRow != nil { hoveredRow = nil }
            store?.lastHoverPoint = nil
            returnRowIntentToKeyboard()
            store?.exitPointer(at: time)
        }
        probe?.pointerActive = store?.pointerIsActive ?? false
    }

    private func handlePlateClick(_ point: CGPoint) {
        guard !reducesMotion else { return }
        if let control = motionFrames["control"], control.insetBy(dx: -4, dy: -4).contains(point) {
            return
        }
        if let copy = motionFrames["copy"], copy.insetBy(dx: -4, dy: -4).contains(point) {
            return
        }
        finishEntrance()
        store?.emitRipple(at: point, at: now())
    }

    private func focusChanged(_ target: AboutFocusTarget?) {
        if target != nil { returnRowIntentToKeyboard() }
        store?.setFocus(target)
        probe?.pointerActive = store?.pointerIsActive ?? false
    }

    /// The window attached or detached.
    ///
    /// The callback carries the window itself, so a duplicate report from the
    /// same window changes nothing and a page moved to another window attaches
    /// again. Attaching only requests the entrance; the root's first evaluated
    /// frame stamps its epoch, so that frame is t = 0 and paints the start
    /// pose by construction.
    private func windowChanged(_ window: ObjectIdentifier?) {
        guard windowIdentity != window else { return }
        probe?.windowReports.append(window)
        let previous = windowIdentity
        windowIdentity = window
        probe?.windowIdentity = window
        if window != nil {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { windowPresent = true }
            probe?.windowPresent = true
            if store == nil { makeStore() }
            if previous != nil, previous != window {
                // A different owner is not a reattach: the old window's
                // pointer, entrance and loop stop before the new owner starts.
                store?.detach()
                detach()
            }
            if let store { attach(store) }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { windowPresent = false }
            probe?.windowPresent = false
            store?.detach()
            detach()
        }
    }

    private func makeStore() {
        let scheduler = wakeScheduler ?? AboutTimerWakeScheduler()
        let created = AboutMotionStore(now: now, scheduler: scheduler)
        let probe = self.probe
        probe?.store = created
        created.onPaused = { [weak probe] value in
            probe?.paused = value
        }
        created.onEntranceChanged = { [weak probe] startedAt, running in
            probe?.entranceStartedAt = startedAt
            probe?.entranceRunning = running
        }
        store = created
    }

    private func attach(_ store: AboutMotionStore) {
        store.setReduceMotion(reducesMotion)
        store.attach()
        installProbe()
        probe?.store = store
        probe?.pauseLoop = store.loop
        probe?.paused = store.paused
        probe?.entranceStartedAt = store.entranceStartedAt
        probe?.entranceRunning = store.entranceRunning
        probe?.pointerActive = store.pointerIsActive
    }

    /// The bridge or the page itself ended the attachment.
    ///
    /// Called synchronously when the page disappears and when the bridge is
    /// dismantled or leaves its window, before any posted report can be
    /// dropped with a released bridge. A second call is a no-op. A surviving
    /// bridge's delivery-time report still attaches the page to a new window.
    private func teardownWindow() {
        statusDismissTask?.cancel()
        statusDismissTask = nil
        windowIdentity = nil
        probe?.windowIdentity = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { windowPresent = false }
        probe?.windowPresent = false
        store?.detach()
        detach()
    }

    /// A detached host keeps no pointer and no live clock.
    private func detach() {
        hoveredRow = nil
        store?.lastHoverPoint = nil
        probe?.pointerActive = false
        clearProbe()
    }

    /// Installs the test-only callbacks on an injected probe. Production has
    /// no probe and installs nothing.
    private func installProbe() {
        guard let probe else { return }
        probe.updateText = currentUpdate.statusText
        probe.activeRow = activeRow
        focusedRowState = focusedRowValue
        probe.requestUpdate = { performUpdate() }
        probe.suppressWindowMoves = { suppress in
            suppressWindowMoveReports = suppress
        }
        probe.hoverRow = { row, phase in handleRowHover(row, phase) }
        probe.movePointer = { point in handlePointer(point) }
        probe.lastFocusedRow = focusedRowValue
    }

    private func finishEntrance() {
        store?.finishEntrance()
    }

    private func resetMotion() {
        store?.setReduceMotion(reducesMotion)
        probe?.pointerActive = false
    }

    private func clearProbe() {
        guard let probe else { return }
        probe.requestUpdate = nil
        probe.suppressWindowMoves = nil
        probe.hoverRow = nil
        probe.movePointer = nil
        probe.pauseLoop = nil
        probe.entrancePoses = [:]
        probe.store = nil
    }
}

/// One matrix leaf: dots, packet and disc, evaluated at a frame time.
///
/// This is the only view that runs the lattice on a clock. It is paused as
/// soon as every anchored effect has finished, including a pointer spring that
/// has settled; the store re-arms it on an event. While it runs, the
/// `TimelineView` evaluates the monotonic clock at each frame, not the display
/// link's wall-clock date. A sampled frame or a preview clock draws a supplied
/// input instead and starts no loop.
private struct AboutMatrixLeaf: View {
    let store: AboutMotionStore?
    let entranceTime: Double?
    let probe: AboutLiveProbe?
    let preview: AboutMotionInput?
    let previewClock: AboutMotionClock?
    let previewTime: Double?
    let frames: [String: CGRect]
    let now: @MainActor @Sendable () -> Double
    let onCanvasDraw: ((Double) -> Void)?

    var body: some View {
        Group {
            if let preview {
                canvas(input: preview)
            } else if let previewClock, let previewTime {
                canvas(input: previewClock.input(at: previewTime))
            } else if let entranceTime, let store {
                // The matrix alone derives the full frame at the plate's one
                // shared entrance timestamp. The root closure never reads the
                // pointer, update, focus or revision state for this frame, so
                // a move cannot invalidate the whole page.
                canvas(input: store.input(at: entranceTime))
            } else if let store {
                // Reading the revision makes a move, a result or a focus change
                // redraw this leaf even between display-link ticks.
                let _ = store.revision
                if store.paused {
                    // The terminal state at the current reading. After a
                    // genuine settle now is at or past the deadline; a clock
                    // changed while paused is drawn at its current time.
                    canvas(input: store.input(at: now()))
                } else {
                    running(store)
                }
            } else {
                canvas(input: AboutMotionInput())
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func running(_ store: AboutMotionStore) -> some View {
        // Reading the injected clock here subscribes a hosted test's clock
        // object to this view; production reads the system uptime, where the
        // TimelineView below is the tick.
        let _ = now()
        return TimelineView(.animation) { _ in
            canvas(input: store.input(at: now()))
        }
    }

    private func canvas(input: AboutMotionInput) -> some View {
        probe?.matrixSamples += 1
        let titleOffset = AboutMotion.contentMotion(input).title.offset.y
        if probe?.matrixTitleOffset != titleOffset {
            probe?.matrixTitleOffset = titleOffset
        }
        return Canvas { context, size in
            let start = CFAbsoluteTimeGetCurrent()
            let motion = AboutMotion.Matrix.motion(
                input: input,
                plateSize: size,
                knockoutFrames: frames
            )
            drawGrazingSheen(&context, size: size, input: input)
            drawDots(&context, motion: motion)
            drawPacket(&context, size: size, motion: motion)
            drawDisc(&context, size: size, input: input)
            onCanvasDraw?((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
    }

    private func drawGrazingSheen(
        _ context: inout GraphicsContext,
        size: CGSize,
        input: AboutMotionInput
    ) {
        guard !input.reduceMotion,
              let pointer = AboutMotion.resolvedPointer(input, plateSize: size),
              input.pointerAmplitude > 0.001
        else { return }
        let alpha = 0.065 * min(1, max(0, input.pointerAmplitude))
        let radius: CGFloat = 148
        let rect = CGRect(
            x: pointer.x - radius,
            y: pointer.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: AboutDialInk.value.opacity(alpha), location: 0.0),
                    .init(color: AboutDialInk.value.opacity(alpha * 0.38), location: 0.48),
                    .init(color: AboutDialInk.value.opacity(0), location: 1.0),
                ]),
                center: pointer,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    private func drawDots(_ context: inout GraphicsContext, motion: AboutMatrixMotion) {
        let bucketCount = 16
        var buckets = [Path](repeating: Path(), count: bucketCount)
        var hasBucket = [Bool](repeating: false, count: bucketCount)
        for dot in motion.dots {
            let energy = min(1, max(0, dot.energy))
            let bucket = min(bucketCount - 1, Int((energy * Double(bucketCount - 1)).rounded()))
            let diameter = AboutMotion.Matrix.dotDiameter
                + AboutMotion.Matrix.dotGrowth * energy
            let rect = CGRect(
                x: dot.x - diameter / 2,
                y: dot.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            buckets[bucket].addEllipse(in: rect)
            hasBucket[bucket] = true
        }
        for bucket in 0..<bucketCount where hasBucket[bucket] {
            let energy = Double(bucket) / Double(bucketCount - 1)
            context.fill(
                buckets[bucket],
                with: .color(
                    AboutDialInk.value.opacity(AboutMotion.Matrix.dotOpacity * energy)
                )
            )
        }
    }

    private func drawPacket(
        _ context: inout GraphicsContext,
        size: CGSize,
        motion: AboutMatrixMotion
    ) {
        guard motion.packetOpacity > 0.001, let status = frames["status"] else { return }
        let discMinX = size.width
            - AboutMotion.Plate.discCentreInset
            - AboutMotion.Plate.discDiameter / 2
        let centreX = (status.maxX + discMinX) / 2
        let centreY = status.midY
        let diameter = AboutMotion.Matrix.packetDotDiameter
        for column in 0..<AboutMotion.Matrix.packetColumns {
            for row in 0..<AboutMotion.Matrix.packetRows {
                let x = centreX + (CGFloat(column) - 0.5) * AboutMotion.Matrix.packetPitch
                let y = centreY + (CGFloat(row) - 1.5) * AboutMotion.Matrix.packetPitch
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: x - diameter / 2,
                        y: y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )),
                    with: .color(AboutDialInk.value.opacity(motion.packetOpacity))
                )
            }
        }
    }

    /// The sculpted porcelain resonator dome, drawn from the same offset as
    /// the lattice hole so the two stay locked together.
    private func drawDisc(
        _ context: inout GraphicsContext,
        size: CGSize,
        input: AboutMotionInput
    ) {
        let offset = AboutMotion.Matrix.discOffset(input)
        let centre = AboutMotion.Plate.discCentre(plateSize: size)
        let movedCentre = CGPoint(x: centre.x + offset.x, y: centre.y + offset.y)
        let radius = AboutMotion.Plate.discDiameter / 2
        let rect = CGRect(
            x: movedCentre.x - radius,
            y: movedCentre.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let highlightCentre: CGPoint
        if !input.reduceMotion, let pointer = AboutMotion.resolvedPointer(input, plateSize: size) {
            let dx = pointer.x - movedCentre.x
            let dy = pointer.y - movedCentre.y
            let dist = max(1, hypot(dx, dy))
            let shift = min(5.5, dist * 0.04)
            highlightCentre = CGPoint(
                x: movedCentre.x + (dx / dist) * shift,
                y: movedCentre.y + (dy / dist) * shift
            )
        } else {
            highlightCentre = CGPoint(x: movedCentre.x - 4.5, y: movedCentre.y - 4.5)
        }
        let shape = Path(ellipseIn: rect)
        context.fill(
            shape,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(.sRGB, red: 0.968, green: 0.960, blue: 0.945), location: 0.0),
                    .init(color: AboutDialInk.disc, location: 0.45),
                    .init(color: AboutDialInk.disc, location: 0.85),
                    .init(color: Color(.sRGB, red: 0.949, green: 0.941, blue: 0.925), location: 1.0),
                ]),
                center: highlightCentre,
                startRadius: 0,
                endRadius: radius * 1.15
            )
        )
        context.stroke(
            shape,
            with: .color(AboutDialInk.edge.opacity(0.10)),
            lineWidth: 0.75
        )
    }
}

/// The gap that keeps the entrance from replaying on a quick tab round trip.
@MainActor
enum AboutEntranceGate {
    static let minimumGap: Double = 1200
    static var lastStartedAt: Double?
}

// MARK: - Motion settle

/// The inputs every animated leaf reads: the one store, a sampled frame, or a
/// preview clock evaluated at a supplied time, plus the monotonic reader.
private struct AboutMotionContext {
    let store: AboutMotionStore?
    let sample: AboutMotionInput?
    let clock: AboutMotionClock?
    let time: Double?
    let now: @MainActor @Sendable () -> Double
    let probe: AboutLiveProbe?
    /// The entrance-only sample the plate shared with every animated leaf in
    /// the current frame. `nil` outside the entrance.
    var entrance: AboutMotionInput? = nil
    /// The one timestamp the entrance frame sampled. The matrix alone derives
    /// its full input at this time; the root never reads pointer, update,
    /// focus or revision state. `nil` outside the entrance.
    var entranceTime: Double? = nil
}

/// The plate's one entrance clock.
///
/// While the store says the entrance is running this view owns the only
/// `TimelineView` on the page. It reads the monotonic clock once per frame and
/// builds the entrance-only snapshot for content groups and rows. It passes
/// the same timestamp to the matrix leaf, which derives the full frame there,
/// so text and knockouts cannot be a frame apart and a pointer move cannot
/// invalidate the root.
///
/// The schedule pauses when the entrance settles rather than replacing this
/// view with the bare content. A branch swap would tear down and rebuild the
/// whole page subtree at the settle, losing the tracking view, the focused row
/// and every row's state. A paused `TimelineView` ticks nothing; content and
/// rows are static, and the matrix leaf's own `TimelineView` takes over for
/// pointer and update effects.
private struct AboutPageMotionRoot<Content: View>: View {
    let context: AboutMotionContext
    let content: (AboutMotionContext) -> Content

    var body: some View {
        if let store = context.store, context.sample == nil, context.clock == nil {
            live(store)
        } else {
            content(context)
        }
    }

    private func live(_ store: AboutMotionStore) -> some View {
        let running = store.entranceRunning
        if running {
            // An injected observable clock drives this body in a hosted test;
            // on a display the TimelineView below is the tick.
            let _ = context.now()
        }
        let frozen = context.probe?.freezeRootClock ?? false
        return TimelineView(
            .animation(paused: !running || frozen)
        ) { _ in
            content(running ? sampled(store, at: context.now()) : context)
        }
    }

    private func sampled(_ store: AboutMotionStore, at time: Double) -> AboutMotionContext {
        context.probe?.rootSamples += 1
        // The first sampled frame is the entrance's t = 0. Attaching only
        // requested the entrance; this read is what starts its clock.
        store.stampEntrance(at: time)
        var frame = context
        frame.entrance = store.entranceInput(at: time)
        frame.entranceTime = time
        return frame
    }
}

/// Which of the three shared content groups a view belongs to.
private enum AboutContentGroup {
    case title
    case update
    case colophon

    func motion(in input: AboutMotionInput) -> AboutContentMotion {
        let content = AboutMotion.contentMotion(input)
        switch self {
        case .title: return content.title
        case .update: return content.update
        case .colophon: return content.colophon
        }
    }
}

/// Puts a content group at its entrance offset and opacity without moving its
/// laid-out frame.
///
/// The offset is a render transform, so the frame readers keep reporting the
/// settled plate while the pixels travel. That is what lets a moving page and
/// a fixed layout be checked against the same numbers.
///
/// Live, the group consumes the plate's one entrance sample; it starts no
/// timeline of its own and reads no pointer, update or focus state. Once the
/// entrance settles it is a plain static view. A sampled frame or a preview
/// clock draws a supplied input and starts no timeline. The pose is also
/// reported as a preference, so a hosted test can read what the first
/// committed frame actually draws.
private struct AboutContentEntrance<Content: View>: View {
    let context: AboutMotionContext
    let group: AboutContentGroup
    let name: String
    let content: Content

    var body: some View {
        Group {
            if let entrance = context.entrance {
                posed(group.motion(in: entrance))
            } else if let clock = context.clock, let time = context.time {
                posed(group.motion(in: clock.input(at: time)))
            } else if let sample = context.sample {
                posed(group.motion(in: sample))
            } else {
                posed(.settled)
            }
        }
    }

    private func posed(_ motion: AboutContentMotion) -> some View {
        content
            .offset(y: motion.offset.y)
            .opacity(motion.opacity)
            .preference(
                key: AboutEntrancePoseKey.self,
                value: [
                    name: AboutEntrancePose(
                        offsetY: motion.offset.y,
                        opacity: motion.opacity
                    )
                ]
            )
    }
}

private extension View {
    func aboutContentEntrance(
        _ context: AboutMotionContext,
        group: AboutContentGroup,
        name: String
    ) -> some View {
        AboutContentEntrance(context: context, group: group, name: name, content: self)
    }
}

/// The presented entrance pose of every group.
private struct AboutEntrancePoseKey: PreferenceKey {
    static var defaultValue: [String: AboutEntrancePose] { [:] }

    static func reduce(
        value: inout [String: AboutEntrancePose],
        nextValue: () -> [String: AboutEntrancePose]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Matrix knockouts

private struct AboutMotionFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct AboutMotionReportingKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var aboutMotionReporting: Bool {
        get { self[AboutMotionReportingKey.self] }
        set { self[AboutMotionReportingKey.self] = newValue }
    }
}

private struct AboutMotionFrameReporter: ViewModifier {
    @Environment(\.aboutMotionReporting) private var reports
    let name: String

    func body(content: Content) -> some View {
        content.background {
            if reports {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: AboutMotionFrameKey.self,
                        value: [name: geometry.frame(in: .named(AboutPage.plateSpace))]
                    )
                }
            }
        }
    }
}

private extension View {
    func aboutMotionFrame(_ name: String) -> some View {
        modifier(AboutMotionFrameReporter(name: name))
    }
}

// MARK: - Window presence

/// Reports which window the page is mounted in, and watches its input.
///
/// An offscreen host has no window, and nothing there should start a clock: the
/// entrance belongs to the moment the page appears to someone. The window's
/// identity, not a captured boolean, is what the page compares: a duplicate
/// report from the same window changes nothing, and a page moved to another
/// window attaches to that one. The same view watches key downs and presses
/// inside the page so either can finish the entrance without waiting for it.
struct AboutHostWindow: NSViewRepresentable {
    let onChange: @MainActor (ObjectIdentifier?) -> Void
    let onTeardown: @MainActor () -> Void
    let reportsWindowMoves: Bool
    let windowQuery: Int
    let onKeyDown: @MainActor () -> Void
    let onPress: @MainActor () -> Void

    func makeNSView(context: Context) -> PresenceView {
        let view = PresenceView()
        view.onChange = onChange
        view.onTeardown = onTeardown
        view.reportsWindowMoves = reportsWindowMoves
        view.onKeyDown = onKeyDown
        view.onPress = onPress
        return view
    }

    func updateNSView(_ nsView: PresenceView, context: Context) {
        nsView.onChange = onChange
        nsView.onTeardown = onTeardown
        nsView.reportsWindowMoves = reportsWindowMoves
        nsView.onKeyDown = onKeyDown
        nsView.onPress = onPress
        if nsView.lastWindowQuery != windowQuery {
            nsView.lastWindowQuery = windowQuery
            // A page can disappear and reappear while this bridge stays in the
            // same window. SwiftUI then updates the representable without moving
            // it, so report the current owner for the page to restore.
            nsView.reportCurrentWindow()
        }
    }

    static func dismantleNSView(_ nsView: PresenceView, coordinator: ()) {
        nsView.dismantle()
    }

    @MainActor
    final class PresenceView: NSView {
        var onChange: (@MainActor (ObjectIdentifier?) -> Void)?
        var onTeardown: (@MainActor () -> Void)?
        var reportsWindowMoves = true
        var onKeyDown: (@MainActor () -> Void)?
        var onPress: (@MainActor () -> Void)?
        var lastWindowQuery: Int?
        private var keyMonitor: Any?
        private var pressMonitor: Any?
        private var dismantled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !dismantled else { return }
            // Revalidate the owner and the callback at delivery. A report
            // queued before a dismantle must not attach a store to a page that
            // is already gone, and an updated callback is the one that owns
            // the page now.
            if reportsWindowMoves {
                Task { @MainActor [weak self] in
                    guard let self, !self.dismantled else { return }
                    self.onChange?(self.window.map(ObjectIdentifier.init))
                }
            }
            installMonitors()
        }

        /// Reports the window this bridge currently occupies. Called when
        /// SwiftUI updates the representable, including a page reappearance
        /// that leaves the bridge in place.
        func reportCurrentWindow() {
            guard !dismantled else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.dismantled else { return }
                self.onChange?(self.window.map(ObjectIdentifier.init))
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                // Synchronous owner signal. A page removal can release this
                // view before its posted report runs, so the page must detach
                // now; a move to another window reports again at delivery.
                onTeardown?()
                stop()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        /// Called by SwiftUI when the representable is removed for good.
        func dismantle() {
            guard !dismantled else { return }
            dismantled = true
            onTeardown?()
            onChange = nil
            onTeardown = nil
            onKeyDown = nil
            onPress = nil
            stop()
        }

        func stop() {
            for monitor in [keyMonitor, pressMonitor] {
                if let monitor { NSEvent.removeMonitor(monitor) }
            }
            keyMonitor = nil
            pressMonitor = nil
        }

        private func installMonitors() {
            stop()
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let number = event.windowNumber
                MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          window.windowNumber == number
                    else { return }
                    self.onKeyDown?()
                }
                return event
            }
            pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let number = event.windowNumber
                let point = event.locationInWindow
                MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          window.windowNumber == number,
                          self.bounds.contains(self.convert(point, from: nil))
                    else { return }
                    self.onPress?()
                }
                return event
            }
        }
    }
}

/// The plate's fixed colours, sampled from the approved composition.
///
/// These are fixed rather than adaptive: the dial is a picture of the app icon
/// and does not change with the system appearance.
enum AboutDialInk {
    static let plate = Color(.sRGB, red: 0x24 / 255, green: 0x21 / 255, blue: 0x1E / 255)
    static let edge = Color(.sRGB, red: 0x62 / 255, green: 0x57 / 255, blue: 0x4D / 255)
    /// The same edge, softened for the two rules drawn inside the plate.
    static let rule = edge.opacity(0.45)
    static let disc = Color(.sRGB, red: 0xF4 / 255, green: 0xF2 / 255, blue: 0xEE / 255)
    static let value = Color(.sRGB, red: 0xFF / 255, green: 0xF4 / 255, blue: 0xE6 / 255)
    static let status = Color(.sRGB, red: 0xD8 / 255, green: 0xCA / 255, blue: 0xBC / 255)
    static let buttonEdge = Color(.sRGB, red: 0x9D / 255, green: 0x8C / 255, blue: 0x7D / 255)
}
