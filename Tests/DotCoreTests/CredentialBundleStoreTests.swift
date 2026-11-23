import Foundation
import os
import Security
import XCTest

@testable import DotCore

/// An in-memory Keychain for credential tests.
///
/// Every query is served from this object; no test in this file can read or
/// write the login Keychain. Data reads and all mutations refuse to run on the
/// main thread, so a synchronous credential call on the main actor fails here.
private final class InMemoryCredentialKeychain: @unchecked Sendable {
    private struct Item {
        var data: Data
        var generic: Data?
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var observed: [CredentialQuery] = []
    var recorder = CredentialQueryRecorder()

    private func observe(
        _ operation: String,
        service: String,
        account: String,
        returnsData: Bool = false
    ) {
        let query = CredentialQuery(
            operation: operation,
            onMainThread: Thread.isMainThread,
            service: service,
            account: account,
            returnsData: returnsData,
            returnsAttributes: false
        )
        lock.lock()
        observed.append(query)
        lock.unlock()
    }

    var mainThreadDataOperations: [CredentialQuery] {
        lock.lock()
        defer { lock.unlock() }
        return observed.filter { $0.returnsData || $0.operation != "copy" }
    }

    func resetRecorder() {
        recorder = CredentialQueryRecorder()
    }
    var dataCopyStatus: (@Sendable (String, String) -> OSStatus?)?
    var attributeCopyStatus: (@Sendable (String, String) -> OSStatus?)?
    var mutationStatus: (@Sendable (String, String) -> OSStatus?)?
    var addStatus: (@Sendable (String, String) -> OSStatus?)?
    var deletionStatus: (@Sendable (String, String) -> OSStatus?)?
    var beforeDataCopy: (@Sendable () -> Void)?
    var beforeUpdate: (@Sendable (String, String) -> Void)?

    var updateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observed.filter { $0.operation == "update" }.count
    }

    private func key(_ service: String, _ account: String) -> String {
        service + "\u{1}" + account
    }

    private func serviceAndAccount(_ query: [String: Any]) -> (String, String) {
        ((query[kSecAttrService as String] as? String) ?? "",
         (query[kSecAttrAccount as String] as? String) ?? "")
    }

    func seed(service: String, account: String, data: Data, generic: Data? = nil) {
        lock.lock()
        items[key(service, account)] = Item(data: data, generic: generic)
        lock.unlock()
    }

    func item(service: String, account: String) -> (data: Data, generic: Data?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = items[key(service, account)] else { return nil }
        return (item.data, item.generic)
    }

    func count(service: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return items.keys.filter { $0.hasPrefix(service + "\u{1}") }.count
    }

