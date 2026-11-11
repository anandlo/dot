import XCTest

@testable import DotCore

/// A provider that answers with whatever it is told to.
private final class ScriptedProvider: Provider, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Scripted"
    let maxSegmentSeconds: Int
    let answers: [Result<String, Error>]
    private(set) var requests: [Data] = []

    init(maxSegmentSeconds: Int = 30, answers: [Result<String, Error>]) {
        self.maxSegmentSeconds = maxSegmentSeconds
        self.answers = answers
    }

    func isAvailable() async -> Bool { true }

    func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
        requests.append(wav)
        let index = min(requests.count - 1, answers.count - 1)
        return try answers[index].get()
    }
}

private struct ScriptedError: Error, Equatable {
    let message: String
}

final class SegmentsTests: XCTestCase {
    private func samples(seconds: Double) -> [Int16] {
        [Int16](repeating: 1_000, count: Int(seconds * Double(WAVSpec.sampleRate)))
    }

    func testTheSegmentsAreThirtySecondsLongByDefault() {
        XCTAssertEqual(Segmenter.defaultSegmentSeconds, 30)
        XCTAssertEqual(Segmenter.sampleCount(seconds: 30), 480_000)
    }

    func testNinetyFiveSecondsBecomeFourSegments() {
        let pieces = Segmenter.segments(samples: samples(seconds: 95), seconds: 30)
        XCTAssertEqual(pieces.count, 4)
        XCTAssertEqual(pieces[0].count, 480_000)
        XCTAssertEqual(pieces[3].count, 95 * 16_000 - 3 * 480_000)
    }

    func testSeventySecondsBecomeThreeSegments() {
        let pieces = Segmenter.segments(samples: samples(seconds: 70), seconds: 30)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces[2].count, 70 * 16_000 - 2 * 480_000)
    }

    func testTheSegmentCountMatchesTheSegments() {
        // The count is what the card shows before the first request, so it has
        // to agree with what the transcriber actually sends.
        for seconds in [0.0, 0.5, 12.0, 12.1, 30.0, 30.1, 63.0, 163.9] {
            let input = samples(seconds: seconds)
            XCTAssertEqual(
                Segmenter.segmentCount(samples: input.count, seconds: 30),
                Segmenter.segments(samples: input, seconds: 30).count,
                "\(seconds) s"
            )
        }
        XCTAssertEqual(Segmenter.segmentCount(samples: 0, seconds: 30), 0)
        XCTAssertEqual(Segmenter.segmentCount(samples: 1, seconds: 30), 1)
    }

    func testTheSegmentsKeepEverySample() {
        let input = samples(seconds: 61)
        let pieces = Segmenter.segments(samples: input, seconds: 30)
        XCTAssertEqual(pieces.flatMap { $0 }.count, input.count)
    }

    func testASilentBufferIsStillSent() async throws {
        // There is no gate: a recording of silence reaches the provider.
        let provider = ScriptedProvider(answers: [.success("")])
        let silence = WAVWriter.encode(samples: [Int16](repeating: 0, count: 16_000))
        let report = try await Transcriber.transcribe(
            wav: silence,
            provider: provider,
            maxSegmentSeconds: 30
        )
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(report.total, 1)
        XCTAssertEqual(report.succeeded, 1)
    }

    func testAZeroSampleRecordingSendsNothing() async throws {
        let provider = ScriptedProvider(answers: [.success("never")])
        let report = try await Transcriber.transcribe(
            wav: WAVWriter.encode(samples: []),
            provider: provider,
            maxSegmentSeconds: 30
        )
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.total, 0)
    }

    func testALongRecordingIsSplitAndSentInOrder() async throws {
        let provider = ScriptedProvider(answers: [
            .success("first"), .success("second"), .success("third"),
        ])
        let report = try await Transcriber.transcribe(
            wav: WAVWriter.encode(samples: samples(seconds: 70)),
            provider: provider,
            maxSegmentSeconds: 30
        )
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertEqual(report.total, 3)
        XCTAssertEqual(report.succeeded, 3)
        XCTAssertEqual(report.text, "first second third")
        // Every request is a WAV of its own, at most thirty seconds long.
        for request in provider.requests {
            let info = try WAVWriter.parse(request)
            XCTAssertTrue(info.isCanonical)
            XCTAssertLessThanOrEqual(info.durationMilliseconds, 30_000)
        }
    }

    func testAFailingSegmentDoesNotDiscardTheOthers() async throws {
        let provider = ScriptedProvider(answers: [
            .success("one"),
            .failure(ScriptedError(message: "boom")),
            .success("three"),
            .success("four"),
        ])
        let report = try await Transcriber.transcribe(
            wav: WAVWriter.encode(samples: samples(seconds: 95)),
            provider: provider,
            maxSegmentSeconds: 30
        )
        XCTAssertEqual(report.total, 4)
        XCTAssertEqual(report.succeeded, 3)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.text, "one three four")
    }

    func testWhenEverySegmentFailsTheErrorIsThrown() async throws {
        let provider = ScriptedProvider(answers: [
            .failure(ScriptedError(message: "boom")),
        ])
        do {
            _ = try await Transcriber.transcribe(
                wav: WAVWriter.encode(samples: samples(seconds: 70)),
                provider: provider,
                maxSegmentSeconds: 30
            )
            XCTFail("the transcription should have failed")
        } catch let error as ScriptedError {
            XCTAssertEqual(error, ScriptedError(message: "boom"))
        }
    }

    func testTheSegmentSizeIsTheProvidersCapability() {
        // The size is a capability of the provider, not a hardcoded number.
        let provider = ScriptedProvider(maxSegmentSeconds: 12, answers: [.success("ok")])
        XCTAssertEqual(provider.maxSegmentSeconds, 12)
        let pieces = Segmenter.segments(samples: samples(seconds: 30), seconds: provider.maxSegmentSeconds)
        XCTAssertEqual(pieces.count, 3)
    }
}
