import AppKit
import DotCore
import SwiftUI
import XCTest

@testable import Dot

/// The service picker on the Speech to text page, driven through its binding.
///
/// The reported defect was a pick that changed nothing on screen: the window
/// held a binding whose storage was a plain property, so a write did not redraw
/// the page and the save and the provider rebuild waited for an unrelated
/// redraw. These tests host the page with a real ``ConfigStore`` and pick
/// through the same binding the control writes, so a regression to a
/// non-observable configuration fails here.
@MainActor
final class SettingsSelectionTests: XCTestCase {
    /// One hosted page, its store and the counters the app wires to the same
    /// hooks.
    @MainActor
    private final class Harness {
        let store: ConfigStore
        let host: NSHostingView<AnyView>
        let tally: Tally
        let credentials: SpeechCredentialChecks
        let keyField: KeyField
        private let view: SettingsView

        init(
            config: DotConfig,
            setKey: @escaping (String, String) -> String? = { _, _ in nil },
            cache: CredentialCache = .shared,
            checkCache: any CredentialCheckCaching = CredentialCheckCache(),
            runsChecks: Bool = false,
            keyField: KeyField = KeyField(),
            modelPreview: [AvailableModel]? = nil
        ) {
            let store = ConfigStore(config: config)
            let credentials = SpeechCredentialChecks(cache: cache, checkCache: checkCache)
            let tally = Tally()
            self.credentials = credentials
            self.store = store
            self.tally = tally
            self.keyField = keyField
            store.onWrite = { tally.writes += 1 }
            let providers = MenuBuilder.providerRows(config: config) { _ in false }
            let view = SettingsView(
                store: store,
                providers: providers,
                tab: 1,
                onChange: { tally.changes += 1 },
                onSetAPIKey: setKey,
                onChangeShortcut: {},
                modelPreview: modelPreview,
                credentials: credentials,
                allowsOffscreenChecks: runsChecks,
                keyField: keyField
            )
            self.view = view
            let host = NSHostingView(rootView: AnyView(view.environment(\.settingsHeadless, true)))
            host.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
            self.host = host
            for _ in 0 ..< 3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }

        /// Picks a row the way the dropdown does: through the page's binding.
        func pick(_ id: String) {
            view.serviceBinding.wrappedValue = id
        }

        /// Puts text in the key field the way a person types it.
        func type(_ text: String) {
            keyField.text = text
        }

        /// Saves a key the way Connect does, without a keyboard.
        func save(_ secret: String) {
            view.save(secret: secret)
        }
    }

    /// A check cache that answers every question and keeps the names it was
    /// asked under.
    ///
    /// Answering from the cache is what keeps these tests off the network: the
    /// name a check builds is made from exactly the inputs its request would
    /// carry, so the list of names is the list of keys the page asked about.
    private actor RecordingCheckCache: CredentialCheckCaching {
        private var entries: [String] = []
        private let answer: CredentialCheck
        private let checkedAt: Date

        init(answer: CredentialCheck = .verified, checkedAt: Date = Date()) {
            self.answer = answer
            self.checkedAt = checkedAt
        }

        func result(for entry: String, now: Date) async -> CredentialCheckRecord? {
            entries.append(entry)
            return CredentialCheckRecord(check: answer, checkedAt: checkedAt)
        }

        func store(_ check: CredentialCheck, for entry: String, at date: Date) async {}

        func remove(_ entry: String) async {}

        /// The names the page has asked about, in the order it asked.
        func recorded() -> [String] { entries }
    }

    /// Counts how many times a test's Keychain reader was asked.
    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0

