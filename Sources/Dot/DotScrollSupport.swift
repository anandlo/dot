import AppKit
import DotCore
import os
import QuartzCore
import SwiftUI

/// Lightweight scroll-state coordinator shared across Settings, History, and Palette.
///
/// Tracks active live trackpad/mouse scroll sessions without using `ObservableObject`
/// so hover handlers and secondary animations (like Appearance swatches) pause
/// cleanly during scrolling without invalidating SwiftUI view trees.
@MainActor
enum DotScrollInteraction {
    static let cooldownDuration: CFTimeInterval = 0.09
    private static var activeScrollCount = 0
    private static var cooldownUntil: CFTimeInterval = 0
    private static var observers: [UUID: (Bool) -> Void] = [:]

    /// Returns `true` while any monitored scroll view is actively scrolling or
    /// within the short settle cooldown immediately after momentum ends.
    static var isScrolling: Bool {
        activeScrollCount > 0 || CACurrentMediaTime() < cooldownUntil
    }

    static var isLiveScrolling: Bool {
        activeScrollCount > 0
    }

    static func beginLiveScroll() {
        activeScrollCount += 1
        cooldownUntil = 0
        if activeScrollCount == 1 {
            notifyObservers(true)
        }
    }

    static func endLiveScroll() {
        guard activeScrollCount > 0 else { return }
        activeScrollCount -= 1
        if activeScrollCount == 0 {
            cooldownUntil = CACurrentMediaTime() + cooldownDuration
            notifyObservers(false)
        }
    }

    @discardableResult
    static func addObserver(_ handler: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    static func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private static func notifyObservers(_ scrolling: Bool) {
        for handler in observers.values {
            handler(scrolling)
        }
    }

    #if DEBUG
    static func debugReset() {
        activeScrollCount = 0
        cooldownUntil = 0
        observers.removeAll()
    }
    #endif
}

/// One live scroll's travel past each edge and its update pacing, written as
/// a `scroll.gesture` line when the scroll ends.
///
/// The overscroll extents say whether the elastic band moved at an edge at all;
/// the largest gap between offset updates says whether it moved in steps.
/// Missed display frames are counted separately by `FrameDropMonitor`.
struct ScrollGestureTrace {
    let surface: String
    let started: CFTimeInterval
    private(set) var updates = 0
    private(set) var topOverscroll: CGFloat = 0
    private(set) var bottomOverscroll: CGFloat = 0
    private(set) var maxBoundsGapMS: Double = 0
    private var last: CFTimeInterval

    init(surface: String, now: CFTimeInterval) {
        self.surface = surface
        started = now
        last = now
    }

    mutating func record(originY: CGFloat, maxY: CGFloat, now: CFTimeInterval) {
        updates += 1
        topOverscroll = max(topOverscroll, -originY)
        bottomOverscroll = max(bottomOverscroll, originY - maxY)
        if updates > 1 {
            maxBoundsGapMS = max(maxBoundsGapMS, (now - last) * 1000)
        }
        last = now
    }

    func fields(now: CFTimeInterval, elastic: Bool) -> [String: LogValue] {
        [
            "surface": .string(surface),
            "ms": .double(((now - started) * 1000).rounded()),
            "updates": .int(updates),
            "top_overscroll": .double(Double((topOverscroll * 10).rounded() / 10)),
            "bottom_overscroll": .double(Double((bottomOverscroll * 10).rounded() / 10)),
            "max_bounds_gap_ms": .double((maxBoundsGapMS * 10).rounded() / 10),
            "elastic": .bool(elastic),
        ]
    }
}

/// Top-left flipped clip view so AppKit scroll origins start at `y = 0` at the top.
final class DotFlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Pure AppKit scroll view for Settings pages.
///
/// Replaces SwiftUI's `HostingScrollView`, whose bounce behaviour cannot be set
/// reliably (macOS 27.2.1 `.scrollBounceBehavior(.basedOnSize)` toggles it by
/// size). Elasticity is held at `.none` on both axes: a page stops at its first
/// and last line instead of pulling past them and springing back.
final class DotPageScrollView: NSScrollView {
    var onMetricsChange: ((CGFloat, CGFloat, CGFloat) -> Void)?
    private(set) var isLiveScrolling = false
    var surface = "settings"
    private var trace: ScrollGestureTrace?

    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []
    private let liveScrollLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private weak var observedDocument: NSView?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let flippedClip = DotFlippedClipView(frame: bounds)
        flippedClip.drawsBackground = false
        contentView = flippedClip

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        automaticallyAdjustsContentInsets = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        scrollsDynamically = true
        wantsLayer = true
        contentView.wantsLayer = true
        contentView.postsBoundsChangedNotifications = true
        contentView.postsFrameChangedNotifications = true
        installNotifications()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        if let documentFrameToken {
            NotificationCenter.default.removeObserver(documentFrameToken)
        }
        let wasScrolling = liveScrollLock.withLock { active -> Bool in
            let prev = active
            active = false
            return prev
        }
        if wasScrolling {
            Task { @MainActor in
                DotScrollInteraction.endLiveScroll()
            }
        }
    }