    func copy(_ query: [String: Any]) -> CredentialCopyResult {
        let (service, account) = serviceAndAccount(query)
        let wantsData = query[kSecReturnData as String] as? Bool == true
        observe(
            "copy",
            service: service,
            account: account,
            returnsData: wantsData
        )
        if wantsData {
            beforeDataCopy?()
        }
        if wantsData, let status = dataCopyStatus?(service, account) {
            return CredentialCopyResult(status: status)
        }
        if !wantsData, let status = attributeCopyStatus?(service, account) {
            return CredentialCopyResult(status: status)
        }
        lock.lock()
        guard let item = items[key(service, account)] else {
            lock.unlock()
            return CredentialCopyResult(status: errSecItemNotFound)
        }
        if wantsData {
            lock.unlock()
            return CredentialCopyResult(status: errSecSuccess, item: item.data as CFTypeRef)
        }
        var attributes: [String: Any] = [
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let generic = item.generic { attributes[kSecAttrGeneric as String] = generic }
        lock.unlock()
        return CredentialCopyResult(status: errSecSuccess, item: attributes as CFDictionary as CFTypeRef)
    }

    func add(_ query: [String: Any]) -> OSStatus {
        let (service, account) = serviceAndAccount(query)
        observe("add", service: service, account: account)
        if let status = addStatus?(service, account) { return status }
        if let status = mutationStatus?(service, account) { return status }
        let itemKey = key(service, account)
        lock.lock()
        defer { lock.unlock() }
        guard items[itemKey] == nil else { return errSecDuplicateItem }
        items[itemKey] = Item(
            data: query[kSecValueData as String] as? Data ?? Data(),
            generic: query[kSecAttrGeneric as String] as? Data
        )
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        let (service, account) = serviceAndAccount(query)
        observe("update", service: service, account: account)
        beforeUpdate?(service, account)
        if let status = mutationStatus?(service, account) { return status }
        let itemKey = key(service, account)
        lock.lock()
        defer { lock.unlock() }
        guard var item = items[itemKey] else { return errSecItemNotFound }
        if let data = attributes[kSecValueData as String] as? Data { item.data = data }
        if let generic = attributes[kSecAttrGeneric as String] as? Data { item.generic = generic }
        items[itemKey] = item
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let (service, account) = serviceAndAccount(query)
        observe("delete", service: service, account: account)
        if let status = deletionStatus?(service, account) { return status }
        lock.lock()
        defer { lock.unlock() }
        guard items.removeValue(forKey: key(service, account)) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}

/// The bundled Keychain item, exercised entirely through an injected store.
final class CredentialBundleStoreTests: XCTestCase {
    private let account = "com.anandlo.dot.test"
    private let legacyAccount = "anandlo-test"

    private func context(
        _ keychain: InMemoryCredentialKeychain
    ) -> CredentialKeychainContext {
        CredentialKeychainContext(
            recorder: keychain.recorder,
            copyHandler: { keychain.copy($0) },
            addHandler: { keychain.add($0) },
            updateHandler: { keychain.update($0, attributes: $1) },
            deleteHandler: { keychain.delete($0) }
        )
    }

    private func store(_ keychain: InMemoryCredentialKeychain) -> CredentialBundleStore {
        CredentialBundleStore(
            context: context(keychain),
            account: account,
            legacyAccount: legacyAccount
        )
    }

    private func bundleData(_ keychain: InMemoryCredentialKeychain) -> Data? {
        keychain.item(service: CredentialBundle.service, account: account)?.data
    }

    private func bundleGeneric(_ keychain: InMemoryCredentialKeychain) -> String? {
        guard let generic = keychain.item(service: CredentialBundle.service, account: account)?.generic
        else { return nil }
        return String(data: generic, encoding: .utf8)
    }

    private func assertCredentialError<T>(
        _ expression: @autoclosure () async throws -> T,
        expected: CredentialError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CredentialError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func markerIDs(_ keychain: InMemoryCredentialKeychain) -> Set<String> {
        guard let generic = keychain.item(
            service: CredentialBundle.migrationService,
            account: account
        )?.generic else { return [] }
        return Set((String(data: generic, encoding: .utf8) ?? "").split(separator: ",").map(String.init))
    }

    func testSeveralProvidersAreKeptInOneItemAndReadOnce() async throws {
        let keychain = InMemoryCredentialKeychain()
        let writer = store(keychain)
        for (id, key) in ["openai": "key-one", "groq": "key-two", "xiaomi": "key-three"] {
            try await writer.writeAsync(key, providerID: id)
        }
        XCTAssertEqual(keychain.count(service: CredentialBundle.service), 1)
        XCTAssertEqual(keychain.count(service: CredentialStore.servicePrefix + "OPENAI"), 0)
        keychain.resetRecorder()

        let reader = store(keychain)
        do {
            let resolved = try await reader.resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "key-one")
        }
        do {
            let resolved = try await reader.resolvedKey(for: "groq")
            XCTAssertEqual(resolved, "key-two")
        }
        do {
            let resolved = try await reader.resolvedKey(for: "xiaomi")
            XCTAssertEqual(resolved, "key-three")
        }
        let bundleReads = keychain.recorder.calls.filter {
            $0.returnsData && $0.service == CredentialBundle.service
        }
        XCTAssertEqual(bundleReads.count, 1, "all keys come from one read of the bundle")
    }

    func testHasKeyNeverAsksForData() async throws {
        let keychain = InMemoryCredentialKeychain()
        let writer = store(keychain)
        try await writer.writeAsync("a", providerID: "openai")
        try await writer.writeAsync("b", providerID: "xiaomi")
        keychain.seed(
            service: CredentialStore.serviceName(for: "groq"),
            account: CredentialStore.account(for: "groq"),
            data: Data("legacy".utf8)
        )
        keychain.resetRecorder()

        let reader = store(keychain)
        XCTAssertTrue(reader.hasKey(for: "openai"))
        XCTAssertTrue(reader.hasKey(for: "xiaomi"))
        XCTAssertTrue(reader.hasKey(for: "groq"))
        XCTAssertFalse(reader.hasKey(for: "azure"))
        XCTAssertFalse(keychain.recorder.hasDataRead, "the status probe decrypted an item")
        XCTAssertTrue(keychain.recorder.calls.allSatisfy(\.returnsAttributes))
    }

    func testALegacyDotItemIsMigratedIntoTheBundleAndDeleted() async throws {
        let keychain = InMemoryCredentialKeychain()
        let service = CredentialStore.serviceName(for: "openai")
        keychain.seed(service: service, account: CredentialStore.account(for: "openai"), data: Data("old-openai-key".utf8))

        let reader = store(keychain)
        do {
            let resolved = try await reader.resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "old-openai-key")
        }
        XCTAssertNil(keychain.item(service: service, account: CredentialStore.account(for: "openai")))
        XCTAssertEqual(keychain.count(service: CredentialBundle.service), 1)
        XCTAssertTrue(keychain.recorder.calls.contains {
            $0.operation == "delete" && $0.service == service
        })
        do {
            let resolved = try await store(keychain).resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "old-openai-key")
        }
    }

