import AppKit
import SwiftUI

/// The shared light window: transparent title bar, native traffic lights,
/// paper content, and a short fade-and-settle when it appears.
@MainActor
final class DotWindowHost: NSWindowController, NSWindowDelegate {
    private let windowTitle: String
    private let contentSize: CGSize
    private let onClose: (() -> Void)?
    private var hosting: NSHostingController<AnyView>?
    private var isDismissing = false

    init(title: String, size: CGSize, onClose: (() -> Void)? = nil) {
        self.windowTitle = title
        self.contentSize = size
        self.onClose = onClose
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Shows the window, replacing its content if it is already open.
    func present<Content: View>(@ViewBuilder content: () -> Content) {
        isDismissing = false
        if window == nil {
            makeWindow()
        }
        hosting?.rootView = AnyView(content())
        guard let window else { return }
        // Assigning a new root view re-applies the hosting view's fitting
        // size to the window, so the fixed size is restored before the window
        // is shown. A window that is still reachable keeps the position the
        // user moved it to; only an off-screen one is brought back.
        window.setContentSize(contentSize)
        if !isOnScreen(window) {
            center(window)
        }
        window.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.invalidateShadow()
    }

    /// Fades the window out and closes it.
    func dismiss(animated: Bool = true) {
        guard let window, !isDismissing else { return }
        isDismissing = true
        guard animated else {
            window.close()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                window.close()
                self?.isDismissing = false
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // The next `present` builds a fresh window and hosting view. Without
        // dropping both, a reused controller would reopen the old content.
        hosting = nil
        window = nil
        onClose?()
    }

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.animationBehavior = .none
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self

        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        // The window draws its own fixed-size paper layout, including the
        // room for the traffic lights, so the hosting view must not add the
        // titlebar's safe area on top of it.
        hosting.safeAreaRegions = []
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentViewController = hosting
        self.hosting = hosting
        self.window = window

        // Installing the hosting controller also installs its empty root view,
        // and AppKit collapses the window to that view's zero fitting size.
        // Restore the requested content size before centring: a zero-width
        // window is centred on the screen's middle, and the real content then
        // grows it to the right from there.
        window.setContentSize(contentSize)
        center(window)
    }

    private func isOnScreen(_ window: NSWindow) -> Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return true }
        return DotWindowPlacement.isOnScreen(
            window.frame,
            visibleFrames: screens.map(\.visibleFrame)
        )
    }

    private func center(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            window.center()
            return
        }
        let content = DotWindowPlacement.contentFrame(
            contentSize: contentSize,
            visibleFrame: screen.visibleFrame
        )
        window.setFrame(
            window.frameRect(forContentRect: content),
            display: false
        )
    }
}
