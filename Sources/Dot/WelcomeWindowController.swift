import AppKit
import DotCore
import SwiftUI

/// Owns the welcome window.
///
/// The window is created once and reused: opening Welcome from the menu
/// replaces the content so the microphone and provider status are current.
/// The controller is deliberately separate from the first-run flag — the
/// caller decides when the flag is written, and closing the window with the
/// traffic lights never touches it.
@MainActor
final class WelcomeWindowController {
    private var host: DotWindowHost?

    /// Called whenever the window closes, however it was closed.
    ///
    /// The first-run flag has to be written here as well as on the explicit
    /// finish action: closing the window with the traffic lights is a perfectly
    /// clear "I have seen this", and treating it otherwise made the welcome
    /// reopen on every launch.
    var onDismiss: (() -> Void)?

    /// Shows the welcome, creating the window the first time.
    func show(
        presets: [ProviderPreset],
        selectedPresetID: String?,
        providerReady: Bool,
        microphoneStatus: String,
        accessibilityGranted: Bool,
        shortcutLabel: String,
        recordingMode: RecordingMode = .toggle,
        onEnableMicrophone: @escaping () async -> String,
        onChangeShortcut: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onConnect: @escaping (ProviderPreset, String) async -> ProviderConnectionResult,
        onFinish: @escaping () -> Void
    ) {
        let host = existingHost()
        host.present {
            WelcomeView(
                presets: presets,
                selectedPresetID: selectedPresetID,
                providerReady: providerReady,
                microphoneStatus: microphoneStatus,
                accessibilityGranted: accessibilityGranted,
                shortcutLabel: shortcutLabel,
                recordingMode: recordingMode,
                onEnableMicrophone: onEnableMicrophone,
                onChangeShortcut: onChangeShortcut,
                onOpenSettings: onOpenSettings,
                onConnect: onConnect,
                onFinish: { [weak self] in
                    onFinish()
                    self?.close()
                }
            )
        }
    }

    /// Closes the window with the same short fade as every other light window.
    func close() {
        host?.dismiss()
    }

    private func existingHost() -> DotWindowHost {
        if let host {
            return host
        }
        let host = DotWindowHost(
            title: "Welcome to Dot",
            size: CGSize(width: 720, height: 560),
            onClose: { [weak self] in self?.onDismiss?() }
        )
        self.host = host
        return host
    }
}