    func testMigrationMarkerStopsARepeatedLegacyCopy() async throws {
        let keychain = InMemoryCredentialKeychain()
        let service = CredentialStore.serviceName(for: "openai")
        let legacyAccountName = CredentialStore.account(for: "openai")
        keychain.seed(service: service, account: legacyAccountName, data: Data("old-key".utf8))
        do {
            let resolved = try await store(keychain).resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "old-key")
        }
        XCTAssertTrue(markerIDs(keychain).contains("openai"))

        keychain.seed(service: CredentialBundle.service, account: account, data: Data("{}".utf8))
        keychain.seed(service: service, account: legacyAccountName, data: Data("changed-key".utf8))
        do {
            let resolved = try await store(keychain).resolvedKey(for: "openai")
            XCTAssertNil(resolved)
        }
        XCTAssertNotNil(
            keychain.item(service: service, account: legacyAccountName),
            "a finished migration must not read the old item again"
        )
    }

    func testInteractionNotAllowedNeverSetsTheMigrationMarker() async throws {
        let keychain = InMemoryCredentialKeychain()
        let service = CredentialStore.serviceName(for: "openai")
        keychain.seed(service: service, account: CredentialStore.account(for: "openai"), data: Data("old-key".utf8))
        keychain.dataCopyStatus = { copyService, _ in
            copyService == service ? errSecInteractionNotAllowed : nil
        }

        await assertCredentialError(
            try await store(keychain).resolvedKey(for: "openai"),
            expected: .unavailable(errSecInteractionNotAllowed)
        )
        XCTAssertTrue(markerIDs(keychain).isEmpty, "a -25308 read must be retried on the next use")
    }

    func testInvalidOwnerEditOnLegacyDeleteIsNonFatal() async throws {
        let keychain = InMemoryCredentialKeychain()
        let service = CredentialStore.serviceName(for: "openai")
        keychain.seed(service: service, account: CredentialStore.account(for: "openai"), data: Data("old-key".utf8))
        keychain.deletionStatus = { _, _ in errSecInvalidOwnerEdit }

        do {
            let resolved = try await store(keychain).resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "old-key")
        }
        XCTAssertTrue(markerIDs(keychain).contains("openai"))
    }

    func testAnOldNameItemIsMigratedAndDeleted() async throws {
        let keychain = InMemoryCredentialKeychain()
        let service = DotMigration.legacyKeychainPrefix + "OPENAI"
        keychain.seed(service: service, account: CredentialStore.account(for: "openai"), data: Data("old-ion-key".utf8))
        do {
            let resolved = try await store(keychain).resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "old-ion-key")
        }
        XCTAssertNil(keychain.item(service: service, account: CredentialStore.account(for: "openai")))
    }

    func testTheXiaomiToolItemIsCopiedButNeverDeleted() async throws {
        let keychain = InMemoryCredentialKeychain()
        keychain.seed(service: LegacyCredentialMigration.xiaomiService, account: legacyAccount, data: Data("tool-key".utf8))

        do {
            let resolved = try await store(keychain).resolvedKey(for: "xiaomi")
            XCTAssertEqual(resolved, "tool-key")
        }
        XCTAssertNotNil(keychain.item(service: LegacyCredentialMigration.xiaomiService, account: legacyAccount))
        do {
            let resolved = try await store(keychain).resolvedKey(for: "xiaomi")
            XCTAssertEqual(resolved, "tool-key")
        }
    }

    func testDeniedReadIsNotRememberedAsMissingAndNeedsAnExplicitRetry() async throws {
        let keychain = InMemoryCredentialKeychain()
        keychain.dataCopyStatus = { service, _ in
            service == CredentialBundle.service ? errSecUserCanceled : nil
        }
        let reader = store(keychain)

        await assertCredentialError(
            try await reader.resolvedKey(for: "openai"),
            expected: .denied(errSecUserCanceled)
        )
        await assertCredentialError(
            try await reader.resolvedKey(for: "openai"),
            expected: .denied(errSecUserCanceled)
        )
        let reads = keychain.recorder.calls.filter {
            $0.returnsData && $0.service == CredentialBundle.service
        }.count
        XCTAssertEqual(reads, 1, "a denial was retried without an explicit action")

        reader.allowRetry()
        keychain.dataCopyStatus = nil
        do {
            let resolved = try await reader.resolvedKey(for: "openai")
            XCTAssertNil(resolved)
        }
        let readsAfterRetry = keychain.recorder.calls.filter {
            $0.returnsData && $0.service == CredentialBundle.service
        }.count
        XCTAssertEqual(readsAfterRetry, reads + 1)
        XCTAssertFalse(reader.hasKey(for: "openai"))
    }

    func testDeleteRemovesOneProviderAndUpdatesTheAttributeList() async throws {
        let keychain = InMemoryCredentialKeychain()
        let writer = store(keychain)
        try await writer.writeAsync("a", providerID: "openai")
        try await writer.writeAsync("b", providerID: "groq")
        try await writer.deleteAsync(providerID: "openai")

        XCTAssertFalse(writer.hasKey(for: "openai"))
        XCTAssertTrue(writer.hasKey(for: "groq"))
        XCTAssertEqual(bundleGeneric(keychain), "groq")
        let fresh = store(keychain)
        do {
            let resolved = try await fresh.resolvedKey(for: "openai")
            XCTAssertNil(resolved)
        }
        do {
            let resolved = try await fresh.resolvedKey(for: "groq")
            XCTAssertEqual(resolved, "b")
        }
    }

    func testAnUnreadableBundleThrowsAndIsNotOverwritten() async throws {
        let keychain = InMemoryCredentialKeychain()
        let original = Data("not a key map".utf8)
        keychain.seed(
            service: CredentialBundle.service,
            account: account,
            data: original,
            generic: Data("openai".utf8)
        )
        let reader = store(keychain)

        await assertCredentialError(
            try await reader.resolvedKey(for: "openai"),
            expected: .unreadable
        )
        XCTAssertFalse(reader.hasKey(for: "openai"), "the UI must ask for a key")
        await assertCredentialError(
            try await reader.writeAsync("new-key", providerID: "openai"),
            expected: .unreadable
        )
        XCTAssertEqual(bundleData(keychain), original, "an unreadable bundle was replaced")

        let outcome = CredentialCache.resolve(
            providerID: "openai",
            read: { id in try reader.key(for: id) },
            hasKey: { reader.hasKey(for: $0) }
        )
        guard case .failed = outcome else {
            return XCTFail("an unreadable bundle must be a failed read, not \(outcome)")
        }

        let cache = CredentialCache(bundle: reader)
        for attempt in 1...2 {
            let key = await cache.resolved(for: "openai")
            XCTAssertNil(key, "attempt \(attempt) invented a key from unreadable bytes")
            XCTAssertFalse(cache.isResolved("openai"), "attempt \(attempt) cached a missing answer")
            XCTAssertTrue(cache.readFailed("openai"), "attempt \(attempt) lost the read failure")
            XCTAssertEqual(bundleData(keychain), original, "attempt \(attempt) replaced the unreadable bundle")
        }
    }
}

