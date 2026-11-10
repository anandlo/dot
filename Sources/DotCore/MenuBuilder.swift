import AppKit
import Foundation

/// What a menu item does when it is picked.
public enum MenuAction: Hashable, Sendable {
    /// Start or stop the recording.
    case toggleRecording
    /// Paste the last transcript again.
    case pasteLast
    /// Copy the last transcript again.
    case copyLast
    /// Copy a transcript from the history.
    case copyHistory(String)
    /// Clear the history.
    case clearHistory
    /// Use a microphone; `nil` is the system default.
    case selectMicrophone(String?)
    /// Use a language.
    case selectLanguage(String)
    /// Use the service a preset id names.
    case selectPreset(String)
    /// Set the API key of a provider.
    case setAPIKey(String)
    /// Turn auto-paste on or off.
    case toggleAutoPaste
    /// Turn fast record (single-click menu bar icon) on or off.
    case toggleFastRecord
    /// Turn launch at login on or off.
    case toggleLaunchAtLogin
    /// Open the history window.
    case openHistory
    /// Open the welcome window.
    case openWelcome
    /// Open the settings window.
    case openSettings
    /// Open the log in Finder.
    case openLog
    /// Check for app updates.
    case checkForUpdates
    /// Open the about window.
    case showAbout
    /// Quit the app.
    case quit
}

/// The modifiers of a keyboard shortcut, in the terms a menu understands.
public struct MenuModifiers: OptionSet, Equatable, Sendable {
    /// The raw value of the set.
    public let rawValue: Int

    /// Creates a set of modifiers.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The Command key.
    public static let command = MenuModifiers(rawValue: 1 << 0)
    /// The Option key.
    public static let option = MenuModifiers(rawValue: 1 << 1)
    /// The Control key.
    public static let control = MenuModifiers(rawValue: 1 << 2)
    /// The Shift key.
    public static let shift = MenuModifiers(rawValue: 1 << 3)
}

/// The keyboard shortcut of a menu item.
public struct MenuShortcut: Equatable, Sendable {
    /// How the shortcut is written, e.g. `⌘Q`.
    public var display: String
    /// The key equivalent the menu uses, e.g. `q`.
    public var key: String
    /// The modifiers the menu uses.
    public var modifiers: MenuModifiers

    /// Creates a shortcut.
    public init(display: String, key: String, modifiers: MenuModifiers = []) {
        self.display = display
        self.key = key
        self.modifiers = modifiers
    }
}

/// A microphone the menu can switch to.
public struct MenuMicrophone: Equatable, Sendable {
    /// The device's unique id; `nil` is the system default.
    public var id: String?
    /// The name shown in the menu.
    public var name: String

    /// Creates a microphone entry.
    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

/// A language the menu can switch to.
public struct MenuLanguage: Equatable, Sendable {
    /// The id sent to the provider.
    public var id: String
    /// The name shown in the menu.
    public var name: String

    /// Creates a language entry.
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A service the menu can switch to.
///
/// A row is a preset, not a provider implementation: the menu offers the same
/// rows the Settings picker offers, so a pick means the same thing in both
/// places. Several rows can select one provider id, because every
/// OpenAI-compatible service does, so the preset id is what a pick carries and
/// the provider id is only where the key lives.
public struct MenuProvider: Equatable, Sendable {
    /// The id of the row a pick selects.
    public var presetID: String
    /// The provider id the row builds.
    public var providerID: String
    /// The name shown in the menu.
    public var displayName: String
    /// Whether the row may need a key.
    public var needsKey: Bool
    /// Whether the credential is in the Keychain.
    public var hasKey: Bool

    /// Creates a provider entry.
    public init(
        presetID: String,
        providerID: String,
        displayName: String,
        needsKey: Bool,
        hasKey: Bool
    ) {
        self.presetID = presetID
        self.providerID = providerID
        self.displayName = displayName
        self.needsKey = needsKey
        self.hasKey = hasKey
    }
}

/// One item of the menu bar menu.
public struct MenuItem: Equatable, Sendable {
    /// The title of the item.
    public var title: String
    /// The action the item performs.
    public var action: MenuAction?
    /// The keyboard shortcut of the item.
    public var shortcut: MenuShortcut?
    /// Whether the item carries a checkmark.
    public var isOn: Bool
    /// Whether the item can be picked.
    public var isEnabled: Bool
    /// The items of a submenu.
    public var children: [MenuItem]
    /// Whether the item is a separator.
    public var isSeparator: Bool

