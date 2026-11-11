import XCTest

@testable import DotCore

/// The identity migration that runs before anything reads a path.
final class DotMigrationTests: XCTestCase {
    private var home: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defaultsSuite = "dot-migration-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    }

    override func tearDownWithError() throws {
        if let home {
            try? FileManager.default.removeItem(at: home)
        }
        if let defaultsSuite {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
    }

    private var legacyConfiguration: URL {
        home.appendingPathComponent(DotMigration.legacyApplicationSupportPath, isDirectory: true)
    }

    private var currentConfiguration: URL {
        home.appendingPathComponent(DotMigration.currentApplicationSupportPath, isDirectory: true)
    }

    private var legacyLogs: URL {
        home.appendingPathComponent(DotMigration.legacyLogPath, isDirectory: true)
    }

    private var currentLogs: URL {
        home.appendingPathComponent(DotMigration.currentLogPath, isDirectory: true)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func runMigration() -> DotMigration.FileReport {
        DotMigration.runSynchronously(home: home, defaults: defaults)
    }

    func testTheOldConfigurationAndTheHistoryMoveTogether() throws {
        try write(#"{"provider":"openai"}"#, to: legacyConfiguration.appendingPathComponent("config.json"))
        try write(#"["one transcript"]"#, to: legacyConfiguration.appendingPathComponent("history.json"))

        let report = runMigration()

        XCTAssertTrue(report.movedConfigurationAndHistory)
        XCTAssertTrue(report.movedAnything)
        XCTAssertEqual(
            try String(contentsOf: currentConfiguration.appendingPathComponent("config.json"), encoding: .utf8),
            #"{"provider":"openai"}"#
        )
        XCTAssertEqual(
            try String(contentsOf: currentConfiguration.appendingPathComponent("history.json"), encoding: .utf8),
            #"["one transcript"]"#
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyConfiguration.path),
            "an emptied folder is removed"
        )
    }

    func testTheOldLogFolderAndItsLogFileMoveUnderTheNewName() throws {
        try write("{\"event\":\"app.started\"}\n", to: legacyLogs.appendingPathComponent(DotMigration.legacyLogFileName))

        let report = runMigration()

        XCTAssertTrue(report.movedLog)
        let moved = currentLogs.appendingPathComponent("Dot.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), "the log file is renamed too")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "{\"event\":\"app.started\"}\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLogs.path))
    }

    func testTheMigratedConfigurationIsTheOneTheAppLoads() throws {
        try write(#"{"provider":"xiaomi","autoPaste":false}"#, to: legacyConfiguration.appendingPathComponent("config.json"))

        _ = runMigration()

        let loaded = DotConfig.load(from: currentConfiguration.appendingPathComponent("config.json"))
        XCTAssertEqual(loaded.provider, ProviderIdentifier.xiaomi)
        XCTAssertFalse(loaded.autoPaste)
    }

    func testALiveConfigurationOnTheRetiredProviderStillDecodesAfterTheMove() throws {
        // The exact shape an installation that still selects the retired
        // provider has on disk. The migration has to carry it across, and the
        // tombstone id has to keep decoding so ``ProviderMigration`` can
        // rewrite it.
        let json = #"""
        {
          "provider": "bridge",
          "providers": {
            "bridge": {},
            "openai": {"model": "whisper-1", "baseURL": "https://api.openai.com/v1"}
          },
          "hotkey": {"keyCode": 2, "modifiers": 2304, "label": "⌥⌘D"},
          "pasteHotkey": {"keyCode": 9, "modifiers": 2304, "label": "⌥⌘V"},
          "autoPaste": true,
          "hudDwellSeconds": 4,
          "maxSegmentSeconds": 30,
          "appearance": "system"
        }
        """#
        try write(json, to: legacyConfiguration.appendingPathComponent("config.json"))

        _ = runMigration()

        var config = DotConfig.load(from: currentConfiguration.appendingPathComponent("config.json"))
        XCTAssertEqual(config.provider, ProviderIdentifier.bridge, "the tombstone still decodes")
        let noKeys = CredentialProbe(hasKey: { _ in false })
        _ = ProviderMigration.retireDeadProviders(in: &config, probe: noKeys)
        XCTAssertEqual(config.provider, ProviderIdentifier.apple)
    }

    func testAnExistingNewFolderWinsAndTheRestIsMerged() throws {
        try write(#"{"provider":"openai"}"#, to: legacyConfiguration.appendingPathComponent("config.json"))
        try write(#"["old history"]"#, to: legacyConfiguration.appendingPathComponent("history.json"))
        try write(#"{"provider":"xiaomi"}"#, to: currentConfiguration.appendingPathComponent("config.json"))

        let report = runMigration()

        XCTAssertTrue(report.movedConfigurationAndHistory)
        XCTAssertEqual(
            try String(contentsOf: currentConfiguration.appendingPathComponent("config.json"), encoding: .utf8),
            #"{"provider":"xiaomi"}"#,
            "a configuration the new name already wrote is never overwritten"
        )
        XCTAssertEqual(
            try String(contentsOf: currentConfiguration.appendingPathComponent("history.json"), encoding: .utf8),
            #"["old history"]"#
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyConfiguration.appendingPathComponent("config.json").path),
            "a colliding file stays where it is instead of being lost"
        )
    }

    func testRunningTheMigrationAgainChangesNothing() throws {
        try write(#"{"provider":"openai"}"#, to: legacyConfiguration.appendingPathComponent("config.json"))

        let first = runMigration()
        let second = runMigration()

        XCTAssertTrue(first.movedAnything)
        XCTAssertFalse(second.movedAnything, "the migration is idempotent")
        XCTAssertEqual(
            try String(contentsOf: currentConfiguration.appendingPathComponent("config.json"), encoding: .utf8),
            #"{"provider":"openai"}"#
        )
    }

    func testAMachineThatNeverRanTheOldNameIsLeftAlone() throws {
        let report = runMigration()

        XCTAssertFalse(report.movedAnything)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentConfiguration.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentLogs.path))
    }

    func testTheWelcomeFlagIsCopiedAndTheOldKeyIsKept() {
        defaults.set(true, forKey: DotMigration.legacyWelcomedKey)

        XCTAssertTrue(DotMigration.migrateWelcomedFlag(defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: DotMigration.welcomedKey))
        XCTAssertNotNil(
            defaults.object(forKey: DotMigration.legacyWelcomedKey),
            "the old key is left alone, never deleted"
        )
        XCTAssertFalse(DotMigration.migrateWelcomedFlag(defaults: defaults), "the copy happens once")
    }

    func testAWelcomeFlagThatIsAlreadySetIsNotOverwritten() {
        defaults.set(true, forKey: DotMigration.legacyWelcomedKey)
        defaults.set(false, forKey: DotMigration.welcomedKey)

        XCTAssertFalse(DotMigration.migrateWelcomedFlag(defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: DotMigration.welcomedKey))
    }

    // MARK: - Keychain

    func testACredentialIsCopiedFromTheOldServiceNameAndTheOldItemIsKept() {
        var store: [String: String] = [DotMigration.legacyKeychainPrefix + "OPENAI": "old-openai-key"]
        let report = DotMigration.migrateCredentials(
            providerIDs: [ProviderIdentifier.openAI, ProviderIdentifier.xiaomi],
            hasSecret: { service, _ in store[service] != nil },
            read: { service, _ in store[service] },
            write: { secret, service, _ in
                store[service] = secret
                return true
            },
            legacyAccount: "anandlo-test"
        )

        XCTAssertEqual(report.copiedProviderIDs, [ProviderIdentifier.openAI])
        XCTAssertEqual(store["DOT_API_KEY_OPENAI"], "old-openai-key")
        XCTAssertEqual(
            store[DotMigration.legacyKeychainPrefix + "OPENAI"], "old-openai-key",
            "the old item is copied, never moved or deleted"
        )
        XCTAssertNil(store["DOT_API_KEY_XIAOMI"], "nothing is invented for a provider without a key")
        XCTAssertFalse(report.copiedFromLegacyTool)
    }

    func testAnExistingCredentialUnderTheNewNameIsNeverOverwritten() {
        var store: [String: String] = [
            DotMigration.legacyKeychainPrefix + "OPENAI": "old-key",
            "DOT_API_KEY_OPENAI": "current-key",
        ]
        let report = DotMigration.migrateCredentials(
            providerIDs: [ProviderIdentifier.openAI],
            hasSecret: { service, _ in store[service] != nil },
            read: { service, _ in
                XCTAssertFalse(
                    service.hasPrefix(CredentialStore.servicePrefix),
                    "a key that already exists under the new name must not be read"
                )
                return store[service]
            },
            write: { secret, service, _ in
                store[service] = secret
                return true
            },
            legacyAccount: "anandlo-test"
        )

        XCTAssertEqual(report.copiedProviderIDs, [])
        XCTAssertEqual(store["DOT_API_KEY_OPENAI"], "current-key")
    }

    func testTheXiaomiKeyOfTheOlderToolIsReported() {
        var store: [String: String] = [LegacyCredentialMigration.xiaomiService: "xiaomi-key"]
        let report = DotMigration.migrateCredentials(
            providerIDs: [],
            hasSecret: { service, _ in store[service] != nil },
            read: { service, _ in store[service] },
            write: { secret, service, _ in
                store[service] = secret
                return true
            },
            legacyAccount: "anandlo-test"
        )

        XCTAssertTrue(report.copiedFromLegacyTool)
        XCTAssertTrue(report.xiaomiKeyAvailable)
        XCTAssertEqual(store["DOT_API_KEY_XIAOMI"], "xiaomi-key")
    }

    func testNoKeyAvailableLeavesProviderSelectionToTheMigration() {
        let report = DotMigration.migrateCredentials(
            providerIDs: [],
            hasSecret: { _, _ in false },
            read: { _, _ in nil },
            write: { _, _, _ in false },
            legacyAccount: "anandlo-test"
        )

        XCTAssertFalse(report.copiedFromLegacyTool)
        XCTAssertFalse(report.xiaomiKeyAvailable)
        XCTAssertEqual(report.copiedProviderIDs, [])
    }

    // MARK: - The launch half

    func testTheLaunchHalfGivesUpWhenTheKeychainDoesNotAnswerInTime() async {
        let report = await DotMigration.migrateCredentialsAtLaunch(within: .milliseconds(50)) {
            Thread.sleep(forTimeInterval: 2)
            return .init(copiedProviderIDs: [], copiedFromLegacyTool: false, xiaomiKeyAvailable: false)
        }
        XCTAssertNil(report, "a pending prompt degrades to a retry, never to a hang")
    }

    func testTheLaunchHalfReportsAFastAnswer() async {
        let expected = DotMigration.CredentialReport(
            copiedProviderIDs: ["openai"],
            copiedFromLegacyTool: false,
            xiaomiKeyAvailable: true
        )
        let report = await DotMigration.migrateCredentialsAtLaunch(within: .seconds(5)) {
            expected
        }
        XCTAssertEqual(report, expected)
    }
}