extension CredentialBundleStoreTests {
    /// A first-use read is awaited to its real answer, never to a deadline.
    func testALateFirstUseIsAwaitedSharedAndRebuildsAfterTheAnswer() async throws {
        final class Gate: @unchecked Sendable {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var calls = 0
            func note() {
                lock.lock()
                calls += 1
                lock.unlock()
                entered.signal()
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return calls
            }
        }
        let gate = Gate()
        let cache = CredentialCache(reader: { _ in
            gate.note()
            _ = gate.release.wait(timeout: .now() + 10)
            return .key("late-key")
        }, logsReads: false)
        let rebuilt = OSAllocatedUnfairLock(initialState: false)

        let first = Task {
            await CredentialFirstUse.resolve("openai", cache: cache) {
                XCTAssertEqual(cache.resolvedKey(for: "openai"), "late-key")
                rebuilt.withLock { $0 = true }
            }
        }
        let second = Task { await CredentialFirstUse.resolve("openai", cache: cache) }

        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success, "the read never started")
        XCTAssertFalse(rebuilt.withLock { $0 }, "the rebuild ran before the answer")
        // A two second deadline would have returned by now with no key.
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertFalse(rebuilt.withLock { $0 }, "the rebuild ran on a deadline instead of the answer")
        gate.release.signal()