    /// Creates an item.
    public init(
        title: String,
        action: MenuAction? = nil,
        shortcut: MenuShortcut? = nil,
        isOn: Bool = false,
        isEnabled: Bool = true,
        children: [MenuItem] = []
    ) {
        self.title = title
        self.action = action
        self.shortcut = shortcut
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.children = children
        self.isSeparator = false
    }

    /// A separator.
    public static var separator: MenuItem {
        var item = MenuItem(title: "", isEnabled: false)
        item.isSeparator = true
        return item
    }
}

/// Everything the menu shows.
///
/// The menu is rebuilt from this every time it is about to open, so every
/// title, every checkmark and every shortcut is the truth at that moment.
public struct MenuState: Equatable, Sendable {
    /// Whether a recording is running.
    public var isRecording: Bool
    /// The shortcut that starts and stops a recording.
    public var recordShortcut: MenuShortcut?
    /// The shortcut that pastes the last transcript again.
    public var pasteShortcut: MenuShortcut?
    /// The last transcripts, newest first.
    public var history: [String]
    /// The microphones that can be used.
    public var microphones: [MenuMicrophone]
    /// The microphone in use.
    public var selectedMicrophoneID: String?
    /// The languages that can be chosen.
    public var languages: [MenuLanguage]
    /// The language in use.
    public var selectedLanguage: String
    /// The services that can be used.
    public var providers: [MenuProvider]
    /// The row in use.
    public var selectedPresetID: String
    /// Whether the transcript is pasted into the frontmost application.
    public var autoPasteEnabled: Bool
    /// Whether single-clicking the menu bar icon starts or stops recording.
    public var fastRecordEnabled: Bool
    /// Whether Dot starts when the machine does.
    public var launchAtLogin: Bool

    /// Creates the state of the menu.
    public init(
        isRecording: Bool = false,
        recordShortcut: MenuShortcut? = nil,
        pasteShortcut: MenuShortcut? = nil,
        history: [String] = [],
        microphones: [MenuMicrophone] = [],
        selectedMicrophoneID: String? = nil,
        languages: [MenuLanguage] = [],
        selectedLanguage: String = "auto",
        providers: [MenuProvider] = [],
        selectedPresetID: String = "",
        autoPasteEnabled: Bool = true,
        fastRecordEnabled: Bool = false,
        launchAtLogin: Bool = false
    ) {
        self.isRecording = isRecording
        self.recordShortcut = recordShortcut
        self.pasteShortcut = pasteShortcut
        self.history = history
        self.microphones = microphones
        self.selectedMicrophoneID = selectedMicrophoneID
        self.languages = languages
        self.selectedLanguage = selectedLanguage
        self.providers = providers
        self.selectedPresetID = selectedPresetID
        self.autoPasteEnabled = autoPasteEnabled
        self.fastRecordEnabled = fastRecordEnabled
        self.launchAtLogin = launchAtLogin
    }
}

/// Builds the menu bar menu.
///
/// The tree is built as data first and turned into an `NSMenu` afterwards, so
/// the whole menu can be walked in a test without a window server.
public enum MenuBuilder {
    /// The languages Dot offers.
    public static let languages: [MenuLanguage] = [
        MenuLanguage(id: "auto", name: "Auto"),
        MenuLanguage(id: "en", name: "English"),
        MenuLanguage(id: "zh", name: "中文"),
    ]

    /// The title of the item that starts or stops the recording.
    public static func recordTitle(isRecording: Bool) -> String {
        isRecording ? "Stop Recording" : "Start Recording"
    }

