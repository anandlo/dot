import AppKit
import DotCore
import SwiftUI

/// The services an offscreen render treats as holding a key.
///
/// A render must not read the machine's Keychain: the two states of the page are
/// the two states of the PNG, and neither may depend on who is signed in.
struct AssistantKeyedProvidersKey: EnvironmentKey {
    static let defaultValue: Set<String>? = nil
}

/// The voices an offscreen render lists, so the picker can be looked at
/// without asking a service.
struct SettingsVoiceOptionsKey: EnvironmentKey {
    static let defaultValue: [VoiceDescriptor]? = nil
}

/// The connector rows an offscreen render draws, with their permissions.
struct SettingsConnectorSummariesKey: EnvironmentKey {
    static let defaultValue: [ConnectorSummary]? = nil
}

extension EnvironmentValues {
    /// The provider ids a render assumes are connected, if any.
    var assistantKeyedProviders: Set<String>? {
        get { self[AssistantKeyedProvidersKey.self] }
        set { self[AssistantKeyedProvidersKey.self] = newValue }
    }

    /// The voices to list instead of asking the provider, if any.
    var settingsVoiceOptions: [VoiceDescriptor]? {
        get { self[SettingsVoiceOptionsKey.self] }
        set { self[SettingsVoiceOptionsKey.self] = newValue }
    }

    /// The connectors to draw instead of asking the system, if any.
    var settingsConnectorSummaries: [ConnectorSummary]? {
        get { self[SettingsConnectorSummariesKey.self] }
        set { self[SettingsConnectorSummariesKey.self] = newValue }
    }
}

/// The Assistant page: which service answers, which model it is asked for and
/// where the answer goes.
///
/// Keys are the only thing the page writes outside the configuration: they go
/// to the Keychain through the same callbacks the Provider page uses, so the
/// item a speech key already lives in is the item a chat request reads.
@MainActor
struct AssistantPage: View {
    @Binding var config: DotConfig
    /// Called after a change that a rebuild or a save depends on.
    let onChange: () -> Void
    /// Stores a key. Returns an error message, or `nil` on success.
    let onSetKey: (String, String) -> String?
    /// Deletes a key. Returns an error message, or `nil` on success.
    let onDeleteKey: (String) -> String?

    @Environment(\.assistantKeyedProviders) private var keyedProviders

