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

    /// The build as the page writes it after the version.
    static func versionLine(version: String, build: String?) -> String {
        "Version \(valueLine(version: version, build: build))"
    }

    /// The colophon's value: the version alone when there is no build to name.
    static func valueLine(version: String, build: String?) -> String {
        guard let build, !build.isEmpty, build != ProductVersion.unknown else {
            return version
        }
        return "\(version) (\(build))"
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
        case .idle: "Not checked"
        case .checking: "Checking..."
        case .upToDate: "Up to date"
        case .available(let version, _): "Version \(version) available"
        case .unreachable: "Could not reach GitHub"
        }
    }

    /// A check already in flight owns the control until it answers.
    var acceptsAnotherCheck: Bool { self != .checking }
}

/// The decorative response of the mark in the plate's top-right corner.
///
/// The mark is a picture, not a control: it answers the pointer only while the
/// pointer is inside its own corner of the plate, and that answer is bounded to
/// a few points of offset. The target is a pure value so its limits, its rest
/// position and its reduced-motion answer can be checked without moving a
/// system pointer.
enum AboutMarkMotion {
    /// The largest horizontal travel, in points.
    static let horizontalLimit: CGFloat = 6
    /// The largest vertical travel, in points.
    static let verticalLimit: CGFloat = 4
    /// The spring used while the pointer is tracked.
    static let engagedResponse: Double = 0.24
    static let engagedDamping: Double = 0.82
    /// The spring used when the pointer leaves or the window resigns.
    static let returnResponse: Double = 0.28
    static let returnDamping: Double = 0.86

    /// Maps a normalized point in the mark's own region to a disc offset.
    ///
    /// - Parameters:
    ///   - x: minus one at the region's left edge, one at its right edge.
    ///   - y: minus one at the region's top edge, one at its bottom edge.
    ///   - reduceMotion: whether the person asked for stillness.
    /// - Returns: the disc's offset from its printed position, or zero.
    static func target(x: CGFloat, y: CGFloat, reduceMotion: Bool) -> CGPoint {
        guard !reduceMotion else { return .zero }
        let boundedX = min(max(x, -1), 1)
        let boundedY = min(max(y, -1), 1)
        return CGPoint(x: boundedX * horizontalLimit, y: boundedY * verticalLimit)
    }

    /// The spring that carries the disc to a target.
    ///
    /// A new target retargets the same spring, so an interruption carries the
    /// current velocity instead of restarting from rest. Reduced motion gets
    /// no spring at all; the disc stays where it was printed.
    static func animation(returning: Bool, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return returning
            ? .spring(response: returnResponse, dampingFraction: returnDamping)
            : .spring(response: engagedResponse, dampingFraction: engagedDamping)
    }
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

/// A transparent view that reports the pointer inside the mark's own corner.
///
/// It installs only a key-window tracking area and never becomes a hit target.
/// The point it reports is local to this view and normalized to minus one
/// through one on each axis. When motion is reduced the coordinator removes the
/// area, so no pointer event can reach the mark.
struct AboutMarkPointerRegion: NSViewRepresentable {
    let enabled: Bool
    let onMove: (CGPoint?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMove: onMove) }

    func makeNSView(context: Context) -> AboutMarkTrackingView {
        let view = AboutMarkTrackingView()
        view.wantsLayer = false
        return view
    }

    func updateNSView(_ nsView: AboutMarkTrackingView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.setEnabled(enabled, in: nsView)
    }

    static func dismantleNSView(_ nsView: AboutMarkTrackingView, coordinator: Coordinator) {
        coordinator.stop(in: nsView)
    }

    @MainActor
    final class Coordinator {
        var onMove: (CGPoint?) -> Void
        private var area: NSTrackingArea?
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(onMove: @escaping (CGPoint?) -> Void) {
            self.onMove = onMove
        }

        func setEnabled(_ enabled: Bool, in view: AboutMarkTrackingView) {
            guard enabled else {
                stop(in: view)
                return
            }
            view.onMove = { [weak self] point in self?.onMove(point) }
            view.onWindowChange = { [weak self] window in self?.watch(window) }
            install(in: view)
            watch(view.window)
        }

        func stop(in view: AboutMarkTrackingView) {
            remove(from: view)
            watch(nil)
        }