    /// The tree of the menu.
    ///
    /// - Parameter state: what the menu shows right now.
    /// - Returns: the items of the menu, in order.
    public static func items(for state: MenuState) -> [MenuItem] {
        var items: [MenuItem] = []

        items.append(MenuItem(
            title: recordTitle(isRecording: state.isRecording),
            action: .toggleRecording,
            shortcut: state.recordShortcut
        ))

        items.append(.separator)

        items.append(MenuItem(
            title: "Paste Last Transcript",
            action: .pasteLast,
            shortcut: state.pasteShortcut,
            isEnabled: !state.history.isEmpty
        ))
        items.append(MenuItem(
            title: "Copy Last Transcript",
            action: .copyLast,
            isEnabled: !state.history.isEmpty
        ))
        items.append(MenuItem(
            title: "Recent Transcripts",
            children: historyItems(state.history)
        ))
        items.append(MenuItem(
            title: "History…",
            action: .openHistory,
            shortcut: MenuShortcut(display: "⌘Y", key: "y", modifiers: .command)
        ))

        items.append(.separator)

        items.append(MenuItem(title: "Microphone", children: microphoneItems(state)))
        items.append(MenuItem(title: "Language", children: languageItems(state)))
        items.append(MenuItem(title: "Provider", children: providerItems(state)))

        items.append(.separator)

        items.append(MenuItem(
            title: "Auto-Paste",
            action: .toggleAutoPaste,
            isOn: state.autoPasteEnabled
        ))
        items.append(MenuItem(
            title: "Fast Record",
            action: .toggleFastRecord,
            isOn: state.fastRecordEnabled
        ))
        items.append(MenuItem(
            title: "Launch at Login",
            action: .toggleLaunchAtLogin,
            isOn: state.launchAtLogin
        ))

        items.append(.separator)

        items.append(MenuItem(title: "Welcome to Dot", action: .openWelcome))
        items.append(MenuItem(
            title: "Settings…",
            action: .openSettings,
            shortcut: MenuShortcut(display: "⌘,", key: ",", modifiers: .command)
        ))
        items.append(MenuItem(title: "Open Log in Finder", action: .openLog))

        items.append(.separator)

        items.append(MenuItem(title: "Check for Updates…", action: .checkForUpdates))
        items.append(MenuItem(title: "About Dot", action: .showAbout))
        items.append(MenuItem(
            title: "Quit Dot",
            action: .quit,
            shortcut: MenuShortcut(display: "⌘Q", key: "q", modifiers: .command)
        ))

        return items
    }

    /// The items of the recent transcripts.
    private static func historyItems(_ history: [String]) -> [MenuItem] {
        guard !history.isEmpty else {
            return [MenuItem(title: "No transcripts yet", isEnabled: false)]
        }
        var items = history.prefix(5).map { transcript in
            MenuItem(
                title: transcript.count > 48 ? String(transcript.prefix(48)) + "…" : transcript,
                action: .copyHistory(transcript)
            )
        }
        items.append(.separator)
        items.append(MenuItem(title: "Clear History…", action: .clearHistory))
        return items
    }

    /// The items of the microphone submenu.
    private static func microphoneItems(_ state: MenuState) -> [MenuItem] {
        var items = state.microphones.map { microphone in
            MenuItem(
                title: microphone.name,
                action: .selectMicrophone(microphone.id),
                isOn: microphone.id == state.selectedMicrophoneID
            )
        }
        if items.isEmpty {
            items.append(MenuItem(
                title: "System Default",
                action: .selectMicrophone(nil),
                isOn: state.selectedMicrophoneID == nil
            ))
        }
        return items
    }

    /// The items of the language submenu.
    private static func languageItems(_ state: MenuState) -> [MenuItem] {
        let languages = state.languages.isEmpty ? Self.languages : state.languages
        return languages.map { language in
            MenuItem(
                title: language.name,
                action: .selectLanguage(language.id),
                isOn: language.id == state.selectedLanguage
            )
        }
    }

    /// The rows of the provider submenu.
    ///
    /// The rows are the services. The key action below them belongs to the row
    /// in use: a key row per service would repeat near-identical titles that
    /// read as more services, and it would name a service only by the shape of
    /// its credential.
    private static func providerItems(_ state: MenuState) -> [MenuItem] {
        guard !state.providers.isEmpty else {
            return [MenuItem(title: "No provider is available", isEnabled: false)]
        }
        var items = state.providers.map { provider in
            MenuItem(
                title: provider.displayName,
                action: .selectPreset(provider.presetID),
                isOn: provider.presetID == state.selectedPresetID
            )
        }
        if let selected = state.providers.first(where: { $0.presetID == state.selectedPresetID }),
           selected.needsKey {
            items.append(.separator)
            items.append(MenuItem(
                title: selected.hasKey ? "Replace API Key…" : "Set API Key…",
                action: .setAPIKey(selected.providerID)
            ))
        }
        return items
    }

