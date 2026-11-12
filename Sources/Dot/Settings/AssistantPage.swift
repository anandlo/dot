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

/// The status an offscreen render draws on the Assistant page.
///
/// A render must not ask a service whether it answers: the four states are four
/// pictures, and none of them may depend on the network or on who is signed in.
struct AssistantConnectionPreviewKey: EnvironmentKey {
    static let defaultValue: AssistantConnectionState? = nil
}

extension EnvironmentValues {
    /// The connection status to draw instead of checking, if any.
    var assistantConnectionPreview: AssistantConnectionState? {
        get { self[AssistantConnectionPreviewKey.self] }
        set { self[AssistantConnectionPreviewKey.self] = newValue }
    }

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
    @Environment(\.assistantConnectionPreview) private var connectionPreview
    @Environment(\.settingsHeadless) private var headless

    @State private var storedKeys: Set<String>?
    @State private var keyField = ""
    @State private var connecting = false
    @State private var note: KeyNote?
    @State private var isCustomModel = false
    /// The service the person picked during this visit to the page.
    ///
    /// The pop-up says "None" while the assistant is not set up, but a service
    /// that was just picked and not yet given a key is not set up either, and
    /// the page still has to ask for that key. The pick is kept here so the two
    /// facts stay apart: a service can be chosen without the assistant being
    /// ready.
    @State private var chosenServiceID: String?
    @State private var connection: AssistantConnectionState = .notSetUp
    @State private var checkTask: Task<Void, Never>?
    @State private var models: [String] = []
    @State private var modelsTask: Task<Void, Never>?
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
            // Until the person sets a service up, the page is the one question
            // it can still answer: which service, and whether it works. A model
            // list, an answer destination and a set of rewrite styles are
            // settings for something that does not exist yet, and showing them
            // beside "Not set up" is how the page came to look configured.
            if config.assistant.isSetUp {
                modelSection
                answersSection
                rewriteSection
            }
        }
        .onAppear(perform: appeared)
        .onDisappear(perform: cancelled)
    }

    // MARK: - Service

    private var serviceSection: some View {
        SettingsSection("Service") {
            SettingsRow("Service") {
                DotSelect(
                    label: "Service",
                    options: serviceOptions,
                    selection: serviceBinding,
                    placeholder: "Choose a service",
                    width: 220
                )
            }
            if showsSharedKeyRow {
                SettingsDivider()
                sharedKeyRow
            }
            if isServiceChosen {
                if !Self.runsOnThisMac(row) {
                    SettingsDivider()
                    AssistantKeyRow(
                        field: $keyField,
                        hasStoredKey: hasKey(row.id),
                        isConnecting: connecting,
                        onConnect: connect,
                        onDelete: deleteKey,
                        subtitle: row.keyNote
                    )
                }
                if showsPlanRow {
                    SettingsDivider()
                    SettingsRow("Plan") {
                        DotSelect(
                            label: "Plan",
                            options: planOptions,
                            selection: planBinding,
                            placeholder: planOptions.first?.title ?? "",
                            width: 220
                        )
                    }
                }
            }
            SettingsDivider()
            SettingsRow(
                "Status",
                subtitle: statusDetail,
                subtitleTone: note?.tone.color ?? DotTheme.ink3
            ) {
                statusChip
            }
            if isServiceChosen, Self.needsAddress(row) {
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
            switch displayedConnection {
            case .checking:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            case .notSetUp, .connected, .notConnected:
                Circle()
                    .fill(statusDotColour)
                    .frame(width: 6, height: 6)
            }
            Text(displayedConnection.title)
                .font(.system(size: 11.5))
                .foregroundStyle(displayedConnection == .notSetUp ? DotTheme.ink3 : DotTheme.ink2)
        }
        .accessibilityElement(children: .combine)
    }

    /// The colour of the status dot.
    private var statusDotColour: Color {
        switch displayedConnection {
        case .connected: DotTheme.switchOn
        case .notConnected: DotTheme.amber
        case .notSetUp, .checking: DotTheme.ink3
        }
    }

    /// The line under the status row: why a check failed, or what the last key
    /// change did.
    private var statusDetail: String? {
        displayedConnection.detail ?? note?.detail
    }

    /// The state the page draws: a render's preview, or what the last check
    /// found.
    private var displayedConnection: AssistantConnectionState {
        connectionPreview ?? connection
    }

    /// Whether the assistant can be used right now.
    private var isUsable: Bool {
        AssistantAvailability.isUsable(config: config.assistant, hasKey: hasKey(row.id))
    }

    /// Whether a service has been chosen at all.
    private var isServiceChosen: Bool {
        chosenServiceID != nil || config.assistant.isSetUp
    }

    /// Whether the page offers the key the Provider page already stored.
    ///
    /// A chat key is the speech key's own Keychain item, so a person who set the
    /// transcriber up already has one. It is offered rather than used: pressing
    /// the button is what says the assistant is wanted, and a key that appears
    /// without a word is how the page came to look connected to someone who
    /// never chose a service.
    private var showsSharedKeyRow: Bool {
        !config.assistant.isSetUp && row.requiresKey && hasKey(row.id)
    }

    private var sharedKeyRow: some View {
        SettingsRow("Speech key", subtitle: "The Provider page stored a key for \(row.name).") {
            Button("Use the key from Speech", action: useSharedKey)
                .buttonStyle(DotSecondaryButtonStyle())
                .accessibilityHint("Sets the assistant up with the key stored on the Provider page.")
        }
    }

    /// The choices the Service pop-up offers: none, then every row.
    private var serviceOptions: [DotSelectOption<String>] {
        [DotSelectOption(value: nil, title: "None")]
            + AssistantProviderCatalogue.rows.map { DotSelectOption(value: $0.id, title: $0.name) }
    }

    /// The plans the chosen vendor sells, when it sells more than one.
    private var showsPlanRow: Bool {
        row.plans.count > 1
    }

    private var planOptions: [DotSelectOption<String>] {
        row.plans.map { DotSelectOption(value: $0.id, title: $0.title) }
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

    /// The ids the picker offers: what the service listed, or its suggestions.
    private var modelChoices: [String] {
        models.isEmpty ? row.defaultModels : models
    }

    /// The catalogue's suggestions for the chosen service, and the row that
    /// opens a field for anything else.
    private var modelOptions: [DotSelectOption<String>] {
        var options = modelChoices.map { DotSelectOption(value: $0, title: $0) }
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
            || modelChoices.isEmpty
            || (!storedModel.isEmpty && !modelChoices.contains(storedModel))
    }

    private var storedModel: String {
        config.assistant.chat.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                if showsModelField { return Self.customChoice }
                return storedModel.isEmpty ? (modelChoices.first ?? Self.customChoice) : storedModel
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
    /// first. The prompt style carries Dot's working rules, so its switch is
    /// followed by the control that keeps them and the field that edits them.
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
                if style == .prompt {
                    SettingsDivider()
                    SettingsToggleRow(
                        title: "Add working rules to agent prompts",
                        isOn: workingRulesEnabledBinding
                    )
                    if config.assistant.rewrite.workingRulesEnabled {
                        SettingsDivider()
                        WorkingRulesRow(text: workingRulesBinding, onReset: resetWorkingRules)
                    }
                }
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

    /// The chosen service, or none.
    ///
    /// The pop-up says "None" until the person has set the assistant up: the
    /// provider id a fresh install stores is what the build wrote, not a choice
    /// the person made, and showing it as one is how an install that never
    /// touched the assistant came to look configured.
    private var serviceBinding: Binding<String?> {
        Binding(
            get: {
                if let chosenServiceID { return chosenServiceID }
                return config.assistant.isSetUp ? config.assistant.chat.providerID : nil
            },
            set: { id in
                chosenServiceID = id
                note = nil
                keyField = ""
                models = []
                isCustomModel = false
                guard let id else {
                    config.assistant.isSetUp = false
                    connection = .notSetUp
                    onChange()
                    return
                }
                let service = AssistantProviderCatalogue.row(for: id)
                if config.assistant.chat.providerID != id {
                    config.assistant.chat.providerID = id
                    // A model and an address belong to the service they were
                    // typed for: a model id from one vendor means nothing to
                    // another, and a typed address would silently replace the
                    // new row's.
                    config.assistant.chat.model = ""
                    if !Self.needsAddress(service) {
                        config.assistant.chat.baseURL = nil
                    }
                }
                // A service that runs on this Mac asks for no key, so picking
                // it is the whole setup. Anything else waits for a key, and a
                // key the Provider page already stored is offered rather than
                // assumed.
                if !service.requiresKey {
                    config.assistant.isSetUp = true
                }
                onChange()
                apply(.availability(isUsable: isUsable))
                check(forced: true)
                loadModels()
            }
        )
    }

    /// The plan the chosen vendor's address belongs to.
    private var planBinding: Binding<String> {
        Binding(
            get: {
                AssistantProviderCatalogue.plan(for: config.assistant.chat, row: row)?.id
                    ?? row.plans.first?.id ?? ""
            },
            set: { id in
                guard let plan = row.plans.first(where: { $0.id == id }) else { return }
                let address = plan.baseURL?.absoluteString
                guard config.assistant.chat.baseURL != address else { return }
                config.assistant.chat.baseURL = address
                note = nil
                onChange()
                apply(.availability(isUsable: isUsable))
                check(forced: true)
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
                apply(.availability(isUsable: isUsable))
                check(forced: true)
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

    private var workingRulesEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.assistant.rewrite.workingRulesEnabled },
            set: { value in
                guard config.assistant.rewrite.workingRulesEnabled != value else { return }
                config.assistant.rewrite.workingRulesEnabled = value
                onChange()
            }
        )
    }

    /// The rules as they are typed, held to the length the configuration keeps.
    private var workingRulesBinding: Binding<String> {
        Binding(
            get: { config.assistant.rewrite.workingRules },
            set: { value in
                let capped = String(
                    value.prefix(RewriteConfiguration.maximumWorkingRulesLength)
                )
                guard config.assistant.rewrite.workingRules != capped else { return }
                config.assistant.rewrite.workingRules = capped
                onChange()
            }
        )
    }

    private func resetWorkingRules() {
        let rules = RewriteConfiguration.defaultWorkingRules
        guard config.assistant.rewrite.workingRules != rules else { return }
        config.assistant.rewrite.workingRules = rules
        onChange()
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

    /// The page is on screen: read the stored keys, check the service and read
    /// the model list, once.
    private func appeared() {
        readStoredKeys()
        guard connectionPreview == nil else { return }
        apply(.availability(isUsable: isUsable))
        check(forced: false)
        loadModels()
    }

    /// The page is going away: no check and no model list may outlive it.
    private func cancelled() {
        checkTask?.cancel()
        modelsTask?.cancel()
    }

    /// Reports a change to the status row.
    private func apply(_ event: AssistantConnectionEvent) {
        connection = event.applied(to: connection)
    }

    /// Asks the service whether it answers.
    ///
    /// The answer is reused for ten minutes, so leaving the page and coming back
    /// does not send a second request, and nothing is asked before the page is
    /// on screen: an install that never opens Settings never makes the call. A
    /// render and a headless run never make it either.
    ///
    /// - Parameter forced: whether a change the person just made is the reason,
    ///   in which case a cached answer is not reused.
    private func check(forced: Bool) {
        checkTask?.cancel()
        guard !headless, connectionPreview == nil, isUsable else { return }
        let settings = config.assistant.chat
        let service = AssistantConnectionCache.serviceKey(settings)
        let cache = AssistantConnectionCache.shared
        let serviceID = row.id
        let needsKey = row.requiresKey
        checkTask = Task { @MainActor in
            if !forced, let fresh = await cache.result(for: service, now: Date()) {
                connection = fresh.state
                return
            }
            apply(.checkStarted)
            let key = needsKey ? await AssistantCredentials.resolvedKey(for: serviceID) : nil
            guard !Task.isCancelled else { return }
            let result = await AssistantConnectionVerifier.verify(
                settings: settings,
                apiKey: key,
                session: AssistantConnectionVerifier.sharedSession
            )
            guard !Task.isCancelled else { return }
            await cache.store(result, for: service, at: Date())
            switch result {
            case .connected:
                apply(.checkSucceeded)
            case .notConnected(let reason):
                apply(.checkFailed(reason))
            }
        }
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
        // A key that belongs to the vendor's other plan moves the address to
        // that plan, and says so: a request sent to the wrong host of a vendor
        // that runs two of them is refused for a reason no one would guess.
        if let moved = AssistantProviderCatalogue.movedPlan(
            forStoredKey: secret,
            settings: config.assistant.chat,
            row: service
        ) {
            config.assistant.chat.baseURL = moved.baseURL?.absoluteString
            note = KeyNote(detail: "Using the \(moved.title) address.", tone: .neutral)
        } else {
            note = KeyNote(detail: nil, tone: .good)
        }
        // The person picked a service and gave it a key: that, and only that,
        // is what sets the assistant up.
        config.assistant.isSetUp = true
        onChange()
        apply(.availability(isUsable: isUsable))
        check(forced: true)
    }

    /// The person accepted the key the Provider page already stored.
    private func useSharedKey() {
        config.assistant.isSetUp = true
        note = KeyNote(detail: nil, tone: .good)
        onChange()
        apply(.availability(isUsable: isUsable))
        check(forced: true)
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
        apply(.availability(isUsable: isUsable))
    }

    /// Reads the model list from the service.
    ///
    /// The list is what the Model pop-up offers, so it is read once the page is
    /// on screen and again whenever the service changes: a service that adds a
    /// model after this build ships still appears in the pop-up. A refusal
    /// leaves the catalogue's suggestions in place, and the status row says why
    /// the service is not answering.
    private func loadModels() {
        modelsTask?.cancel()
        guard !headless, connectionPreview == nil, isUsable else { return }
        let settings = config.assistant.chat
        let service = row
        modelsTask = Task { @MainActor in
            let key = service.requiresKey
                ? await AssistantCredentials.resolvedKey(for: service.id)
                : nil
            let fetched = await AssistantModelCatalog.fetch(
                settings: settings,
                apiKey: key,
                session: AssistantConnectionVerifier.sharedSession
            )
            guard !Task.isCancelled, !fetched.isEmpty else { return }
            models = fetched
        }
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
        SettingsRow(
            "API key",
            subtitle: subtitle,
            subtitleTone: subtitleTone,
            // The field and its buttons take most of the row, which leaves the
            // sentence beside them too narrow to read: the note is drawn under
            // them at the row's full width.
            wideSubtitle: subtitle != nil
        ) {
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
                    // The label is two words and the row may carry a wrapped
                    // line beside it: a button that shrinks its own word is not
                    // a button.
                    .fixedSize()
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

/// The working rules the prompt style carries: the field that edits them and
/// the control that puts the shipped ones back.
///
/// The block is Dot's own text, appended after the model's output, so it is
/// edited as data rather than described as an instruction to the model.
@MainActor
struct WorkingRulesRow: View {
    @Binding var text: String
    let onReset: () -> Void

    @FocusState private var isFocused: Bool

    /// The line height of the field's 12.5 pt text.
    private static let lineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: 12.5)
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }()

    /// Five visible lines of rules, plus the field's own vertical padding.
    static var height: CGFloat { lineHeight * 5 + 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .modifier(DotFieldStyle(focused: isFocused))
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .frame(height: Self.height)
                .accessibilityLabel("Working rules")

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button("Reset", action: onReset)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DotTheme.ink)
                    .accessibilityLabel("Put the shipped working rules back")
            }
        }
        .padding(.vertical, 9)
    }
}
