import AppKit
import DotCore
import SwiftUI

/// The Voices page: which voice reads an answer, and how fast.
///
/// The voice is a separate choice from the dictation engine, so the page owns
/// its own service, its own key and its own speed. A vendor that does both
/// directions uses one Keychain item, which is why the key row is the same row
/// the Provider page draws.
@MainActor
struct VoicesPage: View {
    @Binding var config: DotConfig
    let onChange: () -> Void
    let onSetKey: (String, String) -> String?
    let onDeleteKey: (String) -> String?

    @Environment(\.assistantKeyedProviders) private var keyedProviders
    @Environment(\.settingsVoiceOptions) private var previewVoices

    @State private var storedKeys: Set<String>?
    @State private var keyField = ""
    @State private var connecting = false
    @State private var note: KeyNote?
    @State private var loadedVoices: [VoiceDescriptor] = []
    @State private var player: SpeechPlayer?
    @State private var speechNote: String?
    @State private var liveSpeed: Double?

    /// What the Preview button says.
    static let previewSentence = "This is how answers will sound."

    /// The words the picker uses for the voice that is already on the machine.
    private static let appleTitle = "Apple (on this Mac)"

    var body: some View {
        SettingsSection("Voice") {
            SettingsRow("Service") {
                DotSelect(
                    label: "Service",
                    options: serviceOptions,
                    selection: serviceBinding,
                    placeholder: "Choose a service",
                    width: 220
                )
            }
            if needsKey {
                SettingsDivider()
                AssistantKeyRow(
                    field: $keyField,
                    hasStoredKey: hasKey(providerID),
                    isConnecting: connecting,
                    onConnect: connect,
                    onDelete: deleteKey,
                    subtitle: note?.detail,
                    subtitleTone: note?.tone.color ?? DotTheme.ink3
                )
            }
            SettingsDivider()
            SettingsRow("Voice") {
                DotSelect(
                    label: "Voice",
                    options: voices.map { voice in
                        DotSelectOption(value: voice.id, title: voice.name, detail: voice.detail)
                    },
                    selection: voiceBinding,
                    placeholder: "No voice",
                    width: 220,
                    isEnabled: !voices.isEmpty
                )
            }
            SettingsDivider()
            SettingsRow("Speed", subtitle: speechNote) {
                HStack(spacing: 12) {
                    VoiceSpeedSlider(
                        value: speedBinding,
                        range: VoiceSettings.speedRange,
                        step: 0.1,
                        onCommit: commitSpeed
                    )
                    .frame(width: 155)

                    Text(speedLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(DotTheme.ink2)
                        .frame(width: 44, alignment: .trailing)

                    Button("Preview", action: preview)
                        .buttonStyle(DotSecondaryButtonStyle())
                        .accessibilityHint("Speaks a sentence with the chosen voice.")
                }
            }
        }
        .onAppear(perform: readStoredKeys)
        .task(id: providerID) { await loadVoices() }
        .onDisappear { player?.teardown() }
    }

    // MARK: - Service

    private var providerID: String {
        VoicePresets.preset(id: config.assistant.voice.providerID)?.id ?? VoiceProviderID.apple
    }

    private var needsKey: Bool {
        VoicePresets.preset(id: providerID)?.requiresCredential ?? false
    }

    private var serviceOptions: [DotSelectOption<String>] {
        VoicePresets.all.map { preset in
            DotSelectOption(
                value: preset.id,
                title: preset.id == VoiceProviderID.apple ? Self.appleTitle : preset.displayName
            )
        }
    }

    private var serviceBinding: Binding<String> {
        Binding(
            get: { providerID },
            set: { id in
                guard providerID != id else { return }
                config.assistant.voice.providerID = id
                // A voice id belongs to the vendor that issued it.
                config.assistant.voice.voiceID = nil
                config.assistant.voice.model = nil
                note = nil
                keyField = ""
                speechNote = nil
                onChange()
            }
        )
    }

    // MARK: - Voice

    /// The voices the picker lists: the ones a render was given, otherwise the
    /// ones the provider answered with.
    private var voices: [VoiceDescriptor] {
        previewVoices ?? loadedVoices
    }

    /// The voice the provider will use: the one chosen, or the best the
    /// catalogue offers, which is what the provider resolves to on its own.
    private var selectedVoice: String? {
        if let id = config.assistant.voice.voiceID, voices.contains(where: { $0.id == id }) {
            return id
        }
        return voices.first?.id
    }

    private var voiceBinding: Binding<String?> {
        Binding(
            get: { selectedVoice },
            set: { value in
                guard let value, config.assistant.voice.voiceID != value else { return }
                config.assistant.voice.voiceID = value
                onChange()
            }
        )
    }

    private func loadVoices() async {
        guard previewVoices == nil else { return }
        let id = providerID
        let key: String? = id == VoiceProviderID.apple
            ? nil
            : await AssistantCredentials.resolvedKey(for: id)
        guard let provider = VoiceProviderFactory.make(providerID: id, apiKey: key) else {
            loadedVoices = []
            return
        }
        let catalogue = (try? await provider.voices(language: nil)) ?? []
        guard !Task.isCancelled else { return }
        loadedVoices = catalogue
    }

    // MARK: - Speed

    private var speed: Double {
        liveSpeed ?? config.assistant.voice.effectiveSpeed
    }

    private var speedLabel: String {
        String(format: "%.1fx", speed)
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { speed },
            set: { value in
                liveSpeed = min(max(value, VoiceSettings.speedRange.lowerBound), VoiceSettings.speedRange.upperBound)
            }
        )
    }

