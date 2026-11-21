import AppKit
import DotCore
import SwiftUI

/// Renders the light windows without opening them.
///
/// Every page is snapshotted from an offscreen `NSHostingView`: `ImageRenderer`
/// does not draw secure fields, the content of a `ScrollView` or a text
/// selection reliably. The hosting view is never placed in a window and nothing
/// appears on screen. The preview frame adds the three traffic-light dots and
/// the rounded corners that the window server normally draws, so the PNG reads
/// like the window without teaching the real views any fake chrome.
@MainActor
enum UIPreview {
    /// The argument that renders the light windows and exits.
    static let argument = "--render-ui"
    /// The environment variable that does the same, named without the product
    /// prefix that ``DotMigration/environment(_:in:)`` adds. That reader accepts
    /// the pre-rename spelling of the prefix as well.
    static let environmentKey = "RENDER_UI"

    /// The directory the render was asked for, if any.
    static func requestedDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> URL? {
        if let index = arguments.firstIndex(of: argument), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let value = DotMigration.environment(Self.environmentKey, in: environment) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return nil
    }

    /// Renders the key UI windows (Welcome, Tour, Settings, Palette) and exits.
    static func renderAll(to directory: URL) throws {
        try renderWelcomeAndAbout(to: directory)
        try renderSettings(to: directory)
        try renderSelectLists(to: directory)
        try renderHistory(to: directory)
        try renderPalette(to: directory)
    }

    /// Renders the welcome and about pages in both appearances.
    static func renderWelcomeAndAbout(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let welcome = WelcomeView(
            presets: ProviderPreset.all,
            providerReady: false,
            microphoneStatus: "Not requested yet",
            accessibilityGranted: true,
            shortcutLabel: Hotkey.defaultRecord.keycapLabel,
            onEnableMicrophone: { "Allowed" },
            onChangeShortcut: {},
            onOpenSettings: {},
            onFinish: {},
            stage: .setup,
            animated: false
        )
        let welcomeSize = CGSize(width: 720, height: 560)
        try writeHosted(
            WindowPreview(size: welcomeSize) {
                welcome
            },
            size: welcomeSize,
            scheme: .light,
            to: directory.appendingPathComponent("welcome.png")
        )
        try writeHosted(
            WindowPreview(size: welcomeSize) {
                welcome
            },
            size: welcomeSize,
            scheme: .dark,
            to: directory.appendingPathComponent("welcome-dark.png")
        )
        // A connected welcome: the row names the service, so this file does not.
        let chosen = ProviderPreset.openAI
        try writeHosted(
            WindowPreview(size: welcomeSize) {
                WelcomeView(
                    presets: ProviderPreset.all,
                    selectedPresetID: chosen.id,
                    providerReady: true,
                    microphoneStatus: "Allowed",
                    accessibilityGranted: true,
                    shortcutLabel: Hotkey.defaultRecord.keycapLabel,
                    onEnableMicrophone: { "Allowed" },
                    onChangeShortcut: {},
                    onOpenSettings: {},
                    onFinish: {},
                    stage: .setup,
                    animated: false,
                    previewConnection: ProviderConnectionResult(
                        status: .connected,
                        message: "Key saved. Using \(chosen.name).",
                        providerName: chosen.name
                    )
                )
            },
            size: welcomeSize,
            scheme: .light,
            to: directory.appendingPathComponent("welcome-connected.png")
        )
        try writeHosted(
            WindowPreview(size: welcomeSize) {
                WelcomeView(
                    presets: ProviderPreset.all,
                    selectedPresetID: chosen.id,
                    providerReady: true,
                    microphoneStatus: "Allowed",
                    accessibilityGranted: true,
                    shortcutLabel: Hotkey.defaultRecord.keycapLabel,
                    onEnableMicrophone: { "Allowed" },
                    onChangeShortcut: {},
                    onOpenSettings: {},
                    onFinish: {},
                    stage: .setup,
                    animated: false,
                    previewConnection: ProviderConnectionResult(
                        status: .connected,
                        message: "Key saved. Using \(chosen.name).",
                        providerName: chosen.name
                    )
                )
            },
            size: welcomeSize,
            scheme: .dark,
            to: directory.appendingPathComponent("welcome-connected-dark.png")
        )

        // The welcome's service card, on paper and on ink.
        let providerStates: [(name: String, scheme: ColorScheme)] = [
            ("welcome-provider.png", .light),
            ("welcome-provider-dark.png", .dark),
        ]
        for state in providerStates {
            try writeHosted(
                WindowPreview(size: welcomeSize) {
                    WelcomeView(
                        presets: ProviderPreset.all,
                        providerReady: false,
                        microphoneStatus: "Not requested yet",
                        accessibilityGranted: true,
                        shortcutLabel: Hotkey.defaultRecord.keycapLabel,
                        onEnableMicrophone: { "Allowed" },
                        onChangeShortcut: {},
                        onOpenSettings: {},
                        onFinish: {},
                        stage: .setup,
                        animated: false
                    )
                },
                size: welcomeSize,
                scheme: state.scheme,
                to: directory.appendingPathComponent(state.name)
            )
        }

        // The tour: one render per step, plus the first step on ink, so both
        // appearances and all three demonstrations are looked at.
        let tourStates: [(name: String, step: TourStep, scheme: ColorScheme)] = [
            ("welcome-tour-hold.png", .hold, .light),
            ("welcome-tour-speak.png", .speak, .light),
            ("welcome-tour-paste.png", .paste, .light),
            ("welcome-tour-hold-dark.png", .hold, .dark),
            ("welcome-tour-speak-dark.png", .speak, .dark),
            ("welcome-tour-paste-dark.png", .paste, .dark),
        ]
        // The same step at two moments of the loop: side by side these are the
        // proof that the stage is drawn from the clock and not from a still.
        try writeHosted(
            WindowPreview(size: welcomeSize) {
                WelcomeView(
                    presets: ProviderPreset.all,
                    providerReady: true,
                    microphoneStatus: "Allowed",
                    accessibilityGranted: true,
                    shortcutLabel: Hotkey.defaultRecord.keycapLabel,
                    onEnableMicrophone: { "Allowed" },
                    onChangeShortcut: {},
                    onOpenSettings: {},
                    onFinish: {},
                    stage: .tour,
                    tourStep: .hold,
                    tourPhase: 0.12,
                    animated: false
                )
            },
            size: welcomeSize,
            scheme: .light,
            to: directory.appendingPathComponent("welcome-tour-hold-early.png")
        )

        for state in tourStates {
            try writeHosted(
                WindowPreview(size: welcomeSize) {
                    WelcomeView(
                        presets: ProviderPreset.all,
                        providerReady: true,
                        microphoneStatus: "Allowed",
                        accessibilityGranted: true,
                        shortcutLabel: Hotkey.defaultRecord.keycapLabel,
                        onEnableMicrophone: { "Allowed" },
                        onChangeShortcut: {},
                        onOpenSettings: {},
                        onFinish: {},
                        stage: .tour,
                        tourStep: state.step,
                        animated: false
                    )
                },
                size: welcomeSize,
                scheme: state.scheme,
                to: directory.appendingPathComponent(state.name)
            )
        }
    }