        func increment() {
            lock.lock()
            reads += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }
    }

    /// Counters shared by the two hooks a window installs.
    private final class Tally: @unchecked Sendable {
        var changes = 0
        var writes = 0
    }

    /// The recorded state before a pick.
    private struct Baseline {
        let changes: Int
        let writes: Int
    }

    func testEveryPickTakesEffectAndNotifiesOnce() throws {
        let harness = try makeHarness()
        let picks: [(id: String, provider: String, name: String)] = [
            ("on-device", ProviderIdentifier.apple, "Apple Speech"),
            ("groq", ProviderIdentifier.groq, "Groq"),
            ("on-device", ProviderIdentifier.apple, "Apple Speech"),
            ("xiaomi", ProviderIdentifier.xiaomi, "Xiaomi ASR"),
        ]

        for pick in picks {
            let before = Baseline(changes: harness.tally.changes, writes: harness.tally.writes)
            harness.pick(pick.id)
            let landed = settle(harness.host, until: {
                harness.store.config.provider == pick.provider
                    && self.serviceTitle(in: harness.host) == pick.name
                    && harness.tally.changes == before.changes + 1
            })
            XCTAssertTrue(landed, "picking \(pick.name) did not land on the page")
            XCTAssertEqual(
                harness.store.config.provider,
                pick.provider,
                "the store kept the previous provider after picking \(pick.name)"
            )
            XCTAssertEqual(
                serviceTitle(in: harness.host),
                pick.name,
                "the trigger still draws a stale row after picking \(pick.name)"
            )
            XCTAssertEqual(
                harness.tally.changes,
                before.changes + 1,
                "one pick ran the change closure \(harness.tally.changes - before.changes) times"
            )
            XCTAssertEqual(
                harness.tally.writes,
                before.writes + 1,
                "one pick scheduled \(harness.tally.writes - before.writes) saves"
            )
        }
    }

    func testASecondPickOfTheSameRowNotifiesNothing() throws {
        let harness = try makeHarness()
        harness.pick("on-device")
        XCTAssertTrue(
            settle(harness.host, until: { harness.store.config.provider == ProviderIdentifier.apple }),
            "the first pick did not land"
        )
        let changes = harness.tally.changes
        let writes = harness.tally.writes

        harness.pick("on-device")
        let quiet = settle(harness.host, until: { harness.tally.changes == changes }, within: 0.6)
        XCTAssertTrue(quiet, "the window is still changing after a pick that changes nothing")
        XCTAssertEqual(harness.tally.changes, changes, "a repeat pick ran the change closure again")
        XCTAssertEqual(harness.tally.writes, writes, "a repeat pick scheduled a second save")
        XCTAssertEqual(harness.store.config.provider, ProviderIdentifier.apple)
    }

    /// The change closure each write runs must not write the configuration it
    /// was told about, or one press would notify twice.
    ///
    /// The closure here performs the same reads the app's own closure performs
    /// and keeps its results outside the store, which is the shape the app has:
    /// a colour, a dwell and a mode are copied out, and nothing is written back.
    func testTheChangeClosureIsNotReenteredByItsOwnWork() throws {
        let store = ConfigStore(config: .default)
        var changes = 0
        var writes = 0
        var observed: [String] = []
        store.onWrite = { writes += 1 }
        let mirror = MirrorBox()
        let view = SettingsView(
            store: store,
            providers: MenuBuilder.providerRows(config: store.config) { _ in false },
            tab: 1,
            onChange: {
                changes += 1
                observed.append(store.config.provider)
                mirror.dwell = store.config.hudDwellSeconds
                mirror.material = store.config.hudMaterial
                mirror.mode = store.config.recordingMode
            },
            onSetAPIKey: { _, _ in nil },
            onChangeShortcut: {}
        )
        let host = NSHostingView(rootView: AnyView(view.environment(\.settingsHeadless, true)))
        host.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        store.config.hudMaterial = .black
        XCTAssertTrue(
            settle(host, until: { changes == 1 }),
            "the closure did not run for a write"
        )
        // Two more runloop turns: a closure that had written the configuration
        // would have produced a second notification by now.
        _ = settle(host, until: { false }, within: 0.4)
        XCTAssertEqual(changes, 1, "the change closure ran itself again")
        XCTAssertEqual(writes, 1, "the store reported the write twice")
        XCTAssertEqual(mirror.material, .black, "the closure did not see the value that was written")
        XCTAssertEqual(observed, [ProviderIdentifier.openAI], "the closure saw a provider it did not write")
    }

    /// The state a refused Keychain write produces, and how the page shows it.
    func testAKeyNotSavedStateCarriesTheRefusalsOwnWords() {
        let refusal = "The Keychain did not give the key back."
        let status = SpeechCredentialStatus.notSaved(refusal)
        XCTAssertEqual(status.title, "Key not saved")
        XCTAssertEqual(status.message, refusal)
        XCTAssertFalse(status.isChecking, "a refusal is not a request in flight")

        let checks = SpeechCredentialChecks()
        checks.markNotSaved(refusal)
        XCTAssertEqual(checks.status, .notSaved(refusal))
        checks.clearNotSaved()
        XCTAssertEqual(checks.status, .checking, "the refusal survived the next question about the key")
    }

    /// A key edit is the next question about the key, so it drops the refusal.
    func testAnEditDropsTheRefusal() {
        let checks = SpeechCredentialChecks()
        checks.markNotSaved("The Keychain did not give the key back.")
        checks.check(
            providerID: ProviderIdentifier.openAI,
            config: .default,
            typedKey: "sk-test-key-0123456789abcdef",
            serviceName: "OpenAI",
            requiresKey: true,
            immediate: false
        )
        XCTAssertEqual(checks.status, .checking, "an edit left the Keychain refusal on the page")
        checks.cancel()
    }

    /// The page says the Keychain refused the key, with the writer's words.
    func testARefusedKeySaveIsShownOnThePage() throws {
        let refusal = "The Keychain did not give the key back."
        let harness = Harness(config: keyedConfig(), setKey: { _, _ in refusal })
        harness.save("sk-test-key-0123456789abcdef")

        let status = harness.credentials.status
        XCTAssertEqual(status.title, "Key not saved", "the label does not say the key was not saved")
        XCTAssertEqual(status.message, refusal, "the label's tooltip is not the writer's own words")
        XCTAssertEqual(status, .notSaved(refusal))
        XCTAssertEqual(
            harness.store.config.provider,
            ProviderIdentifier.openAI,
            "a refused key changed the configuration"
        )
        XCTAssertEqual(harness.tally.writes, 0, "a refused key wrote the configuration")
    }

    /// The next successful save replaces the refusal.
    func testASavedKeyReplacesTheRefusalOnThePage() throws {
        let refusal = "The Keychain did not give the key back."
        let harness = Harness(config: keyedConfig(), setKey: { _, _ in refusal })
        harness.save("sk-test-key-0123456789abcdef")
        XCTAssertEqual(harness.credentials.status, .notSaved(refusal), "the refusal was never shown")

        let saved = Harness(config: keyedConfig(), setKey: { _, _ in nil })
        saved.save("sk-test-key-0123456789abcdef")
        XCTAssertNotEqual(
            saved.credentials.status,
            .notSaved(refusal),
            "a saved key kept the Keychain refusal on the page"
        )
        XCTAssertNotEqual(saved.credentials.status.title, "Key not saved")
    }

    /// A pick whose row has gone is recorded, not dropped in silence.
    ///
    /// The panel resolves a click by index into the list it opened, so a click
    /// that arrives after the configuration moved on names a row that is no
    /// longer there. The log is the only evidence that the click happened.
    func testADroppedPickIsRecordedAndChangesNothing() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-pick-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(Log.fileName)
        XCTAssertTrue(Log.shared.openFile(at: url), "the log could not be opened")

        let harness = try makeHarness()
        harness.pick("no-such-row")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("settings.pick.dropped"), "a dropped pick left no trace")
        XCTAssertTrue(text.contains("no-such-row"), "the line does not name the row that was dropped")
        XCTAssertEqual(harness.store.config.provider, ProviderIdentifier.xiaomi, "a dropped pick changed the provider")
        XCTAssertEqual(harness.tally.changes, 0)
        XCTAssertEqual(harness.tally.writes, 0)
    }

    // MARK: - The key a check carries

    /// A pick is a new service even when both rows write the same provider id.
    ///
    /// The custom row and the shipped row it stands in for both write `openai`,
    /// so a check started by the pick used to carry the key typed for the
    /// custom row to the shipped address. The page is asked about its stored
    /// key first, then text is typed into the field, which is the state a
    /// person's keyboard produces. A check names its question after a digest of
    /// the key it will send, so the name it asks the cache under is exactly the
    /// key the request would carry.
    func testAPickDropsTheTypedKeyForTheRowItReplaces() async throws {
        let storedKey = "sk-stored-0123456789abcdef"
        let typedKey = "sk-typed-0123456789abcdef"
        let local = "http://127.0.0.1:9/v1"

        var config = DotConfig.default
        var settings = config.settings(for: ProviderIdentifier.openAI)
        settings.baseURL = local
        settings.language = nil
        config.providers[ProviderIdentifier.openAI] = settings
        config.provider = ProviderIdentifier.openAI

        let recording = RecordingCheckCache()
        let harness = Harness(
            config: config,
            cache: seededKey(storedKey, for: ProviderIdentifier.openAI),
            checkCache: recording,
            runsChecks: true
        )
        let style = settings.authStyle?.rawValue

        // The page must be live before the keyboard is: a value present at the
        // first body evaluation is the starting value, not an edit.
        let storedForCustom = CredentialCheckCache.entry(
            providerID: ProviderIdentifier.openAI,
            baseURL: local,
            authStyle: style,
            credential: storedKey
        )
        let askedOnAppear = await waitFor {
            let names = await recording.recorded()
            return names.contains(storedForCustom)
        }
        XCTAssertTrue(askedOnAppear, "the page never asked about the row it opened on")

        harness.type(typedKey)
        let typedForCustom = CredentialCheckCache.entry(
            providerID: ProviderIdentifier.openAI,
            baseURL: local,
            authStyle: style,
            credential: typedKey
        )
        let askedWithTypedKey = await waitFor {
            let names = await recording.recorded()
            return names.contains(typedForCustom)
        }
        XCTAssertTrue(
            askedWithTypedKey,
            "the unsaved text never reached a check, so the pick below could not have carried it"
        )

        let before = await recording.recorded().count
        harness.pick("openai")
        let askedAfterPick = await waitFor {
            let names = await recording.recorded()
            return names.count > before
        }
        XCTAssertTrue(askedAfterPick, "the pick asked nothing")

        let shipped = "https://api.openai.com/v1"
        let shippedWithStoredKey = CredentialCheckCache.entry(
            providerID: ProviderIdentifier.openAI,
            baseURL: shipped,
            authStyle: style,
            credential: storedKey
        )
        let shippedWithTypedKey = CredentialCheckCache.entry(
            providerID: ProviderIdentifier.openAI,
            baseURL: shipped,
            authStyle: style,
            credential: typedKey
        )
        let asked = Array(await recording.recorded().dropFirst(before))
        XCTAssertEqual(
            asked.first,
            shippedWithStoredKey,
            "the pick asked the shipped row with the key typed for the custom row"
        )
        XCTAssertFalse(asked.contains(typedForCustom), "the typed key survived the pick")
        XCTAssertFalse(
            asked.contains(shippedWithTypedKey),
            "the typed key was sent to the row that replaced its own"
        )
        XCTAssertEqual(
            harness.store.config.provider,
            ProviderIdentifier.openAI,
            "the pick did not move the configuration"
        )
    }

    /// Changing the header the key travels in is a new question.
    ///
    /// The same key, address and provider answer differently when the header
    /// changes: one header is refused where the other is accepted. The page
    /// asks again instead of reusing an answer to the other question.
    func testAnAuthHeaderChangeIsAskedAgain() async throws {
        let storedKey = "sk-stored-0123456789abcdef"
        let local = "http://127.0.0.1:9/v1"

        var config = DotConfig.default
        var settings = config.settings(for: ProviderIdentifier.openAI)
        settings.baseURL = local
        settings.language = nil
        settings.authStyle = .bearer
        config.providers[ProviderIdentifier.openAI] = settings
        config.provider = ProviderIdentifier.openAI

        let recording = RecordingCheckCache()
        let harness = Harness(
            config: config,
            cache: seededKey(storedKey, for: ProviderIdentifier.openAI),
            checkCache: recording,
            runsChecks: true
        )

        let bearer = CredentialCheckCache.entry(
            providerID: ProviderIdentifier.openAI,
            baseURL: local,
            authStyle: AuthStyle.bearer.rawValue,
            credential: storedKey
        )
        let askedBearer = await waitFor {
            let names = await recording.recorded()
            return names.contains(bearer)
        }
        XCTAssertTrue(askedBearer, "the bearer question was never asked")

        var changed = harness.store.config.settings(for: ProviderIdentifier.openAI)
        changed.authStyle = .apiKey
        harness.store.config.providers[ProviderIdentifier.openAI] = changed

        let apiKey = CredentialCheckCache.entry(
            providerID: ProviderIdentifier.openAI,
            baseURL: local,
            authStyle: AuthStyle.apiKey.rawValue,
            credential: storedKey
        )
        let askedApiKey = await waitFor {
            let names = await recording.recorded()
            return names.contains(apiKey)
        }
        XCTAssertTrue(
            askedApiKey,
            "a changed header reused the answer given to the other header"
        )
    }

    /// The on-device answer depends on the language, so a new language is a new
    /// question even though nothing was typed.
    func testAnOnDeviceLanguageChangeIsAskedAgain() async throws {
        var config = DotConfig.default
        var settings = config.settings(for: ProviderIdentifier.apple)
        settings.language = "en_US"
        config.providers[ProviderIdentifier.apple] = settings
        config.provider = ProviderIdentifier.apple

        let recording = RecordingCheckCache()
        let harness = Harness(config: config, checkCache: recording, runsChecks: true)

        let askedEnglish = await waitFor(within: 6) {
            let names = await recording.recorded()
            return names.contains { $0.contains("locale:en_US") }
        }
        XCTAssertTrue(askedEnglish, "the on-device row was never asked about en_US")

        var changed = harness.store.config.settings(for: ProviderIdentifier.apple)
        changed.language = "fr_FR"
        harness.store.config.providers[ProviderIdentifier.apple] = changed

        let askedFrench = await waitFor(within: 6) {
            let names = await recording.recorded()
            return names.contains { $0.contains("locale:fr_FR") }
        }
        XCTAssertTrue(
            askedFrench,
            "a changed on-device language reused the answer given for the old one"
        )
    }

    /// A key typed into the field is never reported as a stored one.
    ///
    /// The page hands the text to the check, and the check's answer is about
    /// that text; the row must say the key is not saved and put the answer in
    /// the sentence, whether the text works or is refused.
    func testATypedKeyIsReportedAsNotSavedOnThePage() async throws {
        let storedKey = "sk-stored-0123456789abcdef"
        let typedKey = "sk-typed-0123456789abcdef"
        var config = DotConfig.default
        var settings = config.settings(for: ProviderIdentifier.openAI)
        settings.baseURL = "http://127.0.0.1:9/v1"
        settings.language = nil
        config.providers[ProviderIdentifier.openAI] = settings
        config.provider = ProviderIdentifier.openAI

        let answers: [(CredentialCheck, String)] = [
            (.verified, "The key works. Save it to use it."),
            (.rejected(status: 401), "The service refused this key."),
        ]
        for (answer, message) in answers {
            let recording = RecordingCheckCache(answer: answer)
            let harness = Harness(
                config: config,
                cache: seededKey(storedKey, for: ProviderIdentifier.openAI),
                checkCache: recording,
                runsChecks: true
            )
            harness.type(typedKey)
            let answered = await waitFor { harness.credentials.status == .notSaved(message) }
            XCTAssertTrue(
                answered,
                "the page showed \(harness.credentials.status) for a typed key, not Key not saved"
            )
            XCTAssertEqual(harness.credentials.status.title, "Key not saved")
        }
    }

    /// The model picker stays usable for the ElevenLabs models this build
    /// ships, even when the key may not read the service's list.
    func testTheModelPickerIsEnabledForTheElevenLabsBuiltInList() {
        var config = DotConfig.default
        var settings = config.settings(for: ProviderIdentifier.elevenLabs)
        settings.language = nil
        config.providers[ProviderIdentifier.elevenLabs] = settings
        config.provider = ProviderIdentifier.elevenLabs

        let builtIn = ElevenLabsProvider.supportedModels.map {
            AvailableModel(id: $0.id, name: $0.title, detail: $0.detail)
        }
        let harness = Harness(config: config, modelPreview: builtIn)
        let picker = select("Model", in: harness.host)
        XCTAssertNotNil(picker, "the model picker was not drawn for the built-in list")
        XCTAssertTrue(
            picker?.isAccessibilityEnabled() == true,
            "the model picker was disabled while it had models to offer"
        )

        let options = SettingsView.modelOptions(catalog: builtIn, storedModel: nil)
        XCTAssertEqual(options.map(\.title), builtIn.map(\.name) + ["Custom model…"])
        XCTAssertEqual(options.last?.value, "__custom__", "the custom choice is not reachable")
    }

    /// A denied stored-key read is not retried while the page stays open.
    ///
    /// The read can put a Keychain prompt on screen. A person who denies it
    /// must not be asked again every time the key field pauses; the page asks
    /// once more only when it is reopened.
    func testAFailedKeychainReadIsNotRetriedWhileThePageIsOpen() async throws {
        let counter = ReadCounter()
        let cache = CredentialCache(reader: { _ in
            counter.increment()
            return .failed("The Keychain refused the read.")
        }, logsReads: false)

        var config = DotConfig.default
        var settings = config.settings(for: ProviderIdentifier.openAI)
        settings.baseURL = "http://127.0.0.1:9/v1"
        settings.language = nil
        config.providers[ProviderIdentifier.openAI] = settings
        config.provider = ProviderIdentifier.openAI

        let recording = RecordingCheckCache()
        let harness = Harness(config: config, cache: cache, checkCache: recording, runsChecks: true)

        let firstRead = await waitFor { counter.value == 1 }
        XCTAssertTrue(firstRead, "the page never read the stored key")

        harness.type("sk-typed-one-0123456789")
        let firstTyped = await waitFor {
            let entries = await recording.recorded()
            return !entries.isEmpty
        }
        XCTAssertTrue(firstTyped, "the first typing pause asked nothing")
        let firstSettled = await waitFor { harness.credentials.status.title != "Checking" }
        XCTAssertTrue(firstSettled, "the status stayed on Checking after the first typing pause")
        XCTAssertEqual(
            harness.credentials.status.title,
            "Verified",
            "a failed read was compared as if it had answered"
        )

        harness.type("sk-typed-two-0123456789")
        let secondTyped = await waitFor {
            let entries = await recording.recorded()
            return entries.count >= 2
        }
        XCTAssertTrue(secondTyped, "the second typing pause asked nothing")
        let secondSettled = await waitFor { harness.credentials.status.title != "Checking" }
        XCTAssertTrue(secondSettled, "the status stayed on Checking after the second typing pause")

        XCTAssertEqual(
            counter.value,
            1,
            "the page read the Keychain \(counter.value) times after the first read failed"
        )
        XCTAssertEqual(harness.credentials.status.title, "Verified")
    }

    // MARK: - Helpers

    /// A key reader that answers for one provider and nothing else.
    private func seededKey(_ key: String, for providerID: String) -> CredentialCache {
        CredentialCache(
            reader: { id in id == providerID ? .key(key) : .missing },
            logsReads: false
        )
    }

    /// Waits for an asynchronous state, looking between runloop turns.
    private func waitFor(
        within limit: TimeInterval = 4,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    /// A configuration whose selected row needs a key and has none stored.
    private func keyedConfig() -> DotConfig {
        var config = DotConfig.default
        var settings = config.settings(for: ProviderIdentifier.openAI)
        settings.language = nil
        config.providers[ProviderIdentifier.openAI] = settings
        return config
    }

    /// The page's starting state: no stored language, so a pick changes the
    /// provider and nothing else.
    private func makeHarness() throws -> Harness {
        var config = DotConfig.default
        // No stored language: every pickable service then keeps its own default
        // and the pick changes the provider and nothing else.
        for id in [ProviderIdentifier.xiaomi, ProviderIdentifier.groq, ProviderIdentifier.apple] {
            var settings = config.settings(for: id)
            settings.language = nil
            config.providers[id] = settings
        }
        config.provider = ProviderIdentifier.xiaomi
        let harness = Harness(config: config)
        XCTAssertEqual(harness.store.config.provider, ProviderIdentifier.xiaomi)
        return harness
    }

    @MainActor
    private final class MirrorBox {
        var dwell: Double = 0
        var material: HUDMaterial = .glass
        var mode: RecordingMode = .hold
    }

    /// The word the service trigger draws, read from the accessibility value
    /// the control publishes.
    private func serviceTitle(in view: NSView) -> String? {
        guard let element = select("Service", in: view) else { return nil }
        return element.accessibilityValue() as? String
    }

    private func select(_ label: String, in view: NSView?) -> DotSelectAccessibilityView? {
        guard let view else { return nil }
        if let element = view as? DotSelectAccessibilityView, element.accessibilityLabel() == label {
            return element
        }
        for sub in view.subviews {
            if let found = select(label, in: sub) { return found }
        }
        return nil
    }

    /// Lays the page out and runs the loop until `predicate` holds.
    ///
    /// - Parameters:
    ///   - host: the hosted page.
    ///   - predicate: the state the test waits for.
    ///   - limit: how long to watch for it.
    /// - Returns: whether the state held before the limit.
    private func settle(
        _ host: NSView,
        until predicate: @MainActor () -> Bool,
        within limit: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if predicate() { return true }
        }
        return predicate()
    }
}

