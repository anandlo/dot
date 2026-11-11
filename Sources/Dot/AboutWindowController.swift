import AppKit
import SwiftUI

/// Owns the About window.
///
/// Like the welcome, it keeps one `DotWindowHost` for its lifetime and
/// replaces the content on every open. About is read-only: everything it shows
/// comes from the bundle, ``ProductLinks`` and the update check, and the one
/// action that leaves the window is the close.
@MainActor
final class AboutWindowController {
    private var host: DotWindowHost?

    /// Shows About, creating the window the first time.
    func show() {
        let host = existingHost()
        host.present {
            AboutView(onClose: { [weak self] in
                self?.close()
            })
        }
    }

    /// Closes the window.
    func close() {
        host?.dismiss()
    }

    private func existingHost() -> DotWindowHost {
        if let host {
            return host
        }
        let host = DotWindowHost(title: "About Dot", size: AboutView.size)
        self.host = host
        return host
    }
}