    /// The appearance a preview of `scheme` must carry.
    ///
    /// The settings page paints itself from the configuration's appearance, and
    /// the shipped default is dark, so a light render has to say `light` or it
    /// would draw ink on a paper bitmap. `system` is never used here: a render
    /// names the palette it is meant to show.
    private static func appearance(for scheme: ColorScheme) -> AppearanceMode {
        scheme == .dark ? .dark : .light
    }

    /// The configuration every settings render is drawn from.
    ///
    /// The input card's calibration line is part of the shipped surface, so the
    /// rendered General page carries a device Dot has learned rather than hiding
    /// the row behind a fresh install. The output-grammar card is opt-in, so the
    /// render turns it on and gives it two overrides: one that changes the
    /// table's answer and one that restores the plain text for an app the table
    /// knows.
    ///
    /// The appearance is not part of the sample: every render sets it to the
    /// scheme it draws.
    private static func settingsSampleConfig() -> DotConfig {
        var config = DotConfig.default
        ProviderPreset.openAI.apply(to: &config)
        config.outputGrammarEnabled = true
        config.outputGrammarTargets = [
            "com.tinyspeck.slackmacgap": .chat,
            "com.apple.dt.Xcode": .plain,
        ]
        config.microphoneCalibration = [
            "DotRenderBuiltInMicrophone": MicrophoneCalibration(
                noiseFloorDBFS: -62,
                peakDBFS: -9,
                observedSamples: 14,
                updatedAt: Date(timeIntervalSinceReferenceDate: 0)
            ),
        ]
        return config
    }

