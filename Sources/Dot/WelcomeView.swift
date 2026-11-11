import AppKit
import DotCore
import SwiftUI

/// Which screen of the welcome the person is looking at.
enum WelcomeStage {
    case tour
    case setup
}

/// The first-run welcome: a short animated tour, then three things to set.
///
/// The view owns no window and touches nothing itself: the microphone, the
/// Keychain and the configuration all go back through callbacks.
@MainActor
struct WelcomeView: View {
    let presets: [ProviderPreset]
    let selectedPresetID: String?
    let providerReady: Bool
    let microphoneStatus: String
    let accessibilityGranted: Bool
    let shortcutLabel: String
    /// How the record shortcut starts and ends a recording. The tour teaches
    /// this and nothing else, so it is the person's chosen mode, not the
    /// shipped one.
    let recordingMode: RecordingMode
    let onEnableMicrophone: () async -> String
    let onChangeShortcut: () -> Void
    let onOpenSettings: () -> Void
    let onConnect: (ProviderPreset, String) async -> ProviderConnectionResult
    let onFinish: () -> Void
    var animated = true
    var previewConnection: ProviderConnectionResult?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage: WelcomeStage
    @State private var tourStep: TourStep
    private let tourPhase: Double
    @State private var microphone: String?
    @State private var enabling = false
    @State private var apiKey = ""
    @State private var chosenPresetID: String?
    @State private var connecting = false
    @State private var connection: ProviderConnectionResult?
    @FocusState private var keyFocused: Bool

    init(
        presets: [ProviderPreset] = ProviderPreset.all,
        selectedPresetID: String? = nil,
        providerReady: Bool,
        microphoneStatus: String,
        accessibilityGranted: Bool,
        shortcutLabel: String,
        recordingMode: RecordingMode = .toggle,
        onEnableMicrophone: @escaping () async -> String,
        onChangeShortcut: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onConnect: @escaping (ProviderPreset, String) async -> ProviderConnectionResult = { _, _ in
            ProviderConnectionResult(
                status: .failed,
                message: "Connecting is not available in a preview.",
                providerName: "Dot"
            )
        },
        onFinish: @escaping () -> Void,
        stage: WelcomeStage = .tour,
        tourStep: TourStep = .hold,
        tourPhase: Double = TourFrame.stillPhase,
        animated: Bool = true,
        previewConnection: ProviderConnectionResult? = nil,
    ) {
        self.presets = presets
        self.selectedPresetID = selectedPresetID
        self.providerReady = providerReady
        self.microphoneStatus = microphoneStatus
        self.accessibilityGranted = accessibilityGranted
        self.shortcutLabel = shortcutLabel
        self.recordingMode = recordingMode
        self.onEnableMicrophone = onEnableMicrophone
        self.onChangeShortcut = onChangeShortcut
        self.onOpenSettings = onOpenSettings
        self.onConnect = onConnect
        self.onFinish = onFinish
        self.tourPhase = tourPhase
        self.animated = animated
        self.previewConnection = previewConnection
        _connection = State(initialValue: previewConnection)
        _chosenPresetID = State(initialValue: selectedPresetID)
        _stage = State(initialValue: stage)
        _tourStep = State(initialValue: tourStep)
    }

    var body: some View {
        ZStack {
            switch stage {
            case .tour:
                WelcomeTourPage(
                    step: tourStep,
                    shortcutLabel: shortcutLabel,
                    recordingMode: recordingMode,
                    animated: animated,
                    phase: tourPhase,
                    onBack: { move(by: -1) },
                    onNext: { move(by: 1) },
                    onSkip: { showSetup() }
                )
                .transition(.opacity)
            case .setup:
                setupPage
                    .transition(.opacity.combined(with: .offset(x: 16)))
            }
        }
        .frame(width: 720, height: 560)
        .background(DotPaper())
    }