    override var documentView: NSView? {
        didSet {
            guard observedDocument !== documentView else { return }
            observeDocument(documentView)
            updateScrollMetrics()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            finishLiveScrollIfNeeded()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        updateScrollMetrics()
    }

    func updateScrollMetrics() {
        let docH = documentView?.frame.height ?? 0
        let clipH = contentView.bounds.height
        if verticalScrollElasticity != .none {
            verticalScrollElasticity = .none
        }
        if horizontalScrollElasticity != .none {
            horizontalScrollElasticity = .none
        }

        // No origin is written here: the clip view re-constrains its own bounds
        // when the document shrinks, and a write during layout or right after
        // live scroll ends cuts the elastic rebound short.
        let maxY = max(0, docH - clipH)
        let remaining = max(0, maxY - contentView.bounds.origin.y)
        onMetricsChange?(docH, clipH, remaining)
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScrollOrLayoutChange() }
        })
        tokens.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScrollMetrics() }
        })
        tokens.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.startLiveScrollIfNeeded() }
        })
        tokens.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishLiveScrollIfNeeded()
                self?.updateScrollMetrics()
            }
        })
        observeDocument(documentView)
    }

    nonisolated(unsafe) private var documentFrameToken: NSObjectProtocol?

    private func observeDocument(_ view: NSView?) {
        if let documentFrameToken {
            NotificationCenter.default.removeObserver(documentFrameToken)
            self.documentFrameToken = nil
        }
        observedDocument = view
        guard let view else { return }
        view.postsFrameChangedNotifications = true
        documentFrameToken = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScrollMetrics() }
        }
    }

    private func handleScrollOrLayoutChange() {
        let docH = documentView?.frame.height ?? 0
        let clipH = contentView.bounds.height
        let maxY = max(0, docH - clipH)
        let originY = contentView.bounds.origin.y
        trace?.record(originY: originY, maxY: maxY, now: CACurrentMediaTime())
        let remaining = max(0, maxY - originY)
        onMetricsChange?(docH, clipH, remaining)
    }

    private func startLiveScrollIfNeeded() {
        guard !isLiveScrolling else { return }
        isLiveScrolling = true
        liveScrollLock.withLock { $0 = true }
        trace = ScrollGestureTrace(surface: surface, now: CACurrentMediaTime())
        DotScrollInteraction.beginLiveScroll()
    }

    func finishLiveScrollIfNeeded() {
        guard isLiveScrolling else { return }
        isLiveScrolling = false
        liveScrollLock.withLock { $0 = false }
        if let trace {
            Log.shared.info("scroll.gesture", trace.fields(
                now: CACurrentMediaTime(),
                elastic: verticalScrollElasticity == .allowed
            ))
        }
        trace = nil
        DotScrollInteraction.endLiveScroll()
    }
}

/// Non-hit-testing bottom paper fade driven directly on CoreAnimation without SwiftUI redraws.
final class DotBottomFadeOverlayView: NSView {
    static let fadeHeight: CGFloat = 22

    private let gradientLayer = CAGradientLayer()
    private var remaining: CGFloat = 0
    private var explicitColorScheme: ColorScheme?

    var debugOpacity: Float { gradientLayer.opacity }