    /// Renders the settings pages into `directory`.
    ///
    /// The sample uses the first row of the picker, so the connect card shows a
    /// chosen service and the endpoint cards carry that service's values.
    /// No key is supplied or read and the binding is a constant, so the
    /// configuration file is never touched.
    static func renderSettings(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sampleConfig = settingsSampleConfig()

        // The same list the app builds, without asking the Keychain whether a
        // key is there: a render must not depend on the person's Keychain.
        let providers = MenuBuilder.providerRows(config: sampleConfig) { _ in false }

        let size = CGSize(width: 820, height: 600)
        let pages: [(name: String, tab: Int, scheme: ColorScheme)] = [
            ("settings-general.png", 0, .light),
            ("settings-provider.png", 1, .light),
            ("settings-shortcuts.png", 2, .light),
            ("settings-appearance.png", 3, .light),
            ("settings-about.png", 4, .light),
            ("settings-general-dark.png", 0, .dark),
            ("settings-provider-dark.png", 1, .dark),
            ("settings-shortcuts-dark.png", 2, .dark),
            ("settings-appearance-dark.png", 3, .dark),
            ("settings-about-dark.png", 4, .dark),
        ]

        for page in pages {
            var config = sampleConfig
            config.appearance = appearance(for: page.scheme)
            let settings = settingsPreview(
                config: config,
                providers: providers,
                tab: page.tab
            )
            try writeHosted(
                WindowPreview(size: size) { settings },
                size: size,
                scheme: page.scheme,
                to: directory.appendingPathComponent(page.name)
            )
        }

        // Every page again, tall enough to hold all of its cards. The window
        // is 600 points so a page can scroll; a render of a scrolling page that
        // stops at the fold cannot show the cards below it, and the last card
        // of a page is exactly where a layout mistake hides.
        let tallSize = CGSize(width: 820, height: 1180)
        for page in pages {
            var config = sampleConfig
            config.appearance = appearance(for: page.scheme)
            let settings = settingsPreview(
                config: config,
                providers: providers,
                tab: page.tab,
                height: tallSize.height
            )
            let name = page.name.replacingOccurrences(of: ".png", with: "-tall.png")
            try writeHosted(
                WindowPreview(size: tallSize) { settings },
                size: tallSize,
                scheme: page.scheme,
                to: directory.appendingPathComponent(name)
            )
        }

        // The hand-filled row, with the endpoint and the model it stores.
        var customConfig = DotConfig.default
        customConfig.appearance = .light
        ProviderPreset.custom.apply(to: &customConfig)
        customConfig.providers[ProviderPreset.custom.providerID] = ProviderConfig(
            model: "whisper-1",
            baseURL: "http://127.0.0.1:8765/v1"
        )
        try writeHosted(
            WindowPreview(size: size) {
                settingsPreview(
                    config: customConfig,
                    providers: providers,
                    tab: 1
                )
            },
            size: size,
            scheme: .light,
            to: directory.appendingPathComponent("settings-provider-custom.png")
        )

        // A configuration that names a provider through an endpoint Dot ships
        // no row for: the card presents it as the custom endpoint it is, with the
        // stored endpoint and model in the fields.
        var storedConfig = DotConfig.default
        storedConfig.appearance = .light
        storedConfig.provider = ProviderIdentifier.xiaomi
        try writeHosted(
            WindowPreview(size: size) {
                settingsPreview(
                    config: storedConfig,
                    providers: providers,
                    tab: 1
                )
            },
            size: size,
            scheme: .light,
            to: directory.appendingPathComponent("settings-provider-stored-endpoint.png")
        )

        var azureConfig = DotConfig.default
        azureConfig.appearance = .light
        azureConfig.provider = ProviderIdentifier.azure
        try writeHosted(
            WindowPreview(size: size) {
                settingsPreview(
                    config: azureConfig,
                    providers: providers,
                    tab: 1
                )
            },
            size: size,
            scheme: .light,
            to: directory.appendingPathComponent("settings-provider-azure.png")
        )

        // The status row in the service card in every state it can hold, in
        // both appearances. The states are handed to the page rather than asked
        // of a service, so a render makes no request. Each state carries the
        // service that can honestly produce it: Apple for Unavailable,
        // ElevenLabs for the accepted-but-restricted key, OpenAI for the rest.
        // A keyed service needs a stored key: the key field then shows the
        // saved-key state, the replacement placeholder and the delete control.
        // "Needs setup" is the same row with no key. The time a check is shown
        // with is fixed, so the picture does not depend on when it was drawn.
        let checkedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let credentialStates: [(name: String, status: SpeechCredentialStatus, preset: ProviderPreset, keyed: Bool)] = [
            ("checking", .checking, .openAI, true),
            ("verified", .settled(.verified, checkedAt: checkedAt), .openAI, true),
            (
                "verified-with-restriction",
                .settled(
                    .verifiedWithRestriction(
                        "ElevenLabs accepted the key. It is not allowed to list models, which Dot does not use."
                    ),
                    checkedAt: checkedAt
                ),
                .elevenLabs,
                true
            ),
            ("rejected", .settled(.rejected(status: 401), checkedAt: checkedAt), .openAI, true),
            ("service-error", .settled(.serviceError(status: 503, host: "the service"), checkedAt: checkedAt), .openAI, true),
            ("unreachable", .settled(.unreachable("Can't reach the service."), checkedAt: checkedAt), .openAI, true),
            ("needs-setup", .settled(.needsSetup("Add an API key for this service."), checkedAt: checkedAt), .openAI, false),
            ("not-saved", .notSaved("The Keychain did not give the key back."), .openAI, true),
            ("unavailable", .settled(.unavailable("Needs macOS 26 or newer."), checkedAt: checkedAt), .apple, false),
        ]
        for state in credentialStates {
            for scheme in [ColorScheme.light, .dark] {
                var config = sampleConfig
                state.preset.apply(to: &config)
                config.appearance = appearance(for: scheme)
                let rows = MenuBuilder.providerRows(config: config) { id in
                    state.keyed && id == state.preset.providerID
                }
                let suffix = scheme == .dark ? "-dark" : ""
                try writeHosted(
                    WindowPreview(size: size) {
                        settingsPreview(
                            config: config,
                            providers: rows,
                            tab: 1,
                            credential: state.status
                        )
                    },
                    size: size,
                    scheme: scheme,
                    to: directory.appendingPathComponent("settings-provider-\(state.name)\(suffix).png")
                )
            }
        }

        // The About page with the update row in each state it can hold. The
        // states are handed to the view rather than asked for, so a render
        // never reaches GitHub.
        let aboutStates: [(name: String, update: AboutUpdateState)] = [
            ("settings-about-update-current.png", .upToDate),
            ("settings-about-update-available.png", .available(version: "2.0", page: nil)),
            ("settings-about-update-unreachable.png", .unreachable),
        ]
        for state in aboutStates {
            var config = sampleConfig
            config.appearance = .light
            try writeHosted(
                WindowPreview(size: tallSize) {
                    settingsPreview(
                        config: config,
                        providers: providers,
                        tab: 4,
                        aboutUpdate: state.update,
                        height: tallSize.height
                    )
                },
                size: tallSize,
                scheme: .light,
                to: directory.appendingPathComponent(state.name)
            )
        }

        // Every update state at the real window size, in both appearances.
        // The states are supplied to the page, so no render reaches GitHub or
        // opens a release page.
        let longVersion = "9.8.7-beta.3+release.candidate.20261120"
        let longBuild = "4812.7.19-nightly"
        let longRelease = "9.9.0-rc.1+release.candidate.20261120"
        let windowStates: [(name: String, update: AboutUpdateState, version: String?, build: String?)] = [
            ("idle", .idle, nil, nil),
            ("checking", .checking, nil, nil),
            ("current", .upToDate, nil, nil),
            ("available", .available(version: "9.9.0", page: nil), nil, nil),
            ("unreachable", .unreachable, nil, nil),
            ("long-build", .upToDate, longVersion, longBuild),
            ("long-combined", .available(version: longRelease, page: nil), longVersion, longBuild),
            // An empty build is the preview's absent build. A nil would fall
            // through to the render's default build number instead.
            ("no-build", .upToDate, "1.0", ""),
        ]
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let suffix = scheme == .dark ? "-dark" : ""
            for state in windowStates {
                var config = sampleConfig
                config.appearance = appearance(for: scheme)
                try writeHosted(
                    WindowPreview(size: size) {
                        settingsPreview(
                            config: config,
                            providers: providers,
                            tab: 4,
                            aboutUpdate: state.update,
                            aboutVersion: state.version,
                            aboutBuild: state.build
                        )
                    },
                    size: size,
                    scheme: scheme,
                    to: directory.appendingPathComponent("settings-about-state-\(state.name)\(suffix).png")
                )
            }
        }