        let firstFound = await first.value
        let secondFound = await second.value
        XCTAssertTrue(firstFound)
        XCTAssertTrue(secondFound)
        XCTAssertEqual(gate.count, 1, "two callers started two keychain reads")
        XCTAssertEqual(cache.resolvedKey(for: "openai"), "late-key")
        XCTAssertTrue(rebuilt.withLock { $0 }, "the rebuild callback never ran")
    }

    /// The in-flight task belongs to the store, so simultaneous callers share one read.
    func testConcurrentStoreCallersShareOneLateRead() async throws {
        let keychain = InMemoryCredentialKeychain()
        keychain.seed(service: CredentialBundle.service, account: account, data: Data("{}".utf8))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        keychain.beforeDataCopy = {
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        let sharedStore = store(keychain)
        let first = Task { try await sharedStore.resolvedKey(for: "openai") }
        let second = Task { try await sharedStore.resolvedKey(for: "openai") }

        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the store never started a read")
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertTrue(sharedStore.isKeyReadInFlight("openai"))
        release.signal()
        do {
            let resolved = try await first.value
            XCTAssertNil(resolved)
        }
        do {
            let resolved = try await second.value
            XCTAssertNil(resolved)
        }
        let reads = keychain.recorder.calls.filter {
            $0.returnsData && $0.service == CredentialBundle.service
        }.count
        XCTAssertEqual(reads, 1, "two callers read the same bundle twice")
    }

    @MainActor
    func testAsyncWritesNeverTouchTheKeychainOnTheMainThread() async throws {
        let keychain = InMemoryCredentialKeychain()
        let store = store(keychain)
        try await store.writeAsync("async-key", providerID: "openai")
        try await store.deleteAsync(providerID: "openai")
        XCTAssertFalse(keychain.mainThreadDataOperations.isEmpty)
        XCTAssertTrue(
            keychain.mainThreadDataOperations.allSatisfy { !$0.onMainThread },
            "keychain data work ran on the main thread"
        )
    }

    /// A stop that lands after the key resolves but before the press callback
    /// runs still owes the take a rebuilt provider.
    func testStopAfterTheCacheResolvedStillRebuildsTheProvider() async throws {
        let cache = CredentialCache(reader: { _ in .key("late-key") }, logsReads: false)
        do {
            let resolved = await cache.resolved(for: "openai")
            XCTAssertEqual(resolved, "late-key")
        }
        XCTAssertTrue(cache.isResolved("openai"))

        XCTAssertTrue(
            CredentialFirstUse.takeNeedsRebuild(
                providerAvailable: false,
                providerID: "openai",
                cache: cache
            ),
            "a resolved cache does not mean the provider was rebuilt"
        )
        XCTAssertFalse(
            CredentialFirstUse.takeNeedsRebuild(
                providerAvailable: true,
                providerID: "openai",
                cache: cache
            )
        )
        XCTAssertTrue(
            CredentialFirstUse.takeNeedsRebuild(
                providerAvailable: false,
                providerID: ProviderIdentifier.apple,
                cache: cache
            ),
            "a keyless provider with no instance still needs a rebuild"
        )

        var providerAvailable = false
        if CredentialFirstUse.takeNeedsRebuild(
            providerAvailable: providerAvailable,
            providerID: "openai",
            cache: cache
        ) {
            _ = await CredentialFirstUse.resolve("openai", cache: cache)
            providerAvailable = cache.resolvedKey(for: "openai") == "late-key"
        }
        XCTAssertTrue(providerAvailable, "the take finished without a provider")
    }
}