        private func install(in view: AboutMarkTrackingView) {
            guard area == nil else { return }
            let area = NSTrackingArea(
                rect: view.bounds,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: view,
                userInfo: ["AboutMarkPointerRegion": true]
            )
            self.area = area
            view.addTrackingArea(area)
        }

        func watch(_ window: NSWindow?) {
            guard self.window !== window else { return }
            clearObservers()
            self.window = window
            guard let window else { return }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reset() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reset() }
            })
        }

        private func clearObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        func reset() { onMove(nil) }

        private func remove(from view: AboutMarkTrackingView) {
            if let area { view.removeTrackingArea(area) }
            area = nil
            view.onMove = nil
            view.onWindowChange = nil
        }
    }
}

/// The tracking view's one job is to turn an AppKit mouse event into a local
/// normalized point. It never draws, never becomes first responder and never
/// answers a click with an action of its own.
final class AboutMarkTrackingView: NSView {
    var onMove: ((CGPoint?) -> Void)?
    var onWindowChange: ((NSWindow?) -> Void)?
    var isActiveProvider: () -> Bool = { NSApp.isActive }
    lazy var isKeyWindowProvider: () -> Bool = { [weak self] in self?.window?.isKeyWindow ?? false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onMove?(nil) }

    private func report(_ event: NSEvent) {
        guard isActiveProvider(), isKeyWindowProvider() else {
            onMove?(nil)
            return
        }
        let point = window == nil ? event.locationInWindow : convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        onMove?(
            CGPoint(
                x: (point.x / bounds.width) * 2 - 1,
                y: 1 - (point.y / bounds.height) * 2
            )
        )
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
    /// The mark's target for an offscreen frame sample. A live page reads the
    /// pointer; a render drives the same target on one mounted host.
    var previewMarkTarget: Binding<CGPoint>?
    /// Holds the control's highlight for an offscreen disabled-state sample.
    var previewControlHighlighted: Bool?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var controlFocused: Bool
    @State private var copied = false
    @State private var update: AboutUpdateState = .idle
    @State private var copyReset: Task<Void, Never>?
    @State private var controlHovered = false
    @State private var markTarget = CGPoint.zero

    /// The coordinate space every reported frame is measured in.
    static let layoutSpace = "AboutPage.content"
    /// The mark is drawn from the approved icon geometry on an imaginary 100 pt
    /// square pinned to the plate's top right corner.
    private static let markSquare: CGFloat = 100
    private static let markDiameter: CGFloat = markSquare * DotMarkDial.clipped.diameter
    private static let markRightInset: CGFloat = markSquare * (1 - DotMarkDial.clipped.centre.x)
    private static let markTopInset: CGFloat = markSquare * DotMarkDial.clipped.centre.y
    /// The trailing room the control leaves for the cropped disc.
    private static let markReserve: CGFloat = 72
    /// The tracking corner is the reserved disc square, narrow enough to stay
    /// clear of the update column and the status line.
    private static let markTrackingSide: CGFloat = 72
    /// The status reserve is exactly two lines at the face and size it draws.
    private static let updateStatusLineHeight: CGFloat = {
        let font = DotType.nsFont(11, .medium)
        return ceil(font.ascender - font.descender + font.leading)
    }()
    private static let statusReserveHeight: CGFloat = updateStatusLineHeight * 2

    private var reducesMotion: Bool {
        systemReduceMotion || DotMotion.reducesMotion
    }

    /// The disc's drawn offset. An offscreen sample supplies a target directly;
    /// the live page uses the last local pointer position.
    private var markOffset: CGPoint {
        let target = previewMarkTarget?.wrappedValue ?? markTarget
        return AboutMarkMotion.target(
            x: target.x,
            y: target.y,
            reduceMotion: reducesMotion
        )
    }

    private var markAnimation: Animation? {
        AboutMarkMotion.animation(
            returning: markOffset == .zero,
            reduceMotion: reducesMotion
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            plate
            destinations
            actions
        }
        .frame(maxWidth: .infinity)
        .environment(\.aboutLayoutReporting, onLayout != nil)
        .coordinateSpace(name: Self.layoutSpace)
        .onPreferenceChange(AboutFrameKey.self) { frames in
            onLayout?(AboutLayoutSnapshot(frames: frames))
        }
        .onChange(of: reducesMotion) { markTarget = .zero }
    }

    // MARK: Dial plate

    /// The matte plate carries the name, the update control and the colophon.
    ///
    /// The disc is one drawing inside the plate's single clip. Nothing else on
    /// the page draws a mark, a shadow or a second edge.
    private var plate: some View {
        VStack(spacing: 0) {
            upperBand
            Rectangle()
                .fill(AboutDialInk.rule)
                .frame(height: 1)
                .aboutFrame("rule")
            colophon
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                .fill(AboutDialInk.plate)
        )
        .overlay(alignment: .topLeading) {
            mark
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                .strokeBorder(AboutDialInk.edge, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            markPointerRegion
        }
        .aboutFrame("plate")
    }

    /// The white disc, cut by the plate and kept out of hit testing and the
    /// accessibility tree.
    private var mark: some View {
        GeometryReader { geometry in
            ZStack {
                if onLayout != nil {
                    Color.clear
                        .preference(
                            key: AboutFrameKey.self,
                            value: ["disc": discFrame(in: geometry)]
                        )
                }
                Circle()
                    .fill(AboutDialInk.disc)
                    .frame(width: Self.markDiameter, height: Self.markDiameter)
                    .position(
                        x: geometry.size.width - Self.markRightInset,
                        y: Self.markTopInset
                    )
                    .offset(x: markOffset.x, y: markOffset.y)
                    .animation(markAnimation, value: markOffset)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The local tracking corner. It is transparent, outside the update
    /// column, and invisible to the accessibility tree.
    private var markPointerRegion: some View {
        AboutMarkPointerRegion(enabled: !reducesMotion) { point in
            markTarget = point ?? .zero
        }
        .frame(width: Self.markTrackingSide, height: Self.markTrackingSide)
        .aboutFrame("markRegion")
        .allowsHitTesting(true)
        .accessibilityHidden(true)
    }

    private func discFrame(in geometry: GeometryProxy) -> CGRect {
        let plate = geometry.frame(in: .named(Self.layoutSpace))
        return CGRect(
            x: plate.minX + geometry.size.width - Self.markRightInset - Self.markDiameter / 2,
            y: plate.minY + Self.markTopInset - Self.markDiameter / 2,
            width: Self.markDiameter,
            height: Self.markDiameter
        )
        .offsetBy(dx: markOffset.x, dy: markOffset.y)
    }

    private var upperBand: some View {
        let controlCanHighlight = currentUpdate.acceptsAnotherCheck && (controlHovered || controlFocused)
        let fillHighlighted = currentUpdate.acceptsAnotherCheck
            && (previewControlHighlighted ?? controlCanHighlight)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Dot")
                    .font(DotTheme.displayFont(30))
                    .tracking(-0.4)
                    .foregroundStyle(AboutDialInk.value)
                    .accessibilityAddTraits(.isHeader)
                    .aboutFrame("title")

                Text(ProductLinks.tagline)
                    .font(DotType.font(12, .medium))
                    .foregroundStyle(AboutDialInk.status)
                    .fixedSize(horizontal: true, vertical: true)
                    .aboutFrame("tagline")
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 2) {
                Button(action: performUpdate) {
                    Text(currentUpdate.controlLabel)
                        .font(DotType.font(12, .semibold))
                        .foregroundStyle(
                            currentUpdate.acceptsAnotherCheck ? AboutDialInk.value : AboutDialInk.status
                        )
                        .frame(width: 132, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AboutDialInk.value.opacity(
                                    AboutControlFill.opacity(
                                        isHighlighted: fillHighlighted
                                    )
                                ))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    AboutDialInk.buttonEdge.opacity(currentUpdate.acceptsAnotherCheck ? 1 : 0.5),
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(DotPressStyle())
                .disabled(!currentUpdate.acceptsAnotherCheck)
                .focused($controlFocused)
                .onHover { controlHovered = $0 }
                .onChange(of: currentUpdate.acceptsAnotherCheck) { _, accepts in
                    if !accepts { controlHovered = false }
                }
                .accessibilityLabel(currentUpdate.controlLabel)
                .accessibilityValue(currentUpdate.statusText)
                .aboutFrame("control")

                Text(currentUpdate.statusText)
                    .font(DotType.font(11, .medium))
                    .foregroundStyle(AboutDialInk.status)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .accessibilityHidden(true)
                    .frame(width: 200, height: Self.statusReserveHeight, alignment: .topTrailing)
                    .aboutFrame("status")
            }
            .padding(.trailing, Self.markReserve)
        }
        .frame(minHeight: 72, alignment: .center)
        .padding(.horizontal, 16)
        .aboutFrame("upper")
    }

    private var colophon: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Version")
                    .font(DotType.font(11, .medium))
                    .foregroundStyle(AboutDialInk.status)
                    .aboutFrame("versionLabel")
                HStack(spacing: 6) {
                    Text(AboutInfo.valueLine(version: version, build: build))
                        .font(DotType.tabularFont(12, .medium))
                        .foregroundStyle(AboutDialInk.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .aboutFrame("versionValue")
                    copyButton
                }
            }
            .padding(.vertical, 5)
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
                    .aboutFrame("systemLabel")
                Text(AboutInfo.operatingSystem)
                    .font(DotType.tabularFont(12, .medium))
                    .foregroundStyle(AboutDialInk.value)
                    .fixedSize(horizontal: false, vertical: true)
                    .aboutFrame("systemValue")
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aboutFrame("systemCell")
        }
        .frame(minHeight: 44, alignment: .center)
        .aboutFrame("lower")
    }

    private var copyButton: some View {
        Button(action: copyVersion) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(DotType.font(11, .semibold))
                .foregroundStyle(copied ? AboutDialInk.value : AboutDialInk.status)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(DotPressStyle())
        .accessibilityLabel("Copy version information")
        .accessibilityValue(copied ? "Copied" : "")
        .help("Copies the version, the build and the macOS version.")
        .aboutFrame("copy")
    }

    private func copyVersion() {
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
        guard previewUpdate == nil else {
            onPreviewUpdatePress?()
            return
        }
        if case .available(_, let page) = currentUpdate {
            NSWorkspace.shared.open(page ?? ProductLinks.website)
            return
        }
        guard currentUpdate != .checking else { return }
        update = .checking
        Task { @MainActor in
            let result = await UpdateController.shared.check()
            switch result {
            case .upToDate:
                update = .upToDate
            case .newer(let version, let page):
                update = .available(version: version, page: page)
            case .failed:
                update = .unreachable
            }
        }
    }

    // MARK: Destinations

    /// The five places Dot lives, unchanged from the settings card rhythm.
    private var destinations: some View {
        DotCard {
            VStack(spacing: 0) {
                linkRow(
                    "Website",
                    detail: ProductLinks.displayWebsite,
                    symbol: "globe",
                    url: ProductLinks.website
                )
                SettingsDivider()
                linkRow(
                    "GitHub",
                    detail: ProductLinks.displayGitHub,
                    symbol: "chevron.left.forwardslash.chevron.right",
                    url: ProductLinks.github
                )
                SettingsDivider()
                linkRow(
                    "Report an issue",
                    detail: ProductLinks.displayIssues,
                    symbol: "exclamationmark.bubble",
                    url: ProductLinks.newIssue
                )
                SettingsDivider()
                linkRow(
                    "Support Dot",
                    detail: ProductLinks.displaySupport,
                    symbol: "cup.and.saucer",
                    url: ProductLinks.support
                )
                SettingsDivider()
                linkRow(
                    "Licence",
                    detail: ProductLinks.licenceName,
                    symbol: "doc.text",
                    url: ProductLinks.licence
                )
            }
        }
    }

    /// A row that leaves Dot for the browser.
    private func linkRow(_ title: String, detail: String?, symbol: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
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
                }
            }
        }
        .buttonStyle(DotPressStyle())
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }

    // MARK: Actions inside Dot

    /// The two rows that act on Dot itself rather than on the network.
    private var actions: some View {
        DotCard {
            VStack(spacing: 0) {
                Button(action: onOpenWelcome) {
                    SettingsRow("Show welcome tour", symbol: "sparkles") {
                        Image(systemName: "chevron.right")
                            .font(DotType.font(10, .semibold))
                            .foregroundStyle(DotTheme.ink3)
                    }
                }
                .buttonStyle(DotPressStyle())
                SettingsDivider()
                Button(action: onOpenLog) {
                    SettingsRow("Open log", symbol: "doc.text.magnifyingglass") {
                        Image(systemName: "chevron.right")
                            .font(DotType.font(10, .semibold))
                            .foregroundStyle(DotTheme.ink3)
                    }
                }
                .buttonStyle(DotPressStyle())
                .aboutFrame("openLog")
            }
        }
        .aboutFrame("actions")
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
