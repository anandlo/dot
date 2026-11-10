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
    /// Opens the welcome window.
    private let onOpenWelcome: () -> Void
    /// Whether the provider list starts open. Headless renders set it so the
    /// open state can be captured; production leaves it closed.
    private let providerMenuOpen: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsHeadless) private var headless
    @Environment(\.settingsVersionOverride) private var versionOverride

    @State private var selected: Page
    @State private var hoveredPage: Page?
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
    ///   - onOpenWelcome: Opens the welcome window.
    ///   - providerMenuOpen: Whether the provider list starts open. `nil` keeps
    ///     it closed; only an offscreen render asks for the open state.
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
        onOpenWelcome: @escaping () -> Void = {},
        providerMenuOpen: Bool? = nil
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
        self.onOpenWelcome = onOpenWelcome
        self.providerMenuOpen = providerMenuOpen ?? false
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
        .frame(width: 820, height: 600)
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
                .font(DotTheme.labelFont)
                .tracking(1.6)
                .textCase(.uppercase)
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
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? DotTheme.sidebarSelectedFill
                            : DotTheme.sidebarHoverFill.opacity(isHovered ? 1 : 0)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? DotTheme.sidebarSelectedBorder : .clear,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isSelected ? DotTheme.cardShadow : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
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
        VStack(alignment: .leading, spacing: 12) {
            recordingCard
            deliveryCard
            inputCard
                .dotSelectLayer()
            updatesCard
            revealLogLink
        }
    }

    private var recordingCard: some View {
        settingsCard("Recording", symbol: "command") {
            VStack(spacing: 0) {
                shortcutRow(
                    title: "Record",
                    keycap: config.hotkey.keycapLabel,
                    action: onChangeShortcut,
                    hint: "Opens the recorder. Escape cancels."
                )
                cardDivider
                shortcutRow(
                    title: "Paste",
                    keycap: config.pasteHotkey.keycapLabel,
                    action: onChangePasteShortcut,
                    hint: "Opens the recorder for the paste shortcut."
                )
            }
        }
    }

    private var deliveryCard: some View {
        settingsCard("Delivery", symbol: "arrow.down.doc") {
            VStack(spacing: 0) {
                toggleRow(
                    title: "Auto-paste",
                    subtitle: "Automatically paste transcribed text at your cursor",
                    isOn: autoPasteBinding
                )
                if config.autoPaste && !Paste.accessibilityGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DotTheme.coral)
                        Text("Accessibility permission required to paste automatically.")
                            .font(.system(size: 11))
                            .foregroundStyle(DotTheme.coral)
                        Spacer()
                        Button("Grant Access") {
                            Paste.requestAccessibility()
                            SystemAction.openAccessibilitySettings()
                        }
                        .buttonStyle(DotSecondaryButtonStyle())
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                }
                cardDivider
                toggleRow(
                    title: "Fast record",
                    subtitle: "Single-click the menu bar icon to start or stop recording",
                    isOn: fastRecordBinding
                )
                cardDivider
                VStack(spacing: 5) {
                    toggleRow(
                        title: "Launch at login",
                        isOn: launchBinding
                    )
                    if let launchError {
                        statusLine(launchError, tone: DotTheme.coral)
                            .padding(.bottom, 2)
                    }
                }
                cardDivider
                dwellRow
                cardDivider
                toggleRow(
                    title: "Log transcripts",
                    isOn: logTranscriptsBinding
                )
            }
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            inputControl
        }
    }

    private var inputControl: some View {
        settingsCard("Input", symbol: "mic") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DotTheme.ink)
                }
                Spacer(minLength: 12)
                DotSelect(
                    label: "Microphone",
                    options: microphoneOptions,
                    selection: microphoneBinding,
                    placeholder: "System Default",
                    width: 210
                )
            }
        }
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

    private var updatesCard: some View {
        settingsCard("Updates", symbol: "arrow.triangle.2.circlepath") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dot Beta")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DotTheme.ink)
                    Text("Check for updates and release notes.")
                        .font(.system(size: 11))
                        .foregroundStyle(DotTheme.ink3)
                }
                Spacer(minLength: 12)
                Button {
                    UpdateController.shared.checkForUpdates(userInitiated: true)
                } label: {
                    Text("Check for updates…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DotTheme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(DotTheme.fieldFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(DotTheme.fieldBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
    }

    private var revealLogLink: some View {
        HStack {
            Button {
                SystemAction.revealLog()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9.5, weight: .medium))
                    Text("Reveal log in Finder")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(DotTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reveal log in Finder")
            .accessibilityHint("Shows the Dot log in Finder.")
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
        .padding(.top, 6)
    }

    private var dwellRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("HUD dwell")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DotTheme.ink)

            Spacer(minLength: 8)

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

            Text(String(format: "%.1f s", liveDwellSeconds))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DotTheme.ink)
                .frame(width: 44, alignment: .center)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
                        )
                )
        }
        .padding(.vertical, 5)
    }

    // MARK: - Provider

    private var providerPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectCard
                .dotSelectLayer()
            if selectedPreset.hasEndpoint {
                endpointCard
                    .dotSelectLayer()
            }
            if config.provider == ProviderIdentifier.azure {
                azureOptionsCard
                    .dotSelectLayer()
            }
            if config.provider == ProviderIdentifier.groq {
                groqOptionsCard
                    .dotSelectLayer()
            }
            if config.provider == ProviderIdentifier.openAI {
                openAIOptionsCard
                    .dotSelectLayer()
            }
            if config.provider == ProviderIdentifier.deepgram {
                deepgramOptionsCard
            }
            if config.provider == ProviderIdentifier.elevenLabs {
                elevenLabsOptionsCard
                    .dotSelectLayer()
            }
            if isCustomOrOwnedEndpoint {
                endpointPrivacyRetentionCard
            }
            languageCard
                .dotSelectLayer()
            connectionCard
        }
    }

    /// The one card a person needs.
    ///
    /// It lists the services Dot can use, takes the key of the one the user
    /// picked and selects it. No row is highlighted in advance, and no string
    /// here names a service: every name comes from the row itself.
    private var connectCard: some View {
        DotCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DotTheme.accent)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(DotTheme.accentSoft)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect a service")
                            .font(DotTheme.sectionFont)
                            .foregroundStyle(DotTheme.ink)
                    }
                    Spacer(minLength: 8)
                }

                serviceSelect
                    .dotSelectLayer()

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
                        .accessibilityLabel("API key")
                        .accessibilityHint("Paste the key for the service you chose. Dot stores it in the Keychain.")

                    if !hasStoredKey(selectedPreset) || !trimmedPrimaryKey.isEmpty {
                        Button(connectingPrimary ? "Connecting…" : "Connect") {
                            connect()
                        }
                        .buttonStyle(DotPrimaryButtonStyle())
                        .disabled(!canConnect)
                        .accessibilityHint("Stores the key in the macOS Keychain and selects the service.")
                    }

                    if hasStoredKey(selectedPreset) && selectedPreset.key != .none {
                        Button(role: .destructive) {
                            deleteKey(for: selectedPreset)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DotTheme.coral)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(DotTheme.fieldFill)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Delete key for \(selectedPreset.name) from Keychain")
                        .accessibilityLabel("Delete stored key from Keychain")
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    statusLine(primaryStatus.text, tone: primaryStatus.tone)
                        .accessibilityLabel(primaryStatus.text)
                    if let detail = primaryStatus.detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The picker of the connect card: one row per service Dot can reach.
    ///
    /// The list is ``DotSelect``, the app's own control, not a system pop-up.
    /// Its rows come from ``ProviderPreset/rows(for:)``, so a configuration
    /// written before a row was retired is presented as the custom endpoint it
    /// is — with its own provider id, so choosing it cannot re-point anything.
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
            width: 280,
            openForPreview: providerMenuOpen
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

    /// The live line under the key field.
    ///
    /// It describes what the chosen row needs and what Dot did, never which
    /// service Dot expected.
    private var primaryStatus: (text: String, detail: String?, tone: Color) {
        if connectingPrimary {
            return ("Connecting…", nil, DotTheme.accent)
        }
        if let keyStatus {
            return (keyStatus.text, keyStatus.detail, keyStatus.tone.color)
        }
        let preset = selectedPreset
        switch preset.key {
        case .none:
            return (
                "\(preset.name) is selected",
                nil,
                DotTheme.mint
            )
        case .optional:
            guard hasStoredKey(preset) else {
                return ("No key (optional)", nil, DotTheme.ink3)
            }
        case .required:
            guard hasStoredKey(preset) else {
                return ("No key yet", nil, DotTheme.amber)
            }
        }
        return (
            "Connected · \(preset.name)",
            nil,
            DotTheme.mint
        )
    }

    /// The placeholder of the key field: about the key, never about a vendor.
    private var keyPlaceholder: String {
        let preset = selectedPreset
        switch preset.key {
        case .none:
            return "No key needed"
        case .optional:
            return hasStoredKey(preset) ? "Replace the API key" : "Paste the API key (optional)"
        case .required:
            return hasStoredKey(preset) ? "Replace the API key" : "Paste the API key"
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
            text: preset.key == .none ? "Selected · \(preset.name)" : "Connected · \(preset.name)",
            detail: nil,
            tone: .good
        )
        refreshModels()
        updateLanguageForModel(currentConfiguredModel)
    }

    private func deleteKey(for preset: ProviderPreset) {
        if let error = onDeleteAPIKey(preset.providerID) {
            keyStatus = KeyStatus(text: "Could not delete key", detail: error, tone: .bad)
        } else {
            savedProviders.remove(preset.providerID)
            primaryKey = ""
            keyStatus = KeyStatus(text: "Key deleted from Keychain", detail: nil, tone: .neutral)
            revision += 1
            onChange()
        }
    }

    private var availableLanguages: [AvailableLanguage] {
        ProviderLanguageCatalog.languages(for: config.provider, model: currentConfiguredModel)
    }

    private var currentConfiguredModel: String? {
        let m = config.settings(for: config.provider).model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m, !m.isEmpty { return m }
        return selectedPreset.model
    }

    private var languageSubtitle: String? {
        if let model = currentConfiguredModel?.lowercased(), model.contains("-en") {
            return "English-only model (fixed to English)"
        }
        return nil
    }

    private var languageCard: some View {
        settingsCard("Language", symbol: "globe") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spoken language")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DotTheme.ink)
                        .lineLimit(1)
                    if let languageSubtitle {
                        Text(languageSubtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
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

    private var endpointCard: some View {
        settingsCard("Endpoint", symbol: "server.rack") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    if config.provider == ProviderIdentifier.azure {
                        endpointField(
                            "Base URL",
                            placeholder: baseURLPlaceholder,
                            field: .baseURL,
                            text: baseURLBinding
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            fieldLabel("Region")
                            DotSelect(
                                label: "Region",
                                options: AzureSpeechProvider.supportedRegions.map { item in
                                    DotSelectOption(
                                        value: item.id,
                                        title: item.title
                                    )
                                },
                                selection: azureRegionBinding,
                                placeholder: AzureSpeechProvider.defaultRegion,
                                width: 175
                            )
                        }
                        .dotSelectLayer()
                        VStack(alignment: .leading, spacing: 4) {
                            fieldLabel("Mode")
                            DotSelect(
                                label: "Mode",
                                options: AzureSpeechProvider.supportedModes.map { item in
                                    DotSelectOption(
                                        value: item.id,
                                        title: item.title,
                                        detail: item.detail
                                    )
                                },
                                selection: azureModeBinding,
                                placeholder: AzureSpeechProvider.defaultRecognitionMode,
                                width: 150
                            )
                        }
                        .dotSelectLayer()
                    } else {
                        endpointField(
                            "Base URL",
                            placeholder: baseURLPlaceholder,
                            field: .baseURL,
                            text: baseURLBinding
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .center, spacing: 6) {
                                fieldLabel("Model")
                                if isLoadingModels {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.65)
                                } else {
                                    Button {
                                        refreshModels()
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(DotTheme.ink3)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Load models from provider API")
                                    .accessibilityLabel("Load models from provider API")
                                }
                            }
                            DotSelect(
                                label: "Model",
                                options: modelOptions,
                                selection: currentModelSelectionBinding,
                                placeholder: modelPlaceholder,
                                width: 250
                            )
                            .dotSelectLayer()
                            if isCustomModelSelected {
                                endpointField(
                                    "Custom model id",
                                    placeholder: modelPlaceholder,
                                    field: .model,
                                    text: modelBinding
                                )
                                .padding(.top, 4)
                            }
                        }
                        .dotSelectLayer()
                    }
                }
                .dotSelectLayer()

                if ProviderRegistry.isGenericEndpoint(config: config) {
                    authStyleRow
                        .dotSelectLayer()
                }

            }
        }
    }

    private var deepgramOptionsCard: some View {
        settingsCard("Transcription options", symbol: "slider.horizontal.3") {
            VStack(spacing: 0) {
                toggleRow(
                    title: "Smart formatting",
                    subtitle: "Automatically format dates, times, currency, emails, and phone numbers",
                    isOn: deepgramBoolBinding(\.smartFormat, default: true)
                )
                cardDivider
                toggleRow(
                    title: "Punctuation & capitalization",
                    subtitle: "Add natural punctuation and sentence casing to transcripts",
                    isOn: deepgramBoolBinding(\.punctuate, default: true)
                )
                cardDivider
                toggleRow(
                    title: "Paragraphs",
                    subtitle: "Split longer transcripts into structured paragraphs",
                    isOn: deepgramBoolBinding(\.paragraphs, default: false)
                )
                cardDivider
                toggleRow(
                    title: "Numerals",
                    subtitle: "Convert spoken numbers into digits",
                    isOn: deepgramBoolBinding(\.numerals, default: false)
                )
                cardDivider
                toggleRow(
                    title: "Filler words",
                    subtitle: "Keep conversational hesitations (uh, um) in the transcript",
                    isOn: deepgramBoolBinding(\.fillerWords, default: false)
                )
                cardDivider
                toggleRow(
                    title: "Profanity filter",
                    subtitle: "Mask detected profanity in the output text",
                    isOn: deepgramBoolBinding(\.profanityFilter, default: false)
                )
                cardDivider
                toggleRow(
                    title: "Speaker diarization",
                    subtitle: "Detect speaker changes across multi-person audio",
                    isOn: deepgramBoolBinding(\.diarize, default: false)
                )
                cardDivider
                toggleRow(
                    title: "Opt out of Model Improvement (mip_opt_out)",
                    subtitle: "Sends mip_opt_out=true so Deepgram does not retain audio or transcripts for model training",
                    isOn: zdrBinding
                )
                cardDivider
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Keyterms / custom vocabulary")
                    TextField(
                        "Comma-separated terms, names, or technical jargon",
                        text: deepgramKeytermsBinding
                    )
                    .modifier(DotFieldStyle(focused: focusedField == .keyterms))
                    .focused($focusedField, equals: .keyterms)
                }
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
        }
    }

    private var elevenLabsOptionsCard: some View {
        settingsCard("Transcription options", symbol: "slider.horizontal.3") {
            VStack(spacing: 0) {
                toggleRow(
                    title: "Clean verbatim (filter fillers & false starts)",
                    subtitle: "Remove conversational hesitations, stutters, and false starts (no_verbatim)",
                    isOn: elevenLabsBoolBinding(\.noVerbatim, default: false)
                )
                cardDivider
                toggleRow(
                    title: "Tag non-speech audio events",
                    subtitle: "Include sound event tags such as (laughter) or (applause) in the transcript",
                    isOn: elevenLabsBoolBinding(\.tagAudioEvents, default: false)
                )
                cardDivider
                toggleRow(
                    title: "Disable server-side logging (enable_logging: false)",
                    subtitle: "Passes enable_logging=false so ElevenLabs does not log or persist audio files on their servers",
                    isOn: zdrBinding
                )
                cardDivider
                toggleRow(
                    title: "Speaker diarization",
                    subtitle: "Identify up to 32 distinct speakers across multi-person audio",
                    isOn: elevenLabsBoolBinding(\.diarize, default: false)
                )
                if config.settings(for: ProviderIdentifier.elevenLabs).diarize == true {
                    cardDivider
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Max speakers")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(DotTheme.ink)
                            Text("Optional maximum speaker count (1–32), or Auto")
                                .font(.system(size: 10.5))
                                .foregroundStyle(DotTheme.ink3)
                        }
                        Spacer(minLength: 12)
                        TextField("Auto", text: elevenLabsNumSpeakersBinding)
                            .modifier(DotFieldStyle(focused: focusedField == .numSpeakers))
                            .focused($focusedField, equals: .numSpeakers)
                            .frame(width: 84)
                    }
                    .padding(.vertical, 8)
                    cardDivider
                    toggleRow(
                        title: "Detect speaker roles",
                        subtitle: "Automatically label speakers as agent and customer",
                        isOn: elevenLabsBoolBinding(\.detectSpeakerRoles, default: false)
                    )
                    cardDivider
                    toggleRow(
                        title: "Match workspace speaker library",
                        subtitle: "Match diarized voices against your registered speaker profiles",
                        isOn: elevenLabsBoolBinding(\.useSpeakerLibrary, default: false)
                    )
                }
                cardDivider
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Timestamps granularity")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DotTheme.ink)
                        Text("Precision level for word or character timing metadata")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                    }
                    Spacer(minLength: 12)
                    DotSelect(
                        label: "Timestamps granularity",
                        options: ElevenLabsProvider.granularityOptions.map { item in
                            DotSelectOption(value: item.id, title: item.title)
                        },
                        selection: elevenLabsGranularityBinding,
                        width: 170
                    )
                }
                .padding(.vertical, 8)
                .dotSelectLayer()
                cardDivider
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Entity detection")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DotTheme.ink)
                        Text("Detect PII, PHI, payment card data, or offensive language")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                    }
                    Spacer(minLength: 12)
                    DotSelect(
                        label: "Entity detection",
                        options: ElevenLabsProvider.entityDetectionOptions.map { item in
                            DotSelectOption(value: item.id, title: item.title)
                        },
                        selection: elevenLabsEntityDetectionBinding,
                        width: 220
                    )
                }
                .padding(.vertical, 8)
                .dotSelectLayer()
                cardDivider
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Keyterms / custom vocabulary")
                    TextField(
                        "Comma-separated terms, product names, or proper nouns (up to 100)",
                        text: elevenLabsKeytermsBinding
                    )
                    .modifier(DotFieldStyle(focused: focusedField == .keyterms))
                    .focused($focusedField, equals: .keyterms)
                }
                .padding(.top, 8)
                .padding(.bottom, 6)
                cardDivider
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Transcript formatting prompt (transcript_edit)")
                    TextField(
                        "Optional instruction to format or normalize output (e.g. ISO dates, bullet points)",
                        text: elevenLabsTranscriptEditBinding
                    )
                    .modifier(DotFieldStyle(focused: focusedField == .transcriptEdit))
                    .focused($focusedField, equals: .transcriptEdit)
                }
                .padding(.top, 8)
                .padding(.bottom, 2)
            }
        }
    }

    private var groqOptionsCard: some View {
        settingsCard("Inference options", symbol: "bolt.fill") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Temperature")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DotTheme.ink)
                        Text("Controls randomness; 0.0 is deterministic and recommended for dictation")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                    }
                    Spacer(minLength: 12)
                    DotSelect(
                        label: "Temperature",
                        options: [
                            DotSelectOption(value: 0.0, title: "0.0 · Deterministic"),
                            DotSelectOption(value: 0.2, title: "0.2 · Low randomness"),
                            DotSelectOption(value: 0.5, title: "0.5 · Balanced"),
                            DotSelectOption(value: 0.8, title: "0.8 · Creative"),
                            DotSelectOption(value: 1.0, title: "1.0 · High variety"),
                        ],
                        selection: Binding(
                            get: { config.settings(for: ProviderIdentifier.groq).temperature ?? 0.0 },
                            set: { val in
                                var settings = config.settings(for: ProviderIdentifier.groq)
                                settings.temperature = val
                                config.providers[ProviderIdentifier.groq] = settings
                                revision &+= 1
                                onChange()
                            }
                        ),
                        placeholder: "0.0",
                        width: 175
                    )
                }
                .padding(.vertical, 8)
                .dotSelectLayer()
                cardDivider
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Response format")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DotTheme.ink)
                        Text("Format returned by the transcription endpoint")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                    }
                    Spacer(minLength: 12)
                    DotSelect(
                        label: "Response format",
                        options: [
                            DotSelectOption(value: "json", title: "JSON (Standard)"),
                            DotSelectOption(value: "verbose_json", title: "Verbose JSON (Timestamps)"),
                            DotSelectOption(value: "text", title: "Plain Text"),
                        ],
                        selection: Binding(
                            get: { config.settings(for: ProviderIdentifier.groq).responseFormat ?? "json" },
                            set: { val in
                                var settings = config.settings(for: ProviderIdentifier.groq)
                                settings.responseFormat = val
                                config.providers[ProviderIdentifier.groq] = settings
                                revision &+= 1
                                onChange()
                            }
                        ),
                        placeholder: "json",
                        width: 175
                    )
                }
                .padding(.vertical, 8)
                .dotSelectLayer()
                if (config.settings(for: ProviderIdentifier.groq).responseFormat ?? "json") == "verbose_json" {
                    cardDivider
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Timestamp granularity")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(DotTheme.ink)
                            Text("Timestamp detail level in verbose JSON responses")
                                .font(.system(size: 10.5))
                                .foregroundStyle(DotTheme.ink3)
                        }
                        Spacer(minLength: 12)
                        DotSelect(
                            label: "Timestamp granularity",
                            options: [
                                DotSelectOption(value: "segment", title: "Segment (Default)"),
                                DotSelectOption(value: "word", title: "Word"),
                                DotSelectOption(value: "both", title: "Word & Segment"),
                            ],
                            selection: Binding(
                                get: { config.settings(for: ProviderIdentifier.groq).timestampsGranularity ?? "segment" },
                                set: { val in
                                    var settings = config.settings(for: ProviderIdentifier.groq)
                                    settings.timestampsGranularity = val
                                    config.providers[ProviderIdentifier.groq] = settings
                                    revision &+= 1
                                    onChange()
                                }
                            ),
                            placeholder: "Segment",
                            width: 175
                        )
                    }
                    .padding(.vertical, 8)
                    .dotSelectLayer()
                }
                cardDivider
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Prompt & Context Hint")
                    TextField(
                        "Optional guide for vocabulary, acronyms, or dictation style…",
                        text: Binding(
                            get: { config.settings(for: ProviderIdentifier.groq).prompt ?? "" },
                            set: { val in
                                var settings = config.settings(for: ProviderIdentifier.groq)
                                settings.prompt = val.isEmpty ? nil : val
                                config.providers[ProviderIdentifier.groq] = settings
                                revision &+= 1
                                onChange()
                            }
                        )
                    )
                    .textFieldStyle(.plain)
                    .modifier(DotFieldStyle(focused: focusedField == .groqPrompt))
                    .focused($focusedField, equals: .groqPrompt)
                    Text("Helps correctly transcribe technical terms, uncommon proper names, and domain jargon.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DotTheme.ink3)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var openAIOptionsCard: some View {
        settingsCard("Transcription options", symbol: "slider.horizontal.3") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Temperature")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DotTheme.ink)
                        Text("Controls randomness; 0.0 is deterministic and recommended for dictation")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                    }
                    Spacer(minLength: 12)
                    DotSelect(
                        label: "Temperature",
                        options: [
                            DotSelectOption(value: 0.0, title: "0.0 · Deterministic"),
                            DotSelectOption(value: 0.2, title: "0.2 · Low randomness"),
                            DotSelectOption(value: 0.5, title: "0.5 · Balanced"),
                            DotSelectOption(value: 0.8, title: "0.8 · Creative"),
                            DotSelectOption(value: 1.0, title: "1.0 · High variety"),
                        ],
                        selection: Binding(
                            get: { config.settings(for: ProviderIdentifier.openAI).temperature ?? 0.0 },
                            set: { val in
                                var settings = config.settings(for: ProviderIdentifier.openAI)
                                settings.temperature = val
                                config.providers[ProviderIdentifier.openAI] = settings
                                revision &+= 1
                                onChange()
                            }
                        ),
                        placeholder: "0.0",
                        width: 175
                    )
                }
                .padding(.vertical, 8)
                .dotSelectLayer()
                cardDivider
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Response format")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DotTheme.ink)
                        Text("Format returned by the transcription endpoint")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                    }
                    Spacer(minLength: 12)
                    DotSelect(
                        label: "Response format",
                        options: [
                            DotSelectOption(value: "json", title: "JSON (Standard)"),
                            DotSelectOption(value: "verbose_json", title: "Verbose JSON (Timestamps)"),
                            DotSelectOption(value: "text", title: "Plain Text"),
                            DotSelectOption(value: "srt", title: "SRT Subtitles"),
                            DotSelectOption(value: "vtt", title: "VTT Subtitles"),
                        ],
                        selection: Binding(
                            get: { config.settings(for: ProviderIdentifier.openAI).responseFormat ?? "json" },
                            set: { val in
                                var settings = config.settings(for: ProviderIdentifier.openAI)
                                settings.responseFormat = val
                                config.providers[ProviderIdentifier.openAI] = settings
                                revision &+= 1
                                onChange()
                            }
                        ),
                        placeholder: "json",
                        width: 175
                    )
                }
                .padding(.vertical, 8)
                .dotSelectLayer()
                if (config.settings(for: ProviderIdentifier.openAI).responseFormat ?? "json") == "verbose_json" {
                    cardDivider
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Timestamp granularity")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(DotTheme.ink)
                            Text("Timestamp detail level in verbose JSON responses")
                                .font(.system(size: 10.5))
                                .foregroundStyle(DotTheme.ink3)
                        }
                        Spacer(minLength: 12)
                        DotSelect(
                            label: "Timestamp granularity",
                            options: [
                                DotSelectOption(value: "segment", title: "Segment (Default)"),
                                DotSelectOption(value: "word", title: "Word"),
                                DotSelectOption(value: "both", title: "Word & Segment"),
                            ],
                            selection: Binding(
                                get: { config.settings(for: ProviderIdentifier.openAI).timestampsGranularity ?? "segment" },
                                set: { val in
                                    var settings = config.settings(for: ProviderIdentifier.openAI)
                                    settings.timestampsGranularity = val
                                    config.providers[ProviderIdentifier.openAI] = settings
                                    revision &+= 1
                                    onChange()
                                }
                            ),
                            placeholder: "Segment",
                            width: 175
                        )
                    }
                    .padding(.vertical, 8)
                    .dotSelectLayer()
                }
                cardDivider
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Prompt & Context Hint")
                    TextField(
                        "Optional guide for vocabulary, acronyms, or dictation style…",
                        text: Binding(
                            get: { config.settings(for: ProviderIdentifier.openAI).prompt ?? "" },
                            set: { val in
                                var settings = config.settings(for: ProviderIdentifier.openAI)
                                settings.prompt = val.isEmpty ? nil : val
                                config.providers[ProviderIdentifier.openAI] = settings
                                revision &+= 1
                                onChange()
                            }
                        )
                    )
                    .textFieldStyle(.plain)
                    .modifier(DotFieldStyle(focused: focusedField == .openAIPrompt))
                    .focused($focusedField, equals: .openAIPrompt)
                    Text("Helps correctly transcribe technical terms, uncommon proper names, and domain jargon.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DotTheme.ink3)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var azureOptionsCard: some View {
        settingsCard("Recognition options", symbol: "slider.horizontal.3") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Profanity filter")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DotTheme.ink)
                        Text("Choose how offensive or profane speech is handled")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                    }
                    Spacer(minLength: 12)
                    DotSelect(
                        label: "Profanity filter",
                        options: AzureSpeechProvider.supportedProfanityModes.map { item in
                            DotSelectOption(value: item.id, title: item.title, detail: item.detail)
                        },
                        selection: azureProfanityBinding,
                        placeholder: "Masked (***)",
                        width: 190
                    )
                }
                .padding(.vertical, 8)
                .dotSelectLayer()
                cardDivider
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Output format")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DotTheme.ink)
                        Text("Select detailed capitalization & punctuation or simple output")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                    }
                    Spacer(minLength: 12)
                    DotSelect(
                        label: "Output format",
                        options: AzureSpeechProvider.supportedOutputFormats.map { item in
                            DotSelectOption(value: item.id, title: item.title, detail: item.detail)
                        },
                        selection: azureOutputFormatBinding,
                        placeholder: "Detailed",
                        width: 190
                    )
                }
                .padding(.vertical, 8)
                .dotSelectLayer()
                cardDivider
                toggleRow(
                    title: "Store audio in Azure",
                    subtitle: "Sends storeAudio=true. Disabled by default (storeAudio=false) for zero data retention",
                    isOn: azureStoreAudioBinding
                )
            }
        }
    }

    private var isCustomOrOwnedEndpoint: Bool {
        selectedPreset.id == ProviderPreset.custom.id
            || (ProviderRegistry.isGenericEndpoint(config: config) && config.provider != ProviderIdentifier.openAI)
    }

    private var endpointPrivacyRetentionCard: some View {
        settingsCard("Privacy & retention", symbol: "lock.shield") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(DotTheme.ink2)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Endpoint Retention Policy")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DotTheme.ink)
                    Text("Audio processing and retention policies are determined by the host of your custom endpoint.")
                        .font(.system(size: 11))
                        .foregroundStyle(DotTheme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }

    private func endpointField(
        _ label: String,
        placeholder: String,
        field: Field,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .modifier(DotFieldStyle(focused: focusedField == field))
                .focused($focusedField, equals: field)
                .accessibilityLabel(label)
                .accessibilityHint("The \(label.lowercased()) sent with every transcription request.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The header the key travels in.
    ///
    /// Only an endpoint Dot calls with the OpenAI shape reads this setting;
    /// every other provider puts its key where its own API documents it.
    private var authStyleRow: some View {
        HStack(spacing: 12) {
            Text("Auth header")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DotTheme.ink)
            Spacer(minLength: 12)
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

    private var connectionCard: some View {
        settingsCard("Connection", symbol: "bolt.horizontal") {
            testSection
        }
    }

    private var testSection: some View {
        HStack(spacing: 10) {
            Button(testing ? "Testing…" : "Test Connection") {
                runTest()
            }
            .buttonStyle(DotSecondaryButtonStyle())
            .disabled(testing)
            .accessibilityHint("Asks the selected service whether it can transcribe right now.")
            if let testResult {
                statusLine(testResult.text, tone: testResult.ok ? DotTheme.mint : DotTheme.coral)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Shortcuts

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCard("Global shortcuts", symbol: "command") {
                VStack(spacing: 0) {
                    shortcutRow(
                        title: "Record",
                        keycap: config.hotkey.keycapLabel,
                        action: onChangeShortcut,
                        hint: "Opens the recorder. Escape cancels."
                    )
                    cardDivider
                    shortcutRow(
                        title: "Paste",
                        keycap: config.pasteHotkey.keycapLabel,
                        action: onChangePasteShortcut,
                        hint: "Opens the recorder for the paste shortcut."
                    )
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            windowAppearanceCard

            sectionHeading("HUD material", symbol: "rectangle.on.rectangle")
                .padding(.top, 2)

            HStack(alignment: .top, spacing: 10) {
                materialCard(.glass, name: "Glass")
                materialCard(.black, name: "Black")
            }

            sectionHeading("Audio wave effect", symbol: "waveform")
                .padding(.top, 6)

            visualizerSection
        }
    }

    private var windowAppearanceCard: some View {
        settingsCard("Window appearance", symbol: "circle.lefthalf.filled") {
            HStack(alignment: .top, spacing: 10) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    appearanceCard(mode)
                }
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appearanceName(mode))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DotTheme.ink)
                    }
                    Spacer(minLength: 2)
                    selectionIndicator(isSelected)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? DotTheme.cardSelectedFill : DotTheme.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? DotTheme.cardBorderSelected : DotTheme.cardBorder,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(appearanceName(mode)) window appearance")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(appearanceHint(mode))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DotTheme.accent)
            Text(title)
                .font(DotTheme.labelFont)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(DotTheme.ink3)
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .frame(height: 16)
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
            VStack(alignment: .leading, spacing: 10) {
                HUDSwatch(material: material)
                HStack(alignment: .top, spacing: 10) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DotTheme.ink)
                    Spacer(minLength: 4)
                    selectionIndicator(isSelected)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? DotTheme.cardSelectedFill : DotTheme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? DotTheme.cardBorderSelected : DotTheme.cardBorder,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) HUD material")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Uses the \(name.lowercased()) material for the recording HUD.")
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
                    Spacer(minLength: 4)
                    selectionIndicator(isSelected)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? DotTheme.cardSelectedFill : DotTheme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? DotTheme.cardBorderSelected : DotTheme.cardBorder,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(visualizer.title) audio wave visualizer")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(visualizer.detail)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - About

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            AboutIdentity(version: version, tagline: DotLinks.tagline)

            DotCard(padding: 8) {
                VStack(spacing: 0) {
                    aboutRow("Check for updates…", symbol: "arrow.triangle.2.circlepath") {
                        UpdateController.shared.checkForUpdates(userInitiated: true)
                    }
                    aboutHairline
                    aboutRow(
                        "Support Dot",
                        detail: DotLinks.displayBuyMeACoffee,
                        symbol: "cup.and.saucer.fill"
                    ) {
                        NSWorkspace.shared.open(DotLinks.buyMeACoffee)
                    }
                    aboutHairline
                    aboutRow(
                        "GitHub",
                        detail: DotLinks.displayGitHub,
                        symbol: "arrow.up.right"
                    ) {
                        NSWorkspace.shared.open(DotLinks.github)
                    }
                    aboutHairline
                    aboutRow("Website", detail: DotLinks.website.host, symbol: "globe") {
                        NSWorkspace.shared.open(DotLinks.website)
                    }
                    aboutHairline
                    aboutRow("Show welcome tour", symbol: "sparkles") {
                        onOpenWelcome()
                    }
                    aboutHairline
                    aboutRow("Open log", symbol: "doc.text.magnifyingglass") {
                        SystemAction.revealLog()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aboutHairline: some View {
        Rectangle()
            .fill(DotTheme.hairline)
            .frame(height: 1)
            .padding(.leading, 4)
    }

    private func aboutRow(
        _ title: String,
        detail: String? = nil,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        AboutActionRow(title: title, detail: detail, symbol: symbol, action: action)
    }

    // MARK: - Pieces

    private func settingsCard<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        DotCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle(title, symbol: symbol)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }


    private func cardTitle(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DotTheme.accent)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DotTheme.accentSoft)
                )
            Text(title)
                .font(DotTheme.labelFont)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(DotTheme.ink3)
            Spacer(minLength: 0)
        }
        .frame(height: 20)
    }

    private func shortcutRow(
        title: String,
        keycap: String,
        action: @escaping () -> Void,
        hint: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DotTheme.ink)
            Spacer(minLength: 8)
            DotKeycap(text: keycap)
            Button("Change…", action: action)
                .buttonStyle(DotSecondaryButtonStyle())
                .accessibilityLabel("Change \(title.lowercased()) shortcut")
                .accessibilityHint(hint)
        }
        .padding(.vertical, 5)
    }

    private func toggleRow(
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DotTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DotTheme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(DotToggleStyle())
                .accessibilityLabel(title)
        }
        .padding(.vertical, 5)
    }

    private func selectionIndicator(_ selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(selected ? DotTheme.accent : Color.clear)
            Circle()
                .strokeBorder(
                    selected ? Color.clear : DotTheme.selectionRing,
                    lineWidth: 1.2
                )
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DotTheme.onAccent)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private func statusLine(_ text: String, tone: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle()
                .fill(tone)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(DotTheme.ink2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    /// Shortcut glyphs are wide and touch in a monospaced face. Hair spaces
    /// keep the keycap readable without changing its label.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(DotTheme.ink3)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(DotTheme.hairline)
            .frame(height: 1)
    }

    /// The row the configuration presents.
    ///
    /// The selection is derived from the configuration, never stored: a URL the
    /// user types is exactly what the custom row means, and a provider id with
    /// no offered row is presented as the custom endpoint that owns it, so the
    /// list and the endpoint fields cannot disagree.
    private var selectedPreset: ProviderPreset {
        ProviderPreset.presenting(config)
    }

    private var baseURLPlaceholder: String {
        selectedPreset.baseURL ?? "https://…/v1"
    }

    private var modelPlaceholder: String {
        selectedPreset.model ?? "model id"
    }

    private func presetDetail(_ preset: ProviderPreset) -> String {
        if !preset.hasEndpoint { return "On this Mac" }
        let currentModel = config.settings(for: preset.providerID).model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let currentModel, !currentModel.isEmpty {
            return ProviderModelCatalog.formattedName(for: currentModel)
        }
        if preset.key == .required {
            return "Requires API key"
        }
        return "Custom endpoint"
    }
    private var version: String {
        if let versionOverride {
            return versionOverride
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0-beta"
    }

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

    private var modelOptions: [DotSelectOption<String>] {
        var opts: [DotSelectOption<String>] = []

        if isLoadingModels {
            opts.append(DotSelectOption(value: "__loading__", title: "Loading models from API…", detail: "Querying provider models endpoint", symbol: "arrow.clockwise"))
        } else if availableModels.isEmpty {
            let key = trimmedPrimaryKey.isEmpty ? CredentialCache.shared.key(for: config.provider) : trimmedPrimaryKey
            if key == nil || key!.isEmpty {
                opts.append(DotSelectOption(value: "__need_key__", title: "Connect API key to load models", detail: "Available models will be fetched automatically from your API key", symbol: "key.fill"))
            } else {
                opts.append(DotSelectOption(value: "__no_models__", title: "No models returned by API", detail: "Select Custom model below to enter an identifier", symbol: "exclamationmark.triangle"))
            }
        } else {
            opts.append(contentsOf: availableModels.map { m in
                DotSelectOption(value: m.id, title: m.name, detail: m.detail)
            })
        }

        let current = config.settings(for: config.provider).model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !current.isEmpty, !opts.contains(where: { $0.value == current }) {
            opts.insert(DotSelectOption(value: current, title: ProviderModelCatalog.formattedName(for: current), detail: ProviderModelCatalog.modelDetail(for: current)), at: 0)
        }
        opts.append(DotSelectOption(value: "__custom__", title: "Custom model…", detail: "Type a custom model identifier", symbol: "pencil"))
        return opts
    }

    private var currentModelSelectionBinding: Binding<String> {
        Binding(
            get: {
                if isCustomModelSelected { return "__custom__" }
                let current = config.settings(for: config.provider).model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !current.isEmpty {
                    return current
                }
                if let first = availableModels.first {
                    return first.id
                }
                let key = trimmedPrimaryKey.isEmpty ? CredentialCache.shared.key(for: config.provider) : trimmedPrimaryKey
                if key == nil || key!.isEmpty {
                    return "__need_key__"
                }
                return "__custom__"
            },
            set: { val in
                if val == "__custom__" {
                    isCustomModelSelected = true
                } else if val == "__need_key__" || val == "__loading__" || val == "__no_models__" {
                    focusedField = .apiKey
                } else {
                    isCustomModelSelected = false
                    var settings = config.settings(for: config.provider)
                    settings.model = val
                    config.providers[config.provider] = settings
                    revision &+= 1
                    onChange()
                    updateLanguageForModel(val)
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

    /// Applies a row and moves the keyboard to the field the user has to fill
    /// in next.
    private func choose(_ preset: ProviderPreset) {
        keyStatus = nil
        testResult = nil
        let wasCustom = selectedPreset.id == ProviderPreset.custom.id
        if preset.id == ProviderPreset.custom.id, !wasCustom {
            // Choosing the hand-filled row means the endpoint is the user's own.
            // A URL that came from another row is not one, so it is cleared
            // rather than presented as theirs.
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

    private func runTest() {
        guard !testing else { return }
        let preset = selectedPreset
        testing = true
        testResult = nil
        Task { @MainActor in
            let ok = await onTest(preset.providerID)
            testResult = TestResult(
                text: ok ? "Connected." : "Not available. Check the service and the key.",
                ok: ok
            )
            testing = false
        }
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
        case openAIPrompt
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
                                ? [HUDTheme.live.opacity(0.95), HUDTheme.accent]
                                : [HUDTheme.accent.opacity(0.85), HUDTheme.accent.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2.2, height: h)
                    .shadow(color: isPeak ? HUDTheme.live.opacity(0.35) : .clear, radius: 2)
            }
        }
    }
}

/// An ultra-smooth, responsive modern macOS slider with continuous local dragging,
/// tactile spring feedback, subtle gradient fill, and debounced commit.
private struct DotModernSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onCommit: () -> Void

    @State private var dragPosition: Double?
    @State private var isDragging: Bool = false
    @State private var isHovering: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let thumbDiameter: CGFloat = 16
            let usableWidth = max(1, totalWidth - thumbDiameter)
            let currentValue = dragPosition ?? value
            let progress = max(0, min(1, (currentValue - range.lowerBound) / (range.upperBound - range.lowerBound)))
            let thumbX = progress * usableWidth

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.16))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                    )
                    .frame(height: 5)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                DotTheme.accent,
                                DotTheme.accent.opacity(0.82),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(thumbDiameter / 2, thumbX + thumbDiameter / 2), height: 5)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white,
                                Color(red: 0.94, green: 0.93, blue: 0.92),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 0.75)
                    )
                    .shadow(color: Color.black.opacity(isDragging ? 0.30 : 0.16), radius: isDragging ? 3 : 1.5, y: 1)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .scaleEffect(isDragging ? 1.14 : (isHovering ? 1.08 : 1.0))
                    .offset(x: thumbX)
                    .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isDragging)
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
    }
}

/// A miniature HUD used by the appearance cards.
private struct HUDSwatch: View {
    let material: HUDMaterial

    var body: some View {
        ZStack {
            if material == .glass {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.22, blue: 0.32).opacity(0.40),
                            Color(red: 0.10, green: 0.12, blue: 0.18).opacity(0.30),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Circle()
                        .fill(DotTheme.accent.opacity(0.30))
                        .frame(width: 44, height: 44)
                        .offset(x: -36, y: -8)
                        .blur(radius: 10)

                    Circle()
                        .fill(DotTheme.amber.opacity(0.20))
                        .frame(width: 32, height: 32)
                        .offset(x: 42, y: 12)
                        .blur(radius: 8)
                }

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.38),
                                Color(red: 0.04, green: 0.05, blue: 0.07).opacity(0.48),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.32), location: 0),
                                .init(color: Color.white.opacity(0.08), location: 0.30),
                                .init(color: Color.clear, location: 0.70),
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

            HUDSwatchWaveform()
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