    #if DEBUG
    var debugOpaqueColor: CGColor? {
        (gradientLayer.colors as? [CGColor])?.last
    }
    #endif

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gradientLayer)
        gradientLayer.opacity = 0
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        let flipped = gradientLayer.isGeometryFlipped
        gradientLayer.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func setColorScheme(_ scheme: ColorScheme?) {
        guard explicitColorScheme != scheme else { return }
        explicitColorScheme = scheme
        updateAppearance()
    }

    func updateAppearance() {
        let appearance: NSAppearance = explicitColorScheme.flatMap {
            NSAppearance(named: $0 == .dark ? .darkAqua : .aqua)
        } ?? effectiveAppearance
        var clearColor: CGColor?
        var opaqueColor: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            let srgb = NSColor(DotTheme.paper).usingColorSpace(.sRGB) ?? NSColor.windowBackgroundColor
            clearColor = srgb.withAlphaComponent(0).cgColor
            opaqueColor = srgb.cgColor
        }
        guard let clearColor, let opaqueColor else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = [clearColor, opaqueColor]
        CATransaction.commit()
    }

    func setRemaining(_ remaining: CGFloat) {
        self.remaining = remaining
        // Same 0.5 pt threshold as the elasticity rule, so a page that does not
        // overflow never shows a faint fade and the bottom limit lands on exact zero.
        let targetOpacity: Float = remaining <= 0.5 ? 0 : Float(min(1, remaining / Self.fadeHeight))
        guard gradientLayer.opacity != targetOpacity,
              targetOpacity == 0 || abs(gradientLayer.opacity - targetOpacity) > 0.001 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.opacity = targetOpacity
        CATransaction.commit()
    }
}

/// Plain flipped document that holds the page's hosting view.
///
/// `NSHostingView` reports itself incompatible with responsive scrolling, so as
/// the document it would force every page onto AppKit's legacy scrolling path.
final class DotPageDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Shared AppKit host view bundling `DotPageScrollView`, a single `NSHostingView`
/// document view, and the scroll-offset-driven bottom paper fade overlay.
@MainActor
class DotPageScrollHostView: NSView {
    let scrollView = DotPageScrollView()
    let hostingView: NSHostingView<AnyView>
    let bottomFadeView = DotBottomFadeOverlayView()
    let documentView = DotPageDocumentView()

    init(rootView: AnyView) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        hostingView.safeAreaRegions = []
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.wantsLayer = true
        documentView.addSubview(hostingView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bottomFadeView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(bottomFadeView)

        scrollView.documentView = documentView
        scrollView.onMetricsChange = { [weak bottomFadeView] _, _, remaining in
            bottomFadeView?.setRemaining(remaining)
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            hostingView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: documentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            bottomFadeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomFadeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomFadeView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomFadeView.heightAnchor.constraint(equalToConstant: DotBottomFadeOverlayView.fadeHeight),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        bottomFadeView.updateAppearance()
    }

    override func layout() {
        super.layout()
        scrollView.updateScrollMetrics()
    }

    func setColorScheme(_ scheme: ColorScheme?) {
        bottomFadeView.setColorScheme(scheme)
    }

    func cancelLiveScrollIfNeeded() {
        scrollView.finishLiveScrollIfNeeded()
    }
}

/// Uncached SwiftUI wrapper around `DotPageScrollHostView` for transient pages such as About.
struct DotPageScrollContainer<Content: View>: NSViewRepresentable {
    var colorScheme: ColorScheme? = nil
    let content: Content

    func makeNSView(context: Context) -> DotPageScrollHostView {
        let view = DotPageScrollHostView(rootView: AnyView(content))
        view.scrollView.surface = "about"
        view.setColorScheme(colorScheme)
        return view
    }

