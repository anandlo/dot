import Foundation

/// Moves a Mac off the product's old name, once, before anything reads a path.
///
/// The product was called something else before it was called Dot. Everything
/// that names it on disk — the configuration folder, the transcript history,
/// the log folder, the Keychain service and the welcome flag — changed with
/// the name, and an existing installation must keep its data. This type is the
/// only place in the source that knows the old name, so the rest of the app can
/// be scanned for it.
///
/// The filesystem and defaults halves run synchronously and are the first thing
/// the process does: ``DotConfig`` and ``Log`` compute their paths eagerly, so
/// they must never see the old folders. The Keychain half runs off the main
/// actor with a deadline (see ``migrateCredentialsAtLaunch(within:)``), because
/// a Keychain read can raise a system prompt.
///
/// Every step is idempotent, so it is safe on every launch, and nothing is ever
/// deleted from the Keychain: the old items stay behind for the build that
/// wrote them.
public enum DotMigration {
    // MARK: - The old identity

    /// The old folder name under Application Support.
    public static let legacyApplicationSupportPath = "Library/Application Support/Ion"
    /// The old folder name under Logs.
    public static let legacyLogPath = "Library/Logs/Ion"
    /// The old log file name.
    public static let legacyLogFileName = "Ion.log"
    /// The old Keychain service prefix.
    public static let legacyKeychainPrefix = "ION_API_KEY_"
    /// The old environment variable prefix.
    public static let legacyEnvironmentPrefix = "ION_"
    /// The old default that marks the welcome as finished.
    public static let legacyWelcomedKey = "ion.welcomed"

    /// The default that marks the welcome as finished today.
    public static let welcomedKey = "dot.welcomed"

    /// The prefix environment variables use today.
    public static let environmentPrefix = "DOT_"

    // MARK: - Environment

    /// Reads `DOT_<suffix>`, falling back to the old `ION_<suffix>` spelling.
    ///
    /// The fallback is the one compatibility shim of the rename: a shell
    /// snippet or a LaunchAgent written before it keeps working instead of
    /// silently doing nothing.
    public static func environment(
        _ suffix: String,
        in values: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let value = values[environmentPrefix + suffix], !value.isEmpty {
            return value
        }
        if let value = values[legacyEnvironmentPrefix + suffix], !value.isEmpty {
            return value
        }
        return nil
    }

    // MARK: - Filesystem and defaults

    /// What the synchronous half moved.
    public struct FileReport: Equatable, Sendable {
        /// Whether anything at all was moved.
        public let movedAnything: Bool
        /// Whether the configuration folder (and the history beside it) moved.
        public let movedConfigurationAndHistory: Bool
        /// Whether the log folder (or the log file inside it) moved.
        public let movedLog: Bool
        /// Whether the welcome flag was copied to its new default.
        public let movedWelcomedFlag: Bool

        public init(
            movedConfigurationAndHistory: Bool,
            movedLog: Bool,
            movedWelcomedFlag: Bool
        ) {
            self.movedConfigurationAndHistory = movedConfigurationAndHistory
            self.movedLog = movedLog
            self.movedWelcomedFlag = movedWelcomedFlag
            self.movedAnything = movedConfigurationAndHistory || movedLog || movedWelcomedFlag
        }
    }

    /// Moves the old folders and copies the welcome flag.
    ///
    /// This must be called before ``DotConfig/load(from:)`` and before ``Log``
    /// opens its file. It never throws: a folder that cannot be moved is left
    /// where it is and reported as not moved, so the app still starts.
    ///
    /// - Parameters:
    ///   - home: the home directory; injected so a test never touches the real
    ///     one.
    ///   - defaults: the defaults database; injected for the same reason.
    ///   - fileManager: the file manager to use.
    /// - Returns: what was moved.
    @discardableResult
    public static func runSynchronously(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> FileReport {
        let configurationMoved = migrateDirectory(
            home.appendingPathComponent(legacyApplicationSupportPath, isDirectory: true),
            to: home.appendingPathComponent(currentApplicationSupportPath, isDirectory: true),
            fileManager: fileManager
        )
        let logMoved = migrateLogs(home: home, fileManager: fileManager)
        let welcomedMoved = migrateWelcomedFlag(defaults: defaults)
        return FileReport(
            movedConfigurationAndHistory: configurationMoved,
            movedLog: logMoved,
            movedWelcomedFlag: welcomedMoved
        )
    }

    /// The folder the configuration and the history live in today.
    static let currentApplicationSupportPath = DotConfig.directoryName

    /// The folder the log lives in today.
    static let currentLogPath = Log.directoryName

    /// Moves the log folder, then the log file inside it.
    ///
    /// The log file was named after the product too, so it is renamed when the
    /// new name is still free. An existing new log always wins: two runs of the
    /// migration never interleave their lines.
    private static func migrateLogs(home: URL, fileManager: FileManager) -> Bool {
        let legacyDirectory = home.appendingPathComponent(legacyLogPath, isDirectory: true)
        let currentDirectory = home.appendingPathComponent(currentLogPath, isDirectory: true)
        var moved = migrateDirectory(legacyDirectory, to: currentDirectory, fileManager: fileManager)

        let legacyFile = currentDirectory.appendingPathComponent(legacyLogFileName)
        let currentFile = currentDirectory.appendingPathComponent(Log.fileName)
        if fileManager.fileExists(atPath: legacyFile.path),
           !fileManager.fileExists(atPath: currentFile.path),
           (try? fileManager.moveItem(at: legacyFile, to: currentFile)) != nil {
            moved = true
        }
        return moved
    }

    /// Copies the welcome flag to its new key without removing the old one.
    ///
    /// The old key is left alone: removing it would only lose the information
    /// the copy needed in the first place.
    @discardableResult
    public static func migrateWelcomedFlag(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: legacyWelcomedKey) != nil,
              defaults.object(forKey: welcomedKey) == nil
        else { return false }
        defaults.set(defaults.bool(forKey: legacyWelcomedKey), forKey: welcomedKey)
        return true
    }