        // A service with a stored key: the key field is empty, the delete
        // button is present and the status chip reads Connected.
        let connectedProviders = MenuBuilder.providerRows(config: sampleConfig) { _ in true }
        let sampleModels = [
            AvailableModel(id: "gpt-4o-transcribe", name: "gpt-4o-transcribe"),
            AvailableModel(id: "gpt-4o-mini-transcribe", name: "gpt-4o-mini-transcribe"),
            AvailableModel(id: "whisper-1", name: "whisper-1"),
        ]
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            var config = sampleConfig
            config.appearance = appearance(for: scheme)
            var openAISettings = config.settings(for: ProviderIdentifier.openAI)
            openAISettings.model = "gpt-4o-transcribe"
            config.providers[ProviderIdentifier.openAI] = openAISettings
            let suffix = scheme == .dark ? "-dark" : ""
            try writeHosted(
                WindowPreview(size: tallSize) {
                    settingsPreview(
                        config: config,
                        providers: connectedProviders,
                        tab: 1,
                        models: sampleModels,
                        height: tallSize.height
                    )
                },
                size: tallSize,
                scheme: scheme,
                to: directory.appendingPathComponent("settings-provider-connected\(suffix).png")
            )
        }

        // One page per engine, in both appearances. Every service has its own
        // set of rows, so a page that is only ever rendered for the first row
        // of the picker proves nothing about the other seven.
        for preset in ProviderPreset.all {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                var config = sampleConfig
                preset.apply(to: &config)
                config.provider = preset.providerID
                config.appearance = appearance(for: scheme)
                let suffix = scheme == .dark ? "-dark" : ""
                let name = "settings-provider-" + preset.id + suffix + ".png"
                try writeHosted(
                    WindowPreview(size: size) {
                        settingsPreview(
                            config: config,
                            providers: providers,
                            tab: 1
                        )
                    },
                    size: size,
                    scheme: scheme,
                    to: directory.appendingPathComponent(name)
                )
            }
        }

        try renderAssistantSettings(to: directory, providers: providers)
    }

    /// Renders the AI rewrite page into `directory`, in the states it can hold.
    ///
    /// Every fact a page would read at run time is handed to it here: the keys a
    /// service holds and the model list its service would answer with. A render
    /// must not read the Keychain or ask a service, and the two states of a page
    /// must be two files rather than two different Macs.
    private static func renderAssistantSettings(
        to directory: URL,
        providers: [MenuProvider]
    ) throws {
        let width: CGFloat = 820
        let tallPage: CGFloat = 1180
        var base = DotConfig.default
        ProviderPreset.openAI.apply(to: &base)

        func render(
            _ name: String,
            tab: Int,
            keys: Set<String>,
            voices: [VoiceDescriptor]? = nil,
            connectors: [ConnectorSummary]? = nil,
            connection: AssistantConnectionState? = nil,
            models: [DiscoveredModel]? = nil,
            style: AssistantPage.StyleSelection? = nil,
            configure: (inout DotConfig) -> Void
        ) throws {
            let size = CGSize(width: width, height: tallPage)
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                var config = base
                configure(&config)
                config.appearance = appearance(for: scheme)
                let suffix = scheme == .dark ? "-dark" : ""
                try writeHosted(
                    WindowPreview(size: size) {
                        settingsPreview(
                            config: config,
                            providers: providers,
                            tab: tab,
                            assistantKeys: keys,
                            assistantConnection: connection,
                            assistantDiscoveredModels: models,
                            assistantStyleSelection: style,
                            voices: voices,
                            connectors: connectors,
                            height: size.height
                        )
                    },
                    size: size,
                    scheme: scheme,
                    to: directory.appendingPathComponent("settings-\(name)\(suffix)-tall.png")
                )
            }
        }

        let customStyles = [
            CustomRewriteStyle(
                id: "haiku",
                title: "Haiku",
                instruction: "Rewrite as a three line haiku."
            ),
            CustomRewriteStyle(
                id: "email",
                title: "Email",
                instruction: "Rewrite for a work email."
            ),
        ]

        // What each service would answer with. The catalogue no longer ships a
        // model list, so the samples are handed to the page the way a live read
        // would: the ids a picker shows, and what the service published about
        // them. `assistant-connected` carries no reasoning support and
        // `assistant-rewrite` does, which is what puts both states of the
        // Reasoning row in front of the reviewer.
        let plainModels = [
            DiscoveredModel(id: "gpt-4o", name: "GPT-4o"),
            DiscoveredModel(id: "gpt-4o-mini", name: "GPT-4o mini"),
        ]
        let reasoningModels = [
            DiscoveredModel(
                id: "gpt-4o",
                name: "GPT-4o",
                reasoning: ModelReasoningSupport(
                    efforts: ["low", "high", "max"],
                    toggle: true,
                    defaultEffort: "high"
                )
            ),
            DiscoveredModel(id: "gpt-4o-mini", name: "GPT-4o mini"),
        ]
        // A sample id, never a brand: the UI layer may only show the name a
        // catalogue row carries.
        let planModels = [DiscoveredModel(id: "chat-model")]
        let subscriptionModels = [
            DiscoveredModel(
                id: "kimi-k3",
                name: "Kimi K3",
                reasoning: ModelReasoningSupport(
                    efforts: ["low", "high", "max"],
                    toggle: true,
                    defaultEffort: "high"
                )
            ),
            DiscoveredModel(id: "kimi-k2", name: "Kimi K2"),
        ]

        /// An assistant the person set up on one row, with the status a check
        /// would have reported.
        func setUp(_ config: inout DotConfig, providerID: String, model: String, isSetUp: Bool = true) {
            config.assistant.isSetUp = isSetUp
            config.assistant.chat = AssistantSettings(providerID: providerID, model: model)
        }

        // The status row's four states, and the two rows added after the first
        // release. The first picture is the bug's own: a key the speech page
        // stored, and no assistant chosen.
        try render("assistant", tab: 5, keys: [AssistantSettings.defaultProviderID], connection: .notSetUp) { config in
            config.assistant.chat = AssistantSettings(
                providerID: AssistantSettings.defaultProviderID,
                model: "gpt-4o-mini"
            )
        }
        try render("assistant-no-key", tab: 5, keys: [], connection: .notSetUp) { config in
            config.assistant.chat = AssistantSettings(
                providerID: AssistantSettings.defaultProviderID,
                model: "gpt-4o-mini"
            )
        }
        // The reported state: a custom endpoint the build was told about, with no
        // address and no set-up flag. The page has to name it rather than show
        // "None", so the address field and the switch that finishes it are
        // reachable.
        try render("assistant-custom-unfinished", tab: 5, keys: [], connection: .notSetUp) { config in
            config.assistant.chat = AssistantSettings(
                providerID: AssistantProviderCatalogue.customRow.id
            )
        }
        try render(
            "assistant-checking",
            tab: 5,
            keys: [AssistantSettings.defaultProviderID],
            connection: .checking
        ) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
        }
        try render(
            "assistant-connected",
            tab: 5,
            keys: [AssistantSettings.defaultProviderID],
            connection: .connected,
            models: plainModels
        ) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
        }
        try render(
            "assistant-unreachable",
            tab: 5,
            keys: [AssistantSettings.defaultProviderID],
            connection: .notConnected("Rejected the key (401)"),
            models: plainModels
        ) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
        }
        // The two rows added after the first release. Their names, ids and
        // addresses come from the catalogue: the UI may not carry a vendor's
        // name in a string.
        let planRow = AssistantProviderCatalogue.row(for: AssistantProviderID.xiaomi)
        let subscriptionRow = AssistantProviderCatalogue.row(for: AssistantProviderID.openCodeGo)
        let planName = "assistant-" + planRow.id
        let tokenPlanName = planName + "-token-plan"
        let subscriptionName = "assistant-" + subscriptionRow.id
        let planAddress = planRow.plans.first { $0.id == "token-plan" }?.baseURL?.absoluteString
        try render(planName, tab: 5, keys: [planRow.id], connection: .connected, models: planModels) { config in
            setUp(&config, providerID: planRow.id, model: "chat-model")
        }
        try render(
            tokenPlanName,
            tab: 5,
            keys: [planRow.id],
            connection: .connected,
            models: planModels
        ) { config in
            setUp(&config, providerID: planRow.id, model: "chat-model")
            config.assistant.chat.baseURL = planAddress
        }
        try render(
            subscriptionName,
            tab: 5,
            keys: [subscriptionRow.id],
            connection: .connected,
            models: subscriptionModels
        ) { config in
            setUp(&config, providerID: subscriptionRow.id, model: "kimi-k3")
        }
        // The page with the master switch off: one card, and nothing below it.
        try render("assistant-off", tab: 5, keys: [AssistantSettings.defaultProviderID], connection: .connected) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
            AssistantPage.setRewriting(false, in: &config.assistant)
        }
        // The agent prompt's own card: its switch, its prompt editor, and the
        // ruling that lets no section hold a detail the speaker did not give.
        try render(
            "assistant-rewrite",
            tab: 5,
            keys: [AssistantSettings.defaultProviderID],
            connection: .connected,
            models: reasoningModels
        ) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
            config.assistant.rewrite.custom = customStyles
        }
        // The standing rules, off and on. Off with text stored proves the field
        // is hidden rather than cleared: the setting is kept and the switch is
        // what decides whether the block is delivered. On draws the six-line
        // field under the Agent prompt's own editor.
        try render(
            "assistant-rewrite-standing-rules-off",
            tab: 5,
            keys: [AssistantSettings.defaultProviderID],
            connection: .connected,
            models: reasoningModels,
            style: .builtIn(.prompt)
        ) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
            config.assistant.rewrite.setStandingRules(
                "## House rules\n- Run the build and the tests before you report.\n- Never touch main."
            )
            config.assistant.rewrite.standingRulesEnabled = false
        }
        try render(
            "assistant-rewrite-standing-rules-on",
            tab: 5,
            keys: [AssistantSettings.defaultProviderID],
            connection: .connected,
            models: reasoningModels,
            style: .builtIn(.prompt)
        ) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
            config.assistant.rewrite.setStandingRules(
                "## House rules\n- Run the build and the tests before you report.\n- Never touch main."
            )
            config.assistant.rewrite.standingRulesEnabled = true
        }
        // Concise and a custom style, which is what proves the working rules
        // are scoped to the agent prompt and the editor belongs to one style.
        try render(
            "assistant-rewrite-concise",
            tab: 5,
            keys: [AssistantSettings.defaultProviderID],
            connection: .connected,
            models: plainModels,
            style: .builtIn(.concise)
        ) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
            config.assistant.rewrite.custom = customStyles
        }
        try render(
            "assistant-rewrite-custom",
            tab: 5,
            keys: [AssistantSettings.defaultProviderID],
            connection: .connected,
            models: plainModels,
            style: .custom("haiku")
        ) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
            config.assistant.rewrite.custom = customStyles
        }
        // Two shipped styles removed: the row loses them, the selection moves
        // to the first style still offered, and the row that restores them is
        // drawn under the card.
        try render(
            "assistant-rewrite-deleted",
            tab: 5,
            keys: [AssistantSettings.defaultProviderID],
            connection: .connected,
            models: plainModels
        ) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
            config.assistant.rewrite.deleteBuiltIn(.prompt)
            config.assistant.rewrite.deleteBuiltIn(.casual)
        }
        // Every shipped style removed and none of the person's own added: the
        // card says what to do instead of drawing the controls of a style that
        // is not there.
        try render(
            "assistant-rewrite-empty",
            tab: 5,
            keys: [AssistantSettings.defaultProviderID],
            connection: .connected,
            models: plainModels
        ) { config in
            setUp(&config, providerID: AssistantSettings.defaultProviderID, model: "gpt-4o")
            for id in RewriteStyleID.shippedCases {
                config.assistant.rewrite.deleteBuiltIn(id)
            }
        }
        // Voices and Connectors are not pages of this product: the sidebar
        // offers Speech to text and AI rewrite, and tab 6 and 7 open AI rewrite.
        // Rendering either tab here would write a picture named for a page the
        // window no longer has.
    }

    /// Connector rows with a mixture of permission states, built from the
    /// shipped connectors so the names, the symbols and the tools are the real
    /// ones and only the permissions are sample.
    private static func sampleConnectorSummaries() -> [ConnectorSummary] {
        let states: [ConnectorID: ConnectorPermissionStatus] = [
            .reminders: .granted,
            .calendar: .notDetermined,
            .contacts: .granted,
            .notes: .denied,
            .files: .granted,
            .mail: .notDetermined,
            .messages: .denied,
            .apps: .granted,
            .shortcuts: .restricted,
            .music: .granted,
            .spotify: .notDetermined,
            .system: .granted,
        ]
        let settings = ConnectorSettings.default
        return ConnectorCatalog.make().map { connector in
            ConnectorSummary(
                id: connector.id,
                displayName: connector.displayName,
                symbol: connector.symbol,
                detail: connector.detail,
                isEnabled: settings.isEnabled(connector.id),
                permission: ConnectorPermission(
                    status: states[connector.id] ?? .granted,
                    service: connector.displayName,
                    settingsURL: ConnectorPermission.Pane.automation.url
                ),
                tools: connector.tools().map { tool in
                    ConnectorSummary.ToolSummary(
                        name: tool.name,
                        title: tool.title,
                        detail: tool.description,
                        risk: tool.risk,
                        policy: ToolPolicy.derived(from: tool.risk)
                    )
                }
            )
        }
    }

    private static func settingsPreview(
        config: DotConfig,
        providers: [MenuProvider],
        tab: Int,
        aboutUpdate: AboutUpdateState? = nil,
        aboutVersion: String? = nil,
        aboutBuild: String? = nil,
        models: [AvailableModel]? = nil,
        assistantKeys: Set<String>? = nil,
        assistantConnection: AssistantConnectionState? = nil,
        assistantDiscoveredModels: [DiscoveredModel]? = nil,
        assistantStyleSelection: AssistantPage.StyleSelection? = nil,
        voices: [VoiceDescriptor]? = nil,
        connectors: [ConnectorSummary]? = nil,
        credential: SpeechCredentialStatus? = nil,
        height: CGFloat? = nil
    ) -> some View {
        SettingsPreviewHost(
            config: config,
            providers: providers,
            tab: tab,
            aboutUpdate: aboutUpdate,
            aboutVersion: aboutVersion,
            aboutBuild: aboutBuild,
            models: models,
            assistantKeys: assistantKeys,
            assistantConnection: assistantConnection,
            assistantDiscoveredModels: assistantDiscoveredModels,
            assistantStyleSelection: assistantStyleSelection,
            voices: voices,
            connectors: connectors,
            credential: credential,
            height: height
        )
    }

    /// A settings window that owns its configuration for the length of a render.
    ///
    /// The store is a `@StateObject`, so the page draws one configuration for as
    /// long as the render holds the view, exactly as the window does.
    private struct SettingsPreviewHost: View {
        @StateObject private var store: ConfigStore

        let providers: [MenuProvider]
        let tab: Int
        let aboutUpdate: AboutUpdateState?
        let aboutVersion: String?
        let aboutBuild: String?
        let models: [AvailableModel]?
        let assistantKeys: Set<String>?
        let assistantConnection: AssistantConnectionState?
        let assistantDiscoveredModels: [DiscoveredModel]?
        let assistantStyleSelection: AssistantPage.StyleSelection?
        let voices: [VoiceDescriptor]?
        let connectors: [ConnectorSummary]?
        let credential: SpeechCredentialStatus?
        let height: CGFloat?

        init(
            config: DotConfig,
            providers: [MenuProvider],
            tab: Int,
            aboutUpdate: AboutUpdateState?,
            aboutVersion: String?,
            aboutBuild: String?,
            models: [AvailableModel]?,
            assistantKeys: Set<String>?,
            assistantConnection: AssistantConnectionState?,
            assistantDiscoveredModels: [DiscoveredModel]?,
            assistantStyleSelection: AssistantPage.StyleSelection?,
            voices: [VoiceDescriptor]?,
            connectors: [ConnectorSummary]?,
            credential: SpeechCredentialStatus?,
            height: CGFloat?
        ) {
            _store = StateObject(wrappedValue: ConfigStore(config: config))
            self.providers = providers
            self.tab = tab
            self.aboutUpdate = aboutUpdate
            self.aboutVersion = aboutVersion
            self.aboutBuild = aboutBuild
            self.models = models
            self.assistantKeys = assistantKeys
            self.assistantConnection = assistantConnection
            self.assistantDiscoveredModels = assistantDiscoveredModels
            self.assistantStyleSelection = assistantStyleSelection
            self.voices = voices
            self.connectors = connectors
            self.credential = credential
            self.height = height
        }

        var body: some View {
            SettingsView(
                store: store,
                providers: providers,
                tab: tab,
                onChange: {},
                onSetAPIKey: { _, _ in nil },
                onChangeShortcut: {},
                onChangePasteShortcut: {},
                onOpenWelcome: {},
                aboutUpdatePreview: aboutUpdate,
                modelPreview: models
            )
            .environment(\.settingsHeadless, true)
            .environment(\.settingsDefaultInputUID, "DotRenderBuiltInMicrophone")
            .environment(\.settingsVersionOverride, aboutVersion ?? "1.0")
            .environment(\.settingsBuildOverride, aboutBuild)
            .environment(\.settingsHeightOverride, height)
            .environment(\.settingsCredentialPreview, credential)
            .environment(\.assistantKeyedProviders, assistantKeys)
            .environment(\.assistantConnectionPreview, assistantConnection)
            .environment(\.assistantDiscoveredModelsPreview, assistantDiscoveredModels)
            .environment(\.assistantStyleSelectionPreview, assistantStyleSelection)
            .environment(\.settingsVoiceOptions, voices)
            .environment(\.settingsConnectorSummaries, connectors)
        }
    }

    /// Renders the history window into `directory`.
    ///
    /// Three states are captured: a populated history, the empty history and a
    /// filtered search. The transcripts are sample copy only — no real
    /// transcript, key or file is read — and the view is drawn with the same
    /// offscreen hosting path as settings because it contains a scroll view.
    static func renderHistory(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let samples = [
            "Meeting notes: ship the history window on Thursday, then walk through the empty, filtered and no-match states with Priya before the Friday sync, and leave time for the search animation review.",
            "Remind me to water the fig tree tomorrow and pick up oat milk on the way home.",
            "The retry loop should stop after three attempts and show the provider error.",
            "Quick thought: the onboarding copy is lovely, but step two could be one sentence shorter.",
            "Book the dentist for tomorrow morning; the first week of November works too.",
        ]
        let size = CGSize(width: 620, height: 560)

        try writeHistory(
            samples,
            query: "",
            size: size,
            scheme: .light,
            to: directory.appendingPathComponent("history.png")
        )
        try writeHistory(
            [],
            query: "",
            size: size,
            scheme: .light,
            to: directory.appendingPathComponent("history-empty.png")
        )
        try writeHistory(
            samples,
            query: "tomorrow",
            size: size,
            scheme: .light,
            to: directory.appendingPathComponent("history-search.png")
        )
        try writeHistory(
            samples,
            query: "xylophone",
            size: size,
            scheme: .light,
            to: directory.appendingPathComponent("history-no-matches.png")
        )
        try writeHistory(
            samples,
            query: "",
            size: size,
            scheme: .dark,
            to: directory.appendingPathComponent("history-dark.png")
        )
    }

    /// Renders the palette into `directory`.
    ///
    /// Four states: the recent dictations with their ages, a search that
    /// matches, a search that matches nothing, and the empty palette a fresh
    /// install summons. The palette floats on paper, so it is drawn in both
    /// appearances: the second one is where a paper surface can go wrong.
    static func renderPalette(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let samples = SampleTranscripts.entries(now: now)
        let states: [(name: String, entries: [HistoryStore.Entry], query: String, scheme: ColorScheme)] = [
            ("palette.png", samples, "", .light),
            ("palette-search.png", samples, "tomorrow", .light),
            ("palette-empty.png", [], "", .light),
            ("palette-no-matches.png", samples, "xylophone", .light),
            ("palette-dark.png", samples, "", .dark),
        ]
        for state in states {
            let model = PaletteModel(now: { now })
            model.present(entries: state.entries)
            model.query = state.query
            try writeHosted(
                PaletteSheet(model: model),
                size: PaletteController.panelSize,
                scheme: state.scheme,
                to: directory.appendingPathComponent(state.name)
            )
        }
    }

    /// The palette with its window chrome, so the PNG reads like the panel.
    private struct PaletteSheet: View {
        @ObservedObject var model: PaletteModel

        var body: some View {
            PaletteView(model: model, insert: { _ in }, copy: { _ in })
                .padding(10)
                .background(Color.clear)
        }
    }

    /// The sample transcripts the palette and the history renders share.
    private enum SampleTranscripts {
        static func entries(now: Date) -> [HistoryStore.Entry] {
            [
                (text: "Meeting notes: ship the history window on Thursday, then walk through the empty, filtered and no-match states with Priya before the Friday sync.", age: 900.0),
                (text: "Remind me to water the fig tree tomorrow and pick up oat milk on the way home.", age: 5_400.0),
                (text: "The retry loop should stop after three attempts and show the provider error.", age: 90_000.0),
                (text: "Quick thought: the onboarding copy is lovely, but step two could be one sentence shorter.", age: 400_000.0),
                (text: "Book the dentist for tomorrow morning; the first week of November works too.", age: 900_000.0),
            ].map { HistoryStore.Entry(text: $0.text, addedAt: now.addingTimeInterval(-$0.age)) }
        }
    }

    private static func writeHistory(
        _ history: [String],
        query: String,
        size: CGSize,
        scheme: ColorScheme,
        to url: URL
    ) throws {
        let view = HistoryView(
            history: history,
            onCopy: { _ in },
            onClear: {},
            onClose: {},
            initialQuery: query
        )
        .environment(\.historyHeadless, true)

        try writeHosted(
            WindowPreview(size: size) {
                view
            },
            size: size,
            scheme: scheme,
            to: url
        )
    }

    /// Renders the island's states in both appearances.
    ///
    /// The island is drawn by ``HUDPreview`` with the same `ImageRenderer` as
    /// the rest of the previews, so this path only decides which states and
    /// which appearances are written. The card is dark in both schemes; the
    /// scroller and the rest of the system chrome follow the scheme, which is
    /// why the render is made in both.
    ///
    /// - Parameter directory: where the PNGs are written.
    /// The menu bar mark, at eight moments of its breath.
    ///
    /// The glyph is small and its whole point is its shape, so the sheet draws
    /// it large above and at its real size below: a plate with a bite that only
    /// reads when it is 72 points tall is not a menu bar glyph.
    static let menuGlyphSize = CGSize(width: 700, height: 190)

    static func renderMenuGlyph(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try writeHosted(
            MenuGlyphSheet(),
            size: menuGlyphSize,
            scheme: .light,
            to: directory.appendingPathComponent("menu-glyph.png")
        )
    }

    /// Eight moments of the breath, large and at true size.
    private struct MenuGlyphSheet: View {
        var body: some View {
            VStack(alignment: .center, spacing: 18) {
                HStack(spacing: 12) {
                    ForEach(0..<8, id: \.self) { step in
                        glyph(step: step, side: 68)
                    }
                }
                HStack(spacing: 12) {
                    ForEach(0..<8, id: \.self) { step in
                        glyph(step: step, side: MenuGlyph.side)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DotTheme.paper)
        }

        private func glyph(step: Int, side: CGFloat) -> some View {
            Image(nsImage: MenuGlyph.image(phase: Double(step) / 8))
                .resizable()
                .interpolation(.none)
                .frame(width: side, height: side)
        }
    }

    static func renderHUDStates(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let states: [(state: HUDPreview.State, name: String)] = [
            (.recording, "hud-recording"),
            (.live, "hud-live"),
            (.ready, "hud-ready"),
            (.transcript, "hud-transcript"),
            (.transcriptLong, "hud-transcript-long"),
            (.transcribing, "hud-transcribing"),
        ]
        for entry in states {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let suffix = scheme == .dark ? "-dark" : ""
                let image = try HUDPreview.render(state: entry.state, scheme: scheme)
                guard let data = image.representation(using: .png, properties: [:]) else {
                    throw RenderError.couldNotEncode
                }
                try data.write(
                    to: directory.appendingPathComponent("\(entry.name)\(suffix).png"),
                    options: .atomic
                )
            }
        }
    }

    /// Renders a view through an offscreen `NSHostingView`.
    ///
    /// `ImageRenderer` does not draw the content of a `ScrollView` on this
    /// macOS version, so the settings pages are snapshotted from a real
    /// hosting view instead. The view is never placed in a window.
    private static func writeHosted<Content: View>(
        _ view: Content,
        size: CGSize,
        scheme: ColorScheme,
        to url: URL
    ) throws {
        let hosting = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)
                // The bitmap below is two times the view, so the view has to
                // resolve its hairlines at that scale: an offscreen hosting view
                // has no screen to ask.
                .environment(\.displayScale, 2)
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * 2,
            pixelsHigh: Int(size.height) * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderError.couldNotRender
        }
        bitmap.size = size
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.couldNotEncode
        }
        try data.write(to: url, options: .atomic)
    }

    /// The render could not be made.
    enum RenderError: Error {
        case couldNotRender
        case couldNotEncode
    }
}

