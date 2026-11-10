import AppKit
import SwiftUI

/// Owns the About window.
///
/// Like the welcome, it keeps one `DotWindowHost` for its lifetime and
/// replaces the content on every open. About is read-only: its only actions
/// are the ones the caller supplies.
@MainActor
final class AboutWindowController {
    private var host: DotWindowHost?

    /// Shows About, creating the window the first time.
    func show(
        version: String,
        onWelcome: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenLog: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        let host = existingHost()
        host.present {
            AboutView(
                version: version,
                onWelcome: onWelcome,
                onOpenSettings: onOpenSettings,
                onOpenLog: onOpenLog,
                onClose: { [weak self] in
                    onClose()
                    self?.close()
                }
            )
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
        let host = DotWindowHost(
            title: "About Dot",
            size: CGSize(width: 520, height: 368)
        )
        self.host = host
        return host
    }
}
