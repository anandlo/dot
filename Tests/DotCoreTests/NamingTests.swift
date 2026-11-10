import XCTest

@testable import DotCore

/// Dot is a product, not a model — and it used to have another name.
///
/// The name of the model that happens to be behind a provider must never leak
/// into Dot's identity: not into the package, the bundle identifier, the
/// configuration keys, the log messages, the menu items, the card or the source
/// code. The same holds for the product's old name, which may only survive in
/// the one type that migrates data written under it.
///
/// Both tokens are built at run time, so this file does not contain either of
/// them and can be scanned like any other.
final class NamingTests: XCTestCase {
    /// The model family that must not appear in the source.
    private static var forbiddenModel: String {
        ["Mi", "Mo"].joined().lowercased()
    }

    /// The product's old name.
    private static var legacyName: String {
        ["I", "on"].joined()
    }

    /// The prefix the old name gave the Keychain service and the environment.
    private static var legacyPrefix: String {
        [legacyName.uppercased(), "_"].joined()
    }

    /// The only file allowed to name the old product: the migration that moves
    /// its data. It has to know the name to find the folders and the Keychain
    /// items.
    private static let legacyUsers: Set<String> = ["DotMigration.swift"]

    /// The package root.
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every Swift file in `Sources` and `Tests`.
    ///
    /// The build folder is not scanned: it holds copies of the sources.
    private static func swiftFiles() -> [URL] {
        var files: [URL] = []
        for directory in ["Sources", "Tests"] {
            files.append(contentsOf: swiftFiles(in: root.appendingPathComponent(directory, isDirectory: true)))
        }
        return files
    }