/// The window chrome that only a preview needs: rounded corners, an edge and
/// the three traffic lights. The real views stay free of fake chrome.
private struct WindowPreview<Content: View>: View {
    let size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: DotTheme.windowCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DotTheme.windowCorner, style: .continuous)
                    .strokeBorder(DotTheme.windowBorder, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) { trafficLights }
            .frame(width: size.width, height: size.height)
    }

    private var trafficLights: some View {
        HStack(spacing: 8) {
            dot(Color(red: 1.0, green: 0.373, blue: 0.341))
            dot(Color(red: 0.996, green: 0.737, blue: 0.180))
            dot(Color(red: 0.157, green: 0.784, blue: 0.251))
        }
        .padding(.leading, 14)
        .padding(.top, 14)
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(
                Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
    }
}

// MARK: - The open list

extension UIPreview {
    /// The size of one open-list sheet.
    static let selectPreviewSize = CGSize(width: 620, height: 560)

    /// Renders an open list beside its trigger, in both appearances.
    ///
    /// The list is a window of its own, and a window has no place in an
    /// offscreen hosting view, so the sheet draws the list's own view and the
    /// trigger's own view in the places the panel would put them. The trigger
    /// and the card are the shipped views: only the two frames are composed
    /// here.
    static func renderSelectLists(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var config = DotConfig.default
        ProviderPreset.openAI.apply(to: &config)
        let services = serviceRows(config: config)
        let modes = RecordingMode.allCases.map { DotSelectRow(title: $0.title) }
        let selectedMode = RecordingMode.allCases.firstIndex(of: config.recordingMode) ?? 0

        let sheets: [(name: String, label: String, rows: [DotSelectRow], selected: Int, highlight: Int, width: CGFloat)] = [
            (
                "select-open-service",
                "Service",
                services,
                services.firstIndex { $0.title == ProviderPreset.openAI.name } ?? 0,
                2,
                220
            ),
            (
                "select-open-recording-mode",
                "Recording mode",
                modes,
                selectedMode,
                selectedMode == 0 ? 1 : 0,
                210
            ),
        ]

        for sheet in sheets {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let suffix = scheme == .dark ? "-dark" : ""
                try writeHosted(
                    WindowPreview(size: selectPreviewSize) {
                        DotSelectOpenPreview(
                            label: sheet.label,
                            rows: sheet.rows,
                            selectedIndex: sheet.selected,
                            highlight: sheet.highlight,
                            triggerWidth: sheet.width
                        )
                    },
                    size: selectPreviewSize,
                    scheme: scheme,
                    to: directory.appendingPathComponent("\(sheet.name)\(suffix).png")
                )
            }
        }
    }

    /// The rows of the Service picker, with the line each one carries.
    private static func serviceRows(config: DotConfig) -> [DotSelectRow] {
        ProviderPreset.rows(for: config).map { preset in
            let model = config.settings(for: preset.providerID).model?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail: String?
            if !preset.hasEndpoint {
                detail = "On this Mac"
            } else if model.isEmpty {
                detail = preset.key == .required ? "Requires API key" : nil
            } else {
                detail = ProviderModelCatalog.formattedName(for: model)
            }
            return DotSelectRow(title: preset.name, detail: detail, symbol: preset.symbol)
        }
    }
}

