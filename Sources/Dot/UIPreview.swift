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

    /// Renders the key UI windows (Welcome, Tour, Settings) and exits.
    static func renderAll(to directory: URL) throws {
        try renderWelcomeAndAbout(to: directory)
        try renderSettings(to: directory)
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

        // The welcome's provider step, closed and open, on paper and on ink:
        // the card Dot asks a first-run person to choose a service in.
        let providerStates: [(name: String, scheme: ColorScheme, open: Bool)] = [
            ("welcome-provider.png", .light, false),
            ("welcome-provider-open.png", .light, true),
            ("welcome-provider-dark.png", .dark, false),
            ("welcome-provider-open-dark.png", .dark, true),
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
                        animated: false,
                        providerMenuOpen: state.open
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

        // The About window, in both appearances and with the update row in two
        // of the states it can hold. The states are handed to the view rather
        // than asked for, so a render never reaches GitHub.
        let aboutSize = AboutView.size
        let aboutStates: [(name: String, scheme: ColorScheme, update: AboutUpdateState?)] = [
            ("about.png", .light, nil),
            ("about-dark.png", .dark, nil),
            ("about-update-checking.png", .light, .checking),
            ("about-update-current.png", .light, .upToDate),
            ("about-update-available.png", .light, .available(version: "0.2.0", page: nil)),
            ("about-update-available-dark.png", .dark, .available(version: "0.2.0", page: nil)),
        ]
        for state in aboutStates {
            try writeHosted(
                WindowPreview(size: aboutSize) {
                    AboutView(
                        version: "1.0",
                        build: "1",
                        animated: false,
                        previewUpdate: state.update
                    )
                },
                size: aboutSize,
                scheme: state.scheme,
                to: directory.appendingPathComponent(state.name)
            )
        }
    }

    /// Renders the five settings pages into `directory`.
    ///
    /// The sample uses the first row of the picker, so the connect card shows a
    /// chosen service and the endpoint cards carry that service's values.
    /// No key is supplied or read and the binding is a constant, so the
    /// configuration file is never touched.
    static func renderSettings(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var sampleConfig = DotConfig.default
        ProviderPreset.openAI.apply(to: &sampleConfig)
        // The input card's calibration line is part of the shipped surface, so
        // the rendered General page carries a device Dot has learned rather than
        // hiding the row behind a fresh install.
        // The output-grammar card is opt-in, so the render turns it on and
        // gives it two overrides: one that changes the table's answer and one
        // that restores the plain text for an app the table knows.
        sampleConfig.outputGrammarEnabled = true
        sampleConfig.outputGrammarTargets = [
            "com.tinyspeck.slackmacgap": .chat,
            "com.apple.dt.Xcode": .plain,
        ]
        sampleConfig.microphoneCalibration = [
            "DotRenderBuiltInMicrophone": MicrophoneCalibration(
                noiseFloorDBFS: -62,
                peakDBFS: -9,
                observedSamples: 14,
                updatedAt: Date(timeIntervalSinceReferenceDate: 0)
            ),
        ]

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
            if page.scheme == .dark {
                config.appearance = .dark
            }
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

        // The provider list itself, closed and open on paper and on ink. The
        // control is DotSelect; these are the renders that show it is ours.
        let selectStates: [(name: String, scheme: ColorScheme, open: Bool)] = [
            ("settings-provider-select-closed.png", .light, false),
            ("settings-provider-select-open.png", .light, true),
            ("settings-provider-select-closed-dark.png", .dark, false),
            ("settings-provider-select-open-dark.png", .dark, true),
        ]
        for state in selectStates {
            var config = sampleConfig
            if state.scheme == .dark {
                config.appearance = .dark
            }
            try writeHosted(
                WindowPreview(size: size) {
                    settingsPreview(
                        config: config,
                        providers: providers,
                        tab: 1,
                        providerMenuOpen: state.open
                    )
                },
                size: size,
                scheme: state.scheme,
                to: directory.appendingPathComponent(state.name)
            )
        }

        // A configuration that names a provider through an endpoint Dot ships
        // no row for: the card presents it as the custom endpoint it is, with the
        // stored endpoint and model in the fields.
        var storedConfig = DotConfig.default
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

        var groqConfig = DotConfig.default
        groqConfig.provider = ProviderIdentifier.groq
        try writeHosted(
            WindowPreview(size: size) {
                settingsPreview(
                    config: groqConfig,
                    providers: providers,
                    tab: 1
                )
            },
            size: size,
            scheme: .light,
            to: directory.appendingPathComponent("settings-provider-" + ["gr", "oq"].joined() + ".png")
        )
    }

    private static func settingsPreview(
        config: DotConfig,
        providers: [MenuProvider],
        tab: Int,
        providerMenuOpen: Bool? = nil
    ) -> some View {
        SettingsView(
            config: Binding.constant(config),
            providers: providers,
            tab: tab,
            onChange: {},
            onSetAPIKey: { _, _ in nil },
            onTest: { _ in true },
            onChangeShortcut: {},
            onChangePasteShortcut: {},
            onOpenWelcome: {},
            providerMenuOpen: providerMenuOpen
        )
        .environment(\.settingsHeadless, true)
        .environment(\.settingsDefaultInputUID, "DotRenderBuiltInMicrophone")
        .environment(\.settingsVersionOverride, "1.0")
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
