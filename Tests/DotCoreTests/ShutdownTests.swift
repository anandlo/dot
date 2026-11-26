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

    /// Yields until the condition holds, or records a failure after a bounded
    /// number of turns and says so. It never measures time, so it cannot fail
    /// because a machine is slow: the bound is generous enough that only work
    /// which never happens exhausts it.
    private func settle(
        _ condition: @escaping () -> Bool,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0 ..< 1_000_000 {
            if condition() { return true }
            await Task.yield()
        }
        XCTFail(message.isEmpty ? "the drain did not reach the expected state" : message, file: file, line: line)
        return false
    }

    /// The event of every line the logger wrote, in the order it wrote them.
    private func logEvents() throws -> [String] {
        log.flush()
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
    ///
    /// The archive is real and still committing when the answer is given. The
    /// commit waits on a gate the test opens only after the answer, so "still
    /// running" is something the test holds rather than an interval it hopes the
    /// machine honours, and the limit is measured on the manual clock rather
    /// than against a stopwatch.
    func testTheAnswerArrivesAtTheLimitWhenTheArchiveIsSlower() async throws {
        let folder = try folder()
        let day = folder.appendingPathComponent("2026-11-16.md")
        let when = atNoon()
        let calendar = utc()
        let gate = Box(DispatchSemaphore(value: 0))
        let committing = Box(false)
        let archive = TranscriptArchive(
            calendar: { calendar },
            beforeCommit: { _ in
                committing.value = true
                _ = gate.value.wait(timeout: .now() + .seconds(10))
            }
        )
        let write = Task.detached { () -> Void in
            try? await archive.recordTake("Words.", at: when, folder: folder)
        }
        let clock = ManualClock()
        let answered = Box(false)
        let writtenBeforeAnswer = Box(false)

        let drain = Task { () -> Void in
            await Shutdown.drain(limit: .milliseconds(100), clock: clock.clock, pending: { [write] }, reply: { _ in
                answered.value = true
                writtenBeforeAnswer.value = FileManager.default.fileExists(atPath: day.path)
            })
        }

        guard await settle(
            { committing.value && clock.sleepRequests.count == 1 },
            "the drain never reached its wait"
        ) else {
            gate.value.signal()
            return
        }
        guard clock.sleepRequests == [.milliseconds(100)] else {
            XCTFail(
                "the pass was handed \(clock.sleepRequests), not the 100 ms limit",
                file: #filePath,
                line: #line
            )
            gate.value.signal()
            return
        }
        XCTAssertFalse(answered.value, "the quit was answered before the limit ran out")

        clock.advance(by: .milliseconds(100))
        guard await settle({ answered.value }, "the quit was never answered") else {
            gate.value.signal()
            return
        }
        await drain.value

        XCTAssertTrue(answered.value, "the quit was never answered")
        XCTAssertFalse(writtenBeforeAnswer.value, "the archive was not slower than the limit")

        gate.value.signal()
        await write.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: day.path), "the write did not finish once it was let go")
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
    ///
    /// The arithmetic is asserted on a clock the test moves, so a slow runner
    /// cannot fail it. The first pass is handed the whole limit; its write
    /// finishes 100 ms into that limit; the second pass is handed the 50 ms that
    /// are left. The caps are not additive - the first pass is handed 150 ms and
    /// spends 100 of them - so the assertion is that the second cap plus what the
    /// first pass spent is the limit, which is what stops the passes together
    /// from spending more than one limit. The answer comes when the clock reaches
    /// the deadline, and one millisecond earlier it does not.
    func testTheLoopSharesOneLimitAcrossPasses() async throws {
        let clock = ManualClock()
        let calls = Box(0)
        let replied = Box(false)
        let running = Box<[Task<Void, Never>]>([])
        let finishes = Box<[CheckedContinuation<Void, Never>]>([])
        let spentByTheFirstPass = Duration.milliseconds(100)

        let drain = Task { () -> Void in
            await Shutdown.drain(limit: .milliseconds(150), clock: clock.clock, pending: {
                let count = calls.value
                calls.value = count + 1
                switch count {
                case 0, 1:
                    // A write that finishes when the test says so, so which pass
                    // is waiting is decided here rather than by the scheduler.
                    let task = Task { () -> Void in
                        await withCheckedContinuation { continuation in
                            finishes.value.append(continuation)
                        }
                    }
                    running.value = [task]
                    return [task]
                default:
                    // The second write is still running when the limit arrives.
                    return running.value
                }
            }, reply: { _ in
                replied.value = true
            })
        }

        // The first pass is handed the whole limit, and its write is running.
        guard await settle(
            { clock.sleepRequests.count == 1 && finishes.value.count == 1 },
            "the drain never reached its first wait"
        ) else {
            return
        }
        XCTAssertEqual(clock.sleepRequests, [.milliseconds(150)], "the first pass was not handed the whole limit")

        // The first write finishes 100 ms into the limit.
        clock.advance(by: spentByTheFirstPass)
        finishes.value[0].resume()

        // The second pass is handed what the first one left.
        guard await settle({ clock.sleepRequests.count == 2 }, "the drain never reached its second wait") else {
            return
        }
        guard clock.sleepRequests == [.milliseconds(150), .milliseconds(50)] else {
            // A drain that hands each pass the whole limit stops here rather
            // than leaving this test suspended on a wait that will never end.
            XCTFail(
                "the passes were handed \(clock.sleepRequests), not the whole limit then what it left",
                file: #filePath,
                line: #line
            )
            return
        }
        XCTAssertEqual(
            spentByTheFirstPass + clock.sleepRequests[1],
            .milliseconds(150),
            "the two passes together could spend more than one limit"
        )
        XCTAssertFalse(replied.value, "the quit was answered while a pass was still waiting")

        // One millisecond short of the deadline the quit is still waiting.
        clock.advance(by: .milliseconds(49))
        XCTAssertFalse(replied.value, "the quit was answered before the deadline")

        // Reaching the deadline answers it.
        clock.advance(by: .milliseconds(1))
        guard await settle({ replied.value }, "the quit was never answered") else {
            return
        }
        await drain.value
        XCTAssertTrue(replied.value, "the quit was never answered")
        XCTAssertEqual(clock.now, .milliseconds(150), "the deadline was not where the limit put it")
        XCTAssertEqual(calls.value, 3, "the drain asked for writes after the deadline")

        // Release the second write, so nothing is left suspended by this test.
        guard await settle({ finishes.value.count == 2 }, "the second write never started") else {
            return
        }
        finishes.value[1].resume()
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

/// A clock a test moves by hand, so the wait's arithmetic is asserted exactly.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration = .zero
    private var sleepers: [(deadline: Duration, continuation: CheckedContinuation<Void, Never>)] = []
    private var requests: [Duration] = []

    var clock: ShutdownClock {
        ShutdownClock(
            now: { self.now },
            sleep: { duration in await self.sleep(for: duration) }
        )
    }

    var now: Duration {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Every duration a sleeper has asked for, in the order it asked.
    var sleepRequests: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Moves the clock on and wakes the sleepers whose deadline has arrived.
    func advance(by duration: Duration) {
        lock.lock()
        current += duration
        let due = sleepers.filter { $0.deadline <= current }
        sleepers.removeAll { $0.deadline <= current }
        lock.unlock()
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    func sleep(for duration: Duration) async {
        let began = beginSleep(duration)
        guard began.waits else { return }
        await withCheckedContinuation { continuation in
            guard register(continuation, until: began.deadline) else {
                continuation.resume()
                return
            }
        }
    }

    private func beginSleep(_ duration: Duration) -> (deadline: Duration, waits: Bool) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(duration)
        let deadline = current + duration
        return (deadline, current < deadline)
    }

    private func register(
        _ continuation: CheckedContinuation<Void, Never>,
        until deadline: Duration
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard current < deadline else { return false }
        sleepers.append((deadline, continuation))
        return true
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