extension CredentialBundleStoreTests {
    /// Two saves must not read one merged map and then overwrite each other.
    func testConcurrentWritesKeepBothProviders() async throws {
        let keychain = InMemoryCredentialKeychain()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        keychain.beforeUpdate = { service, _ in
            guard service == CredentialBundle.service else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        let store = store(keychain)
        let first = Task { try await store.writeAsync("first-key", providerID: "openai") }
        let second = Task { try await store.writeAsync("second-key", providerID: "groq") }

        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "no write reached the backend")
        XCTAssertEqual(keychain.updateCount, 1, "the second save used a stale snapshot")
        release.signal()
        try await first.value
        try await second.value

        let data = try XCTUnwrap(bundleData(keychain))
        let map = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(map["openai"], "first-key")
        XCTAssertEqual(map["groq"], "second-key")
    }

    /// A late answer from an invalidated read must not replace a newer save.
    func testStaleReadDoesNotCommitOrReturnAnOldKey() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cache = CredentialCache(reader: { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return .key("old-key")
        }, logsReads: false)
        let stale = Task { await cache.resolved(for: "openai") }

        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the read never started")
        cache.store("new-key", for: "openai")
        release.signal()
        let returned = await stale.value
        XCTAssertNil(returned, "a stale read returned a key")
        XCTAssertEqual(cache.resolvedKey(for: "openai"), "new-key")
    }

    /// An explicit save is a new decision and may retry a previous denial.
    func testExplicitSaveRetriesAPreviouslyDeniedBundle() async throws {
        let keychain = InMemoryCredentialKeychain()
        keychain.dataCopyStatus = { service, _ in
            service == CredentialBundle.service ? errSecUserCanceled : nil
        }
        let reader = store(keychain)
        await assertCredentialError(
            try reader.key(for: "openai"),
            expected: .denied(errSecUserCanceled)
        )

        keychain.dataCopyStatus = nil
        try await reader.writeAsync("fresh-key", providerID: "openai")
        do {
            let resolved = try await reader.resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "fresh-key")
        }
    }

    /// A finished migration makes a retained legacy item invisible to status.
    func testMarkedLegacyItemDoesNotReportAKey() async throws {
        let keychain = InMemoryCredentialKeychain()
        let service = CredentialStore.serviceName(for: "openai")
        keychain.seed(service: service, account: CredentialStore.account(for: "openai"), data: Data("old".utf8))
        let reader = store(keychain)
        do {
            let resolved = try await reader.resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "old")
        }
        XCTAssertTrue(reader.hasKey(for: "openai"))

        keychain.seed(service: CredentialBundle.service, account: account, data: Data("{}".utf8))
        keychain.seed(service: service, account: CredentialStore.account(for: "openai"), data: Data("again".utf8))
        XCTAssertFalse(store(keychain).hasKey(for: "openai"), "a migrated item still looks keyed")
    }

    func testDeletingAProviderKeepsTheXiaomiToolItem() async throws {
        let keychain = InMemoryCredentialKeychain()
        keychain.seed(
            service: LegacyCredentialMigration.xiaomiService,
            account: legacyAccount,
            data: Data("tool-key".utf8)
        )
        let store = store(keychain)
        try await store.writeAsync("xiaomi-key", providerID: ProviderIdentifier.xiaomi)
        try await store.deleteAsync(providerID: ProviderIdentifier.xiaomi)

        XCTAssertNotNil(
            keychain.item(service: LegacyCredentialMigration.xiaomiService, account: legacyAccount),
            "the external tool's item was deleted"
        )
        XCTAssertNil(bundleData(keychain).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: String]
        }?[ProviderIdentifier.xiaomi])
    }

    /// A real bundle read is coalesced by cache generation and stays off main.
    func testBundleBackedCacheCoalescesAndStaysOffMain() async throws {
        let keychain = InMemoryCredentialKeychain()
        keychain.seed(
            service: CredentialBundle.service,
            account: account,
            data: Data(#"{"openai":"bundle-key"}"#.utf8)
        )
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        keychain.beforeDataCopy = {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        let sharedStore = store(keychain)
        let cache = CredentialCache(bundle: sharedStore)
        let first = Task { await cache.resolved(for: "openai") }
        let second = Task { await cache.resolved(for: "openai") }

        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the bundle was not read")
        XCTAssertTrue(cache.isReadInFlight("openai"), "in-flight read was not reported")
        release.signal()
        do {
            let firstKey = await first.value
            let secondKey = await second.value
            XCTAssertEqual(firstKey, "bundle-key")
            XCTAssertEqual(secondKey, "bundle-key")
        }
        let reads = keychain.recorder.calls.filter {
            $0.returnsData && $0.service == CredentialBundle.service
        }.count
        XCTAssertEqual(reads, 1, "two cache callers decrypted the bundle twice")
        XCTAssertTrue(keychain.mainThreadDataOperations.allSatisfy { !$0.onMainThread })
    }
}

extension CredentialBundleStoreTests {
    private final class GatedAnswers: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var answers: [String]
        private var gated = true

        init(_ answers: [String]) {
            self.answers = answers
        }

        func next(_ providerID: String) -> CredentialCache.Outcome {
            if gated {
                gated = false
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            lock.lock()
            defer { lock.unlock() }
            return answers.isEmpty ? .missing : .key(answers.removeFirst())
        }
    }

    private func assertInvalidationDuringSyncRead(
        invalidate: (CredentialCache) -> Void
    ) async throws {
        let answers = GatedAnswers(["old-key", "fresh-key"])
        let cache = CredentialCache(reader: answers.next, logsReads: false)
        let finished = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock(initialState: "pending")

        DispatchQueue.global().async {
            result.withLock { $0 = cache.key(for: "openai") ?? "none" }
            finished.signal()
        }
        XCTAssertEqual(answers.entered.wait(timeout: .now() + 5), .success, "the read never started")
        invalidate(cache)
        answers.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "the stale read never finished")
        XCTAssertEqual(result.withLock { $0 }, "none", "a stale read returned a key")

        let fresh = cache.key(for: "openai")
        XCTAssertEqual(fresh, "fresh-key", "a fresh read could not start after invalidation")
    }

    func testPerProviderInvalidationDuringAGenerationZeroSyncRead() async throws {
        try await assertInvalidationDuringSyncRead { cache in
            cache.invalidate("openai")
        }
    }

    func testGlobalInvalidationDuringAGenerationZeroSyncRead() async throws {
        try await assertInvalidationDuringSyncRead { cache in
            cache.invalidateAll()
        }
    }

    func testExplicitDeleteBeforeMigrationSuppressesARetainedLegacyItem() async throws {
        let keychain = InMemoryCredentialKeychain()
        let service = CredentialStore.serviceName(for: "openai")
        let legacyAccountName = CredentialStore.account(for: "openai")
        keychain.seed(service: service, account: legacyAccountName, data: Data("legacy-key".utf8))
        keychain.deletionStatus = { deletedService, _ in
            deletedService == service ? errSecInvalidOwnerEdit : nil
        }
        let deleter = store(keychain)

        try await deleter.deleteAsync(providerID: "openai")

        XCTAssertNotNil(
            keychain.item(service: service, account: legacyAccountName),
            "the retained legacy item was needed for this case"
        )
        XCTAssertTrue(markerIDs(keychain).contains("openai"), "delete did not persist suppression")
        XCTAssertFalse(deleter.hasKey(for: "openai"))

        let fresh = store(keychain)
        XCTAssertFalse(fresh.hasKey(for: "openai"), "a fresh store sees the retained item as a key")
        do {
            let resolved = try await fresh.resolvedKey(for: "openai")
            XCTAssertNil(resolved, "a fresh store reimported a deleted provider")
        }
    }

    func testDeleteDoesNotReportSuccessWhenSuppressionCannotBePersisted() async throws {
        let keychain = InMemoryCredentialKeychain()
        keychain.seed(
            service: CredentialStore.serviceName(for: "openai"),
            account: CredentialStore.account(for: "openai"),
            data: Data("legacy-key".utf8)
        )
        keychain.mutationStatus = { service, _ in
            service == CredentialBundle.migrationService ? errSecInteractionNotAllowed : nil
        }
        let deleter = store(keychain)

        await assertCredentialError(
            try await deleter.deleteAsync(providerID: "openai"),
            expected: .unavailable(errSecInteractionNotAllowed)
        )
        XCTAssertTrue(markerIDs(keychain).isEmpty, "a -25308 marker write was persisted")
    }
}

