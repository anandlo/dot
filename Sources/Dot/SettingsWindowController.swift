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
    private var onClose: (() -> Void)?
    private let offscreen: Bool

    init(offscreen: Bool = false) {
        self.offscreen = offscreen
    }

    var isVisible: Bool {
        host?.window?.isVisible ?? false
    }

    /// Shows the settings.
    func show(
        store: ConfigStore,
        providers: [MenuProvider],
        tab: Int = 0,
        onChange: @escaping () -> Void,
        onSetAPIKey: @escaping (String, String) async -> String?,
        onDeleteAPIKey: @escaping (String) async -> String? = { _ in nil },
        onDeleteAllAPIKeys: @escaping () async -> String? = { nil },
        onChangeShortcut: @escaping () -> Void,
        onChangePasteShortcut: @escaping () -> Void = {},
        onChangePaletteShortcut: @escaping () -> Void = {},
        onOpenWelcome: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.onClose = onClose
        let host = existingHost()
        host.present {
            SettingsView(
                store: store,
                providers: providers,
                tab: tab,
                onChange: onChange,
                onSetAPIKey: onSetAPIKey,
                onDeleteAPIKey: onDeleteAPIKey,
                onDeleteAllAPIKeys: onDeleteAllAPIKeys,
                onChangeShortcut: onChangeShortcut,
                onChangePasteShortcut: onChangePasteShortcut,
                onChangePaletteShortcut: onChangePaletteShortcut,
                onOpenWelcome: onOpenWelcome
            )
            .environment(\.settingsHeadless, offscreen)
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
            size: CGSize(width: 820, height: 600),
            offscreen: offscreen,
            onClose: { [weak self] in
                self?.onClose?()
            }
        )
        self.host = host
        return host
    }
}
