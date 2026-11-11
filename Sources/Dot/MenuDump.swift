import Foundation
import DotCore

/// Prints the menu bar menu without opening it.
///
/// The dump is the review copy of the menu: every title, checkmark, shortcut
/// and submenu, in order. It reads the real configuration and the real
/// provider list, but never the Keychain's contents and never a transcript
/// from the user's history — the history shown here is a sample.
@MainActor
enum MenuDump {
    /// The argument that prints the menu and exits.
    static let argument = "--dump-menu"

    /// Prints the menu.
    static func run() {
        // The dump shows what the app shows. A provider id Dot cannot build is
        // corrected the same way the launch corrects it, but nothing is written
        // back: a review tool never edits the user's configuration.
        let config = ProviderMigration.loadConfiguration().config
        let providers = MenuBuilder.providerRows(config: config) { id in
            CredentialStore.hasKey(for: id)
        }

        var state = MenuState()
        state.isRecording = false
        state.recordShortcut = MenuShortcuts.shortcut(for: config.hotkey)
        state.assistantShortcut = MenuShortcuts.shortcut(for: config.assistantHotkey)
        state.pasteShortcut = MenuShortcuts.shortcut(for: config.pasteHotkey)
        state.history = [
            "The meeting is at four.",
            "Remind me to call Sam.",
        ]
        state.microphones = [
            MenuMicrophone(id: nil, name: "System Default"),
            MenuMicrophone(id: "built-in", name: "MacBook Pro Microphone"),
            MenuMicrophone(id: "airpods", name: "AirPods Pro"),
        ]
        state.selectedMicrophoneID = config.microphoneDeviceUID
        let currentModel = config.settings(for: config.provider).model
        state.languages = ProviderLanguageCatalog.menuLanguages(for: config.provider, model: currentModel)
        state.selectedLanguage = ProviderLanguageCatalog.validatedLanguage(
            config.settings(for: config.provider).language,
            for: config.provider,
            model: currentModel
        )
        state.providers = providers
        state.selectedPresetID = ProviderPreset.presenting(config).id
        state.autoPasteEnabled = config.autoPaste
        state.launchAtLogin = LaunchAtLogin.isEnabled

        print("Dot — menu bar menu")
        print(MenuBuilder.plainText(for: state))
    }
}
