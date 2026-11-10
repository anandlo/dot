import AppKit
import DotCore
import SwiftUI

/// Owns the settings window.
///
/// The host is created the first time settings are asked for and reused after
/// that; it owns the window and rebuilds it after a close. Dot is an accessory
/// app, so opening the window is the one moment it deliberately comes
/// forward — and only because the user picked Settings. The window itself is
/// the shared `DotWindowHost`: transparent title bar, native traffic lights
/// and the warm paper surface.
@MainActor
final class SettingsWindowController {
    private var host: DotWindowHost?

    /// Shows the settings.
    func show(
        config: Binding<DotConfig>,
        providers: [MenuProvider],
        tab: Int = 0,
        onChange: @escaping () -> Void,
        onSetAPIKey: @escaping (String, String) -> String?,
        onTest: @escaping (String) async -> Bool,
        onChangeShortcut: @escaping () -> Void,
        onChangePasteShortcut: @escaping () -> Void = {},
        onOpenWelcome: @escaping () -> Void = {}
    ) {
        let host = existingHost()
        host.present {
            SettingsView(
                config: config,
                providers: providers,
                tab: tab,
                onChange: onChange,
                onSetAPIKey: onSetAPIKey,
                onTest: onTest,
                onChangeShortcut: onChangeShortcut,
                onChangePasteShortcut: onChangePasteShortcut,
                onOpenWelcome: onOpenWelcome
            )
        }
    }

    /// Closes the window without the usual fade.
    ///
    /// This is the path used when Dot is terminating: the process is about to
    /// disappear, so an animation would only delay it.
    func close() {
        host?.dismiss(animated: false)
    }

    private func existingHost() -> DotWindowHost {
        if let host {
            return host
        }
        let host = DotWindowHost(
            title: "Dot Settings",
            size: CGSize(width: 820, height: 600)
        )
        self.host = host
        return host
    }
}
