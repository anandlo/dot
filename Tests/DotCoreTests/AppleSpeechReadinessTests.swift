import Foundation
import XCTest

@testable import DotCore

final class AppleSpeechReadinessTests: XCTestCase {
    private static let missingMessage =
        "The on-device speech model for English (United States) is not installed on this Mac."

    func testInstalledLocaleIsVerifiedAndAvailable() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let provider = AppleSpeechProvider(
            localeIdentifier: "en_US",
            readiness: environment(installed: ["en-US"], calls: calls)
        )

        let check = await provider.verifyCredentials()
        let available = await provider.isAvailable()
        XCTAssertEqual(check, .verified)
        XCTAssertTrue(available)
    }

    func testBareLanguageIdentifierUsesTheSupportedLocale() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let provider = AppleSpeechProvider(
            localeIdentifier: "en",
            readiness: environment(
                installed: ["en-US"],
                calls: calls,
                supported: { _ in Locale(identifier: "en-US") }
            )
        )

        let check = await provider.verifyCredentials()
        let available = await provider.isAvailable()
        XCTAssertEqual(check, .verified)
        XCTAssertTrue(available)
    }

    func testUnderscoreLocaleIdentifierUsesTheSupportedLocale() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let provider = AppleSpeechProvider(
            localeIdentifier: "zh_CN",
            readiness: environment(
                installed: ["zh-Hans-CN"],
                calls: calls,
                supported: { _ in Locale(identifier: "zh-Hans-CN") }
            )
        )

        let check = await provider.verifyCredentials()
        let available = await provider.isAvailable()
        XCTAssertEqual(check, .verified)
        XCTAssertTrue(available)
    }

    func testMissingLocaleReportsNeedsSetupAndIsUnavailable() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let provider = AppleSpeechProvider(
            localeIdentifier: "en_US",
            readiness: environment(installed: ["fr-FR"], calls: calls)
        )

        let check = await provider.verifyCredentials()
        guard case .needsSetup(let message) = check else {
            return XCTFail("expected needsSetup, got \(check)")
        }
        let available = await provider.isAvailable()
        XCTAssertEqual(message, Self.missingMessage)
        XCTAssertFalse(available)
    }

    func testLanguageOnlyInstalledLocaleDoesNotCountAsInstalled() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let provider = AppleSpeechProvider(
            localeIdentifier: "en_US",
            readiness: environment(
                installed: ["en-GB"],
                calls: calls,
                supported: { _ in Locale(identifier: "en-US") }
            )
        )

        let check = await provider.verifyCredentials()
        guard case .needsSetup(let message) = check else {
            return XCTFail("expected needsSetup, got \(check)")
        }
        let available = await provider.isAvailable()
        XCTAssertEqual(message, Self.missingMessage)
        XCTAssertFalse(available)
    }

    func testUnsupportedLocaleKeepsTheUnavailableMessage() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let provider = AppleSpeechProvider(
            localeIdentifier: "en_US",
            readiness: environment(
                installed: ["en-US"],
                calls: calls,
                supported: { _ in nil }
            )
        )

        let check = await provider.verifyCredentials()
        guard case .unavailable(let message) = check else {
            return XCTFail("expected unavailable, got \(check)")
        }
        let available = await provider.isAvailable()
        XCTAssertEqual(message, "The on-device transcriber does not speak en_US.")
        XCTAssertFalse(available)
    }

    func testBCP47MatchIsCaseInsensitive() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let provider = AppleSpeechProvider(
            localeIdentifier: "en_US",
            readiness: environment(installed: ["EN-us"], calls: calls)
        )

        let check = await provider.verifyCredentials()
        let available = await provider.isAvailable()
        XCTAssertEqual(check, .verified)
        XCTAssertTrue(available)
    }

    func testFingerprintDistinguishesInstalledAndMissingAssets() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let installed = AppleSpeechProvider(
            localeIdentifier: "en_US",
            readiness: environment(installed: ["en-US"], calls: calls)
        )
        let missing = AppleSpeechProvider(
            localeIdentifier: "en_US",
            readiness: environment(installed: ["fr-FR"], calls: calls)
        )

        let installedFingerprint = await installed.assetFingerprint()
        let missingFingerprint = await missing.assetFingerprint()
        XCTAssertEqual(installedFingerprint, "asset:installed")
        XCTAssertEqual(missingFingerprint, "asset:missing")
    }

    func testReadinessUsesOnlyTheInjectedSeam() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let provider = AppleSpeechProvider(
            localeIdentifier: "en_US",
            readiness: environment(installed: ["en-US"], calls: calls)
        )

        _ = await provider.isAvailable()
        XCTAssertEqual(calls.transcriber, 1)
        XCTAssertEqual(calls.supportedLocale, 1)
        XCTAssertEqual(calls.installedLocales, 1)
    }

    func testUnavailableTranscriberIsUnavailableWithoutReadingLocales() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let provider = AppleSpeechProvider(
            localeIdentifier: "en_US",
            readiness: environment(installed: ["en-US"], calls: calls, transcriberAvailable: false)
        )

        let available = await provider.isAvailable()
        XCTAssertFalse(available)
        let check = await provider.verifyCredentials()
        XCTAssertEqual(check, .unavailable("The on-device transcriber is not available on this Mac."))
        let fingerprint = await provider.assetFingerprint()
        XCTAssertEqual(fingerprint, "transcriber")
        XCTAssertEqual(calls.supportedLocale, 0)
        XCTAssertEqual(calls.installedLocales, 0)
    }

    func testInstalledLocaleWithAnImpliedScriptCountsAsInstalled() async throws {
        try requireAppleSpeech()
        let calls = ReadinessCalls()
        let provider = AppleSpeechProvider(
            localeIdentifier: "zh_CN",
            readiness: environment(
                installed: ["zh-CN"],
                calls: calls,
                supported: { _ in Locale(identifier: "zh-Hans-CN") }
            )
        )

        let available = await provider.isAvailable()
        XCTAssertTrue(available)
        let check = await provider.verifyCredentials()
        XCTAssertEqual(check, .verified)
    }

    private func requireAppleSpeech() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Apple Speech readiness needs macOS 26 or newer.")
        }
    }

    private func environment(
        installed: [String],
        calls: ReadinessCalls,
        transcriberAvailable: Bool = true,
        supported: (@Sendable (String) async -> Locale?)? = nil
    ) -> AppleSpeechReadinessEnvironment {
        let resolver: @Sendable (String) async -> Locale? =
            supported ?? { identifier in Locale(identifier: identifier) }
        return AppleSpeechReadinessEnvironment(
            transcriberIsAvailable: {
                calls.incrementTranscriber()
                return transcriberAvailable
            },
            supportedLocale: { identifier in
                calls.incrementSupportedLocale()
                return await resolver(identifier)
            },
            installedLocaleIdentifiers: {
                calls.incrementInstalledLocales()
                return installed
            }
        )
    }
}

private final class ReadinessCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriberCount = 0
    private var supportedLocaleCount = 0
    private var installedLocalesCount = 0

    var transcriber: Int {
        lock.lock()
        defer { lock.unlock() }
        return transcriberCount
    }

    var supportedLocale: Int {
        lock.lock()
        defer { lock.unlock() }
        return supportedLocaleCount
    }

    var installedLocales: Int {
        lock.lock()
        defer { lock.unlock() }
        return installedLocalesCount
    }

    func incrementTranscriber() {
        lock.lock()
        defer { lock.unlock() }
        transcriberCount += 1
    }

    func incrementSupportedLocale() {
        lock.lock()
        defer { lock.unlock() }
        supportedLocaleCount += 1
    }

    func incrementInstalledLocales() {
        lock.lock()
        defer { lock.unlock() }
        installedLocalesCount += 1
    }
}