    func updateNSView(_ nsView: DotPageScrollHostView, context: Context) {
        nsView.hostingView.rootView = AnyView(content)
        nsView.setColorScheme(colorScheme)
        nsView.scrollView.updateScrollMetrics()
    }
}

/// Holds a SwiftUI `ScrollView`'s AppKit scroll view at a hard stop and tracks
/// its live scrolls (used by History, Palette and the island).
struct DotScrollViewConfigurator: NSViewRepresentable {
    let surface: String

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: surface)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.coordinator = context.coordinator
        context.coordinator.attachIfNeeded(from: nsView)
        context.coordinator.syncElasticity()
    }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                coordinator?.detach()
            } else {
                coordinator?.attachIfNeeded(from: self)
            }
        }

        override func layout() {
            super.layout()
            coordinator?.attachIfNeeded(from: self)
            coordinator?.syncElasticity()
        }
    }

    @MainActor
    final class Coordinator {
        private weak var scrollView: NSScrollView?
        private weak var documentView: NSView?
        nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []
        private let liveScrollLock = OSAllocatedUnfairLock<Bool>(initialState: false)
        private let surface: String
        private var trace: ScrollGestureTrace?

        init(surface: String) {
            self.surface = surface
        }

        deinit {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
            let wasScrolling = liveScrollLock.withLock { active -> Bool in
                let prev = active
                active = false
                return prev
            }
            if wasScrolling {
                Task { @MainActor in
                    DotScrollInteraction.endLiveScroll()
                }
            }
        }

        func attachIfNeeded(from probe: NSView) {
            guard let enclosing = probe.enclosingScrollView else { return }
            let doc = enclosing.documentView
            if scrollView !== enclosing || documentView !== doc {
                rebind(scrollView: enclosing, documentView: doc)
            }
            syncElasticity()
        }

        /// Binds an AppKit scroll view that owns its document directly, without
        /// the SwiftUI probe view used by the other surfaces.
        func attach(scrollView: NSScrollView) {
            rebind(scrollView: scrollView, documentView: scrollView.documentView)
            syncElasticity()
        }

        func detach() {
            finishLiveScrollIfNeeded()
        }

        /// Holds the scroll view at a hard stop on both axes. SwiftUI may reset
        /// elasticity when it rebuilds the hosting scroll view, so this runs on
        /// every layout and bounds change rather than once.
        func syncElasticity() {
            guard let scrollView else { return }
            if scrollView.verticalScrollElasticity != .none {
                scrollView.verticalScrollElasticity = .none
            }
            if scrollView.horizontalScrollElasticity != .none {
                scrollView.horizontalScrollElasticity = .none
            }
        }

        private func rebind(scrollView: NSScrollView, documentView: NSView?) {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
            tokens.removeAll()
            finishLiveScrollIfNeeded()

            self.scrollView = scrollView
            self.documentView = documentView

            scrollView.contentView.postsFrameChangedNotifications = true
            scrollView.contentView.postsBoundsChangedNotifications = true
            documentView?.postsFrameChangedNotifications = true

            let center = NotificationCenter.default
            tokens.append(center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncElasticity() }
            })
            tokens.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncElasticity()
                    self?.recordTrace()
                }
            })
            if let documentView {
                tokens.append(center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: documentView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncElasticity() }
                })
            }
            tokens.append(center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncElasticity()
                    self?.startLiveScrollIfNeeded()
                }
            })
            tokens.append(center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishLiveScrollIfNeeded()
                    self?.syncElasticity()
                }
            })
        }

        private func startLiveScrollIfNeeded() {
            let started = liveScrollLock.withLock { active -> Bool in
                guard !active else { return false }
                active = true
                return true
            }
            guard started else { return }
            trace = ScrollGestureTrace(surface: surface, now: CACurrentMediaTime())
            DotScrollInteraction.beginLiveScroll()
        }

        private func recordTrace() {
            guard trace != nil, let scrollView else { return }
            let docH = scrollView.documentView?.frame.height ?? 0
            let maxY = max(0, docH - scrollView.contentView.bounds.height)
            trace?.record(
                originY: scrollView.contentView.bounds.origin.y,
                maxY: maxY,
                now: CACurrentMediaTime()
            )
        }

        private func finishLiveScrollIfNeeded() {
            let ended = liveScrollLock.withLock { active -> Bool in
                guard active else { return false }
                active = false
                return true
            }
            guard ended else { return }
            if let trace, let scrollView {
                Log.shared.info("scroll.gesture", trace.fields(
                    now: CACurrentMediaTime(),
                    elastic: scrollView.verticalScrollElasticity == .allowed
                ))
            }
            trace = nil
            DotScrollInteraction.endLiveScroll()
        }
    }
}