extension CredentialBundleStoreTests {
    func testRefusedSuppressionKeepsTheCurrentBundleKey() async throws {
        let keychain = InMemoryCredentialKeychain()
        let original = Data(#"{"openai":"primary-key"}"#.utf8)
        keychain.seed(service: CredentialBundle.service, account: account, data: original)
        keychain.addStatus = { service, _ in
            service == CredentialBundle.migrationService ? errSecUserCanceled : nil
        }
        let deleter = store(keychain)

        await assertCredentialError(
            try await deleter.deleteAsync(providerID: "openai"),
            expected: .denied(errSecUserCanceled)
        )
        XCTAssertEqual(bundleData(keychain), original, "the primary key was removed first")
        XCTAssertTrue(markerIDs(keychain).isEmpty, "a refused marker write was persisted")

        let fresh = store(keychain)
        do {
            let resolved = try await fresh.resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "primary-key")
        }
    }

    func testFailedMarkerReadDoesNotOverwritePriorSuppressionOrKey() async throws {
        let keychain = InMemoryCredentialKeychain()
        let original = Data(#"{"openai":"primary-key","groq":"groq-key"}"#.utf8)
        keychain.seed(service: CredentialBundle.service, account: account, data: original)
        keychain.seed(
            service: CredentialBundle.migrationService,
            account: account,
            data: Data(),
            generic: Data("groq,xiaomi".utf8)
        )
        keychain.attributeCopyStatus = { service, _ in
            service == CredentialBundle.migrationService ? errSecUserCanceled : nil
        }
        let deleter = store(keychain)

        await assertCredentialError(
            try await deleter.deleteAsync(providerID: "openai"),
            expected: .denied(errSecUserCanceled)
        )
        XCTAssertEqual(markerIDs(keychain), ["groq", "xiaomi"], "prior suppression was overwritten")
        XCTAssertEqual(bundleData(keychain), original, "the key was mutated despite the failed read")
    }
}

extension CredentialBundleStoreTests {
    /// An attribute probe with a status Dot did not expect must leave the
    /// migration unfinished so a later use can try the legacy item again.
    func testAnUnexpectedLegacyProbeStatusDoesNotSetTheMarker() async throws {
        let keychain = InMemoryCredentialKeychain()
        let service = CredentialStore.serviceName(for: "openai")
        let legacyAccountName = CredentialStore.account(for: "openai")
        keychain.seed(service: service, account: legacyAccountName, data: Data("old-key".utf8))
        keychain.attributeCopyStatus = { copyService, _ in
            copyService == service ? errSecIO : nil
        }

        await assertCredentialError(
            try await store(keychain).resolvedKey(for: "openai"),
            expected: .unexpectedStatus(errSecIO)
        )
        XCTAssertTrue(markerIDs(keychain).isEmpty, "a failed probe marked migration done")

        keychain.attributeCopyStatus = nil
        do {
            let resolved = try await store(keychain).resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "old-key", "a retry could not migrate the legacy key")
        }
    }