    /// Moves every entry of `source` into `destination`, skipping names that
    /// already exist there.
    ///
    /// A merge, not a swap: an installation that already wrote a new
    /// configuration keeps it, and a file that collides is left in the old
    /// folder rather than overwritten. The old folder is removed only when it
    /// is empty.
    private static func migrateDirectory(
        _ source: URL,
        to destination: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }

        var moved = false
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let entries = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil
            )
            for entry in entries {
                let target = destination.appendingPathComponent(entry.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                do {
                    try fileManager.moveItem(at: entry, to: target)
                    moved = true
                } catch {
                    continue
                }
            }
            let remaining = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            if remaining.isEmpty {
                try? fileManager.removeItem(at: source)
            }
        } catch {
            return moved
        }
        return moved
    }

    // MARK: - Keychain

    /// What the Keychain half found and copied.
    public struct CredentialReport: Equatable, Sendable {
        /// The providers whose key was copied from the old service name.
        public let copiedProviderIDs: [String]
        /// Whether the key of the older Xiaomi tool was copied in.
        public let copiedFromLegacyTool: Bool
        /// Whether a Xiaomi key is available under the new service name.
        public let xiaomiKeyAvailable: Bool

        public init(
            copiedProviderIDs: [String],
            copiedFromLegacyTool: Bool,
            xiaomiKeyAvailable: Bool
        ) {
            self.copiedProviderIDs = copiedProviderIDs
            self.copiedFromLegacyTool = copiedFromLegacyTool
            self.xiaomiKeyAvailable = xiaomiKeyAvailable
        }
    }

    /// The longest the launch waits for the Keychain.
    ///
    /// Long enough for an unlocked Keychain that answers at once, short enough
    /// that a forgotten system prompt cannot keep the app from starting.
    public static let launchTimeout: Duration = .seconds(2)

    /// Copies the credentials of the old name, off the main actor.
    ///
    /// - Parameters:
    ///   - timeout: how long the launch waits before giving up.
    ///   - credentials: the blocking body; injected so a test never reads the
    ///     real Keychain.
    /// - Returns: the report, or `nil` when the deadline passed first. `nil`
    ///   means "the provider stays as it is and the migration runs again on the
    ///   next launch", never a failure.
    public static func migrateCredentialsAtLaunch(
        within timeout: Duration = launchTimeout,
        credentials: @escaping @Sendable () -> CredentialReport = { migrateCredentials() }
    ) async -> CredentialReport? {
        await BoundedWork.run(within: timeout, credentials).value
    }

    /// The synchronous body of the Keychain half, meant for a background queue.
    ///
    /// Every probe asks for attributes only, so asking "is there a key?" never
    /// decrypts one and never raises a prompt. The data is read only for an
    /// item that exists and only when its new copy does not.
    ///
    /// - Parameters:
    ///   - providerIDs: the providers to copy.
    ///   - hasSecret: probes a secret without reading it; injected for tests.
    ///   - read: reads a secret; injected for tests.
    ///   - write: writes a secret and reports success; injected for tests.
    ///   - legacyAccount: the account the older Xiaomi tool used.
    /// - Returns: what was copied.
    public static func migrateCredentials(
        providerIDs: [String] = ProviderRegistry.builtInIDs,
        hasSecret: (String, String) -> Bool = { service, account in
            CredentialStore.hasSecret(service: service, account: account)
        },
        read: (String, String) -> String? = { service, account in
            try? CredentialStore.readSecret(service: service, account: account)
        },
        write: (String, String, String) -> Bool = { secret, service, account in
            (try? CredentialStore.writeSecret(secret, service: service, account: account)) != nil
        },
        legacyAccount: String = NSUserName()
    ) -> CredentialReport {
        var copied: [String] = []
        for providerID in providerIDs {
            let account = CredentialStore.account(for: providerID)
            let destination = CredentialStore.serviceName(for: providerID)
            guard !hasSecret(destination, account) else { continue }
            let legacy = legacyKeychainPrefix + providerID.uppercased()
            guard hasSecret(legacy, account) else { continue }
            guard let secret = read(legacy, account),
                  !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            if write(secret, destination, account) {
                copied.append(providerID)
            }
        }

        let legacyTool = LegacyCredentialMigration.migrateXiaomiKeyIfNeeded(
            legacyAccount: legacyAccount,
            hasSecret: hasSecret,
            read: read,
            write: write
        )

        let xiaomiAccount = CredentialStore.account(for: ProviderIdentifier.xiaomi)
        return CredentialReport(
            copiedProviderIDs: copied,
            copiedFromLegacyTool: legacyTool.migrated,
            xiaomiKeyAvailable: hasSecret(CredentialStore.serviceName(for: ProviderIdentifier.xiaomi), xiaomiAccount)
        )
    }
}
