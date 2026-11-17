import XCTest

@testable import Dot

/// The sample store a take keeps across converter rebuilds.
///
/// A microphone that changes format replaces the tap processor, not the take.
/// The offsets the live loop and the transcript ledger already used have to
/// keep naming the same audio afterwards, and a callback from the processor
/// that was replaced must not land in the new processor's audio. Nothing here
/// touches a microphone, an audio engine or a window.
final class AudioSampleStoreTests: XCTestCase {
    private func append(_ samples: [Int16], to store: AudioSampleStore) {
        store.append(samples, from: store.currentGeneration)
    }

    func testSamplesArriveInTheOrderTheyWereAppended() {
        let store = AudioSampleStore()
        append([1, 2, 3], to: store)
        append([4, 5], to: store)

        XCTAssertEqual(store.count, 5)
        XCTAssertEqual(store.all(), [1, 2, 3, 4, 5])
    }

    func testAnEmptyChunkLeavesTheTakeAlone() {
        let store = AudioSampleStore()

        XCTAssertFalse(store.append([], from: store.currentGeneration))
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.all(), [])
    }

    func testACommittedRangeStillNamesTheSameAudioAfterTheConverterIsRebuilt() {
        // The bug: the rebuilt processor used to start a second array at zero,
        // so a stop asked for `committed..<sampleCount` on audio that no longer
        // held the committed samples. The store keeps the prefix in place.
        let store = AudioSampleStore()
        append([1, 2, 3], to: store)
        let committed = store.count

        // The next processor appends instead of replacing.
        let generation = store.beginGeneration()
        XCTAssertTrue(store.append([4, 5], from: generation))

        XCTAssertEqual(store.samples(in: 0..<committed), [1, 2, 3])
        XCTAssertEqual(store.samples(in: committed..<store.count), [4, 5])
        XCTAssertEqual(store.samples(in: 0..<store.count), [1, 2, 3, 4, 5])
    }

    func testRangesAreClampedToTheSamplesThatHaveArrived() {
        let store = AudioSampleStore()
        append([10, 20, 30], to: store)

        XCTAssertEqual(store.samples(in: 1..<3), [20, 30])
        XCTAssertEqual(store.samples(in: 1..<99), [20, 30], "a range that runs past the audio is truncated")
        XCTAssertEqual(store.samples(in: 99..<120), [])
        XCTAssertEqual(store.samples(in: -5..<2), [10, 20])
        XCTAssertEqual(store.samples(in: 3..<3), [])
    }

    func testRangesAreACopyNotAViewOfTheTake() {
        let store = AudioSampleStore()
        append([1, 2, 3], to: store)
        var slice = store.samples(in: 0..<2)
        slice.append(99)

        XCTAssertEqual(store.all(), [1, 2, 3])
    }

    func testTheGenerationAdvancesByOneForEveryRebuild() {
        let store = AudioSampleStore()
        let first = store.currentGeneration

        XCTAssertEqual(store.beginGeneration(), first + 1)
        XCTAssertEqual(store.currentGeneration, first + 1)
        XCTAssertEqual(store.beginGeneration(), first + 2)
        XCTAssertEqual(store.currentGeneration, first + 2)
    }

    func testAppendsFromAFencedGenerationAreDroppedAndTheAcceptedOrderIsKept() {
        let store = AudioSampleStore()
        append([1, 2, 3], to: store)
        let staleGeneration = store.currentGeneration
        let accepted = store.all()

        let liveGeneration = store.beginGeneration()

        // A late callback of the processor that fed the take up to the rebuild.
        XCTAssertFalse(store.append([99, 98], from: staleGeneration))
        XCTAssertEqual(store.all(), accepted)

        // The processor that replaced it appends normally, after the prefix.
        XCTAssertTrue(store.append([4, 5], from: liveGeneration))
        XCTAssertEqual(store.all(), [1, 2, 3, 4, 5])
        XCTAssertEqual(store.samples(in: 0..<accepted.count), accepted)
    }

    func testAnAppendFromAGenerationThatNeverExistedIsDropped() {
        let store = AudioSampleStore()
        append([1], to: store)

        XCTAssertFalse(store.append([2], from: store.currentGeneration + 1))
        XCTAssertEqual(store.all(), [1])
    }

    func testEveryChunkFromEveryThreadArrives() {
        // The audio thread appends while the live loop reads. Appends from
        // concurrent queues must not lose a chunk or corrupt the count.
        let store = AudioSampleStore()
        let generation = store.currentGeneration
        let chunks = 64
        let size = 128

        DispatchQueue.concurrentPerform(iterations: chunks) { index in
            store.append([Int16](repeating: Int16(index % 7), count: size), from: generation)
        }

        XCTAssertEqual(store.count, chunks * size)
        XCTAssertEqual(store.all().count, chunks * size)
    }
}
