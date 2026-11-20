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

/// The models an offscreen render lists, so the Model card's picker and its
/// reasoning row can be looked at without asking a service.
///
/// The list is the same shape live discovery produces, which is what lets a
/// render prove the reasoning row appears for a model that publishes levels and
/// stays away for a model that does not.
struct AssistantDiscoveredModelsKey: EnvironmentKey {
    static let defaultValue: [DiscoveredModel]? = nil
}

/// The style the Styles card opens on, so a render or a test can look at a
/// style other than the first one without clicking its pill.
struct AssistantStyleSelectionKey: EnvironmentKey {
    static let defaultValue: AssistantPage.StyleSelection? = nil
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

    /// The models to list instead of reading the service's catalogue, if any.
    var assistantDiscoveredModelsPreview: [DiscoveredModel]? {
        get { self[AssistantDiscoveredModelsKey.self] }
        set { self[AssistantDiscoveredModelsKey.self] = newValue }
    }

    /// The style the Styles card opens on, if a render named one.
    var assistantStyleSelectionPreview: AssistantPage.StyleSelection? {
        get { self[AssistantStyleSelectionKey.self] }
        set { self[AssistantStyleSelectionKey.self] = newValue }
    }
}

/// The AI rewrite page: whether the card offers rewrites, which service asks
/// for them, which model answers and which styles the card carries.
///
/// The engine underneath is still the assistant's — the same configuration
/// block, the same Keychain items and the same provider catalogue — but the page
/// presents one thing a person configures: rewriting their own text. It offers
/// no answer destination and no connected apps, because neither is part of this
/// product.
///
/// The page opens on its master switch. Nothing else is drawn until rewriting
/// is on, and the service, model and styles are drawn only once the service can
/// actually answer: settings for something that does not exist yet are how the
/// page came to look configured.
///
/// Keys are the only thing the page writes outside the configuration: they go
/// to the Keychain through the same callbacks the Speech to text page uses, so
/// the item a speech key already lives in is the item a rewrite request reads.
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
    @Environment(\.assistantDiscoveredModelsPreview) private var modelsPreview
    @Environment(\.assistantStyleSelectionPreview) private var stylePreview
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
    /// Coalesces a burst of address edits into one models request.
    @State private var addressChecks = AssistantCheckDebounce()
    /// The models the service listed for the current address and key.
    @State private var discoveredModels: [DiscoveredModel] = []
    @State private var catalogState: CatalogState = .idle
    @State private var modelsTask: Task<Void, Never>?
    /// The style whose controls the Styles card draws.
    @State private var selectedStyle: StyleSelection = .builtIn(.prompt)
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
    static let customChoice = "__custom__"

    // MARK: - The cards

    /// One card of the page, in the order the page draws them.
    ///
    /// The list is the product rule in one place: the master switch is always
    /// offered, a service is offered while rewriting is on, and a model and the
    /// styles are settings for a service that can be used. The assistant's
    /// answer destination and connected apps are not cards here, so neither can
    /// come back without this list changing.
    enum Card: String, CaseIterable, Hashable {
        case toggle = "AI rewrite"
        case service = "Service"
        case model = "Model"
        case styles = "Styles"

        /// The heading over the card.
        var title: String { rawValue }
    }

    /// The cards the page draws for a record, in order.
    ///
    /// Turning rewriting off leaves the switch alone on the page: the service,
    /// the model and the styles are kept in the configuration but are not
    /// settings of a capability that is off. A record whose service cannot
    /// answer is the switch and the service card, because that card is what
    /// makes it answer.
    ///
    /// - Parameters:
    ///   - config: the assistant's block of the configuration.
    ///   - hasKey: whether the Keychain holds a key for the chosen service.
    /// - Returns: the cards to draw, in order.
    static func cards(config: AssistantConfiguration, hasKey: Bool) -> [Card] {
        guard config.rewrite.enabled else { return [.toggle] }
        return AssistantAvailability.readiness(config: config, hasKey: hasKey).isReady
            ? [.toggle, .service, .model, .styles]
            : [.toggle, .service]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Self.cards(config: config.assistant, hasKey: hasKey(row.id)), id: \.self) { card in
                switch card {
                case .toggle:
                    toggleSection
                case .service:
                    serviceSection
                case .model:
                    modelSection
                case .styles:
                    stylesSection
                }
            }
        }
        .onAppear(perform: appeared)
        .onDisappear(perform: cancelled)
    }

    /// The master switch, on its own above the cards it governs.
    ///
    /// It is a bare card rather than a section: the page title already says "AI
    /// rewrite", and a heading that repeated it would put the same words twice
    /// in four lines. Turning it off keeps the service, its address, the model
    /// and every style in the file, so the switch stops the offer without
    /// erasing the setup.
    private var toggleSection: some View {
        DotCard {
            SettingsToggleRow(title: "Offer rewrites after dictation", isOn: rewriteEnabledBinding)
        }
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
            if isServiceChosen, showsAddressRow {
                SettingsDivider()
                SettingsRow("Base URL") {
                    TextField(baseURLPlaceholder, text: baseURLBinding)
                        .modifier(DotFieldStyle(focused: focusedField == .baseURL))
                        .focused($focusedField, equals: .baseURL)
                        .frame(width: 300)
                        .accessibilityLabel("Base URL")
                        .accessibilityHint(
                            "The address this service is reached at. It is kept in the configuration, not the Keychain."
                        )
                }
            }
            if showsTurnOnRow {
                SettingsDivider()
                SettingsRow(
                    "AI rewrite",
                    subtitle: Self.canTurnOn(config.assistant)
                        ? "The service needs no key. Turning it on is the whole setup."
                        : "Add the address of this service, then turn it on."
                ) {
                    Button("Turn on", action: turnOn)
                        .buttonStyle(DotPrimaryButtonStyle())
                        .disabled(!Self.canTurnOn(config.assistant))
                        .accessibilityHint("Turns AI rewrite on for the chosen service.")
                }
            }
            SettingsDivider()
            SettingsRow(
                "Status",
                subtitle: statusDetail,
                subtitleTone: note?.tone.color ?? DotTheme.ink2
            ) {
                statusChip
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
                .font(DotType.font(11.5, .regular))
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

    /// The line under the status row: why a check failed, what the last key
    /// change did, or what the chosen record still needs.
    ///
    /// The last of the three is ``AssistantAvailability``'s own sentence, so the
    /// page cannot tell a person the assistant is configured while the chips
    /// and the menu treat the same record as unfinished. It names the missing
    /// piece and never repeats the typed address or the key.
    private var statusDetail: String? {
        if let detail = displayedConnection.detail { return detail }
        if let detail = note?.detail { return detail }
        // The rule cannot know which service the page is presenting, so the one
        // sentence that differs between an untouched install and a chosen one
        // is said here: a chosen service is not asked for twice, and a switch
        // that is still waiting for an address or a key says what it waits for.
        if case .notSetUp = readiness, isServiceChosen {
            guard Self.canTurnOn(config.assistant) else {
                var turnedOn = config.assistant
                turnedOn.isSetUp = true
                return AssistantAvailability.readiness(config: turnedOn, hasKey: hasKey(row.id)).message
            }
            return "Turn AI rewrite on to use this service."
        }
        return readiness.message
    }

    /// Why the assistant can, or cannot, be used.
    private var readiness: AssistantAvailability.Readiness {
        AssistantAvailability.readiness(config: config.assistant, hasKey: hasKey(row.id))
    }

    /// The state the page draws: a render's preview, or what the last check
    /// found.
    private var displayedConnection: AssistantConnectionState {
        connectionPreview ?? connection
    }

    /// Whether the assistant can be used right now.
    private var isUsable: Bool {
        readiness.isReady
    }

    /// Whether the page is presenting a service at all.
    private var isServiceChosen: Bool {
        chosenServiceID != nil || Self.presentsService(config.assistant)
    }

    /// Whether a record presents a service, whether or not it is turned on.
    ///
    /// The stored flag is the answer once it exists: turning the assistant off
    /// keeps the service, its model and a typed address, and hides them behind
    /// "None" until the person picks one again. A file written before the flag
    /// existed says nothing, so it is read by what it stores — a service other
    /// than the build's default, or an address. That is how the reported
    /// install, which named a custom endpoint without ever finishing it, still
    /// finds the field that finishes it.
    static func presentsService(_ config: AssistantConfiguration) -> Bool {
        if config.isSetUp { return true }
        if let chosen = config.serviceChosen { return chosen }
        return namesService(config)
    }

    /// Whether a record names a service rather than the build's default.
    ///
    /// It is the fallback for a file written before ``serviceChosen`` existed;
    /// it never overrules a stored "None".
    static func namesService(_ config: AssistantConfiguration) -> Bool {
        if let typed = config.chat.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !typed.isEmpty
        {
            return true
        }
        return config.chat.resolvedProviderID != AssistantSettings.defaultProviderID
    }

    /// Whether the address row is drawn.
    ///
    /// It is the only control for the rows whose shipped address cannot be used
    /// as it stands, and for an address the person typed over a row that has a
    /// default: a proxy must be editable and clearable after it is stored.
    private var showsAddressRow: Bool {
        Self.needsAddress(row) || hasTypedAddress
    }

    /// Whether the record carries an address that is not one of the row's plans.
    private var hasTypedAddress: Bool {
        guard let typed = config.assistant.chat.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !typed.isEmpty
        else { return false }
        return !row.plans.contains { $0.baseURL?.absoluteString == typed }
    }

    /// Whether the page offers to turn on a service that needs no key.
    ///
    /// Picking such a service is the whole setup, so the button is the way back
    /// for a record that names one without being set up. It is never pressed on
    /// the person's behalf: a speech key stored on the Speech to text page is not a
    /// choice of assistant.
    private var showsTurnOnRow: Bool {
        Self.needsTurnOn(config: config.assistant, isServiceChosen: isServiceChosen)
    }

    /// Whether a record needs the explicit switch a keyless service uses.
    ///
    /// - Parameters:
    ///   - config: the assistant's block.
    ///   - isServiceChosen: whether the page is presenting a service at all.
    /// - Returns: whether the turn-on row is drawn.
    static func needsTurnOn(
        config: AssistantConfiguration,
        isServiceChosen: Bool
    ) -> Bool {
        guard isServiceChosen, !config.isSetUp else { return false }
        let row = AssistantProviderCatalogue.row(for: config.chat.resolvedProviderID)
        return !row.requiresKey
    }

    /// Whether the switch may be pressed yet.
    ///
    /// A custom endpoint is turned on only once its address is one a request
    /// can be built from: a button that records "on" for an address that cannot
    /// answer would put the page back where the report found it.
    static func canTurnOn(_ config: AssistantConfiguration) -> Bool {
        var turnedOn = config
        turnedOn.isSetUp = true
        return AssistantAvailability.readiness(config: turnedOn, hasKey: false).isReady
    }

    /// Turns the assistant on, keeping the chosen service.
    static func turnOn(_ config: inout AssistantConfiguration) {
        config.serviceChosen = true
        config.isSetUp = true
    }

    /// Applies a Service pop-up choice to a record.
    ///
    /// - "None" turns the assistant off and remembers that it was turned off;
    ///   the service, the model and a typed address stay in the file, so the
    ///   next pick starts where the last one stopped.
    /// - A service the build ships as a local server is turned on by picking it.
    /// - Anything else, including every custom endpoint, waits for its key or
    ///   for the explicit switch, and its address is kept while it waits.
    static func choose(_ id: String?, in config: inout AssistantConfiguration) {
        guard let id else {
            config.isSetUp = false
            config.serviceChosen = false
            return
        }
        let service = AssistantProviderCatalogue.row(for: id)
        config.serviceChosen = true
        if config.chat.resolvedProviderID != id {
            config.chat.providerID = id
            // A model and an address belong to the service they were typed for:
            // a model id from one vendor means nothing to another, and a typed
            // address would silently replace the new row's.
            config.chat.model = ""
            if !needsAddress(service) {
                config.chat.baseURL = nil
            }
        }
        // Only a service known to run on this Mac is switched on by its pick:
        // it asks for no key, so picking it is the whole setup. A custom
        // endpoint also asks for no key, but nothing about it is known yet.
        if turnsOnWhenPicked(service) {
            config.isSetUp = true
        }
    }

    /// Whether picking a row is the whole setup.
    ///
    /// - Parameter row: the catalogue row the pop-up offered.
    /// - Returns: `true` only for a shipped row that runs on this Mac.
    static func turnsOnWhenPicked(_ row: AssistantProviderRow) -> Bool {
        guard !row.requiresKey else { return false }
        guard AssistantProviderCatalogue.shippedRow(for: row.id) != nil else { return false }
        return runsOnThisMac(row)
    }

    /// Whether the page offers a key the Keychain already stores.
    ///
    /// A chat key is the speech key's own Keychain item, so a person who set the
    /// transcriber up already has one, and an older build may have stored one on
    /// this page without ever switching rewriting on. It is offered rather than
    /// used: pressing the button is what says rewriting is wanted, and a key that
    /// appears without a word is how the page came to look connected to someone
    /// who never chose a service.
    private var showsSharedKeyRow: Bool {
        !config.assistant.isSetUp && row.requiresKey && hasKey(row.id)
    }

    private var sharedKeyRow: some View {
        SettingsRow("Stored key", subtitle: "A key for \(row.name) is already in the Keychain.") {
            Button("Use the stored key", action: useSharedKey)
                .buttonStyle(DotSecondaryButtonStyle())
                .accessibilityHint(
                    "Turns AI rewrite on with the key already stored for this service."
                )
        }
    }

    /// The choices the Service pop-up offers: none, then every row.
    ///
    /// An id this build does not ship is kept in the list rather than being
    /// shown as no choice at all: it is the record's own service, and the
    /// person can still reach its key and address rows.
    private var serviceOptions: [DotSelectOption<String>] {
        var options = AssistantProviderCatalogue.rows.map { DotSelectOption(value: $0.id, title: $0.name) }
        let stored = config.assistant.chat.resolvedProviderID
        if Self.presentsService(config.assistant), !options.contains(where: { $0.value == stored }) {
            options.append(
                DotSelectOption(
                    value: stored,
                    title: AssistantProviderCatalogue.row(for: stored).name
                )
            )
        }
        return [DotSelectOption(value: nil, title: "None")] + options
    }

    /// The plans the chosen vendor sells, when it sells more than one.
    private var showsPlanRow: Bool {
        row.plans.count > 1
    }

    private var planOptions: [DotSelectOption<String>] {
        row.plans.map { DotSelectOption(value: $0.id, title: $0.title) }
    }

    // MARK: - Model

    /// The model the service answered with, or the field that names one.
    ///
    /// There is no shipped list: a service adds and retires models faster than
    /// Dot ships a build, so the picker is what the service listed, the id the
    /// file already names (so a stored model is never silently replaced), and
    /// the row that opens a field for anything else.
    private var modelSection: some View {
        SettingsSection("Model") {
            SettingsRow("Model", isNamedBySection: true) {
                DotSelect(
                    label: "Model",
                    options: modelOptions,
                    selection: modelBinding,
                    placeholder: modelPlaceholder,
                    width: 220,
                    fillsWidth: true
                )
            }
            if showsRetryRow {
                SettingsDivider()
                retryRow
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
            if !reasoningChoices.isEmpty {
                SettingsDivider()
                SettingsRow("Reasoning") {
                    DotSelect(
                        label: "Reasoning",
                        options: reasoningChoices,
                        selection: reasoningBinding,
                        placeholder: "Default",
                        width: 220
                    )
                }
            }
        }
    }

    /// The catalogue a render handed the page, or the one the service answered
    /// with.
    private var effectiveCatalog: [DiscoveredModel] {
        modelsPreview ?? discoveredModels
    }

    /// The ids the picker offers: what the service listed, then the stored id
    /// when the list no longer names it, then the field for anything else.
    ///
    /// There is no shipped list to fall back to: an empty catalogue offers the
    /// field and nothing else, which is how a service that retired a model
    /// stops offering it.
    ///
    /// - Parameters:
    ///   - catalog: the models the service published.
    ///   - storedModel: the id the configuration carries.
    /// - Returns: the choices, in the order the picker shows them.
    static func modelOptions(
        catalog: [DiscoveredModel],
        storedModel: String
    ) -> [DotSelectOption<String>] {
        var options = catalog.map { DotSelectOption(value: $0.id, title: $0.id) }
        if !storedModel.isEmpty, !options.contains(where: { $0.value == storedModel }) {
            options.insert(DotSelectOption(value: storedModel, title: storedModel), at: 0)
        }
        options.append(DotSelectOption(value: customChoice, title: "Custom model…"))
        return options
    }

    private var modelOptions: [DotSelectOption<String>] {
        Self.modelOptions(catalog: effectiveCatalog, storedModel: storedModel)
    }

    /// The words the picker shows when no row matches.
    private var modelPlaceholder: String {
        if catalogState == .loading, effectiveCatalog.isEmpty, storedModel.isEmpty {
            return "Loading models…"
        }
        if effectiveCatalog.isEmpty, storedModel.isEmpty {
            return "No models available"
        }
        return "Choose a model"
    }

    /// Whether the field under the picker is drawn.
    ///
    /// The field is the way to name a model the service did not list, so it
    /// opens for "Custom model…" and for a service that answered with nothing
    /// to choose. A stored id the list no longer names is inserted into the
    /// picker instead, so it stays visible without opening the field.
    private var showsModelField: Bool {
        if isCustomModel { return true }
        guard storedModel.isEmpty else { return false }
        return effectiveCatalog.isEmpty && catalogState != .loading
    }

    /// Whether the service was asked and did not answer its list.
    private var showsRetryRow: Bool {
        effectiveCatalog.isEmpty && catalogState == .failed
    }

    /// The one control that asks for the list again after a refusal.
    private var retryRow: some View {
        SettingsRow("Models", subtitle: "The service did not answer its model list.") {
            Button("Retry") { loadModels() }
                .buttonStyle(DotSecondaryButtonStyle())
                .accessibilityHint("Asks the service for its model list again.")
        }
    }

    private var storedModel: String {
        config.assistant.chat.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The model the picker offers, and the discovery that belongs to it.
    ///
    /// Choosing a model also stores what the service published about it, so a
    /// request can be routed and its reasoning levels offered without a second
    /// call. A reasoning level the new model does not publish is cleared here
    /// rather than left to be sent to an endpoint that never documented it.
    private var modelBinding: Binding<String> {
        Binding(
            get: {
                if showsModelField { return Self.customChoice }
                return storedModel.isEmpty ? (effectiveCatalog.first?.id ?? Self.customChoice) : storedModel
            },
            set: { value in
                if value == Self.customChoice {
                    isCustomModel = true
                    return
                }
                isCustomModel = false
                var changed = false
                if config.assistant.chat.model != value {
                    config.assistant.chat.model = value
                    changed = true
                }
                let matched = effectiveCatalog.first { $0.id == value }
                if config.assistant.chat.discoveredModel != matched {
                    config.assistant.chat.discoveredModel = matched
                    changed = true
                }
                if let variant = config.assistant.chat.reasoningVariant,
                   !Self.reasoningOptions(for: matched, style: effectiveStyle(for: matched))
                       .contains(where: { $0.value == variant })
                {
                    config.assistant.chat.reasoningVariant = nil
                    changed = true
                }
                if changed { onChange() }
            }
        )
    }

    /// Writes a typed model id exactly as it is typed; the settings are trimmed
    /// when a request is built.
    ///
    /// A typed id describes no discovered model, so the discovery and the
    /// reasoning level that belonged to the last one go with it.
    private var typedModelBinding: Binding<String> {
        Binding(
            get: { config.assistant.chat.model },
            set: { value in
                guard config.assistant.chat.model != value else { return }
                config.assistant.chat.model = value
                config.assistant.chat.discoveredModel = nil
                config.assistant.chat.reasoningVariant = nil
                onChange()
            }
        )
    }

    /// The model the Reasoning row is about: the one the service listed, or the
    /// discovery the file already carries for the stored id.
    private var activeModel: DiscoveredModel? {
        effectiveCatalog.first { $0.id == storedModel }
            ?? (config.assistant.chat.discoveredModel?.id == storedModel
                ? config.assistant.chat.discoveredModel
                : nil)
    }

    /// The reasoning choices the stored model publishes.
    private var reasoningChoices: [DotSelectOption<String>] {
        let model = activeModel
        return Self.reasoningOptions(for: model, style: effectiveStyle(for: model))
    }

    /// The wire shape a model is served as: its own route, then a typed
    /// override, then the row's.
    private func effectiveStyle(for model: DiscoveredModel?) -> AssistantAPIStyle {
        model?.route?.style ?? config.assistant.chat.apiStyle ?? row.style
    }

    /// The reasoning choices a model publishes, in the order the picker shows
    /// them.
    ///
    /// Nothing is guessed: a model that publishes no levels and no switch gets
    /// an empty list, which is what keeps the row off the page. The default row
    /// names the level the service uses so a person can see what "Default"
    /// means, and the switch's own two states are offered only when the service
    /// documents them.
    ///
    /// - Parameters:
    ///   - model: the discovered model, when one was discovered.
    ///   - style: the shape the model is served as.
    /// - Returns: the choices, or an empty list when there is nothing to choose.
    static func reasoningOptions(
        for model: DiscoveredModel?,
        style: AssistantAPIStyle
    ) -> [DotSelectOption<String>] {
        guard let support = model?.reasoning, support.supportsReasoning else { return [] }
        var options: [DotSelectOption<String>] = []
        if let defaultEffort = support.defaultEffort {
            options.append(
                DotSelectOption(value: "", title: "Default (\(reasoningLabel(defaultEffort)))")
            )
        } else {
            options.append(DotSelectOption(value: "", title: "Default"))
        }
        if support.toggle, !support.efforts.contains("off") {
            options.append(DotSelectOption(value: "off", title: "Off"))
        }
        if support.toggle, support.efforts.isEmpty,
           style == .openAICompatible || support.thinkingTypes.contains("adaptive")
        {
            options.append(DotSelectOption(value: "on", title: "On"))
        }
        for effort in support.efforts {
            options.append(DotSelectOption(value: effort, title: reasoningLabel(effort)))
        }
        return options
    }

    /// The words a level is shown as.
    ///
    /// - Parameter effort: the service's own name for the level.
    /// - Returns: the label, with the two compound levels spelled out.
    static func reasoningLabel(_ effort: String) -> String {
        switch effort.lowercased() {
        case "none": "None"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra high"
        case "max": "Max"
        default: effort.capitalized
        }
    }

    private var reasoningBinding: Binding<String?> {
        Binding(
            get: { config.assistant.chat.reasoningVariant ?? "" },
            set: { value in
                let choice = (value?.isEmpty ?? true) ? nil : value
                guard config.assistant.chat.reasoningVariant != choice else { return }
                config.assistant.chat.reasoningVariant = choice
                onChange()
            }
        )
    }

    // MARK: - Styles

    /// The styles the card offers, as one selector and the controls of the
    /// chosen style.
    ///
    /// The pills are the whole list at a glance: a green dot says the style is
    /// on, a grey one says it is off, and a custom style with no text says it
    /// cannot run. The controls under them belong to exactly one style, so the
    /// page has one prompt editor rather than a column of fields.
    private var stylesSection: some View {
        SettingsSection("Styles") {
            FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Self.stylePills(config.assistant.rewrite)) { pill in
                    stylePill(pill)
                }
                if config.assistant.rewrite.custom.count < CustomRewriteStyle.maximumCount {
                    addStylePill
                }
            }
            // The layout reports the width it was offered, and the frame keeps
            // the pills at the card's leading edge: a row that fits is not a
            // shorter row floating in the middle of the card.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            SettingsDivider()
            styleControls
            if !config.assistant.rewrite.deletedBuiltIns.isEmpty {
                SettingsDivider()
                restoreBuiltInsRow
            }
        }
    }

    /// The way back for a style the person removed.
    ///
    /// It is drawn only while something is missing, so the card says nothing
    /// about restoring a page that has every style it ships.
    private var restoreBuiltInsRow: some View {
        SettingsRow("Default styles") {
            Button("Restore default styles", action: restoreBuiltIns)
                .buttonStyle(DotSecondaryButtonStyle())
                .accessibilityHint("Puts the removed styles back on the page.")
        }
    }

    /// One choice the Styles selector draws.
    ///
    /// The pill is data before it is a drawing: the titles, the order and the
    /// dots are one function, so the row cannot show a style the configuration
    /// does not carry.
    struct StylePill: Identifiable, Equatable {
        let selection: StyleSelection
        let title: String
        /// Which dot the pill draws: on for an offered built-in, usable for a
        /// custom style.
        let isOn: Bool

        var id: StyleSelection { selection }
    }

    /// The style a pill selects: a built-in, or one the person wrote.
    enum StyleSelection: Hashable {
        case builtIn(RewriteStyleID)
        case custom(String)
    }

    /// The pills the selector draws, in order: the shipped styles the person
    /// kept, then the custom ones.
    ///
    /// A removed style is not a pill, which is what makes deleting one visible
    /// on the row it was deleted from.
    ///
    /// - Parameter rewrite: the rewrite block of the configuration.
    /// - Returns: one pill per style the person can reach.
    static func stylePills(_ rewrite: RewriteConfiguration) -> [StylePill] {
        let builtIn = rewrite.visibleBuiltIns.map { id in
            StylePill(
                selection: .builtIn(id),
                title: id.title,
                isOn: rewrite.styles.contains(id)
            )
        }
        let custom = rewrite.custom.map { style in
            let trimmed = style.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return StylePill(
                selection: .custom(style.id),
                title: trimmed.isEmpty ? "Untitled" : style.title,
                isOn: style.isUsable
            )
        }
        return builtIn + custom
    }

    /// What the Styles card says when the person removed every style.
    static let emptyStylesMessage = "No styles. Use + Add style to create one."

    /// The selection the card draws, with a fallback for a style that is not in
    /// the build or was removed while it was open.
    ///
    /// A removed style cannot stay selected: the card would draw the controls of
    /// a style the row no longer offers. The first style still on the page takes
    /// its place, and a page whose styles were all removed has no selection at
    /// all.
    static func resolvedSelection(
        _ selection: StyleSelection,
        rewrite: RewriteConfiguration
    ) -> StyleSelection? {
        switch selection {
        case .builtIn(let id):
            if rewrite.visibleBuiltIns.contains(id) { return selection }
        case .custom(let id):
            if rewrite.custom.contains(where: { $0.id == id }) { return selection }
        }
        if let first = rewrite.visibleBuiltIns.first { return .builtIn(first) }
        if let first = rewrite.custom.first { return .custom(first.id) }
        return nil
    }

    private var activeSelection: StyleSelection? {
        Self.resolvedSelection(
            stylePreview ?? selectedStyle,
            rewrite: config.assistant.rewrite
        )
    }

    private func stylePill(_ pill: StylePill) -> some View {
        let isSelected = activeSelection == pill.selection
        return Button {
            selectedStyle = pill.selection
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(pill.isOn ? DotTheme.switchOn : DotTheme.ink3.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(pill.title)
                    .font(DotType.font(12, .medium))
                    .foregroundStyle(DotTheme.ink)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule(style: .circular)
                    .fill(isSelected ? DotTheme.cardSelectedFill : DotTheme.secondaryFill)
                    .overlay(
                        Capsule(style: .circular)
                            .strokeBorder(
                                isSelected ? DotTheme.cardBorderSelected : DotTheme.secondaryBorder,
                                lineWidth: 1
                            )
                    )
            )
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(DotPressStyle())
        .accessibilityLabel(pill.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The borderless pill that adds a style, up to the count the catalogue
    /// keeps.
    private var addStylePill: some View {
        Button {
            addStyle()
        } label: {
            Text("+ Add style")
                .font(DotType.font(12, .medium))
                .foregroundStyle(DotTheme.ink)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    Capsule(style: .circular)
                        .fill(DotTheme.secondaryFill)
                        .overlay(
                            Capsule(style: .circular)
                                .strokeBorder(DotTheme.secondaryBorder, lineWidth: 1)
                        )
                )
                .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(DotPressStyle())
        .accessibilityLabel("Add a custom style")
    }

    @ViewBuilder
    private var styleControls: some View {
        switch activeSelection {
        case .none:
            HStack(spacing: 0) {
                Text(Self.emptyStylesMessage)
                    .font(DotTheme.rowTitleFont)
                    .foregroundStyle(DotTheme.ink2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
        case .some(.builtIn(let id)):
            HStack(spacing: 8) {
                SettingsToggleRow(title: id.title, subtitle: id.subtitle, isOn: styleBinding(id))
                deleteBuiltInButton(id)
            }
            SettingsDivider()
            promptEditor(for: id)
            if id == .prompt {
                SettingsDivider()
                standingRulesControls
            }
        case .some(.custom(let id)):
            if config.assistant.rewrite.custom.contains(where: { $0.id == id }) {
                SettingsRow("Name") {
                    HStack(spacing: 8) {
                        TextField("Style name", text: customTitleBinding(id))
                            .modifier(DotFieldStyle())
                            .frame(width: 220)
                            .accessibilityLabel("Style name")
                        deleteStyleButton(id)
                    }
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(DotTheme.rowTitleFont)
                        .foregroundStyle(DotTheme.ink)
                    DotTextEditor(
                        text: customInstructionBinding(id),
                        height: 84,
                        accessibilityLabel: "Style instruction"
                    )
                }
                .padding(.vertical, 10)
            }
        }
    }

    /// The height of a built-in style's prompt field.
    ///
    /// Twelve whole lines of the field's own type plus the room the clip view
    /// and the text container keep clear of the two borders, so the field ends
    /// between two lines: the twelfth line sits inside the clip view and the
    /// thirteenth starts where the clip begins, which is why a scrolled prompt
    /// is cut by the clip rather than sliced in half by the bottom border.
    ///
    /// Resolved on every read rather than stored: it is measured from the
    /// app's typeface, and a stored height would keep whatever face was
    /// registered when something first asked for it.
    static var promptEditorHeight: CGFloat {
        promptEditorHeight(lines: 12)
    }

    /// The height of the standing rules field, which is six whole lines.
    static var standingRulesEditorHeight: CGFloat {
        promptEditorHeight(lines: 6)
    }

    /// The height a field of `lines` whole lines of the editor's type needs.
    ///
    /// - Parameter lines: how many lines the field shows before it scrolls.
    /// - Returns: the height, in points.
    static func promptEditorHeight(lines: Int) -> CGFloat {
        let font = DotType.nsFont(12.5, .regular)
        // The height one line is drawn at. The layout manager rounds the ascent
        // and the descent to whole points and adds the leading unrounded, so
        // the em sum the font reports is not the line the text view lays out: a
        // field sized from that shows part of the next line.
        let lineHeight = font.ascender.rounded() - font.descender.rounded() + font.leading
        // Rounded up to a whole point: the face draws a 12.5 point line at
        // 17.313, so twelve lines come to 207.75 and the clip view AppKit builds
        // from a fraction rounds down and cuts the twelfth line by a quarter of
        // a point. A whole point of height puts the clip on 208, which holds all
        // twelve and no more than the quarter point of blank line box above the
        // thirteenth.
        return DotTextEditor.verticalClipInset * 2
            + DotTextEditor.textInset.height
            + (lineHeight * CGFloat(lines)).rounded(.up)
    }

    /// The prompt of a built-in style, with the control that puts the shipped
    /// one back.
    ///
    /// The control is drawn only while the style carries an edit: the shipped
    /// prompt has nothing to reset, and a disabled label beside a field that
    /// already holds the template reads as a second, unavailable control.
    private func promptEditor(for id: RewriteStyleID) -> some View {
        let isCustomized = config.assistant.rewrite.builtInInstructions[id.rawValue] != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Prompt")
                    .font(DotTheme.rowTitleFont)
                    .foregroundStyle(DotTheme.ink)
                Spacer(minLength: 8)
                if isCustomized {
                    Button("Reset") { resetBuiltInInstruction(for: id) }
                        .buttonStyle(DotPressStyle())
                        .font(DotType.font(12, .medium))
                        .foregroundStyle(DotTheme.ink)
                        .accessibilityLabel("Reset \(id.title) prompt")
                }
            }
            DotTextEditor(
                text: builtInInstructionBinding(for: id),
                height: Self.promptEditorHeight,
                accessibilityLabel: "\(id.title) prompt"
            )
        }
        .padding(.vertical, 10)
    }

    private func deleteStyleButton(_ id: String) -> some View {
        deleteButton(help: "Delete this style") {
            deleteStyle(id)
        }
    }

    /// The title of the standing rules switch.
    static let standingRulesTitle = "Standing rules"

    /// What the switch explains when the pointer rests on its label.
    static let standingRulesHelp =
        "Dot adds this text word for word under every Agent prompt. The model never sees or writes it."

    /// The block Dot puts under every Agent prompt, and the switch that turns
    /// it on.
    ///
    /// The field is drawn only while the switch is on: a block that is off is
    /// one line in the card, and a person who turned it on has a text to write.
    /// Nothing explains the block under the row, because the help on the label
    /// already says the one fact the row cannot show: the model never reads it.
    private var standingRulesControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.standingRulesTitle)
                    .font(DotTheme.rowTitleFont)
                    .foregroundStyle(DotTheme.ink)
                    .help(Self.standingRulesHelp)
                Spacer(minLength: 8)
                Toggle("", isOn: standingRulesEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(DotToggleStyle())
                    .accessibilityLabel(Self.standingRulesTitle)
            }
            if config.assistant.rewrite.standingRulesEnabled {
                DotTextEditor(
                    text: standingRulesBinding,
                    height: Self.standingRulesEditorHeight,
                    accessibilityLabel: Self.standingRulesTitle
                )
            }
        }
        .padding(.vertical, 10)
    }

    /// The control that removes a shipped style from the page.
    ///
    /// A built-in style is a starting point, not a fixture: the control matches
    /// the one beside a custom style, so the page has one way to remove a style
    /// rather than two.
    private func deleteBuiltInButton(_ id: RewriteStyleID) -> some View {
        deleteButton(help: "Delete \(id.title)") {
            deleteBuiltIn(id)
        }
    }

    private func deleteButton(help: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
                .font(DotType.font(12, .medium))
                .foregroundStyle(DotTheme.coral)
                .frame(width: 26, height: 26, alignment: .trailing)
                .padding(.trailing, -2)
                .contentShape(Rectangle())
        }
        .buttonStyle(DotPressStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Bindings

    /// The catalogue row of the chosen service.
    ///
    /// The id is read the way the provider factory reads it, so a hand-edited
    /// blank falls back to the build's default rather than to a custom row.
    private var row: AssistantProviderRow {
        AssistantProviderCatalogue.row(for: config.assistant.chat.resolvedProviderID)
    }

    /// The chosen service, or none.
    ///
    /// The pop-up says "None" for a build-written default and for a record the
    /// person turned off. A service the person chose stays visible, whether it
    /// is on or merely waiting for a key or an address, so the fields that
    /// finish it can be reached.
    private var serviceBinding: Binding<String?> {
        Binding(
            get: {
                if let chosenServiceID { return chosenServiceID }
                guard Self.presentsService(config.assistant) else { return nil }
                return config.assistant.chat.resolvedProviderID
            },
            set: { id in
                chosenServiceID = id
                note = nil
                keyField = ""
                isCustomModel = false
                addressChecks.cancel()
                chooseService(id)
                onChange()
                guard id != nil else {
                    connection = .notSetUp
                    resetCatalog()
                    return
                }
                apply(.availability(isUsable: isUsable))
                check(forced: true)
                resetCatalog()
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
                // A level one plan's models publish can mean nothing to
                // another, and a route names an address the other plan does not
                // serve.
                config.assistant.chat.reasoningVariant = nil
                config.assistant.chat.discoveredModel = nil
                addressChecks.cancel()
                note = nil
                onChange()
                apply(.availability(isUsable: isUsable))
                check(forced: true)
                resetCatalog()
                loadModels()
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
                resetCatalog()
                // A request per keystroke would ask the service about every
                // prefix of the address. The check waits for the typing to stop.
                addressChecks.schedule {
                    check(forced: true)
                    loadModels()
                }
            }
        )
    }

    private var rewriteEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.assistant.rewrite.enabled },
            set: { value in
                guard config.assistant.rewrite.enabled != value else { return }
                Self.setRewriting(value, in: &config.assistant)
                resetCatalog()
                onChange()
                guard value else { return }
                loadModels()
            }
        )
    }

    /// Applies the master switch, and nothing else.
    ///
    /// The switch stops the card offering rewrites. It is not a way to erase
    /// the setup: the service, its key, the model, the typed address and every
    /// style stay exactly as they were, so turning it back on returns the page
    /// to the state it left.
    ///
    /// - Parameters:
    ///   - enabled: whether the card offers rewrites.
    ///   - config: the assistant's block.
    static func setRewriting(_ enabled: Bool, in config: inout AssistantConfiguration) {
        config.rewrite.enabled = enabled
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
                // The shipped styles keep the order the build lists them in;
                // a retired id a file still carries keeps its place after them
                // rather than being dropped by a toggle of another style.
                let shipped = RewriteStyleID.shippedCases
                let order = shipped + RewriteStyleID.allCases.filter { !shipped.contains($0) }
                let ordered = order.filter { kept.contains($0) }
                guard ordered != config.assistant.rewrite.styles else { return }
                config.assistant.rewrite.styles = ordered
                onChange()
            }
        )
    }

    /// The instruction the built-in style is run with, as the field edits it.
    ///
    /// The getter reads the stored override first, so a box that was cleared
    /// while it is being edited stays empty and an untouched style shows the
    /// shipped template. An edit that puts the template back is not stored:
    /// the map exists for edits, and a template written into it would claim an
    /// edit nobody made.
    private func builtInInstructionBinding(for id: RewriteStyleID) -> Binding<String> {
        Binding(
            get: { config.assistant.rewrite.builtInInstructions[id.rawValue] ?? id.template },
            set: { value in
                if Self.shouldStoreInstruction(value, for: id) {
                    guard config.assistant.rewrite.builtInInstructions[id.rawValue] != value else {
                        return
                    }
                    config.assistant.rewrite.setInstruction(value, for: id)
                } else {
                    guard config.assistant.rewrite.builtInInstructions[id.rawValue] != nil else {
                        return
                    }
                    Self.resetInstruction(for: id, in: &config.assistant.rewrite)
                }
                onChange()
            }
        )
    }

    /// Whether an instruction the field holds is an edit worth keeping.
    ///
    /// The map exists for the person's words. A field that still holds the
    /// shipped template is not an edit, and writing it would leave a file that
    /// claims one.
    ///
    /// - Parameters:
    ///   - instruction: what the field holds.
    ///   - id: the style it belongs to.
    /// - Returns: whether the value differs from the shipped template.
    static func shouldStoreInstruction(_ instruction: String, for id: RewriteStyleID) -> Bool {
        instruction != id.template
    }

    /// Removes the person's instruction for a style, restoring the shipped one.
    ///
    /// - Parameters:
    ///   - id: the style to restore.
    ///   - rewrite: the rewrite block.
    static func resetInstruction(
        for id: RewriteStyleID,
        in rewrite: inout RewriteConfiguration
    ) {
        rewrite.setInstruction(nil, for: id)
    }

    private func resetBuiltInInstruction(for id: RewriteStyleID) {
        guard config.assistant.rewrite.builtInInstructions[id.rawValue] != nil else { return }
        Self.resetInstruction(for: id, in: &config.assistant.rewrite)
        onChange()
    }

    /// Whether Dot puts the standing rules under an Agent prompt.
    ///
    /// The switch reads and writes the stored field rather than a preview, so
    /// the field beside it is drawn from the same answer the next rewrite
    /// reads.
    private var standingRulesEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.assistant.rewrite.standingRulesEnabled },
            set: { isOn in
                guard config.assistant.rewrite.standingRulesEnabled != isOn else { return }
                config.assistant.rewrite.standingRulesEnabled = isOn
                onChange()
            }
        )
    }

    /// The standing rules, held to the length the block keeps.
    private var standingRulesBinding: Binding<String> {
        Binding(
            get: { config.assistant.rewrite.standingRules },
            set: { value in
                let capped = String(value.prefix(RewriteConfiguration.maximumStandingRulesLength))
                guard config.assistant.rewrite.standingRules != capped else { return }
                config.assistant.rewrite.setStandingRules(capped)
                onChange()
            }
        )
    }

    /// A custom style's name, held to the length the catalogue keeps.
    private func customTitleBinding(_ id: String) -> Binding<String> {
        Binding(
            get: {
                config.assistant.rewrite.custom.first { $0.id == id }?.title ?? ""
            },
            set: { value in
                let capped = String(value.prefix(CustomRewriteStyle.maximumTitleLength))
                guard let index = config.assistant.rewrite.custom.firstIndex(where: { $0.id == id }),
                      config.assistant.rewrite.custom[index].title != capped
                else { return }
                config.assistant.rewrite.custom[index].title = capped
                onChange()
            }
        )
    }

    /// A custom style's instruction, without the fixed sentence.
    private func customInstructionBinding(_ id: String) -> Binding<String> {
        Binding(
            get: {
                config.assistant.rewrite.custom.first { $0.id == id }?.instruction ?? ""
            },
            set: { value in
                let capped = String(value.prefix(CustomRewriteStyle.maximumInstructionLength))
                guard let index = config.assistant.rewrite.custom.firstIndex(where: { $0.id == id }),
                      config.assistant.rewrite.custom[index].instruction != capped
                else { return }
                config.assistant.rewrite.custom[index].instruction = capped
                onChange()
            }
        )
    }

    /// Applies the pop-up's choice and drops what only the old service
    /// published.
    ///
    /// `choose` owns the id, the model and the typed address.
    /// ``AssistantSettings/selectProvider(_:)`` does the same for the two
    /// values that are a service's own — a reasoning level and a discovery —
    /// and it is called after the id is stored because it answers for a change
    /// of id.
    private func chooseService(_ id: String?) {
        let previous = config.assistant.chat.resolvedProviderID
        Self.choose(id, in: &config.assistant)
        if let id, id != previous {
            config.assistant.chat.selectProvider(id)
        }
        config.assistant.chat.reasoningVariant = nil
        config.assistant.chat.discoveredModel = nil
    }

    private func addStyle() {
        guard config.assistant.rewrite.custom.count < CustomRewriteStyle.maximumCount else { return }
        let style = CustomRewriteStyle(title: "", instruction: "")
        config.assistant.rewrite.custom.append(style)
        selectedStyle = .custom(style.id)
        onChange()
    }

    private func deleteStyle(_ id: String) {
        guard config.assistant.rewrite.custom.contains(where: { $0.id == id }) else { return }
        config.assistant.rewrite.custom.removeAll { $0.id == id }
        if selectedStyle == .custom(id) {
            selectedStyle = .builtIn(.prompt)
        }
        onChange()
    }

    /// Removes a shipped style, clearing the edit it may have carried.
    private func deleteBuiltIn(_ id: RewriteStyleID) {
        guard config.assistant.rewrite.visibleBuiltIns.contains(id) else { return }
        config.assistant.rewrite.deleteBuiltIn(id)
        if selectedStyle == .builtIn(id) {
            selectedStyle = .builtIn(.prompt)
        }
        onChange()
    }

    /// Puts every removed shipped style back, shipped templates included.
    private func restoreBuiltIns() {
        guard !config.assistant.rewrite.deletedBuiltIns.isEmpty else { return }
        config.assistant.rewrite.restoreBuiltIns()
        onChange()
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
        addressChecks.cancel()
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
        addressChecks.cancel()
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
        // is what turns rewriting on.
        config.assistant.serviceChosen = true
        config.assistant.isSetUp = true
        onChange()
        apply(.availability(isUsable: isUsable))
        check(forced: true)
        resetCatalog()
        loadModels()
    }

    /// The person accepted a key the Keychain already stores for this service.
    private func useSharedKey() {
        config.assistant.serviceChosen = true
        config.assistant.isSetUp = true
        note = KeyNote(detail: nil, tone: .good)
        onChange()
        apply(.availability(isUsable: isUsable))
        check(forced: true)
        resetCatalog()
        loadModels()
    }

    /// The person turned AI rewrite on for a service that asks for no key.
    ///
    /// It is the whole setup for a local server or a custom endpoint, and the
    /// only way back for a record that names one without being set up. A stored
    /// speech key never presses it.
    private func turnOn() {
        guard !config.assistant.isSetUp, Self.canTurnOn(config.assistant) else { return }
        Self.turnOn(&config.assistant)
        note = KeyNote(detail: nil, tone: .good)
        onChange()
        apply(.availability(isUsable: isUsable))
        check(forced: true)
        resetCatalog()
        loadModels()
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
        resetCatalog()
        loadModels()
    }

    /// The states a model list can be in.
    enum CatalogState: Equatable {
        /// Nothing was asked yet, or the last read was invalidated.
        case idle
        /// The service is being asked now.
        case loading
        /// The service answered; the list may still be empty.
        case loaded
        /// The service was asked and refused.
        case failed
    }

    /// Drops a list the current service, address or key no longer owns.
    private func resetCatalog() {
        discoveredModels = []
        catalogState = .idle
    }

    /// Reads the model list from the service.
    ///
    /// The list is what the Model picker offers, so it is read once the page is
    /// on screen and again whenever the service, its address, its key or the
    /// master switch changes: a service that adds a model after this build ships
    /// still appears in the picker. A refusal empties the list, says so, and
    /// leaves the row that asks again; a render and a headless run never send
    /// the request.
    private func loadModels() {
        modelsTask?.cancel()
        guard !headless,
              connectionPreview == nil,
              modelsPreview == nil,
              isUsable,
              config.assistant.rewrite.enabled
        else { return }
        catalogState = .loading
        let settings = config.assistant.chat
        let service = row
        modelsTask = Task { @MainActor in
            let key = service.requiresKey
                ? await AssistantCredentials.resolvedKey(for: service.id)
                : nil
            let result = await AssistantModelCatalog.fetchCatalog(
                settings: settings,
                apiKey: key,
                session: AssistantConnectionVerifier.sharedSession
            )
            guard !Task.isCancelled else { return }
            guard result.succeeded else {
                discoveredModels = []
                catalogState = .failed
                return
            }
            discoveredModels = result.models
            catalogState = .loaded
            syncDiscovery(with: result.models, complete: result.complete)
        }
    }

    /// What a model list says the stored record should hold.
    ///
    /// The values are the change, not the record: the page writes them only
    /// when there is something to write, so a list that agrees with the file
    /// does not touch it.
    struct DiscoveryUpdate: Equatable {
        var model: String
        var discoveredModel: DiscoveredModel?
        var reasoningVariant: String?
    }

    /// The change a service's list makes to the stored model, or `nil` when it
    /// makes none.
    ///
    /// A service that lists models and has none stored gets its first one, so
    /// the card is usable after the key without a second edit. A stored model
    /// the list names gets its discovery stored beside it, and a reasoning
    /// level the model no longer publishes is cleared rather than sent to an
    /// endpoint that never documented it.
    ///
    /// A model a *complete* list does not name was retired. The metadata that
    /// described it — its route, its temperature and its reasoning levels — no
    /// longer describes anything, so it is dropped; the id stays, because the
    /// person's model is never silently replaced. A partial list proves
    /// nothing about a retirement, so it changes no stored metadata at all.
    ///
    /// - Parameters:
    ///   - storedModel: the model id in the configuration.
    ///   - storedDiscovered: the discovery stored beside it, if any.
    ///   - storedVariant: the reasoning choice stored for it, if any.
    ///   - models: the models the service answered with.
    ///   - complete: whether every page of the list was read.
    ///   - style: the shape the service is asked for on when a model names none.
    /// - Returns: the values to write, or `nil` when nothing changes.
    static func discoveryUpdate(
        storedModel: String,
        storedDiscovered: DiscoveredModel?,
        storedVariant: String?,
        models: [DiscoveredModel],
        complete: Bool,
        style: AssistantAPIStyle
    ) -> DiscoveryUpdate? {
        let stored = storedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.isEmpty {
            guard complete, let first = models.first else { return nil }
            return DiscoveryUpdate(model: first.id, discoveredModel: first, reasoningVariant: nil)
        }
        let wanted = storedVariant?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantedVariant = (wanted?.isEmpty ?? true) ? nil : wanted
        if let matched = models.first(where: { $0.id == stored }) {
            let supported = wantedVariant.map { variant in
                reasoningOptions(for: matched, style: matched.route?.style ?? style)
                    .contains { $0.value == variant }
            } ?? true
            let variant = supported ? wantedVariant : nil
            guard matched != storedDiscovered || variant != storedVariant else { return nil }
            return DiscoveryUpdate(model: stored, discoveredModel: matched, reasoningVariant: variant)
        }
        guard complete, storedDiscovered != nil || storedVariant != nil else { return nil }
        return DiscoveryUpdate(model: stored, discoveredModel: nil, reasoningVariant: nil)
    }

    /// Makes the stored model agree with what the service published about it.
    ///
    /// - Parameters:
    ///   - models: the models the service answered with.
    ///   - complete: whether every page of the list was read.
    private func syncDiscovery(with models: [DiscoveredModel], complete: Bool) {
        guard let update = Self.discoveryUpdate(
            storedModel: config.assistant.chat.model,
            storedDiscovered: config.assistant.chat.discoveredModel,
            storedVariant: config.assistant.chat.reasoningVariant,
            models: models,
            complete: complete,
            style: row.style
        ) else { return }
        config.assistant.chat.model = update.model
        config.assistant.chat.discoveredModel = update.discoveredModel
        config.assistant.chat.reasoningVariant = update.reasoningVariant
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
            case .neutral: DotTheme.ink2
            }
        }
    }
}

