import AppKit
import DotCore
import SwiftUI

/// The settings window.
///
/// It is the only surface where Dot's behaviour can be changed. The view owns
/// no window, reads no Keychain and writes no file: every value arrives from
/// the caller and every change goes back out through a binding or a callback.
/// The window is deliberately light and quiet — the HUD is the only dark
/// surface in the app.
@MainActor
struct SettingsView: View {
    @Binding private var config: DotConfig
    /// The providers that can be chosen.
    private let providers: [MenuProvider]
    /// The page the caller asked for. A later `show(tab:)` can move the
    /// already-open window to another page.
    private let requestedTab: Int
    /// Called after any real change to the configuration.
    private let onChange: () -> Void
    /// Stores an API key. Returns an error message, or `nil` on success.
    private let onSetAPIKey: (String, String) -> String?
    /// Deletes an API key for a provider. Returns an error message, or `nil` on success.
    private let onDeleteAPIKey: (String) -> String?
    /// Deletes all API keys for all providers from Keychain.
    private let onDeleteAllAPIKeys: () -> String?
    /// Asks a provider whether it can transcribe right now.
    private let onTest: (String) async -> Bool
    /// Opens the shortcut recorder for the record shortcut.
    private let onChangeShortcut: () -> Void
    /// Opens the shortcut recorder for the paste shortcut.
    private let onChangePasteShortcut: () -> Void
    /// Opens the shortcut recorder for the palette shortcut.
    private let onChangePaletteShortcut: () -> Void
    /// Opens the welcome window.
    private let onOpenWelcome: () -> Void
    /// A state to draw in place of the update check, for a render.
    private let aboutUpdatePreview: AboutUpdateState?
    /// The model list a render draws, so the picker can be looked at without a
    /// network.
    private let modelPreview: [AvailableModel]?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsHeadless) private var headless
    @Environment(\.settingsVersionOverride) private var versionOverride
    @Environment(\.settingsDefaultInputUID) private var defaultInputUIDOverride
    @Environment(\.settingsHeightOverride) private var heightOverride

    @State private var selected: Page
    @State private var hoveredPage: Page?
    /// The space the selection pill travels in, so a change of page reads as the
    /// pill moving down the list instead of one pill vanishing and another
    /// appearing.
    @Namespace private var sidebarPillSpace
    /// Counts the writes this view makes to its own configuration.
    ///
    /// `config` is a binding whose value lives on a plain property outside
    /// SwiftUI, so a write through it changes nothing the view is observing and
    /// the tree is only rebuilt when something else happens to rebuild it -
    /// measured at one and three quarter seconds for a press whose application
    /// took forty milliseconds. Reading this counter in the body makes the view
    /// a participant in its own change again.
    @State private var revision = 0
    @State private var microphoneDevices: [MicrophoneDevice] = []
    /// The UID the system default microphone resolves to, read when the window
    /// appears. A calibration is keyed by device, and "system default" names
    /// whichever device is first today.
    @State private var defaultInputUID: String?
    @State private var primaryKey = ""
    @State private var keyStatus: KeyStatus?
    @State private var savedProviders: Set<String> = []
    @State private var connectingPrimary = false
    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var liveDwellSeconds: Double = HUDDwell.defaultSeconds
    @State private var availableModels: [AvailableModel] = []
    @State private var isLoadingModels = false
    @State private var isCustomModelSelected = false
    @FocusState private var focusedField: Field?

    /// Creates the settings.
    ///
    /// - Parameters:
    ///   - config: The configuration every control reads and writes.
    ///   - providers: The providers the menu currently knows about.
    ///   - tab: The page to open: 0 General, 1 Provider, 2 Shortcuts,
    ///     3 Appearance, 4 About.
    ///   - onChange: Called once for every real configuration change.
    ///   - onSetAPIKey: Writes a key and returns an error, or `nil`.
    ///   - onDeleteAPIKey: Deletes a key and returns an error, or `nil`.
    ///   - onDeleteAllAPIKeys: Purges all keys and returns an error, or `nil`.
    ///   - onTest: Checks whether a provider can transcribe right now.
    ///   - onChangeShortcut: Opens the record-shortcut recorder.
    ///   - onChangePasteShortcut: Opens the paste-shortcut recorder.
    ///   - onChangePaletteShortcut: Opens the palette-shortcut recorder.
    ///   - onOpenWelcome: Opens the welcome window.
    ///   - aboutUpdatePreview: A state to draw in the update row, for a render.
    init(
        config: Binding<DotConfig>,
        providers: [MenuProvider],
        tab: Int = 0,
        onChange: @escaping () -> Void,
        onSetAPIKey: @escaping (String, String) -> String?,
        onDeleteAPIKey: @escaping (String) -> String? = { _ in nil },
        onDeleteAllAPIKeys: @escaping () -> String? = { nil },
        onTest: @escaping (String) async -> Bool,
        onChangeShortcut: @escaping () -> Void,
        onChangePasteShortcut: @escaping () -> Void = {},
        onChangePaletteShortcut: @escaping () -> Void = {},
        onOpenWelcome: @escaping () -> Void = {},
        aboutUpdatePreview: AboutUpdateState? = nil,
        modelPreview: [AvailableModel]? = nil
    ) {
        _config = config
        self.providers = providers
        self.requestedTab = tab
        _selected = State(initialValue: Page(rawValue: tab) ?? .general)
        self.onChange = onChange
        self.onSetAPIKey = onSetAPIKey
        self.onDeleteAPIKey = onDeleteAPIKey
        self.onDeleteAllAPIKeys = onDeleteAllAPIKeys
        self.onTest = onTest
        self.onChangeShortcut = onChangeShortcut
        self.onChangePasteShortcut = onChangePasteShortcut
        self.onChangePaletteShortcut = onChangePaletteShortcut
        self.onOpenWelcome = onOpenWelcome
        self.aboutUpdatePreview = aboutUpdatePreview
        self.modelPreview = modelPreview
        _availableModels = State(initialValue: modelPreview ?? [])
        _liveDwellSeconds = State(initialValue: config.wrappedValue.hudDwellSeconds)
    }

    var body: some View {
        let _ = revision
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(DotTheme.hairline)
                .frame(width: 1)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(width: 820, height: heightOverride ?? 600)
        .background(DotPaper())
        .dotAppearance(config.appearance)
        .onChange(of: config) { _, _ in
            onChange()
        }
        .onChange(of: config.hudDwellSeconds) { _, newValue in
            if liveDwellSeconds != newValue {
                liveDwellSeconds = newValue
            }
        }
        .onChange(of: requestedTab) { _, value in
            guard let page = Page(rawValue: value), page != selected else { return }
            select(page)
        }
        .onAppear {
            // A render supplies the default input rather than enumerating the
            // machine's audio devices; the real window asks the system.
            if defaultInputUID == nil {
                defaultInputUID = defaultInputUIDOverride
                    ?? (headless ? nil : MicrophoneCatalog.recordingDeviceUID(configured: nil))
            }
            guard !headless else { return }
            launchAtLogin = LaunchAtLogin.isEnabled
            if microphoneDevices.isEmpty {
                microphoneDevices = MicrophoneCatalog.devices()
            }
            refreshModels()
        }
        .onChange(of: config.provider) { _, _ in
            availableModels = []
            isCustomModelSelected = false
            refreshModels()
            updateLanguageForModel(currentConfiguredModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            guard !headless else { return }
            let latest = LaunchAtLogin.isEnabled
            if launchAtLogin != latest {
                launchAtLogin = latest
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DotTheme.ink3)
                .padding(.leading, 22)
                .padding(.top, 40)
                .padding(.bottom, 8)

            VStack(spacing: 3) {
                ForEach(Page.allCases) { page in
                    sidebarItem(page)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)
        }
        .padding(.bottom, 12)
        .frame(width: 198)
        .frame(maxHeight: .infinity)
        .background(
            DotTheme.sidebarFill
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [DotTheme.sidebarHighlight, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 150)
                }
        )
    }

    private func sidebarItem(_ page: Page) -> some View {
        let isSelected = selected == page
        let isHovered = hoveredPage == page
        return Button {
            select(page)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isSelected ? DotTheme.sidebarSelectedIcon : DotTheme.ink3)
                    .frame(width: 16)
                Text(page.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? DotTheme.sidebarSelectedText : DotTheme.ink2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 33)
            .background {
                if isSelected {
                    sidebarPill
                        .matchedGeometryEffect(id: "sidebar-pill", in: sidebarPillSpace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DotTheme.sidebarHoverFill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                if hovering {
                    hoveredPage = page
                } else if hoveredPage == page {
                    hoveredPage = nil
                }
            }
        }
        .accessibilityLabel(page.title)
        .accessibilityHint("Shows the \(page.title) settings.")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The selection pill itself, matched across rows so it travels rather than
    /// blinking from one item to the next.
    private var sidebarPill: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(DotTheme.sidebarSelectedFill)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(DotTheme.sidebarSelectedBorder, lineWidth: 1)
            )
    }

    // MARK: - Page

    private var page: some View {
        VStack(spacing: 0) {
            pageHeader
                .zIndex(2)
            Rectangle()
                .fill(DotTheme.hairline)
                .frame(height: 1)
                .zIndex(2)
            ScrollView(.vertical) {
                pageContent
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.never)
            // A page taller than the window used to end in a card sliced flat
            // by the window edge, which reads as a clipped label. The foot of
            // the scroll view fades instead, so the cut is a fade and the card
            // underneath looks like it continues rather than like it is broken.
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(
                        colors: [.black, .black.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 22)
                }
            }
            .zIndex(1)
        }
        .id(selected)
        .transition(pageTransition)
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selected.title)
                    .font(DotTheme.titleFont)
                    .foregroundStyle(DotTheme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 28)
        .frame(height: 64)
        .background(DotTheme.paper)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selected {
        case .general:
            generalPage
        case .provider:
            providerPage
        case .shortcuts:
            shortcutsPage
        case .appearance:
            appearancePage
        case .about:
            aboutPage
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 8)),
            removal: .opacity.combined(with: .offset(x: -8))
        )
    }

    private func select(_ page: Page) {
        guard page != selected else { return }
        let change = {
            selected = page
            hoveredPage = nil
        }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18), change)
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86), change)
        }
    }

    // MARK: - General

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            recordingSection
            outputSection
            microphoneSection
            formattingSection
            historySection
        }
    }

    private var recordingSection: some View {
        SettingsSection("Recording") {
            shortcutRow(
                title: "Start and stop recording",
                keycap: config.hotkey.keycapLabel,
                action: onChangeShortcut,
                hint: "Starts and stops a recording. Escape cancels."
            )
            SettingsDivider()
            shortcutRow(
                title: "Paste last transcript",
                keycap: config.pasteHotkey.keycapLabel,
                action: onChangePasteShortcut,
                hint: "Opens the recorder for the paste shortcut."
            )
            SettingsDivider()
            SettingsRow("Recording mode") {
                DotSelect(
                    label: "Recording mode",
                    options: RecordingMode.allCases.map { mode in
                        DotSelectOption(value: mode, title: mode.title)
                    },
                    selection: recordingModeBinding,
                    width: nil
                )
            }
        }
    }

    private var outputSection: some View {
        SettingsSection("Output") {
            toggleRow(
                title: "Paste into the active app",
                subtitle: "When off, transcripts are copied to the clipboard.",
                isOn: autoPasteBinding
            )
            if config.autoPaste && !Paste.accessibilityGranted {
                SettingsDivider()
                SettingsRow(
                    "Accessibility permission",
                    subtitle: "Pasting into another app needs this permission."
                ) {
                    Button("Grant Access") {
                        Paste.requestAccessibility()
                        SystemAction.openAccessibilitySettings()
                    }
                    .buttonStyle(DotSecondaryButtonStyle())
                }
            }
            SettingsDivider()
            toggleRow(
                title: "Record from the menu bar icon",
                subtitle: "Clicking the icon starts and stops recording instead of opening the menu.",
                isOn: fastRecordBinding
            )
            SettingsDivider()
            toggleRow(
                title: "Open at login",
                subtitle: launchError,
                isOn: launchBinding
            )
            SettingsDivider()
            dwellRow
            SettingsDivider()
            toggleRow(
                title: "Include transcripts in the log",
                subtitle: "Off keeps your words out of Dot.log.",
                isOn: logTranscriptsBinding
            )
        }
    }

    private var microphoneSection: some View {
        SettingsSection("Microphone") {
            SettingsRow("Microphone") {
                DotSelect(
                    label: "Microphone",
                    options: microphoneOptions,
                    selection: microphoneBinding,
                    placeholder: "System default",
                    width: nil
                )
            }
            if let calibration = selectedCalibration {
                SettingsDivider()
                calibrationRow(calibration)
            }
        }
    }

    private var formattingSection: some View {
        SettingsSection("Formatting") {
            toggleRow(
                title: "Format for each app",
                subtitle: "Punctuation and line breaks match the app you dictate into. History keeps your original words.",
                isOn: grammarEnabledBinding
            )
            if config.outputGrammarEnabled {
                SettingsDivider()
                if config.outputGrammarTargets.isEmpty {
                    SettingsRow(
                        "Common apps are formatted automatically",
                        subtitle: "Add an app to choose its style."
                    )
                } else {
                    overrideList
                }
                SettingsDivider()
                addAppRow
            }
        }
    }

    private var historySection: some View {
        SettingsSection("History") {
            SettingsRow("Transcripts to keep") {
                DotSelect(
                    label: "Transcripts to keep",
                    options: Self.historyLimitOptions.map { limit in
                        DotSelectOption(value: limit, title: "\(limit)")
                    },
                    selection: historyLimitBinding,
                    width: nil
                )
            }
        }
    }

    /// The row that says what the meter knows about this microphone, and the
    /// way to forget it.
    private func calibrationRow(_ calibration: MicrophoneCalibration) -> some View {
        SettingsRow(
            "Level meter calibration",
            subtitle: calibrationObservedText(calibration.observedSamples)
        ) {
            Button("Reset") {
                resetCalibration()
            }
            .buttonStyle(DotSecondaryButtonStyle())
            .accessibilityLabel("Reset level meter calibration")
            .accessibilityHint("Forgets what Dot learned about this microphone.")
        }
    }

    /// How many recordings the entry was learned from.
    private func calibrationObservedText(_ count: Int) -> String {
        count == 1
            ? "Based on 1 recording with this microphone"
            : "Based on \(count) recordings with this microphone"
    }

    /// What Dot learned about the microphone the picker selects.
    ///
    /// With the system default chosen, the row describes the device that would
    /// record right now, which is the device a new take would teach. A UID the
    /// system cannot resolve has no row: there is nothing to describe.
    private var selectedCalibration: MicrophoneCalibration? {
        MicrophoneCalibrationBook.calibration(
            for: calibrationDeviceUID,
            in: config.microphoneCalibration
        )
    }

    /// The device the calibration row is about: the chosen one, or the one the
    /// system default resolves to.
    private var calibrationDeviceUID: String? {
        configurationDeviceUID ?? defaultInputUID
    }

    private var configurationDeviceUID: String? {
        let trimmed = config.microphoneDeviceUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Forgets one device, and only that device.
    private func resetCalibration() {
        guard let device = calibrationDeviceUID else { return }
        let next = MicrophoneCalibrationBook.resetting(config.microphoneCalibration, device: device)
        guard next != config.microphoneCalibration else { return }
        config.microphoneCalibration = next
        revision &+= 1
        onChange()
    }

    /// The inputs the microphone list offers: the system default, the device a
    /// configuration names even when it is unplugged, then the inputs that are
    /// here now. The rows come from the same rule as the menu, so the two
    /// surfaces cannot disagree about what is a microphone.
    private var microphoneOptions: [DotSelectOption<String>] {
        MicrophoneDirectory.options(
            devices: microphoneDevices,
            configuredUID: config.microphoneDeviceUID
        ).map { option in
            DotSelectOption(value: option.uid, title: option.name)
        }
    }

    /// One row per app the person has styled, and nothing when there are none.
    @ViewBuilder
    private var overrideList: some View {
        let keys = config.outputGrammarTargets.keys.sorted()
        ForEach(Array(keys.enumerated()), id: \.element) { index, bundleID in
            overrideRow(bundleID)
            if index < keys.count - 1 {
                SettingsDivider()
            }
        }
    }

    private func overrideRow(_ bundleID: String) -> some View {
        let entry = AppCatalog.entry(for: bundleID)
        return SettingsRow(
            entry.title,
            appIcon: entry.icon,
            titleTone: entry.isInstalled ? DotTheme.ink : DotTheme.ink3
        ) {
            HStack(spacing: 8) {
                DotSelect(
                    label: "Style for \(entry.title)",
                    options: grammarOptions,
                    selection: overrideBinding(for: bundleID),
                    placeholder: DictationTarget.plain.title,
                    width: nil
                )
                AppRemoveButton {
                    removeOverride(bundleID)
                }
            }
        }
    }

    private var addAppRow: some View {
        Button(action: addAppStyle) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add app…")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(DotTheme.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .frame(minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose an app to style")
    }

    private var grammarOptions: [DotSelectOption<DictationTarget>] {
        DictationTarget.allCases.map { target in
            DotSelectOption(value: target, title: target.title)
        }
    }

    private var grammarEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.outputGrammarEnabled },
            set: { value in
                guard config.outputGrammarEnabled != value else { return }
                config.outputGrammarEnabled = value
                revision &+= 1
                onChange()
            }
        )
    }

    private func overrideBinding(for bundleID: String) -> Binding<DictationTarget> {
        Binding(
            get: {
                config.outputGrammarTargets[bundleID]
                    ?? DictationTarget.resolved(bundleIdentifier: bundleID)
            },
            set: { value in
                guard config.outputGrammarTargets[bundleID] != value else { return }
                config.outputGrammarTargets[bundleID] = value
                revision &+= 1
                onChange()
            }
        )
    }

    /// Adds the application the person chose, on the style it would get today.
    ///
    /// A duplicate, Dot itself, and a bundle with no identifier are ignored:
    /// the list names apps the frontmost-application signal can report.
    private func addAppStyle() {
        guard let id = AppCatalog.chooseBundleID() else { return }
        guard id != Bundle.main.bundleIdentifier else { return }
        guard config.outputGrammarTargets[id] == nil else { return }
        config.outputGrammarTargets[id] = config.dictationTarget(for: id)
        revision &+= 1
        onChange()
    }

    private func removeOverride(_ bundleID: String) {
        guard config.outputGrammarTargets[bundleID] != nil else { return }
        config.outputGrammarTargets.removeValue(forKey: bundleID)
        revision &+= 1
        onChange()
    }

    /// The retention choices. The list is short on purpose: a picker with twenty
    /// numbers is a text field with extra steps.
    static let historyLimitOptions = [5, 10, 20, 50, 100]

    private var historyLimitBinding: Binding<Int> {
        Binding(
            get: {
                let limit = config.historyLimit
                return Self.historyLimitOptions.contains(limit) ? limit : HistoryStore.limit
            },
            set: { value in
                config.historyLimit = value
                revision &+= 1
                onChange()
            }
        )
    }

    private var dwellRow: some View {
        SettingsRow("Keep result on screen") {
            HStack(spacing: 12) {
                DotModernSlider(
                    value: $liveDwellSeconds,
                    range: HUDDwell.minimumSeconds...HUDDwell.maximumSeconds,
                    step: HUDDwell.step,
                    onCommit: {
                        guard config.hudDwellSeconds != liveDwellSeconds else { return }
                        config.hudDwellSeconds = liveDwellSeconds
                        revision &+= 1
                        onChange()
                    }
                )
                .frame(width: 155)

                Text(dwellText)
                    .font(.system(size: 12))
                    .foregroundStyle(DotTheme.ink2)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    /// The dwell as a person reads it: whole seconds without a decimal, half
    /// seconds with one.
    private var dwellText: String {
        let whole = liveDwellSeconds.rounded()
        if abs(liveDwellSeconds - whole) < 0.05 {
            return String(format: "%.0f s", whole)
        }
        return String(format: "%.1f s", liveDwellSeconds)
    }

    // MARK: - Provider

    private var providerPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            speechEngineSection
            if selectedPreset.hasEndpoint {
                endpointSection
            }
            if paramsSectionApplies {
                parametersSection
            }
            if config.provider == ProviderIdentifier.azure {
                azureOptionsSection
            }
            if config.provider == ProviderIdentifier.deepgram {
                deepgramOptionsSection
            }
            if config.provider == ProviderIdentifier.elevenLabs {
                elevenLabsOptionsSection
            }
            if isCustomOrOwnedEndpoint {
                retentionSection
            }
            if selectedPreset.hasEndpoint {
                longRecordingsSection
            }
            languageSection
            connectionSection
        }
    }

    // MARK: Speech engine

    /// The one card a person needs: the service, its key and the state of the
    /// connection between them.
    private var speechEngineSection: some View {
        SettingsSection("Speech engine") {
            SettingsRow("Service") {
                serviceSelect
            }
            SettingsDivider()
            SettingsRow("API key") {
                HStack(spacing: 8) {
                    SecureField(keyPlaceholder, text: $primaryKey)
                        .modifier(DotFieldStyle(focused: focusedField == .apiKey))
                        .focused($focusedField, equals: .apiKey)
                        .disabled(selectedPreset.key == ProviderPreset.KeyRequirement.none)
                        .onSubmit {
                            connect()
                        }
                        .onChange(of: primaryKey) { _, newKey in
                            let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.count >= 8 {
                                refreshModels()
                            }
                        }
                        .frame(width: 240)
                        .accessibilityLabel("API key")
                        .accessibilityHint("The key for the chosen service. It is stored in the Keychain.")

                    Button(connectingPrimary ? "Connecting…" : connectTitle) {
                        connect()
                    }
                    .buttonStyle(DotPrimaryButtonStyle())
                    .disabled(!canConnect)
                    .accessibilityHint("Stores the key in the macOS Keychain and selects the service.")

                    if hasStoredKey(selectedPreset) && selectedPreset.key != .none {
                        Button(role: .destructive) {
                            deleteKey(for: selectedPreset)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DotTheme.coral)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete the stored key")
                        .accessibilityLabel("Delete the stored key from the Keychain")
                    }
                }
            }
            SettingsDivider()
            SettingsRow(
                "Status",
                subtitle: keyStatus?.detail,
                subtitleTone: keyStatus?.tone.color ?? DotTheme.ink3
            ) {
                statusChip
            }
        }
    }

    /// The service the configuration presents, and the state of its key.
    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isServiceConnected ? DotTheme.switchOn : DotTheme.ink3)
                .frame(width: 6, height: 6)
            Text(isServiceConnected ? "Connected" : "Not connected")
                .font(.system(size: 11.5))
                .foregroundStyle(isServiceConnected ? DotTheme.ink2 : DotTheme.ink3)
        }
        .accessibilityElement(children: .combine)
    }

    private var isServiceConnected: Bool {
        if selectedPreset.key == .none { return true }
        return hasStoredKey(selectedPreset)
    }

    /// The picker of the speech engine: one row per service Dot can reach.
    ///
    /// Its rows come from ``ProviderPreset/rows(for:)``, so an endpoint Dot
    /// ships no row for is still presented, as the custom row that owns it.
    private var serviceSelect: some View {
        DotSelect(
            label: "Service",
            options: ProviderPreset.rows(for: config).map { preset in
                DotSelectOption(
                    value: preset.id,
                    title: preset.name,
                    detail: presetDetail(preset),
                    symbol: preset.symbol
                )
            },
            selection: serviceBinding,
            placeholder: "Choose a service",
            width: 220
        )
    }

    /// Writes the chosen row into the configuration.
    ///
    /// The rows are read again here rather than captured: a row that presents a
    /// stored provider only exists for the configuration that owns it.
    private var serviceBinding: Binding<String> {
        Binding(
            get: { selectedPreset.id },
            set: { id in
                guard let preset = ProviderPreset.rows(for: config).first(where: { $0.id == id }) else {
                    return
                }
                choose(preset)
            }
        )
    }

    /// What the primary button of the speech engine card says.
    private var connectTitle: String {
        selectedPreset.key == .none ? "Use" : "Connect"
    }

    /// The placeholder of the key field: about the key, never about a vendor.
    private var keyPlaceholder: String {
        let preset = selectedPreset
        switch preset.key {
        case .none:
            return "No key needed"
        case .optional:
            return hasStoredKey(preset) ? "Replace the API key" : "API key (optional)"
        case .required:
            return hasStoredKey(preset) ? "Replace the API key" : "API key"
        }
    }

    private var trimmedPrimaryKey: String {
        primaryKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the Connect button can do something.
    private var canConnect: Bool {
        guard !connectingPrimary else { return false }
        if selectedPreset.key == .required {
            return !trimmedPrimaryKey.isEmpty
        }
        return true
    }

    /// Whether the Keychain holds a key for a row.
    private func hasStoredKey(_ preset: ProviderPreset) -> Bool {
        savedProviders.contains(preset.providerID)
            || providers.first { $0.providerID == preset.providerID }?.hasKey == true
    }

    /// Stores the key of the chosen service and selects it.
    ///
    /// The Keychain callback runs first, so a refused key leaves the
    /// configuration exactly as it was.
    private func connect() {
        guard canConnect else { return }
        let preset = selectedPreset
        let secret = trimmedPrimaryKey
        connectingPrimary = true
        keyStatus = nil
        testResult = nil
        focusedField = nil
        defer { connectingPrimary = false }

        if preset.key != .none, !secret.isEmpty {
            if let message = onSetAPIKey(secret, preset.providerID) {
                keyStatus = KeyStatus(text: "Not connected", detail: message, tone: .bad)
                focusedField = .apiKey
                return
            }
            savedProviders.insert(preset.providerID)
        }

        preset.apply(to: &config)
        primaryKey = ""
        keyStatus = KeyStatus(
            text: preset.key == .none ? "Selected" : "Connected",
            detail: nil,
            tone: .good
        )
        refreshModels()
        updateLanguageForModel(currentConfiguredModel)
    }

    private func deleteKey(for preset: ProviderPreset) {
        if let error = onDeleteAPIKey(preset.providerID) {
            keyStatus = KeyStatus(text: "Not connected", detail: error, tone: .bad)
        } else {
            savedProviders.remove(preset.providerID)
            primaryKey = ""
            keyStatus = KeyStatus(text: "Key deleted", detail: nil, tone: .neutral)
            revision += 1
            onChange()
        }
    }

    // MARK: Endpoint

    private var endpointSection: some View {
        SettingsSection("Endpoint") {
            if config.provider == ProviderIdentifier.azure {
                azureEndpointRows
            } else {
                SettingsRow("Base URL") {
                    TextField(baseURLPlaceholder, text: baseURLBinding)
                        .modifier(DotFieldStyle(focused: focusedField == .baseURL))
                        .focused($focusedField, equals: .baseURL)
                        .frame(width: 300)
                        .accessibilityLabel("Base URL")
                }
                SettingsDivider()
                SettingsRow("Model", subtitle: modelRowNote) {
                    HStack(spacing: 8) {
                        if hasModelsKey {
                            if isLoadingModels {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                                    .frame(width: 20, height: 20)
                            } else {
                                Button {
                                    refreshModels()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(DotTheme.ink2)
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Load the model list from the service")
                                .accessibilityLabel("Load the model list from the service")
                            }
                        }
                        if hasModelChoices {
                            DotSelect(
                                label: "Model",
                                options: modelOptions,
                                selection: currentModelSelectionBinding,
                                placeholder: "No model",
                                width: 220,
                                isEnabled: !availableModels.isEmpty
                            )
                        }
                    }
                }
                if isCustomModelSelected {
                    SettingsDivider()
                    SettingsRow("Custom model") {
                        TextField("Model ID", text: modelBinding)
                            .modifier(DotFieldStyle(focused: focusedField == .model))
                            .focused($focusedField, equals: .model)
                            .frame(width: 300)
                            .accessibilityLabel("Custom model ID")
                    }
                }
            }
        }
    }

    /// The Azure endpoint is not a field: the region and the mode produce it.
    @ViewBuilder
    private var azureEndpointRows: some View {
        SettingsRow("Region") {
            DotSelect(
                label: "Region",
                options: AzureSpeechProvider.supportedRegions.map { item in
                    DotSelectOption(value: item.id, title: item.title)
                },
                selection: azureRegionBinding,
                placeholder: AzureSpeechProvider.defaultRegion,
                width: 220
            )
        }
        SettingsDivider()
        SettingsRow("Mode") {
            DotSelect(
                label: "Mode",
                options: AzureSpeechProvider.supportedModes.map { item in
                    DotSelectOption(value: item.id, title: item.title, detail: item.detail)
                },
                selection: azureModeBinding,
                placeholder: AzureSpeechProvider.defaultRecognitionMode,
                width: 220
            )
        }
        SettingsDivider()
        SettingsRow("Endpoint", subtitle: "Built from the region and the mode") {
            Text(config.settings(for: ProviderIdentifier.azure).baseURL ?? baseURLPlaceholder)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DotTheme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360, alignment: .trailing)
                .textSelection(.enabled)
        }
    }

    /// The one line under the model picker, in the states that need one.
    private var modelRowNote: String? {
        if isLoadingModels { return "Loading models..." }
        if !hasModelsKey {
            return "Add an API key to load the model list."
        }
        if availableModels.isEmpty { return "The service returned no models." }
        return nil
    }

    private var hasModelsKey: Bool {
        if !trimmedPrimaryKey.isEmpty { return true }
        if hasStoredKey(selectedPreset) { return true }
        return CredentialCache.shared.key(for: config.provider).map { !$0.isEmpty } ?? false
    }

    /// Whether the picker has a real model to name: a configured one counts,
    /// a list that came back empty does not.
    private var hasModelChoices: Bool {
        !modelOptions.isEmpty
    }

    private var modelOptions: [DotSelectOption<String>] {
        var options = availableModels.map { m in
            DotSelectOption(value: m.id, title: m.name)
        }
        let current = config.settings(for: config.provider).model?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !current.isEmpty, !options.contains(where: { $0.value == current }) {
            options.insert(
                DotSelectOption(value: current, title: ProviderModelCatalog.formattedName(for: current)),
                at: 0
            )
        }
        if !options.isEmpty {
            options.append(DotSelectOption(value: "__custom__", title: "Custom model…"))
        }
        return options
    }

    private var currentModelSelectionBinding: Binding<String> {
        Binding(
            get: {
                if isCustomModelSelected { return "__custom__" }
                let current = config.settings(for: config.provider).model?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !current.isEmpty { return current }
                if let first = availableModels.first { return first.id }
                return "__custom__"
            },
            set: { value in
                if value == "__custom__" {
                    isCustomModelSelected = true
                } else {
                    isCustomModelSelected = false
                    var settings = config.settings(for: config.provider)
                    settings.model = value
                    config.providers[config.provider] = settings
                    revision &+= 1
                    onChange()
                    updateLanguageForModel(value)
                }
            }
        )
    }

    private func updateLanguageForModel(_ model: String?) {
        let currentRaw = config.settings(for: config.provider).language
        let validated = ProviderLanguageCatalog.validatedLanguage(currentRaw, for: config.provider, model: model)
        let newStored = validated == "auto" ? nil : validated
        if currentRaw != newStored {
            var settings = config.settings(for: config.provider)
            settings.language = newStored
            config.providers[config.provider] = settings
            revision &+= 1
            onChange()
        }
    }

    private func refreshModels() {
        let providerID = config.provider
        guard providerID != ProviderIdentifier.apple else { return }
        isLoadingModels = true
        let key = trimmedPrimaryKey.isEmpty ? CredentialCache.shared.key(for: providerID) : trimmedPrimaryKey
        let baseURLStr = config.settings(for: providerID).baseURL
        let baseURL = (baseURLStr != nil && !baseURLStr!.isEmpty) ? URL(string: baseURLStr!) : nil
        let authStyle = config.settings(for: providerID).authStyle

        Task {
            let fetched = await ProviderModelCatalog.fetchModels(
                for: providerID,
                baseURL: baseURL,
                apiKey: key,
                authStyle: authStyle
            )
            await MainActor.run {
                self.availableModels = fetched
                self.isLoadingModels = false
                let current = self.config.settings(for: providerID).model?.trimmingCharacters(in: .whitespacesAndNewlines)
                if (current == nil || current?.isEmpty == true), let first = fetched.first {
                    var settings = self.config.settings(for: providerID)
                    settings.model = first.id
                    self.config.providers[providerID] = settings
                    self.revision &+= 1
                    self.onChange()
                }
                self.updateLanguageForModel(self.currentConfiguredModel)
            }
        }
    }

    // MARK: Advanced

    /// Whether the Advanced card has anything to show for this service.
    private var paramsSectionApplies: Bool {
        ProviderRegistry.isGenericEndpoint(config: config)
            || config.provider == ProviderIdentifier.groq
            || config.provider == ProviderIdentifier.openAI
    }

    private var parametersSection: some View {
        SettingsSection("Advanced") {
            if ProviderRegistry.isGenericEndpoint(config: config) {
                SettingsRow("Auth header") {
                    DotSelect(
                        label: "Auth header",
                        options: [
                            DotSelectOption(value: AuthStyle.bearer, title: "Authorization: Bearer"),
                            DotSelectOption(value: AuthStyle.apiKey, title: "api-key header"),
                        ],
                        selection: authStyleBinding,
                        width: 220
                    )
                }
            }
            if config.provider == ProviderIdentifier.groq || config.provider == ProviderIdentifier.openAI {
                if ProviderRegistry.isGenericEndpoint(config: config) {
                    SettingsDivider()
                }
                SettingsRow("Temperature") {
                    DotSelect(
                        label: "Temperature",
                        options: temperatureOptions,
                        selection: temperatureBinding,
                        width: 220
                    )
                }
                SettingsDivider()
                SettingsRow("Response format") {
                    DotSelect(
                        label: "Response format",
                        options: responseFormatOptions,
                        selection: responseFormatBinding,
                        width: 220
                    )
                }
                if responseFormatBinding.wrappedValue == "verbose_json" {
                    SettingsDivider()
                    SettingsRow("Timestamp granularity") {
                        DotSelect(
                            label: "Timestamp granularity",
                            options: granularityOptions,
                            selection: granularityBinding,
                            width: 220
                        )
                    }
                }
                SettingsDivider()
                SettingsRow("Vocabulary hint", subtitle: "Sent with each request to help spelling.") {
                    TextField("Names, acronyms and terms you use", text: promptBinding)
                        .modifier(DotFieldStyle(focused: focusedField == .groqPrompt))
                        .focused($focusedField, equals: .groqPrompt)
                        .frame(width: 260)
                        .accessibilityLabel("Vocabulary hint")
                }
            }
        }
    }

    private var temperatureOptions: [DotSelectOption<Double>] {
        [
            DotSelectOption(value: 0.0, title: "0 (most consistent)"),
            DotSelectOption(value: 0.2, title: "0.2"),
            DotSelectOption(value: 0.5, title: "0.5"),
            DotSelectOption(value: 0.8, title: "0.8"),
            DotSelectOption(value: 1.0, title: "1.0 (most varied)"),
        ]
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { config.settings(for: config.provider).temperature ?? 0.0 },
            set: { value in
                var settings = config.settings(for: config.provider)
                settings.temperature = value
                config.providers[config.provider] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var responseFormatOptions: [DotSelectOption<String>] {
        [
            DotSelectOption(value: "json", title: "JSON"),
            DotSelectOption(value: "verbose_json", title: "Verbose JSON with timestamps"),
            DotSelectOption(value: "text", title: "Plain text"),
        ]
    }

    private var responseFormatBinding: Binding<String> {
        Binding(
            get: { config.settings(for: config.provider).responseFormat ?? "json" },
            set: { value in
                var settings = config.settings(for: config.provider)
                settings.responseFormat = value
                config.providers[config.provider] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var granularityOptions: [DotSelectOption<String>] {
        [
            DotSelectOption(value: "segment", title: "Segment"),
            DotSelectOption(value: "word", title: "Word"),
            DotSelectOption(value: "both", title: "Word and segment"),
        ]
    }

    private var granularityBinding: Binding<String> {
        Binding(
            get: { config.settings(for: config.provider).timestampsGranularity ?? "segment" },
            set: { value in
                var settings = config.settings(for: config.provider)
                settings.timestampsGranularity = value
                config.providers[config.provider] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { config.settings(for: config.provider).prompt ?? "" },
            set: { value in
                var settings = config.settings(for: config.provider)
                settings.prompt = value.isEmpty ? nil : value
                config.providers[config.provider] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    // MARK: Service options

    private var azureOptionsSection: some View {
        SettingsSection("Recognition") {
            SettingsRow("Profanity filter") {
                DotSelect(
                    label: "Profanity filter",
                    options: AzureSpeechProvider.supportedProfanityModes.map { item in
                        DotSelectOption(value: item.id, title: item.title, detail: item.detail)
                    },
                    selection: azureProfanityBinding,
                    placeholder: AzureSpeechProvider.defaultProfanityFilter,
                    width: 220
                )
            }
            SettingsDivider()
            SettingsRow("Output format", subtitle: "Detailed adds casing and punctuation") {
                DotSelect(
                    label: "Output format",
                    options: AzureSpeechProvider.supportedOutputFormats.map { item in
                        DotSelectOption(value: item.id, title: item.title, detail: item.detail)
                    },
                    selection: azureOutputFormatBinding,
                    placeholder: AzureSpeechProvider.defaultOutputFormat,
                    width: 220
                )
            }
            SettingsDivider()
            toggleRow(
                title: "Store audio in Azure",
                subtitle: "Azure keeps the audio after transcription.",
                isOn: azureStoreAudioBinding
            )
        }
    }

    private var deepgramOptionsSection: some View {
        SettingsSection("Transcription") {
            toggleRow(
                title: "Smart formatting",
                subtitle: "Dates, times, currency, emails and phone numbers.",
                isOn: deepgramBoolBinding(\.smartFormat, default: true)
            )
            SettingsDivider()
            toggleRow(
                title: "Punctuation and casing",
                isOn: deepgramBoolBinding(\.punctuate, default: true)
            )
            SettingsDivider()
            toggleRow(
                title: "Paragraph breaks",
                isOn: deepgramBoolBinding(\.paragraphs, default: false)
            )
            SettingsDivider()
            toggleRow(
                title: "Numbers as digits",
                isOn: deepgramBoolBinding(\.numerals, default: false)
            )
            SettingsDivider()
            toggleRow(
                title: "Filler words",
                subtitle: "Hesitations such as uh and um are kept.",
                isOn: deepgramBoolBinding(\.fillerWords, default: false)
            )
            SettingsDivider()
            toggleRow(
                title: "Profanity filter",
                isOn: deepgramBoolBinding(\.profanityFilter, default: false)
            )
            SettingsDivider()
            toggleRow(
                title: "Speakers",
                subtitle: "Each speaker is labelled in multi-person audio.",
                isOn: deepgramBoolBinding(\.diarize, default: false)
            )
            SettingsDivider()
            toggleRow(
                title: "Opt out of model training",
                subtitle: "Audio and transcripts are not kept for training.",
                isOn: zdrBinding
            )
            SettingsDivider()
            SettingsRow("Keyterms", subtitle: "Names and terms the service should expect.") {
                TextField("Names and terms, comma separated", text: deepgramKeytermsBinding)
                    .modifier(DotFieldStyle(focused: focusedField == .keyterms))
                    .focused($focusedField, equals: .keyterms)
                    .frame(width: 260)
                    .accessibilityLabel("Keyterms")
            }
        }
    }

    private var elevenLabsOptionsSection: some View {
        SettingsSection("Transcription") {
            toggleRow(
                title: "Clean verbatim",
                subtitle: "Hesitations, stutters and false starts are removed.",
                isOn: elevenLabsBoolBinding(\.noVerbatim, default: false)
            )
            SettingsDivider()
            toggleRow(
                title: "Audio events",
                subtitle: "Tags such as (laughter) and (applause) are kept.",
                isOn: elevenLabsBoolBinding(\.tagAudioEvents, default: false)
            )
            SettingsDivider()
            toggleRow(
                title: "No server-side logging",
                subtitle: "ElevenLabs does not log or keep audio.",
                isOn: zdrBinding
            )
            SettingsDivider()
            toggleRow(
                title: "Speakers",
                subtitle: "Up to 32 speakers in multi-person audio.",
                isOn: elevenLabsBoolBinding(\.diarize, default: false)
            )
            if config.settings(for: ProviderIdentifier.elevenLabs).diarize == true {
                SettingsDivider()
                SettingsRow("Max speakers", subtitle: "1 to 32, or Auto.") {
                    TextField("Auto", text: elevenLabsNumSpeakersBinding)
                        .modifier(DotFieldStyle(focused: focusedField == .numSpeakers))
                        .focused($focusedField, equals: .numSpeakers)
                        .frame(width: 84)
                        .accessibilityLabel("Maximum speakers")
                }
                SettingsDivider()
                toggleRow(
                    title: "Detect speaker roles",
                    subtitle: "Speakers are labelled agent and customer.",
                    isOn: elevenLabsBoolBinding(\.detectSpeakerRoles, default: false)
                )
                SettingsDivider()
                toggleRow(
                    title: "Speaker library",
                    subtitle: "Matched against voices saved in your workspace.",
                    isOn: elevenLabsBoolBinding(\.useSpeakerLibrary, default: false)
                )
            }
            SettingsDivider()
            SettingsRow("Timestamps", subtitle: "Word or character timing.") {
                DotSelect(
                    label: "Timestamps",
                    options: ElevenLabsProvider.granularityOptions.map { item in
                        DotSelectOption(value: item.id, title: item.title)
                    },
                    selection: elevenLabsGranularityBinding,
                    width: 220
                )
            }
            SettingsDivider()
            SettingsRow("Sensitive data", subtitle: "Flags PII, PHI, card numbers and offensive language.") {
                DotSelect(
                    label: "Sensitive data",
                    options: ElevenLabsProvider.entityDetectionOptions.map { item in
                        DotSelectOption(value: item.id, title: item.title)
                    },
                    selection: elevenLabsEntityDetectionBinding,
                    width: 220
                )
            }
            SettingsDivider()
            SettingsRow("Keyterms", subtitle: "Names and terms the service should expect.") {
                TextField("Names and terms, comma separated", text: elevenLabsKeytermsBinding)
                    .modifier(DotFieldStyle(focused: focusedField == .keyterms))
                    .focused($focusedField, equals: .keyterms)
                    .frame(width: 260)
                    .accessibilityLabel("Keyterms")
            }
            SettingsDivider()
            SettingsRow("Formatting notes", subtitle: "Formatting to prefer, such as ISO dates.") {
                TextField("Formatting to prefer", text: elevenLabsTranscriptEditBinding)
                    .modifier(DotFieldStyle(focused: focusedField == .transcriptEdit))
                    .focused($focusedField, equals: .transcriptEdit)
                    .frame(width: 260)
                    .accessibilityLabel("Formatting notes")
            }
        }
    }

    // MARK: Retention, requests, language, connection

    private var isCustomOrOwnedEndpoint: Bool {
        selectedPreset.id == ProviderPreset.custom.id
            || (ProviderRegistry.isGenericEndpoint(config: config) && config.provider != ProviderIdentifier.openAI)
    }

    private var retentionSection: some View {
        SettingsSection("Retention") {
            SettingsRow(
                "Retention is set by the endpoint",
                subtitle: "The endpoint decides how long it keeps the audio. Dot keeps none.",
                symbol: "server.rack"
            )
        }
    }

    private var longRecordingsSection: some View {
        SettingsSection("Long recordings") {
            SettingsRow("Send long recordings in parts of") {
                DotSelect(
                    label: "Send long recordings in parts of",
                    options: Self.segmentOptions.map { seconds in
                        DotSelectOption(
                            value: seconds,
                            title: seconds == 0 ? "Service default" : "\(seconds) s"
                        )
                    },
                    selection: segmentBinding,
                    width: 220
                )
            }
        }
    }

    /// The segment lengths a provider can be capped at, in seconds. Zero leaves
    /// the request at what the provider documents.
    static let segmentOptions = [0, 15, 30, 60, 120]

    private var segmentBinding: Binding<Int> {
        Binding(
            get: {
                let stored = config.maxSegmentSeconds
                return Self.segmentOptions.contains(stored) ? stored : 0
            },
            set: { value in
                config.maxSegmentSeconds = value
                revision &+= 1
                onChange()
            }
        )
    }

    private var availableLanguages: [AvailableLanguage] {
        ProviderLanguageCatalog.languages(for: config.provider, model: currentConfiguredModel)
    }

    private var currentConfiguredModel: String? {
        let m = config.settings(for: config.provider).model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let m, !m.isEmpty { return m }
        return selectedPreset.model
    }

    private var languageSubtitle: String? {
        if let model = currentConfiguredModel?.lowercased(), model.contains("-en") {
            return "English-only model"
        }
        return nil
    }

    private var languageSection: some View {
        SettingsSection("Language") {
            SettingsRow("Spoken language", subtitle: languageSubtitle) {
                DotSelect(
                    label: "Spoken language",
                    options: availableLanguages.map { language in
                        DotSelectOption(value: language.id, title: language.name, detail: language.detail)
                    },
                    selection: languageBinding,
                    width: 220
                )
            }
        }
    }

    private var connectionSection: some View {
        SettingsSection("Connection") {
            SettingsRow(
                "Test connection",
                subtitle: testResult?.text,
                subtitleTone: testResult.map { $0.ok ? DotTheme.ink3 : DotTheme.coral } ?? DotTheme.ink3
            ) {
                Button(testing ? "Testing…" : "Test") {
                    runTest()
                }
                .buttonStyle(DotSecondaryButtonStyle())
                .disabled(testing)
                .accessibilityHint("Asks the chosen service whether it can transcribe right now.")
            }
        }
    }

    private func runTest() {
        guard !testing else { return }
        let preset = selectedPreset
        testing = true
        testResult = nil
        Task { @MainActor in
            let ok = await onTest(preset.providerID)
            testResult = TestResult(
                text: ok ? "Connected." : "No answer. Check the service and the key.",
                ok: ok
            )
            testing = false
        }
    }

    /// The one line under a service name in the picker.
    private func presetDetail(_ preset: ProviderPreset) -> String? {
        if !preset.hasEndpoint { return "On this Mac" }
        let currentModel = config.settings(for: preset.providerID).model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let currentModel, !currentModel.isEmpty {
            return ProviderModelCatalog.formattedName(for: currentModel)
        }
        if preset.key == .required {
            return "Requires API key"
        }
        if preset.name == customEndpointName { return nil }
        return customEndpointName
    }

    /// What a hand-filled row is called when it has no host to name it after.
    private var customEndpointName: String { "Custom endpoint" }

    private var authStyleBinding: Binding<AuthStyle> {
        Binding(
            get: { config.settings(for: config.provider).authStyle ?? .bearer },
            set: { value in
                var settings = config.settings(for: config.provider)
                settings.authStyle = value
                config.providers[config.provider] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private func deepgramBoolBinding(
        _ keyPath: WritableKeyPath<ProviderConfig, Bool?>,
        default defaultValue: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.deepgram)[keyPath: keyPath] ?? defaultValue },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.deepgram)
                settings[keyPath: keyPath] = value
                config.providers[ProviderIdentifier.deepgram] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var deepgramKeytermsBinding: Binding<String> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.deepgram).keyterms ?? "" },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.deepgram)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.keyterms = trimmed.isEmpty ? nil : value
                config.providers[ProviderIdentifier.deepgram] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private func elevenLabsBoolBinding(
        _ keyPath: WritableKeyPath<ProviderConfig, Bool?>,
        default defaultValue: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.elevenLabs)[keyPath: keyPath] ?? defaultValue },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.elevenLabs)
                settings[keyPath: keyPath] = value
                config.providers[ProviderIdentifier.elevenLabs] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var elevenLabsKeytermsBinding: Binding<String> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.elevenLabs).keyterms ?? "" },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.elevenLabs)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.keyterms = trimmed.isEmpty ? nil : value
                config.providers[ProviderIdentifier.elevenLabs] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var elevenLabsTranscriptEditBinding: Binding<String> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.elevenLabs).transcriptEdit ?? "" },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.elevenLabs)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.transcriptEdit = trimmed.isEmpty ? nil : value
                config.providers[ProviderIdentifier.elevenLabs] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var elevenLabsNumSpeakersBinding: Binding<String> {
        Binding(
            get: {
                if let n = config.settings(for: ProviderIdentifier.elevenLabs).numSpeakers {
                    return String(n)
                }
                return ""
            },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.elevenLabs)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let parsed = Int(trimmed), (1...32).contains(parsed) {
                    settings.numSpeakers = parsed
                } else {
                    settings.numSpeakers = nil
                }
                config.providers[ProviderIdentifier.elevenLabs] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var elevenLabsGranularityBinding: Binding<String> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.elevenLabs).timestampsGranularity ?? "word" },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.elevenLabs)
                settings.timestampsGranularity = value
                config.providers[ProviderIdentifier.elevenLabs] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var elevenLabsEntityDetectionBinding: Binding<String> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.elevenLabs).entityDetection ?? "" },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.elevenLabs)
                settings.entityDetection = value.isEmpty ? nil : value
                config.providers[ProviderIdentifier.elevenLabs] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var azureRegionBinding: Binding<String> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.azure).azureRegion ?? AzureSpeechProvider.defaultRegion },
            set: { newRegion in
                var settings = config.settings(for: ProviderIdentifier.azure)
                settings.azureRegion = newRegion
                let mode = settings.azureRecognitionMode ?? AzureSpeechProvider.defaultRecognitionMode
                settings.baseURL = "https://\(newRegion).stt.speech.microsoft.com/speech/recognition/\(mode)/cognitiveservices/v1"
                config.providers[ProviderIdentifier.azure] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var azureModeBinding: Binding<String> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.azure).azureRecognitionMode ?? AzureSpeechProvider.defaultRecognitionMode },
            set: { newMode in
                var settings = config.settings(for: ProviderIdentifier.azure)
                settings.azureRecognitionMode = newMode
                let region = settings.azureRegion ?? AzureSpeechProvider.defaultRegion
                settings.baseURL = "https://\(region).stt.speech.microsoft.com/speech/recognition/\(newMode)/cognitiveservices/v1"
                config.providers[ProviderIdentifier.azure] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var azureProfanityBinding: Binding<String> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.azure).azureProfanityFilter ?? AzureSpeechProvider.defaultProfanityFilter },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.azure)
                settings.azureProfanityFilter = value
                config.providers[ProviderIdentifier.azure] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var azureOutputFormatBinding: Binding<String> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.azure).azureOutputFormat ?? AzureSpeechProvider.defaultOutputFormat },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.azure)
                settings.azureOutputFormat = value
                config.providers[ProviderIdentifier.azure] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var azureStoreAudioBinding: Binding<Bool> {
        Binding(
            get: { config.settings(for: ProviderIdentifier.azure).azureStoreAudio ?? false },
            set: { value in
                var settings = config.settings(for: ProviderIdentifier.azure)
                settings.azureStoreAudio = value
                config.providers[ProviderIdentifier.azure] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var zdrBinding: Binding<Bool> {
        Binding(
            get: { config.settings(for: config.provider).zeroDataRetention ?? true },
            set: { value in
                var settings = config.settings(for: config.provider)
                settings.zeroDataRetention = value
                config.providers[config.provider] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var baseURLBinding: Binding<String> {
        endpointBinding(keyPath: \.baseURL)
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { config.settings(for: config.provider).model ?? "" },
            set: { value in
                var settings = config.settings(for: config.provider)
                settings.model = value.isEmpty ? nil : value
                config.providers[config.provider] = settings
                revision &+= 1
                onChange()
                updateLanguageForModel(settings.model)
            }
        )
    }

    private var baseURLPlaceholder: String {
        selectedPreset.baseURL ?? "https://…/v1"
    }

    private func endpointBinding(
        keyPath: WritableKeyPath<ProviderConfig, String?>
    ) -> Binding<String> {
        Binding(
            get: { config.settings(for: config.provider)[keyPath: keyPath] ?? "" },
            set: { value in
                var settings = config.settings(for: config.provider)
                settings[keyPath: keyPath] = value.isEmpty ? nil : value
                config.providers[config.provider] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    /// Applies a row and moves the keyboard to the field the user has to fill
    /// in next.
    private func choose(_ preset: ProviderPreset) {
        keyStatus = nil
        testResult = nil
        let wasCustom = selectedPreset.id == ProviderPreset.custom.id
        if preset.id == ProviderPreset.custom.id, !wasCustom {
            var settings = config.settings(for: preset.providerID)
            settings.baseURL = nil
            config.providers[preset.providerID] = settings
        }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                preset.apply(to: &config)
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                preset.apply(to: &config)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if !preset.hasEndpoint {
                focusedField = nil
            } else if preset.id == ProviderPreset.custom.id {
                focusedField = .baseURL
            } else {
                focusedField = .apiKey
            }
        }
    }

    /// The row the configuration presents.
    ///
    /// The selection is derived from the configuration, never stored: a URL the
    /// user types is exactly what the custom row means.
    private var selectedPreset: ProviderPreset {
        ProviderPreset.presenting(config)
    }

    // MARK: - Shortcuts

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Global shortcuts") {
                shortcutRow(
                    title: "Start and stop recording",
                    keycap: config.hotkey.keycapLabel,
                    action: onChangeShortcut,
                    hint: "Starts and stops a recording. Escape cancels."
                )
                SettingsDivider()
                shortcutRow(
                    title: "Paste last transcript",
                    keycap: config.pasteHotkey.keycapLabel,
                    action: onChangePasteShortcut,
                    hint: "Opens the recorder for the paste shortcut."
                )
                SettingsDivider()
                shortcutRow(
                    title: "Open dictation palette",
                    keycap: config.paletteHotkey.keycapLabel,
                    action: onChangePaletteShortcut,
                    hint: "Opens the recorder for the palette shortcut."
                )
            }
        }
    }

    // MARK: - Appearance

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Window appearance") {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        appearanceCard(mode)
                    }
                }
                .padding(.vertical, 9)
            }

            SettingsSection("Recording card material") {
                HStack(alignment: .top, spacing: 10) {
                    materialCard(.glass, name: "Glass")
                    materialCard(.black, name: "Black")
                }
                .padding(.vertical, 9)
            }

            SettingsSection("Waveform") {
                visualizerSection
                    .padding(.vertical, 9)
            }
        }
    }

    private func appearanceCard(_ mode: AppearanceMode) -> some View {
        let isSelected = config.appearance == mode
        return Button {
            selectAppearance(mode)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                AppearanceSwatch(mode: mode)
                HStack(alignment: .top, spacing: 8) {
                    Text(appearanceName(mode))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DotTheme.ink)
                    Spacer(minLength: 2)
                    selectionIndicator(isSelected)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background(tileFill(isSelected))
            .overlay(tileBorder(isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(appearanceName(mode)) window appearance")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(appearanceHint(mode))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func appearanceName(_ mode: AppearanceMode) -> String {
        switch mode {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private func appearanceHint(_ mode: AppearanceMode) -> String {
        switch mode {
        case .system: "Follows the Mac's light or dark appearance."
        case .light: "Always uses the warm paper palette."
        case .dark: "Always uses the deep ink palette."
        }
    }

    private func selectAppearance(_ mode: AppearanceMode) {
        guard config.appearance != mode else { return }
        AppearanceTrace.pickAt = CACurrentMediaTime()
        config.appearance = mode
        revision &+= 1
        onChange()
    }

    private func materialCard(_ material: HUDMaterial, name: String) -> some View {
        let isSelected = config.hudMaterial == material
        return Button {
            guard config.hudMaterial != material else { return }
            if reduceMotion {
                config.hudMaterial = material
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    config.hudMaterial = material
                }
            }
            revision &+= 1
            onChange()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HUDSwatch(material: material)
                HStack(alignment: .top, spacing: 8) {
                    Text(name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DotTheme.ink)
                    Spacer(minLength: 2)
                    selectionIndicator(isSelected)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background(tileFill(isSelected))
            .overlay(tileBorder(isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) recording card material")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Uses the \(name.lowercased()) material for the recording card.")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var visualizerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                visualizerCard(.stretch)
                visualizerCard(.filament)
                visualizerCard(.silk)
            }
            HStack(spacing: 8) {
                visualizerCard(.matrix)
                visualizerCard(.haloEdge)
            }
        }
    }

    private func visualizerCard(_ visualizer: HUDVisualizer) -> some View {
        let isSelected = config.hudVisualizer == visualizer
        return Button {
            guard config.hudVisualizer != visualizer else { return }
            if reduceMotion {
                config.hudVisualizer = visualizer
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    config.hudVisualizer = visualizer
                }
            }
            revision &+= 1
            onChange()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                VisualizerSwatch(visualizer: visualizer)
                HStack(alignment: .top, spacing: 8) {
                    Text(visualizer.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DotTheme.ink)
                    Spacer(minLength: 2)
                    selectionIndicator(isSelected)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(tileFill(isSelected))
            .overlay(tileBorder(isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(visualizer.title) waveform")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(visualizer.detail)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The fill and border every choice tile shares, so the three groups on the
    /// page read as one control family.
    private func tileFill(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? DotTheme.cardSelectedFill : DotTheme.cardFill)
    }

    private func tileBorder(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                isSelected ? DotTheme.cardBorderSelected : DotTheme.cardBorder,
                lineWidth: isSelected ? 1.5 : 1
            )
    }

    // MARK: - About

    private var aboutPage: some View {
        AboutPage(
            version: version,
            build: buildNumber,
            previewUpdate: aboutUpdatePreview,
            onOpenWelcome: onOpenWelcome,
            onOpenLog: { SystemAction.revealLog() }
        )
    }

    // MARK: - Pieces

    private func shortcutRow(
        title: String,
        keycap: String,
        action: @escaping () -> Void,
        hint: String
    ) -> some View {
        SettingsRow(title) {
            HStack(spacing: 8) {
                DotKeycap(text: keycap)
                Button("Change…", action: action)
                    .buttonStyle(DotSecondaryButtonStyle())
                    .accessibilityLabel("Change \(title.lowercased()) shortcut")
                    .accessibilityHint(hint)
            }
        }
    }

    private func toggleRow(
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        SettingsRow(title, subtitle: subtitle) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(DotToggleStyle())
                .accessibilityLabel(title)
        }
    }

    private func selectionIndicator(_ selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(selected ? DotTheme.selectionFill : Color.clear)
            Circle()
                .strokeBorder(
                    selected ? Color.clear : DotTheme.selectionRing,
                    lineWidth: 1.2
                )
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DotTheme.onSelection)
            }
        }
        .frame(width: 16, height: 16)
        .animation(.spring(response: 0.26, dampingFraction: 0.75), value: selected)
        .accessibilityHidden(true)
    }

    /// The version the page shows, unless a render supplies one.
    private var version: String {
        versionOverride ?? ProductVersion.current
    }

    /// The build number the page prints.
    ///
    /// A render supplies a version, so it supplies the build that belongs to
    /// it: the number `CFBundleVersion` reports from inside the test bundle is
    /// the test runner's, not Dot's.
    private var buildNumber: String? {
        versionOverride == nil ? AboutInfo.build : "1"
    }

    // MARK: - Bindings

    private var currentLanguageID: String {
        let raw = config.settings(for: config.provider).language
        return ProviderLanguageCatalog.validatedLanguage(raw, for: config.provider, model: currentConfiguredModel)
    }

    private var autoPasteBinding: Binding<Bool> {
        Binding(
            get: { config.autoPaste },
            set: { value in
                guard config.autoPaste != value else { return }
                config.autoPaste = value
                if value, !headless, !Paste.accessibilityGranted {
                    Paste.requestAccessibility()
                }
                revision &+= 1
                onChange()
            }
        )
    }

    private var fastRecordBinding: Binding<Bool> {
        Binding(
            get: { config.fastRecord },
            set: { value in
                guard config.fastRecord != value else { return }
                config.fastRecord = value
                revision &+= 1
                onChange()
            }
        )
    }

    private var logTranscriptsBinding: Binding<Bool> {
        Binding(
            get: { config.logTranscripts },
            set: { value in
                guard config.logTranscripts != value else { return }
                config.logTranscripts = value
                revision &+= 1
                onChange()
            }
        )
    }

    private var recordingModeBinding: Binding<RecordingMode> {
        Binding(
            get: { config.recordingMode },
            set: { value in
                guard config.recordingMode != value else { return }
                config.recordingMode = value
                revision &+= 1
                onChange()
            }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { currentLanguageID },
            set: { value in
                var settings = config.settings(for: config.provider)
                settings.language = value == "auto" ? nil : value
                config.providers[config.provider] = settings
                revision &+= 1
                onChange()
            }
        )
    }

    private var microphoneBinding: Binding<String?> {
        Binding(
            get: { config.microphoneDeviceUID },
            set: { value in
                guard config.microphoneDeviceUID != value else { return }
                config.microphoneDeviceUID = value
                revision &+= 1
                onChange()
            }
        )
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                guard newValue != launchAtLogin else { return }
                do {
                    try LaunchAtLogin.set(newValue)
                    launchAtLogin = newValue
                    launchError = nil
                    revision &+= 1
                    onChange()
                } catch {
                    launchError = error.localizedDescription
                    launchAtLogin = LaunchAtLogin.isEnabled
                    revision &+= 1
                }
            }
        )
    }

    // MARK: - Types

    private enum Field: Hashable {
        case baseURL
        case model
        case apiKey
        case keyterms
        case numSpeakers
        case transcriptEdit
        case groqPrompt
    }

    private enum Page: Int, CaseIterable, Identifiable {
        case general
        case provider
        case shortcuts
        case appearance
        case about

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .provider: "Provider"
            case .shortcuts: "Shortcuts"
            case .appearance: "Appearance"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .provider: "waveform"
            case .shortcuts: "command"
            case .appearance: "circle.lefthalf.filled"
            case .about: "info.circle"
            }
        }

    }

    private struct KeyStatus {
        let text: String
        let detail: String?
        let tone: PrimaryTone
    }

    /// The small palette the primary card uses for its line of status.
    private enum PrimaryTone {
        case good
        case waiting
        case bad
        case neutral

        var color: Color {
            switch self {
            case .good: DotTheme.mint
            case .waiting: DotTheme.amber
            case .bad: DotTheme.coral
            case .neutral: DotTheme.ink3
            }
        }
    }

    private struct TestResult {
        let text: String
        let ok: Bool
    }
}

