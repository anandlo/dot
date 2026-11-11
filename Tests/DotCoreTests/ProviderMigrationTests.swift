import XCTest

@testable import DotCore

final class ProviderMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-provider-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Fixtures

    /// The probe of a Mac whose Keychain holds exactly these providers' keys.
    private func probe(keys: Set<String>) -> CredentialProbe {
        CredentialProbe(hasKey: { keys.contains($0) })
    }

    /// The probe of a Mac with no key at all.
    private var noKeys: CredentialProbe { probe(keys: []) }

    /// The probe of a Mac whose only key belongs to the hosted model.
    private var xiaomiKey: CredentialProbe { probe(keys: [ProviderIdentifier.xiaomi]) }

    /// The probe of a Mac whose only key belongs to the OpenAI-compatible
    /// provider.
    private var openAIKey: CredentialProbe { probe(keys: [ProviderIdentifier.openAI]) }

    /// The exact shape a configuration that still selects the retired provider
    /// has on disk: the selection, and settings left behind for it.
    private static let tombstoneJSON = #"""
    {
      "provider": "bridge",
      "providers": {
        "apple": {},
        "bridge": {"model": "mimo_v2_5_asr"},
        "openai": {"model": "whisper-1", "baseURL": "https://api.openai.com/v1"},
        "xiaomi": {"model": "mimo-v2.5-asr", "baseURL": "https://api.xiaomimimo.com/v1"}
      },
      "hotkey": {"keyCode": 2, "modifiers": 2304, "label": "⌥⌘D"},
      "pasteHotkey": {"keyCode": 9, "modifiers": 2304, "label": "⌥⌘V"},
      "autoPaste": true,
      "hudDwellSeconds": 4,
      "maxSegmentSeconds": 30,
      "appearance": "system"
    }
    """#

    /// Writes the tombstone configuration and returns its file.
    private func writeTombstone() throws -> URL {
        let url = directory.appendingPathComponent("config.json")
        try Data(Self.tombstoneJSON.utf8).write(to: url)
        return url
    }

    /// Writes the tombstone configuration and decodes it, as a bare decode.
    private func loadTombstone() throws -> DotConfig {
        DotConfig.load(from: try writeTombstone())
    }

    // MARK: - The legacy key

    func testTheLegacyKeyIsCopiedOnceIntoDotsItem() {
        var writes: [(secret: String, service: String, account: String)] = []
        var reads: [(service: String, account: String)] = []
        let result = LegacyCredentialMigration.migrateXiaomiKeyIfNeeded(
            legacyAccount: "anandlo-test",
            hasSecret: { _, _ in false },
            read: { service, account in
                reads.append((service, account))
                if service == LegacyCredentialMigration.xiaomiService { return "legacy-key" }
                return nil
            },
            write: { secret, service, account in
                writes.append((secret, service, account))
                return true
            }
        )

        XCTAssertEqual(result, .init(migrated: true, keyAvailable: true))
        // Only the legacy item is read: the destination is answered by its
        // attributes, so an existing key is never decrypted.
        XCTAssertEqual(reads.map(\.service), [LegacyCredentialMigration.xiaomiService])
        XCTAssertEqual(reads.map(\.account), ["anandlo-test"])
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].secret, "legacy-key")
        XCTAssertEqual(writes[0].service, "DOT_API_KEY_XIAOMI")
        XCTAssertEqual(writes[0].account, "xiaomi")
    }

    func testAnExistingDotKeyIsNeverOverwritten() {
        var writes = 0
        let result = LegacyCredentialMigration.migrateXiaomiKeyIfNeeded(
            legacyAccount: "anandlo-test",
            hasSecret: { service, _ in service == "DOT_API_KEY_XIAOMI" },
            read: { _, _ in
                XCTFail("an existing key must not be read")
                return "legacy-key"
            },
            write: { _, _, _ in
                writes += 1
                return true
            }
        )

        XCTAssertEqual(result, .init(migrated: false, keyAvailable: true))
        XCTAssertEqual(writes, 0)
    }

    func testNoLegacyKeyMeansNothingToMigrate() {
        var writes = 0
        let result = LegacyCredentialMigration.migrateXiaomiKeyIfNeeded(
            legacyAccount: "anandlo-test",
            hasSecret: { _, _ in false },
            read: { _, _ in nil },
            write: { _, _, _ in
                writes += 1
                return true
            }
        )

        XCTAssertEqual(result, .init(migrated: false, keyAvailable: false))
        XCTAssertEqual(writes, 0)
    }

    func testAWhitespaceOnlyLegacyItemIsNotCopied() {
        var writes = 0
        let result = LegacyCredentialMigration.migrateXiaomiKeyIfNeeded(
            legacyAccount: "anandlo-test",
            hasSecret: { _, _ in false },
            read: { service, _ in
                service == LegacyCredentialMigration.xiaomiService ? "  \n " : nil
            },
            write: { _, _, _ in
                writes += 1
                return true
            }
        )

        XCTAssertEqual(result, .init(migrated: false, keyAvailable: false))
        XCTAssertEqual(writes, 0)
    }

    func testAFailedWriteKeepsTheLegacyItemAndReportsNoKey() {
        let result = LegacyCredentialMigration.migrateXiaomiKeyIfNeeded(
            legacyAccount: "anandlo-test",
            hasSecret: { _, _ in false },
            read: { service, _ in
                service == LegacyCredentialMigration.xiaomiService ? "legacy-key" : nil
            },
            write: { _, _, _ in false }
        )

        XCTAssertEqual(result, .init(migrated: false, keyAvailable: false))
    }

    func testAnExistingKeyIsFoundWithoutReadingItsData() {
        // "Does Dot already have a key?" is answered from the item's
        // attributes. Reading the data would decrypt the item, and decrypting
        // an item after a rebuild raises a system prompt that can hang a launch.
        var reads = 0
        let result = LegacyCredentialMigration.migrateXiaomiKeyIfNeeded(
            legacyAccount: "anandlo-test",
            hasSecret: { service, _ in service == "DOT_API_KEY_XIAOMI" },
            read: { _, _ in
                reads += 1
                return "should-never-be-read"
            },
            write: { _, _, _ in
                XCTFail("a key that already exists must not be written again")
                return false
            }
        )

        XCTAssertEqual(result, .init(migrated: false, keyAvailable: true))
        XCTAssertEqual(reads, 0, "the data of an existing key must never be read")
    }


    // MARK: - The launch retirement

    func testAConfigFileOnTheRetiredProviderLoadsAndIsCorrectedToALiveId() throws {
        // The whole launch load, from the file on disk: the tombstone decodes,
        // and the value handed on names a provider that can be built.
        let loaded = ProviderMigration.loadConfiguration(from: try writeTombstone(), probe: noKeys)
        let config = loaded.config
        let correction = try XCTUnwrap(loaded.correction)

        XCTAssertEqual(correction.retiredIDs, [ProviderIdentifier.bridge])
        XCTAssertEqual(correction.selectedID, ProviderIdentifier.apple)
        XCTAssertTrue(correction.awaitingKey, "no key was found, so the choice may still change")
        XCTAssertEqual(config.provider, ProviderIdentifier.apple)
        XCTAssertTrue(ProviderRegistry.knows(config.provider), "a live id, not a tombstone")
        XCTAssertNil(config.providers[ProviderIdentifier.bridge], "nothing may keep naming it")
        // The app comes up on a provider it can actually build.
        let provider = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        XCTAssertEqual(provider.id, ProviderIdentifier.apple)
        // Nothing else about the configuration moved.
        XCTAssertEqual(config.hotkey, Hotkey.defaultRecord)
        XCTAssertEqual(config.maxSegmentSeconds, 30)
    }

    func testTheRetirementChoosesTheServiceWhoseKeyExists() throws {
        var config = try loadTombstone()

        let correction = try XCTUnwrap(
            ProviderMigration.retireDeadProviders(in: &config, probe: xiaomiKey)
        )

        XCTAssertEqual(correction.selectedID, ProviderIdentifier.xiaomi)
        XCTAssertFalse(correction.awaitingKey, "the key was already there")
        XCTAssertEqual(config.provider, ProviderIdentifier.xiaomi)
        XCTAssertEqual(
            config.settings(for: ProviderIdentifier.xiaomi).model,
            XiaomiASRProvider.defaultModel
        )
        XCTAssertNotNil(try? ProviderRegistry.selectedProvider(config: config, credentials: .empty))
    }

    func testTheRetirementStillRunsWhenTheCredentialMigrationTimesOut() async throws {
        var config = try loadTombstone()

        // The Keychain does not answer in time: the copy is skipped entirely,
        // exactly as on a rebuild whose signature changed.
        let report = await DotMigration.migrateCredentialsAtLaunch(within: .milliseconds(30)) {
            Thread.sleep(forTimeInterval: 1)
            return DotMigration.CredentialReport(
                copiedProviderIDs: [],
                copiedFromLegacyTool: false,
                xiaomiKeyAvailable: false
            )
        }
        XCTAssertNil(report, "the launch gives up on the prompt instead of hanging")

        // The retirement does not share that fate: it runs on its own, with no
        // key material involved.
        let correction = try XCTUnwrap(
            ProviderMigration.retireDeadProviders(in: &config, probe: noKeys)
        )
        XCTAssertEqual(correction.selectedID, ProviderIdentifier.apple)
        let provider = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        XCTAssertEqual(provider.id, ProviderIdentifier.apple, "the app is usable on the fallback")
    }

    func testTheRetirementNeverReadsKeyData() throws {
        // The retirement asks the Keychain one question per keyed provider, the
        // attributes-only "is there a key?". The decrypting read is the call
        // that can raise a system prompt, so it is wired to fail the test and
        // must stay unused.
        var asked: [String] = []
        var reads = 0
        let probe = CredentialProbe(
            hasKey: { id in
                asked.append(id)
                return false
            },
            readKey: { _ in
                reads += 1
                XCTFail("provider retirement must never read a key")
                return "should-never-be-read"
            }
        )
        var config = try loadTombstone()

        XCTAssertNotNil(ProviderMigration.retireDeadProviders(in: &config, probe: probe))
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(
            asked,
            [
                ProviderIdentifier.openAI,
                ProviderIdentifier.groq,
                ProviderIdentifier.azure,
                ProviderIdentifier.deepgram,
                ProviderIdentifier.elevenLabs,
                ProviderIdentifier.xiaomi,
            ]
        )
        XCTAssertEqual(config.provider, ProviderIdentifier.apple)
    }

    func testASoundConfigurationIsLeftAloneWithoutAskingTheKeychain() {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.apple
        let before = config
        let probe = CredentialProbe(
            hasKey: { _ in
                XCTFail("a configuration Dot can build needs no Keychain question")
                return true
            },
            readKey: { _ in
                XCTFail("a configuration Dot can build needs no Keychain question")
                return nil
            }
        )

        XCTAssertNil(ProviderMigration.retireDeadProviders(in: &config, probe: probe))
        XCTAssertEqual(config, before)
    }

    func testTheRetirementIsIdempotent() throws {
        var config = try loadTombstone()
        XCTAssertNotNil(ProviderMigration.retireDeadProviders(in: &config, probe: noKeys))
        let after = config

        XCTAssertNil(ProviderMigration.retireDeadProviders(in: &config, probe: noKeys))
        XCTAssertEqual(config, after, "the second run has nothing left to do")
    }

    // MARK: - The late upgrade

    func testTheFallbackBecomesTheServiceWhoseKeyArrivesLaterInTheLaunch() throws {
        var config = try loadTombstone()
        let correction = try XCTUnwrap(
            ProviderMigration.retireDeadProviders(in: &config, probe: noKeys)
        )
        XCTAssertEqual(config.provider, ProviderIdentifier.apple)

        // The background copy of an older build's key finishes after the
        // retirement had to answer.
        let upgraded = ProviderMigration.upgrade(&config, after: correction, probe: xiaomiKey)

        XCTAssertTrue(upgraded)
        XCTAssertEqual(config.provider, ProviderIdentifier.xiaomi)
        XCTAssertEqual(
            config.settings(for: ProviderIdentifier.xiaomi).baseURL,
            XiaomiASRProvider.defaultBaseURL.absoluteString
        )
    }

    func testAKeyThatNeverArrivesLeavesTheFallbackInPlace() throws {
        var config = try loadTombstone()
        let correction = try XCTUnwrap(
            ProviderMigration.retireDeadProviders(in: &config, probe: noKeys)
        )

        XCTAssertFalse(ProviderMigration.upgrade(&config, after: correction, probe: noKeys))
        XCTAssertEqual(config.provider, ProviderIdentifier.apple)
    }

    func testAProviderTheUserChoseIsNeverUpgraded() {
        // No correction: the user picked the OpenAI-compatible provider and
        // there is nothing to undo.
        var config = DotConfig.default
        config.provider = ProviderIdentifier.openAI
        XCTAssertFalse(
            ProviderMigration.upgrade(&config, after: nil, probe: probe(keys: [ProviderIdentifier.xiaomi]))
        )
        XCTAssertEqual(config.provider, ProviderIdentifier.openAI)

        // A correction that already selected a service with a key has no
        // upgrade left.
        let settled = ProviderMigration.Correction(
            retiredIDs: [ProviderIdentifier.bridge],
            selectedID: ProviderIdentifier.xiaomi,
            awaitingKey: false
        )
        XCTAssertFalse(
            ProviderMigration.upgrade(&config, after: settled, probe: probe(keys: [ProviderIdentifier.xiaomi]))
        )
        XCTAssertEqual(config.provider, ProviderIdentifier.openAI)
    }

    func testAChoiceMadeAfterTheRetirementWins() throws {
        var config = try loadTombstone()
        let correction = try XCTUnwrap(
            ProviderMigration.retireDeadProviders(in: &config, probe: noKeys)
        )
        XCTAssertEqual(config.provider, ProviderIdentifier.apple)
        // The user picks another provider while the copy is still running.
        config.provider = ProviderIdentifier.openAI

        XCTAssertFalse(
            ProviderMigration.upgrade(&config, after: correction, probe: xiaomiKey)
        )
        XCTAssertEqual(config.provider, ProviderIdentifier.openAI)
    }

    // MARK: - The invariant

    func testEveryProviderIDDotWritesIsOneItShips() {
        // Every producer of a provider id — the defaults, the rows and the
        // registry — has to agree with the registry, because the id in the file
        // is what the next launch builds a provider from.
        XCTAssertTrue(ProviderRegistry.knows(DotConfig.default.provider))
        for id in DotConfig.defaultProviders.keys {
            XCTAssertTrue(ProviderRegistry.knows(id), "the default settings name a live provider: \(id)")
        }
        for preset in ProviderPreset.all {
            XCTAssertTrue(ProviderRegistry.knows(preset.providerID), "the row \(preset.id) names a live provider")
        }
        // The tombstone only has to decode; it is not a provider Dot ships.
        XCTAssertFalse(ProviderRegistry.knows(ProviderIdentifier.bridge))
    }

    func testEveryProviderTheRetirementCanPickIsOneDotShips() {
        // Whatever the Keychain holds, the replacement is a live id.
        let keychains: [Set<String>] = [
            [],
            [ProviderIdentifier.openAI],
            [ProviderIdentifier.xiaomi],
            [ProviderIdentifier.apple],
            [ProviderIdentifier.openAI, ProviderIdentifier.apple],
            [ProviderIdentifier.xiaomi, ProviderIdentifier.apple],
            [ProviderIdentifier.openAI, ProviderIdentifier.xiaomi],
            [ProviderIdentifier.openAI, ProviderIdentifier.xiaomi, ProviderIdentifier.apple],
        ]
        for keys in keychains {
            var config = DotConfig.default
            config.provider = ProviderIdentifier.bridge
            let probe = probe(keys: keys)

            let correction = ProviderMigration.retireDeadProviders(in: &config, probe: probe)

            XCTAssertTrue(ProviderRegistry.knows(config.provider), "\(keys) left a dead id")
            XCTAssertEqual(correction?.selectedID, config.provider)
            XCTAssertNotNil(try? ProviderRegistry.selectedProvider(config: config, credentials: .empty), "\(keys)")
        }
    }

    func testWhatTheAppSavesIsWhatTheNextLaunchCanBuild() throws {
        var config = try loadTombstone()
        let correction = try XCTUnwrap(
            ProviderMigration.retireDeadProviders(in: &config, probe: noKeys)
        )
        XCTAssertEqual(correction.selectedID, config.provider)

        let url = directory.appendingPathComponent("saved.json")
        try config.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(ProviderIdentifier.bridge), "the retired id is gone from the file")

        var reloaded = DotConfig.load(from: url)
        XCTAssertEqual(reloaded.provider, config.provider)
        XCTAssertNil(ProviderMigration.retireDeadProviders(in: &reloaded, probe: noKeys))
    }

    // MARK: - A named service without its endpoint

    /// A configuration that names OpenAI and carries no URL builds nothing:
    /// every press does nothing and the only trace is one error line in a log.
    /// The endpoint is the preset's, so it can be written back.
    func testANamedProviderWithoutAnEndpointGetsItsPresetEndpoint() {
        var config = DotConfig()
        config.provider = ProviderIdentifier.openAI
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            model: "whisper-1",
            baseURL: nil
        )

        let filled = ProviderMigration.fillMissingEndpoints(in: &config)

        XCTAssertEqual(filled, [ProviderIdentifier.openAI])
        XCTAssertEqual(
            config.providers[ProviderIdentifier.openAI]?.baseURL,
            "https://api.openai.com/v1"
        )
        // The rest of the record is the user's and is untouched.
        XCTAssertEqual(config.providers[ProviderIdentifier.openAI]?.model, "whisper-1")
    }

    func testAStoredEndpointIsNeverOverwritten() {
        var config = DotConfig()
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            baseURL: "http://localhost:8080/v1"
        )

        XCTAssertTrue(ProviderMigration.fillMissingEndpoints(in: &config).isEmpty)
        XCTAssertEqual(
            config.providers[ProviderIdentifier.openAI]?.baseURL,
            "http://localhost:8080/v1"
        )
    }

    /// Apple's row id is `on-device`, not its provider id, so a lookup by row
    /// id skipped it: the repair asked for `apple` and the table answered
    /// nothing. The provider id is the key the configuration stores, so that is
    /// what the lookup uses.
    func testTheAppleRowIsFoundByItsProviderID() {
        XCTAssertNil(
            ProviderPreset.preset(id: ProviderIdentifier.apple),
            "the row is not stored under the provider id"
        )
        XCTAssertEqual(
            ProviderPreset.row(forProviderID: ProviderIdentifier.apple)?.id,
            ProviderPreset.apple.id
        )
        XCTAssertNil(
            ProviderPreset.endpoint(forProviderID: ProviderIdentifier.apple),
            "the on-device transcriber has no endpoint to write in"
        )
    }

    /// Apple has nothing to fill in, so the repair leaves it alone rather than
    /// inventing an endpoint for a provider that runs inside the machine.
    func testTheAppleProviderIsNeverGivenAnEndpoint() {
        var config = DotConfig()
        config.providers[ProviderIdentifier.apple] = ProviderConfig()

        XCTAssertTrue(ProviderMigration.fillMissingEndpoints(in: &config).isEmpty)
        XCTAssertNil(config.providers[ProviderIdentifier.apple]?.baseURL)
    }

    /// Every provider id that a row declares an endpoint for is found by that
    /// id, which is what makes the repair exhaustive instead of coincidental.
    func testEveryDeclaredEndpointIsReachableByProviderID() {
        let declared = ProviderPreset.declared.filter { $0.baseURL != nil }
        XCTAssertFalse(declared.isEmpty)
        for row in declared {
            XCTAssertEqual(
                ProviderPreset.endpoint(forProviderID: row.providerID)?.baseURL,
                row.baseURL,
                row.id
            )
        }
    }

    /// A custom endpoint is the user's own URL. An empty one means they have not
    /// typed it yet, and there is nothing honest to fill in.
    func testACustomEndpointIsLeftEmpty() {
        var config = DotConfig()
        config.providers["custom"] = ProviderConfig(baseURL: nil)

        XCTAssertTrue(ProviderMigration.fillMissingEndpoints(in: &config).isEmpty)
        XCTAssertNil(config.providers["custom"]?.baseURL)
    }

    /// The repair runs inside the one call launch makes, and it reports itself so
    /// the corrected file is written back instead of being repaired on every
    /// launch forever.
    func testLoadingRepairsTheEndpointAndReportsIt() throws {
        let url = directory.appendingPathComponent("config.json")
        var config = DotConfig()
        config.provider = ProviderIdentifier.openAI
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(model: "whisper-1")
        try config.save(to: url)

        let loaded = ProviderMigration.loadConfiguration(from: url, probe: noKeys)

        XCTAssertEqual(
            loaded.config.providers[ProviderIdentifier.openAI]?.baseURL,
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(loaded.correction?.filledEndpoints, [ProviderIdentifier.openAI])
        XCTAssertEqual(loaded.correction?.retiredIDs, [])
        XCTAssertEqual(loaded.correction?.selectedID, ProviderIdentifier.openAI)
    }

    /// A sound configuration is not corrected, so it is not rewritten.
    func testASoundConfigurationReportsNothing() throws {
        let url = directory.appendingPathComponent("config.json")
        var config = DotConfig()
        config.provider = ProviderIdentifier.openAI
        config.providers[ProviderIdentifier.openAI] = ProviderConfig(
            baseURL: "https://api.openai.com/v1"
        )
        try config.save(to: url)

        let loaded = ProviderMigration.loadConfiguration(from: url, probe: noKeys)

        XCTAssertNil(loaded.correction)
    }
}