    /// Every Swift file under one directory.
    private static func swiftFiles(in start: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: start,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    /// The brands Dot must not present as its own: the model family, and the
    /// vendor whose row the picker no longer offers.
    ///
    /// Service names are a different question. A row has to be recognisable to
    /// the person choosing it, so `ProviderPreset.groq` and
    /// `ProviderPreset.openAI` may carry theirs in row data. What may never
    /// happen is one of *these* names reaching a row or a sentence: the model
    /// and the vendor Dot was built around are not a service a person picks,
    /// they are the assumption the product was supposed to lose.
    private static var brandTokens: [String] {
        [forbiddenModel]
    }

    /// The names of the speech-to-text services Dot can talk to, built at run
    /// time so this file can be scanned like any other.
    ///
    /// The platform is not on the list: macOS names its own frameworks and URL
    /// schemes, and one of them opens System Settings. What must never appear
    /// in the app's own copy is a service name used as the assumed case.
    private static var vendorTokens: [String] {
        [
            ["xia", "omi"].joined(),
            ["mi", "mo"].joined(),
            ["gro", "q"].joined(),
            ["open", "ai"].joined(),
        ]
    }

    /// The text inside the string literals of one line.
    ///
    /// A quote ends one literal and starts the next, so the odd segments of a
    /// split carry the text a person can read. Interpolations stay inside their
    /// segment, which is what makes `\(row.name)` safe and a written-out name
    /// visible.
    private static func quotedSegments(in line: String) -> [String] {
        line.split(separator: "\"", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.offset % 2 == 1 }
            .map { String($0.element) }
    }

    func testNoProviderOrPresetNameMentionsTheModel() {
        // The model id is data inside the Xiaomi provider and preset. What the
        // user reads — the menu, the settings cards, the welcome — is named
        // after the product or the service, never after the model.
        let providers: [any Provider] = [
            OpenAICompatibleProvider(baseURL: URL(string: "https://api.openai.com/v1")!),
            XiaomiASRProvider(),
            AppleSpeechProvider(),
        ]
        for provider in providers {
            XCTAssertFalse(
                provider.displayName.lowercased().contains(Self.forbiddenModel),
                provider.displayName
            )
        }
        for preset in ProviderPreset.declared {
            XCTAssertFalse(preset.name.lowercased().contains(Self.forbiddenModel), preset.name)
        }
    }

    func testThePackageAndTheTargetsAreNamedAfterTheProduct() throws {
        let package = try String(
            contentsOf: Self.root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(package.contains("name: \"dot\""))
        XCTAssertTrue(package.contains("name: \"Dot\""))
        XCTAssertTrue(package.contains("name: \"DotCore\""))
        XCTAssertTrue(package.contains("name: \"DotCoreTests\""))
        XCTAssertTrue(package.contains("name: \"DotTests\""))
        XCTAssertFalse(package.lowercased().contains(Self.forbiddenModel))
        XCTAssertFalse(package.contains(Self.legacyName), "Package.swift still names the old product")
    }

    func testTheConfigurationAndTheLogLiveUnderTheProductName() {
        XCTAssertTrue(
            DotConfig.defaultURL().path.contains("/Application Support/Dot/"),
            DotConfig.defaultURL().path
        )
        XCTAssertTrue(
            HistoryStore.defaultURL().path.contains("/Application Support/Dot/"),
            HistoryStore.defaultURL().path
        )
        XCTAssertEqual(Log.fileName, "Dot.log")
        XCTAssertEqual(Log.directoryName, "Library/Logs/Dot")
        XCTAssertTrue(Log.defaultURL().path.hasSuffix("/Library/Logs/Dot/Dot.log"))
    }

    func testTheProviderIdentifiersAreNeutral() {
        // The retired id is a tombstone: it still decodes, but nothing selects
        // it and no provider is built for it.
        XCTAssertEqual(ProviderIdentifier.bridge, "bridge")
        XCTAssertFalse(ProviderRegistry.builtInIDs.contains(ProviderIdentifier.bridge))
        XCTAssertFalse(ProviderMigration.knownProviderIDs.contains(ProviderIdentifier.bridge))
        XCTAssertEqual(ProviderIdentifier.openAI, "openai")
        XCTAssertEqual(ProviderIdentifier.xiaomi, "xiaomi")
        XCTAssertEqual(ProviderIdentifier.apple, "apple")
        for id in [
            ProviderIdentifier.bridge,
            ProviderIdentifier.openAI,
            ProviderIdentifier.xiaomi,
            ProviderIdentifier.apple,
        ] {
            XCTAssertFalse(id.lowercased().contains(Self.forbiddenModel))
        }
    }

    func testTheKeychainServiceIsNamedAfterTheProduct() {
        XCTAssertEqual(CredentialStore.servicePrefix, "DOT_API_KEY_")
        XCTAssertEqual(CredentialStore.serviceName(for: "openai"), "DOT_API_KEY_OPENAI")
        XCTAssertEqual(CredentialStore.account(for: "openai"), "openai")
    }

    func testTheDefaultsAreNamedAfterTheProduct() {
        XCTAssertEqual(DotMigration.welcomedKey, "dot.welcomed")
    }

    func testTheEnvironmentIsNamedAfterTheProductWithOneOldSpellingFallback() {
        XCTAssertEqual(DotMigration.environmentPrefix, "DOT_")
        let current = DotMigration.environment("PROBE", in: ["DOT_PROBE": "new"])
        let legacy = DotMigration.environment("PROBE", in: [Self.legacyPrefix + "PROBE": "old"])
        XCTAssertEqual(current, "new")
        XCTAssertEqual(legacy, "old", "the old spelling must keep working")
        XCTAssertNil(DotMigration.environment("PROBE", in: [:]))
        XCTAssertNil(DotMigration.environment("PROBE", in: ["DOT_PROBE": ""]))
    }

    func testNoSourceFileNamesTheOldProduct() {
        let legacy = Self.legacyName
        let prefix = Self.legacyPrefix
        var offenders: [String] = []
        var allowed: Set<String> = []
        for file in Self.swiftFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard text.contains(legacy) || text.contains(prefix) else { continue }
            let name = file.lastPathComponent
            if Self.legacyUsers.contains(name) {
                allowed.insert(name)
            } else {
                offenders.append(file.path)
            }
        }
        XCTAssertEqual(
            offenders,
            [],
            "these files still name the old product — Dot is the only name the source may use"
        )
        XCTAssertEqual(
            allowed,
            Self.legacyUsers,
            "only the migration may name the old product, and it has to keep doing so"
        )
    }

    func testNoUserFacingStringNamesAService() {
        // `Sources/Dot` is the surface a person reads: the welcome, Settings,
        // the menu labels, the HUD messages and the log keys. Every service
        // name it shows has to come from a row, so no string literal there may
        // carry one. A vendor written into a sentence is how Dot came to
        // present one service as the expected case.
        let directory = Self.root.appendingPathComponent("Sources/Dot", isDirectory: true)
        var offenders: [String] = []
        for file in Self.swiftFiles(in: directory) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                for quoted in Self.quotedSegments(in: String(line)) {
                    let lower = quoted.lowercased()
                    guard let token = Self.vendorTokens.first(where: { lower.contains($0) }) else {
                        continue
                    }
                    offenders.append("\(file.lastPathComponent):\(index + 1) names \(token): \(quoted)")
                }
            }
        }
        XCTAssertEqual(
            offenders,
            [],
            "the UI layer may only show the name of a row; these strings name a service themselves"
        )