    @State private var storedKeys: Set<String>?
    @State private var keyField = ""
    @State private var connecting = false
    @State private var note: KeyNote?
    @State private var isCustomModel = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case apiKey
        case model
        case baseURL
    }

    /// Whether a service carries an address field of its own.
    ///
    /// The field is for the three kinds of row whose shipped address cannot be
    /// used as it stands: the one that has none, the two that run on this Mac,
    /// and the one that ships a resource name the person has to replace.
    private static func needsAddress(_ row: AssistantProviderRow) -> Bool {
        guard let address = row.defaultBaseURL else { return true }
        let host = address.host ?? ""
        return runsOnThisMac(row) || host.hasPrefix("example.")
    }

    /// Whether a service runs on this Mac, where there is no key to ask for.
    private static func runsOnThisMac(_ row: AssistantProviderRow) -> Bool {
        guard let host = row.defaultBaseURL?.host else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }

    /// The id a typed model is stored under while the picker shows "Custom…".
    private static let customChoice = "__custom__"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            serviceSection
            modelSection
            answersSection
            rewriteSection
        }
        .onAppear(perform: readStoredKeys)
    }

    // MARK: - Service

    private var serviceSection: some View {
        SettingsSection("Service") {
            SettingsRow("Service") {
                DotSelect(
                    label: "Service",
                    options: AssistantProviderCatalogue.rows.map { row in
                        DotSelectOption(value: row.id, title: row.name)
                    },
                    selection: providerBinding,
                    placeholder: "Choose a service",
                    width: 220
                )
            }
            if !Self.runsOnThisMac(row) {
                SettingsDivider()
                AssistantKeyRow(
                    field: $keyField,
                    hasStoredKey: hasKey(row.id),
                    isConnecting: connecting,
                    onConnect: connect,
                    onDelete: deleteKey
                )
            }
            SettingsDivider()
            SettingsRow(
                "Status",
                subtitle: note?.detail,
                subtitleTone: note?.tone.color ?? DotTheme.ink3
            ) {
                statusChip
            }
            if Self.needsAddress(row) {
                SettingsDivider()
                SettingsRow("Base URL") {
                    TextField(baseURLPlaceholder, text: baseURLBinding)
                        .modifier(DotFieldStyle(focused: focusedField == .baseURL))
                        .focused($focusedField, equals: .baseURL)
                        .frame(width: 300)
                        .accessibilityLabel("Base URL")
                }
            }
        }
    }

    /// The dot and the words that say whether a turn would be able to run.
    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? DotTheme.switchOn : DotTheme.ink3)
                .frame(width: 6, height: 6)
            Text(isConnected ? "Connected" : "Not connected")
                .font(.system(size: 11.5))
                .foregroundStyle(isConnected ? DotTheme.ink2 : DotTheme.ink3)
        }
        .accessibilityElement(children: .combine)
    }

    /// Whether a request would find what it needs: a key, or a service that
    /// runs on this Mac and asks for none.
    private var isConnected: Bool {
        !row.requiresKey || hasKey(row.id)
    }

    // MARK: - Model

    private var modelSection: some View {
        SettingsSection("Model") {
            SettingsRow("Model") {
                DotSelect(
                    label: "Model",
                    options: modelOptions,
                    selection: modelBinding,
                    placeholder: "No model",
                    width: 220
                )
            }
            if showsModelField {
                SettingsDivider()
                SettingsRow("Custom model") {
                    TextField("Model ID", text: typedModelBinding)
                        .modifier(DotFieldStyle(focused: focusedField == .model))
                        .focused($focusedField, equals: .model)
                        .frame(width: 300)
                        .accessibilityLabel("Model ID")
                }
            }
        }
    }

    /// The catalogue's suggestions for the chosen service, and the row that
    /// opens a field for anything else.
    private var modelOptions: [DotSelectOption<String>] {
        var options = row.defaultModels.map { DotSelectOption(value: $0, title: $0) }
        let current = storedModel
        if !current.isEmpty, !options.contains(where: { $0.value == current }) {
            options.insert(DotSelectOption(value: current, title: current), at: 0)
        }
        options.append(DotSelectOption(value: Self.customChoice, title: "Custom model…"))
        return options
    }

    /// Whether the field under the picker is shown: it is the only way to name a
    /// model when the service suggests none.
    private var showsModelField: Bool {
        isCustomModel
            || row.defaultModels.isEmpty
            || (!storedModel.isEmpty && !row.defaultModels.contains(storedModel))
    }

    private var storedModel: String {
        config.assistant.chat.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                if showsModelField { return Self.customChoice }
                return storedModel.isEmpty ? (row.defaultModels.first ?? Self.customChoice) : storedModel
            },
            set: { value in
                if value == Self.customChoice {
                    isCustomModel = true
                    return
                }
                isCustomModel = false
                guard config.assistant.chat.model != value else { return }
                config.assistant.chat.model = value
                onChange()
            }
        )
    }

    /// Writes a typed model id exactly as it is typed; the settings are trimmed
    /// when a request is built.
    private var typedModelBinding: Binding<String> {
        Binding(
            get: { config.assistant.chat.model },
            set: { value in
                guard config.assistant.chat.model != value else { return }
                config.assistant.chat.model = value
                onChange()
            }
        )
    }

    // MARK: - Answers

    private var answersSection: some View {
        SettingsSection("Answers") {
            SettingsRow("Deliver answers") {
                DotSelect(
                    label: "Deliver answers",
                    options: AnswerDelivery.allCases.map { mode in
                        DotSelectOption(value: mode, title: mode.title)
                    },
                    selection: deliveryBinding,
                    width: 220
                )
            }
            SettingsDivider()
            SettingsToggleRow(
                title: "Let the assistant use connected apps",
                subtitle: "Actions that change something always ask first.",
                isOn: actionsBinding
            )
        }
    }

    // MARK: - Rewrite

    /// The styles the transcript card offers once a dictation lands.
    ///
    /// A switch per built-in style, then the person's own: a row of two fields
    /// and the control that removes it, and the button that adds another. The
    /// chips on the card show exactly the styles that are on here, built-ins
    /// first.
    private var rewriteSection: some View {
        SettingsSection("Rewrite") {
            SettingsToggleRow(
                title: "Offer rewrites after dictation",
                subtitle: "Shown when an assistant service is connected.",
                isOn: rewriteEnabledBinding
            )
            ForEach(RewriteStyleID.allCases, id: \.self) { style in
                SettingsDivider()
                SettingsToggleRow(
                    title: style.title,
                    subtitle: style.subtitle,
                    isOn: styleBinding(style)
                )
                // A two-line description under a one-line title leaves the
                // row's ink high in its cell, so those rows carry three points
                // more air below it. A one-line description is already level.
                .padding(.bottom, style.wrapsSubtitle ? 3 : 0)
            }
            ForEach(config.assistant.rewrite.custom) { style in
                SettingsDivider()
                customStyleRow(style)
            }
            if config.assistant.rewrite.custom.count < CustomRewriteStyle.maximumCount {
                SettingsDivider()
                addStyleRow
            }
        }
    }

    /// One custom style: its name, what it should do, and the control that
    /// removes it.
    private func customStyleRow(_ style: CustomRewriteStyle) -> some View {
        HStack(spacing: 8) {
            TextField("Name", text: customBinding(style.id, \.title))
                .modifier(DotFieldStyle())
                .frame(width: 150)
                .accessibilityLabel("Style name")

            TextField("How to rewrite", text: customBinding(style.id, \.instruction))
                .modifier(DotFieldStyle())
                .frame(width: 250)
                .accessibilityLabel("Style instruction")

            Spacer(minLength: 8)

            Button(role: .destructive) {
                deleteStyle(style.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DotTheme.coral)
                    .frame(width: 26, height: 26, alignment: .trailing)
                    .padding(.trailing, -2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this style")
            .accessibilityLabel("Delete this style")
        }
        .padding(.vertical, 9)
        .frame(minHeight: 40)
    }

    /// The borderless button that adds a style, up to the limit the catalogue
    /// keeps.
    private var addStyleRow: some View {
        HStack(spacing: 0) {
            Button {
                addStyle()
            } label: {
                Text("+ Add style")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DotTheme.ink)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a custom style")

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 40)
    }

    // MARK: - Bindings

    /// The catalogue row of the chosen service.
    private var row: AssistantProviderRow {
        AssistantProviderCatalogue.row(for: config.assistant.chat.providerID)
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { config.assistant.chat.providerID },
            set: { id in
                guard config.assistant.chat.providerID != id else { return }
                config.assistant.chat.providerID = id
                // A model and an address belong to the service they were typed
                // for: a model id from one vendor means nothing to another, and
                // a typed address would silently replace the new row's.
                config.assistant.chat.model = ""
                if !Self.needsAddress(AssistantProviderCatalogue.row(for: id)) {
                    config.assistant.chat.baseURL = nil
                }
                isCustomModel = false
                note = nil
                keyField = ""
                onChange()
            }
        )
    }

    private var baseURLPlaceholder: String {
        row.defaultBaseURL?.absoluteString ?? "https://…"
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { config.assistant.chat.baseURL ?? "" },
            set: { value in
                guard config.assistant.chat.baseURL != value else { return }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                config.assistant.chat.baseURL = trimmed.isEmpty ? nil : value
                onChange()
            }
        )
    }

    private var deliveryBinding: Binding<AnswerDelivery> {
        Binding(
            get: { config.assistant.delivery },
            set: { value in
                guard config.assistant.delivery != value else { return }
                config.assistant.delivery = value
                onChange()
            }
        )
    }

    private var rewriteEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.assistant.rewrite.enabled },
            set: { value in
                guard config.assistant.rewrite.enabled != value else { return }
                config.assistant.rewrite.enabled = value
                onChange()
            }
        )
    }

    private func styleBinding(_ style: RewriteStyleID) -> Binding<Bool> {
        Binding(
            get: { config.assistant.rewrite.styles.contains(style) },
            set: { isOn in
                var kept = config.assistant.rewrite.styles
                if isOn {
                    if !kept.contains(style) { kept.append(style) }
                } else {
                    kept.removeAll { $0 == style }
                }
                let ordered = RewriteStyleID.allCases.filter { kept.contains($0) }
                guard ordered != config.assistant.rewrite.styles else { return }
                config.assistant.rewrite.styles = ordered
                onChange()
            }
        )
    }

    private func customBinding(
        _ id: String,
        _ keyPath: WritableKeyPath<CustomRewriteStyle, String>
    ) -> Binding<String> {
        Binding(
            get: {
                config.assistant.rewrite.custom.first { $0.id == id }?[keyPath: keyPath] ?? ""
            },
            set: { value in
                guard let index = config.assistant.rewrite.custom.firstIndex(where: { $0.id == id }),
                      config.assistant.rewrite.custom[index][keyPath: keyPath] != value
                else { return }
                config.assistant.rewrite.custom[index][keyPath: keyPath] = value
                onChange()
            }
        )
    }

    private func addStyle() {
        guard config.assistant.rewrite.custom.count < CustomRewriteStyle.maximumCount else { return }
        config.assistant.rewrite.custom.append(CustomRewriteStyle(title: "", instruction: ""))
        onChange()
    }

    private func deleteStyle(_ id: String) {
        guard config.assistant.rewrite.custom.contains(where: { $0.id == id }) else { return }
        config.assistant.rewrite.custom.removeAll { $0.id == id }
        onChange()
    }

    private var actionsBinding: Binding<Bool> {
        Binding(
            get: { config.assistant.actionsEnabled },
            set: { value in
                guard config.assistant.actionsEnabled != value else { return }
                config.assistant.actionsEnabled = value
                onChange()
            }
        )
    }

    // MARK: - Keys

    /// Whether the Keychain holds a key for a service: the items a render was
    /// told about, otherwise the ones the Keychain reports without decrypting.
    private func hasKey(_ id: String) -> Bool {
        (storedKeys ?? keyedProviders ?? []).contains(id)
    }

    private func readStoredKeys() {
        guard storedKeys == nil else { return }
        if let keyedProviders {
            storedKeys = keyedProviders
            return
        }
        storedKeys = Set(
            AssistantProviderCatalogue.rows.map(\.id).filter { AssistantCredentials.hasKey(for: $0) }
        )
    }

    private var trimmedKey: String {
        keyField.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConnect: Bool {
        !connecting && !trimmedKey.isEmpty
    }

    private func connect() {
        guard canConnect else { return }
        let service = row
        let secret = trimmedKey
        connecting = true
        note = nil
        focusedField = nil
        defer { connecting = false }
        if let message = onSetKey(secret, service.id) {
            note = KeyNote(detail: message, tone: .bad)
            focusedField = .apiKey
            return
        }
        storedKeys = (storedKeys ?? keyedProviders ?? []).union([service.id])
        keyField = ""
        note = KeyNote(detail: nil, tone: .good)
        onChange()
    }

    private func deleteKey() {
        let service = row
        if let message = onDeleteKey(service.id) {
            note = KeyNote(detail: message, tone: .bad)
            return
        }
        storedKeys = (storedKeys ?? keyedProviders ?? []).subtracting([service.id])
        keyField = ""
        note = KeyNote(detail: nil, tone: .neutral)
        onChange()
    }
}