/// A miniature waveform for HUD appearance swatches: discrete porcelain filament bars
/// with dynamic voice cadence and warm glowing amber accents.
private struct HUDSwatchWaveform: View {
    /// The colour of the bars. A frosted swatch is light, so the same warm
    /// white that reads on the black swatch disappears on it.
    var tint: Color = HUDTheme.accent
    var peak: Color = HUDTheme.live

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<26, id: \.self) { i in
                let norm = Double(i) / 25.0
                let envelope = sin(.pi * norm)
                let harmonic1 = sin(norm * .pi * 3.2 + 0.4) * 0.4 + 0.6
                let harmonic2 = cos(norm * .pi * 5.5 + 0.2) * 0.25 + 0.75
                let h = max(2.8, CGFloat(envelope * harmonic1 * harmonic2) * 23.0)
                let isPeak = h > 13.0

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: isPeak
                                ? [peak.opacity(0.95), tint]
                                : [tint.opacity(0.85), tint.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2.2, height: h)
                    .shadow(color: isPeak ? peak.opacity(0.35) : .clear, radius: 2)
            }
        }
    }
}

/// A slider in the app's own control family: the warm grey track and green fill
/// of the switch, a porcelain knob with the same seat shadow, and a knob that
/// grows under the pointer and further while it is held.
private struct DotModernSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onCommit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragPosition: Double?
    @State private var isDragging: Bool = false
    @State private var isHovering: Bool = false

    private var reducesMotion: Bool {
        reduceMotion || DotMotion.reducesMotion
    }

    private var thumbDiameter: CGFloat { 15 }
    private var trackHeight: CGFloat { 5 }

    /// Writes through the binding and commits, so a change made from the
    /// accessibility slider reaches the configuration the same way a drag does.
    private var committedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                value = newValue
                onCommit()
            }
        )
    }

    private var knobScale: CGFloat {
        guard !reducesMotion else { return 1 }
        if isDragging {
            return 1.14
        }
        return isHovering ? 1.06 : 1
    }

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let usableWidth = max(1, totalWidth - thumbDiameter)
            let currentValue = dragPosition ?? value
            let progress = max(0, min(1, (currentValue - range.lowerBound) / (range.upperBound - range.lowerBound)))
            let thumbX = progress * usableWidth

            ZStack(alignment: .leading) {
                Capsule(style: .circular)
                    .fill(DotTheme.sliderTrack)
                    .overlay(
                        Capsule(style: .circular)
                            .strokeBorder(DotTheme.switchOffEdge, lineWidth: 0.5)
                    )
                    .frame(height: trackHeight)

                Capsule(style: .circular)
                    .fill(
                        LinearGradient(
                            colors: [DotTheme.switchOnTop, DotTheme.switchOn],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(
                        width: max(thumbDiameter / 2, thumbX + thumbDiameter / 2),
                        height: trackHeight
                    )

                Circle()
                    .fill(DotTheme.switchKnob)
                    .shadow(color: DotTheme.switchKnobShadow, radius: 2, x: 0, y: 1)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .scaleEffect(knobScale)
                    .offset(x: thumbX)
                    .animation(
                        reducesMotion ? nil : .spring(response: 0.20, dampingFraction: 0.80),
                        value: isDragging
                    )
                    .animation(.easeOut(duration: 0.12), value: isHovering)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .onHover { inside in
                isHovering = inside
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let locationX = max(0, min(usableWidth, gesture.location.x - thumbDiameter / 2))
                        let ratio = locationX / usableWidth
                        let rawValue = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                        let stepped = (rawValue / step).rounded() * step
                        let clamped = min(max(stepped, range.lowerBound), range.upperBound)
                        if dragPosition != clamped {
                            dragPosition = clamped
                            value = clamped
                        }
                    }
                    .onEnded { _ in
                        if let finalValue = dragPosition {
                            value = finalValue
                            onCommit()
                        } else {
                            onCommit()
                        }
                        dragPosition = nil
                        isDragging = false
                    }
            )
        }
        .frame(height: 20)
        .accessibilityRepresentation {
            Slider(value: committedValue, in: range, step: step)
        }
    }
}

