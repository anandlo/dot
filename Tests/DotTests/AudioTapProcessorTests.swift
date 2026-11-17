import AVFoundation
import XCTest

import DotCore
@testable import Dot

/// Two processors over one take, the way a microphone change rebuilds the tap.
///
/// Every buffer is made in memory. No microphone is opened, no audio engine is
/// started, no window is shown and nothing is played.
final class AudioTapProcessorTests: XCTestCase {
    private func format(_ sampleRate: Double) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        )
    }

    private func buffer(
        frames: Int,
        format: AVAudioFormat,
        amplitude: Float = 0.4
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        )
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<frames {
            let phase = 2 * Double.pi * 440 * Double(frame) / format.sampleRate
            channel[frame] = amplitude * Float(sin(phase))
        }
        return buffer
    }

    private func processor(
        at sampleRate: Double,
        store: AudioSampleStore,
        generation: Int? = nil
    ) throws -> AudioTapProcessor {
        AudioTapProcessor(
            resampler: try Resampler(inputFormat: try format(sampleRate)),
            store: store,
            generation: generation ?? store.currentGeneration
        )
    }

    /// Feeds `count` buffers of one second each at the given rate.
    private func feed(_ processor: AudioTapProcessor, seconds count: Int, at sampleRate: Double) throws {
        let input = try format(sampleRate)
        for _ in 0..<count {
            processor.handle(try buffer(frames: Int(sampleRate), format: input))
        }
    }

    func testTheSecondProcessorAppendsAfterTheFirst() throws {
        let store = AudioSampleStore()
        let first = try processor(at: 48_000, store: store)
        try feed(first, seconds: 1, at: 48_000)

        let beforeRebuild = store.count
        XCTAssertGreaterThan(beforeRebuild, 0, "the first processor collected nothing")
        let audioBeforeRebuild = store.all()

        // The device came back at another rate: a new converter, the same take.
        let second = try processor(
            at: 44_100,
            store: store,
            generation: store.beginGeneration()
        )
        try feed(second, seconds: 1, at: 44_100)

        XCTAssertGreaterThan(store.count, beforeRebuild, "the rebuilt processor did not append")
        XCTAssertEqual(
            store.samples(in: 0..<beforeRebuild),
            audioBeforeRebuild,
            "the audio collected before the rebuild moved or was lost"
        )
    }

    func testEveryRebuildAdvancesTheOffsetsInsteadOfRestartingThem() throws {
        let store = AudioSampleStore()
        var counts: [Int] = []
        var prefixes: [[Int16]] = []

        for (index, rate) in [48_000.0, 44_100.0, 48_000.0].enumerated() {
            let tap = try processor(
                at: rate,
                store: store,
                generation: store.beginGeneration()
            )
            try feed(tap, seconds: 1, at: rate)
            counts.append(store.count)
            prefixes.append(store.all())

            XCTAssertGreaterThan(
                counts[index],
                index == 0 ? 0 : counts[index - 1],
                "rebuild \(index) did not add audio"
            )
            for earlier in 0..<index {
                XCTAssertEqual(
                    store.samples(in: 0..<counts[earlier]),
                    prefixes[earlier],
                    "the audio collected before rebuild \(earlier) changed by rebuild \(index)"
                )
            }
        }

        // A live request that committed the first second still asks for the
        // same samples on the last processor.
        XCTAssertEqual(store.samples(in: 0..<counts[0]), prefixes[0])
        XCTAssertEqual(store.count, counts[2])
    }

    func testTheRebuildSequenceKeepsTheFlushedTailAheadOfTheNewProcessor() throws {
        let store = AudioSampleStore()
        let first = try processor(at: 48_000, store: store)
        try feed(first, seconds: 1, at: 48_000)

        // What Recorder.rebuild does: stop the old stream, then move the store
        // to a new generation, then feed from the new converter.
        XCTAssertTrue(first.finish())
        let beforeNewProcessor = store.all()

        let second = try processor(
            at: 44_100,
            store: store,
            generation: store.beginGeneration()
        )
        try feed(second, seconds: 1, at: 44_100)

        XCTAssertEqual(
            store.samples(in: 0..<beforeNewProcessor.count),
            beforeNewProcessor,
            "the flushed tail or the audio before it moved"
        )
        XCTAssertGreaterThan(store.count, beforeNewProcessor.count)
    }

    func testAStaleProcessorCannotAppendAfterTheTakeMovesToANewGeneration() throws {
        let store = AudioSampleStore()
        let stale = try processor(at: 48_000, store: store)
        try feed(stale, seconds: 1, at: 48_000)

        let beforeSwap = store.all()
        let live = try processor(
            at: 44_100,
            store: store,
            generation: store.beginGeneration()
        )
        try feed(live, seconds: 1, at: 44_100)
        let afterLive = store.all()

        // A tap callback of the old processor lands after the swap. It must not
        // append to the new processor's audio.
        stale.handle(try buffer(frames: 4_800, format: try format(48_000)))

        XCTAssertEqual(store.all(), afterLive, "a stale callback appended audio")
        XCTAssertEqual(store.samples(in: 0..<beforeSwap.count), beforeSwap)
    }

    func testAStaleProcessorCannotFlushIntoTheNewGeneration() throws {
        let store = AudioSampleStore()
        let stale = try processor(at: 48_000, store: store)
        try feed(stale, seconds: 1, at: 48_000)

        let live = try processor(
            at: 44_100,
            store: store,
            generation: store.beginGeneration()
        )
        try feed(live, seconds: 1, at: 44_100)
        let afterLive = store.all()

        XCTAssertFalse(stale.finish(), "the fenced processor's tail was accepted")
        XCTAssertEqual(store.all(), afterLive)
    }

    func testFinishAppendsTheConvertersTailBeforeTheGenerationChanges() throws {
        let store = AudioSampleStore()
        let tap = try processor(at: 48_000, store: store)
        try feed(tap, seconds: 1, at: 48_000)

        let beforeFinish = store.count
        let accepted = store.all()

        XCTAssertTrue(tap.finish(), "the converter was not holding any samples")
        XCTAssertGreaterThan(store.count, beforeFinish)
        XCTAssertEqual(
            store.samples(in: 0..<beforeFinish),
            accepted,
            "flushing moved the samples that were already accepted"
        )

        let afterFinish = store.count
        XCTAssertFalse(tap.finish(), "a stream can only be flushed once")
        XCTAssertEqual(store.count, afterFinish)

        // A callback that outlived the flush cannot append either.
        tap.handle(try buffer(frames: 4_800, format: try format(48_000)))
        XCTAssertEqual(store.count, afterFinish)
    }

    func testTheStopDrainIncludesTheFlushedTailAndIgnoresALateCallback() throws {
        let store = AudioSampleStore()
        let tap = try processor(at: 48_000, store: store)
        try feed(tap, seconds: 1, at: 48_000)

        let beforeStop = store.count
        let accepted = store.all()

        // This is what Recorder.endCapture does after it removed the tap and
        // stopped the engine: finish the stream, then take the snapshot.
        XCTAssertTrue(tap.finish())
        let drained = store.all()
        XCTAssertGreaterThan(drained.count, beforeStop, "the converter tail was dropped")
        XCTAssertEqual(Array(drained.prefix(beforeStop)), accepted)

        // A callback that was still in flight arrives after the drain. The
        // stream is closed, so the take cannot grow behind the snapshot.
        tap.handle(try buffer(frames: 4_800, format: try format(48_000)))
        XCTAssertEqual(store.all(), drained)
    }

    func testAProcessorThatNeverHeardABufferFlushesNothing() throws {
        let store = AudioSampleStore()
        let tap = try processor(at: 44_100, store: store)

        XCTAssertFalse(tap.finish())
        XCTAssertEqual(store.count, 0)
    }

    func testAFreshProcessorStartsItsMeterAtZeroWhileTheTakeKeepsItsAudio() throws {
        let store = AudioSampleStore()
        let first = try processor(at: 48_000, store: store)
        try feed(first, seconds: 1, at: 48_000)

        XCTAssertGreaterThan(first.level, 0)
        XCTAssertNotEqual(first.spectrum, .zero)

        let second = try processor(at: 48_000, store: store)
        XCTAssertEqual(second.level, 0, "a new processor has not measured a buffer yet")
        XCTAssertEqual(second.spectrum, .zero)
        XCTAssertGreaterThan(store.count, 0, "the take kept the audio of the previous processor")
    }

    func testAConversionFailureKeepsTheSamplesAlreadyCollected() throws {
        let store = AudioSampleStore()
        let tap = try processor(at: 44_100, store: store)
        try feed(tap, seconds: 1, at: 44_100)

        let collected = store.count
        XCTAssertGreaterThan(collected, 0)

        // A buffer at a rate the converter was not built for: the processor
        // reports the failure and the take keeps what it already has.
        tap.handle(try buffer(frames: 4_800, format: try format(48_000)))

        XCTAssertNotNil(tap.error)
        XCTAssertEqual(store.count, collected, "a failed conversion appended audio")
        XCTAssertEqual(store.all().count, collected)

        // The processor is a stream: a buffer with the right rate still works
        // after the bad one, and the take keeps growing at its offsets.
        try feed(tap, seconds: 1, at: 44_100)
        XCTAssertGreaterThan(store.count, collected)
        XCTAssertNotNil(tap.error)
    }

    func testTwoTakesDoNotShareAudio() throws {
        let firstStore = AudioSampleStore()
        let secondStore = AudioSampleStore()
        let first = try processor(at: 48_000, store: firstStore)

        try feed(first, seconds: 1, at: 48_000)

        XCTAssertGreaterThan(firstStore.count, 0)
        XCTAssertEqual(secondStore.count, 0)
    }

    func testTheProcessorKeepsTheFormatTheRebuildCompares() throws {
        let store = AudioSampleStore()
        let tap = try processor(at: 44_100, store: store)

        XCTAssertEqual(tap.inputFormat.sampleRate, 44_100)
        XCTAssertEqual(tap.inputFormat.channelCount, 1)
    }
}
