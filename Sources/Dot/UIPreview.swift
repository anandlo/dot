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

        try renderAboutMarkSamples(to: directory)
        try renderAssistantSettings(to: directory, providers: providers)
    }

    /// Renders settled mark states from one mounted host, then two control
    /// fills. No synthetic system pointer is moved.
    ///
    /// The target phases all run through one `AboutPage` and one `NSHostingView`.
    /// They are settled state captures, not interpolated spring frames. The
    /// renderer has no way to pulse the live spring without a real pointer, so
    /// the log says `state-settled` and does not claim return animation proof.
    static func renderAboutMarkSamples(to directory: URL) throws {
        let size = CGSize(width: 565, height: 600)
        var lines: [String] = []
        let phases: [(name: String, point: CGPoint?)] = [
            ("about-mark-rest", nil),
            ("about-mark-engaged", CGPoint(x: 100, y: 20)),
            ("about-mark-retarget", CGPoint(x: 500, y: 28)),
            ("about-mark-exit-settled", nil),
            ("about-mark-return-settled", nil),
        ]

        for phase in phases {
            let box = AboutMarkSampleBox()
            let input = AboutMotionInput(pointer: phase.point)
            let hosting = NSHostingView(
                rootView: AboutPage(
                    version: "1.0",
                    build: "1",
                    previewUpdate: .upToDate,
                    onLayout: { box.frames = $0.frames },
                    previewMotion: input
                )
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .light)
                .environment(\.displayScale, 2)
            )
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.appearance = NSAppearance(named: .aqua)
            settleMotionHost(hosting)
            let bitmap = try hostedBitmap(hosting, size: size)
            try write(bitmap, to: directory.appendingPathComponent("\(phase.name).png"))

            let plate = box.frames["plate"] ?? .zero
            let disc = box.frames["disc"] ?? .zero
            let actual = renderedDiscFrame(in: bitmap) ?? disc
            let region = box.frames["markRegion"] ?? .zero
            let pointerText = phase.point.map { "\($0.x) \($0.y)" } ?? "none"
            let patchPoint = phase.point ?? CGPoint(x: 300, y: 68)
            let patch = pixel(patchPoint, in: bitmap)
            let far = pixel(CGPoint(x: 300, y: 68), in: bitmap)
            lines.append(
                "\(phase.name) kind=state-settled pointer \(pointerText) "
                    + "plate \(plate.origin.x) \(plate.origin.y) \(plate.size.width) \(plate.size.height) "
                    + "disc \(disc.origin.x) \(disc.origin.y) \(disc.size.width) \(disc.size.height) "
                    + "actual \(actual.origin.x) \(actual.origin.y) \(actual.size.width) \(actual.size.height) "
                    + "region \(region.origin.x) \(region.origin.y) \(region.size.width) \(region.size.height) "
                    + "patch \(patch.0) \(patch.1) \(patch.2) "
                    + "far \(far.0) \(far.1) \(far.2)"
            )
        }

        for state in [
            (name: "about-control-rest", update: AboutUpdateState.upToDate, highlighted: false),
            (name: "about-control-enabled-highlight", update: AboutUpdateState.upToDate, highlighted: true),
            (name: "about-control-disabled-highlight", update: AboutUpdateState.checking, highlighted: true),
        ] {
            let controlBox = AboutMarkSampleBox()
            let controlPage = AboutPage(
                version: "1.0",
                build: "1",
                previewUpdate: state.update,
                onLayout: { controlBox.frames = $0.frames },
                previewControlHighlighted: state.highlighted
            )
            try writeHosted(
                controlPage.frame(width: size.width, height: size.height),
                size: size,
                scheme: .light,
                to: directory.appendingPathComponent("\(state.name).png")
            )
            let control = controlBox.frames["control"] ?? .zero
            let bitmap = try bitmap(at: directory.appendingPathComponent("\(state.name).png"))
            let sample = CGPoint(x: control.minX + 8, y: control.midY)
            let fill = pixel(sample, in: bitmap)
            lines.append(
                "\(state.name) kind=control-state "
                    + "control \(control.origin.x) \(control.origin.y) "
                    + "\(control.size.width) \(control.size.height) "
                    + "fill \(fill.0) \(fill.1) \(fill.2)"
            )
        }

        try lines.joined(separator: "\n").appending("\n").write(
            to: directory.appendingPathComponent("about-mark-frames.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func hostedBitmap(
        _ hosting: NSHostingView<some View>,
        size: CGSize
    ) throws -> NSBitmapImageRep {
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
        ) else { throw RenderError.couldNotRender }
        bitmap.size = size
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        return bitmap
    }

    private static func bitmap(at url: URL) throws -> NSBitmapImageRep {
        let data = try Data(contentsOf: url)
        guard let bitmap = NSBitmapImageRep(data: data) else { throw RenderError.couldNotRender }
        return bitmap
    }

    private static func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.couldNotEncode
        }
        try data.write(to: url, options: .atomic)
    }

    /// Finds the disc in the rendered pixels instead of trusting the layout
    /// frame. Offscreen hosting does not drive the live spring presentation,
    /// so the drawn disc can remain at its printed position while the target
    /// frame moves. This returns the frame the pixels actually show.
    private static func renderedDiscFrame(in bitmap: NSBitmapImageRep) -> CGRect? {
        let resolved = NSColor(AboutDialInk.disc).usingColorSpace(.sRGB) ?? NSColor.white
        let ink = (
            Int((resolved.redComponent * 255).rounded()),
            Int((resolved.greenComponent * 255).rounded()),
            Int((resolved.blueComponent * 255).rounded())
        )
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min
        let xLimit = min(1_159, bitmap.pixelsWide - 1)
        let yLimit = min(139, bitmap.pixelsHigh - 1)
        for y in 0...yLimit {
            for x in 980...xLimit {
                let sample = pixel(CGPoint(x: Double(x) / 2, y: Double(y) / 2), in: bitmap)
                guard abs(sample.0 - ink.0) <= 4,
                      abs(sample.1 - ink.1) <= 4,
                      abs(sample.2 - ink.2) <= 4
                else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard minX != Int.max else { return nil }
        return CGRect(
            x: Double(minX) / 2,
            y: Double(minY) / 2,
            width: Double(maxX - minX + 1) / 2,
            height: Double(maxY - minY + 1) / 2
        )
    }

    private static func pixel(_ point: CGPoint, in bitmap: NSBitmapImageRep) -> (Int, Int, Int) {
        let x = Int((point.x * 2).rounded())
        let y = Int((point.y * 2).rounded())
        guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (
            Int((colour.redComponent * 255).rounded()),
            Int((colour.greenComponent * 255).rounded()),
            Int((colour.blueComponent * 255).rounded())
        )
    }

    /// Renders the General page before any take has taught the microphone.
    ///
    /// The calibration row is present with no profile, so its Reset control
    /// is disabled and its tooltip says nothing was learned yet.
    static func renderSettingsWithoutProfile(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let providers = MenuBuilder.providerRows(config: .default) { _ in false }
        let size = CGSize(width: 820, height: 1180)
        for scheme in [ColorScheme.light, .dark] {
            var config = DotConfig.default
            config.appearance = appearance(for: scheme)
            let settings = settingsPreview(
                config: config,
                providers: providers,
                tab: 0,
                height: size.height
            )
            let name = scheme == .dark
                ? "settings-general-no-profile-dark.png"
                : "settings-general-no-profile.png"
            try writeHosted(
                WindowPreview(size: size) { settings },
                size: size,
                scheme: scheme,
                to: directory.appendingPathComponent(name)
            )
        }
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


    // MARK: - About motion study

    /// The argument that renders the About motion study and exits.
    static let motionArgument = "--render-about-motion"

    /// The directory the motion study was asked for, if any.
    static func requestedMotionDirectory(
        arguments: [String] = CommandLine.arguments
    ) -> URL? {
        if let index = arguments.firstIndex(of: motionArgument), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return nil
    }

    /// One sampled frame of a contact sheet.
    private struct MotionSample {
        let label: String
        let input: AboutMotionInput
        let update: AboutUpdateState
    }

    /// Renders the matrix: a settled frame and its layout, four contact sheets,
    /// a real-speed clip with and without reduced motion, and a clip of the
    /// interruptions.
    ///
    /// Every frame is one offscreen host injected with a sampled input, never a
    /// live spring and never a sleep. The hosts are the page alone in a scroll
    /// view at 565 points wide, which is the width and the geometry the real
    /// settings window gives it.
    static func renderAboutMotionStudy(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeMotionSettled(to: directory)
        try writeMotionEntranceSheet(to: directory)
        try writeMotionPointerSheet(to: directory)
        try writeMotionUpdateSheet(to: directory)
        try writeMotionRowsSheet(to: directory)
        try writeMotionClip(reduceMotion: false, interrupt: false, to: directory)
        try writeMotionClip(reduceMotion: true, interrupt: false, to: directory)
        try writeMotionClip(reduceMotion: false, interrupt: true, to: directory)
    }

    /// The settled frame and the layout frames it was measured at.
    private static func writeMotionSettled(to directory: URL) throws {
        let size = CGSize(width: 565, height: 600)
        var frames: [String: CGRect] = [:]
        try autoreleasepool {
            let hosting = motionHost(
                input: AboutMotionInput(),
                update: .idle,
                size: size,
                onLayout: { frames = $0.frames }
            )
            let bitmap = try hostedBitmap(hosting, size: size)
            try write(
                bitmap,
                to: directory.appendingPathComponent("about-settled-matrix.png")
            )
        }
        let lines = frames.keys.sorted().map { key -> String in
            let frame = frames[key] ?? .zero
            return String(
                format: "%@ %.2f %.2f %.2f %.2f",
                key,
                frame.origin.x,
                frame.origin.y,
                frame.size.width,
                frame.size.height
            )
        }
        try lines.joined(separator: "\n").appending("\n").write(
            to: directory.appendingPathComponent("layout-frames-after-matrix.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writeMotionEntranceSheet(to directory: URL) throws {
        let labels = ["0 ms", "83 ms", "167 ms", "283 ms", "467 ms", "633 ms", "settled"]
        let elapsed: [Double?] = [0, 83, 167, 283, 467, 633, nil]
        let samples = zip(labels, elapsed).map { pair in
            MotionSample(
                label: pair.0,
                input: AboutMotionInput(entranceElapsed: pair.1),
                update: .idle
            )
        }
        try writeMotionSheet(
            title: "matrix",
            samples: samples,
            frameSize: CGSize(width: 565, height: 260),
            to: directory.appendingPathComponent("matrix-entrance.png")
        )
    }

    private static func writeMotionPointerSheet(to directory: URL) throws {
        let points: [(String, CGPoint?)] = [
            ("no pointer", nil),
            ("40, 40", CGPoint(x: 40, y: 40)),
            ("282, 36", CGPoint(x: 282, y: 36)),
            ("475, 30", CGPoint(x: 475, y: 30)),
            ("525, 90", CGPoint(x: 525, y: 90)),
        ]
        let samples = points.map { pair in
            MotionSample(
                label: pair.0,
                input: AboutMotionInput(pointer: pair.1),
                update: .idle
            )
        }
        try writeMotionSheet(
            title: "matrix",
            samples: samples,
            frameSize: CGSize(width: 565, height: 260),
            to: directory.appendingPathComponent("matrix-pointer.png")
        )
    }

    private static func writeMotionUpdateSheet(to directory: URL) throws {
        let checking: [Double] = [0, 140, 280, 420, 560, 800]
        var samples = checking.map { elapsed in
            MotionSample(
                label: "checking \(Int(elapsed))",
                input: AboutMotionInput(update: .checking(elapsed: elapsed)),
                update: .checking
            )
        }
        samples.append(
            MotionSample(
                label: "upToDate 100",
                input: AboutMotionInput(
                    update: .upToDate(elapsed: 100, frontsElapsed: nil)
                ),
                update: .upToDate
            )
        )
        samples.append(
            MotionSample(
                label: "upToDate 400",
                input: AboutMotionInput(
                    update: .upToDate(elapsed: 400, frontsElapsed: nil)
                ),
                update: .upToDate
            )
        )
        samples.append(
            MotionSample(
                label: "available 400",
                input: AboutMotionInput(
                    update: .available(elapsed: 400, frontsElapsed: nil)
                ),
                update: .available(version: "9.9.0", page: nil)
            )
        )
        samples.append(
            MotionSample(
                label: "unreachable 60",
                input: AboutMotionInput(
                    // A front 60 ms old is still beside the disc, clear of the
                    // control and status knockouts, so the half-faded fronts
                    // are visible in the frame.
                    update: .unreachable(elapsed: 60, frontsElapsed: 60)
                ),
                update: .unreachable
            )
        )
        try writeMotionSheet(
            title: "matrix",
            samples: samples,
            frameSize: CGSize(width: 565, height: 260),
            to: directory.appendingPathComponent("matrix-update.png")
        )
    }

    private static func writeMotionRowsSheet(to directory: URL) throws {
        let rows: [Int] = [0, 1, 2, 3, 4, 5, 6]
        var samples = rows.map { row in
            MotionSample(
                label: "row \(row)",
                input: AboutMotionInput(engagedRow: row),
                update: .idle
            )
        }
        samples.append(
            MotionSample(
                label: "focus update",
                input: AboutMotionInput(focusedControl: .update),
                update: .idle
            )
        )
        samples.append(
            MotionSample(
                label: "focus copy",
                input: AboutMotionInput(focusedControl: .copy),
                update: .idle
            )
        )
        try writeMotionSheet(
            title: "matrix",
            samples: samples,
            frameSize: CGSize(width: 565, height: 600),
            to: directory.appendingPathComponent("matrix-rows.png")
        )
    }

    /// Renders the samples at full size and lays them out three to a row with a
    /// label under each.
    ///
    /// The frames are drawn at the bitmap's own pixels, so a contact sheet is
    /// read at 100 percent rather than half size.
    private static func writeMotionSheet(
        title: String,
        samples: [MotionSample],
        frameSize: CGSize,
        to url: URL
    ) throws {
        let framePixels = CGSize(width: frameSize.width * 2, height: frameSize.height * 2)
        var frames: [(label: String, image: NSImage)] = []
        for sample in samples {
            let image = try autoreleasepool { () -> NSImage in
                let hosting = motionHost(
                    input: sample.input,
                    update: sample.update,
                    size: frameSize
                )
                let bitmap = try hostedBitmap(hosting, size: frameSize)
                let image = NSImage(size: frameSize)
                image.addRepresentation(bitmap)
                return image
            }
            frames.append((sample.label, image))
        }

        let columns = min(3, frames.count)
        let rows = (frames.count + columns - 1) / max(columns, 1)
        let margin: CGFloat = 24
        let gap: CGFloat = 20
        let rowGap: CGFloat = 18
        let titleHeight: CGFloat = 56
        let labelHeight: CGFloat = 28
        let width = margin * 2
            + CGFloat(columns) * framePixels.width
            + CGFloat(max(columns - 1, 0)) * gap
        let height = margin * 2
            + titleHeight
            + CGFloat(rows) * (framePixels.height + labelHeight)
            + CGFloat(max(rows - 1, 0)) * rowGap
        guard let sheet = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width),
            pixelsHigh: Int(height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: sheet) else {
            throw RenderError.couldNotRender
        }
        sheet.size = CGSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        NSString(string: title).draw(
            at: NSPoint(x: margin, y: height - margin - 34),
            withAttributes: [
                .font: DotType.nsFont(30, .semibold),
                .foregroundColor: NSColor.black,
            ]
        )
        let contentTop = height - margin - titleHeight
        for (index, frame) in frames.enumerated() {
            let row = index / columns
            let column = index % columns
            let x = margin + CGFloat(column) * (framePixels.width + gap)
            let rowTop = contentTop
                - CGFloat(row) * (framePixels.height + labelHeight + rowGap)
            let rect = CGRect(
                x: x,
                y: rowTop - framePixels.height,
                width: framePixels.width,
                height: framePixels.height
            )
            frame.image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            NSColor(white: 0.78, alpha: 1).setStroke()
            NSBezierPath(rect: rect).stroke()
            NSString(string: frame.label).draw(
                at: NSPoint(x: x, y: rowTop - framePixels.height - labelHeight + 6),
                withAttributes: [
                    .font: DotType.nsFont(17, .regular),
                    .foregroundColor: NSColor(white: 0.22, alpha: 1),
                ]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = sheet.representation(using: .png, properties: [:]) else {
            throw RenderError.couldNotEncode
        }
        try data.write(to: url, options: .atomic)
    }

    /// The clip's clock and springs, stepped once per frame.
    ///
    /// A clip has no SwiftUI animation session, so the pointer spring is
    /// integrated here. Everything else is the model's own elapsed time: the
    /// entrance, the pointer exit fade, the row fill and dot fades, the
    /// checking fronts and the result that arrives mid-front.
    private struct MatrixClipDriver {
        let reduceMotion: Bool
        let interrupt: Bool
        var time: Double = 0
        var clock = AboutMotionClock()
        var engagedRow: Int?
        var engagedAt: Double?
        var releasedRow: Int?
        var releasedAt: Double?
        private var started = false

        init(reduceMotion: Bool, interrupt: Bool) {
            self.reduceMotion = reduceMotion
            self.interrupt = interrupt
        }

        static let plateCentre = CGPoint(x: 282.5, y: 59)
        static let pointerEntry = CGPoint(x: 12, y: 58)
        static let pointerNearDisc = CGPoint(x: 500, y: 30)

        mutating func advance(to time: Double) {
            self.time = time
            if !started {
                clock.entranceStartedAt = 0
                started = true
            }
            clock.reduceMotion = reduceMotion
            if interrupt {
                advanceInterrupt(to: time)
            } else {
                advanceNormal(to: time)
            }
        }

        /// The sampled frame, including the row engagement the clip drives by
        /// hand. The content groups and the matrix read the clock; the rows
        /// use this input because their engagement is not an event on the
        /// store.
        var contentInput: AboutMotionInput {
            var input = clock.input(at: time)
            input.engagedRow = engagedRow
            input.engagedElapsed = engagedAt.map { time - $0 }
            input.releasedRow = releasedRow
            input.releasedElapsed = releasedAt.map { time - $0 }
            input.reduceMotion = reduceMotion
            return input
        }

        private static func lerp(_ from: CGPoint, _ to: CGPoint, _ progress: Double) -> CGPoint {
            let p = AboutEasing.clamp(progress)
            return CGPoint(
                x: from.x + (to.x - from.x) * p,
                y: from.y + (to.y - from.y) * p
            )
        }

        private mutating func advanceNormal(to time: Double) {
            if time >= 2500 {
                if let pointer = clock.pointer, pointer.amplitudeTo > 0 {
                    clock.pointer?.exit(at: time)
                }
            } else if time >= 1300 {
                let target: CGPoint
                if time < 1900 {
                    target = Self.lerp(
                        Self.pointerEntry,
                        Self.pointerNearDisc,
                        (time - 1300) / 600
                    )
                } else {
                    target = Self.lerp(
                        Self.pointerNearDisc,
                        Self.plateCentre,
                        (time - 1900) / 600
                    )
                }
                follow(target, at: time)
            }

            if time >= 2800, time < 4000 {
                setRow(min(4, Int((time - 2800) / 240)), at: time)
            } else if time >= 4000 {
                setRow(nil, at: time)
            }

            if time >= 5800 {
                clock.update = .upToDate(at: 5800, frontsElapsed: 1400)
            } else if time >= 4400 {
                clock.update = .checking(startedAt: 4400)
            }
        }

        private mutating func advanceInterrupt(to time: Double) {
            if time >= 200 {
                clock.entranceStartedAt = nil
            }
            if time >= 1250 {
                if let pointer = clock.pointer, pointer.amplitudeTo > 0 {
                    clock.pointer?.exit(at: time)
                }
            } else if time >= 1130 {
                let target = Self.lerp(
                    CGPoint(x: 120, y: 60),
                    CGPoint(x: 200, y: 40),
                    (time - 1130) / 120
                )
                follow(target, at: time)
            } else if time >= 1050 {
                if let pointer = clock.pointer, pointer.amplitudeTo > 0 {
                    clock.pointer?.exit(at: time)
                }
            } else if time >= 950 {
                follow(
                    Self.lerp(
                        CGPoint(x: 140, y: 50),
                        CGPoint(x: 480, y: 30),
                        (time - 950) / 100
                    ),
                    at: time
                )
            } else if time >= 800 {
                follow(
                    Self.lerp(
                        CGPoint(x: 80, y: 30),
                        CGPoint(x: 140, y: 50),
                        (time - 800) / 150
                    ),
                    at: time
                )
            }

            if time >= 2050 {
                clock.update = .unreachable(at: 2050, frontsElapsed: 250)
            } else if time >= 1800 {
                clock.update = .checking(startedAt: 1800)
            }
        }

        /// A move retargets the live pointer timeline from its presented
        /// position; a fresh entry starts there at full strength.
        private mutating func follow(_ target: CGPoint, at time: Double) {
            if clock.pointer == nil {
                clock.pointer = AboutPointerTimeline(point: target, at: time)
            } else {
                clock.pointer?.retarget(to: target, at: time)
            }
        }

        private mutating func setRow(_ row: Int?, at time: Double) {
            guard row != engagedRow else { return }
            if let previous = engagedRow {
                releasedRow = previous
                releasedAt = time
            }
            engagedRow = row
            engagedAt = row == nil ? nil : time
        }

        var updateState: AboutUpdateState {
            if interrupt {
                if time >= 1800, time < 2050 { return .checking }
                if time >= 2050 { return .unreachable }
                return .idle
            }
            if time >= 4400, time < 5800 { return .checking }
            if time >= 5800 { return .upToDate }
            return .idle
        }
    }

    /// Writes 420 frames at 60 frames per second, encodes them with H.264 and
    /// deletes the frames.
    private static func writeMotionClip(
        reduceMotion: Bool,
        interrupt: Bool,
        to directory: URL
    ) throws {
        let name = interrupt
            ? "matrix-clip-interrupt"
            : (reduceMotion ? "matrix-clip-reduced" : "matrix-clip")
        // Each invocation gets its own scratch directory. The renderer never
        // removes a predictable path in the caller's directory: only the
        // directory it just created is deleted.
        let frameDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-about-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: frameDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: frameDirectory) }

        let size = CGSize(width: 565, height: 380)
        let frameCount = interrupt ? 180 : 420
        var driver = MatrixClipDriver(reduceMotion: reduceMotion, interrupt: interrupt)
        for frame in 0..<frameCount {
            let time = Double(frame) / 60.0 * 1000.0
            driver.advance(to: time)
            let url = frameDirectory.appendingPathComponent(
                String(format: "frame-%04d.png", frame)
            )
            try autoreleasepool {
                let hosting = motionHost(
                    input: driver.contentInput,
                    update: driver.updateState,
                    clock: driver.clock,
                    frameTime: time,
                    size: size
                )
                let bitmap = try hostedBitmap(hosting, size: size)
                try write(bitmap, to: url)
            }
        }

        let output = directory.appendingPathComponent("\(name).mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-y",
            "-loglevel", "error",
            "-framerate", "60",
            "-i", frameDirectory.appendingPathComponent("frame-%04d.png").path,
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-crf", "18",
            "-preset", "medium",
            output.path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown encoder error"
            throw RenderError.encoderFailed(message)
        }
    }

    /// Measures the whole matrix leaf for consecutive clip frames.
    ///
    /// The timer wraps the leaf's Canvas closure: lattice evaluation, the
    /// pointer patch, the checking fronts, the packet and the disc, followed
    /// by their drawing. Layout and PNG encoding are outside it.
    static func measureMatrixDraw(frames: Int) throws -> [Double] {
        var driver = MatrixClipDriver(reduceMotion: false, interrupt: false)
        var durations: [Double] = []
        let size = CGSize(width: 565, height: 380)
        for frame in 0..<frames {
            let time = Double(frame) / 60.0 * 1000.0
            driver.advance(to: time)
            var sample: Double?
            try autoreleasepool {
                let hosting = motionHost(
                    input: driver.contentInput,
                    update: driver.updateState,
                    clock: driver.clock,
                    frameTime: time,
                    size: size,
                    onCanvasDraw: { sample = $0 }
                )
                _ = try hostedBitmap(hosting, size: size)
            }
            if let sample { durations.append(sample) }
        }
        return durations
    }

    /// One offscreen host for a sampled frame.
    ///
    /// The scroll view gives the page the same 565 points of width and the same
    /// content geometry the settings window gives it. The host is never placed
    /// in a window and never ordered front.
    private static func motionHost(
        input: AboutMotionInput?,
        update: AboutUpdateState,
        clock: AboutMotionClock? = nil,
        frameTime: Double? = nil,
        size: CGSize,
        onLayout: ((AboutLayoutSnapshot) -> Void)? = nil,
        onCanvasDraw: ((Double) -> Void)? = nil
    ) -> NSHostingView<AnyView> {
        let page = AboutPage(
            version: "1.0",
            build: "1",
            previewUpdate: update,
            onLayout: onLayout,
            previewMotion: input,
            previewClock: clock,
            previewTime: frameTime,
            onCanvasDraw: onCanvasDraw
        )
        let root = AnyView(
            ScrollView(.vertical) {
                page.frame(width: size.width)
            }
            .frame(width: size.width, height: size.height)
            .background(DotTheme.paper)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, 2)
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        settleMotionHost(hosting)
        return hosting
    }

    /// Pumps the layout until the page's preference readers have reported.
    ///
    /// The four knockout frames arrive through a preference after the first
    /// pass. Nothing here waits for an animation: the injected input is static,
    /// so the passes only carry a frame from one SwiftUI layout generation to
    /// the next.
    private static func settleMotionHost(_ hosting: NSView) {
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            hosting.layoutSubtreeIfNeeded()
        }
    }

    /// The render could not be made.
    enum RenderError: Error {
        case couldNotRender
        case couldNotEncode
        case encoderFailed(String)
    }
}

/// The frame reader for one offscreen mark sample.
@MainActor
private final class AboutMarkSampleBox {
    var frames: [String: CGRect] = [:]
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