/// A miniature HUD used by the appearance cards.
private struct HUDSwatch: View {
    let material: HUDMaterial

    var body: some View {
        ZStack {
            if material == .glass {
                // Glass is shown as glass on the product's own paper, not as a
                // grey block: a blue-grey wash behind the swatch made the tile
                // the one cold surface in a warm window, and the frost it was
                // meant to describe disappeared into it.
                ZStack {
                    LinearGradient(
                        colors: [DotTheme.paperTint, DotTheme.paperDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    HStack(spacing: 0) {
                        Capsule()
                            .fill(DotTheme.amber.opacity(0.55))
                            .frame(width: 96, height: 40)
                            .blur(radius: 16)
                        Capsule()
                            .fill(DotTheme.accent.opacity(0.30))
                            .frame(width: 70, height: 34)
                            .blur(radius: 14)
                    }
                    .opacity(0.8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.34), location: 0),
                                .init(color: Color.white.opacity(0.06), location: 0.34),
                                .init(color: Color.clear, location: 0.72),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.07, green: 0.07, blue: 0.08),
                                Color(red: 0.025, green: 0.025, blue: 0.03),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            // The bars are drawn on both materials; on the frosted one they
            // take the ink of the paper, because the warm white that reads on
            // black is invisible on a light pane.
            HUDSwatchWaveform(
                tint: material == .glass ? DotTheme.ink2 : HUDTheme.accent,
                peak: material == .glass ? DotTheme.amber : HUDTheme.live
            )
            .frame(width: 132, height: 26)

            HStack {
                Spacer()
                VStack {
                    Circle()
                        .fill(DotTheme.amber)
                        .frame(width: 6, height: 6)
                        .shadow(color: DotTheme.amber.opacity(0.6), radius: 3)
                    Spacer()
                }
            }
            .padding(10)
        }
        .frame(height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(border, lineWidth: material == .glass ? 1.25 : 1)
        )
        .accessibilityHidden(true)
    }

    private var border: LinearGradient {
        switch material {
        case .glass:
            LinearGradient(
                colors: [
                    Color.white.opacity(0.45),
                    Color.white.opacity(0.18),
                    Color.white.opacity(0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .black:
            LinearGradient(
                colors: [
                    Color.white.opacity(0.09),
                    Color.white.opacity(0.02),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

/// A miniature preview swatch showing one visualizer style.
private struct VisualizerSwatch: View {
    let visualizer: HUDVisualizer

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            HUDTheme.surfaceTop.opacity(0.95),
                            HUDTheme.surfaceBottom,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            previewContent
                .frame(height: 22)
                .padding(.horizontal, 10)

            if visualizer == .haloEdge {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                HUDTheme.live.opacity(0.0),
                                HUDTheme.live.opacity(0.9),
                                HUDTheme.accent.opacity(0.8),
                                HUDTheme.live.opacity(0.0),
                                HUDTheme.live.opacity(0.9),
                                HUDTheme.live.opacity(0.0)
                            ]),
                            center: .center
                        ),
                        lineWidth: 1.5
                    )
            }
        }
        .frame(height: 52)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var previewContent: some View {
        let sampleHistory = SpeechSchedule.history(endingAt: 2.35)
        let sampleHeights: [CGFloat] = [2, 4, 7, 10, 11, 8, 4, 3, 5, 9, 11, 7, 3, 2, 4, 8, 10, 5, 2]
        HUDWaveform(
            visualizer: visualizer,
            halfHeights: sampleHeights,
            history: sampleHistory,
            phase: 0.35,
            time: 2.35,
            level: 0.68,
            pulse: 0.25
        )
    }
}

/// A miniature window that shows the paper and ink of one appearance choice.
///
/// The swatch is an illustration, so it uses fixed palette values: the System
/// card must show both palettes side by side even while one of them is active.
private struct AppearanceSwatch: View {
    let mode: AppearanceMode

    var body: some View {
        Group {
            switch mode {
            case .system:
                HStack(spacing: 0) {
                    miniature(dark: false)
                    miniature(dark: true)
                }
            case .light:
                miniature(dark: false)
            case .dark:
                miniature(dark: true)
            }
        }
        .frame(height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private func miniature(dark: Bool) -> some View {
        let palette = SwatchPalette(dark: dark)
        return ZStack {
            palette.paper
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 2.5) {
                    Circle().fill(SwatchPalette.red).frame(width: 4, height: 4)
                    Circle().fill(SwatchPalette.yellow).frame(width: 4, height: 4)
                    Circle().fill(SwatchPalette.green).frame(width: 4, height: 4)
                }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(palette.sidebar)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2.5) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(palette.card)
                            .frame(height: 12)
                            .overlay(alignment: .leading) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Capsule()
                                        .fill(palette.accent)
                                        .frame(width: 12, height: 2)
                                    Capsule()
                                        .fill(palette.ink.opacity(0.62))
                                        .frame(width: 20, height: 1.5)
                                }
                                .padding(.leading, 3)
                            }
                        HStack(spacing: 2.5) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(palette.card)
                                .frame(height: 8)
                            Circle().fill(SwatchPalette.yellow).frame(width: 3, height: 3)
                        }
                    }
                }
            }
            .padding(4)
        }
    }
}

