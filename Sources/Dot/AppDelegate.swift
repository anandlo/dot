import AppKit
import AVFoundation
import Foundation
import DotCore
import SwiftUI

/// The application's coordinator.
///
/// It owns the menu bar item, the HUD, the recorder, the hot keys, the key
/// watcher and the provider, and it makes sure the app never takes focus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = DotConfig.default
    /// The appearance that is already in force.
    ///
    /// Setting `NSApp.appearance` invalidates every view in the app, so it is
    /// only written when the choice really moved. It used to be written on
    /// every configuration change, which made a text field feel like it was
    /// dragging the whole app behind it.
    private var appliedAppearance: AppearanceMode?
    /// The material last shown as a preview, so a re-render cannot re-show it.
    private var previewedMaterial: HUDMaterial?
    /// The visualizer last shown as a preview, so a re-render cannot re-show it.
    private var previewedVisualizer: HUDVisualizer?
    /// The interaction last reported, so the log names a switch and not a redraw.
    private var appliedRecordingMode: RecordingMode?
    /// Keeps the app out of App Nap, which would delay the hotkey.
    private var activity: NSObjectProtocol?
    /// Times a press from the mouse to the moment this app hears about it.
    private let inputLatency = InputLatency()
    /// When the last configuration change left a control.
    ///
    /// It is the click, as far as the model can see it: the time between this
    /// and the forced draw below is what the person who pressed the tile
    /// actually waits for, and it is logged so that "switching takes ten
    /// seconds" can be a number instead of a memory.
    private var changeArrivedAt: CFTimeInterval?
    /// Watches the main thread for the gaps a person feels.
    private let heartbeat = MainThreadHeartbeat()
    /// A save that is waiting for the typing to stop.
    private var pendingSave: DispatchWorkItem?
    private let hud = HUD()
    private let recorder = Recorder()
    private let keyWatcher = KeyWatcher()
    private let cancelWatcher = KeyWatcher()
    /// The API keys this session has resolved.
    ///
    /// Reading one decrypts a Keychain item, which blocks the calling thread
    /// for as long as the Keychain takes. It happens once per provider, here,
    /// and never on the path between a stop and a transcript.
    private let credentials = CredentialCache.shared
    private var statusItem: StatusItemController!
    private var hotkeys: GlobalHotkeyManager?
    private var provider: (any Provider)?
    private var lastTranscript: String?
    private var history = HistoryStore.loadEntries()
    private var providers: [MenuProvider] = []
    private var transcriptionTask: Task<Void, Never>?
    /// The loop that asks the provider for a live partial while recording.
    private var liveTask: Task<Void, Never>?
    /// What has already been transcribed for the recording that is running.
    ///
    /// Created when the microphone starts and dropped when the recording is
    /// delivered, cancelled or failed. It is what makes the stop send the tail
    /// instead of the whole take.
    private var ledger: TranscriptLedger?
    private var shortcutRecorder: ShortcutRecorder?
    private var secretPrompt: SecretPrompt?
    private let settingsController = SettingsWindowController()
    private let welcomeController = WelcomeWindowController()
    private let historyController = HistoryWindowController()
    /// The dictation palette: the recent transcripts, one keystroke away.
    private let palette = PaletteController()
    private var triggerTimer: Timer?
    private var triggerURL: URL?
    private var providerRefreshTimer: Timer?
    /// The application the user was in when the recording started.
    ///
    /// The process and the bundle are both kept: the paste guard compares them
    /// with the frontmost app at delivery, so a transcript is only typed into
    /// the application the words were meant for.
    private var frontmostAtPress: FrontmostApp?
    /// The localized name of that application, for the card's header.
    private var frontmostNameAtPress: String?
    /// Whether the recording was asked for by the hot key.
    private var startedFromHotkey = false
    /// Whether Accessibility permission has already been prompted during this session.
    private var hasRequestedAccessibility = false
    /// How long the last recording was, in seconds.
    private var recordingElapsed: TimeInterval = 0
    /// The microphone the running recording is using, as the calibration book
    /// knows it. Resolved when the microphone starts, while the device is known
    /// to be the one producing the take.
    private var recordingDeviceUID: String?
    /// The credential migration that runs off the main actor at launch.
    private var migrationTask: Task<Void, Never>?

    /// The part of the configuration a provider is built from.
    ///
    /// Appearance, dwell, the microphone and the shortcuts live outside this, so
    /// changing one of them must not tear down the provider: doing that also
    /// re-probes every other provider over the network, which is what made a
    /// settings click feel like it took ten seconds.
    internal struct ProviderSignature: Equatable {
        var provider: String
        var providers: [String: ProviderConfig]
    }

    /// What the live provider was built from, so a rebuild can be skipped when
    /// nothing it depends on has changed.
    private var providerSignature: ProviderSignature?
    /// What the launch correction did, so a key that arrives later in the same
    /// launch can still move the app onto the service that key belongs to.
    private var launchCorrection: ProviderMigration.Correction?

    /// The state of the app.
    enum State {
        case idle
        case recording
        case working
    }

    private(set) var state: State = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.openFile()
        heartbeat.start()
        // A dictation app is asked to do its one job by a key press that may
        // arrive hours after the last one. App Nap will happily put an idle,
        // invisible app to sleep and coalesce its timers, which shows up as a
        // hotkey that answers late and a menu bar mark that stops breathing.
        // The assertion is released by the system when the app quits.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Answer the record key without waiting to be woken"
        )
        inputLatency.start()
        Log.shared.info("app.started", [
            "version": .string(Self.version),
            "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
        ])
        logIdentityMigration()
        loadConfiguration()
        warmCredentials()
        migrateProviderIfNeeded()
        applyAppearance()
        // The material the app already has is not a change: only a pick shows a
        // preview, or every unrelated setting would flash the island.
        previewedMaterial = config.hudMaterial
        previewedVisualizer = config.hudVisualizer

        hud.dwell = config.hudDwellSeconds
        hud.visualizer = config.hudVisualizer
        hud.material = config.hudMaterial
        applyCalibration(for: MicrophoneCatalog.recordingDeviceUID(
            configured: config.microphoneDeviceUID
        ))
        hud.setLevelProvider { [weak self] in
            self?.recorder.level ?? 0
        }
        hud.setSpectrumProvider { [weak self] in
            self?.recorder.spectrum ?? .zero
        }
        installHUDActions()

        statusItem = StatusItemController()
        statusItem.onAction = { [weak self] action in
            self?.handle(action)
        }

        recorder.onFailure = { [weak self] message in
            self?.failRecording(message)
        }
        // The clock of the recording card is the real length of the
        // recording, not a number that was set once.
        recorder.onTick = { [weak self] level, elapsed in
            _ = level
            self?.recordingElapsed = elapsed
            self?.hud.updateRecording(elapsed: HUDClock.string(for: elapsed))
        }

        keyWatcher.onRelease = { [weak self] in
            self?.recordKeyReleased()
        }
        keyWatcher.onBlocked = { [weak self] in
            self?.hotkeyBlocked()
        }

        // Escape cancels a recording without transcribing it. It is watched
        // the same way as the record key, so it works without accessibility
        // permission and without a focused window. No hot key announces it, so
        // the watcher has to trust the keyboard state on its own.
        cancelWatcher.onRelease = { [weak self] in
            self?.cancelRecording()
        }

        // The watcher reads the keyboard state from the start: it is the only
        // way to see the release of the key, and the only way to say that
        // secure input swallowed the press.
        keyWatcher.watch(keyCode: config.hotkey.keyCode)
        cancelWatcher.watch(keyCode: Self.escapeKeyCode, reportsUnannouncedPresses: true)
        registerHotkeys()
        installTestTrigger()
        startProviderRefresh()
        // The provider is built once the credential cache is warm, not here:
        // building one resolves its key, and a re-signed build answers that
        // read with a Keychain prompt. Waiting for it on this path froze the
        // whole launch, island included, until someone clicked Allow.
        refreshMenu()
        logConfiguration()
        Log.shared.info("microphone.status", [
            "status": .string(Self.describe(AVCaptureDevice.authorizationStatus(for: .audio))),
        ])
        showLaunchIsland()
        scheduleFirstRunWelcome()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveConfiguration()
        migrationTask?.cancel()
        stopLiveTranscription()
        transcriptionTask?.cancel()
        recorder.cancel()
        keyWatcher.stop()
        cancelWatcher.stop()
        hotkeys?.uninstall()
        welcomeController.close()
        historyController.close()
        palette.dismiss(restoringFocus: false)
        settingsController.close()
        hud.hide()
        triggerTimer?.invalidate()
        providerRefreshTimer?.invalidate()
        statusItem.tearDown()
        Log.shared.info("app.stopped")
    }

    /// The virtual key code of Escape.
    private static let escapeKeyCode = 53

    /// The name of a microphone permission state.
    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not-determined"
        @unknown default: "unknown"
        }
    }

    /// Says what the identity migration moved.
    ///
    /// The migration itself runs before this method exists, because the
    /// configuration and the log folders have to be in place before either of
    /// them is read. This only reports it, once the log has a file.
    private func logIdentityMigration() {
        guard let report = DotMain.pendingMigrationReport else { return }
        Log.shared.info("identity.migrated", [
            "configuration": .bool(report.movedConfigurationAndHistory),
            "log": .bool(report.movedLog),
            "welcome_flag": .bool(report.movedWelcomedFlag),
        ])
        DotMain.pendingMigrationReport = nil
    }

    /// Loads the configuration and retires a provider Dot cannot build, in that
    /// order and once per launch.
    ///
    /// Loading and correcting are one call (``ProviderMigration/loadConfiguration(from:probe:)``),
    /// so the configuration cannot be handed on before the correction. It runs
    /// here — after the log has a file, because the correction is reported, and
    /// before ``rebuildProvider()`` and before anything else reads the
    /// selection. The only Keychain question it asks is the attributes-only "is
    /// there a key?", which cannot raise a prompt, so a Keychain prompt can never
    /// leave the app on a provider that was deleted.
    private func loadConfiguration() {
        let loaded = ProviderMigration.loadConfiguration(from: DotConfig.defaultURL())
        config = loaded.config
        // The history file is read against the limit this configuration asks
        // for, so the window, the palette and the menu open with the same list.
        history = HistoryStore.loadEntries(limit: config.historyLimit)
        // The dwell of the card moved, and a file that never touched the slider
        // holds the old default. The migration rewrites it once and records the
        // revision, so a value the user chooses from now on is left alone.
        let migratedDwell = HUDDwellMigration.apply(to: &config)
        if migratedDwell {
            Log.shared.info("hud.dwell.migrated", [
                "seconds": .double(config.hudDwellSeconds),
                "revision": .int(config.hudDwellRevision),
            ])
        }
        if let correction = loaded.correction {
            launchCorrection = correction
            if !correction.filledEndpoints.isEmpty {
                // A service was named but its endpoint was missing, which builds
                // no provider at all: the app came up able to do nothing and
                // said so only as an error line.
                Log.shared.info("provider.endpoint.filled", [
                    "providers": .string(correction.filledEndpoints.joined(separator: ",")),
                ])
            }
            if !correction.retiredIDs.isEmpty {
                Log.shared.info("provider.retired", [
                    "old": .string(correction.retiredIDs.joined(separator: ",")),
                    "new": .string(correction.selectedID),
                    "key_available": .bool(!correction.awaitingKey),
                ])
            }
        }
        guard migratedDwell || loaded.correction != nil else { return }
        // Nothing can build a retired provider and nothing reads an unmigrated
        // dwell the same way twice, so the file has to hold what this launch
        // uses: the next launch reads it back.
        saveConfiguration()
    }

    /// Copies credentials written by an older build, and upgrades the launch
    /// fallback when the copy makes one of its services usable.
    ///
    /// The Keychain work does not run here. A read of an item whose signature
    /// changed puts a system prompt on screen and waits for an answer, and
    /// waiting for it in `applicationDidFinishLaunching` froze the launch. The
    /// work therefore runs on a background queue with a deadline: a prompt that
    /// is never answered leaves the app on the provider the launch correction
    /// chose and the copy runs again on the next launch, instead of hanging.
    ///
    /// Nothing here ever reads a key value into this method: the migration
    /// copies secret to secret and reports only which providers it touched. The
    /// configuration is written atomically before the provider is rebuilt.
    private func migrateProviderIfNeeded() {
        migrationTask = Task { [weak self] in
            guard let report = await DotMigration.migrateCredentialsAtLaunch() else {
                // The app is already usable: the provider was chosen before
                // this task started, without asking for any key material.
                Log.shared.warn("credential.migration.timedOut")
                return
            }
            guard let self else { return }
            if !report.copiedProviderIDs.isEmpty {
                Log.shared.info("credential.migrated", [
                    "providers": .string(report.copiedProviderIDs.joined(separator: ",")),
                    "from": .string("service-name"),
                ])
                // A key that the copy just produced may have been answered as
                // "no key" before it existed: forget the answer, so the rebuild
                // below resolves the new one.
                for id in report.copiedProviderIDs {
                    self.credentials.invalidate(id)
                }
            }
            if report.copiedFromLegacyTool {
                Log.shared.info("credential.migrated", [
                    "provider": .string(ProviderIdentifier.xiaomi),
                    "from": .string("legacy-tool"),
                ])
            }
            // The copy may have produced the key the launch correction could
            // not see yet; a provider the user chose stays untouched.
            let correction = self.launchCorrection
            self.launchCorrection = nil
            if ProviderMigration.upgrade(&self.config, after: correction) {
                self.saveConfiguration()
                Log.shared.info("provider.upgraded", [
                    "provider": .string(self.config.provider),
                    "reason": .string("key-available"),
                ])
            }
            self.rebuildProvider()
            self.refreshProviders()
        }
    }

    // MARK: - HUD

    /// Wires the island's buttons once.
    ///
    /// `HUDView` draws no button without a closure, so every action the card
    /// offers is filled in here. Every closure is weak so the HUD, which the
    /// delegate owns, can never keep the delegate alive.
    private func installHUDActions() {
        var actions = HUDActions()
        actions.stop = { [weak self] in self?.stopRecording() }
        actions.cancel = { [weak self] in self?.cancelRecording() }
        actions.copy = { [weak self] in self?.copyLastTranscript() }
        actions.paste = { [weak self] in self?.pasteLastTranscript() }
        actions.beginInlineEdit = { [weak self] in self?.hud.beginInlineEditing() }
        actions.endInlineEdit = { [weak self] in self?.hud.endInlineEditing() }
        actions.updateTranscript = { [weak self] updated in
            self?.applyInlineTranscriptEdit(updated)
        }
        actions.history = { [weak self] in self?.openHistory() }
        actions.settings = { [weak self] in self?.openSettings() }
        actions.close = { [weak self] in self?.hud.hide() }
        hud.actions = actions
    }

    /// Shows the launch card once, after the menu is ready.
    ///
    /// The short delay lets the menu bar item settle, so the greeting does not
    /// race the first menu refresh. A recording that started in the meantime
    /// wins: the card never covers the microphone state.
    private func showLaunchIsland() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.state == .idle else { return }
            self.refreshReadyCard()
            self.hud.showReady(shortcut: self.config.hotkey.label)
        }
    }

    /// Tells the ready card which service dictation goes to, and a masked hint
    /// of the key in use. The key is served from the credential cache, so this
    /// never pays a Keychain round trip.
    private func refreshReadyCard() {
        let key = credentials.resolvedKey(for: config.provider)
        hud.setActiveService(
            activeServiceLabel,
            keyHint: MaskedKey.describe(key) ?? ""
        )
    }

    /// The active service, named so a person can tell what they are connected to.
    ///
    /// A configured endpoint is named after its host rather than "Custom
    /// endpoint": the whole point of showing it is to answer "what is my speech
    /// going to", and the host is the answer. A service with a real name keeps
    /// that name.
    private var activeServiceLabel: String {
        let preset = ProviderPreset.presenting(config)
        guard preset.id == ProviderPreset.custom.id,
              let host = Self.host(of: config.providers[config.provider]?.baseURL),
              !host.isEmpty
        else {
            return preset.name
        }
        return host
    }

    /// The host of a base URL, without the scheme, path or a trailing slash.
    nonisolated static func host(of baseURL: String?) -> String? {
        guard let baseURL, let url = URL(string: baseURL), let host = url.host else { return nil }
        return host
    }

    /// The default that records whether the welcome has been finished.
    private static let welcomedKey = "dot.welcomed"

    /// Shows the welcome on the first launch after installation.
    ///
    /// The delay leaves the menu bar and the launch card time to settle. The
    /// flag is read again after the delay, so finishing the welcome quickly
    /// can never present it a second time.
    private func scheduleFirstRunWelcome() {
        guard !UserDefaults.standard.bool(forKey: Self.welcomedKey) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self,
                  !UserDefaults.standard.bool(forKey: Self.welcomedKey)
            else { return }
            self.openWelcome()
        }
    }

    // MARK: - Menu actions

    private func handle(_ action: MenuAction) {
        switch action {
        case .toggleRecording:
            toggleRecording()
        case .pasteLast:
            pasteLastTranscript()
        case .copyLast:
            copyLastTranscript()
        case .copyHistory(let text):
            copyHistory(text)
        case .clearHistory:
            confirmClearHistory()
        case .selectMicrophone(let id):
            selectMicrophone(id)
        case .selectLanguage(let id):
            selectLanguage(id)
        case .selectPreset(let id):
            selectPreset(id)
        case .setAPIKey(let id):
            setAPIKey(for: id)
        case .toggleAutoPaste:
            toggleAutoPaste()
        case .toggleFastRecord:
            toggleFastRecord()
        case .toggleLaunchAtLogin:
            toggleLaunchAtLogin()
        case .openHistory:
            openHistory()
        case .openWelcome:
            openWelcome()
        case .openSettings:
            openSettings()
        case .openLog:
            SystemAction.revealLog()
        case .checkForUpdates:
            UpdateController.shared.checkForUpdates(userInitiated: true)
        case .showAbout:
            openSettings(tab: 4)
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// Builds the state the menu shows.
    ///
    /// The microphones are read again here, so a headset that was plugged in
    /// after launch appears in the menu the next time it opens. The options
    /// carry the configured device even when Dot cannot offer it, so a refresh
    /// never changes the person's choice.
    private func refreshMenu() {
        var state = MenuState()
        state.isRecording = self.state == .recording
        state.recordShortcut = MenuShortcuts.shortcut(for: config.hotkey)
        state.pasteShortcut = MenuShortcuts.shortcut(for: config.pasteHotkey)
        state.history = history.map(\.text)
        state.microphones = MicrophoneDirectory.options(
            devices: MicrophoneCatalog.devices(),
            configuredUID: config.microphoneDeviceUID
        ).map { MenuMicrophone(id: $0.uid, name: $0.name) }
        state.selectedMicrophoneID = config.microphoneDeviceUID
        let currentModel = config.settings(for: config.provider).model
        state.languages = ProviderLanguageCatalog.menuLanguages(for: config.provider, model: currentModel)
        state.selectedLanguage = ProviderLanguageCatalog.validatedLanguage(
            config.settings(for: config.provider).language,
            for: config.provider,
            model: currentModel
        )
        state.providers = providers
        state.selectedPresetID = ProviderPreset.presenting(config).id
        state.autoPasteEnabled = config.autoPaste
        state.fastRecordEnabled = config.fastRecord
        state.launchAtLogin = LaunchAtLogin.isEnabled
        statusItem.menuState = state
    }

    // MARK: - Recording

    private func toggleRecording() {
        switch state {
        case .recording:
            stopRecording()
        case .idle, .working:
            startRecording()
        }
    }

    /// The hot key was pressed.
    ///
    /// The press is answered in both modes: it starts a recording when there is
    /// none, and it stops one when there is. The mode only decides what a
    /// *release* means, which is ``recordKeyReleased()``'s question.
    private func hotkeyPressed() {
        Log.shared.info("hotkey.pressed", [
            "hotkey": .string(config.hotkey.label),
            "mode": .string(config.recordingMode.rawValue),
        ])
        keyWatcher.noteHotkeyFired()
        switch RecordKeyInteraction.action(
            for: .press,
            mode: config.recordingMode,
            phase: phase
        ) {
        case .start:
            startRecording(fromHotkey: true)
        case .stop:
            // The press stops the take in both modes. In hold mode this is the
            // fallback for a release the keyboard state could not read; in
            // toggle mode it is the normal way a recording ends.
            stopRecording()
        case .ignore:
            break
        }
    }

    /// The hot key came back up.
    ///
    /// Only ``RecordingMode/hold`` acts on this: the key is the gesture, and
    /// lifting it ends the take. In ``RecordingMode/toggle`` the release is not
    /// an instruction, so a recording started by a press keeps running until
    /// the next press, and the watcher is left running for the two things it
    /// still owes: the secure-input report and the release of the fallback.
    private func recordKeyReleased() {
        guard RecordKeyInteraction.action(
            for: .release,
            mode: config.recordingMode,
            phase: phase
        ) == .stop else { return }
        stopRecording()
    }

    /// The state the record key is answered in.
    private var phase: RecordingPhase {
        switch state {
        case .idle: .idle
        case .recording: .recording
        case .working: .working
        }
    }

    private func startRecording(fromHotkey: Bool = false) {
        guard state == .idle else { return }
        startedFromHotkey = fromHotkey

        // There is no point in recording when the transcript could never be
        // made.
        if let provider, !(providerIsAvailable(provider)) {
            hud.showMessage(
                text: "\(selectedProviderName) is not available right now.",
                action: nil
            )
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            Log.shared.info("microphone.requesting")
            Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                Log.shared.info("microphone.answered", ["granted": .bool(granted)])
                if granted {
                    self.beginRecording()
                } else {
                    self.showMicrophoneDenied()
                }
            }
            return
        default:
            showMicrophoneDenied()
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        // The microphone prompt is answered on a path of its own, and the
        // person may press the shortcut again while it is up. The second
        // answer must not open a second recording over the first.
        guard state == .idle else { return }
        // In hold mode the press may already be over: the microphone prompt
        // takes long enough for a quick tap to end while it is up, and a
        // recording whose key was released can never be stopped by that key.
        // In toggle mode the press that started the take *has* ended by design,
        // so a tap that outruns the prompt is a recording like any other.
        if startedFromHotkey, config.recordingMode == .hold, !keyWatcher.isPressActive {
            Log.shared.info("recording.skipped", ["reason": .string("the press was over")])
            startedFromHotkey = false
            return
        }
        startedFromHotkey = false
        do {
            try recorder.start(deviceUID: config.microphoneDeviceUID)
        } catch RecorderError.permissionDenied {
            showMicrophoneDenied()
            return
        } catch {
            hud.showMessage(text: error.localizedDescription, action: nil)
            Log.shared.error("recorder.start.failed", ["error": .string(error.localizedDescription)])
            return
        }
        // The card only appears once the microphone really runs: a live-looking
        // meter over a system dialog would be a lie. The device is resolved
        // before the card exists, because the card seeds its meter from the
        // calibration of the device that is recording. It is written directly
        // rather than through ``applyCalibration(for:)``, which refuses to touch
        // a take that is already running.
        recordingDeviceUID = MicrophoneCatalog.recordingDeviceUID(
            configured: config.microphoneDeviceUID
        )
        hud.setCalibration(
            MicrophoneCalibrationBook.calibration(
                for: recordingDeviceUID,
                in: config.microphoneCalibration
            )
        )
        state = .recording
        let frontmost = NSWorkspace.shared.frontmostApplication
        frontmostAtPress = FrontmostApp(
            processIdentifier: frontmost?.processIdentifier,
            bundleIdentifier: frontmost?.bundleIdentifier
        )
        frontmostNameAtPress = frontmost?.localizedName
        hud.showRecording(elapsed: "0:00")
        startLiveTranscription()
        keyWatcher.watch(keyCode: config.hotkey.keyCode)
        refreshMenu()
        Log.shared.info("recording.started")
    }

    private func stopRecording() {
        guard state == .recording else { return }
        let inFlightLiveTask = liveTask
        liveTask = nil
        let recording = recorder.stop()
        state = .working

        let samples = recording.sampleCount
        let initialLedger = self.ledger
            ?? TranscriptLedger(commitSeconds: maxSegmentSeconds(self.provider))

        Log.shared.info("recording.stopped", [
            "duration_s": .double(recording.duration),
            "samples": .int(samples),
            "peak_dbfs": .double(recording.peakDBFS),
            "final_samples": .int(initialLedger.committedSamples),
            "final_chunks": .int(initialLedger.committedText.count),
        ])

        // The only thing that sends nothing at all: not a single sample.
        guard samples > 0 else {
            inFlightLiveTask?.cancel()
            self.ledger = nil
            hud.showMessage(text: "Nothing was recorded.", action: nil)
            finishWork()
            return
        }

        learn(from: recording)
        refreshMenu()
        // The guard reads the frontmost application when the words are ready,
        // not when the recording stops: the transcript can arrive seconds
        // later, and what is frontmost then is what a paste would land in.

        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let initialLedger = self.ledger ?? initialLedger
            let lastTranscribed = initialLedger.provisional?.endSample ?? initialLedger.committedSamples
            let uncoveredCount = max(0, samples - lastTranscribed)

            // VAD check: determine whether trailing audio after the last live request contains speech
            let uncoveredHasSpeech: Bool = {
                guard uncoveredCount > 0 else { return false }
                let start = max(0, samples - uncoveredCount)
                guard start < samples else { return false }
                let hop = 256
                let frames = uncoveredCount / hop
                guard frames > 0 else { return false }
                var maxRMS = 0.0
                for f in 0..<frames {
                    var sumSq = 0.0
                    let fStart = start + f * hop
                    for i in fStart..<(fStart + hop) {
                        let s = Double(recording.samples[i]) / 32768.0
                        sumSq += s * s
                    }
                    let rms = sqrt(sumSq / Double(hop))
                    if rms > maxRMS { maxRMS = rms }
                    if maxRMS > 0.015 { return true }
                }
                return false
            }()

            // Fast-Path: If trailing audio is release silence/room noise, await the in-flight
            // live task with a fast deadline (1.0s) and promote its transcript immediately.
            if !uncoveredHasSpeech, let activeTask = inFlightLiveTask {
                _ = await withTaskGroup(of: Void.self) { group in
                    group.addTask { _ = await activeTask.result }
                    group.addTask { try? await Task.sleep(for: .milliseconds(1000)) }
                    await group.next()
                    group.cancelAll()
                }
                let currentLedger = self.ledger ?? initialLedger
                let candidateText = currentLedger.displayText
                if !candidateText.isEmpty {
                    Log.shared.info("transcription.fastpath.reusedProvisional", [
                        "samples": .int(samples),
                        "characters": .int(candidateText.count),
                    ])
                    self.ledger = nil
                    self.handleTranscript(candidateText)
                    return
                }
                // The partial said nothing usable, so the tail below is the one
                // that sends this audio. The live task must not commit a chunk
                // the tail is about to send again, and it must not keep a
                // connection open while the stop waits for its own.
                activeTask.cancel()
            } else if let activeTask = inFlightLiveTask {
                // Speech continued right to the stop; cancel the obsolete live
                // task immediately so the final tail request is dispatched
                // without waiting for it.
                activeTask.cancel()
            }

            let currentLedger = self.ledger ?? initialLedger
            self.ledger = nil

            let trailingTolerance = uncoveredHasSpeech ? WAVSpec.sampleRate / 4 : WAVSpec.sampleRate * 2
            switch currentLedger.stopPlan(sampleCount: samples, trailingTolerance: trailingTolerance) {
            case .alreadyFinal(let text):
                Log.shared.info("transcription.reused", [
                    "samples": .int(samples),
                    "characters": .int(text.count),
                ])
                self.handleTranscript(text)
            case .send(let range, let prefix):
                let piece = Array(recording.samples[range])
                let segments = Segmenter.segmentCount(
                    samples: piece.count,
                    seconds: self.maxSegmentSeconds(self.provider)
                )
                Log.shared.info("transcription.tail", [
                    "samples": .int(piece.count),
                    "segments": .int(segments),
                    "final_samples": .int(currentLedger.committedSamples),
                ])
                self.hud.showTranscribing()
                do {
                    let transcript = try await self.transcribe(
                        samples: piece,
                        prefix: prefix,
                        total: segments
                    )
                    self.handleTranscript(transcript)
                } catch is CancellationError {
                    self.finishWork()
                } catch {
                    // The tail failed, but the audio the live loop already
                    // committed is transcribed and final. Losing it because the
                    // last few seconds failed would throw away the recording.
                    let fallback = currentLedger.displayText
                    if !fallback.isEmpty {
                        Log.shared.info("transcription.tail.fallbackToPrefix", [
                            "characters": .int(fallback.count),
                        ])
                        self.handleTranscript(fallback)
                    } else {
                        self.handleFailure(error)
                    }
                }
            }
        }
    }

    /// Drops the recording without sending it anywhere.
    private func cancelRecording() {
        guard state == .recording else { return }
        stopLiveTranscription()
        ledger = nil
        recorder.cancel()
        state = .idle
        refreshMenu()
        hud.cancel()
        hud.showMessage(text: "Recording cancelled.", symbol: "xmark.circle")
        Log.shared.info("recording.cancelled")
    }

    // MARK: - Microphone calibration

    /// Tells the card what is known about a microphone.
    ///
    /// A running take keeps the window of the device that is actually
    /// recording: changing the picker while it is open must not rescale the
    /// waveform halfway through. The next take picks the change up.
    private func applyCalibration(for device: String?) {
        guard state != .recording else { return }
        hud.setCalibration(
            MicrophoneCalibrationBook.calibration(for: device, in: config.microphoneCalibration)
        )
    }

    /// Folds a finished take into the book of what is known about the
    /// microphone that recorded it.
    ///
    /// Only measurements are folded: the room floor and the loudest moment. The
    /// samples are never scaled, filtered or gated, so the WAV a provider
    /// receives is byte for byte the WAV it would have received before the
    /// calibration existed.
    private func learn(from recording: Recorder.Recording) {
        guard let device = recordingDeviceUID,
              let observation = MicrophoneCalibrationBook.observation(
                  samples: recording.samples,
                  peakDBFS: recording.peakDBFS
              )
        else { return }
        let book = MicrophoneCalibrationBook.folding(
            config.microphoneCalibration,
            observation: observation,
            device: device,
            now: Date()
        )
        guard book != config.microphoneCalibration else { return }
        config.microphoneCalibration = book
        saveConfiguration()
        let entry = MicrophoneCalibrationBook.calibration(for: device, in: book)
        Log.shared.info("microphone.calibration.learned", [
            "recordings": .int(entry?.observedSamples ?? 0),
            "floor_dbfs": .double(entry?.noiseFloorDBFS ?? 0),
            "peak_dbfs": .double(entry?.peakDBFS ?? 0),
        ])
    }

    // MARK: - Live partial transcription

    /// The shape and the cadence of the live partial requests.
    private enum Live {
        /// The most audio one committed chunk may hold, in seconds, however
        /// long a request the provider accepts.
        ///
        /// A commit ends the open audio and starts a new request, so this
        /// bounds how long the card can go without final text. It is a cadence
        /// of the live loop, not a capability of a provider: the request itself
        /// never carries more than ``maxSegmentSeconds(_:)``.
        static let maximumCommitSeconds = 60
        /// How long the recording runs before the first request.
        static let initialDelay: Duration = .milliseconds(300)
        /// The pause after one request before the next one starts.
        static let interval: Duration = .milliseconds(350)
        /// The pause when the recording has not produced a sample yet.
        static let emptyDelay: Duration = .milliseconds(200)
        /// How much new audio, in seconds, justifies a new partial.
        static let minimumGrowth: Double = 1.1
        /// How many consecutive failures end the loop.
        static let failureLimit = 5
        /// The longest error text that reaches the log, in characters.
        ///
        /// A service that answers with an HTML error page would otherwise put
        /// kilobytes of markup on one line of a file a person has to read. The
        /// head of the message carries the diagnosis; the rest does not.
        static let errorCharacters = 160
    }

    /// Starts transcribing the recording while the user is still speaking.
    ///
    /// The loop does two things, in this order, one request at a time:
    ///
    /// 1. **Commit.** When a whole ``Live/maximumCommitSeconds`` chunk of new
    ///    audio is available it is sent once and its text becomes final.
    ///    Committed audio is never sent again, not by the next partial and not
    ///    by the stop.
    /// 2. **Preview.** Otherwise it sends the tail that is still open, so the
    ///    card can show what the user just said. The partial never reaches back
    ///    into committed audio.
    ///
    /// The provider is captured once, at the start of the recording: a
    /// recording is never transcribed by a provider the user switched to in the
    /// middle of it. The on-device transcriber is skipped: its path analyses one
    /// finished buffer, so calling it every second would reserve and release the
    /// same assets over and over without producing a stream.
    ///
    /// The loop sends one request at a time: a slow answer delays the next
    /// attempt instead of overlapping it, and cancellation is checked after
    /// every await, so a late partial never reaches the card.
    private func startLiveTranscription() {
        stopLiveTranscription()
        guard let provider, provider.id != ProviderIdentifier.apple else {
            // Nothing is streamed by the on-device transcriber, so the whole
            // recording stays open and the stop sends it.
            ledger = TranscriptLedger(commitSeconds: maxSegmentSeconds(provider))
            return
        }
        let commitSeconds = min(Live.maximumCommitSeconds, maxSegmentSeconds(provider))
        ledger = TranscriptLedger(commitSeconds: commitSeconds)
        let settings = config.settings(for: provider.id)
        liveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Live.initialDelay)
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.state == .recording, let currentLedger = self.ledger else { return }
                let sampleCount = self.recorder.sampleCount
                if sampleCount <= 0 {
                    try? await Task.sleep(for: Live.emptyDelay)
                    continue
                }
                let committed = currentLedger.committedSamples
                let openSamples = sampleCount > committed
                    ? self.recorder.samples(in: committed..<sampleCount)
                    : []
                guard let vadPlan = currentLedger.evaluateVAD(in: openSamples) else {
                    try? await Task.sleep(for: Live.interval)
                    continue
                }
                let reqRange: Range<Int>
                let isCommit: Bool
                let commitUpTo: Int
                switch vadPlan {
                case .sendSegment(let segRange, let upTo):
                    reqRange = segRange
                    isCommit = true
                    commitUpTo = upTo
                case .sendProvisional(let provRange):
                    reqRange = provRange
                    isCommit = false
                    commitUpTo = provRange.upperBound
                }
                guard let wav = self.recorder.wav(range: reqRange) else {
                    try? await Task.sleep(for: Live.emptyDelay)
                    continue
                }
                do {
                    let text = try await provider.transcribe(
                        wav: wav,
                        model: settings.model,
                        language: settings.language
                    )
                    guard !Task.isCancelled, self.state == .recording else { return }
                    failures = 0
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isCommit {
                        self.ledger?.commit(range: committed..<commitUpTo, text: trimmed)
                        Log.shared.info("live.committed", [
                            "characters": .int(trimmed.count),
                            "samples": .int(reqRange.count),
                            "committed_samples": .int(self.ledger?.committedSamples ?? 0),
                        ])
                    } else if !trimmed.isEmpty {
                        self.ledger?.recordProvisional(range: reqRange, text: trimmed)
                    }
                    self.hud.showLiveText(self.ledger?.displayText ?? "")
                } catch {
                    guard !Task.isCancelled, self.state == .recording else { return }
                    if Self.isIgnoredLiveError(error) {
                        failures = 0
                    } else {
                        failures += 1
                        Log.shared.warn("live.failed", [
                            "error": .string(Self.shortDescription(of: error)),
                            "attempt": .int(failures),
                            "stage": .string(isCommit ? "commit" : "provisional"),
                        ])
                        if failures >= Live.failureLimit || Self.stopsLiveImmediately(error) {
                            return
                        }
                    }
                }
                try? await Task.sleep(for: Live.interval)
            }
        }
    }

    /// Stops the live loop. Safe to call when there is none.
    private func stopLiveTranscription() {
        liveTask?.cancel()
        liveTask = nil
    }

    /// Whether a failed partial should not count against the provider.
    ///
    /// A silent second is not an error: the provider simply heard nothing yet.
    private nonisolated static func isIgnoredLiveError(_ error: Error) -> Bool {
        guard let error = error as? ProviderError else { return false }
        if case .noSpeech = error { return true }
        return false
    }

    /// Whether the provider cannot serve partials at all.
    private nonisolated static func stopsLiveImmediately(_ error: Error) -> Bool {
        guard let error = error as? ProviderError else { return false }
        switch error {
        case .unavailable, .missingCredential, .unsupported:
            return true
        default:
            return false
        }
    }

    /// A short error for the log. It never contains the audio or a transcript.
    private nonisolated static func shortDescription(of error: Error) -> String {
        let text: String
        if let providerError = error as? ProviderError {
            text = providerError.errorDescription ?? providerError.localizedDescription
        } else {
            text = error.localizedDescription
        }
        return String(text.prefix(Live.errorCharacters))
    }

    /// Sends the audio that is still open, one segment at a time.
    ///
    /// The prefix is the text of the chunks the live loop already committed;
    /// this call only pays for the tail.
    ///
    /// - Parameters:
    ///   - samples: the tail, in 16 kHz mono samples.
    ///   - prefix: the text that is already final.
    ///   - total: how many requests the tail needs, for the card's progress.
    private func transcribe(samples: [Int16], prefix: String, total: Int) async throws -> String {
        guard let provider else {
            throw ProviderError.unavailable("There is no provider.")
        }
        let settings = config.settings(for: provider.id)
        let report = try await Transcriber.transcribe(
            samples: samples,
            provider: provider,
            model: settings.model,
            language: settings.language,
            maxSegmentSeconds: maxSegmentSeconds(provider),
            progress: nil
        )
        if !report.isComplete {
            Log.shared.warn("transcription.partial", [
                "succeeded": .int(report.succeeded),
                "failed": .int(report.failed),
                "total": .int(report.total),
            ])
        }
        if total != report.total {
            Log.shared.warn("transcription.replanned", [
                "announced": .int(total),
                "sent": .int(report.total),
            ])
        }
        return TranscriptLedger.join([prefix, report.text])
    }

    /// The longest segment one request may carry, in seconds.
    ///
    /// The length is a capability of the provider: it is what the service
    /// accepts in one request, and it is declared there rather than here.
    /// `config.maxSegmentSeconds` can lower it for every provider at once, and
    /// a value of `0` leaves the provider's own capability in force.
    private func maxSegmentSeconds(_ provider: (any Provider)?) -> Int {
        guard let provider else { return Segmenter.defaultSegmentSeconds }
        let configured = config.maxSegmentSeconds
        guard configured > 0 else { return provider.maxSegmentSeconds }
        return min(provider.maxSegmentSeconds, configured)
    }

    private func failRecording(_ message: String) {
        guard state == .recording else { return }
        stopLiveTranscription()
        ledger = nil
        recorder.cancel()
        // The watcher keeps running: a failed take is not a reason to stop
        // hearing the key. It still reports secure input, and in hold mode the
        // next press must still be able to end the recording.
        state = .idle
        refreshMenu()
        hud.showMessage(text: message, action: nil)
        Log.shared.error("recording.failed", ["error": .string(message)])
    }

    private func handleTranscript(_ transcript: String) {
        lastTranscript = transcript
        history = HistoryStore.adding(
            transcript,
            at: Date(),
            to: history,
            limit: config.historyLimit
        )
        HistoryStore.saveEntries(history, limit: config.historyLimit)
        refreshMenu()

        // The history keeps the transcript and the clipboard keeps the
        // transcript, whichever text the rewrite puts at the cursor.
        let grammar = grammarResult(for: transcript)
        let plan = TranscriptDelivery.plan(transcript: transcript, grammar: grammar)

        // The clipboard and the paste always carry the whole transcript, even
        // when the card only has room for the top of it. It is on the clipboard
        // before the guard runs, because a copy is the outcome the guard
        // decides on: the words are never left only in a failed paste.
        Paste.copy(plan.clipboard)
        let decision = pasteDecision()
        var delivery: HUDDelivery = .copied
        switch decision {
        case .paste:
            delivery = paste(plan)
        case .copy(let reason):
            if reason == .accessibilityMissing, !hasRequestedAccessibility {
                hasRequestedAccessibility = true
                Paste.requestAccessibility()
            }
            logSkippedPaste(reason)
        }
        hud.showTranscript(
            text: transcript,
            delivery: delivery,
            elapsed: HUDClock.string(for: recordingElapsed),
            destination: decision == .paste ? frontmostNameAtPress : nil,
            grammar: grammar?.target,
            grammarWasLong: grammar?.wasLong ?? false
        )
        if let grammar {
            Log.shared.info("grammar.applied", [
                "target": .string(grammar.target.rawValue),
                "was_long": .bool(grammar.wasLong),
                "characters": .int(grammar.text.count),
            ])
        }
        if config.logTranscripts {
            Log.shared.info("transcript", ["text": .string(transcript)])
        } else {
            Log.shared.info("transcript.received", ["characters": .int(transcript.count)])
        }
        finishWork()
    }

    /// The rewrite for this transcript, or `nil` when the rewrite is off.
    ///
    /// The target comes from the app that was frontmost when the recording
    /// started, which is the app the words were meant for; an app Dot cannot
    /// place is plain and gets no rewrite at all.
    private func grammarResult(for transcript: String) -> OutputGrammar.Result? {
        guard config.outputGrammarEnabled else { return nil }
        let target = config.dictationTarget(for: frontmostAtPress?.bundleIdentifier)
        guard target != .plain else { return nil }
        return OutputGrammar.result(for: transcript, target: target)
    }

    /// What the paste guard decides for a finished transcript.
    ///
    /// The application at the press is the one the words were meant for, and it
    /// has to still be frontmost when they are ready. Anything else is a copy: a
    /// paste is a keystroke into whatever holds the focus, and nothing on screen
    /// tells the person where it landed.
    private func pasteDecision() -> PasteDecision {
        PasteDecision.decide(
            atPress: frontmostAtPress,
            atDelivery: Paste.frontmostApp,
            accessibilityGranted: Paste.accessibilityGranted,
            autoPasteEnabled: config.autoPaste,
            ownBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
    }

    /// Records why the transcript was copied instead of pasted.
    ///
    /// The two apps are logged with the reason: a guard that copies without
    /// saying what changed is indistinguishable from a guard that is broken.
    private func logSkippedPaste(_ reason: PasteDecision.CopyReason) {
        let fields: [String: LogValue] = [
            "press": .string(frontmostAtPress?.bundleIdentifier ?? "none"),
            "delivery": .string(Paste.frontmostApp?.bundleIdentifier ?? "none"),
        ]
        if reason.isWarning {
            Log.shared.warn(reason.logEvent, fields)
        } else {
            Log.shared.info(reason.logEvent, fields)
        }
    }

    /// Posts the planned insertion at the cursor.
    ///
    /// A rewritten transcript has to sit on the pasteboard while the keystroke
    /// is posted, because that is how the frontmost app receives it. The
    /// original words go back afterwards, so the clipboard never keeps the
    /// rewrite and a copy the person makes in between wins.
    ///
    /// - Parameter plan: what to insert and what the clipboard keeps.
    /// - Returns: how the card reports the delivery.
    private func paste(_ plan: TranscriptDelivery) -> HUDDelivery {
        let rewritten = plan.insertion != plan.clipboard
        if rewritten {
            Paste.copy(plan.insertion)
        }
        guard Paste.pasteCommand() else {
            Paste.copy(plan.clipboard)
            return .copied
        }
        if rewritten {
            restoreClipboard(plan.clipboard, after: plan.insertion)
        }
        return .pasted
    }

    /// Puts the original text back once the paste has been read.
    private func restoreClipboard(_ text: String, after insertion: String) {
        Task { @MainActor in
            // Long enough for the frontmost app to have read the pasteboard,
            // which happens as it handles the keystroke.
            try? await Task.sleep(for: .milliseconds(350))
            Paste.restore(text, ifStill: insertion)
        }
    }

    private func handleFailure(_ error: Error) {
        let message: String
        if let providerError = error as? ProviderError {
            message = providerError.errorDescription ?? providerError.localizedDescription
        } else {
            message = error.localizedDescription
        }
        Log.shared.error("transcription.failed", ["error": .string(message)])
        hud.showMessage(text: message, action: nil)
        finishWork()
    }

    private func finishWork() {
        stopLiveTranscription()
        ledger = nil
        state = .idle
        refreshMenu()
    }

    private func showMicrophoneDenied() {
        hud.showMessage(
            text: "Dot needs the microphone.",
            action: "Open Settings"
        ) {
            SystemAction.openMicrophoneSettings()
        }
        Log.shared.warn("microphone.denied")
    }

    private func hotkeyBlocked() {
        guard state == .idle else { return }
        Log.shared.warn("hotkey.blocked")
        hud.showMessage(
            text: "HOTKEY BLOCKED",
            action: "Open Settings"
        ) {
            SystemAction.openAccessibilitySettings()
        }
    }

    // MARK: - Transcript delivery

    /// Applies an inline edit made directly on the HUD island.
    private func applyInlineTranscriptEdit(_ newText: String) {
        let previous = lastTranscript
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastTranscript = trimmed.isEmpty ? nil : newText
        hud.updateTranscriptText(newText)
        if !trimmed.isEmpty {
            Paste.copy(newText)
            if let previous, let index = history.firstIndex(where: { $0.text == previous }) {
                history[index].text = newText
            } else if !history.isEmpty {
                history[0].text = newText
            } else {
                history = [HistoryStore.Entry(text: newText, addedAt: Date())]
            }
            HistoryStore.saveEntries(history)
            refreshMenu()
        }
    }

    private func pasteLastTranscript() {
        guard let transcript = lastTranscript ?? history.first?.text, !transcript.isEmpty else {
            hud.showMessage(text: "There is no transcript yet.", action: nil)
            return
        }
        lastTranscript = transcript
        Paste.copy(transcript)
        if Paste.accessibilityGranted, Paste.pasteCommand() {
            hud.showTranscript(text: transcript, delivery: .pasted, elapsed: "0:00")
        } else {
            hud.showTranscript(text: transcript, delivery: .copied, elapsed: "0:00")
        }
        Log.shared.info("transcript.pasted.again")
    }

    private func copyLastTranscript() {
        guard let transcript = lastTranscript ?? history.first?.text, !transcript.isEmpty else {
            hud.showMessage(text: "There is no transcript yet.", action: nil)
            return
        }
        lastTranscript = transcript
        Paste.copy(transcript)
        hud.showTranscript(text: transcript, delivery: .copied, elapsed: "0:00")
        Log.shared.info("transcript.copied.again")
    }

    // MARK: - Dictation palette

    /// Shows the palette over the recent transcripts, or closes it.
    private func showPalette() {
        // The key that opens the palette also closes it: pressing it again is
        // how a person changes their mind without reaching for Escape.
        if palette.isVisible {
            palette.dismiss()
            return
        }
        // A recording owns the microphone and the card. The palette is about
        // words that already exist, so it waits for the take to finish.
        guard state == .idle else {
            hud.showMessage(text: "A recording is still running.", symbol: "waveform")
            return
        }
        palette.show(
            entries: history,
            insert: { [weak self] text in self?.insertFromPalette(text) },
            copy: { [weak self] text in self?.copyFromPalette(text) }
        )
    }

    /// Inserts a transcript the person picked in the palette, at the cursor.
    ///
    /// The same path a dictation takes: the text goes on the clipboard and the
    /// paste keystroke is posted. The palette has already closed itself, so the
    /// application that was frontmost is the one receiving the paste.
    private func insertFromPalette(_ text: String) {
        lastTranscript = text
        Paste.copy(text)
        guard Paste.accessibilityGranted else {
            if !hasRequestedAccessibility {
                hasRequestedAccessibility = true
                Paste.requestAccessibility()
            }
            hud.showTranscript(text: text, delivery: .copied, elapsed: "0:00")
            Log.shared.warn("palette.inserted.copiedOnly")
            return
        }
        Task { @MainActor in
            // The palette closed itself before calling in, and the application
            // that was frontmost is being activated again: the keystroke has to
            // wait for it to be the one receiving keys.
            try? await Task.sleep(for: .milliseconds(140))
            let delivery: HUDDelivery = Paste.pasteCommand() ? .pasted : .copied
            hud.showTranscript(text: text, delivery: delivery, elapsed: "0:00")
            Log.shared.info("palette.inserted", [
                "characters": .int(text.count),
                "delivery": .string(delivery == .pasted ? "pasted" : "copied"),
            ])
        }
    }

    /// Copies a transcript the person picked in the palette, without inserting
    /// it.
    private func copyFromPalette(_ text: String) {
        lastTranscript = text
        Paste.copy(text)
        hud.showTranscript(text: text, delivery: .copied, elapsed: "0:00")
        Log.shared.info("palette.copied", ["characters": .int(text.count)])
    }

    private func copyHistory(_ text: String) {
        lastTranscript = text
        Paste.copy(text)
        hud.showTranscript(text: text, delivery: .copied, elapsed: "0:00")
        Log.shared.info("transcript.copied.history")
    }

    private func confirmClearHistory(refreshingHistory: Bool = false) {
        guard !history.isEmpty else {
            hud.showMessage(text: "There is no history yet.", symbol: "clock")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Clear the transcript history?"
        alert.informativeText = "This removes the last transcripts from Dot. It cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        history = []
        HistoryStore.saveEntries(history)
        lastTranscript = nil
        refreshMenu()
        // An open history window must not keep showing transcripts that no
        // longer exist. The clear can come from the window itself or from the
        // menu while the window is up; both refresh it in place.
        if refreshingHistory || isHistoryWindowVisible {
            presentHistory()
        }
        hud.showMessage(text: "The history is clear.", symbol: "checkmark.circle")
        Log.shared.info("history.cleared")
    }

    // MARK: - Devices and language

    private func selectMicrophone(_ id: String?) {
        guard state != .recording else {
            hud.showMessage(text: "The microphone cannot change during a recording.", symbol: "mic.slash")
            return
        }
        config.microphoneDeviceUID = id
        saveConfiguration()
        refreshMenu()
        let name = MicrophoneDirectory.options(
            devices: MicrophoneCatalog.devices(),
            configuredUID: id
        ).first { $0.uid == id }?.name ?? MicrophoneDirectory.systemDefaultName
        hud.showMessage(text: "Microphone: \(name)", symbol: "mic")
        Log.shared.info("microphone.changed", ["device": .string(id ?? "system")])
    }

    private func selectLanguage(_ id: String) {
        guard state != .recording else {
            hud.showMessage(text: "The language cannot change during a recording.", symbol: "globe")
            return
        }
        var settings = config.settings(for: config.provider)
        settings.language = id == "auto" ? nil : id
        config.providers[config.provider] = settings
        saveConfiguration()
        rebuildProvider()
        refreshMenu()
        let currentModel = config.settings(for: config.provider).model
        let name = ProviderLanguageCatalog.languages(for: config.provider, model: currentModel).first { $0.id == id }?.name ?? id
        hud.showMessage(text: "Language: \(name)", symbol: "globe")
        Log.shared.info("language.changed", ["language": .string(id)])
    }

    // MARK: - Providers

    /// Builds the provider the configuration selects.
    private func rebuildProvider() {
        providerSignature = ProviderSignature(provider: config.provider, providers: config.providers)
        refreshReadyCard()
        do {
            provider = try ProviderRegistry.selectedProvider(config: config, credentials: credentials)
            Log.shared.info("provider.selected", ["provider": .string(provider?.id ?? "")])
        } catch {
            provider = nil
            Log.shared.error("provider.failed", ["error": .string(error.localizedDescription)])
        }
    }

    /// Whether a provider can be used right now.
    ///
    /// The answer is cached: it is refreshed every few seconds and whenever
    /// the provider changes, so a press never waits for a network round trip.
    private var availability: [String: Bool] = [:]

    private func providerIsAvailable(_ provider: any Provider) -> Bool {
        availability[provider.id] ?? true
    }

    /// Asks every provider whether it can be used, and fills the menu.
    private func startProviderRefresh() {
        refreshProviders()
        providerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A probe never competes with a recording or a transcription:
                // it is a network round trip to every provider, and the user
                // is waiting for words, not for a menu.
                guard self.state == .idle else { return }
                self.refreshProviders()
            }
        }
    }

    /// Resolves the keys once, off the main actor.
    ///
    /// A decrypting `SecItemCopyMatching` blocks for as long as the Keychain
    /// takes — on a re-signed build this was measured at about fourteen
    /// seconds — so the one read a session needs happens here, on a background
    /// task, instead of inside a frame.
    private func warmCredentials() {
        let credentials = self.credentials
        Task.detached(priority: .userInitiated) { [weak self] in
            credentials.warm(ProviderRegistry.builtInIDs)
            await MainActor.run {
                guard let self else { return }
                self.rebuildProvider()
                self.refreshProviders()
                self.refreshReadyCard()
            }
        }
    }

    /// Fills the menu's provider rows and asks every provider whether it can be
    /// used, off the main actor.
    ///
    /// The rows come from ``MenuBuilder/providerRows(config:hasKey:)``, so the
    /// menu offers exactly what the Settings picker offers. Nothing here
    /// decrypts a key: the probe that answers "is a key stored" asks the
    /// Keychain for attributes only.
    ///
    /// That probe is cheap, until the Keychain is waiting for its own
    /// authorization prompt after a re-signed build. Then the item's lock is
    /// held by that prompt and even an attribute read waits on it, so running
    /// this from the main actor froze the launch, island and all.
    private func refreshProviders() {
        let current = config
        let credentials = self.credentials
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = MenuBuilder.providerRows(config: current) { id in
                CredentialStore.hasKey(for: id)
            }

            let available = await ProviderRegistry.availableProviders(
                config: current,
                credentials: credentials
            )

            var map: [String: Bool] = [:]
            for provider in available {
                map[provider.id] = true
            }

            await MainActor.run {
                guard let self else { return }
                self.providers = entries
                self.availability = map
                self.refreshMenu()
            }
        }
    }

    private func selectPreset(_ id: String) {
        guard let preset = ProviderPreset.preset(id: id) else { return }
        guard id != ProviderPreset.presenting(config).id else { return }
        guard state != .recording else {
            hud.showMessage(text: "The service cannot change during a recording.", symbol: "waveform")
            return
        }
        preset.apply(to: &config)
        saveConfiguration()
        rebuildProvider()
        refreshProviders()
        // The row that is in use afterwards is the one that is named: a row
        // that carries no endpoint of its own leaves the stored one in place,
        // so the row that was picked is not always the row that results.
        hud.showMessage(
            text: "Provider: \(ProviderPreset.presenting(config).name)",
            symbol: "checkmark.circle"
        )
        Log.shared.info("provider.changed", ["provider": .string(config.provider)])
    }

    /// Writes an API key into the Keychain and reads it back.
    private func setAPIKey(for providerID: String) {
        let name = providerName(for: providerID)
        let prompt = SecretPrompt()
        prompt.title = "Set API key"
        prompt.explanation = "The key for \(name) is kept in the Keychain, never in the configuration file."
        prompt.completion = { [weak self] secret in
            guard let self, let secret else { return }
            do {
                try CredentialStore.write(secret, providerID: providerID)
                // The key is verified by reading it back. The read goes through
                // the session cache, so the verification is also the one read
                // the rest of the session will use.
                credentials.invalidate(providerID)
                let readBack = credentials.key(for: providerID)
                guard readBack == secret else {
                    throw ProviderError.invalidResponse("the Keychain did not give the key back")
                }
                // Defense in depth: if the key ever reached a log line by
                // mistake, the logger would write stars instead.
                Log.shared.registerSecret(secret)
                Log.shared.info("credential.stored", ["provider": .string(providerID)])
                // The key belongs to the service the user chose, so nothing is
                // inferred from it and no endpoint is rewritten. The provider
                // is rebuilt even when the configuration did not change: the
                // instance built before the save does not carry the new key
                // yet.
                self.rebuildProvider()
                self.refreshProviders()
                self.hud.showMessage(
                    text: "Key saved. Using \(self.selectedProviderName).",
                    symbol: "key"
                )
            } catch {
                Log.shared.error("credential.failed", ["provider": .string(providerID)])
                self.hud.showMessage(text: error.localizedDescription, action: nil)
            }
        }
        secretPrompt = prompt
        prompt.begin()
    }

    /// Selects the service the user picked in Welcome and stores its key.
    ///
    /// The choice arrives whole: the row says which provider to select and
    /// which endpoint and model it carries, so nothing here reads the key to
    /// guess where it belongs. The key is only ever passed to
    /// ``CredentialStore`` and the logger's redaction list. It is never
    /// printed, logged or written into the configuration. A Keychain failure
    /// leaves the configuration untouched.
    ///
    /// - Parameters:
    ///   - preset: the row the user picked.
    ///   - secret: the key, empty when the row needs none.
    /// - Returns: what the view shows.
    private func connect(_ preset: ProviderPreset, key secret: String) -> ProviderConnectionResult {
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if preset.key == .none {
            preset.apply(to: &config)
            saveConfiguration()
            rebuildProvider()
            refreshProviders()
            refreshMenu()
            Log.shared.info("provider.changed", ["provider": .string(config.provider)])
            return ProviderConnectionResult.make(preset, keyStored: false, config: config)
        }
        guard !key.isEmpty else {
            return .failure("Paste a key first.", providerName: preset.name)
        }
        do {
            try CredentialStore.write(key, providerID: preset.providerID)
            credentials.invalidate(preset.providerID)
            guard credentials.key(for: preset.providerID) == key else {
                return .failure(
                    "The Keychain did not give the key back.",
                    providerName: preset.name
                )
            }
            // Defense in depth: if the key ever reached a log line by mistake,
            // the logger writes stars instead.
            Log.shared.registerSecret(key)
            preset.apply(to: &config)
            saveConfiguration()
            // The provider built before the save does not carry the new key.
            rebuildProvider()
            refreshProviders()
            refreshMenu()
            Log.shared.info("credential.stored", [
                "provider": .string(preset.providerID),
                "preset": .string(preset.id),
            ])
            return ProviderConnectionResult.make(preset, keyStored: true, config: config)
        } catch {
            Log.shared.error("credential.failed", ["provider": .string(preset.providerID)])
            return .failure(error.localizedDescription, providerName: preset.name)
        }
    }

    // MARK: - Windows

    private func openHistory() {
        presentHistory()
    }

    /// Shows the current history, replacing the content of an open window.
    private func presentHistory() {
        historyController.show(
            history: history.map(\.text),
            recordHotkey: config.hotkey,
            onCopy: { [weak self] text in self?.copyHistory(text) },
            onClear: { [weak self] in self?.confirmClearHistory(refreshingHistory: true) }
        )
    }

    /// Whether the history window is on screen.
    ///
    /// `DotWindowHost` does not report its visibility, but the window keeps
    /// the title it was created with, so the window list is enough to know
    /// whether a clear has to refresh a window the user can see.
    private var isHistoryWindowVisible: Bool {
        NSApp.windows.contains { $0.title == "History" && $0.isVisible }
    }

    private func openWelcome() {
        // Closing the window counts as having seen the welcome, whichever way it
        // was closed. The explicit finish action also writes the flag.
        welcomeController.onDismiss = { [weak self] in self?.markWelcomeSeen() }
        welcomeController.show(
            presets: ProviderPreset.rows(for: config),
            selectedPresetID: ProviderPreset.presenting(config).id,
            providerReady: selectedProviderIsReady,
            microphoneStatus: Self.describe(AVCaptureDevice.authorizationStatus(for: .audio)),
            accessibilityGranted: Paste.accessibilityGranted,
            shortcutLabel: config.hotkey.keycapLabel,
            recordingMode: config.recordingMode,
            onEnableMicrophone: { [weak self] in
                guard let self else { return "unknown" }
                return await self.requestMicrophoneAccess()
            },
            onChangeShortcut: { [weak self] in
                self?.chooseShortcut()
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onConnect: { [weak self] preset, key in
                guard let self else {
                    return .failure("Dot is not running.", providerName: preset.name)
                }
                return self.connect(preset, key: key)
            },
            onFinish: { [weak self] in
                self?.markWelcomeSeen()
            }
        )
    }

    /// Asks macOS for the microphone without starting a recording.
    private func requestMicrophoneAccess() async -> String {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.shared.info("microphone.answered", ["granted": .bool(granted)])
        }
        let status = Self.describe(AVCaptureDevice.authorizationStatus(for: .audio))
        Log.shared.info("microphone.status", ["status": .string(status)])
        return status
    }

    /// Records that the welcome will not open by itself again.
    ///
    /// Closing the window with the traffic lights deliberately does not call
    /// this: only the window's own finish action writes the flag.
    private func markWelcomeSeen() {
        UserDefaults.standard.set(true, forKey: Self.welcomedKey)
        Log.shared.info("welcome.finished")
    }

    /// The name of the selected provider, even when it cannot be built yet.
    ///
    /// A selection is named after the row that presents it, not after the
    /// implementation type: the menu says what the person picked. A provider id
    /// with no offered row — one an earlier build wrote — is named the custom
    /// endpoint the picker shows it as.
    private var selectedProviderName: String {
        ProviderPreset.presenting(config).name
    }

    /// The name of the service a key belongs to.
    ///
    /// The menu offers the key action for the row in use, so that row names it.
    /// Falling back to the first row with the provider id would name the
    /// service by whichever row happens to be listed first: every
    /// OpenAI-compatible row shares one provider id.
    private func providerName(for providerID: String) -> String {
        if providerID == config.provider { return selectedProviderName }
        return ProviderPreset.declared.first { $0.providerID == providerID }?.name ?? providerID
    }

    /// Whether the selected provider has everything it needs right now.
    private var selectedProviderIsReady: Bool {
        guard let entry = providers.first(where: {
            $0.presetID == ProviderPreset.presenting(config).id
        }),
              !entry.needsKey || entry.hasKey,
              let provider
        else { return false }
        return providerIsAvailable(provider)
    }

    /// The version this build reports, read from the bundle.
    private static var version: String { ProductVersion.current }

    // MARK: - Settings

    private func openSettings(tab: Int = 0) {
        let binding = Binding<DotConfig>(
            get: { [weak self] in self?.config ?? DotConfig.load() },
            set: { [weak self] value in
                guard let self, value != self.config else { return }
                self.changeArrivedAt = CACurrentMediaTime()
                self.config = value
                self.scheduleConfigurationSave()
            }
        )
        let currentProviders = providers
        settingsController.show(
            config: binding,
            providers: currentProviders,
            tab: tab,
            onChange: { [weak self] in
                guard let self else { return }
                let started = CACurrentMediaTime()
                self.hud.dwell = self.config.hudDwellSeconds
                self.hud.visualizer = self.config.hudVisualizer
                self.hud.material = self.config.hudMaterial
                // A shorter history takes effect now rather than on the next
                // dictation: the window is open on the list being shortened.
                if self.history.count > self.config.historyLimit {
                    self.history = Array(self.history.prefix(self.config.historyLimit))
                    HistoryStore.saveEntries(self.history, limit: self.config.historyLimit)
                    self.refreshMenu()
                }
                // The mode is read again on every press and release, so a switch
                // needs no wiring to take effect; the line exists so a log can
                // say which interaction was in force when a recording ran.
                if self.appliedRecordingMode != self.config.recordingMode {
                    self.appliedRecordingMode = self.config.recordingMode
                    Log.shared.info("recording.mode.changed", [
                        "mode": .string(self.config.recordingMode.rawValue),
                    ])
                }
                self.applyCalibration(for: MicrophoneCatalog.recordingDeviceUID(
                    configured: self.config.microphoneDeviceUID
                ))
                // Asking for a material or visualizer is asking to see it. Without
                // this the tile only moves its own selection ring and the island,
                // which is not on screen, is unchanged in every way a person can see.
                if self.config.hudMaterial != self.previewedMaterial {
                    self.previewedMaterial = self.config.hudMaterial
                    self.hud.previewMaterial(self.config.hudMaterial)
                }
                if self.config.hudVisualizer != self.previewedVisualizer {
                    self.previewedVisualizer = self.config.hudVisualizer
                    if self.state == .idle {
                        self.hud.previewVisualizer(self.config.hudVisualizer)
                    }
                }
                self.applyAppearance()
                self.refreshMenu()
                // One line, no audio and no transcript: a settings change that
                // ever costs real time shows up in the log as a number instead
                // of as a feeling.
                let milliseconds = (CACurrentMediaTime() - started) * 1000
                if milliseconds > 40 {
                    Log.shared.warn("settings.slow", ["ms": .double(milliseconds)])
                }
                // Only a change the provider is built from justifies rebuilding
                // it. A colour, a dwell or a microphone does not, and rebuilding
                // costs a probe of every provider.
                let signature = ProviderSignature(
                    provider: self.config.provider,
                    providers: self.config.providers
                )
                guard signature != self.providerSignature else { return }
                self.rebuildProvider()
                self.refreshProviders()
            },
            onSetAPIKey: { [weak self] secret, providerID in
                guard let self else { return "Dot is not running." }
                do {
                    try CredentialStore.write(secret, providerID: providerID)
                    credentials.invalidate(providerID)
                    guard credentials.key(for: providerID) == secret else {
                        return "The Keychain did not give the key back."
                    }
                    Log.shared.registerSecret(secret)
                    // The endpoint may be rewritten by the view from the same
                    // key; rebuilding here makes the new key usable even when
                    // the view keeps an explicit custom endpoint.
                    self.rebuildProvider()
                    self.refreshProviders()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onDeleteAPIKey: { [weak self] providerID in
                guard let self else { return "Dot is not running." }
                do {
                    try CredentialStore.delete(providerID: providerID)
                    self.credentials.invalidate(providerID)
                    self.rebuildProvider()
                    self.refreshProviders()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onDeleteAllAPIKeys: { [weak self] in
                guard let self else { return "Dot is not running." }
                do {
                    for preset in ProviderPreset.all {
                        try CredentialStore.delete(providerID: preset.providerID)
                    }
                    self.credentials.invalidateAll()
                    self.rebuildProvider()
                    self.refreshProviders()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onTest: { [weak self] providerID in
                guard let self,
                      let provider = try? ProviderRegistry.makeProvider(
                          id: providerID,
                          config: self.config,
                          credentials: self.credentials
                      )
                else { return false }
                return await provider.isAvailable()
            },
            onChangeShortcut: { [weak self] in
                self?.chooseShortcut()
            },
            onChangePasteShortcut: { [weak self] in
                self?.choosePasteShortcut()
            },
            onChangePaletteShortcut: { [weak self] in
                self?.choosePaletteShortcut()
            },
            onOpenWelcome: { [weak self] in
                self?.openWelcome()
            }
        )
    }

    private func toggleAutoPaste() {
        config.autoPaste.toggle()
        if config.autoPaste && !Paste.accessibilityGranted {
            Paste.requestAccessibility()
        }
        saveConfiguration()
        refreshMenu()
        hud.showMessage(
            text: config.autoPaste ? "Auto-paste on" : "Auto-paste off",
            symbol: config.autoPaste ? "doc.on.clipboard" : "doc.on.clipboard.fill"
        )
    }

    private func toggleFastRecord() {
        config.fastRecord.toggle()
        saveConfiguration()
        refreshMenu()
        hud.showMessage(
            text: config.fastRecord ? "Menu bar recording on" : "Menu bar recording off",
            symbol: config.fastRecord ? "cursorarrow.click.2" : "cursorarrow.click"
        )
    }

    private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
            refreshMenu()
            hud.showMessage(
                text: LaunchAtLogin.isEnabled ? "Dot starts at login." : "Dot no longer starts at login.",
                symbol: "power"
            )
        } catch {
            refreshMenu()
            hud.showMessage(text: error.localizedDescription, action: nil)
            Log.shared.error("loginitem.failed", ["error": .string(error.localizedDescription)])
        }
    }

    // MARK: - Shortcuts

    private func registerHotkeys() {
        hotkeys?.uninstall()
        let manager = GlobalHotkeyManager { [weak self] identifier in
            Task { @MainActor in
                guard let self else { return }
                switch identifier {
                case GlobalHotkeyManager.recordIdentifier,
                     GlobalHotkeyManager.aliasIdentifier:
                    self.hotkeyPressed()
                case GlobalHotkeyManager.pasteIdentifier:
                    self.pasteLastTranscript()
                case GlobalHotkeyManager.paletteIdentifier:
                    self.showPalette()
                default:
                    break
                }
            }
        }
        guard manager.install() else {
            Log.shared.error("hotkey.install.failed")
            return
        }
        if manager.register(config.hotkey, identifier: GlobalHotkeyManager.recordIdentifier) {
            Log.shared.info("hotkey.registered", ["hotkey": .string(config.hotkey.label), "role": .string("record")])
        } else {
            Log.shared.error("hotkey.register.failed", ["hotkey": .string(config.hotkey.label)])
            hud.showMessage(text: "macOS refused \(config.hotkey.label). Another app owns it.", action: nil)
        }
        if manager.registerAlias(config.hotkey, identifier: GlobalHotkeyManager.aliasIdentifier) {
            Log.shared.info("hotkey.alias.registered", ["hotkey": .string(config.hotkey.label)])
        }
        if manager.register(config.pasteHotkey, identifier: GlobalHotkeyManager.pasteIdentifier) {
            Log.shared.info("hotkey.registered", ["hotkey": .string(config.pasteHotkey.label), "role": .string("paste")])
        } else {
            Log.shared.error("hotkey.register.failed", ["hotkey": .string(config.pasteHotkey.label)])
        }
        if manager.register(config.paletteHotkey, identifier: GlobalHotkeyManager.paletteIdentifier) {
            Log.shared.info("hotkey.registered", ["hotkey": .string(config.paletteHotkey.label), "role": .string("palette")])
        } else {
            Log.shared.error("hotkey.register.failed", ["hotkey": .string(config.paletteHotkey.label)])
            Log.shared.warn("hotkey.role.unavailable", ["role": .string("palette")])
        }
        hotkeys = manager
        // The watcher reads the keyboard state of the key that was just bound.
        // A rebind moves the key, so the watcher moves with it: otherwise the
        // release of hold mode — and the secure-input report — would keep
        // reading the combination the person no longer uses.
        if state != .recording {
            keyWatcher.watch(keyCode: config.hotkey.keyCode)
        }
        refreshMenu()
    }

    /// Which global shortcut the recorder is setting.
    private enum ShortcutRole: Equatable {
        case record
        case paste
        case palette

        var title: String {
            switch self {
            case .record: "Set Record Shortcut"
            case .paste: "Set Paste Shortcut"
            case .palette: "Set Palette Shortcut"
            }
        }

        var logName: String {
            switch self {
            case .record: "record"
            case .paste: "paste"
            case .palette: "palette"
            }
        }

        var messageName: String {
            switch self {
            case .record: "Shortcut"
            case .paste: "Paste shortcut"
            case .palette: "Palette shortcut"
            }
        }
    }

    private func chooseShortcut() {
        chooseShortcut(for: .record)
    }

    private func choosePasteShortcut() {
        chooseShortcut(for: .paste)
    }

    private func choosePaletteShortcut() {
        chooseShortcut(for: .palette)
    }

    /// Opens the shortcut recorder for one of the two global shortcuts.
    ///
    /// The other shortcut is refused while one is typed, so the record and
    /// paste shortcuts can never end up on the same combination.
    private func chooseShortcut(for role: ShortcutRole) {
        guard shortcutRecorder == nil else { return }
        // Dot's own shortcuts must not answer while a new one is typed.
        hotkeys?.unregisterAll()
        let recorder = ShortcutRecorder()
        recorder.title = role.title
        recorder.inUse = Self.otherHotkeys(than: role, config: config)
        shortcutRecorder = recorder
        recorder.completion = { [weak self] result in
            guard let self else { return }
            self.shortcutRecorder = nil
            switch result {
            case .success(let hotkey):
                switch role {
                case .record: self.config.hotkey = hotkey
                case .paste: self.config.pasteHotkey = hotkey
                case .palette: self.config.paletteHotkey = hotkey
                }
                self.saveConfiguration()
                self.registerHotkeys()
                self.hud.showMessage(
                    text: "\(role.messageName) set to \(hotkey.label)",
                    action: nil
                )
                Log.shared.info("hotkey.changed", [
                    "hotkey": .string(hotkey.label),
                    "role": .string(role.logName),
                ])
            case .failure(let rejection):
                if case .unsupportedKey = rejection {
                    self.registerHotkeys()
                    return
                }
                self.registerHotkeys()
                self.hud.showMessage(text: rejection.localizedDescription, action: nil)
                Log.shared.warn("hotkey.rejected", ["reason": .string(rejection.localizedDescription)])
            }
        }
        recorder.begin()
    }

    /// The shortcuts a new one must not collide with.
    ///
    /// All three are Dot's, and two of them can be on the same combination
    /// without Carbon telling anyone: the second registration simply never
    /// fires.
    private static func otherHotkeys(
        than role: ShortcutRole,
        config: DotConfig
    ) -> [Hotkey] {
        switch role {
        case .record: [config.pasteHotkey, config.paletteHotkey]
        case .paste: [config.hotkey, config.paletteHotkey]
        case .palette: [config.hotkey, config.pasteHotkey]
        }
    }

    // MARK: - Configuration

    /// Applies the window appearance the configuration selects.
    ///
    /// The HUD is deliberately left alone: its ink surface is part of its
    /// identity and never follows the windows.
    private func applyAppearance() {
        guard appliedAppearance != config.appearance else { return }
        appliedAppearance = config.appearance
        let appearance: NSAppearance? = switch config.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
        // Every open window is given the appearance and told to draw now. The
        // app-wide value alone waits for the next event to reach a window that
        // is already on screen, which is why a theme change looked like it took
        // seconds to arrive: it arrived on the next mouse move.
        for window in NSApp.windows where !(window is HUDPanel) {
            window.appearance = appearance
            window.contentView?.needsDisplay = true
            window.invalidateShadow()
            window.displayIfNeeded()
        }
        if let arrived = changeArrivedAt {
            changeArrivedAt = nil
            let now = CACurrentMediaTime()
            var fields: [String: LogValue] = [
                "mode": .string(config.appearance.rawValue),
                "ms": .double((now - arrived) * 1000)
            ]
            if let pick = AppearanceTrace.pickAt {
                fields["click_ms"] = .double((now - pick) * 1000)
            }
            AppearanceTrace.pickAt = nil
            Log.shared.info("appearance.applied", fields)
        }
    }

    /// Watches a file that toggles the recording.
    ///
    /// `DOT_TEST_TRIGGER` (or the spelling under the old prefix) points at a
    /// file; when the file appears the
    /// recording starts, when it appears again the recording stops. It is how
    /// the end-to-end test drives the app when the machine's keyboard cannot
    /// be used — a locked screen swallows synthetic key events. The trigger is
    /// off unless the variable is set.
    private func installTestTrigger() {
        guard let path = DotMigration.environment("TEST_TRIGGER") else { return }
        // The trigger is a developer tool, and it is the one thing that can
        // start a recording without the user asking. It is only honoured when
        // the binary was started with the explicit flag, so a stale variable
        // in an installed app can never open the microphone.
        guard CommandLine.arguments.contains("--allow-test-trigger") else {
            Log.shared.warn("test.trigger.refused", ["path": .string(path)])
            return
        }
        triggerURL = URL(fileURLWithPath: path)
        // A trigger left over from the previous run must not fire at launch.
        try? FileManager.default.removeItem(at: triggerURL!)
        triggerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let url = self.triggerURL else { return }
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                try? FileManager.default.removeItem(at: url)
                Log.shared.info("test.trigger.toggled")
                self.toggleRecording()
            }
        }
        Log.shared.info("test.trigger.enabled", ["path": .string(path)])
    }

    private func saveConfiguration() {
        // A queued save is superseded: this one writes the current values.
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try config.save()
        } catch {
            Log.shared.error("config.save.failed", ["error": .string(error.localizedDescription)])
        }
    }

    /// Writes the configuration once the typing has stopped.
    ///
    /// A text field writes its value on every keystroke. Saving on each one
    /// touched the disk dozens of times for one word, so a settings field
    /// waited on the file it was editing. Everything that changes behaviour
    /// rather than text still saves immediately.
    private func scheduleConfigurationSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.saveConfiguration()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func logConfiguration() {
        Log.shared.info("config.loaded", [
            "hotkey": .string(config.hotkey.label),
            "paste_hotkey": .string(config.pasteHotkey.label),
            "provider": .string(config.provider),
            "auto_paste": .bool(config.autoPaste),
            "hud_dwell_s": .double(config.hudDwellSeconds),
            "hud_dwell_revision": .int(config.hudDwellRevision),
            "max_segment_s": .int(config.maxSegmentSeconds),
            "material": .string(config.hudMaterial.rawValue),
            "recording_mode": .string(config.recordingMode.rawValue),
            "accessibility": .bool(Paste.accessibilityGranted),
            "history": .int(history.count),
        ])
    }
}