    private var transition: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.35, dampingFraction: 0.88)
    }

    private func move(by offset: Int) {
        guard let target = TourStep(rawValue: tourStep.rawValue + offset) else {
            showSetup()
            return
        }
        withAnimation(transition) { tourStep = target }
    }

    private func showSetup() {
        withAnimation(transition) { stage = .setup }
    }

    // MARK: - Setup

    private var setupPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 36)

            // The shipped mark, drawn from the same dial the icon and the About
            // window are drawn from. The bitmap path this used to take fell
            // back to the running application's icon, which in a bare binary is
            // the generic macOS application icon: a blue folder on the first
            // screen of a paid app.
            DotMarkDialPresentation(dial: DotMark.chosenDial ?? .clipped, size: 56)
                .accessibilityHidden(true)

            Text(ProductLinks.tagline)
                .font(DotTheme.displayFont(27))
                .tracking(-0.5)
                .foregroundStyle(DotTheme.ink)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                serviceRow
                divider
                microphoneRow
                divider
                shortcutRow
            }
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DotTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
                    )
            )
            .frame(width: 520)
            .padding(.top, 30)

            Spacer(minLength: 24)

            HStack {
                Button("Back") {
                    withAnimation(transition) { stage = .tour }
                }
                .buttonStyle(DotSecondaryButtonStyle())

                Spacer()

                Button("Finish") { onFinish() }
                    .buttonStyle(DotPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 26)
        }
    }

    private var divider: some View {
        Rectangle().fill(DotTheme.hairline).frame(height: 1)
    }

    private func row<Trailing: View>(
        _ symbol: String,
        _ title: String,
        done: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            // A finished row is marked with a filled check in the same neutral
            // ink as the symbol it replaces: the step is complete, it is not a
            // success message, and the pale mint check read as a disabled
            // button next to the black labels.
            Image(systemName: done ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(done ? DotTheme.ink : DotTheme.ink2)
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(DotTheme.ink)
            Spacer(minLength: 12)
            trailing()
        }
        .frame(minHeight: 58)
    }

    // Service

    private var chosenPreset: ProviderPreset? {
        chosenPresetID.flatMap { id in presets.first { $0.id == id } }
    }

    private var serviceConnected: Bool {
        if let connection { return connection.status == .connected }
        return providerReady && chosenPresetID == selectedPresetID && chosenPresetID != nil
    }

    private var needsKey: Bool {
        guard let chosenPreset else { return false }
        return chosenPreset.key != .none && !serviceConnected
    }

    private var serviceRow: some View {
        VStack(spacing: 0) {
            row("waveform", "Service", done: serviceConnected) {
                DotSelect(
                    label: "Service",
                    options: presets.map { DotSelectOption(value: $0.id, title: $0.name, symbol: $0.symbol) },
                    selection: Binding(
                        get: { chosenPresetID },
                        set: { value in
                            chosenPresetID = value
                            connection = nil
                            apiKey = ""
                            if let preset = presets.first(where: { $0.id == value }), preset.key == .none {
                                connect()
                            }
                        }
                    ),
                    placeholder: "Choose a service",
                    width: 200
                )
            }

            if needsKey {
                HStack(spacing: 8) {
                    SecureField("API key", text: $apiKey)
                        .modifier(DotFieldStyle(focused: keyFocused))
                        .focused($keyFocused)
                        .onSubmit { connect() }
                        .accessibilityHint("Stored in the macOS Keychain.")
                    Button(connecting ? "…" : "Connect") { connect() }
                        .buttonStyle(DotPrimaryButtonStyle())
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connecting)
                }
                .padding(.leading, 34)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let connection, connection.status == .failed {
                Text(connection.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DotTheme.coral)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 34)
                    .padding(.bottom, 12)
            }
        }
        .animation(transition, value: needsKey)
    }

    private func connect() {
        guard let preset = chosenPreset, !connecting else { return }
        let secret = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if preset.key == .required && secret.isEmpty { return }
        keyFocused = false
        connecting = true
        Task { @MainActor in
            let result = await onConnect(preset, secret)
            withAnimation(transition) {
                connection = result
                connecting = false
                apiKey = ""
            }
            if result.status == .failed { keyFocused = true }
        }
    }

    // Microphone

    private var micAllowed: Bool {
        let value = (microphone ?? microphoneStatus).lowercased()
        return value.contains("authoriz") || value.contains("allow") || value.contains("grant")
    }

    private var micDenied: Bool {
        let value = (microphone ?? microphoneStatus).lowercased()
        return value.contains("denied") || value.contains("restrict")
    }

    private var microphoneRow: some View {
        row("mic", "Microphone", done: micAllowed) {
            if micAllowed {
                EmptyView()
            } else if micDenied {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(DotSecondaryButtonStyle())
            } else {
                Button(enabling ? "…" : "Allow") {
                    guard !enabling else { return }
                    enabling = true
                    Task { @MainActor in
                        let status = await onEnableMicrophone()
                        withAnimation(transition) {
                            microphone = status
                            enabling = false
                        }
                    }
                }
                .buttonStyle(DotSecondaryButtonStyle())
            }
        }
    }

    // Shortcut

    private var shortcutRow: some View {
        row("command", "Shortcut", done: false) {
            Button { onChangeShortcut() } label: {
                DotKeycap(text: shortcutLabel)
            }
            .buttonStyle(.plain)
            .help("Change shortcut")
            .accessibilityLabel("Shortcut \(shortcutLabel). Change.")
        }
    }
}
