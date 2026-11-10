import AppKit
import DotCore
import SwiftUI

/// Owns the History window.
///
/// The host is created the first time the window is asked for and reused after
/// that. `show` replaces the content, so calling it again with a fresh history
/// keeps an already-open window current after a copy or a clear. The controller
/// never reads the history file: the caller passes the transcripts and owns the
/// copy and clear behaviour.
@MainActor
final class HistoryWindowController {
    private var host: DotWindowHost?

    /// Shows the history, creating the window the first time.
    func show(
        history: [String],
        recordHotkey: Hotkey,
        onCopy: @escaping (String) -> Void,
        onClear: @escaping () -> Void
    ) {
        let host = existingHost()
        host.present {
            HistoryView(
                history: history,
                onCopy: onCopy,
                onClear: onClear,
                onClose: { [weak self] in
                    self?.close()
                },
                recordHotkey: recordHotkey
            )
        }
    }

    /// Closes the window with the same short fade as every light window.
    func close() {
        host?.dismiss()
    }

    private func existingHost() -> DotWindowHost {
        if let host {
            return host
        }
        let host = DotWindowHost(
            title: "History",
            size: CGSize(width: 620, height: 560)
        )
        self.host = host
        return host
    }
}