// MARK: - Components

/// The key row the Speech to text page draws: the field, the button that stores it and
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
    var subtitleTone: Color = DotTheme.ink2

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
                            .font(DotType.font(12, .medium))
                            .foregroundStyle(DotTheme.coral)
                            .frame(width: 26, height: 26, alignment: .trailing)
                            // The symbol's own side bearing would otherwise end
                            // the row two points inside the card's edge, out of
                            // line with every other trailing control.
                            .padding(.trailing, -2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(DotPressStyle())
                    .help("Delete the stored key")
                    .accessibilityLabel("Delete the stored key from the Keychain")
                }
            }
        }
    }
}

/// A switch row: the name, the fact under it and the switch at the trailing
/// edge, drawn the way the Speech to text page draws one.
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

/// A row-major layout for controls that are wider than one line.
///
/// The style pills are a set, not a column, and a fixed `HStack` would either
/// clip a style or force the card wider than the window. The layout measures
/// each pill's own width and starts a new row when the next one does not fit,
/// so a long custom title moves to a second row instead of shrinking its
/// neighbours.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        var height: CGFloat = 0
        var isRowStart = true
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !isRowStart, rowWidth + size.width > available {
                widest = max(widest, rowWidth)
                height += rowHeight + verticalSpacing
                rowWidth = 0
                rowHeight = 0
                isRowStart = true
            }
            rowWidth += (isRowStart ? 0 : horizontalSpacing) + size.width
            rowHeight = max(rowHeight, size.height)
            isRowStart = false
        }
        widest = max(widest, rowWidth)
        height += rowHeight
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        var isRowStart = true
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !isRowStart, x + size.width > bounds.maxX {
                y += rowHeight + verticalSpacing
                x = bounds.minX
                rowHeight = 0
                isRowStart = true
            }
            if !isRowStart { x += horizontalSpacing }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width
            rowHeight = max(rowHeight, size.height)
            isRowStart = false
        }
    }
}

/// Coalesces a burst of edits into one check.
///
/// An address is typed one character at a time, and every character changes the
/// record. Asking the service about each prefix would send a request per
/// keystroke and store a cache entry per prefix; this waits for the typing to
/// stop and runs the newest action only. It is injectable so a test can prove
/// the coalescing without waiting a real typing pause: the delay runs on the
/// clock it is given, and a test hands in one it moves itself rather than the
/// wall clock the app uses.
@MainActor
final class AssistantCheckDebounce {
    /// How long an edit rests before it is checked.
    static let defaultDelay: Duration = .milliseconds(600)

    private let delay: Duration
    private let clock: any Clock<Duration>
    private var task: Task<Void, Never>?

    init(delay: Duration = AssistantCheckDebounce.defaultDelay, clock: any Clock<Duration> = ContinuousClock()) {
        self.delay = delay
        self.clock = clock
    }

    /// Replaces whatever was waiting with `action`, after the delay.
    func schedule(_ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        let clock = clock
        let delay = delay
        task = Task { @MainActor in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// Drops the pending action, if there is one.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