    /// The same rule for the decrypting read of a legacy item.
    func testAnUnexpectedLegacyDataStatusDoesNotSetTheMarker() async throws {
        let keychain = InMemoryCredentialKeychain()
        let service = CredentialStore.serviceName(for: "openai")
        let legacyAccountName = CredentialStore.account(for: "openai")
        keychain.seed(service: service, account: legacyAccountName, data: Data("old-key".utf8))
        keychain.dataCopyStatus = { copyService, _ in
            copyService == service ? errSecIO : nil
        }

        await assertCredentialError(
            try await store(keychain).resolvedKey(for: "openai"),
            expected: .unexpectedStatus(errSecIO)
        )
        XCTAssertTrue(markerIDs(keychain).isEmpty, "a failed legacy read marked migration done")

        keychain.dataCopyStatus = nil
        do {
            let resolved = try await store(keychain).resolvedKey(for: "openai")
            XCTAssertEqual(resolved, "old-key", "a retry could not migrate the legacy key")
        }
    }

    /// A write the Keychain refused is a denial or an unavailable store, not an
    /// unknown status, so settings can tell the person what happened.
    func testBundleWriteRefusalsKeepTheirCredentialStatus() async throws {
        let refusals: [(OSStatus, CredentialError)] = [
            (errSecUserCanceled, .denied(errSecUserCanceled)),
            (errSecAuthFailed, .denied(errSecAuthFailed)),
            (errSecInteractionNotAllowed, .unavailable(errSecInteractionNotAllowed)),
        ]
        for (status, expected) in refusals {
            let keychain = InMemoryCredentialKeychain()
            keychain.addStatus = { service, _ in
                service == CredentialBundle.service ? status : nil
            }
            await assertCredentialError(
                try await store(keychain).writeAsync("new-key", providerID: "openai"),
                expected: expected
            )
            XCTAssertNil(bundleData(keychain), "a refused write left a bundle")
        }
    }
}
