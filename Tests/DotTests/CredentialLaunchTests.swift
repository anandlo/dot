import Foundation
import os
import Security
import XCTest

@testable import Dot
@testable import DotCore

/// Launch must never decrypt a Keychain item. Each stale item of a self-signed
/// build carries its own SecurityAgent prompt, so even one data read at launch
/// can leave the app waiting on a dialog before it draws.
final class CredentialLaunchTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [CredentialQuery] = []
        func add(_ query: CredentialQuery) {
            lock.lock()
            calls.append(query)
            lock.unlock()
        }
        var snapshot: [CredentialQuery] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    func testTheLaunchProbeMakesNoDataRead() {
        let recorder = Recorder()
        let queries = CredentialQueryRecorder()
        let context = CredentialKeychainContext(
            recorder: queries,
            copyHandler: { query in
                recorder.add(CredentialQuery(
                    operation: "copy",
                    onMainThread: Thread.isMainThread,
                    service: query[kSecAttrService as String] as? String,
                    account: query[kSecAttrAccount as String] as? String,
                    returnsData: query[kSecReturnData as String] as? Bool == true,
                    returnsAttributes: query[kSecReturnAttributes as String] as? Bool == true
                ))
                return CredentialCopyResult(status: errSecItemNotFound)
            }
        )
        let store = CredentialBundleStore(context: context, account: "com.anandlo.dot.test")
        let probe = AppDelegate.credentialLaunchProbe(store: store)

        for id in ProviderRegistry.builtInIDs {
            XCTAssertFalse(probe.hasKey(id), "the in-memory keychain holds no items")
        }
        XCTAssertFalse(probe.readKey("openai") != nil)
        XCTAssertFalse(recorder.snapshot.isEmpty, "the probe never asked the Keychain anything")
        XCTAssertFalse(recorder.snapshot.contains { $0.returnsData }, "launch decrypted a Keychain item")
        XCTAssertTrue(recorder.snapshot.allSatisfy(\.returnsAttributes))
        XCTAssertEqual(
            queries.calls.filter(\.returnsData).count,
            0,
            "launch performed a secret data read"
        )
    }

    func testTheLaunchBodyContainsNoCredentialRead() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Dot/AppDelegate.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(source.range(of: "func applicationWillTerminate", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        for forbidden in [
            ".key(for:",
            "CredentialStore.read(",
            "resolvedKey(",
            "readSecret(",
            "warmCredentials(",
            "migrateProviderIfNeeded(",
            "CredentialFirstUse.resolve(",
        ] {
            XCTAssertFalse(body.contains(forbidden), "launch calls \(forbidden)")
        }
    }

    private func appDelegateSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Dot/AppDelegate.swift"),
            encoding: .utf8
        )
    }

    private func launchBody() throws -> String {
        let source = try appDelegateSource()
        let start = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(source.range(of: "func applicationWillTerminate", range: start.lowerBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    /// Apple Speech is keyless. Removing the launch warm left `provider` nil
    /// forever, so the first stop threw "There is no provider." The build uses
    /// only keys already in memory, so a keyless launch must still build it.
    func testLaunchBuildsTheAppleProviderWithoutADataRead() throws {
        let body = try launchBody()
        XCTAssertTrue(body.contains("rebuildProvider()"), "launch never builds a provider")
        XCTAssertTrue(
            body.contains("canBuildWithoutKey(config)"),
            "launch does not build every provider that needs no key"
        )
        XCTAssertFalse(ProviderPreset.requiresKey(for: ProviderIdentifier.apple))
        XCTAssertTrue(ProviderPreset.requiresKey(for: ProviderIdentifier.openAI))

        let queries = CredentialQueryRecorder()
        let context = CredentialKeychainContext(
            recorder: queries,
            copyHandler: { query in
                XCTAssertFalse(
                    query[kSecReturnData as String] as? Bool == true,
                    "a launch probe decrypted a Keychain item"
                )
                return CredentialCopyResult(status: errSecItemNotFound)
            }
        )
        let store = CredentialBundleStore(context: context, account: "com.anandlo.dot.test")
        var config = DotConfig.default
        config.provider = ProviderIdentifier.apple
        let probe = AppDelegate.credentialLaunchProbe(store: store)
        XCTAssertFalse(probe.hasKey(ProviderIdentifier.apple), "the in-memory keychain holds no items")

        let view = CredentialCache(reader: { _ in .missing }, logsReads: false)
        let provider = try ProviderRegistry.selectedProvider(config: config, credentials: view)
        XCTAssertEqual(provider.id, ProviderIdentifier.apple)
        XCTAssertFalse(queries.calls.contains(where: \.returnsData), "launch decrypted a Keychain item")
    }

    /// A keyless provider that is somehow absent must still be rebuilt on first
    /// use, and that rebuild must not start a credential read.
    func testAKeylessFirstUseNeedsNoCredentialRead() async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let cache = CredentialCache(reader: { _ in
            reads.withLock { $0 += 1 }
            return .missing
        }, logsReads: false)
        XCTAssertTrue(
            CredentialFirstUse.takeNeedsRebuild(
                providerAvailable: false,
                providerID: ProviderIdentifier.apple,
                cache: cache
            ),
            "a missing Apple provider could not finish a take"
        )

        let rebuilt = OSAllocatedUnfairLock(initialState: false)
        let found = await CredentialFirstUse.resolve(ProviderIdentifier.apple, cache: cache) {
            rebuilt.withLock { $0 = true }
        }
        XCTAssertTrue(found, "a keyless provider needs no key")
        XCTAssertTrue(rebuilt.withLock { $0 }, "the first-use rebuild callback did not run")
        XCTAssertEqual(reads.withLock { $0 }, 0, "first use of a keyless provider read a key")
    }

    /// The shared first-use flight ignores task cancellation; the awaiting
    /// caller has to stop before it applies the rebuild.
    func testTranscribeChecksCancellationAfterTheFirstUseResolve() throws {
        let source = try appDelegateSource()
        let start = try XCTUnwrap(source.range(of: "private func transcribe(samples:"))
        let end = try XCTUnwrap(source.range(of: "private func uploadWAV", range: start.lowerBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        let resolve = try XCTUnwrap(body.range(of: "await CredentialFirstUse.resolve("))
        let apply = try XCTUnwrap(body.range(of: "applyFirstUseRebuild(", range: resolve.upperBound..<body.endIndex))
        let between = String(body[resolve.upperBound..<apply.lowerBound])
        XCTAssertTrue(between.contains("try Task.checkCancellation()"), "a cancelled stop still rebuilt the provider")
    }

    private func loopbackConfig() -> DotConfig {
        var config = DotConfig.default
        config.provider = ProviderIdentifier.openAI
        var settings = config.settings(for: ProviderIdentifier.openAI)
        settings.baseURL = "http://127.0.0.1:8791/v1"
        config.providers[ProviderIdentifier.openAI] = settings
        return config
    }

    /// A local OpenAI-shaped endpoint declares an optional key. It has to be
    /// built at launch from empty credentials, and its first use must not read
    /// the Keychain just because the provider id is `openai`.
    func testLoopbackEndpointBuildsAtLaunchWithoutAKeyRead() throws {
        let body = try launchBody()
        XCTAssertTrue(
            body.contains("canBuildWithoutKey(config)"),
            "launch skips the optional-key endpoint on this Mac"
        )
        let config = loopbackConfig()
        XCTAssertEqual(ProviderPreset.presenting(config).key, .optional)
        XCTAssertTrue(ProviderPreset.canBuildWithoutKey(config), "the loopback endpoint still looks keyed")

        let queries = CredentialQueryRecorder()
        let context = CredentialKeychainContext(
            recorder: queries,
            copyHandler: { query in
                XCTAssertFalse(
                    query[kSecReturnData as String] as? Bool == true,
                    "launch decrypted a Keychain item"
                )
                return CredentialCopyResult(status: errSecItemNotFound)
            }
        )
        let store = CredentialBundleStore(context: context, account: "com.anandlo.dot.test")
        XCTAssertFalse(AppDelegate.credentialLaunchProbe(store: store).hasKey(ProviderIdentifier.openAI))

        let provider = try ProviderRegistry.selectedProvider(config: config, credentials: .empty)
        XCTAssertEqual(provider.id, ProviderIdentifier.openAI)
        XCTAssertFalse(queries.calls.contains(where: \.returnsData), "launch decrypted a Keychain item")

        let reads = OSAllocatedUnfairLock(initialState: 0)
        let cache = CredentialCache(reader: { _ in
            reads.withLock { $0 += 1 }
            return .missing
        }, logsReads: false)
        let needsRead = CredentialFirstUse.takeNeedsRebuild(
            providerAvailable: true,
            providerID: ProviderIdentifier.openAI,
            cache: cache,
            providerBuiltWithoutKey: true,
            buildGeneration: cache.generation(for: ProviderIdentifier.openAI)
        )
        XCTAssertFalse(needsRead, "first use of the loopback endpoint started a key read")
        XCTAssertEqual(reads.withLock { $0 }, 0, "the rebuild decision read a key")
    }

    /// Settings resolves a stored key into the same cache after a provider was
    /// built without it. The press and the Stop must both notice, even though
    /// the provider is already non-nil.
    func testAKeyResolvedAfterTheBuildForcesAFirstUseRebuild() async throws {
        let source = try appDelegateSource()
        XCTAssertTrue(source.contains("providerBuiltWithoutKey"), "the build did not remember a missing key")
        XCTAssertTrue(source.contains("buildGeneration:"), "first use does not compare the build generation")
        XCTAssertTrue(source.contains("credentialRebuildGate.forget"), "an old gate decision can suppress the new key")

        let cache = CredentialCache(reader: { _ in .key("stored-key") }, logsReads: false)
        let resolved = await cache.resolved(for: ProviderIdentifier.openAI)
        XCTAssertEqual(resolved, "stored-key")
        let generation = cache.generation(for: ProviderIdentifier.openAI)
        XCTAssertTrue(
            CredentialFirstUse.takeNeedsRebuild(
                providerAvailable: true,
                providerID: ProviderIdentifier.openAI,
                cache: cache,
                providerBuiltWithoutKey: true,
                buildGeneration: generation
            ),
            "a key resolved after the build was ignored"
        )
        XCTAssertFalse(
            CredentialFirstUse.takeNeedsRebuild(
                providerAvailable: true,
                providerID: ProviderIdentifier.openAI,
                cache: cache,
                providerBuiltWithoutKey: false,
                buildGeneration: generation
            ),
            "an unchanged build kept asking to rebuild"
        )

        cache.store("rotated-key", for: ProviderIdentifier.openAI)
        XCTAssertTrue(
            CredentialFirstUse.takeNeedsRebuild(
                providerAvailable: true,
                providerID: ProviderIdentifier.openAI,
                cache: cache,
                providerBuiltWithoutKey: false,
                buildGeneration: generation
            ),
            "a newer cache generation was ignored"
        )
    }
}