///
/// The owner's complaint was that a separate subsection existed only to test a
/// connection. A string that survives in a page nobody opens is a section that
/// comes back the next time someone edits that page, so the scan is the test.
final class SpeechConnectionSourceGuardTests: XCTestCase {
    /// The package root, found from this file.
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testNoConnectionSectionOrTestControlRemainsInTheApp() throws {
        let sources = Self.root.appendingPathComponent("Sources/Dot")
        let files = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(
                text.contains("SettingsSection(\"Connection\")"),
                "\(url.lastPathComponent) still draws a Connection section"
            )
            XCTAssertFalse(
                text.contains("Test connection"),
                "\(url.lastPathComponent) still offers a Test connection control"
            )
            XCTAssertFalse(
                text.contains("onTest"),
                "\(url.lastPathComponent) still carries the onTest probe"
            )
        }
        XCTAssertGreaterThan(scanned, 40, "the scan did not reach the app's sources")
    }

    /// The Speech to text page carries one status, in the last credential card.
    ///
    /// A second row that reported the stored key's presence could disagree with
    /// the check's answer: a key that is present and refused would show
    /// "Connected" next to "Key rejected". One Status row, placed after every
    /// setup field, leaves no second answer on the page.
    func testTheSpeechPageHasOneStatusRowAtTheEndOfCredentialRows() throws {
        let url = Self.root.appendingPathComponent("Sources/Dot/SettingsView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let statusRow = try NSRegularExpression(pattern: #"SettingsRow\(\s*"Status""#)
        let range = NSRange(text.startIndex..., in: text)
        XCTAssertEqual(
            statusRow.numberOfMatches(in: text, range: range),
            1,
            "SettingsView draws more than one row titled Status"
        )

        let speechEngine = try slice(
            text,
            from: "private var speechEngineSection",
            to: "/// The picker of the speech engine"
        )
        let apiKeyPlacement = try XCTUnwrap(speechEngine.range(of: #"SettingsRow("API key""#)?.lowerBound)
        let statusPlacement = try XCTUnwrap(speechEngine.range(of: "credentialStatusRow")?.lowerBound)
        XCTAssertGreaterThan(
            statusPlacement,
            apiKeyPlacement,
            "the Status row moved above the service's key field"
        )
        XCTAssertNotNil(
            try NSRegularExpression(pattern: #"SettingsDivider\(\)\s*credentialStatusRow"#)
                .firstMatch(in: speechEngine, range: NSRange(speechEngine.startIndex..., in: speechEngine)),
            "the service card has no divider directly above its Status row"
        )
        XCTAssertFalse(
            speechEngine.contains("if !selectedPreset.hasEndpoint"),
            "the speech engine card made its Status row conditional on the endpoint card"
        )

        let endpoint = try slice(
            text,
            from: "private var endpointSection",
            to: "/// The Azure endpoint"
        )
        XCTAssertNotNil(
            endpoint.range(of: #"SettingsRow("Model""#),
            "the endpoint card lost its model field"
        )
        XCTAssertFalse(
            endpoint.contains("credentialStatusRow"),
            "the endpoint card drew a second Status row"
        )

        let statusDeclaration = try slice(
            text,
            from: "private var credentialStatusRow",
            to: "/// The row the configuration presents."
        )
        let declarationRange = NSRange(statusDeclaration.startIndex..., in: statusDeclaration)
        XCTAssertEqual(
            statusRow.numberOfMatches(in: statusDeclaration, range: declarationRange),
            1,
            "the shared status row no longer draws the Status title"
        )
        XCTAssertTrue(
            statusDeclaration.contains(".accessibilityLabel(credentialStatus.statusAccessibilityLabel)"),
            "the Status row lost its accessible name"
        )
        XCTAssertTrue(
            statusDeclaration.contains(".accessibilityValue(credentialStatus.statusAccessibilityValue)"),
            "the Status row lost its accessible value"
        )
        XCTAssertTrue(
            statusDeclaration.contains(".help(credentialStatus.message)"),
            "the whole Status row lost its tooltip"
        )
        XCTAssertFalse(text.contains("SpeechCredentialLabel"), "the picker-label view came back")
        for helper in ["statusChip", "isServiceConnected", "keyStatus"] {
            XCTAssertFalse(text.contains(helper), "SettingsView still carries \(helper)")
        }
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let startIndex = try XCTUnwrap(text.range(of: start)?.lowerBound)
        let endIndex = try XCTUnwrap(text.range(of: end, range: startIndex..<text.endIndex)?.lowerBound)
        return String(text[startIndex..<endIndex])
    }
}
