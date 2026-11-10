import XCTest

@testable import DotCore

/// How often a key is decrypted.
///
/// A decrypting `SecItemCopyMatching` blocks the calling thread for as long as
/// the Keychain takes — about fourteen seconds on a re-signed build of this app
/// — so the count is a latency budget, not a nicety. The reader is injected, so
/// these tests never touch the real Keychain.
final class CredentialCacheTests: XCTestCase {
    /// Counts the reads and answers what it is told.
    /// A one-shot gate the first read waits behind.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        private var used = false

        func waitIfFirst() {
            lock.lock()
            let first = !used
            used = true
            lock.unlock()
            guard first else { return }
            entered.signal()
            released.wait()
        }

        func waitUntilEntered() -> Bool {
            entered.wait(timeout: .now() + 5) == .success
        }

        func release() {
            released.signal()
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        var keys: [String: String] = [:]

        func read(_ providerID: String) -> CredentialCache.Outcome {
            lock.lock()
            ids.append(providerID)
            lock.unlock()
            guard let key = keys[providerID] else { return .missing }
            return .key(key)
        }

        var calls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }

        var count: Int { calls.count }
    }

    /// A reader that answers from a script, once per call.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [CredentialCache.Outcome]

        init(_ items: [CredentialCache.Outcome]) {
            self.items = items
        }

        func next() -> CredentialCache.Outcome {
            lock.lock()
            defer { lock.unlock() }
            return items.isEmpty ? .missing : items.removeFirst()
        }
    }

    func testAKeyIsDecryptedOncePerSession() {
        let counter = Counter()
        counter.keys["xiaomi"] = "secret-key"
        let cache = CredentialCache(reader: counter.read)

        for _ in 0..<50 {
            XCTAssertEqual(cache.key(for: "xiaomi"), "secret-key")
        }

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(cache.readCount, 1)
    }

    func testAMissingKeyIsRememberedTooButAFailureIsNot() {
        let counter = Counter()
        let cache = CredentialCache(reader: counter.read)

        // A provider with no key answers nil without asking again...
        XCTAssertNil(cache.key(for: "openai"))
        XCTAssertNil(cache.key(for: "openai"))
        XCTAssertEqual(counter.count, 1)

        // ...and a provider whose read failed is not remembered as "no key".
        let attempts = Counter()
        let failing = CredentialCache(reader: { id in
            _ = attempts.read(id)
            return attempts.count > 1 ? .key("arrived") : .failed("the Keychain is locked")
        })
        XCTAssertNil(failing.key(for: "xiaomi"))
        XCTAssertEqual(failing.key(for: "xiaomi"), "arrived")
        XCTAssertEqual(attempts.count, 2)
    }

    func testAWriteReplacesWhatTheCacheKnows() {
        let counter = Counter()
        let cache = CredentialCache(reader: counter.read)
        XCTAssertNil(cache.key(for: "xiaomi"))

        cache.store("new-key", for: "xiaomi")

        XCTAssertEqual(cache.key(for: "xiaomi"), "new-key")
        XCTAssertEqual(counter.count, 1)
        // The value is in the cache, so the provider is built without a read.
        XCTAssertEqual(counter.calls, ["xiaomi"])
    }

    func testInvalidatingMakesTheNextAskDecryptAgain() {
        let counter = Counter()
        counter.keys["xiaomi"] = "one"
        let cache = CredentialCache(reader: counter.read)
        XCTAssertEqual(cache.key(for: "xiaomi"), "one")

        counter.keys["xiaomi"] = "two"
        cache.invalidate("xiaomi")

        XCTAssertEqual(cache.key(for: "xiaomi"), "two")
        XCTAssertEqual(counter.count, 2)
    }

    func testResolvedTellsApartANilAnswerFromNoAnswer() {
        let cache = CredentialCache(reader: { _ in .missing })

        XCTAssertFalse(cache.isResolved("openai"))
        XCTAssertNil(cache.resolvedKey(for: "openai"))

        XCTAssertNil(cache.key(for: "openai"))

        XCTAssertTrue(cache.isResolved("openai"))
        XCTAssertNil(cache.resolvedKey(for: "openai"))
    }

    func testWarmingResolvesEveryProviderOnce() {
        let counter = Counter()
        counter.keys["openai"] = "a"
        counter.keys["xiaomi"] = "b"
        let cache = CredentialCache(reader: counter.read)

        cache.warm(ProviderRegistry.builtInIDs)
        cache.warm(ProviderRegistry.builtInIDs)

        XCTAssertEqual(counter.calls, ["openai", "groq", "azure", "deepgram", "elevenlabs", "xiaomi", "apple"])
        XCTAssertEqual(cache.readCount, 7)
    }

    func testTheReadDurationIsRecordedForTheLog() {
        let cache = CredentialCache(reader: { _ in
            usleep(2_000)
            return .key("slow")
        })

        _ = cache.key(for: "openai")

        let milliseconds = cache.readMilliseconds(for: "openai") ?? 0
        XCTAssertGreaterThanOrEqual(milliseconds, 1.5)
        XCTAssertLessThan(milliseconds, 1_000)
    }

    func testAnEmptyCacheNeverReadsAnything() {
        // The empty cache is its own object with a reader that answers nothing:
        // a provider description built from it cannot reach a Keychain.
        let empty = CredentialCache.empty
        XCTAssertNil(empty.key(for: "openai"))
        XCTAssertTrue(empty.isResolved("openai"))
        XCTAssertEqual(empty.readCount, 1)

        // Every empty cache is its own: nothing is shared between callers.
        XCTAssertFalse(CredentialCache.empty.isResolved("openai"))

        // And it is silent. Its answer is not a statement about the Keychain,
        // yet logging it wrote `credential.read found:false` into the log three
        // times a minute, which read exactly like a key that had disappeared.
        XCTAssertFalse(CredentialCache.empty.reportsReads)
        XCTAssertTrue(CredentialCache().reportsReads)
    }

    func testBuildingAProviderFromTheCacheReadsTheKeyOnce() throws {
        let counter = Counter()
        counter.keys[ProviderIdentifier.xiaomi] = "xiaomi-key"
        let cache = CredentialCache(reader: counter.read)
        var config = DotConfig.default
        config.provider = ProviderIdentifier.xiaomi

        for _ in 0..<10 {
            let provider = try ProviderRegistry.selectedProvider(config: config, credentials: cache)
            XCTAssertEqual((provider as? XiaomiASRProvider)?.apiKey, "xiaomi-key")
        }

        XCTAssertEqual(counter.count, 1)
    }

    func testAProviderDescriptionNeverTouchesACredential() throws {
        let counter = Counter()
        counter.keys[ProviderIdentifier.xiaomi] = "xiaomi-key"
        let cache = CredentialCache(reader: counter.read)

        for id in ProviderRegistry.builtInIDs {
            let descriptor = try ProviderRegistry.descriptor(id: id, config: .default)
            XCTAssertFalse(descriptor.displayName.isEmpty)
            XCTAssertEqual(descriptor.id, id)
        }

        // A description does not need a key, so it does not ask for one.
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(cache.readCount, 0)

        // The real build still finds the key.
        let provider = try ProviderRegistry.selectedProvider(config: .default, credentials: cache)
        XCTAssertNotNil(provider)
    }

    func testTheDescriptorNamesMatchTheProviders() throws {
        let descriptions = try ProviderRegistry.builtInIDs.map {
            try ProviderRegistry.descriptor(id: $0, config: .default)
        }
        XCTAssertEqual(descriptions.map(\.id), ["openai", "groq", "azure", "deepgram", "elevenlabs", "xiaomi", "apple"])
        XCTAssertEqual(descriptions.map(\.requiresCredential), [true, true, true, true, true, true, false])
        XCTAssertEqual(descriptions[1].displayName, "Groq")
        XCTAssertEqual(descriptions[2].displayName, "Azure Speech")
        XCTAssertEqual(descriptions[6].displayName, "Apple Speech")
    }

    func testARefusedKeyIsNotReportedAsAMissingOne() {
        // Measured on this machine: after a re-signed build, the decrypting
        // query answered "not found" while `security find-generic-password`
        // showed the item. The difference is knowable, and "no key" is the
        // wrong thing to tell someone who has one.
        let refused = CredentialCache.resolve(
            providerID: "xiaomi",
            read: { _ in nil },
            hasKey: { _ in true }
        )
        guard case .failed = refused else {
            return XCTFail("a refused key was reported as \(refused)")
        }

        let absent = CredentialCache.resolve(
            providerID: "xiaomi",
            read: { _ in nil },
            hasKey: { _ in false }
        )
        XCTAssertEqual(absent, .missing)

        let present = CredentialCache.resolve(
            providerID: "xiaomi",
            read: { _ in "k" },
            hasKey: { _ in true }
        )
        XCTAssertEqual(present, .key("k"))

        let broken = CredentialCache.resolve(
            providerID: "xiaomi",
            read: { _ in throw CredentialError.unexpectedStatus(-25293) },
            hasKey: { _ in true }
        )
        guard case .failed = broken else {
            return XCTFail("a throwing read was reported as \(broken)")
        }

        // And the failure is not remembered, so a locked Keychain is retried
        // instead of leaving the app keyless for the session.
        let answers = Answers([refused, .key("k")])
        let cache = CredentialCache(reader: { _ in answers.next() }, logsReads: false)
        XCTAssertNil(cache.key(for: "xiaomi"))
        XCTAssertFalse(cache.isResolved("xiaomi"))
        XCTAssertEqual(cache.key(for: "xiaomi"), "k")
    }

    /// A second caller answers from what is known instead of waiting.
    ///
    /// One decrypting read can sit behind a system prompt for ten seconds. The
    /// cache used to let every caller start its own read, so a settings window
    /// that asked for the key while the launch warm was still waiting took the
    /// main actor down with it: the theme change that felt like a hang.
    func testASecondCallerDoesNotWaitForTheFirstRead() {
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let cache = CredentialCache(reader: { _ in
            entered.signal()
            gate.wait()
            return .key("secret")
        }, logsReads: false)

        DispatchQueue.global().async { _ = cache.key(for: "xiaomi") }
        XCTAssertEqual(
            entered.wait(timeout: .now() + 5),
            .success,
            "the first read never started"
        )

        // The second call runs off this thread, so the old behaviour fails the
        // test instead of hanging it: waiting is exactly the bug.
        let answered = expectation(description: "the second caller answered")
        var second: String?
        DispatchQueue.global().async {
            second = cache.key(for: "xiaomi")
            answered.fulfill()
        }
        wait(for: [answered], timeout: 1.0)
        XCTAssertNil(second, "the key is not known yet")

        gate.signal()

        // Once the read finishes, the answer is there for everyone.
        var key: String?
        for _ in 0..<100 where key == nil {
            usleep(20_000)
            key = cache.key(for: "xiaomi")
        }
        XCTAssertEqual(key, "secret")
    }

    /// A read that fails does not leave the provider marked as in flight.
    func testAFailedReadCanBeRetried() {
        // The first read blocks until the test lets it go; the second answers
        // straight away, so a stuck gate cannot hang the run.
        let gate = Gate()
        let answers = Answers([.failed("locked"), .key("secret")])
        let cache = CredentialCache(reader: { _ in
            gate.waitIfFirst()
            return answers.next()
        }, logsReads: false)

        DispatchQueue.global().async { _ = cache.key(for: "xiaomi") }
        XCTAssertTrue(gate.waitUntilEntered(), "the first read never started")
        gate.release()

        // The retry must be able to start a read of its own.
        var key: String?
        for _ in 0..<100 where key == nil {
            usleep(20_000)
            key = cache.key(for: "xiaomi")
        }
        XCTAssertEqual(key, "secret", "a failed read left the provider in flight")
    }
}