/// An open list drawn next to the trigger that opened it.
///
/// It is a page-like sheet rather than a window: a card holds one settings row,
/// the trigger sits where the row's trailing control sits, and the list hangs
/// from the trigger's leading edge with the gap the panel leaves.
@MainActor
private struct DotSelectOpenPreview: View {
    let label: String
    let rows: [DotSelectRow]
    let selectedIndex: Int
    let highlight: Int
    let triggerWidth: CGFloat

    private let pageInset: CGFloat = 16
    private let rowInset: CGFloat = 18
    private let cardHeight: CGFloat = 110
    private let triggerHeight = DotSelectMetrics.height

    private var cardSize: CGSize {
        DotSelectPlacement.size(
            triggerWidth: triggerWidth,
            widestRow: DotSelectListMetrics.widestRow(rows),
            rowHeights: rows.map { DotSelectPlacement.rowHeight(detail: $0.detail) }
        )
    }

    var body: some View {
        let size = UIPreview.selectPreviewSize
        // The list may be wider than its trigger and hangs from its leading
        // edge, so the trigger is placed where the wider of the two still ends
        // inside the sheet.
        let triggerX = size.width - pageInset - rowInset - max(triggerWidth, cardSize.width)
        let triggerY = pageInset + (cardHeight - triggerHeight) / 2
        ZStack(alignment: .topLeading) {
            DotTheme.paper
            pageCard(triggerX: triggerX)
            Text(label)
                .font(DotType.font(13, .medium))
                .foregroundStyle(DotTheme.ink)
                .offset(x: pageInset + rowInset, y: triggerY + 6)
            DotSelectTriggerPreview(title: title, width: triggerWidth)
                .offset(x: triggerX, y: triggerY)
            DotSelectListCard(
                rows: rows,
                selectedIndex: selectedIndex,
                highlight: highlight,
                size: cardSize,
                onHighlight: { _ in },
                onChoose: { _ in }
            )
            .frame(width: cardSize.width, height: cardSize.height)
            .offset(x: triggerX, y: triggerY + triggerHeight + DotSelectPlacement.gap)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The words the trigger shows: the selected row's title.
    private var title: String {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex].title : "Choose…"
    }

    private func pageCard(triggerX: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
            .fill(DotTheme.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                    .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
            )
            .frame(
                width: triggerX + triggerWidth + rowInset - pageInset,
                height: cardHeight
            )
            .offset(x: pageInset, y: pageInset)
    }
}

/// The trigger as it draws when it is closed and at rest.
@MainActor
private struct DotSelectTriggerPreview: View {
    let title: String
    let width: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(DotSelectMetrics.titleFont)
                .foregroundStyle(DotTheme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(DotType.font(9, .semibold))
                .foregroundStyle(DotTheme.ink3)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: DotSelectMetrics.height)
        .background(
            RoundedRectangle(cornerRadius: DotSelectMetrics.corner, style: .continuous)
                .fill(DotTheme.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DotSelectMetrics.corner, style: .continuous)
                .strokeBorder(DotTheme.fieldBorder, lineWidth: 1)
        )
    }
}