/// The last thing the key row said.
struct KeyNote {
    let detail: String?
    let tone: Tone

    enum Tone {
        case good
        case bad
        case neutral

        var color: Color {
            switch self {
            case .good: DotTheme.mint
            case .bad: DotTheme.coral
            case .neutral: DotTheme.ink3
            }
        }
    }
}

// MARK: - Components

/// The key row the Provider page draws: the field, the button that stores it and
/// the control that removes it. It is one row so the two pages that need a key
/// cannot drift apart.
@MainActor
struct AssistantKeyRow: View {
    @Binding var field: String
    let hasStoredKey: Bool
    let isConnecting: Bool
    let onConnect: () -> Void
    let onDelete: () -> Void
    /// A line under the row, for a page with no status row of its own.
    var subtitle: String?
    var subtitleTone: Color = DotTheme.ink3

    @FocusState private var isFocused: Bool

    private var trimmed: String {
        field.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var placeholder: String {
        hasStoredKey ? "Replace the API key" : "API key"
    }

    var body: some View {
        SettingsRow("API key", subtitle: subtitle, subtitleTone: subtitleTone) {
            HStack(spacing: 8) {
                SecureField(placeholder, text: $field)
                    .modifier(DotFieldStyle(focused: isFocused))
                    .focused($isFocused)
                    .onSubmit(onConnect)
                    .frame(width: 240)
                    .accessibilityLabel("API key")
                    .accessibilityHint("The key for the chosen service. It is stored in the Keychain.")

                Button(isConnecting ? "Connecting…" : "Connect", action: onConnect)
                    .buttonStyle(DotPrimaryButtonStyle())
                    .disabled(isConnecting || trimmed.isEmpty)
                    .accessibilityHint("Stores the key in the macOS Keychain.")

                if hasStoredKey {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DotTheme.coral)
                            .frame(width: 26, height: 26, alignment: .trailing)
                            // The symbol's own side bearing would otherwise end
                            // the row two points inside the card's edge, out of
                            // line with every other trailing control.
                            .padding(.trailing, -2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete the stored key")
                    .accessibilityLabel("Delete the stored key from the Keychain")
                }
            }
        }
    }
}

/// A switch row: the name, the fact under it and the switch at the trailing
/// edge, drawn the way the Provider page draws one.
@MainActor
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(DotToggleStyle())
                .accessibilityLabel(title)
        }
    }
}