private struct SwatchPalette {
    let paper: Color
    let sidebar: Color
    let card: Color
    let accent: Color
    let ink: Color

    init(dark: Bool) {
        if dark {
            paper = Color(red: 0.102, green: 0.090, blue: 0.082)
            sidebar = Color(red: 0.078, green: 0.071, blue: 0.063)
            card = Color(red: 0.145, green: 0.129, blue: 0.118)
            accent = Color(red: 0.827, green: 0.859, blue: 1.0)
            ink = Color(red: 0.953, green: 0.929, blue: 0.894)
        } else {
            paper = Color(red: 0.973, green: 0.957, blue: 0.929)
            sidebar = Color(red: 0.945, green: 0.929, blue: 0.898)
            card = Color(red: 0.996, green: 0.988, blue: 0.973)
            accent = Color(red: 0.122, green: 0.176, blue: 0.361)
            ink = Color(red: 0.075, green: 0.065, blue: 0.085)
        }
    }

    static let red = Color(red: 1.0, green: 0.373, blue: 0.341)
    static let yellow = Color(red: 0.996, green: 0.737, blue: 0.180)
    static let green = Color(red: 0.157, green: 0.784, blue: 0.251)
}

/// The remove control of a formatting row: quiet until the pointer reaches it.
private struct AppRemoveButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(hovering ? DotTheme.ink2 : DotTheme.ink3)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove")
        .accessibilityLabel("Remove")
    }
}