        // The rows are the other half of the same rule. Every view draws
        // `preset.name`, so a brand written into a row is on screen even though
        // no view names it — which is exactly how the picker went on saying it.
        // Every declaration is scanned, including a row the picker no longer
        // draws: a retired row is one edit away from being offered again.
        var presetOffenders: [String] = []
        var declaredNames: [String] = []
        let core = Self.root.appendingPathComponent("Sources/DotCore", isDirectory: true)
        for file in Self.swiftFiles(in: core) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                let declaration = String(line).trimmingCharacters(in: .whitespaces)
                guard declaration.hasPrefix("name:") else { continue }
                for quoted in Self.quotedSegments(in: declaration) {
                    declaredNames.append(quoted)
                    let lower = quoted.lowercased()
                    guard let token = Self.brandTokens.first(where: { lower.contains($0) }) else {
                        continue
                    }
                    presetOffenders.append("\(file.lastPathComponent):\(index + 1) names \(token): \(quoted)")
                }
            }
        }
        XCTAssertEqual(
            presetOffenders,
            [],
            "a row may not name the model or the vendor Dot was built around; that name is how it reached the picker"
        )
        // The scan has to have seen the rows, or a moved declaration would make
        // this guard pass by finding nothing.
        for preset in ProviderPreset.declared {
            XCTAssertTrue(
                declaredNames.contains(preset.name),
                "the row \(preset.id) was not scanned — the declarations moved or changed shape"
            )
        }
    }

    func testNoSentenceInTheCoreNamesTheVendor() {
        // The UI scan above covers `Sources/Dot`, which is where a person
        // reads. A sentence in the core is still a sentence a person reads:
        // ``ProviderError`` carries a message the HUD shows verbatim, and the
        // one that told the user to set the vendor's key sat in a provider the
        // picker no longer offers. A view-layer sweep cannot see it, which is
        // how it outlived every earlier pass.
        //
        // Only literals with a space are prose. An identifier, a model id and
        // a base URL carry the vendor's own spelling and are data: they have
        // no space, so this scan leaves them alone without an allowlist. The
        // one gap left is a multi-line literal, whose interior lines carry no
        // quotes to segment; no user-facing copy lives in one.
        let core = Self.root.appendingPathComponent("Sources/DotCore", isDirectory: true)
        var offenders: [String] = []
        var sentences = 0
        for file in Self.swiftFiles(in: core) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                for quoted in Self.quotedSegments(in: String(line)) where quoted.contains(" ") {
                    sentences += 1
                    let lower = quoted.lowercased()
                    guard let token = Self.brandTokens.first(where: { lower.contains($0) }) else {
                        continue
                    }
                    offenders.append("\(file.lastPathComponent):\(index + 1) names \(token): \(quoted)")
                }
            }
        }
        XCTAssertEqual(
            offenders,
            [],
            "the core's messages reach the HUD verbatim; they may not name the vendor"
        )
        // The scan has to have seen the prose, or a moved declaration would
        // make this guard pass by finding nothing.
        XCTAssertGreaterThan(sentences, 60, "the scan found almost no prose — it is looking in the wrong place")
    }

    func testTheBundleIdentityIsTheProductIdentity() throws {
        let build = try String(
            contentsOf: Self.root.appendingPathComponent("scripts/build.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(build.contains("com.anandlo.dot"))
        XCTAssertTrue(build.contains("Dot.app"))
        XCTAssertFalse(build.contains(Self.legacyName), "build.sh still names the old product")

        let install = try String(
            contentsOf: Self.root.appendingPathComponent("scripts/install.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(install.contains("com.local.dot"))
        XCTAssertTrue(install.contains("/Applications/Dot.app") || install.contains("APP_NAME=\"Dot\""))
    }
}
