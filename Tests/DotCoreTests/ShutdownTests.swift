import Foundation
import XCTest

@testable import DotCore

/// What a quit waits for before it answers.
///
/// A day file is replaced whole, so a write cut off by the process ending is a
/// write that did not happen. These tests are about the wait rather than the
/// words: the answer to the termination request arrives after the archive has
/// finished, so the archive's log line is on disk before the app logs that it
/// stopped, and a folder that never answers cannot hold a quit open.
final class ShutdownTests: XCTestCase {
    private var directory: URL!
    private var log: Log!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-shutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = Log()
        log.openFile(at: directory.appendingPathComponent("Dot.log"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A real archive that takes its time, standing in for a folder on a disk
    /// that has gone to sleep.
    private func slowArchive(folder: URL, for seconds: TimeInterval) -> TranscriptArchive {
        let calendar = utc()
        return TranscriptArchive(
            calendar: { calendar },
            beforeCommit: { _ in Thread.sleep(forTimeInterval: seconds) }
        )
    }

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = TimeZone(secondsFromGMT: 0) {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    private func folder() throws -> URL {
        let folder = directory.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func atNoon() -> Date {
        let calendar = utc()
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 16
        components.hour = 14
        components.minute = 32
        components.second = 5
        return calendar.date(from: components) ?? Date()
    }

    /// The event of every line the logger wrote, in the order it wrote them.
    private func logEvents() throws -> [String] {
        let url = try XCTUnwrap(log.url)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line -> String? in
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                return (object as? [String: Any])?["event"] as? String
            }
    }

    /// The answer comes after the archive has finished, and the log keeps that
    /// order.
    func testTheAnswerWaitsForTheArchiveAndTheLogKeepsTheOrder() async throws {
        let folder = try folder()
        let archive = slowArchive(folder: folder, for: 0.15)
        let day = folder.appendingPathComponent("2026-11-16.md")
        let log = SendableBox(self.log!)
        let when = atNoon()

        let write = Task.detached {
            try? await archive.recordTake("Words.", at: when, folder: folder)
            log.value.info("archive.write")
        }
        let answered = Box(false)
        let writtenBeforeAnswer = Box(false)

        let queue = Box<[Task<Void, Never>]>([write])
        await Shutdown.drain(pending: { takeOnce(queue) }) { _ in
            answered.value = true
            writtenBeforeAnswer.value = FileManager.default.fileExists(atPath: day.path)
            log.value.info("app.stopped")
        }

        XCTAssertTrue(answered.value, "the quit was never answered")
        XCTAssertTrue(writtenBeforeAnswer.value, "the quit was answered before the archive finished")
        let events = try logEvents()
        XCTAssertEqual(events, ["archive.write", "app.stopped"])
    }

    /// A folder that never answers cannot hold the quit open.
    func testTheAnswerArrivesAtTheLimitWhenTheArchiveIsSlower() async throws {
        let folder = try folder()
        let archive = slowArchive(folder: folder, for: 0.6)
        let day = folder.appendingPathComponent("2026-11-16.md")
        let when = atNoon()

        let write = Task.detached { () -> Void in
            try? await archive.recordTake("Words.", at: when, folder: folder)
        }
        let answered = Box<Duration?>(nil)
        let writtenBeforeAnswer = Box(false)
        let started = ContinuousClock.now

        let queue = Box<[Task<Void, Never>]>([write])
        await Shutdown.drain(limit: .milliseconds(100), pending: { takeOnce(queue) }) { _ in
            answered.value = started.duration(to: .now)
            writtenBeforeAnswer.value = FileManager.default.fileExists(atPath: day.path)
        }

        let elapsed = try XCTUnwrap(answered.value)
        XCTAssertLessThan(elapsed, .milliseconds(500), "the quit waited for a folder that never answered")
        XCTAssertFalse(writtenBeforeAnswer.value, "the archive was not slower than the limit")
        await write.value
    }

    /// A write registered while the drain is running is waited for too.
    func testAWriteRegisteredDuringTheDrainIsWaitedFor() async throws {
        let first = Task { () -> Void in
            try? await Task.sleep(for: .milliseconds(20))
        }
        let late = Box<Task<Void, Never>?>(nil)
        let calls = Box(0)
        let order = Box<[String]>([])

        await Shutdown.drain(pending: {
            let count = calls.value
            calls.value = count + 1
            switch count {
            case 0:
                // A rewrite lands while the first write is still being waited
                // for, which is exactly what a quit has to allow.
                let task = Task { () -> Void in
                    try? await Task.sleep(for: .milliseconds(20))
                    order.value.append("late")
                }
                late.value = task
                return [first]
            case 1:
                return [late.value].compactMap { $0 }
            default:
                return []
            }
        }, reply: { _ in
            order.value.append("reply")
        })

        XCTAssertEqual(calls.value, 3, "the drain stopped asking while a write was registered")
        XCTAssertEqual(order.value, ["late", "reply"], "the reply came before the write registered during the drain")
    }

    /// The whole loop shares one limit instead of taking it per pass.
    func testTheLoopSharesOneLimitAcrossPasses() async throws {
        let calls = Box(0)
        let elapsed = Box<Duration?>(nil)
        let started = ContinuousClock.now

        await Shutdown.drain(limit: .milliseconds(150), pending: {
            let count = calls.value
            calls.value = count + 1
            guard count < 3 else { return [] }
            return [Task { () -> Void in
                try? await Task.sleep(for: .milliseconds(100))
            }]
        }, reply: { _ in
            elapsed.value = started.duration(to: .now)
        })

        XCTAssertEqual(calls.value, 3, "the drain kept asking after the limit ran out")
        let total = try XCTUnwrap(elapsed.value)
        XCTAssertLessThan(total, .milliseconds(280), "each pass took the whole limit instead of sharing it")
    }

    /// The look that finds nothing and the answer are one main-actor step.
    ///
    /// A rewrite finishing on the main actor at that moment must not be able to
    /// register a write between the two: the quit would then be told to proceed
    /// with that write running. The producer here is scheduled from inside the
    /// look that returns nothing, which is exactly the turn an `await` before the
    /// answer would give it.
    func testTheReplySharesOneStepWithTheLookThatFindsNothing() async throws {
        let queue = Box<[Task<Void, Never>]>([])
        let order = Box<[String]>([])
        let replied = Box(false)
        let producer = Box<Task<Void, Never>?>(nil)
        let first = Task { () -> Void in
            try? await Task.sleep(for: .milliseconds(10))
            order.value.append("first")
        }
        queue.value = [first]

        await Shutdown.drain(pending: {
            let tasks = takeOnce(queue)
            if tasks.isEmpty {
                producer.value = Task { @MainActor in
                    let late = Task { () -> Void in
                        try? await Task.sleep(for: .milliseconds(20))
                        order.value.append("late")
                    }
                    queue.value = [late]
                    order.value.append("producer")
                    await late.value
                }
            }
            return tasks
        }, reply: { _ in
            replied.value = true
            order.value.append("reply")
        })

        XCTAssertTrue(replied.value)
        await producer.value?.value
        XCTAssertEqual(
            order.value,
            ["first", "reply", "producer", "late"],
            "the answer gave the main actor a turn, so a write could be registered behind it"
        )
    }

    /// Nothing to wait for is answered at once.
    func testAQuitWithNothingToWaitForIsAnsweredAtOnce() async {
        let answered = Box(false)

        await Shutdown.drain(pending: { [] }) { _ in answered.value = true }

        XCTAssertTrue(answered.value)
    }
}

/// A registry handed over once, which is what the app's archive list is.
private func takeOnce(_ queue: Box<[Task<Void, Never>]>) -> [Task<Void, Never>] {
    let tasks = queue.value
    queue.value = []
    return tasks
}

/// A value a test closure can carry across isolation domains.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// A value that is only ever read, carried into a closure of another isolation
/// domain.
private final class SendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
