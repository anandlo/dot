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
    /// The configuration this window draws.
    ///
    /// It is the store's published value, so a write through any control is
    /// seen by the view: the page redraws and `.onChange(of: config)` saves and
    /// applies the change once.
    @Binding private var config: DotConfig
    /// The store `config` is read from and written to.
    @ObservedObject private var store: ConfigStore
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
    /// Opens the shortcut recorder for the record shortcut.
    private let onChangeShortcut: () -> Void
    /// Opens the shortcut recorder for the paste shortcut.
    private let onChangePasteShortcut: () -> Void
    /// Opens the shortcut recorder for the palette shortcut.
    private let onChangePaletteShortcut: () -> Void
    /// Opens the shortcut recorder for the assistant's shortcut.
    private let onChangeAssistantShortcut: () -> Void
    /// Opens the welcome window.
    private let onOpenWelcome: () -> Void
    /// A state to draw in place of the update check, for a render.
    private let aboutUpdatePreview: AboutUpdateState?
    /// The model list a render draws, so the picker can be looked at without a
    /// network.
    private let modelPreview: [AvailableModel]?
    /// Whether the page may ask the service while its host is headless.
    ///
    /// A headless host has no window and no keyboard: by default the page
    /// draws the state it was handed and touches neither the Keychain nor the
    /// network. A caller that supplies its own ``SpeechCredentialChecks``, with
    /// caches that answer without either, can let the page ask; that is how the
    /// triggers behind the controls are measured.
    private let allowsOffscreenChecks: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsHeadless) private var headless
    @Environment(\.settingsVersionOverride) private var versionOverride
    @Environment(\.settingsBuildOverride) private var buildOverride
    @Environment(\.settingsDefaultInputUID) private var defaultInputUIDOverride
    @Environment(\.settingsHeightOverride) private var heightOverride
    /// The credential state a render draws, in place of a live check.
    @Environment(\.settingsCredentialPreview) private var credentialPreview

    @State private var selected: Page
    @State private var hoveredPage: Page?
    /// The space the selection pill travels in, so a change of page reads as the
    /// pill moving down the list instead of one pill vanishing and another
    /// appearing.
    @Namespace private var sidebarPillSpace
    @State private var microphoneDevices: [MicrophoneDevice] = []
    /// The UID the system default microphone resolves to, read when the window
    /// appears. A calibration is keyed by device, and "system default" names
    /// whichever device is first today.
    @State private var defaultInputUID: String?
    /// The text of the key field, shared with the check a pick starts.
    @StateObject private var keyField: KeyField
    @State private var savedProviders: Set<String> = []
    @State private var connectingPrimary = false
    /// The automatic check behind the status label beside the service picker.
    @StateObject private var credentials: SpeechCredentialChecks
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
    ///   - store: The configuration every control reads and writes.
    ///   - providers: The providers the menu currently knows about.
    ///   - tab: The page to open: 0 General, 1 Speech to text, 2 Shortcuts,
    ///     3 Appearance, 4 About, 5 AI rewrite. The retired 6 and 7 open AI
    ///     rewrite as well, so a caller that still names them is not stranded.
    ///   - onChange: Called once for every real configuration change.
    ///   - onSetAPIKey: Writes a key and returns an error, or `nil`.
    ///   - onDeleteAPIKey: Deletes a key and returns an error, or `nil`.
    ///   - onDeleteAllAPIKeys: Purges all keys and returns an error, or `nil`.
    ///   - onChangeShortcut: Opens the record-shortcut recorder.
    ///   - onChangePasteShortcut: Opens the paste-shortcut recorder.
    ///   - onChangePaletteShortcut: Opens the palette-shortcut recorder.
    ///   - onOpenWelcome: Opens the welcome window.
    ///   - aboutUpdatePreview: A state to draw in the update row, for a render.
    ///   - credentials: The status label's model. The window makes its own;
    ///     a caller that already holds one can watch what the label draws.
    ///   - allowsOffscreenChecks: Whether that model may run in a headless
    ///     host. The caller that turns this on supplies caches that answer
    ///     without the Keychain or the network.
    ///   - keyField: The text of the key field. The window makes its own; a
    ///     caller that holds one can see what a pick discards.
    init(
        store: ConfigStore,
        providers: [MenuProvider],
        tab: Int = 0,
        onChange: @escaping () -> Void,
        onSetAPIKey: @escaping (String, String) -> String?,
        onDeleteAPIKey: @escaping (String) -> String? = { _ in nil },
        onDeleteAllAPIKeys: @escaping () -> String? = { nil },
        onChangeShortcut: @escaping () -> Void,
        onChangePasteShortcut: @escaping () -> Void = {},
        onChangePaletteShortcut: @escaping () -> Void = {},
        onChangeAssistantShortcut: @escaping () -> Void = {},
        onOpenWelcome: @escaping () -> Void = {},
        aboutUpdatePreview: AboutUpdateState? = nil,
        modelPreview: [AvailableModel]? = nil,
        credentials: SpeechCredentialChecks = SpeechCredentialChecks(),
        allowsOffscreenChecks: Bool = false,
        keyField: KeyField = KeyField()
    ) {
        _store = ObservedObject(wrappedValue: store)
        _config = store.configBinding
        self.providers = providers
        self.requestedTab = tab
        _selected = State(initialValue: (Page(rawValue: tab) ?? .general).resolved)
        self.onChange = onChange
        self.onSetAPIKey = onSetAPIKey
        self.onDeleteAPIKey = onDeleteAPIKey
        self.onDeleteAllAPIKeys = onDeleteAllAPIKeys
        self.onChangeShortcut = onChangeShortcut
        self.onChangePasteShortcut = onChangePasteShortcut
        self.onChangePaletteShortcut = onChangePaletteShortcut
        self.onChangeAssistantShortcut = onChangeAssistantShortcut
        self.onOpenWelcome = onOpenWelcome
        self.aboutUpdatePreview = aboutUpdatePreview
        self.modelPreview = modelPreview
        self.allowsOffscreenChecks = allowsOffscreenChecks
        _credentials = StateObject(wrappedValue: credentials)
        _availableModels = State(initialValue: modelPreview ?? [])
        _liveDwellSeconds = State(initialValue: store.config.hudDwellSeconds)
        _keyField = StateObject(wrappedValue: keyField)
    }

    var body: some View {
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
            guard let page = Page(rawValue: value)?.resolved, page != selected else { return }
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
            keyField.text = ""
            refreshModels()
            updateLanguageForModel(currentConfiguredModel)
            startCredentialCheck(immediate: true)
        }
        .onChange(of: keyField.text) { _, _ in
            startCredentialCheck(immediate: false)
        }
        .onChange(of: credentialSignature) { _, _ in
            startCredentialCheck(immediate: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            guard !headless else { return }
            let latest = LaunchAtLogin.isEnabled
            if launchAtLogin != latest {
                launchAtLogin = latest
            }
            // A window that comes back to the front is when inputs Dot cannot
            // observe are read again: a language model that finished
            // installing, a key replaced outside this window. The check's name
            // carries both, so an answer that did not move costs a cache
            // lookup and an answer that did is asked once.
            if selected == .provider {
                startCredentialCheck(immediate: true)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(DotType.font(12, .semibold))
                .foregroundStyle(DotTheme.ink3)
                .padding(.leading, 22)
                .padding(.top, 40)
                .padding(.bottom, 8)

            VStack(spacing: 3) {
                ForEach(Page.sidebarPages) { page in
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
                    .font(DotType.font(11.5, .semibold))
                    .foregroundStyle(isSelected ? DotTheme.sidebarSelectedIcon : DotTheme.ink3)
                    .frame(width: 16)
                Text(page.title)
                    .font(DotType.font(12.5, .semibold))
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
        .buttonStyle(DotPressStyle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
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
        // The retired Voices and Connectors pages keep their enum cases and tab
        // numbers, so an old configuration still resolves them; neither page is
        // drawn, and both tabs open AI rewrite.
        case .assistant, .voices, .connectors:
            assistantPage
        case .about:
            aboutPage
        }
    }

    private var assistantPage: some View {
        AssistantPage(
            config: $config,
            onChange: {},
            onSetKey: onSetAPIKey,
            onDeleteKey: onDeleteAPIKey
        )
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
                    .font(DotType.font(10, .semibold))
                Text("Add app…")
                    .font(DotType.font(12.5, .semibold))
            }
            .foregroundStyle(DotTheme.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .frame(minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DotPressStyle())
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
    }

    private func removeOverride(_ bundleID: String) {
        guard config.outputGrammarTargets[bundleID] != nil else { return }
        config.outputGrammarTargets.removeValue(forKey: bundleID)
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
                    }
                )
                .frame(width: 155)

                Text(dwellText)
                    .font(DotType.tabularFont(12, .medium))
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
        }
        .onAppear {
            credentials.pageAppeared()
            startCredentialCheck(immediate: true)
        }
        .onDisappear {
            credentials.cancel()
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
                    SecureField(keyPlaceholder, text: $keyField.text)
                        .modifier(DotFieldStyle(focused: focusedField == .apiKey))
                        .focused($focusedField, equals: .apiKey)
                        .disabled(selectedPreset.key == ProviderPreset.KeyRequirement.none)
                        .onSubmit {
                            connect()
                        }
                        .onChange(of: keyField.text) { _, newKey in
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
                    .accessibilityIdentifier("speech.apiKey.trailing")

                    if hasStoredKey(selectedPreset) && selectedPreset.key != .none {
                        Button(role: .destructive) {
                            deleteKey(for: selectedPreset)
                        } label: {
                            Image(systemName: "trash")
                                .font(DotType.font(12, .semibold))
                                .foregroundStyle(DotTheme.coral)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(DotPressStyle())
                        .help("Delete the stored key")
                        .accessibilityLabel("Delete the stored key from the Keychain")
                        .accessibilityIdentifier("speech.apiKey.trailing")
                    }
                }
                .overlay(
                    SpeechRowAnchor(identifier: "speech.apiKey.trailing")
                        .frame(width: 1, height: 1),
                    alignment: .trailing
                )
            }
            SettingsDivider()
            credentialStatusRow
        }
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
        .accessibilityIdentifier("speech.service")
        .overlay(
            SpeechRowAnchor(identifier: "speech.service")
                .frame(width: 1, height: 1),
            alignment: .trailing
        )
    }

    /// Writes the chosen row into the configuration.
    ///
    /// The rows are read again here rather than captured: a row that presents a
    /// stored provider only exists for the configuration that owns it. A click
    /// on a list the configuration has moved out from under names a row that is
    /// no longer there, and it is recorded rather than dropped in silence.
    var serviceBinding: Binding<String> {
        Binding(
            get: { selectedPreset.id },
            set: { id in
                guard let preset = ProviderPreset.rows(for: config).first(where: { $0.id == id }) else {
                    Log.shared.info("settings.pick.dropped", ["id": .string(id)])
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

    private var trimmedKey: String {
        keyField.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the Connect button can do something.
    private var canConnect: Bool {
        guard !connectingPrimary else { return false }
        if selectedPreset.key == .required {
            return !trimmedKey.isEmpty
        }
        return true
    }

    /// Whether the Keychain holds a key for a row.
    private func hasStoredKey(_ preset: ProviderPreset) -> Bool {
        savedProviders.contains(preset.providerID)
            || providers.first { $0.providerID == preset.providerID }?.hasKey == true
    }

    /// Stores the key of the chosen service and selects it.
    private func connect() {
        guard canConnect else { return }
        save(secret: trimmedKey)
    }

    /// Stores a key, then selects the row with it.
    ///
    /// The Keychain callback runs first, so a refused key leaves the
    /// configuration exactly as it was and the status label says the Keychain
    /// refused it. Split from ``connect()`` so the refusal path is reachable
    /// without a keyboard: the key the page would have sent is the only
    /// difference between the two calls.
    ///
    /// - Parameter secret: the key to store, as it was typed.
    func save(secret: String) {
        let preset = selectedPreset
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        connectingPrimary = true
        focusedField = nil
        defer { connectingPrimary = false }

        if preset.key != .none, !trimmed.isEmpty {
            if let message = onSetAPIKey(trimmed, preset.providerID) {
                credentials.markNotSaved(message)
                focusedField = .apiKey
                return
            }
            savedProviders.insert(preset.providerID)
        }

        credentials.clearNotSaved()
        apply(preset)
        keyField.text = ""
        refreshModels()
        updateLanguageForModel(currentConfiguredModel)
        startCredentialCheck(immediate: true)
    }

    private func deleteKey(for preset: ProviderPreset) {
        guard onDeleteAPIKey(preset.providerID) == nil else { return }
        savedProviders.remove(preset.providerID)
        keyField.text = ""
        startCredentialCheck(immediate: true)
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
                                        .font(DotType.font(10, .semibold))
                                        .foregroundStyle(DotTheme.ink2)
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(DotPressStyle())
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
                .font(DotType.tabularFont(11, .medium))
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
        if !trimmedKey.isEmpty { return true }
        if hasStoredKey(selectedPreset) { return true }
        return CredentialCache.shared.key(for: config.provider).map { !$0.isEmpty } ?? false
    }

    /// Whether the picker has a real model to name: a configured one counts,
    /// a list that came back empty does not.
    private var hasModelChoices: Bool {
        !modelOptions.isEmpty
    }

    private var modelOptions: [DotSelectOption<String>] {
        Self.modelOptions(
            catalog: availableModels,
            storedModel: config.settings(for: config.provider).model
        )
    }

    /// The rows the model picker offers for one catalogue.
    ///
    /// The catalogue is what the service published; the configured id is kept
    /// even when the service stopped listing it, and the custom choice is the
    /// last row when there is anything to choose. A page and a test ask the
    /// same function, so the two cannot disagree about what "enabled" means.
    ///
    /// - Parameters:
    ///   - catalog: the models the service published.
    ///   - storedModel: the id the configuration already names.
    /// - Returns: the rows, in the order the picker draws them.
    static func modelOptions(
        catalog: [AvailableModel],
        storedModel: String?
    ) -> [DotSelectOption<String>] {
        var options = catalog.map { model in
            DotSelectOption(value: model.id, title: model.name)
        }
        let current = storedModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        }
    }

    private func refreshModels() {
        let providerID = config.provider
        // A render and a headless host have no key to read and no service to
        // ask; they draw the list they were handed.
        guard !headless else { return }
        guard providerID != ProviderIdentifier.apple else { return }
        isLoadingModels = true
        let key = trimmedKey.isEmpty ? CredentialCache.shared.key(for: providerID) : trimmedKey
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
            }
        )
    }

    /// Applies a row and moves the keyboard to the field the user has to fill
    /// in next.
    private func choose(_ preset: ProviderPreset) {
        let showing = selectedPreset
        let wasCustom = showing.id == ProviderPreset.custom.id
        // A key typed for the row that was showing is not a key for the row
        // that replaces it. The row can move without the provider id moving:
        // the custom row and the shipped row it stands in for write the same
        // id, so the row is what decides, and the unsaved text is discarded
        // before anything is applied or asked.
        if preset.id != showing.id {
            keyField.text = ""
        }
        if preset.id == ProviderPreset.custom.id, !wasCustom {
            var settings = config.settings(for: preset.providerID)
            settings.baseURL = nil
            config.providers[preset.providerID] = settings
        }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                apply(preset)
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                apply(preset)
            }
        }
        startCredentialCheck(immediate: true)
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

    /// Writes a row into the configuration and records the service it selected.
    ///
    /// Every pick on this page reaches the configuration here, so the line that
    /// names the change is emitted exactly when the provider really moved: a
    /// second pick of the row already in use is not a change, and nothing is
    /// logged for it.
    private func apply(_ preset: ProviderPreset) {
        let from = config.provider
        preset.apply(to: &config)
        guard config.provider != from else { return }
        // A key typed for the service that was showing is not a key for the one
        // that replaced it: the unsaved text is discarded before any check can
        // carry it across.
        keyField.text = ""
        Log.shared.info("provider.changed", [
            "from": .string(from),
            "to": .string(config.provider),
            "source": .string("settings"),
        ])
    }

    /// Starts the check behind the status label beside the service picker.
    ///
    /// A render draws the state it was handed, and a headless host asks no
    /// service unless its caller supplied caches that answer without one: the
    /// live value belongs to a window someone is looking at. A check replaces
    /// the one in flight, so a quick sequence of edits ends in one request.
    ///
    /// - Parameter immediate: whether an action, rather than the end of an
    ///   edit, is the reason for the check.
    private func startCredentialCheck(immediate: Bool) {
        guard credentialPreview == nil else { return }
        guard !headless || allowsOffscreenChecks else { return }
        credentials.check(
            providerID: config.provider,
            config: config,
            typedKey: keyField.text,
            serviceName: selectedPreset.name,
            requiresKey: selectedPreset.key == .required,
            immediate: immediate
        )
    }

    /// Every input, apart from the key, that changes the request a check makes.
    ///
    /// The address, the header the key travels in and the on-device language
    /// all change what should be asked, so a change to any of them is a new
    /// question and is asked at once. The key is covered by the writes that can
    /// change it (typing, saving, deleting), and every question is named after
    /// a digest of it, so a replaced key is a different question even when the
    /// page did not see the replacement.
    private var credentialSignature: String {
        let settings = config.settings(for: config.provider)
        return [
            config.provider,
            settings.baseURL ?? "",
            settings.authStyle?.rawValue ?? "",
            settings.language ?? "",
        ].joined(separator: " ")
    }

    /// The credential state the Status row draws.
    private var credentialStatus: SpeechCredentialStatus {
        credentialPreview ?? credentials.status
    }

    /// The last row of the card that holds the service's setup fields.
    private var credentialStatusRow: some View {
        SettingsRow(
            "Status",
            subtitle: credentialStatus.statusDetail
        ) {
            StatusChip(
                title: credentialStatus.title,
                dotTone: credentialStatus.tone,
                textTone: DotTheme.ink2,
                isChecking: credentialStatus.isChecking
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(credentialStatus.statusAccessibilityLabel)
        .accessibilityValue(credentialStatus.statusAccessibilityValue)
        .help(credentialStatus.message)
        .overlay(
            SpeechRowAnchor(
                identifier: "speech.status.row",
                label: credentialPreview == nil ? nil : credentialStatus.statusAccessibilityLabel,
                value: credentialPreview == nil ? nil : credentialStatus.statusAccessibilityValue,
                help: credentialPreview == nil ? nil : credentialStatus.message
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        )
    }

    /// The row the configuration presents.
    ///
    /// The selection is derived from the configuration, never stored: a URL the
    /// user types is exactly what the custom row means.
    private var selectedPreset: ProviderPreset {
        ProviderPreset.presenting(config)
    }

    // MARK: - Shortcuts

    /// One key the Shortcuts page offers.
    ///
    /// The list is the page's whole content, so a row cannot appear on the page
    /// without being here. The assistant's key is not one of them: nothing in
    /// this product starts a spoken assistant. Its recorded shortcut stays in
    /// the configuration and in the app's hotkey table, so the runtime can
    /// decide what to do with it and nothing has to be re-recorded later.
    enum ShortcutRow: String, CaseIterable, Identifiable {
        case record = "Start and stop recording"
        case paste = "Paste last transcript"
        case palette = "Open dictation palette"

        var id: String { rawValue }
        var title: String { rawValue }

        /// The sentence the row's recorder button speaks.
        var hint: String {
            switch self {
            case .record: "Starts and stops a recording. Escape cancels."
            case .paste: "Opens the recorder for the paste shortcut."
            case .palette: "Opens the recorder for the palette shortcut."
            }
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Global shortcuts") {
                ForEach(Array(ShortcutRow.allCases.enumerated()), id: \.offset) { entry in
                    if entry.offset > 0 {
                        SettingsDivider()
                    }
                    shortcutRow(
                        title: entry.element.title,
                        keycap: keycap(for: entry.element),
                        action: action(for: entry.element),
                        hint: entry.element.hint
                    )
                }
            }
        }
    }

    /// The recorded key one shortcut row shows.
    private func keycap(for row: ShortcutRow) -> String {
        switch row {
        case .record: config.hotkey.keycapLabel
        case .paste: config.pasteHotkey.keycapLabel
        case .palette: config.paletteHotkey.keycapLabel
        }
    }

    /// The recorder one shortcut row opens.
    private func action(for row: ShortcutRow) -> () -> Void {
        switch row {
        case .record: onChangeShortcut
        case .paste: onChangePasteShortcut
        case .palette: onChangePaletteShortcut
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

            SettingsSection("Island surface") {
                HStack(alignment: .top, spacing: 10) {
                    materialCard(.glass, name: HUDMaterial.glass.title)
                    materialCard(.black, name: HUDMaterial.black.title)
                }
                .padding(.vertical, 9)
            }

            SettingsSection("Voice visualizer") {
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
                        .font(DotType.font(12.5, .semibold))
                        .foregroundStyle(DotTheme.ink)
                    Spacer(minLength: 2)
                    selectionIndicator(isSelected)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(tileFill(isSelected))
            .overlay(tileBorder(isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(DotPressStyle())
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
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HUDSwatch(material: material)
                    .frame(maxWidth: .infinity, alignment: .center)
                HStack(alignment: .top, spacing: 8) {
                    Text(name)
                        .font(DotType.font(12.5, .semibold))
                        .foregroundStyle(DotTheme.ink)
                    Spacer(minLength: 2)
                    selectionIndicator(isSelected)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(tileFill(isSelected))
            .overlay(tileBorder(isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(DotPressStyle())
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
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                VisualizerSwatch(
                    visualizer: visualizer,
                    isAnimating: isSelected && !reduceMotion
                )
                HStack(alignment: .top, spacing: 8) {
                    Text(visualizer.title)
                        .font(DotType.font(12.5, .semibold))
                        .foregroundStyle(DotTheme.ink)
                    Spacer(minLength: 2)
                    selectionIndicator(isSelected)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(tileFill(isSelected))
            .overlay(tileBorder(isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(DotPressStyle())
        .accessibilityLabel("\(visualizer.title) visualizer")
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
                    .font(DotType.font(8, .bold))
                    .foregroundStyle(DotTheme.onSelection)
            }
        }
        .frame(width: 16, height: 16)
        .animation(
            reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.75),
            value: selected
        )
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
        versionOverride == nil ? AboutInfo.build : (buildOverride ?? "1")
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
            }
        )
    }

    private var fastRecordBinding: Binding<Bool> {
        Binding(
            get: { config.fastRecord },
            set: { value in
                guard config.fastRecord != value else { return }
                config.fastRecord = value
            }
        )
    }

    private var logTranscriptsBinding: Binding<Bool> {
        Binding(
            get: { config.logTranscripts },
            set: { value in
                guard config.logTranscripts != value else { return }
                config.logTranscripts = value
            }
        )
    }

    private var recordingModeBinding: Binding<RecordingMode> {
        Binding(
            get: { config.recordingMode },
            set: { value in
                guard config.recordingMode != value else { return }
                config.recordingMode = value
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
            }
        )
    }

    private var microphoneBinding: Binding<String?> {
        Binding(
            get: { config.microphoneDeviceUID },
            set: { value in
                guard config.microphoneDeviceUID != value else { return }
                config.microphoneDeviceUID = value
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
                    // The login item is a system setting, not a configuration
                    // value: nothing else here would tell the app it moved.
                    onChange()
                } catch {
                    launchError = error.localizedDescription
                    launchAtLogin = LaunchAtLogin.isEnabled
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

    /// One page of the window.
    ///
    /// The raw value is the tab number a caller passes to `show(tab:)`, which
    /// the menu also uses to open the About page. The offered cases are declared
    /// in sidebar order while the numbers stay put, so a page added in the middle
    /// of the list does not move the page a caller already names. The type is
    /// internal so a test can ask which pages the sidebar offers and where a
    /// retired tab lands.
    enum Page: Int, CaseIterable, Identifiable {
        case general = 0
        case provider = 1
        case shortcuts = 2
        case appearance = 3
        case assistant = 5
        // Retired from the sidebar. The cases and their tab numbers stay: the
        // stored configuration of both pages is still in the file, and a caller
        // that names tab 6 or 7 has to land somewhere that exists.
        case voices = 6
        case connectors = 7
        case about = 4

        var id: Int { rawValue }

        /// The pages the sidebar draws, in the order it draws them.
        static var sidebarPages: [Page] {
            allCases.filter(\.isShownInSidebar)
        }

        /// Whether the sidebar offers this page.
        var isShownInSidebar: Bool {
            switch self {
            case .general, .provider, .shortcuts, .appearance, .assistant, .about:
                true
            case .voices, .connectors:
                false
            }
        }

        /// The page a tab number opens.
        ///
        /// Voices and Connectors are routed to AI rewrite rather than exposed:
        /// the product has two settings, speech to text and AI rewrite, and an
        /// old caller naming one of the retired tabs must not open a page the
        /// sidebar no longer offers.
        var resolved: Page {
            switch self {
            case .voices, .connectors: .assistant
            case .general, .provider, .shortcuts, .appearance, .assistant, .about: self
            }
        }

        var title: String {
            switch self {
            case .general: "General"
            case .provider: "Speech to text"
            case .shortcuts: "Shortcuts"
            case .appearance: "Appearance"
            case .assistant: "AI rewrite"
            case .voices: "Voices"
            case .connectors: "Connectors"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .provider: "waveform"
            case .shortcuts: "command"
            case .appearance: "circle.lefthalf.filled"
            case .assistant: "sparkle"
            case .voices: "speaker.wave.2"
            case .connectors: "puzzlepiece.extension"
            case .about: "info.circle"
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

/// A miniature of the real recording card, for the material cards.
///
/// The tile is the card itself at sixty-two per cent, not an illustration of it:
/// the same fill, the same live dot, label, clock, waveform, divider and
/// buttons, laid out at the card's own 316 by 54 points and scaled into a 196 by
/// 34 frame. A redrawn miniature is a second card that drifts from the first the
/// moment either one is touched; this one cannot drift, because every part of it
/// is the part the island draws.
///
/// A Settings page has no desktop behind it, so the Glass tile carries a fixed
/// backdrop of its own and draws its own glass over it: on macOS 26 and later
/// the system's Liquid Glass, which samples the window behind it and has no
/// switch to turn sampling off, and before that the surface's own tint and
/// specular with the behind-window sampler turned off. The Black tile is the
/// same card in its opaque material.
struct HUDSwatch: View {
    let material: HUDMaterial

    /// The size the card is laid out at, in points, before it is scaled.
    static let cardSize = CGSize(
        width: HUDState.recordingWidth,
        height: HUDState.recordingHeight
    )
    /// How much of the card the tile shows.
    private static let scale: CGFloat = 0.62
    /// The frame the scaled card sits in, in points.
    static let tileSize = CGSize(width: 196, height: 34)
    /// The radius the tile's backdrop is clipped to.
    private static let backdropRadius: CGFloat = 10
    /// The radius of the tile's own glass, a half point inside the backdrop.
    private static let glassRadius: CGFloat = 10.5

    /// The level the live dot and the centre of the card are drawn at.
    private static let level: Double = 0.55

    var body: some View {
        ZStack {
            if material == .glass {
                backdrop
                if #available(macOS 26.0, *) {
                    Color.clear
                        .frame(width: Self.tileSize.width, height: Self.tileSize.height)
                        .glassEffect(
                            HUDTheme.glass,
                            in: RoundedRectangle(cornerRadius: Self.glassRadius, style: .continuous)
                        )
                    // The same scrim the card draws over its material, so the
                    // tile is the card's own two layers and the ink on it reads
                    // at the contrast the card was measured at.
                    RoundedRectangle(cornerRadius: Self.glassRadius, style: .continuous)
                        .fill(Color.black.opacity(HUDTheme.glassScrimOpacity))
                }
            }

            content
                .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                .scaleEffect(Self.scale, anchor: .center)
        }
        .frame(width: Self.tileSize.width, height: Self.tileSize.height)
        .clipShape(RoundedRectangle(
            cornerRadius: HUDTheme.cornerRadius * Self.scale,
            style: .continuous
        ))
        .accessibilityHidden(true)
    }

    /// The desktop the Glass tile stands in for.
    ///
    /// A page is opaque, so the tile carries a still desktop of its own: one
    /// neutral gradient for the room and two lights for something to refract.
    /// It is drawn rather than sampled, so the tile looks the same on every Mac
    /// and in every appearance.
    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.30, green: 0.34, blue: 0.42),
                    Color(red: 0.14, green: 0.16, blue: 0.22),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [
                    Color(red: 0.96, green: 0.70, blue: 0.20).opacity(0.85),
                    Color(red: 0.96, green: 0.70, blue: 0.20).opacity(0),
                ],
                center: UnitPoint(x: 0.26, y: 0.40),
                startRadius: 0,
                endRadius: 46
            )
            RadialGradient(
                colors: [
                    Color(red: 0.15, green: 0.65, blue: 0.90).opacity(0.85),
                    Color(red: 0.15, green: 0.65, blue: 0.90).opacity(0),
                ],
                center: UnitPoint(x: 0.74, y: 0.60),
                startRadius: 0,
                endRadius: 52
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.backdropRadius, style: .continuous))
    }

    /// The card's row, over the fill the tile draws for it.
    ///
    /// Where the tile draws the glass itself the row is drawn alone, with no
    /// surface of its own, so the glass is one layer and the row sits on it. A
    /// Mac without Liquid Glass gets the surface, which draws the fill the row
    /// needs and the desktop it does not have.
    @ViewBuilder
    private var content: some View {
        if HUDSurface.drawsSystemGlass(material) {
            recordingRow
        } else {
            card
        }
    }

    /// The recording card: its surface, and the row it draws while it listens.
    private var card: some View {
        ZStack {
            HUDSurface(material: material, samplesDesktop: false)
            recordingRow
        }
    }

    /// The recording row of ``HUDView``, at the card's own measurements.
    private var recordingRow: some View {
        HStack(spacing: 0) {
            LiveDot(level: Self.level, pulse: 0.25)
                .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)

            Color.clear.frame(width: 10)

            Text("REC")
                .font(HUDTheme.labelFont)
                .tracking(HUDTheme.labelTracking)
                .foregroundStyle(HUDTheme.ink)

            Color.clear.frame(width: 10)

            Text("0:07")
                .font(HUDTheme.clockFont)
                .tracking(HUDTheme.clockTracking)
                .foregroundStyle(HUDTheme.clockInk(material))

            Color.clear.frame(width: 14)

            // The tile draws the card's style through the card's own view, from
            // the same demonstration the visualizer tile draws, at the same
            // moment of it: a tile that handed the row a frozen buffer of its own
            // was a second picture of the same voice.
            HUDWaveform(
                visualizer: .stretch,
                halfHeights: [],
                history: VisualizerTile.history(at: VisualizerTile.stillTime),
                spectrumHistory: VisualizerTile.spectrum(at: VisualizerTile.stillTime),
                phase: DictationScript.phase(at: VisualizerTile.stillTime),
                time: VisualizerTile.stillTime,
                level: Self.level,
                pulse: 0.25,
                ceiling: 1,
                reveal: 1,
                material: material
            )
            .frame(maxWidth: .infinity)
            .frame(height: HUDTheme.waveformHeight)

            divider

            HStack(spacing: 4) {
                HUDActionButton(action: .stop) {}
                HUDActionButton(action: .cancel) {}
            }
        }
        .padding(.horizontal, HUDTheme.padding)
        .frame(maxWidth: .infinity)
        .frame(height: HUDState.recordingHeight)
    }

    /// The hairline between the wave and the buttons, as the card draws it.
    private var divider: some View {
        Capsule()
            .fill(HUDTheme.hairline)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 8)
    }
}

/// The signal a Settings tile is drawn with.
///
/// A tile has no microphone, so it draws a synthetic voice. It used to draw that
/// voice with no spectrum at all, and the grid fell back to an envelope-derived
/// weight that is darker than anything the live card shows, which is how the tile
/// came to glow while the island beside it stayed flat. The tile now draws the
/// same five bands the card draws, through the card's own per-voice window, so
/// the two pictures are the same kind of picture.
@MainActor
enum VisualizerTile {
    /// How long a selected tile's demonstration runs before it repeats, in
    /// seconds.
    ///
    /// The tile draws the same script the island's preview draws, so it loops
    /// over the same span: a tile that repeats at a pace of its own is a second
    /// demonstration that drifts against the one the island shows.
    static let loop = DictationScript.loop

    /// Where the still tiles are frozen, in seconds.
    ///
    /// The moment is just past the loudest syllable of the script, where every
    /// visualizer has something to show: a tile frozen in the breath before the
    /// first syllable would be a picture of silence next to the selected one.
    static let stillTime: Double = DictationScript.stillTime

    /// The envelope line the tile's synthetic voice is drawn from.
    static var history: [Double] { history(at: stillTime) }

    /// The envelope line of the demonstration at a moment.
    ///
    /// - Parameter time: where in the demonstration, in seconds.
    static func history(at time: Double) -> [Double] {
        DictationScript.history(endingAt: time)
    }

    /// The five bands of the tile's synthetic voice at a moment.
    ///
    /// The script carries the bands of each syllable, so the tile draws the
    /// spectrum a dictation of this sentence really has: the top row lifts on the
    /// words with an `s` and the bottom row carries the vowels. It used to
    /// rebuild a spectrum from the envelope alone, which made every moment the
    /// same picture at a different height.
    ///
    /// - Parameter time: where in the demonstration, in seconds.
    /// - Returns: one frame per tick, oldest first, on the card's own window.
    static func spectrum(at time: Double) -> [AudioSpectrumFrame] {
        DictationScript.spectrumHistory(endingAt: time)
    }

    /// The view a visualizer swatch draws, from the one feed every preview uses.
    ///
    /// The swatch and the island's own preview are the same picture of the same
    /// performance, so they hand ``HUDWaveform`` the same four values: the feed is
    /// advanced to the moment, and its history, its stamped spectrum ring, its
    /// phase and its clock are what the style is drawn from.
    ///
    /// - Parameters:
    ///   - visualizer: the style to draw.
    ///   - feed: the demonstration's feed, advanced here to the moment.
    ///   - time: where in the demonstration the tile is drawing.
    ///   - halfHeights: the row the styles that use one are drawn against.
    /// - Returns: the waveform view.
    static func waveform(
        _ visualizer: HUDVisualizer,
        from feed: VisualizerFeed,
        at time: Double,
        halfHeights: [CGFloat]
    ) -> HUDWaveform {
        feed.advance(to: time)
        return HUDWaveform(
            visualizer: visualizer,
            halfHeights: halfHeights,
            history: feed.history,
            spectrumHistory: feed.ring,
            phase: feed.phase,
            time: feed.time,
            level: 0.68,
            pulse: 0.25
        )
    }
}

/// The feeds the visualizer tiles draw from, one per style.
///
/// A feed holds the demonstration's own clock, so it is kept between frames: one
/// rebuilt in a body would reseed its two seconds of the script on every frame,
/// and one shared by two tiles would let each of them advance the other's
/// performance.
@MainActor
private enum VisualizerFeeds {
    private static var feeds: [HUDVisualizer: VisualizerFeed] = [:]

    /// The feed a running tile draws from.
    static func feed(for visualizer: HUDVisualizer) -> VisualizerFeed {
        if let feed = feeds[visualizer] { return feed }
        let feed = VisualizerFeed()
        feeds[visualizer] = feed
        return feed
    }

    /// The one moment every tile that is not running is frozen at.
    ///
    /// It is the demonstration advanced to ``VisualizerTile/stillTime`` once and
    /// kept, so the four still tiles are four styles of one frame rather than four
    /// frames of their own.
    static let still: VisualizerFeed = {
        let feed = VisualizerFeed(from: VisualizerTile.stillTime - 2)
        feed.advance(to: VisualizerTile.stillTime)
        return feed
    }()
}

/// A miniature preview swatch showing one visualizer style.
///
/// The selected swatch is a demonstration rather than a diagram: it draws the
/// island's own simulated voice at the island's own pace, so choosing a
/// visualizer by eye is choosing between two pictures of the same performance.
/// The other swatches are frozen at one moment of the same demonstration, which
/// is what makes them comparable: five tiles each running their own clock would
/// be five different syllables.
///
/// Every style is drawn by ``HUDWaveform`` itself, the view the card uses, so a
/// tile is a preview of a style rather than a sixth style of its own. The Halo
/// tile is the ring the card draws, at the tile's own canvas.
private struct VisualizerSwatch: View {
    let visualizer: HUDVisualizer
    /// Whether the demonstration runs: the chosen tile's, unless Reduce Motion
    /// asks for a still picture. The preference asks for no movement, not for
    /// fewer choices, so the chosen tile keeps its frame and stops its clock.
    let isAnimating: Bool

    /// How fast the demonstration is drawn.
    ///
    /// It is the card's own sixty frames a second, because the feed advances in
    /// sixtieths: a tile drawn at thirty would show every other frame of the same
    /// performance, and a grid measured on it would be a grid the card never draws.
    private static let frameInterval: TimeInterval = 1.0 / 60

    /// Where inside the script the swatch's clock starts, in seconds.
    ///
    /// The same moment the island's preview opens at, so selecting a visualizer
    /// and looking at it shows one performance rather than two.
    private static let startOffset: Double = 0.4

    @State private var startedAt = Date()

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

            if isAnimating {
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { timeline in
                    content(from: VisualizerFeeds.feed(for: visualizer), at: moment(for: timeline.date))
                }
            } else {
                content(from: VisualizerFeeds.still, at: VisualizerTile.stillTime)
            }
        }
        .frame(height: 52)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    /// Where in the demonstration a clock reading sits.
    private func moment(for date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(startedAt)) + Self.startOffset
        return elapsed.truncatingRemainder(dividingBy: VisualizerTile.loop)
    }

    /// The tile's picture of the demonstration at a moment.
    ///
    /// - Parameters:
    ///   - feed: the demonstration's feed, advanced here to the moment.
    ///   - time: where in the demonstration the tile is drawing.
    private func content(from feed: VisualizerFeed, at time: Double) -> some View {
        VisualizerTile.waveform(
            visualizer,
            from: feed,
            at: time,
            halfHeights: Self.sampleHeights
        )
        .frame(height: 22)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    /// The row of half heights the synthetic voice is drawn against, in points.
    ///
    /// They are the tile's own, not the card's: the tile is narrower than the
    /// card's canvas, so a card's row would be drawn inside a narrower box and
    /// leave the picture short of both edges.
    private static let sampleHeights: [CGFloat] = [2, 4, 7, 10, 11, 8, 4, 3, 5, 9, 11, 7, 3, 2, 4, 8, 10, 5, 2]
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
                .font(DotType.font(14, .medium))
                .foregroundStyle(hovering ? DotTheme.ink2 : DotTheme.ink3)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(DotPressStyle())
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

/// A transparent AppKit view that gives a hosted SwiftUI row a stable edge and
/// frame. The status row exposes its accessibility state here only in a preview
/// host, where SwiftUI's own element has no AppKit tree; the live window keeps
/// the SwiftUI element alone. The view draws nothing and takes no click.
private struct SpeechRowAnchor: NSViewRepresentable {
    let identifier: String
    var label: String?
    var value: String?
    var help: String?

    func makeNSView(context: Context) -> SpeechRowAnchorView {
        let view = SpeechRowAnchorView()
        view.apply(identifier: identifier, label: label, value: value, help: help)
        return view
    }

    func updateNSView(_ view: SpeechRowAnchorView, context: Context) {
        view.apply(identifier: identifier, label: label, value: value, help: help)
    }
}

private final class SpeechRowAnchorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        alphaValue = 0
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = false
        alphaValue = 0
    }

    func apply(identifier: String, label: String?, value: String?, help: String?) {
        self.identifier = NSUserInterfaceItemIdentifier(rawValue: identifier)
        setAccessibilityElement(label != nil)
        guard label != nil else { return }
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
        setAccessibilityHelp(help)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

/// A build override for offscreen renders. A render that names a version must
/// be able to show a long prerelease build or no build at all.
private struct SettingsBuildKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The build to show instead of the render's default, if any.
    var settingsBuildOverride: String? {
        get { self[SettingsBuildKey.self] }
        set { self[SettingsBuildKey.self] = newValue }
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