    /// The provider rows the menu draws for a configuration.
    ///
    /// The rows come from ``ProviderPreset/rows(for:)``, the list the picker
    /// draws, so the menu cannot offer a different set of services than
    /// Settings, cannot name an owned endpoint differently, and cannot drop a
    /// service Dot ships because its base URL has not been filled in.
    ///
    /// - Parameters:
    ///   - config: the configuration the rows describe.
    ///   - hasKey: whether a provider id has a key in the Keychain. Asked once
    ///     per distinct id, and never for a row that cannot need one.
    /// - Returns: one row per preset, in the order the picker shows them.
    public static func providerRows(
        config: DotConfig,
        hasKey: (String) -> Bool
    ) -> [MenuProvider] {
        var known: [String: Bool] = [:]
        func keyState(for providerID: String) -> Bool {
            if let known = known[providerID] { return known }
            let exists = hasKey(providerID)
            known[providerID] = exists
            return exists
        }
        return ProviderPreset.rows(for: config).map { preset in
            MenuProvider(
                presetID: preset.id,
                providerID: preset.providerID,
                displayName: preset.name,
                needsKey: preset.key != .none,
                hasKey: preset.key == .none ? false : keyState(for: preset.providerID)
            )
        }
    }

    /// Builds the menu of the menu bar item.
    ///
    /// - Parameters:
    ///   - state: what the menu shows right now.
    ///   - target: the object that receives the actions.
    /// - Returns: the menu, ready to be shown.
    public static func build(state: MenuState, target: MenuActionTarget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items(for: state) {
            menu.addItem(makeItem(item, target: target))
        }
        return menu
    }

    /// The menu as text.
    ///
    /// This is the review copy: it shows every title, every checkmark, every
    /// shortcut and every submenu in the order the menu shows them. It has no
    /// effect on the menu itself.
    public static func plainText(for state: MenuState) -> String {
        var lines: [String] = []

        func append(_ items: [MenuItem], depth: Int) {
            for item in items {
                let indent = String(repeating: "  ", count: depth)
                if item.isSeparator {
                    lines.append(indent + "───")
                    continue
                }
                var line = indent
                line += item.isOn ? "✓ " : "  "
                line += item.title
                if !item.children.isEmpty { line += " ▸" }
                if !item.isEnabled { line += "  (disabled)" }
                if let shortcut = item.shortcut { line += "  " + shortcut.display }
                lines.append(line)
                if !item.children.isEmpty {
                    append(item.children, depth: depth + 1)
                }
            }
        }

        append(items(for: state), depth: 0)
        return lines.joined(separator: "\n")
    }

    /// Turns one item of the tree into a menu item.
    private static func makeItem(_ item: MenuItem, target: MenuActionTarget) -> NSMenuItem {
        if item.isSeparator {
            return .separator()
        }
        let menuItem = NSMenuItem(
            title: item.title,
            action: item.action == nil ? nil : #selector(MenuActionTarget.performAction(_:)),
            keyEquivalent: ""
        )
        menuItem.target = target
        menuItem.isEnabled = item.isEnabled
        menuItem.state = item.isOn ? .on : .off
        menuItem.representedObject = item.action.map(MenuActionBox.init(action:))
        if let shortcut = item.shortcut, shortcut.key.count == 1 {
            menuItem.keyEquivalent = shortcut.key.lowercased()
            var flags: NSEvent.ModifierFlags = []
            if shortcut.modifiers.contains(.command) { flags.insert(.command) }
            if shortcut.modifiers.contains(.option) { flags.insert(.option) }
            if shortcut.modifiers.contains(.control) { flags.insert(.control) }
            if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
            menuItem.keyEquivalentModifierMask = flags
        }
        if !item.children.isEmpty {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in item.children {
                submenu.addItem(makeItem(child, target: target))
            }
            menuItem.submenu = submenu
        }
        return menuItem
    }
}

/// Carries a menu action through `representedObject`.
public final class MenuActionBox: NSObject {
    /// The action the item performs.
    public let action: MenuAction

    /// Creates the box.
    public init(action: MenuAction) {
        self.action = action
    }
}

/// Receives the actions of the menu.
///
/// A menu item's target is not retained, so the controller that owns the menu
/// keeps this object alive.
public final class MenuActionTarget: NSObject {
    /// Called when an item is picked.
    public var handler: ((MenuAction) -> Void)?

    /// Creates a target.
    public override init() {
        super.init()
    }

    /// Picks the action out of the item and hands it over.
    @objc public func performAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuActionBox else { return }
        handler?(box.action)
    }
}