    private func commitSpeed() {
        let value = (speed * 10).rounded() / 10
        liveSpeed = nil
        guard abs(config.assistant.voice.speed - value) > 0.001 else { return }
        config.assistant.voice.speed = value
        onChange()
    }

    // MARK: - Preview

    /// Speaks one sentence with the chosen voice.
    ///
    /// The player and the output engine are built on the press and released
    /// when the page goes away, so a Mac that never asks for a preview never
    /// pays for an audio graph.
    private func preview() {
        let settings = config.assistant.voice
        if player == nil {
            player = SpeechPlayer()
        }
        guard let player else { return }
        player.stop()
        speechNote = nil
        player.onFailure = { error in
            speechNote = ProviderErrorText.sanitized(error.localizedDescription)
        }
        Task { @MainActor in
            let id = providerID
            let key: String? = id == VoiceProviderID.apple
                ? nil
                : await AssistantCredentials.resolvedKey(for: id)
            guard let provider = VoiceProviderFactory.make(providerID: id, apiKey: key) else { return }
            player.speak(Self.previewSentence, provider: provider, settings: settings)
        }
    }

    // MARK: - Keys

    private func hasKey(_ id: String) -> Bool {
        (storedKeys ?? keyedProviders ?? []).contains(id)
    }

    private func readStoredKeys() {
        guard storedKeys == nil else { return }
        if let keyedProviders {
            storedKeys = keyedProviders
            return
        }
        storedKeys = Set(VoicePresets.all.map(\.id).filter { VoiceProviderFactory.hasKey(providerID: $0) })
    }

    private var trimmedKey: String {
        keyField.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        guard !connecting, !trimmedKey.isEmpty else { return }
        let id = providerID
        connecting = true
        note = nil
        defer { connecting = false }
        if let message = onSetKey(trimmedKey, id) {
            note = KeyNote(detail: message, tone: .bad)
            return
        }
        storedKeys = (storedKeys ?? keyedProviders ?? []).union([id])
        keyField = ""
        note = KeyNote(detail: nil, tone: .good)
        onChange()
    }

    private func deleteKey() {
        let id = providerID
        if let message = onDeleteKey(id) {
            note = KeyNote(detail: message, tone: .bad)
            return
        }
        storedKeys = (storedKeys ?? keyedProviders ?? []).subtracting([id])
        keyField = ""
        note = KeyNote(detail: nil, tone: .neutral)
        onChange()
    }
}

/// The speed control: the green track and the porcelain knob of the app's own
/// switch family, with the value beside it.
private struct VoiceSpeedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onCommit: () -> Void

    @State private var isDragging = false

    private var thumb: CGFloat { 15 }

    private var progress: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// Writes through and commits, so the accessibility slider reaches the
    /// configuration the same way a drag does.
    private var committed: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                value = newValue
                onCommit()
            }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let usable = max(1, proxy.size.width - thumb)
            let offset = CGFloat(progress) * usable

            ZStack(alignment: .leading) {
                Capsule(style: .circular)
                    .fill(DotTheme.sliderTrack)
                    .overlay(
                        Capsule(style: .circular)
                            .strokeBorder(DotTheme.switchOffEdge, lineWidth: 0.5)
                    )
                    .frame(height: 5)

                Capsule(style: .circular)
                    .fill(
                        LinearGradient(
                            colors: [DotTheme.switchOnTop, DotTheme.switchOn],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: max(thumb / 2, offset + thumb / 2), height: 5)

                Circle()
                    .fill(DotTheme.switchKnob)
                    .shadow(color: DotTheme.switchKnobShadow, radius: 2, x: 0, y: 1)
                    .frame(width: thumb, height: thumb)
                    .scaleEffect(isDragging ? 1.12 : 1)
                    .offset(x: offset)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let location = max(0, min(usable, gesture.location.x - thumb / 2))
                        let raw = range.lowerBound
                            + Double(location / usable) * (range.upperBound - range.lowerBound)
                        let stepped = (raw / step).rounded() * step
                        value = min(max(stepped, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onCommit()
                    }
            )
        }
        .frame(height: 20)
        .accessibilityRepresentation {
            Slider(value: committed, in: range, step: step)
        }
    }
}