/// Headless renders must not enumerate audio devices. The real window keeps
/// the default and reads the catalog when it appears.
private struct SettingsHeadlessKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the settings view is being drawn for an offscreen PNG.
    var settingsHeadless: Bool {
        get { self[SettingsHeadlessKey.self] }
        set { self[SettingsHeadlessKey.self] = newValue }
    }
}

/// The device the system default microphone would resolve to, for an offscreen
/// render. A render must not enumerate audio devices, and a page that names a
/// device it cannot resolve shows the placeholder instead of the real row.
private struct SettingsDefaultInputKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The UID an offscreen render treats as the system default input.
    var settingsDefaultInputUID: String? {
        get { self[SettingsDefaultInputKey.self] }
        set { self[SettingsDefaultInputKey.self] = newValue }
    }
}

/// A version override for offscreen renders. The real windows read the app
/// bundle; the test host reports its own version, which is not Dot's.
private struct SettingsVersionKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The version to show instead of the bundle's, if any.
    var settingsVersionOverride: String? {
        get { self[SettingsVersionKey.self] }
        set { self[SettingsVersionKey.self] = newValue }
    }
}

/// A height override for offscreen renders.
///
/// The window is 600 points tall and its pages scroll. A render of a scrolling
/// page stops at the fold, so the cards below it are never looked at; a taller
/// host with this override draws the whole page at once.
private struct SettingsHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The height to draw the window at, if a render asks for one.
    var settingsHeightOverride: CGFloat? {
        get { self[SettingsHeightKey.self] }
        set { self[SettingsHeightKey.self] = newValue }
    }
}
