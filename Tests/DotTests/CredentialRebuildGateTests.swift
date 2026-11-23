import XCTest

@testable import DotCore

/// The press callback and a Stop can arrive in either order. Only one of them
/// may rebuild for one resolved key, and neither may rebuild an obsolete pick.
@MainActor
final class CredentialRebuildGateTests: XCTestCase {
    func testCallbackThenStopRebuildsOnce() {
        let gate = CredentialRebuildGate()
        var rebuilds = 0
        let rebuild = { rebuilds += 1 }
        let first = gate.perform(
            providerID: "openai",
            selectedProviderID: "openai",
            signatureMatches: true,
            ready: true,
            generation: 3,
            rebuild: rebuild
        )
        let second = gate.perform(
            providerID: "openai",
            selectedProviderID: "openai",
            signatureMatches: true,
            ready: true,
            generation: 3,
            rebuild: rebuild
        )
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(rebuilds, 1)
    }

    func testStopThenCallbackRebuildsOnce() {
        let gate = CredentialRebuildGate()
        var rebuilds = 0
        let rebuild = { rebuilds += 1 }
        let stop = gate.perform(
            providerID: "openai",
            selectedProviderID: "openai",
            signatureMatches: true,
            ready: true,
            generation: 7,
            rebuild: rebuild
        )
        let callback = gate.perform(
            providerID: "openai",
            selectedProviderID: "openai",
            signatureMatches: true,
            ready: true,
            generation: 7,
            rebuild: rebuild
        )
        XCTAssertTrue(stop)
        XCTAssertFalse(callback)
        XCTAssertEqual(rebuilds, 1)
    }

    func testANewGenerationMayRebuildAgain() {
        let gate = CredentialRebuildGate()
        var rebuilds = 0
        let rebuild = { rebuilds += 1 }
        XCTAssertTrue(gate.perform(
            providerID: "openai",
            selectedProviderID: "openai",
            signatureMatches: true,
            ready: true,
            generation: 1,
            rebuild: rebuild
        ))
        XCTAssertTrue(gate.perform(
            providerID: "openai",
            selectedProviderID: "openai",
            signatureMatches: true,
            ready: true,
            generation: 2,
            rebuild: rebuild
        ))
        XCTAssertEqual(rebuilds, 2)
    }

    func testObsoleteProviderAndUnreadyCacheDoNotRebuild() {
        let gate = CredentialRebuildGate()
        var rebuilds = 0
        let rebuild = { rebuilds += 1 }
        XCTAssertFalse(gate.perform(
            providerID: "openai",
            selectedProviderID: "groq",
            signatureMatches: true,
            ready: true,
            generation: 1,
            rebuild: rebuild
        ))
        XCTAssertFalse(gate.perform(
            providerID: "openai",
            selectedProviderID: "openai",
            signatureMatches: false,
            ready: true,
            generation: 1,
            rebuild: rebuild
        ))
        XCTAssertFalse(gate.perform(
            providerID: "openai",
            selectedProviderID: "openai",
            signatureMatches: true,
            ready: false,
            generation: 1,
            rebuild: rebuild
        ))
        XCTAssertEqual(rebuilds, 0)
    }

    /// A store advances the answer's generation just as an invalidation does.
    /// Two stores followed by an invalidate must not reuse an older number.
    func testStoreStoreInvalidateGenerationsAreStrictlyIncreasing() {
        let cache = CredentialCache(reader: { _ in .missing }, logsReads: false)
        let initial = cache.generation(for: "openai")
        cache.store("one", for: "openai")
        let first = cache.generation(for: "openai")
        cache.store("two", for: "openai")
        let second = cache.generation(for: "openai")
        cache.invalidate("openai")
        let third = cache.generation(for: "openai")
        cache.store("three", for: "openai")
        let fourth = cache.generation(for: "openai")
        cache.invalidateAll()
        let fifth = cache.generation(for: "openai")

        XCTAssertGreaterThan(first, initial)
        XCTAssertGreaterThan(second, first)
        XCTAssertGreaterThan(third, second, "an invalidation reused an older generation")
        XCTAssertGreaterThan(fourth, third)
        XCTAssertGreaterThan(fifth, fourth, "a global invalidation reused an older generation")
    }

    /// The gate keys its decision on the generation. A repeated number after
    /// store, store, invalidate silently drops a valid rebuild.
    func testAValidRebuildAfterStoreStoreInvalidateIsNotSkipped() {
        let cache = CredentialCache(reader: { _ in .missing }, logsReads: false)
        let gate = CredentialRebuildGate()
        var rebuilds = 0
        let rebuild = { rebuilds += 1 }
        cache.store("one", for: "openai")
        let first = cache.generation(for: "openai")
        cache.store("two", for: "openai")
        let second = cache.generation(for: "openai")
        cache.invalidate("openai")
        let third = cache.generation(for: "openai")

        // The middle store need not produce a press. The next press after the
        // invalidation is still a new answer and must not be suppressed by the
        // generation the first press already handled.
        XCTAssertGreaterThan(second, first)
        for generation in [first, third] {
            XCTAssertTrue(gate.perform(
                providerID: "openai",
                selectedProviderID: "openai",
                signatureMatches: true,
                ready: true,
                generation: generation,
                rebuild: rebuild
            ), "generation \(generation) was skipped")
        }
        XCTAssertEqual(rebuilds, 2)
    }
}
