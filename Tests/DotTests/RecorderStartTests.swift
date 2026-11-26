import AVFoundation
import CoreAudio
import XCTest

import DotCore
@testable import Dot

/// What the press costs, and who owns the take it starts.
///
/// A take used to open the engine on the thread that answered the key:
/// `AVAudioEngine()`, the device format, a discovery session over the capture
/// devices, the tap, and `start()`, which opens the audio device. A Bluetooth
/// input made that the longest part of starting a take, and the main thread
/// waited for it. The recorder hands the work to a queue of its own now. The
/// engine here is a stub that takes as long as a slow device, so the measurements
/// can be made without a microphone, a permission prompt or a window.
final class RecorderStartTests: XCTestCase {
    /// An engine whose input takes its time, the way a waking device does.
    private final class StubEngine: CaptureEngine, @unchecked Sendable {
        private typealias TapBlock = (AVAudioPCMBuffer, AVAudioTime) -> Void

        private let lock = NSLock()
        private let startDelay: TimeInterval
        private let startError: RecorderError?
        private var format: AVAudioFormat
        private var deviceUID: String?
        private var tapBlock: TapBlock?
        private var retainedTaps: [(format: AVAudioFormat?, block: TapBlock)] = []
        private var deviceOnStart: String?
        private var deviceOnStartAfterStarts = 0
        private var feedOnStart = false
        private var feedFrequency = 440.0
        private var formatOnStart: AVAudioFormat?
        private var tapFormat: AVAudioFormat?
        private var starts = 0
        private var stops = 0
        private var installs = 0
        private var running = false
        private var startGate: (entered: DispatchSemaphore, release: DispatchSemaphore)?
        private var calls: [String] = []
        private var selectionFails = false
        private var followsSelection = true
        private var writes = 0
        private var readbackOverride: String?
        private var hasReadbackOverride = false
        private var startFails = false
        private var feedOnStartFailure = false
        private var deviceOnStartFailure: String?
        private let notificationIdentity = NSObject()

        init(startDelay: TimeInterval, startError: RecorderError? = nil) throws {
            self.startDelay = startDelay
            self.startError = startError
            self.format = try Self.makeFormat(48_000)
        }

        /// The object a real configuration notification names, injected so a
        /// test can distinguish the active engine from a stale or foreign one.
        var configurationIdentity: AnyObject? { notificationIdentity }

        private enum SelectionFailure: Error { case refused }
        private enum StartFailure: Error { case refused }

        static func makeFormat(_ rate: Double, channels: Int = 1) throws -> AVAudioFormat {
            try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: rate,
                    channels: AVAudioChannelCount(channels),
                    interleaved: false
                )
            )
        }

        /// The calls that matter to device selection, in the order they arrived.
        var callLog: [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func failSelection() {
            lock.lock()
            selectionFails = true
            lock.unlock()
        }

        /// Keeps the engine on one device regardless of a selection, so a test
        /// can make the open report a device other than the one requested.
        func holdDevice(_ uid: String?) {
            lock.lock()
            deviceUID = uid
            followsSelection = false
            lock.unlock()
        }

        func resumeSelection() {
            lock.lock()
            followsSelection = true
            lock.unlock()
        }

        var writeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return writes
        }

        /// How many times a device write was attempted while the unit ran.
        ///
        /// A selection belongs after the stop: writing a running unit is the
        /// ordering this fixture refuses, so a recorder that does it ends up
        /// with a failed route instead of a silent double write.
        private var selectsWhileRunning = 0

        var runningSelections: Int {
            lock.lock()
            defer { lock.unlock() }
            return selectsWhileRunning
        }

        func selectInputDevice(uid: String) throws {
            lock.lock()
            calls.append("select:\(uid)")
            guard !running else {
                selectsWhileRunning += 1
                calls.append("select-while-running:\(uid)")
                lock.unlock()
                throw SelectionFailure.refused
            }
            // A unit already on the requested device must not be written again.
            guard deviceUID != uid else { lock.unlock(); return }
            writes += 1
            let fails = selectionFails
            if !fails, followsSelection { deviceUID = uid }
            lock.unlock()
            if fails { throw SelectionFailure.refused }
        }

        var stopCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return stops
        }

        var startCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return starts
        }

        var installCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return installs
        }

        /// Makes the next start throw, the way a device that cannot open does.
        func failStartOnNext() {
            lock.lock()
            startFails = true
            lock.unlock()
        }

        var retainedTapCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return retainedTaps.count
        }

        /// Calls a callback installed by an earlier tap after it was removed.
        func invokeRetainedTap(_ index: Int, frequency: Double = 440) throws {
            let retained = try XCTUnwrap(retainedTaps.indices.contains(index) ? retainedTaps[index] : nil)
            guard let format = retained.format else { return }
            Self.pushBlock(retained.block, format: format, frequency: frequency)
        }

        var tapCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return tapFormat == nil ? 0 : 1
        }

        var lastTapFormat: AVAudioFormat? {
            lock.lock()
            defer { lock.unlock() }
            return tapFormat
        }

        /// The callback the recorder installed, so a test can feed the meter and
        /// the sample store without a microphone.
        var installedTap: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return tapBlock
        }

        /// Makes the input change format while it is being opened, the way a
        /// device that finishes connecting does.
        func changeFormatOnStart(_ rate: Double) throws {
            let next = try Self.makeFormat(rate)
            lock.lock()
            formatOnStart = next
            lock.unlock()
        }

        /// The device the opened engine reports it is running on.
        func setDevice(_ uid: String?) {
            lock.lock()
            deviceUID = uid
            lock.unlock()
        }

        func useUnknownReadback() {
            lock.lock()
            readbackOverride = nil
            hasReadbackOverride = true
            lock.unlock()
        }

        func currentDeviceUID() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return hasReadbackOverride ? readbackOverride : deviceUID
        }

        /// Switches the device the engine reports, inside the next start.
        ///
        /// - Parameter afterStarts: the number of successful starts that have
        ///   to have happened before the switch is applied. A later start is
        ///   how a fixture keeps a first start on one device and lands the
        ///   rebuild that follows on another.
        func switchDeviceOnStart(_ uid: String, afterStarts: Int = 0) {
            lock.lock()
            deviceOnStart = uid
            deviceOnStartAfterStarts = afterStarts
            lock.unlock()
        }

        /// Pushes one block of audio through the tap inside the next start.
        func feedAudioOnStart(frequency: Double = 440) {
            lock.lock()
            feedOnStart = true
            feedFrequency = frequency
            lock.unlock()
        }

        /// Emits a block through the tap inside the next start, then makes
        /// that start throw the way a device that gives up does.
        ///
        /// The readback is switched first, so the block looks like the audio
        /// of the device that refused to open.
        func feedAudioThenFailOnStart(frequency: Double = 440, device: String? = nil) {
            lock.lock()
            feedOnStartFailure = true
            feedFrequency = frequency
            deviceOnStartFailure = device
            lock.unlock()
        }

        /// Changes the format now, the way a route change does.
        func setFormat(_ rate: Double) throws {
            setFormat(try Self.makeFormat(rate))
        }

        func setFormat(_ next: AVAudioFormat) {
            lock.lock()
            format = next
            lock.unlock()
        }

        func inputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat {
            lock.lock()
            defer { lock.unlock() }
            calls.append("inputFormat")
            return format
        }

        func installTap(
            onBus bus: AVAudioNodeBus,
            bufferSize: AVAudioFrameCount,
            format: AVAudioFormat?,
            block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
        ) {
            lock.lock()
            installs += 1
            tapFormat = format
            tapBlock = block
            retainedTaps.append((format: format, block: block))
            lock.unlock()
        }

        func removeTap(onBus bus: AVAudioNodeBus) {
            lock.lock()
            tapFormat = nil
            tapBlock = nil
            lock.unlock()
        }

        func prepare() {}

        func start() throws {
            // A route change's restart is a start like any other, and it is the
            // one the audio queue is doing when a stop arrives. Holding it here
            // is holding the audio queue itself, not only its answer.
            lock.lock()
            let gate = startGate
            startGate = nil
            lock.unlock()
            gate?.entered.signal()
            _ = gate?.release.wait(timeout: .now() + 5)
            // The sleep runs on the audio control queue, which is the point: it
            // is the stand-in for a device that has to be opened.
            Thread.sleep(forTimeInterval: startDelay)
            if let startError { throw startError }
            lock.lock()
            if startFails {
                startFails = false
                lock.unlock()
                throw StartFailure.refused
            }
            if feedOnStartFailure {
                // A device that delivers a block and then refuses to open: the
                // buffer is in the tap before the start reports its failure.
                feedOnStartFailure = false
                let tap = tapBlock
                let feedFormat = tapFormat ?? format
                let frequency = feedFrequency
                let device = deviceOnStartFailure
                deviceOnStartFailure = nil
                lock.unlock()
                if let tap {
                    Self.pushBlock(tap, format: feedFormat, frequency: frequency)
                }
                if let device { setDevice(device) }
                throw StartFailure.refused
            }
            if let formatOnStart { format = formatOnStart }
            starts += 1
            running = true
            let tap = tapBlock
            let feedFormat = tapFormat ?? format
            let feed = feedOnStart
            let frequency = feedFrequency
            let device = deviceOnStart
            let deviceAfter = deviceOnStartAfterStarts
            let startsNow = starts
            let appliesDevice = device != nil && startsNow > deviceAfter
            if appliesDevice {
                deviceOnStart = nil
                deviceOnStartAfterStarts = 0
            }
            feedOnStart = false
            lock.unlock()
            // A device that is already delivering audio while the engine opens,
            // or that changes under it, emits in the installed tap's format.
            if feed, let tap {
                Self.pushBlock(tap, format: feedFormat, frequency: frequency)
            }
            if let device, appliesDevice {
                setDevice(device)
            }
        }

        /// Holds the next start on the audio queue, and reports when it got
        /// there.
        ///
        /// The returned release is waited for with a bound, so a test that
        /// fails before opening it cannot leave the queue asleep forever.
        func blockNextStart() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
            let gate = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
            lock.lock()
            startGate = gate
            lock.unlock()
            return gate
        }

        /// Pushes one block of audio through an installed tap.
        static func pushBlock(
            _ tap: (AVAudioPCMBuffer, AVAudioTime) -> Void,
            format: AVAudioFormat,
            frames: Int = 4_800,
            frequency: Double = 440
        ) {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ), let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            for frame in 0..<frames {
                channel[frame] = 0.3 * Float(sin(2 * Double.pi * frequency * Double(frame) / format.sampleRate))
            }
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
        }

        func stop() {
            lock.lock()
            calls.append("stop")
            stops += 1
            running = false
            lock.unlock()
        }

        func reset() {
            lock.lock()
            running = false
            lock.unlock()
        }

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }
    }

    /// Hands out one stub engine per open.
    private final class EngineQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var engines: [StubEngine]

        init(_ engines: [StubEngine]) {
            self.engines = engines
        }

        func next() -> CaptureEngine {
            lock.lock()
            defer { lock.unlock() }
            guard !engines.isEmpty else {
                preconditionFailure("the test opened more engines than it supplied")
            }
            return engines.removeFirst()
        }
    }

    /// Watches the main queue for gaps, the way the app's own heartbeat does.
    ///
    /// A timer that expects to run every ten milliseconds records the difference
    /// between the ticks: a block of work longer than the interval shows up as a
    /// gap that no measurement inside the blocked code could see.
    private final class MainQueueProbe: @unchecked Sendable {
        private var timer: Timer?
        private var last = CACurrentMediaTime()
        private var largest: TimeInterval = 0

        func start(interval: TimeInterval = 0.01) {
            last = CACurrentMediaTime()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.largest = max(self.largest, now - self.last)
                self.last = now
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        /// Stops sampling and returns the largest gap in milliseconds.
        func stop() -> Double {
            timer?.invalidate()
            timer = nil
            return largest * 1000
        }
    }

    /// Holds the moment between the audio queue answering and the app hearing it.
    ///
    /// It is the delivery seam: the ownership checks have to hold across a
    /// cancellation and a second start inside that gap, which is exactly where a
    /// reused session used to stop the wrong engine.
    private final class DeliveryGate: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [@MainActor @Sendable () -> Void] = []
        private var holding = true

        func deliver(_ work: @escaping @MainActor @Sendable () -> Void) {
            lock.lock()
            if holding {
                held.append(work)
                lock.unlock()
                return
            }
            lock.unlock()
            MainThreadTick.run(work)
        }

        var heldCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return held.count
        }

        @MainActor
        func waitForHeld(_ count: Int, timeout: TimeInterval = 5) async {
            let deadline = Date().addingTimeInterval(timeout)
            while heldCount < count, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(heldCount, count, "the answers did not reach the delivery gate")
        }

        @MainActor
        func hold() {
            lock.lock()
            holding = true
            lock.unlock()
        }

        @MainActor
        func release() {
            lock.lock()
            holding = false
            let work = held
            held = []
            lock.unlock()
            for item in work { item() }
        }

        /// Runs the held answer at `index` only, leaving the others held.
        ///
        /// It is how a test proves an answer is matched by the take that asked
        /// for it: the older answer can be let through after a newer take has
        /// started, which the queue's own order never does.
        @MainActor
        func releaseHeld(at index: Int) {
            lock.lock()
            guard held.indices.contains(index) else {
                lock.unlock()
                return
            }
            let work = held.remove(at: index)
            lock.unlock()
            work()
        }
    }

    /// Records the warning lines the recorder writes, so a test can read them.
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(String, [String: LogValue])] = []

        func record(_ event: String, _ fields: [String: LogValue]) {
            lock.lock()
            lines.append((event, fields))
            lock.unlock()
        }

        func first(_ event: String) -> [String: LogValue]? {
            lock.lock()
            defer { lock.unlock() }
            return lines.first { $0.0 == event }?.1
        }
    }

    @MainActor
    private func recorder(
        _ engine: StubEngine,
        deliver: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = {
            MainThreadTick.run($0)
        }
    ) -> Recorder {
        Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: deliver
            )
        )
    }

    @MainActor
    func testTheMainQueueKeepsAnsweringWhileTheEngineStarts() async throws {
        let engine = try StubEngine(startDelay: 0.3)
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        let probe = MainQueueProbe()
        probe.start()
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
        let largestGap = probe.stop()
        print("BENCH pressPath mainQueueGap=\(Int(largestGap))ms with a 300 ms engine")

        guard case .success? = report?.result else {
            return XCTFail("the start should have succeeded, got \(String(describing: report))")
        }
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.tapCount, 1)
        XCTAssertLessThan(
            largestGap,
            100,
            "the main queue stalled for \(Int(largestGap)) ms while the engine was starting"
        )
    }

    @MainActor
    func testACancelWhileTheEngineStartsTakesTheTakeBackAndStopsTheEngine() async throws {
        let engine = try StubEngine(startDelay: 0.3)
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        // The engine is held inside its own start, so the take is cancelled
        // after the open began: the engine that opened is the one to drain.
        let held = engine.blockNextStart()
        recorder.start(deviceUID: nil) { value in
            report = value
            answered.fulfill()
        }
        XCTAssertEqual(held.entered.wait(timeout: .now() + 5), .success, "the engine never started opening")
        XCTAssertEqual(recorder.state, .starting)
        recorder.cancel()
        held.release.signal()
        XCTAssertFalse(recorder.isRecording, "a cancelled start must never read as a recording")

        await fulfillment(of: [answered], timeout: 10)

        guard case .failure(.cancelled)? = report?.result else {
            return XCTFail("the start should have reported a cancellation, got \(String(describing: report))")
        }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(engine.stopCount, 1, "the engine that opened must be stopped, not left running")
    }

    @MainActor
    func testAStopWhileTheEngineStartsAnswersAtOnceWithAnEmptyTake() async throws {
        let engine = try StubEngine(startDelay: 0.3)
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }

        let before = CACurrentMediaTime()
        let recording = recorder.stop()
        let milliseconds = (CACurrentMediaTime() - before) * 1000

        print("BENCH pressPath stopDuringStarting=\(Int(milliseconds))ms")
        XCTAssertLessThan(milliseconds, 50, "stop() waited \(Int(milliseconds)) ms for a start that had not finished")
        XCTAssertEqual(recording.sampleCount, 0)
        XCTAssertEqual(recording.duration, 0)
        XCTAssertFalse(recorder.isRecording)
        await fulfillment(of: [answered], timeout: 10)
    }

    /// The instrument Test A leans on: a blocked main queue is seen as a gap.
    ///
    /// Without this, a probe that never fired would let the main-queue test pass
    /// over a main thread that was blocked for the whole start.
    @MainActor
    func testTheProbeNoticesABlockedMainQueue() {
        let probe = MainQueueProbe()
        probe.start()
        // Block the main thread the way a synchronous start used to. The timer
        // that came due during the block runs on the next turn of the run loop,
        // and that is where it reads the gap.
        let until = CACurrentMediaTime() + 0.2
        while CACurrentMediaTime() < until {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let largestGap = probe.stop()
        print("BENCH pressPath controlGap=\(Int(largestGap))ms for a 200 ms block")
        XCTAssertGreaterThan(
            largestGap,
            150,
            "the probe did not see a 200 ms block on the main queue"
        )
    }

    /// A take that is starting answers the record key the way a recording does.
    ///
    /// The table itself is ``RecordKeyInteraction``'s; what is checked here is
    /// the phase the app reports while the engine is opening, because a press
    /// that started a second take, or a hold release that did nothing, would
    /// leave a take nobody can stop.
    func testATakeThatIsStillStartingAnswersTheRecordKeyAsARecording() {
        let phase = AppDelegate.phase(for: .starting)
        XCTAssertEqual(phase, .recording)
        XCTAssertEqual(RecordKeyInteraction.action(for: .press, mode: .hold, phase: phase), .stop)
        XCTAssertEqual(RecordKeyInteraction.action(for: .release, mode: .hold, phase: phase), .stop)
        XCTAssertEqual(RecordKeyInteraction.action(for: .press, mode: .toggle, phase: phase), .stop)
        XCTAssertEqual(RecordKeyInteraction.action(for: .release, mode: .toggle, phase: phase), .ignore)
    }

    /// The device list is asked once, off the main thread, and nowhere else.
    ///
    /// A discovery session and the HAL reads behind it are synchronous questions
    /// to the audio server. They used to be asked on the press that starts a
    /// recording and again in `refreshMenu()`. The scan is the contract: only the
    /// catalog's cache refresh may ask, so a second caller is a failing test
    /// rather than a stall nobody sees until someone plugs in a headset.
    func testTheDeviceListIsOnlyReadByTheCatalogCache() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogPath = "Sources/Dot/MicrophoneCatalog.swift"
        let markers = [
            "AVCaptureDevice.DiscoverySession",
            "CoreAudioInput.defaultInputUID(",
            "AudioObjectGetPropertyData(",
        ]

        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root.appendingPathComponent("Sources/Dot"),
                includingPropertiesForKeys: nil
            )
        )
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard relative != catalogPath else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for marker in markers {
                XCTAssertFalse(
                    text.contains(marker),
                    "\(relative) asks the audio system for the device list outside the cache: \(marker)"
                )
            }
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 50, "the scan did not reach the app's sources")

        let catalog = try String(contentsOf: root.appendingPathComponent(catalogPath), encoding: .utf8)
        let refresh = try XCTUnwrap(body(of: "private static func read() -> Snapshot {", in: catalog))
        XCTAssertEqual(
            occurrences(of: "AVCaptureDevice.DiscoverySession", in: catalog),
            1,
            "the discovery session is not in the catalog exactly once"
        )
        XCTAssertEqual(
            occurrences(of: "AVCaptureDevice.DiscoverySession", in: catalog),
            occurrences(of: "AVCaptureDevice.DiscoverySession", in: refresh),
            "the discovery session is created outside the cache refresh"
        )
        XCTAssertEqual(
            occurrences(of: "CoreAudioInput.defaultInputUID(", in: catalog),
            occurrences(of: "CoreAudioInput.defaultInputUID(", in: refresh),
            "the HAL default input is read outside the cache refresh"
        )
        XCTAssertGreaterThan(
            occurrences(of: "CoreAudioInput.defaultInputUID(", in: catalog),
            0,
            "the cache refresh no longer reads the default input"
        )
    }

    /// A cancellation that arrives after its take was replaced stops nothing.
    ///
    /// The session is one object for the life of the recorder, so a late
    /// cancellation of take A used to be able to run its `stopCapture` after take
    /// B had opened, stopping the microphone B was recording with. Here A's
    /// answer is held between the audio queue and the app, A is cancelled and B is
    /// started inside that gap, and only then is A's answer allowed through.
    @MainActor
    func testALateCancellationOfAReplacedTakeDoesNotStopTheNextOne() async throws {
        let engineA = try StubEngine(startDelay: 0)
        let engineB = try StubEngine(startDelay: 0)
        let engines = EngineQueue([engineA, engineB])
        let gate = DeliveryGate()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engines.next() },
                isAuthorized: { true },
                deliver: { gate.deliver($0) }
            )
        )

        var first: Recorder.StartReport?
        recorder.start(deviceUID: nil) { first = $0 }
        // A's engine is open and its answer is waiting at the gate: everything
        // below happens inside the gap the ownership checks have to survive.
        await gate.waitForHeld(1)
        let firstGeneration = recorder.startGeneration

        recorder.cancel()
        var second: Recorder.StartReport?
        recorder.start(deviceUID: nil) { second = $0 }
        await gate.waitForHeld(2)
        gate.release()

        XCTAssertEqual(firstGeneration, 1)
        XCTAssertEqual(second?.generation, 2)
        guard case .failure(.cancelled)? = first?.result else {
            return XCTFail("A should have reported its cancellation, got \(String(describing: first))")
        }
        guard case .success? = second?.result else {
            return XCTFail("B should have started, got \(String(describing: second))")
        }
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(engineB.stopCount, 0, "B's engine was stopped by A's late cancellation")
        XCTAssertTrue(engineB.isRunning, "B's engine is not running")
        XCTAssertEqual(engineA.stopCount, 1, "the engine of the abandoned take was left running")
    }

    /// A device that changes while the engine opens is rebuilt before the take is
    /// published.
    ///
    /// Opening the engine takes as long as the device takes, and a device that
    /// finishes connecting inside that window leaves the take with a converter for
    /// a format the microphone no longer uses.
    @MainActor
    func testADeviceThatChangesWhileTheEngineOpensIsRebuiltBeforeTheTakeIsPublished() async throws {
        let engine = try StubEngine(startDelay: 0.02)
        try engine.changeFormatOnStart(44_100)
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .success? = report?.result else {
            return XCTFail("the start should have succeeded, got \(String(describing: report))")
        }
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(
            engine.lastTapFormat?.sampleRate,
            44_100,
            "the take was published on the converter of the format the device had before it changed"
        )
        XCTAssertEqual(engine.installCount, 2, "the tap was not installed again for the new format")
    }

    /// A route change that arrives while the take is being published is rebuilt
    /// after it is published.
    ///
    /// The observer is installed before the take is reconciled, so a change that
    /// lands between reconciliation and publication is noted and run once the
    /// recorder is `.recording`, not lost.
    @MainActor
    func testARouteChangeThatArrivesWhileTheTakeIsPublishingIsRebuiltAfterwards() async throws {
        let engine = try StubEngine(startDelay: 0)
        let gate = DeliveryGate()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { gate.deliver($0) }
            )
        )
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report = $0 }
        // The engine is open and reconciled; the answer is waiting at the gate, so
        // everything below happens in the window the fix is about.
        await gate.waitForHeld(1)
        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { recorder.pendingRouteCheck }

        gate.release()
        await waitUntil { engine.installCount == 2 }

        guard case .success? = report?.result else {
            return XCTFail("the start should have succeeded, got \(String(describing: report))")
        }
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(
            engine.lastTapFormat?.sampleRate,
            44_100,
            "the take stayed on the format it was reconciled with"
        )
        XCTAssertEqual(engine.installCount, 2)
    }

    @MainActor
    func testCancellingBeforeTheQueuedStartFailureSuppressesTheError() async throws {
        let engine = try StubEngine(startDelay: 0, startError: .noInputDevice)
        let gate = DeliveryGate()
        let recorder = Recorder(environment: .init(
            makeEngine: { engine },
            isAuthorized: { true },
            deliver: { gate.deliver($0) }
        ))
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report = $0 }
        await gate.waitForHeld(1)
        XCTAssertEqual(recorder.state, .starting)

        recorder.cancel()
        gate.release()

        guard case .failure(.cancelled)? = report?.result else {
            return XCTFail("The queued error must become a cancellation: \(String(describing: report))")
        }
        XCTAssertEqual(recorder.state, .idle)
    }

    /// A cancelled start leaves no route observer and no noted change behind.
    ///
    /// What the start installed belongs to its generation: the cancel takes it
    /// away immediately, and the answer that arrives afterwards cannot take away
    /// the observer of the start that replaced it.
    @MainActor
    func testACancelledStartLeavesNoRouteObserverAndNoFlagBehind() async throws {
        let engineA = try StubEngine(startDelay: 0.2)
        let engineB = try StubEngine(startDelay: 0)
        let engines = EngineQueue([engineA, engineB])
        let gate = DeliveryGate()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engines.next() },
                isAuthorized: { true },
                deliver: { gate.deliver($0) }
            )
        )

        var first: Recorder.StartReport?
        recorder.start(deviceUID: nil) { first = $0 }
        // The answer is held at the delivery gate, so the take is still starting
        // when the active engine's route change arrives.
        await gate.waitForHeld(1)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engineA.configurationIdentity
        )
        await waitUntil { recorder.pendingRouteCheck }
        XCTAssertEqual(recorder.routeObserverCount, 1)

        recorder.cancel()
        XCTAssertEqual(recorder.routeObserverCount, 0, "the cancelled start kept its route observer")
        XCTAssertFalse(recorder.pendingRouteCheck, "the cancelled start kept its noted change")

        await gate.waitForHeld(1)
        gate.release()
        guard case .failure(.cancelled)? = first?.result else {
            return XCTFail("A should have reported its cancellation, got \(String(describing: first))")
        }
        XCTAssertEqual(recorder.routeObserverCount, 0, "the answer of the cancelled start installed an observer")
        XCTAssertFalse(recorder.pendingRouteCheck)

        // B publishes without consuming a note that belonged to A.
        gate.hold()
        var second: Recorder.StartReport?
        recorder.start(deviceUID: nil) { second = $0 }
        await gate.waitForHeld(1)
        gate.release()
        guard case .success? = second?.result else {
            return XCTFail("B should have started, got \(String(describing: second))")
        }
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(engineB.installCount, 1, "B was rebuilt for a change that belonged to A")
        XCTAssertFalse(recorder.pendingRouteCheck)
    }

    /// The take is labelled by the device its engine opened, not by the lookup
    /// that came before it.
    @MainActor
    func testATakeIsLabelledByTheDeviceItsEngineOpened() async throws {
        // The default lookup answers B, and it is already loaded when the take
        // starts, so B is what a pre-open read would have said.
        let catalog = CatalogCache(discovery: {
            CatalogCache.Snapshot(
                devices: [MicrophoneDevice(uid: "device-b", name: "Desk mic")],
                defaultInputUID: "device-b"
            )
        })
        let previous = MicrophoneCatalog.cache
        MicrophoneCatalog.cache = catalog
        defer { MicrophoneCatalog.cache = previous }
        await waitUntil { catalog.snapshot().isLoaded }
        XCTAssertEqual(
            MicrophoneCatalog.recordingDeviceUID(configured: nil),
            "device-b",
            "the default lookup did not answer B, so the test cannot tell the two apart"
        )

        // The engine opens C.
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-c")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .success? = report?.result else {
            return XCTFail("the take should have started, got \(String(describing: report))")
        }
        XCTAssertEqual(
            report?.openedDeviceUID,
            "device-c",
            "the take was labelled by the lookup instead of the device its engine opened"
        )

        // The calibration of the take belongs to C, and B's entry is untouched.
        let observation = try XCTUnwrap(
            MicrophoneCalibrationBook.observation(samples: try toneSamples(), peakDBFS: -20)
        )
        var book = MicrophoneCalibrationBook.folding(
            [:],
            observation: observation,
            device: "device-b",
            now: Date()
        )
        let bEntry = MicrophoneCalibrationBook.calibration(for: "device-b", in: book)
        book = MicrophoneCalibrationBook.folding(
            book,
            observation: observation,
            device: try XCTUnwrap(report?.openedDeviceUID),
            now: Date()
        )
        XCTAssertEqual(
            MicrophoneCalibrationBook.calibration(for: "device-b", in: book),
            bEntry,
            "the take updated the calibration of a device it did not record on"
        )
        XCTAssertNotNil(
            MicrophoneCalibrationBook.calibration(for: "device-c", in: book),
            "the take left no calibration on the device it recorded on"
        )
    }

    /// A catalog that never answers still records, and the timeout line names the
    /// device that was asked for and the one the engine opened.
    @MainActor
    func testACatalogTimeoutLogsBothDevices() async throws {
        let slow = CatalogCache(discovery: {
            Thread.sleep(forTimeInterval: 2.5)
            return CatalogCache.Snapshot(devices: [], defaultInputUID: "device-b")
        })
        let previous = MicrophoneCatalog.cache
        MicrophoneCatalog.cache = slow
        defer { MicrophoneCatalog.cache = previous }

        let engine = try StubEngine(startDelay: 0)
        engine.holdDevice("device-c")
        let logged = LogBox()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                logWarning: { event, fields in logged.record(event, fields) }
            )
        )
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: "device-a") { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .failure(.noInputDevice)? = report?.result else {
            return XCTFail("an explicit device must not fall back to the default, got \(String(describing: report))")
        }
        let line = try XCTUnwrap(logged.first("catalog.wait.timeout"))
        XCTAssertEqual(try XCTUnwrap(double(line["seconds"])), 2)
        XCTAssertEqual(try XCTUnwrap(string(line["requested_device"])), "device-a")
        XCTAssertEqual(try XCTUnwrap(string(line["opened_device"])), "device-c")
    }

    /// A take whose opened device cannot be read is not calibrated at all.
    @MainActor
    func testATakeWithNoReadableDeviceIsNotCalibrated() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-c")
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                openedDeviceUID: { _ in nil }
            )
        )
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .success? = report?.result else {
            return XCTFail("the take should have started, got \(String(describing: report))")
        }
        XCTAssertNil(report?.openedDeviceUID, "a device that cannot be read must not be named")

        // A store that already holds an entry for the device the stub engine
        // reported and one for a known device. A take with no identity may not
        // touch either of them.
        let observation = try XCTUnwrap(
            MicrophoneCalibrationBook.observation(samples: try toneSamples(), peakDBFS: -20)
        )
        var store = MicrophoneCalibrationBook.folding(
            [:],
            observation: observation,
            device: "device-b",
            now: Date()
        )
        store = MicrophoneCalibrationBook.folding(
            store,
            observation: observation,
            device: "device-c",
            now: Date()
        )
        let before = store

        // The app's path: the device the take reports is what a fold uses, and a
        // take with none folds nothing.
        if let device = report?.openedDeviceUID {
            store = MicrophoneCalibrationBook.folding(
                store,
                observation: observation,
                device: device,
                now: Date()
            )
        }
        XCTAssertEqual(store, before, "a take with no readable device changed the calibration store")

        // The instrument: the same fold with a device does change the store, so a
        // store that was silently touched could not pass the check above.
        let control = MicrophoneCalibrationBook.folding(
            before,
            observation: observation,
            device: "device-c",
            now: Date()
        )
        XCTAssertNotEqual(
            control,
            before,
            "the test cannot tell a store that was touched from one that was not"
        )
    }

    /// A restarted engine re-reads the device it is running on.
    ///
    /// A route that leaves the format alone stops the engine; starting it again
    /// can be starting it on another device, so the take's identity is read again
    /// after every successful start, not only after an open or a rebuild.
    @MainActor
    func testARestartedEngineReportsTheDeviceItIsOnNow() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-b")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(recorder.state, .recording)

        engine.stop()
        engine.setDevice("device-c")
        let changed = expectation(description: "the take reported its new device")
        recorder.onDeviceChange = { uid in
            if uid == "device-c" { changed.fulfill() }
        }
        recorder.checkForFormatChange()
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(recorder.state, .recording)
    }

    /// A take that recorded on one device teaches that device.
    @MainActor
    func testASingleDeviceTakeTeachesItsCalibration() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-b")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        try feed(engine)
        XCTAssertGreaterThan(recorder.sampleCount, 0, "the tap produced no samples")

        let recording = recorder.stop()
        XCTAssertFalse(recording.spannedDevices, "a take on one device was marked as spanning")
        XCTAssertEqual(AppDelegate.calibrationTarget(for: recording), "device-b")
    }

    /// A take that recorded on two devices teaches neither of them.
    @MainActor
    func testATakeThatRanOnTwoDevicesTeachesNothing() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-b")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        try feed(engine)
        XCTAssertGreaterThan(recorder.sampleCount, 0, "the tap produced no samples")

        // The engine stops, the device under it changes, and the same converter
        // starts again on the new device.
        engine.stop()
        engine.setDevice("device-c")
        let changed = expectation(description: "the take reported its new device")
        recorder.onDeviceChange = { uid in
            if uid == "device-c" { changed.fulfill() }
        }
        recorder.checkForFormatChange()
        await fulfillment(of: [changed], timeout: 5)

        let recording = recorder.stop()
        XCTAssertTrue(recording.spannedDevices, "the take did not record that it ran on two devices")
        XCTAssertNil(
            AppDelegate.calibrationTarget(for: recording),
            "a take that ran on two devices would teach one of them its mixed floor"
        )
    }

    /// A stop is claimed on the main actor, not behind the audio queue.
    ///
    /// The queue is held inside a route reconciliation's restart, exactly where
    /// a synchronous stop waits. The claim must return without touching it, mark
    /// the take as stopping, release the clock and the route observer, and queue
    /// exactly one drain. The audio that arrives before that drain runs is still
    /// the take's, and the device and spanning flag are the ones the queue finds.
    @MainActor
    func testAStopIsClaimedWithoutWaitingForAReconcilingAudioQueue() async throws {
        let previousCache = MicrophoneCatalog.cache
        let catalog = CatalogCache(discovery: {
            CatalogCache.Snapshot(devices: [], defaultInputUID: nil)
        })
        MicrophoneCatalog.cache = catalog
        defer { MicrophoneCatalog.cache = previousCache }
        await waitUntil { catalog.snapshot().isLoaded }

        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let gate = DeliveryGate()
        let recorder = self.recorder(engine, deliver: { gate.deliver($0) })

        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report = $0 }
        await gate.waitForHeld(1)
        gate.release()
        guard case .success? = report?.result else {
            return XCTFail("the take should have started, got \(String(describing: report))")
        }
        try feed(engine)
        let published = recorder.sampleCount
        XCTAssertGreaterThan(published, 0, "the take recorded nothing to stop")
        let expected = recorder.samples(in: 0..<published)
        var deviceChanges: [String?] = []
        recorder.onDeviceChange = { deviceChanges.append($0) }

        // The queue is busy restarting the engine a route change asked for, and
        // that restart is held on the queue itself.
        gate.hold()
        let restart = engine.blockNextStart()
        defer { restart.release.signal() }
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        XCTAssertEqual(
            restart.entered.wait(timeout: .now() + 5),
            .success,
            "the route change never reached the audio queue"
        )
        let stopsBeforeClaim = engine.stopCount
        // The route's replacement converter flushed the accepted tail before
        // its start was held, so the take now holds the whole accepted audio.
        let beforeClaim = recorder.sampleCount
        XCTAssertGreaterThanOrEqual(beforeClaim, published)

        let claimedAt = CACurrentMediaTime()
        let claim = try XCTUnwrap(recorder.claimStop())
        let claimedMilliseconds = (CACurrentMediaTime() - claimedAt) * 1000

        XCTAssertLessThan(
            claimedMilliseconds,
            100,
            "claiming the stop waited \(Int(claimedMilliseconds)) ms for the audio queue"
        )
        XCTAssertEqual(claim.publishedSamples, beforeClaim)
        XCTAssertEqual(recorder.state, .stopping)
        XCTAssertEqual(recorder.routeObserverCount, 0, "a claimed take kept its route observer")
        XCTAssertEqual(recorder.elapsed, 0, "a claimed take kept its clock running")
        XCTAssertEqual(recorder.sampleCount, beforeClaim, "the claim drained the take itself")
        XCTAssertEqual(engine.stopCount, stopsBeforeClaim, "the claim stopped the engine itself")
        XCTAssertNil(recorder.claimStop(), "a second stop claimed the same take")
        XCTAssertEqual(recorder.stop().sampleCount, 0, "a second stop drained the take")
        XCTAssertEqual(engine.stopCount, stopsBeforeClaim, "a second stop stopped the engine")

        // Audio that arrives while the drain waits behind the reconcile is
        // staged with the restart's candidate, because that start has not
        // succeeded yet. The claim did not snapshot the samples, and the
        // staging has not published them either.
        try feed(engine)
        XCTAssertEqual(
            recorder.sampleCount,
            beforeClaim,
            "the held restart published its frames before its device was known"
        )

        // The queue is let go. The reconcile finishes first, then the one drain,
        // and both answers are held on their way to the main actor.
        restart.release.signal()
        await gate.waitForHeld(2)
        gate.release()
        guard case .drained(let recording) = await claim.result else {
            return XCTFail("the claimed stop was abandoned")
        }

        XCTAssertEqual(Array(recording.samples.prefix(published)), expected, "the drain lost already-published audio")
        // The buffer fed behind the held restart went through the replacement
        // converter, so it is a fresh block of the same tone.
        let staged = try expectedAudio([440])
        XCTAssertEqual(
            recording.samples.count,
            beforeClaim + staged.count,
            "the audio that arrived behind the held restart was not drained"
        )
        XCTAssertEqual(
            Array(recording.samples.suffix(staged.count)),
            staged,
            "the audio that arrived behind the held restart was lost or changed"
        )
        XCTAssertEqual(recording.deviceUID, "device-a")
        XCTAssertFalse(recording.spannedDevices, "a take that stayed on one device was marked as spanning")
        XCTAssertEqual(engine.stopCount, stopsBeforeClaim + 1, "the take was drained more than once")
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(
            deviceChanges.isEmpty,
            "the route answer of the claimed take was applied to it"
        )
    }

    /// A take is not opened over a stop whose drain has not finished.
    ///
    /// The drain owns the microphone until it answers. A start that lands in
    /// that window is answered at once as cancelled, and it opens nothing; once
    /// the cutoff has finished, the next take starts normally.
    @MainActor
    func testAStopClaimRefusesANewTakeUntilTheDrainFinishes() async throws {
        let previousCache = MicrophoneCatalog.cache
        let catalog = CatalogCache(discovery: {
            CatalogCache.Snapshot(devices: [], defaultInputUID: nil)
        })
        MicrophoneCatalog.cache = catalog
        defer { MicrophoneCatalog.cache = previousCache }
        await waitUntil { catalog.snapshot().isLoaded }

        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let gate = DeliveryGate()
        let recorder = self.recorder(engine, deliver: { gate.deliver($0) })
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report = $0 }
        await gate.waitForHeld(1)
        gate.release()
        guard case .success? = report?.result else {
            return XCTFail("the take should have started, got \(String(describing: report))")
        }
        try feed(engine)

        gate.hold()
        let restart = engine.blockNextStart()
        defer { restart.release.signal() }
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        XCTAssertEqual(restart.entered.wait(timeout: .now() + 5), .success)
        let claim = try XCTUnwrap(recorder.claimStop())
        XCTAssertEqual(recorder.state, .stopping)
        XCTAssertEqual(engine.startCount, 1)

        var refused: Recorder.StartReport?
        recorder.start(deviceUID: nil) { refused = $0 }
        guard case .failure(.cancelled)? = refused?.result else {
            return XCTFail("a start over a claimed take was not refused, got \(String(describing: refused))")
        }
        XCTAssertEqual(recorder.state, .stopping, "the refused start changed the claimed take")
        XCTAssertEqual(engine.startCount, 1, "the refused start opened the microphone")

        restart.release.signal()
        await gate.waitForHeld(2)
        gate.release()
        guard case .drained = await claim.result else {
            return XCTFail("the claimed stop was abandoned")
        }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(
            engine.startCount,
            2,
            "the refused start opened an engine, or the reconcile did not restart it"
        )

        gate.hold()
        var next: Recorder.StartReport?
        recorder.start(deviceUID: nil) { next = $0 }
        await gate.waitForHeld(1)
        gate.release()
        guard case .success? = next?.result else {
            return XCTFail("a take after the cutoff should start, got \(String(describing: next))")
        }
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(engine.startCount, 3, "the take after the cutoff did not open the microphone")
    }

    /// A claim that is taken back still lets the one drain release the engine,
    /// and never answers with audio.
    @MainActor
    func testAStopClaimTakenBackReleasesTheTakeWithoutDelivering() async throws {
        let previousCache = MicrophoneCatalog.cache
        let catalog = CatalogCache(discovery: {
            CatalogCache.Snapshot(devices: [], defaultInputUID: nil)
        })
        MicrophoneCatalog.cache = catalog
        defer { MicrophoneCatalog.cache = previousCache }
        await waitUntil { catalog.snapshot().isLoaded }

        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        try feed(engine)
        let stopsBeforeClaim = engine.stopCount

        let claim = try XCTUnwrap(recorder.claimStop())
        recorder.cancel()
        XCTAssertTrue(claim.isAbandoned, "a cancelled claim kept its delivery")
        XCTAssertEqual(recorder.state, .stopping, "a cancelled claim let go of the microphone before the drain")
        recorder.cancel()

        guard case .abandoned = await claim.result else {
            return XCTFail("a cancelled claim delivered audio")
        }
        await waitUntil { recorder.state == .idle }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(
            engine.stopCount,
            stopsBeforeClaim + 1,
            "the engine was stopped more than once for one claim"
        )
    }

    /// A route answer is matched to the take that asked for it, not to the
    /// phase it arrives in.
    ///
    /// The answer is let through after the claimed take has ended and a newer
    /// take is recording on another device. The phase alone would apply the old
    /// take's device to the new one; the identity must drop it.
    @MainActor
    func testALateRouteAnswerFromAClaimedTakeIsNotAppliedToTheNextOne() async throws {
        let previousCache = MicrophoneCatalog.cache
        let catalog = CatalogCache(discovery: {
            CatalogCache.Snapshot(devices: [], defaultInputUID: nil)
        })
        MicrophoneCatalog.cache = catalog
        defer { MicrophoneCatalog.cache = previousCache }
        await waitUntil { catalog.snapshot().isLoaded }

        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let gate = DeliveryGate()
        let recorder = self.recorder(engine, deliver: { gate.deliver($0) })
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report = $0 }
        await gate.waitForHeld(1)
        gate.release()
        guard case .success? = report?.result else {
            return XCTFail("the take should have started, got \(String(describing: report))")
        }
        try feed(engine)
        var deviceChanges: [String?] = []
        recorder.onDeviceChange = { deviceChanges.append($0) }

        // A route change is reconciled and its answer is held on the way to the
        // main actor.
        gate.hold()
        engine.stop()
        engine.setDevice("device-b")
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        await gate.waitForHeld(1)
        XCTAssertTrue(deviceChanges.isEmpty, "the reconcile reported a device before its answer was let through")

        // The stop claims the take and its drain answers behind the route's
        // answer, which is still held.
        let claim = try XCTUnwrap(recorder.claimStop())
        await gate.waitForHeld(2)
        gate.releaseHeld(at: 1)
        guard case .drained(let recording) = await claim.result else {
            return XCTFail("the claimed stop was abandoned")
        }
        XCTAssertTrue(recording.spannedDevices, "the take recorded on A and B and was not marked as spanning")
        XCTAssertNil(AppDelegate.calibrationTarget(for: recording))
        XCTAssertEqual(recorder.state, .idle)

        // A new take records on C, with the old route answer still held.
        engine.setDevice("device-c")
        var next: Recorder.StartReport?
        recorder.start(deviceUID: nil) { next = $0 }
        await gate.waitForHeld(2)
        gate.releaseHeld(at: 1)
        guard case .success? = next?.result else {
            return XCTFail("the next take should have started, got \(String(describing: next))")
        }
        XCTAssertEqual(recorder.state, .recording)

        // The stale answer is let through last. It belongs to the claimed take,
        // and it must not touch the take that is recording now.
        gate.releaseHeld(at: 0)
        XCTAssertTrue(deviceChanges.isEmpty, "the claimed take's route answer was applied to the next take")
        XCTAssertEqual(recorder.state, .recording)
    }

    /// Pushes one block of audio through the tap the recorder installed.
    private func toneBuffer(
        frequency: Double,
        format: AVAudioFormat? = nil,
        frames: Int = 4_800
    ) throws -> AVAudioPCMBuffer {
        let actual = try format ?? StubEngine.makeFormat(48_000)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: actual, frameCapacity: AVAudioFrameCount(frames))
        )
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<frames {
            channel[frame] = 0.3 * Float(sin(
                2 * Double.pi * frequency * Double(frame) / actual.sampleRate
            ))
        }
        return buffer
    }

    private func expectedAudio(_ frequencies: [Double], rate: Double = 48_000) throws -> [Int16] {
        var output: [Int16] = []
        let format = try StubEngine.makeFormat(rate)
        for frequency in frequencies {
            let resampler = try Resampler(inputFormat: format)
            output.append(contentsOf: try resampler.convert(
                try toneBuffer(frequency: frequency, format: format)
            ))
            output.append(contentsOf: try resampler.flush())
        }
        return output
    }

    private func feed(_ engine: StubEngine, frames: Int = 4_800, frequency: Double = 440) throws {
        let tap = try XCTUnwrap(engine.installedTap, "the recorder installed no tap")
        let format = try engine.lastTapFormat ?? StubEngine.makeFormat(48_000)
        let buffer = try toneBuffer(frequency: frequency, format: format, frames: frames)
        tap(buffer, AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
    }

    /// A take that crossed devices while its route change was still on its way
    /// to the app is a spanning take.
    ///
    /// The device change is decided where the audio is, on the audio queue, so a
    /// stop that lands before the app has heard about the change still knows the
    /// take ran on both devices.
    @MainActor
    func testAStopBeforeTheRouteChangeIsDeliveredStillSpans() async throws {
        let recording = try await stopWithHeldRouteChange(feedBeforeSwitch: true)
        XCTAssertTrue(recording.spannedDevices)
        XCTAssertNil(AppDelegate.calibrationTarget(for: recording))
    }

    @MainActor
    func testAStopBeforeRouteDeliveryUsesTheOnlyMicrophoneThatProducedSamples() async throws {
        let recording = try await stopWithHeldRouteChange(feedBeforeSwitch: false)
        XCTAssertFalse(recording.spannedDevices)
        XCTAssertEqual(AppDelegate.calibrationTarget(for: recording), "device-b")
    }

    @MainActor
    private func stopWithHeldRouteChange(feedBeforeSwitch: Bool) async throws -> Recorder.Recording {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let gate = DeliveryGate()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { gate.deliver($0) }
            )
        )
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report = $0 }
        await gate.waitForHeld(1)
        gate.release()
        guard case .success? = report?.result else {
            XCTFail("the take should have started, got \(String(describing: report))")
            throw RecorderError.noInputDevice
        }
        if feedBeforeSwitch {
            try feed(engine)
            XCTAssertGreaterThan(recorder.sampleCount, 0, "the first tap produced no samples")
        } else {
            XCTAssertEqual(recorder.sampleCount, 0)
        }

        // The route stops the engine and it starts again on B, same format. The
        // outcome is held at the gate, so the app has not heard about it yet.
        gate.hold()
        engine.stop()
        engine.setDevice("device-b")
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await gate.waitForHeld(1)

        defer { gate.release() }
        let sampleCountBeforeFeeding = recorder.sampleCount
        try feed(engine)
        XCTAssertGreaterThan(recorder.sampleCount, sampleCountBeforeFeeding)
        return recorder.stop()
    }

    /// A take whose device changed before it was published is a spanning take.
    ///
    /// The audio arrives on A while the engine opens; the reconcile rebuilds onto
    /// B before the take is published. Publication must not clear what the audio
    /// queue already knows.
    @MainActor
    func testATakeRebuiltBeforePublicationStillSpans() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        try engine.changeFormatOnStart(44_100)
        // The first start stays on device-a and commits the block it emitted;
        // the rebuild that the format change forces is the start that lands on
        // device-b, so the take really holds audio from both.
        engine.switchDeviceOnStart("device-b", afterStarts: 1)
        engine.feedAudioOnStart()
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .success? = report?.result else {
            return XCTFail("the take should have started, got \(String(describing: report))")
        }
        XCTAssertEqual(engine.installCount, 2, "the reconcile did not rebuild the take")
        let recording = recorder.stop()
        XCTAssertTrue(
            recording.spannedDevices,
            "the take recorded on A and then on B and was not marked as spanning"
        )
        XCTAssertNil(AppDelegate.calibrationTarget(for: recording))
    }

    /// A take that stayed on one device still teaches it.
    @MainActor
    func testATakeThatStayedOnOneDeviceStillTeachesIt() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        try feed(engine)

        let recording = recorder.stop()
        XCTAssertFalse(recording.spannedDevices)
        XCTAssertEqual(AppDelegate.calibrationTarget(for: recording), "device-a")
    }

    /// The calibration target of a take is a pure decision over the take.
    func testTheCalibrationTargetIsTheDeviceOfATakeThatStayedOnOne() {
        let single = Recorder.Recording(
            samples: [],
            duration: 0,
            peakDBFS: 0,
            deviceUID: "device-a"
        )
        XCTAssertEqual(AppDelegate.calibrationTarget(for: single), "device-a")

        let spanning = Recorder.Recording(
            samples: [],
            duration: 0,
            peakDBFS: 0,
            spannedDevices: true,
            deviceUID: "device-b"
        )
        XCTAssertNil(
            AppDelegate.calibrationTarget(for: spanning),
            "a take that ran on two devices was given a calibration target"
        )

        let unnamed = Recorder.Recording(samples: [], duration: 0, peakDBFS: 0)
        XCTAssertNil(AppDelegate.calibrationTarget(for: unnamed))
    }

    /// A quit closes every recording entry point before anything is captured or
    /// waited for.
    ///
    /// The app cannot be built in a test binary, so the wiring is read from the
    /// source, the same way the archive's quit contract is: the gate is the
    /// first thing `applicationShouldTerminate` sets, before the live loop and
    /// the recorder are taken back and before the card's last versions are read
    /// or the drain starts; the entry points that can open a microphone, claim a
    /// stop, or publish a failed take ask it before their first work; and the
    /// start answer and the live loop ask it before they publish. The recorder
    /// side of the same edge is covered by the held start and held route tests
    /// below, which run the real `shutDown()`; this test is the source-only
    /// coverage for the AppDelegate entry points, the start-answer guard, and
    /// the live-loop guards.
    func testAQuitClosesTheRecordingEntryPointsBeforeItCapturesAnything() throws {
        let source = try appDelegateSource()

        // The gate and the recorder's release are the quit's first half. It is
        // its own method so the gate can be closed without the disk work; the
        // termination request calls it before it captures or waits for
        // anything.
        let beginQuit = try XCTUnwrap(
            functionBody("func beginQuit(", in: source),
            "the quit reader found no beginQuit"
        )
        let gate = try XCTUnwrap(
            beginQuit.range(of: "quitPending = true"),
            "the quit does not close the recording entry points"
        )
        let live = try XCTUnwrap(
            beginQuit.range(of: "stopLiveTranscription()"),
            "the quit does not cancel the live loop"
        )
        let recorder = try XCTUnwrap(
            beginQuit.range(of: "recorder.shutDown()"),
            "the quit does not take the recorder back"
        )
        XCTAssertLessThan(gate.lowerBound, live.lowerBound, "the quit cancelled the live loop before its gate")
        XCTAssertLessThan(live.lowerBound, recorder.lowerBound, "the quit took the recorder back before the live loop")
        XCTAssertTrue(
            beginQuit.contains("transcriptionTask?.cancel()"),
            "the quit left a stop's delivery alive"
        )
        XCTAssertTrue(
            beginQuit.contains("recorder.invalidateStopDelivery()"),
            "the quit left the claimed drain's delivery alive"
        )
        XCTAssertTrue(beginQuit.contains("stopOwner = nil"), "the quit left the card owned by a stop")

        let quit = try XCTUnwrap(
            functionBody("func applicationShouldTerminate(", in: source),
            "the quit reader found no applicationShouldTerminate"
        )
        let gateCall = try XCTUnwrap(
            quit.range(of: "beginQuit()"),
            "the quit request never closes the recording entry points"
        )
        let rewrite = try XCTUnwrap(
            quit.range(of: "persistRewrite(rewrite.card)"),
            "the quit no longer writes the card's last versions"
        )
        let drain = try XCTUnwrap(
            quit.range(of: "Shutdown.drain("),
            "the quit no longer drains"
        )
        XCTAssertLessThan(
            gateCall.lowerBound,
            rewrite.lowerBound,
            "the quit captured the card before it closed the recording entry points"
        )
        XCTAssertLessThan(
            gateCall.lowerBound,
            drain.lowerBound,
            "the quit waited before it closed the recording entry points"
        )

        let pending = try XCTUnwrap(
            functionBody("private func takePendingArchiveWrites(", in: source),
            "the quit reader found no pending-work provider"
        )
        XCTAssertTrue(
            pending.contains("recorder.takePendingStopCutoff()"),
            "the quit does not join the one audio cutoff"
        )

        // The start answer can arrive after the quit began: it must publish
        // nothing, and it must take the recorder back if a success won the race.
        let begin = try XCTUnwrap(
            functionBody("private func beginRecording(", in: source),
            "the quit reader found no beginRecording"
        )
        let startCall = try XCTUnwrap(begin.range(of: "recorder.start(deviceUID:"))
        // The gate at the top of the method is not the answer's: the answer is
        // the guard inside the completion the start call hands over.
        let answerGate = try XCTUnwrap(
            begin.range(
                of: "guard !self.quitPending else",
                range: startCall.upperBound..<begin.endIndex
            ),
            "the start answer does not ask the quit gate"
        )
        let answerSwitch = try XCTUnwrap(begin.range(of: "switch report.result"))
        XCTAssertLessThan(startCall.lowerBound, answerGate.lowerBound)
        XCTAssertLessThan(answerGate.lowerBound, answerSwitch.lowerBound, "a start answer published during the quit")
        XCTAssertTrue(
            begin.contains("self.recorder.shutDown()"),
            "a start that wins the quit race leaves the microphone running"
        )

        // The permission answer arrives after the press returned, so the denied
        // branch must ask the quit gate itself before it draws a card. The
        // answer comes through the injected permission seam, which is the same
        // call the behavioural tests below hold open.
        let permission = try XCTUnwrap(
            functionBody("func requestMicrophoneAccessIfNeeded(", in: source),
            "the quit reader found no requestMicrophoneAccessIfNeeded"
        )
        let answer = try XCTUnwrap(
            permission.range(of: "await self.microphoneAccess.request()"),
            "the recording path no longer asks the permission seam"
        )
        let deniedGate = try XCTUnwrap(
            permission.range(
                of: "guard !self.quitPending else { return }",
                range: answer.upperBound..<permission.endIndex
            ),
            "the permission answer's denied branch does not ask the quit gate"
        )
        let deniedCard = try XCTUnwrap(
            permission.range(
                of: "self.showMicrophoneDenied()",
                range: deniedGate.upperBound..<permission.endIndex
            )
        )
        XCTAssertLessThan(
            deniedGate.lowerBound,
            deniedCard.lowerBound,
            "a denied permission can draw a card during the quit"
        )

        for (signature, firstWork) in [
            ("private func startRecording(", "startedFromHotkey = fromHotkey"),
            ("private func beginRecording(", "rewrite.reset()"),
            ("private func stopRecording(", "recorder.claimStop()"),
            ("private func failRecording(", "rewrite.reset()"),
        ] {
            let body = try XCTUnwrap(functionBody(signature, in: source), "no \(signature)")
            let gate = try XCTUnwrap(
                body.range(of: "guard !quitPending else { return }"),
                "\(signature) does not ask the quit gate"
            )
            let work = try XCTUnwrap(body.range(of: firstWork), "\(signature) lost its first work")
            XCTAssertLessThan(
                gate.lowerBound,
                work.lowerBound,
                "\(signature) worked before it asked the quit gate"
            )
        }
    }

    /// A quit while a start's success is held takes the start back without
    /// waiting, and the microphone is released exactly once.
    ///
    /// The answer is held on its way to the main actor, which is the window a
    /// quit can land in. The quit must not leave the card to open later and
    /// must not wait for the audio queue. The open has already returned, so the
    /// quit queues the engine's one teardown itself; that stop may not have run
    /// yet when the quit returns, and the held answer must not stop it again.
    @MainActor
    func testAQuitWhileAStartSuccessIsHeldTakesTheStartBackWithoutWaiting() async throws {
        let previousCache = MicrophoneCatalog.cache
        let catalog = CatalogCache(discovery: {
            CatalogCache.Snapshot(devices: [], defaultInputUID: nil)
        })
        MicrophoneCatalog.cache = catalog
        defer { MicrophoneCatalog.cache = previousCache }
        await waitUntil { catalog.snapshot().isLoaded }

        let engine = try StubEngine(startDelay: 0)
        let gate = DeliveryGate()
        let recorder = self.recorder(engine, deliver: { gate.deliver($0) })
        defer { gate.release() }
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report = $0 }
        await gate.waitForHeld(1)
        XCTAssertEqual(recorder.state, .starting)
        let stopsBefore = engine.stopCount

        let quitAt = CACurrentMediaTime()
        recorder.shutDown()
        let quitMilliseconds = (CACurrentMediaTime() - quitAt) * 1000

        XCTAssertLessThan(
            quitMilliseconds,
            100,
            "the quit waited \(Int(quitMilliseconds)) ms for a start that had not answered"
        )
        XCTAssertEqual(recorder.state, .idle, "an abandoned start stayed open")
        XCTAssertEqual(recorder.routeObserverCount, 0, "an abandoned start kept its observer")
        XCTAssertLessThanOrEqual(engine.stopCount, stopsBefore + 1, "the quit stopped the engine more than once")

        gate.release()
        await waitUntil { report != nil }
        guard case .failure(.cancelled)? = report?.result else {
            return XCTFail("a start held across the quit was not cancelled: \(String(describing: report))")
        }
        recorder.drainAudioQueueForTesting()
        await waitUntil { engine.stopCount == stopsBefore + 1 }
        XCTAssertEqual(engine.stopCount, stopsBefore + 1, "the abandoned start was not torn down once")
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertFalse(engine.isRunning, "the abandoned start left the microphone running")
        XCTAssertEqual(engine.startCount, 1)
    }

    /// A quit while a start's failure is held suppresses the failure and leaves
    /// the recorder idle.
    @MainActor
    func testAQuitWhileAStartFailureIsHeldSuppressesIt() async throws {
        let previousCache = MicrophoneCatalog.cache
        let catalog = CatalogCache(discovery: {
            CatalogCache.Snapshot(devices: [], defaultInputUID: nil)
        })
        MicrophoneCatalog.cache = catalog
        defer { MicrophoneCatalog.cache = previousCache }
        await waitUntil { catalog.snapshot().isLoaded }

        let engine = try StubEngine(startDelay: 0, startError: .noInputDevice)
        let gate = DeliveryGate()
        let recorder = self.recorder(engine, deliver: { gate.deliver($0) })
        defer { gate.release() }
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report = $0 }
        await gate.waitForHeld(1)
        XCTAssertEqual(recorder.state, .starting)

        let quitAt = CACurrentMediaTime()
        recorder.shutDown()
        let quitMilliseconds = (CACurrentMediaTime() - quitAt) * 1000

        XCTAssertLessThan(
            quitMilliseconds,
            100,
            "the quit waited \(Int(quitMilliseconds)) ms for a start that had not answered"
        )
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(recorder.routeObserverCount, 0)

        gate.release()
        await waitUntil { report != nil }
        guard case .failure(.cancelled)? = report?.result else {
            return XCTFail("a start failure held across the quit was published: \(String(describing: report))")
        }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(engine.stopCount, 0, "a start that never opened an engine stopped one")
        XCTAssertEqual(engine.startCount, 0)
    }

    /// A quit while a recording has a route answer held claims one drain
    /// without waiting, publishes nothing, and never drains a second time.
    @MainActor
    func testAQuitWhileARecordingHasAHeldRouteAnswerClaimsOneDrainWithoutWaiting() async throws {
        let previousCache = MicrophoneCatalog.cache
        let catalog = CatalogCache(discovery: {
            CatalogCache.Snapshot(devices: [], defaultInputUID: nil)
        })
        MicrophoneCatalog.cache = catalog
        defer { MicrophoneCatalog.cache = previousCache }
        await waitUntil { catalog.snapshot().isLoaded }

        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let gate = DeliveryGate()
        let recorder = self.recorder(engine, deliver: { gate.deliver($0) })
        defer { gate.release() }
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report = $0 }
        await gate.waitForHeld(1)
        gate.release()
        guard case .success? = report?.result else {
            return XCTFail("the take should have started, got \(String(describing: report))")
        }
        try feed(engine)
        let published = recorder.sampleCount
        XCTAssertGreaterThan(published, 0, "the take recorded nothing to stop")
        var deviceChanges: [String?] = []
        var failures: [String] = []
        recorder.onDeviceChange = { deviceChanges.append($0) }
        recorder.onFailure = { failures.append($0) }

        // The route change is being reconciled on the audio queue, and the
        // engine restart it needs is held there: the queue is busy when the
        // quit arrives, which is the window this test is about.
        gate.hold()
        let restart = engine.blockNextStart()
        defer { restart.release.signal() }
        engine.stop()
        engine.setDevice("device-b")
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        XCTAssertEqual(
            restart.entered.wait(timeout: .now() + 5),
            .success,
            "the route change never reached the audio queue"
        )
        let stopsBefore = engine.stopCount
        // The route's replacement converter flushed the accepted tail before
        // its start was held, so the take now holds the whole accepted audio.
        let beforeQuit = recorder.sampleCount
        XCTAssertGreaterThanOrEqual(beforeQuit, published)

        let quitAt = CACurrentMediaTime()
        recorder.shutDown()
        let quitMilliseconds = (CACurrentMediaTime() - quitAt) * 1000

        XCTAssertLessThan(
            quitMilliseconds,
            100,
            "the quit waited \(Int(quitMilliseconds)) ms for the audio queue"
        )
        XCTAssertEqual(recorder.state, .stopping, "a recording was not claimed by the quit")
        XCTAssertEqual(recorder.sampleCount, beforeQuit, "the quit drained the take on the main thread")
        XCTAssertEqual(engine.stopCount, stopsBefore, "the quit stopped the engine itself")
        XCTAssertEqual(recorder.routeObserverCount, 0, "a claimed take kept its route observer")

        // Drop the gate: the reconcile finishes, the route answer and then the
        // one drain reach the main actor. The route answer belongs to the take
        // the quit is closing and is dropped; the claim's own answer publishes
        // nothing because the quit took its delivery back.
        restart.release.signal()
        await gate.waitForHeld(2)
        gate.releaseHeld(at: 0)
        XCTAssertTrue(deviceChanges.isEmpty, "the quit applied a route answer to the take it closed")
        XCTAssertTrue(failures.isEmpty, "the quit published a route failure")
        XCTAssertEqual(recorder.state, .stopping)

        gate.releaseHeld(at: 0)
        await waitUntil { recorder.state == .idle }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(engine.stopCount, stopsBefore + 1, "the quit drained the take more than once")
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.startCount, 2, "the quit opened the microphone again")

        // The teardown that follows (a second quit or a cancel) drains nothing.
        recorder.shutDown()
        recorder.cancel()
        XCTAssertEqual(engine.stopCount, stopsBefore + 1, "a repeated quit drained the take again")
        XCTAssertEqual(recorder.state, .idle)
    }

    /// The card belongs to the claim that took it, not to whatever is working.
    ///
    /// The state alone cannot tell a stop from the one that replaced it, which
    /// is what an answer held across the drain would need; the claim is the
    /// identity both sides share.
    @MainActor
    func testTheCardBelongsToTheClaimThatTookIt() {
        let first = Recorder.StopClaim(publishedSamples: 0)
        let second = Recorder.StopClaim(publishedSamples: 0)

        XCTAssertTrue(AppDelegate.cardBelongsTo(first, state: .working, owner: first))
        XCTAssertFalse(
            AppDelegate.cardBelongsTo(first, state: .working, owner: second),
            "a stop that lost the card to a newer claim still owned it"
        )
        XCTAssertFalse(AppDelegate.cardBelongsTo(first, state: .idle, owner: first))
        XCTAssertFalse(AppDelegate.cardBelongsTo(first, state: .working, owner: nil))
    }

    /// A cache that answers with the chosen microphone and a distinct default.
    @MainActor
    private func installSelectedDeviceCache() -> CatalogCache {
        let previous = MicrophoneCatalog.cache
        MicrophoneCatalog.cache = CatalogCache(discovery: {
            CatalogCache.Snapshot(
                devices: [
                    MicrophoneDevice(uid: "device-selected", name: "Selected mic"),
                    MicrophoneDevice(uid: "device-default", name: "System default"),
                ],
                defaultInputUID: "device-default"
            )
        })
        return previous
    }

    @MainActor
    func testASelectedMicrophoneIsChosenBeforeTheFirstFormatRead() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: "device-selected") { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .success? = report?.result else {
            return XCTFail("the start should have succeeded, got \(String(describing: report))")
        }
        let calls = engine.callLog
        XCTAssertEqual(
            Array(calls.prefix(2)),
            ["select:device-selected", "inputFormat"],
            "the input was used before the chosen device was opened: \(calls)"
        )
        XCTAssertEqual(report?.openedDeviceUID, "device-selected")
    }

    @MainActor
    func testTheSystemDefaultDoesNotSelectADevice() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: nil) { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .success? = report?.result else {
            return XCTFail("the start should have succeeded, got \(String(describing: report))")
        }
        XCTAssertFalse(
            engine.callLog.contains { $0.hasPrefix("select:") },
            "a take on the system default changed the input device"
        )
    }

    @MainActor
    func testAFailedSelectionLeavesNoTapAndReleasesTheEngine() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        var engine: StubEngine? = try StubEngine(startDelay: 0)
        weak let released = engine
        try XCTUnwrap(engine).failSelection()
        let engines = EngineQueue([try XCTUnwrap(engine)])
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engines.next() },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) }
            )
        )
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: "device-selected") { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
        let taps = try XCTUnwrap(engine).installCount
        engine = nil

        guard case .failure(.noInputDevice)? = report?.result else {
            return XCTFail("a device that cannot be opened should fail, got \(String(describing: report))")
        }
        XCTAssertEqual(taps, 0, "a tap was installed on an unopened device")
        XCTAssertNil(released, "the failed engine was kept alive")
    }

    @MainActor
    func testADeviceMismatchEndsTheStartAndLogsBothDevices() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        engine.holdDevice("device-default")
        let logged = LogBox()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                logWarning: { event, fields in logged.record(event, fields) }
            )
        )
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: "device-selected") { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .failure(.noInputDevice)? = report?.result else {
            return XCTFail("a take on the wrong device should fail, got \(String(describing: report))")
        }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(engine.stopCount, 1, "the mismatched open was not stopped")
        let line = try XCTUnwrap(logged.first("capture.device.mismatch"))
        XCTAssertEqual(string(line["requested_device"]), "device-selected")
        XCTAssertEqual(string(line["opened_device"]), "device-default")
    }

    @MainActor
    func testARouteChangeReselectsTheChosenMicrophone() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let gate = DeliveryGate()
        let recorder = self.recorder(engine, deliver: { gate.deliver($0) })
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await gate.waitForHeld(1)
        gate.release()
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(engine.writeCount, 1)

        // The unit moves off the chosen device while it runs. The route change
        // has to stop it before writing the device back: the stub refuses a
        // write to a running unit, so a recorder that selects first fails the
        // take instead of passing silently.
        engine.setDevice("device-default")
        gate.hold()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await gate.waitForHeld(1)
        gate.release()

        XCTAssertEqual(
            engine.runningSelections,
            0,
            "the chosen microphone was written while the unit was running"
        )
        XCTAssertEqual(
            engine.callLog.filter { $0.hasPrefix("select:") },
            ["select:device-selected", "select:device-selected"],
            "the route change did not reselect the chosen microphone exactly once"
        )
        XCTAssertEqual(
            Array(engine.callLog.suffix(3)),
            ["stop", "select:device-selected", "inputFormat"],
            "the reselect did not happen after the unit was stopped and before its format was read"
        )
        XCTAssertEqual(engine.writeCount, 2, "the chosen device was not written back")
    }

    @MainActor
    func testCalibrationIsLearnedForTheSelectedMicrophone() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-default")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: "device-selected") { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
        guard case .success? = report?.result else {
            return XCTFail("the start should have succeeded, got \(String(describing: report))")
        }
        try feed(engine)

        let recording = recorder.stop()
        let target = AppDelegate.calibrationTarget(for: recording)
        XCTAssertEqual(target, "device-selected", "the take was calibrated for the default input")
        let observation = try XCTUnwrap(
            MicrophoneCalibrationBook.observation(
                samples: recording.samples,
                peakDBFS: recording.peakDBFS
            )
        )
        let book = MicrophoneCalibrationBook.folding(
            [:],
            observation: observation,
            device: target,
            now: Date()
        )
        XCTAssertNotNil(book["device-selected"])
        XCTAssertNil(book["device-default"])
    }

    /// The HAL translation a device selection depends on, checked against the
    /// list the HAL itself reports. No engine is started and no audio is read.
    func testTheHALTranslatesAListedDeviceUIDAndRejectsAnUnknownOne() throws {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &devicesSize
        ) == noErr, devicesSize > 0 else {
            throw XCTSkip("the HAL lists no devices")
        }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(devicesSize) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &devicesSize,
            &devices
        ) == noErr else {
            throw XCTSkip("the HAL did not answer the device list")
        }

        var matched = false
        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(
                device,
                &uidAddress,
                0,
                nil,
                &uidSize,
                &uid
            ) == noErr, let uid else { continue }
            let uidText = uid.takeRetainedValue() as String
            guard let translated = CoreAudioInput.deviceID(forUID: uidText) else { continue }
            XCTAssertEqual(translated, device, "the HAL translated the UID to another device")
            matched = true
            break
        }
        guard matched else { throw XCTSkip("the HAL lists no input devices") }
        XCTAssertNil(
            CoreAudioInput.deviceID(forUID: "dot-unknown-device-\(UUID().uuidString)"),
            "an unknown UID was translated to a device"
        )
    }

    @MainActor
    func testAnAlreadySelectedUnitIsNotSelectedTwice() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)

        let selections = engine.callLog.filter { $0.hasPrefix("select:") }
        XCTAssertEqual(selections, ["select:device-selected"], "the unit was selected again after it was already correct")
        XCTAssertEqual(engine.writeCount, 1, "the same device was written more than once")
    }

    @MainActor
    func testAForeignConfigurationNotificationDoesNotTouchTheTake() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let gate = DeliveryGate()
        let recorder = self.recorder(engine, deliver: { gate.deliver($0) })
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await gate.waitForHeld(1)
        gate.release()
        await fulfillment(of: [answered], timeout: 10)
        let selections = engine.callLog.filter { $0.hasPrefix("select:") }
        let starts = engine.startCount
        let stops = engine.stopCount
        // The start's own reconcile is the baseline; the foreign notification
        // must not add a pass.
        let passesBefore = recorder.reconcilePassCount

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: NSObject()
        )
        // The barrier is the audio queue itself: every pass queued before this
        // line has run when it returns. Only the counter can tell that the
        // foreign notification added none; the engine counters could not.
        recorder.drainAudioQueueForTesting()
        XCTAssertEqual(
            recorder.reconcilePassCount,
            passesBefore,
            "a foreign notification ran a reconciliation pass"
        )
        // A real route answer still runs one, which proves the counter moves.
        gate.hold()
        recorder.checkForFormatChange()
        await gate.waitForHeld(1)
        gate.release()
        XCTAssertEqual(
            recorder.reconcilePassCount,
            passesBefore + 1,
            "the barrier did not run its own reconciliation"
        )
        XCTAssertEqual(engine.callLog.filter { $0.hasPrefix("select:") }, selections)
        XCTAssertEqual(engine.startCount, starts)
        XCTAssertEqual(engine.stopCount, stops)
    }

    @MainActor
    func testAnActiveEngineNotificationBeforePublicationIsStillNoted() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0.05)
        let gate = DeliveryGate()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { gate.deliver($0) }
            )
        )
        recorder.start(deviceUID: "device-selected") { _ in }
        await gate.waitForHeld(1)

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { recorder.pendingRouteCheck }
        gate.release()
    }

    @MainActor
    func testAnExplicitUIDSurvivesACatalogTimeout() async throws {
        let slow = CatalogCache(discovery: {
            Thread.sleep(forTimeInterval: 2.5)
            return CatalogCache.Snapshot(devices: [], defaultInputUID: "device-default")
        })
        let previous = MicrophoneCatalog.cache
        MicrophoneCatalog.cache = slow
        defer { MicrophoneCatalog.cache = previous }

        let engine = try StubEngine(startDelay: 0)
        let logged = LogBox()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                logWarning: { event, fields in logged.record(event, fields) }
            )
        )
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: "device-selected") { value in
            report = value
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)

        guard case .success? = report?.result else {
            return XCTFail("the HAL should have been the authority, got \(String(describing: report))")
        }
        XCTAssertEqual(report?.openedDeviceUID, "device-selected")
        XCTAssertEqual(engine.writeCount, 1, "the configured device was not opened")
        XCTAssertNotNil(logged.first("catalog.wait.timeout"))
    }

    @MainActor
    func testAnUnknownExplicitReadbackAcceptsNoFrames() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        engine.useUnknownReadback()
        // The engine emits a block while it opens, before its readback is
        // known: those frames belong to the candidate, not to the take.
        engine.feedAudioOnStart(frequency: 880)
        let admission = AdmissionHold()
        let handled = AdmissionHold()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                afterAdmission: { admission.hook() },
                afterHandle: { handled.hook() }
            )
        )
        admission.arm()
        handled.arm()
        let answered = expectation(description: "the start was answered")
        var report: Recorder.StartReport?
        recorder.start(deviceUID: "device-selected") { value in
            report = value
            answered.fulfill()
        }
        XCTAssertEqual(
            admission.waitForEntry(timeout: 5),
            .success,
            "the unverified device's buffer never reached the gate"
        )
        // Read the publication while the buffer is still inside the gate: the
        // failure path clears the store after this, so a check made only after
        // the answer could not tell abandoned frames from accepted ones.
        XCTAssertEqual(
            recorder.sampleCount,
            0,
            "frames from an unreadable device entered the publication"
        )
        XCTAssertNil(
            recorder.wav(range: 0..<8_000),
            "the unreadable device published audio before its readback was known"
        )
        admission.releaseHook()
        XCTAssertEqual(
            handled.waitForEntry(timeout: 5),
            .success,
            "the admitted buffer never reached the end of the callback"
        )
        // The second boundary is after the converter handled the buffer. A
        // transient publication between handle and verification would be
        // visible here even though the failure path clears it later.
        XCTAssertEqual(
            recorder.sampleCount,
            0,
            "the callback published frames before the readback was known"
        )
        XCTAssertNil(
            recorder.wav(range: 0..<8_000),
            "the callback published audio after the converter handled it"
        )
        handled.releaseHook()
        await fulfillment(of: [answered], timeout: 10)

        guard case .failure(.noInputDevice)? = report?.result else {
            return XCTFail("an unreadable explicit device should fail, got \(String(describing: report))")
        }
        XCTAssertEqual(engine.writeCount, 1)
        XCTAssertEqual(recorder.sampleCount, 0, "frames were accepted before the readback was known")
        XCTAssertTrue(recorder.stop().samples.isEmpty, "the failed start left audio in the take")
    }

    @MainActor
    func testARejectedRestartDiscardsWrongFramesAndRecoversTheAcceptedTake() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let gate = DeliveryGate()
        let recorder = self.recorder(engine, deliver: { gate.deliver($0) })
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await gate.waitForHeld(1)
        gate.release()
        await fulfillment(of: [answered], timeout: 10)
        try feed(engine, frequency: 440)
        let accepted = recorder.sampleCount
        let acceptedAudio = Array(try expectedAudio([440]).prefix(accepted))
        XCTAssertGreaterThan(accepted, 0)
        XCTAssertEqual(recorder.samples(in: 0..<accepted), acceptedAudio)

        gate.hold()
        engine.holdDevice("device-other")
        engine.feedAudioOnStart(frequency: 880)
        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await gate.waitForHeld(1)
        gate.release()
        // The route's replacement converter flushed the accepted 440 Hz tail
        // before its start was rejected. That tail is accepted audio; the 880
        // Hz frames from the held device are not.
        let acceptedAfterRejection = try expectedAudio([440])
        XCTAssertEqual(
            recorder.samples(in: 0..<recorder.sampleCount),
            acceptedAfterRejection,
            "the rejected 880 Hz frames changed or replaced the accepted audio"
        )

        engine.resumeSelection()
        engine.setDevice("device-selected")
        try engine.setFormat(48_000)
        gate.hold()
        recorder.checkForFormatChange()
        await gate.waitForHeld(1)
        gate.release()
        try feed(engine, frequency: 1_320)

        let recording = recorder.stop()
        let expected = try expectedAudio([440, 1_320])
        XCTAssertEqual(recording.samples, expected, "the recovered WAV did not contain exactly the two accepted tones")
        XCTAssertEqual(recording.deviceUID, "device-selected", "the prior accepted identity was lost")
    }

    @MainActor
    func testADefaultRestartFailureUsesExistingVisibleRecovery() async throws {
        let engine = try StubEngine(startDelay: 0)
        let clock = ManualRecoveryClock()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        let ended = expectation(description: "the failed restart ended the take")
        recorder.onFailure = { _ in ended.fulfill() }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        try feed(engine, frequency: 440)
        let expected = try expectedAudio([440])

        engine.setDevice("device-default")
        engine.stop()
        engine.failStartOnNext()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { clock.scheduledCount == 1 }
        XCTAssertTrue(recorder.isRecording, "the failed restart ended the take before its deadline")
        clock.advance(to: 2.0)
        clock.runNext()
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertFalse(recorder.isRecording)
        let recording = recorder.stop()
        XCTAssertEqual(recording.samples, expected)
        // The take opened with no readable identity; the failed restart's
        // readback is not evidence that device-default recorded anything.
        XCTAssertNil(recording.deviceUID)
        XCTAssertNil(AppDelegate.calibrationTarget(for: recording))
    }

    @MainActor
    func testARetiredTapCallbackAfterSameRateRebuildAddsNoSamples() async throws {
        let engine = try StubEngine(startDelay: 0)
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        try feed(engine, frequency: 440)
        let expected = try expectedAudio([440])

        engine.setFormat(try StubEngine.makeFormat(48_000, channels: 2))
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { engine.installCount == 2 }
        XCTAssertEqual(engine.retainedTapCount, 2)

        try engine.invokeRetainedTap(0, frequency: 880)
        XCTAssertEqual(recorder.samples(in: 0..<recorder.sampleCount), expected)
        XCTAssertEqual(recorder.stop().samples, expected)
    }

    @MainActor
    func testADefaultReplacementStartIncludesFramesFromItsOwnStart() async throws {
        let first = try StubEngine(startDelay: 0)
        let second = try StubEngine(startDelay: 0)
        second.setDevice("device-b")
        second.feedAudioOnStart(frequency: 880)
        let engines = EngineQueue([first, second])
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engines.next() },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) }
            )
        )

        let firstAnswered = expectation(description: "the first start was answered")
        recorder.start(deviceUID: nil) { _ in firstAnswered.fulfill() }
        await fulfillment(of: [firstAnswered], timeout: 10)
        _ = recorder.stop()

        let secondAnswered = expectation(description: "the replacement start was answered")
        recorder.start(deviceUID: nil) { _ in secondAnswered.fulfill() }
        await fulfillment(of: [secondAnswered], timeout: 10)

        let recording = recorder.stop()
        XCTAssertEqual(recording.samples, try expectedAudio([880]))
        XCTAssertEqual(recording.deviceUID, "device-b")
        XCTAssertFalse(
            recording.spannedDevices,
            "a take whose only audio came from device-b was marked as mixed"
        )
        XCTAssertEqual(
            AppDelegate.calibrationTarget(for: recording),
            "device-b",
            "the only device that supplied audio taught nothing"
        )
    }

    @MainActor
    func testAnExplicitRejectionEndsVisiblyAndPreservesPriorAcceptedAudio() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let recorder = self.recorder(engine)
        let ended = expectation(description: "the rejected route ended the take")
        recorder.onFailure = { _ in ended.fulfill() }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 10)
        try feed(engine, frequency: 440)
        let expected = try expectedAudio([440])

        engine.holdDevice("device-other")
        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertFalse(recorder.isRecording)
        let recording = recorder.stop()
        XCTAssertEqual(recording.samples, expected)
        XCTAssertEqual(recording.deviceUID, "device-selected")

        engine.resumeSelection()
        engine.setDevice("device-selected")
        // The returning device reports its own rate; the stub says what it is
        // told, so the fixture restores it before the take opens again.
        try engine.setFormat(48_000)
        let restarted = expectation(description: "the requested device restarted")
        recorder.start(deviceUID: "device-selected") { _ in restarted.fulfill() }
        await fulfillment(of: [restarted], timeout: 10)
        try feed(engine, frequency: 1_320)
        let recovered = recorder.stop()
        XCTAssertEqual(recovered.samples, try expectedAudio([1_320]))
        XCTAssertEqual(recovered.deviceUID, "device-selected")
    }

    /// Audio the engine emits while a same-take rebuild starts is kept.
    ///
    /// The replacement converter and its store generation are installed before
    /// the engine starts, so a buffer converted inside the start belongs to the
    /// take instead of being fenced out by the generation that is not live yet.
    @MainActor
    func testASameTakeDefaultRebuildKeepsAudioEmittedWhileItsEngineStarts() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)

        engine.feedAudioOnStart(frequency: 880)
        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { engine.installCount == 2 }

        let recording = recorder.stop()
        let expected = try expectedAudio([440]) + expectedAudio([880], rate: 44_100)
        XCTAssertEqual(
            recording.samples,
            expected,
            "audio emitted while the rebuilt engine started was lost"
        )
    }

    /// A failed default restart keeps the device that supplied the audio.
    ///
    /// The readback of the failed restart is not evidence that its device
    /// recorded anything: the accepted samples came from the earlier input, and
    /// the calibration they teach must be filed under it.
    @MainActor
    func testAFailedDefaultRestartKeepsTheDeviceThatSuppliedTheAudio() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-x")
        let clock = ManualRecoveryClock()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        let ended = expectation(description: "the failed restart ended the take")
        recorder.onFailure = { _ in ended.fulfill() }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)
        let expected = try expectedAudio([440])

        engine.setDevice("device-y")
        engine.stop()
        engine.failStartOnNext()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { clock.scheduledCount == 1 }
        clock.advance(to: 2.0)
        clock.runNext()
        await fulfillment(of: [ended], timeout: 5)

        let recording = recorder.stop()
        XCTAssertEqual(recording.samples, expected)
        XCTAssertEqual(
            recording.deviceUID,
            "device-x",
            "the failed restart's readback became the take's identity"
        )
        XCTAssertEqual(
            AppDelegate.calibrationTarget(for: recording),
            "device-x",
            "the audio the take holds was filed under a device that never supplied it"
        )
    }

    /// A same-format default restart stages the frames the new device emits
    /// while its engine starts.
    ///
    /// The take started on `device-a` but no sample from it survived. The
    /// restart opens `device-b`, which is already delivering audio inside
    /// `start()`. Those frames are `device-b`'s alone: the take is not mixed,
    /// its identity is `device-b`, and `device-b` is what it teaches.
    @MainActor
    func testADefaultRestartOnAnotherDeviceWithNoAcceptedAudioIsNotMixed() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        // One frame converts to nothing and leaves no tail, so the take holds
        // no audio from device-a.
        try feed(engine, frames: 1, frequency: 440)
        XCTAssertEqual(recorder.sampleCount, 0, "the fixture left audio in the take")

        engine.switchDeviceOnStart("device-b")
        engine.feedAudioOnStart(frequency: 880)
        engine.stop()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        let expected = try expectedAudio([880])
        await waitUntil { recorder.sampleCount == expected.count }

        let recording = recorder.stop()
        XCTAssertEqual(
            recording.samples,
            expected,
            "the frames the replacement device emitted while it started were lost or changed"
        )
        XCTAssertFalse(
            recording.spannedDevices,
            "a take whose only audio came from device-b was marked as mixed"
        )
        XCTAssertEqual(recording.deviceUID, "device-b")
        XCTAssertEqual(
            AppDelegate.calibrationTarget(for: recording),
            "device-b",
            "the only device that supplied audio taught nothing"
        )
    }

    /// A default restart that emits audio and then fails takes that audio with
    /// it.
    ///
    /// The device that refused to open contributed no accepted audio, so its
    /// frames must not stay in the take under the identity of the device that
    /// did. The failure enters the rejection episode, and the take keeps the
    /// audio the accepted device supplied.
    @MainActor
    func testAThrowingDefaultRestartDiscardsTheFramesItEmitted() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let clock = ManualRecoveryClock()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        var failures: [String] = []
        recorder.onFailure = { failures.append($0) }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)
        let accepted = try expectedAudio([440])

        engine.feedAudioThenFailOnStart(frequency: 880, device: "device-b")
        engine.stop()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { clock.scheduledCount == 1 }
        XCTAssertEqual(clock.scheduledDelays, [2.0], "the failed restart armed a different deadline")

        let recording = recorder.stop()
        XCTAssertEqual(
            recording.samples,
            accepted,
            "the failed start's frames stayed in the take"
        )
        XCTAssertEqual(
            recording.deviceUID,
            "device-a",
            "the failed start's device became the take's identity"
        )
        XCTAssertFalse(
            recording.spannedDevices,
            "the take was marked mixed by a device that never contributed accepted audio"
        )
        XCTAssertEqual(
            AppDelegate.calibrationTarget(for: recording),
            "device-a",
            "the accepted audio was filed under the device that refused to open"
        )
        XCTAssertTrue(failures.isEmpty, "the failed restart published a failure before its deadline")
    }

    /// Audio from the previous device marks the take as mixed even when only a
    /// flushed tail survived.
    ///
    /// The span check counts the samples the flush actually added to the take.
    /// A buffer whose conversion produced no samples and no tail contributes
    /// nothing and must not mark the take.
    @MainActor
    func testATailOnlyPrefixMarksTheTakeAsMixed() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-x")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        // Ten frames produce no sample in the store, only a converter tail:
        // the trace of device-x is the tail the flush adds after the route.
        try feed(engine, frames: 10, frequency: 440)

        engine.setDevice("device-y")
        engine.stop()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { engine.startCount == 2 }

        let recording = recorder.stop()
        XCTAssertTrue(
            recording.spannedDevices,
            "the take's audio came from device-x but the take was not marked as mixed"
        )
        XCTAssertNil(
            AppDelegate.calibrationTarget(for: recording),
            "a mixed take taught its calibration to one device"
        )
    }

    /// A predecessor that delivered a buffer but contributed no samples does
    /// not mark the take as mixed.
    ///
    /// One frame is below the converter's output: it produces no sample and no
    /// tail. The take that follows on the other device is a single-device take,
    /// and its audio teaches the device that supplied it.
    @MainActor
    func testAPredecessorWithNoSurvivingSamplesDoesNotMarkTheTakeAsMixed() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-x")
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frames: 1, frequency: 440)

        engine.setDevice("device-y")
        engine.stop()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { engine.startCount == 2 && engine.installCount == 2 }
        try feed(engine, frequency: 440)

        let recording = recorder.stop()
        XCTAssertEqual(
            recording.samples,
            try expectedAudio([440]),
            "the empty predecessor contributed audio to the take"
        )
        XCTAssertFalse(
            recording.spannedDevices,
            "a buffer that contributed no samples marked the take as mixed"
        )
        XCTAssertEqual(recording.deviceUID, "device-y")
        XCTAssertEqual(
            AppDelegate.calibrationTarget(for: recording),
            "device-y",
            "the only device that supplied audio was not taught"
        )
    }

    /// A failed restart must not name audio with a device whose only witness is
    /// the readback that failed.
    ///
    /// The accepted take opened with no readable identity. The restart reports
    /// device-y when it throws, and that readback is not evidence that device-y
    /// recorded anything: the take stays unknown and teaches no calibration.
    @MainActor
    func testAFailedRestartWithNoAcceptedIdentityLeavesTheDeviceUnknown() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-x")
        let readback = FirstReadbackUnknown()
        let clock = ManualRecoveryClock()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                openedDeviceUID: { readback.read($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        let ended = expectation(description: "the failed restart ended the take")
        recorder.onFailure = { _ in ended.fulfill() }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)
        let expected = try expectedAudio([440])

        engine.setDevice("device-y")
        engine.stop()
        engine.failStartOnNext()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { clock.scheduledCount == 1 }
        clock.advance(to: 2.0)
        clock.runNext()
        await fulfillment(of: [ended], timeout: 5)

        let recording = recorder.stop()
        XCTAssertEqual(recording.samples, expected)
        XCTAssertNil(
            recording.deviceUID,
            "the failed restart's readback became the identity of audio it did not record"
        )
        XCTAssertNil(
            AppDelegate.calibrationTarget(for: recording),
            "a take with no readable device taught a calibration"
        )
    }

    /// A rebuild whose engine refuses to start is retired, and the take
    /// recovers onto a fresh converter when the old format returns.
    ///
    /// The replacement converter must not be the fenced one that failed: a
    /// later route that returns to the old rate has to build a converter bound
    /// to the store generation that is live now, or its audio is dropped.
    @MainActor
    func testAThrownRebuildRecoversWithAFreshConverterWhenTheFormatReturns() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let clock = ManualRecoveryClock()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)
        let firstSegment = try expectedAudio([440])

        try engine.setFormat(44_100)
        engine.failStartOnNext()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { clock.scheduledCount == 1 }
        XCTAssertTrue(recorder.isRecording, "the failed rebuild ended the take before its deadline")
        XCTAssertEqual(engine.installCount, 2, "the failed rebuild never installed its candidate")

        // The format returns before the deadline. The recovery must build a
        // fresh converter: the 44.1 kHz candidate was fenced when it failed.
        try engine.setFormat(48_000)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { engine.startCount == 2 && engine.installCount == 3 }
        try feed(engine, frequency: 1_320)

        let recording = recorder.stop()
        XCTAssertEqual(
            recording.samples,
            firstSegment + (try expectedAudio([1_320])),
            "the audio after the format returned was dropped by the fenced converter"
        )
        XCTAssertEqual(recording.deviceUID, "device-a")
        XCTAssertFalse(recording.spannedDevices)
    }

    /// Without the format returning, the thrown rebuild ends at the deadline
    /// with the audio that was accepted before it.
    @MainActor
    func testAThrownRebuildEndsAtTheDeadlineWithTheAcceptedAudio() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let clock = ManualRecoveryClock()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        let ended = expectation(description: "the thrown rebuild ended the take")
        recorder.onFailure = { _ in ended.fulfill() }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)
        let expected = try expectedAudio([440])

        try engine.setFormat(44_100)
        engine.failStartOnNext()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { clock.scheduledCount == 1 }
        clock.advance(to: 2.0)
        clock.runNext()
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(clock.totalScheduled, 1, "the thrown rebuild armed more than one deadline")
        let recording = recorder.stop()
        XCTAssertEqual(recording.samples, expected)
        XCTAssertEqual(recording.deviceUID, "device-a")
    }

    /// A changed-rate rebuild retires the old tap, and its callback adds
    /// nothing to the converter that replaced it.
    @MainActor
    func testARetiredTapCallbackAfterAChangedRateRebuildAddsNoSamples() async throws {
        let engine = try StubEngine(startDelay: 0)
        let recorder = self.recorder(engine)
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)
        let expected = try expectedAudio([440])

        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { engine.installCount == 2 }
        XCTAssertEqual(engine.retainedTapCount, 2)

        try engine.invokeRetainedTap(0, frequency: 880)
        XCTAssertEqual(recorder.samples(in: 0..<recorder.sampleCount), expected)
        XCTAssertEqual(recorder.stop().samples, expected)
    }

    /// Counts the engines a recorder asks for.
    private final class OpenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var opens = 0

        func record() {
            lock.lock()
            opens += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return opens
        }
    }

    /// A quit that lands before the audio queue opens the engine skips the open.
    ///
    /// The start block waits for the device cache first; a quit during that wait
    /// owns the take, so no microphone is opened and nothing is published.
    @MainActor
    func testAQuitBeforeTheAudioQueueOpensSkipsTheEngine() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cache = CatalogCache(discovery: {
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            return CatalogCache.Snapshot(devices: [], defaultInputUID: nil)
        })
        let previous = MicrophoneCatalog.cache
        MicrophoneCatalog.cache = cache
        defer { MicrophoneCatalog.cache = previous }

        let engine = try StubEngine(startDelay: 0)
        let opens = OpenCounter()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: {
                    opens.record()
                    return engine
                },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) }
            )
        )
        var report: Recorder.StartReport?
        let answered = expectation(description: "the quit answered the start")
        recorder.start(deviceUID: nil) { value in
            report = value
            answered.fulfill()
        }
        XCTAssertEqual(
            entered.wait(timeout: .now() + 5),
            .success,
            "the start never reached the device cache"
        )
        recorder.shutDown()
        release.signal()
        await fulfillment(of: [answered], timeout: 5)

        XCTAssertEqual(opens.count, 0, "the microphone was opened after the quit")
        XCTAssertEqual(engine.startCount, 0, "the engine was started after the quit")
        XCTAssertEqual(engine.installCount, 0, "a tap was installed after the quit")
        XCTAssertEqual(recorder.sampleCount, 0, "a take was published after the quit")
        XCTAssertEqual(recorder.state, .idle)
        guard case .failure(.cancelled)? = report?.result else {
            return XCTFail("the quit should have answered the start with a cancellation, got \(String(describing: report))")
        }
    }

    /// A permission answer a test can hold open.
    ///
    /// The app asks the system on a task of its own, so the only way to observe
    /// both answers after the quit gate closed is to hold the request itself.
    private final class HeldPermission: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var requested = false

        func access(status: AVAuthorizationStatus) -> AppDelegate.MicrophoneAccess {
            AppDelegate.MicrophoneAccess(
                status: { status },
                request: { [self] in
                    await withCheckedContinuation { continuation in
                        lock.lock()
                        self.continuation = continuation
                        requested = true
                        lock.unlock()
                    }
                }
            )
        }

        var wasRequested: Bool {
            lock.lock()
            defer { lock.unlock() }
            return requested
        }

        /// Answers the held request. The awaiting task is queued on the main
        /// actor by the resume.
        func answer(_ granted: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: granted)
        }
    }

    /// Waits until the main actor has run the work queued before the block.
    ///
    /// A resumed permission answer continues on the main actor. Its job is
    /// enqueued when the continuation is resumed, before this block, so the
    /// block is a completion barrier rather than a timed silence.
    @MainActor
    private func drainMainActor() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// The permission seam and the quit gate, in one AppDelegate.
    ///
    /// The delegate is real: the same `requestMicrophoneAccessIfNeeded` and
    /// `beginQuit` the app runs, with an offscreen HUD and a recorder whose
    /// engine counter proves nothing was opened.
    @MainActor
    private func permissionAfterQuit(granted: Bool) async throws -> (
        delegate: AppDelegate,
        hud: HUD,
        engine: StubEngine,
        opens: OpenCounter,
        recorder: Recorder
    ) {
        let hud = HUD(offscreen: true)
        let engine = try StubEngine(startDelay: 0)
        let opens = OpenCounter()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: {
                    opens.record()
                    return engine
                },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) }
            )
        )
        let delegate = AppDelegate(hud: hud, recorder: recorder)
        let permission = HeldPermission()
        delegate.microphoneAccess = permission.access(status: .notDetermined)
        XCTAssertFalse(
            delegate.requestMicrophoneAccessIfNeeded(),
            "a permission prompt that has not answered must not begin a take"
        )
        await waitUntil { permission.wasRequested }
        delegate.beginQuit()
        permission.answer(granted)
        // The answer resumes the delegate's task on the main actor; the drain
        // runs after the job the resume enqueued.
        await drainMainActor()
        await drainMainActor()
        return (delegate, hud, engine, opens, recorder)
    }

    /// A denied permission that lands after the quit draws no card.
    @MainActor
    func testAPermissionDeniedAfterQuitDrawsNoCardAndStartsNothing() async throws {
        let result = try await permissionAfterQuit(granted: false)
        defer { result.hud.hide() }

        XCTAssertFalse(
            result.hud.isVisible,
            "the denied permission drew a card after the quit"
        )
        XCTAssertEqual(
            result.hud.debugMode,
            .message(text: "", symbol: "info.circle"),
            "the denied permission replaced the empty card during the quit"
        )
        if case .idle = result.delegate.state {} else {
            XCTFail("a denied permission moved the app out of idle during the quit")
        }
        XCTAssertEqual(result.opens.count, 0, "the microphone was opened after a denied answer")
        XCTAssertEqual(result.engine.startCount, 0, "the engine was started after a denied answer")
        XCTAssertEqual(result.engine.installCount, 0, "a tap was installed after a denied answer")
        XCTAssertEqual(result.recorder.state, .idle)
        XCTAssertFalse(result.recorder.isRecording)
    }

    /// A granted permission that lands after the quit does not start a take.
    @MainActor
    func testAPermissionGrantedAfterQuitDoesNotStartATake() async throws {
        let result = try await permissionAfterQuit(granted: true)
        defer { result.hud.hide() }

        XCTAssertFalse(result.hud.isVisible, "a take was drawn after the quit")
        if case .idle = result.delegate.state {} else {
            XCTFail("a granted permission moved the app out of idle during the quit")
        }
        XCTAssertEqual(result.opens.count, 0, "the microphone was opened after the quit")
        XCTAssertEqual(result.engine.startCount, 0, "the engine was started after the quit")
        XCTAssertEqual(result.engine.installCount, 0, "a tap was installed after the quit")
        XCTAssertEqual(result.recorder.state, .idle)
        XCTAssertFalse(result.recorder.isRecording)
    }

    /// Holds one gate boundary, and reports when the held work went on.
    private final class AdmissionHold: @unchecked Sendable {
        private let lock = NSLock()
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let exited = DispatchSemaphore(value: 0)
        private var armed = false

        func arm() {
            lock.lock()
            armed = true
            lock.unlock()
        }

        func hook() {
            lock.lock()
            let shouldPause = armed
            armed = false
            lock.unlock()
            guard shouldPause else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            exited.signal()
        }

        func waitForEntry(timeout: TimeInterval) -> DispatchTimeoutResult {
            entered.wait(timeout: .now() + timeout)
        }

        /// Waits until the held boundary returned, so the code after it runs.
        func waitForExit(timeout: TimeInterval) -> DispatchTimeoutResult {
            exited.wait(timeout: .now() + timeout)
        }

        func releaseHook() {
            release.signal()
        }
    }

    /// A hand-over waits for the callback that was already admitted.
    ///
    /// The gate hook holds one buffer inside the tap while the rebuild's start
    /// is released. The hand-over leaves its own hook and reaches the gate lock
    /// while the callback still holds it, so the ordering is fixed: the
    /// callback is released only after the hand-over is blocked. The promotion
    /// cannot finish, and cannot close that converter, until the callback ends;
    /// the buffer then lands in the take exactly once. A gate that unlocked
    /// before handling the admitted buffer would lose its frames to the
    /// hand-over's generation, so the exact PCM is the check.
    @MainActor
    func testAPromotionWaitsForAnAdmittedCallback() async throws {
        let engine = try StubEngine(startDelay: 0)
        engine.setDevice("device-a")
        let gate = DeliveryGate()
        let admitted = AdmissionHold()
        let promoting = AdmissionHold()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { gate.deliver($0) },
                afterAdmission: { admitted.hook() },
                beforePromotion: { promoting.hook() }
            )
        )
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { _ in answered.fulfill() }
        await gate.waitForHeld(1)
        gate.release()
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)

        let held = engine.blockNextStart()
        admitted.arm()
        promoting.arm()
        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { engine.retainedTapCount == 2 }

        DispatchQueue.global().async {
            try? engine.invokeRetainedTap(1, frequency: 880)
        }
        XCTAssertEqual(
            admitted.waitForEntry(timeout: 5),
            .success,
            "the admitted callback never reached the gate hook"
        )
        let firstSegment = try expectedAudio([440])
        let expected = firstSegment + (try expectedAudio([880], rate: 44_100))
        // Release the rebuilt engine's start: the hand-over enters promotion,
        // which is the moment before it takes the gate lock. The admitted
        // callback is still inside the gate hook, so it holds that lock.
        held.release.signal()
        XCTAssertEqual(
            promoting.waitForEntry(timeout: 5),
            .success,
            "the hand-over never entered promotion"
        )
        // Let the hand-over leave its hook: its next instruction is the gate
        // lock, which the admitted callback holds. It has to wait there until
        // the callback ends, so the take has not received its frames and no
        // route answer has been delivered.
        promoting.releaseHook()
        XCTAssertEqual(
            promoting.waitForExit(timeout: 5),
            .success,
            "the hand-over did not reach the gate lock"
        )
        XCTAssertEqual(
            recorder.sampleCount,
            firstSegment.count,
            "the hand-over published the admitted frames before the callback finished"
        )
        XCTAssertEqual(
            gate.heldCount,
            0,
            "the hand-over completed while the admitted callback held the gate"
        )

        // Only now release the callback. The hand-over is already blocked on
        // the gate lock, so a gate that unlocked before handling the buffer
        // would let the hand-over fence the frames out.
        admitted.releaseHook()
        await waitUntil { recorder.sampleCount == expected.count }

        let recording = recorder.stop()
        XCTAssertEqual(
            recording.samples,
            expected,
            "the admitted buffer was lost or counted more than once by the promotion"
        )
    }

    /// A quit during the open closes the engine on the audio queue, and the
    /// start answers with a cancellation.
    @MainActor
    func testAQuitDuringTheOpenClosesTheEngineOnTheAudioQueue() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let held = engine.blockNextStart()
        let recorder = self.recorder(engine)
        var report: Recorder.StartReport?
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { value in
            report = value
            answered.fulfill()
        }
        XCTAssertEqual(
            held.entered.wait(timeout: .now() + 5),
            .success,
            "the open never reached the engine"
        )
        XCTAssertEqual(recorder.state, .starting)

        recorder.shutDown()
        let cutoff = try XCTUnwrap(
            recorder.takePendingStopCutoff(),
            "the quit handed over no start cutoff"
        )
        held.release.signal()
        let joined = expectation(description: "the start cleanup finished")
        Task { await cutoff.value; joined.fulfill() }
        await fulfillment(of: [answered, joined], timeout: 5)

        XCTAssertFalse(engine.isRunning, "the abandoned open left the engine running")
        XCTAssertEqual(engine.tapCount, 0, "the abandoned open left its tap installed")
        XCTAssertEqual(engine.stopCount, 1, "the abandoned open stopped the engine more or less than once")
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(recorder.sampleCount, 0)
        XCTAssertTrue(recorder.stop().samples.isEmpty)
        guard case .failure(.cancelled)? = report?.result else {
            return XCTFail("the quit did not cancel the start, got \(String(describing: report))")
        }
    }

    /// A stop while the open is held registers the cleanup a later quit joins.
    ///
    /// The press takes the start back before the engine opens, so there is no
    /// card and no audio. The engine the open is still holding is not finished
    /// with: a quit that follows must be able to wait for its cleanup instead of
    /// ending the process with the input running.
    @MainActor
    func testAStopWhileTheOpenIsHeldHandsTheCleanupToTheQuit() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let held = engine.blockNextStart()
        let recorder = self.recorder(engine)
        var report: Recorder.StartReport?
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { value in
            report = value
            answered.fulfill()
        }
        XCTAssertEqual(
            held.entered.wait(timeout: .now() + 5),
            .success,
            "the open never reached the engine"
        )
        XCTAssertEqual(recorder.state, .starting)

        let stopped = recorder.stop()
        XCTAssertTrue(stopped.samples.isEmpty, "a take that never opened handed over audio")
        XCTAssertEqual(recorder.state, .idle)

        // The stop had no cutoff of its own, but the open it abandoned still
        // owes a cleanup. The quit has to be able to join it.
        recorder.shutDown()
        let cutoff = try XCTUnwrap(
            recorder.takePendingStopCutoff(),
            "the stop left the held open's cleanup with no one to join it"
        )
        held.release.signal()
        let joined = expectation(description: "the start cleanup finished")
        Task { await cutoff.value; joined.fulfill() }
        await fulfillment(of: [answered, joined], timeout: 5)

        XCTAssertFalse(engine.isRunning, "the abandoned open left the engine running")
        XCTAssertEqual(engine.tapCount, 0, "the abandoned open left its tap installed")
        XCTAssertEqual(engine.stopCount, 1, "the abandoned open stopped the engine more or less than once")
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(recorder.sampleCount, 0)
        XCTAssertTrue(recorder.stop().samples.isEmpty)
        guard case .failure(.cancelled)? = report?.result else {
            return XCTFail("the stop did not cancel the start, got \(String(describing: report))")
        }
    }

    /// A quit while a start's success answer is held closes the engine itself
    /// instead of waiting for the answer to be released.
    @MainActor
    func testAQuitWhileAStartSuccessIsHeldStopsTheEngineWithoutTheHeldAnswer() async throws {
        let engine = try StubEngine(startDelay: 0)
        let gate = DeliveryGate()
        let recorder = self.recorder(engine, deliver: { gate.deliver($0) })
        var report: Recorder.StartReport?
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: nil) { value in
            report = value
            answered.fulfill()
        }
        await gate.waitForHeld(1)
        XCTAssertEqual(recorder.state, .starting)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.tapCount, 1)

        recorder.shutDown()
        let cutoff = try XCTUnwrap(
            recorder.takePendingStopCutoff(),
            "the quit handed over no start cutoff"
        )
        let joined = expectation(description: "the start cleanup finished")
        Task { await cutoff.value; joined.fulfill() }
        await fulfillment(of: [joined], timeout: 5)

        XCTAssertFalse(engine.isRunning, "the held success answer owned the engine after the quit")
        XCTAssertEqual(engine.tapCount, 0, "the held success answer left its tap installed")
        XCTAssertEqual(engine.stopCount, 1, "the quit stopped the engine more than once")
        XCTAssertEqual(recorder.sampleCount, 0)

        gate.release()
        await fulfillment(of: [answered], timeout: 5)
        guard case .failure(.cancelled)? = report?.result else {
            return XCTFail("the released answer was not cancelled, got \(String(describing: report))")
        }
        XCTAssertEqual(engine.stopCount, 1, "the released held answer stopped the engine a second time")
        XCTAssertTrue(recorder.stop().samples.isEmpty)
        XCTAssertEqual(recorder.state, .idle)
    }

    /// A recovery that was in flight when the quit began changes nothing on the
    /// card and does not refresh the menu after the quit.
    @MainActor
    func testAFailedRecoveryInFlightChangesNothingAfterBeginQuit() async throws {
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showMessage(text: "working", action: nil)
        let engine = try StubEngine(startDelay: 0)
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) }
            )
        )
        let delegate = AppDelegate(hud: hud, recorder: recorder)
        let visible = hud.isVisible
        let mode = hud.debugMode
        let history = hud.debugModeHistory
        let refreshes = delegate.menuRefreshCount
        XCTAssertTrue(visible, "the test cannot tell a card that changed from one that did not")

        let hold = HeldLiveTask()
        let liveTask = hold.makeTask()
        let recording = Recorder.Recording(
            samples: [Int16](repeating: 120, count: 1_600),
            duration: 0.1,
            peakDBFS: -20,
            spannedDevices: false,
            deviceUID: "device-a"
        )
        delegate.recoverForTesting(
            recording,
            ledger: TranscriptLedger(commitSeconds: 12),
            failure: "the microphone stopped",
            liveTask: liveTask
        )

        delegate.beginQuit()
        hold.release()
        await delegate.waitForRecoveryForTesting()

        XCTAssertTrue(hud.isVisible, "the quit hid the card")
        XCTAssertEqual(hud.debugMode, mode, "the quit replaced the card")
        XCTAssertEqual(hud.debugModeHistory, history, "the quit changed the card's mode")
        XCTAssertEqual(delegate.menuRefreshCount, refreshes, "the quit refreshed the menu")
    }

    /// A live task a test can hold across a quit and then release.
    private final class HeldLiveTask: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func makeTask() -> Task<Void, Never> {
            Task {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if released {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        self.continuation = continuation
                        lock.unlock()
                    }
                }
            }
        }

        func release() {
            lock.lock()
            released = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    /// What a route change did to the take's input.
    private enum RouteOutcomeCell: String, CaseIterable {
        /// The replacement input is verified and the audio it emits while it
        /// starts belongs to the take.
        case rebuilt = "successful-rebuild"
        /// The replacement input is rejected after emitting audio.
        case rejectedWithAudio = "rejection-with-audio"
        /// The replacement input is rejected without emitting audio.
        case rejectedWithoutAudio = "rejection-without-audio"
    }

    /// How the take was ended while the route answer was in flight.
    private enum TakeEnding: String, CaseIterable {
        case stop
        case quit
    }

    /// When the route answer reached the main actor relative to the ending.
    private enum DeliveryOrder: String, CaseIterable {
        case answerFirst = "answer-first"
        case endingFirst = "ending-first"
    }

    /// One cell of the merged Stop/quit matrix.
    ///
    /// The route change is reconciled to completion on the audio queue and its
    /// answer is held before the main actor, which is the only instant at which
    /// the two delivery orders differ. In the answer-first order the seam is
    /// opened after the answer and the test waits for the rejection's deadline
    /// to reach the clock, so the answer has been applied before the ending is
    /// issued instead of racing the arm; the ending-first order keeps the
    /// answer held across the ending. The applied answer and the stop cutoff
    /// are the completion barriers; no engine counter decides when a step is
    /// done, and the drain count is only compared before and after it. The HUD
    /// is wired to the recorder's two publication channels, so a failure or a
    /// device change that reached the app would draw a card here.
    @MainActor
    private func assertRouteEndingCell(
        _ outcome: RouteOutcomeCell,
        _ ending: TakeEnding,
        _ order: DeliveryOrder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let cell = "\(outcome.rawValue)/\(ending.rawValue)/\(order.rawValue)"
        let previousCache = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previousCache }
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        let engine = try StubEngine(startDelay: 0)
        let gate = DeliveryGate()
        let clock = ManualRecoveryClock()
        let drain = AdmissionHold()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { gate.deliver($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) },
                beforeDrain: { drain.hook() }
            )
        )
        var report: Recorder.StartReport?
        recorder.start(deviceUID: "device-selected") { report = $0 }
        await gate.waitForHeld(1)
        gate.release()
        await waitUntil { report != nil }
        guard case .success? = report?.result else {
            return XCTFail(
                "\(cell): the take did not start: \(String(describing: report))",
                file: file,
                line: line
            )
        }
        try feed(engine, frequency: 440)

        var deviceChanges: [String?] = []
        var failures: [String] = []
        recorder.onDeviceChange = { uid in
            deviceChanges.append(uid)
            hud.showMessage(text: "device changed", action: nil)
        }
        recorder.onFailure = { message in
            failures.append(message)
            hud.showMessage(text: message, action: nil)
        }

        gate.hold()
        switch outcome {
        case .rebuilt:
            engine.feedAudioOnStart(frequency: 880)
            try engine.setFormat(44_100)
        case .rejectedWithAudio:
            engine.holdDevice("device-other")
            engine.feedAudioOnStart(frequency: 880)
            try engine.setFormat(44_100)
        case .rejectedWithoutAudio:
            engine.holdDevice("device-other")
            try engine.setFormat(44_100)
        }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        // The held answer is the reconciliation-complete barrier: the audio
        // queue has finished the rebuild and, for a rejection, already
        // discarded the candidate's frames.
        await gate.waitForHeld(1)
        XCTAssertEqual(
            gate.heldCount,
            1,
            "\(cell): the route answer did not reach the delivery gate",
            file: file,
            line: line
        )

        let expectedAudio: [Int16]
        switch outcome {
        case .rebuilt:
            expectedAudio = try self.expectedAudio([440]) + self.expectedAudio([880], rate: 44_100)
        case .rejectedWithAudio, .rejectedWithoutAudio:
            expectedAudio = try self.expectedAudio([440])
        }

        let stopsBefore = engine.stopCount
        drain.arm()
        var claim: Recorder.StopClaim?
        let end: () -> Recorder.StopClaim? = {
            switch ending {
            case .stop:
                return recorder.claimStop()
            case .quit:
                return recorder.shutDown()
            }
        }
        switch order {
        case .answerFirst:
            gate.releaseHeld(at: 0)
            if outcome != .rebuilt {
                // The rejected answer arms its deadline on the audio queue and
                // schedules it through the same delivery seam. Opening the seam
                // and waiting for the clock is what makes this order mean the
                // answer was applied: the ending below then cancels a deadline
                // that exists, instead of racing the arm and cancelling one the
                // queue has not yet recorded.
                gate.release()
                await waitUntil(
                    { clock.totalScheduled == 1 },
                    message: "\(cell): the rejection answer armed no deadline before the ending"
                )
            }
            claim = end()
        case .endingFirst:
            claim = end()
            gate.releaseHeld(at: 0)
        }

        XCTAssertEqual(
            drain.waitForEntry(timeout: 5),
            .success,
            "\(cell): the ending never reached its drain",
            file: file,
            line: line
        )
        // The drain is paused before it touches the session, so the take's
        // published samples are read at a known point instead of racing the
        // engine release. The last converter still holds its filter tail until
        // the drain flushes it, so the published prefix is compared against the
        // accepted audio's prefix; the drain's answer below is compared whole.
        let accepted = recorder.sampleCount
        let acceptedAudio = recorder.samples(in: 0..<accepted)
        XCTAssertGreaterThan(accepted, 0, "\(cell): the take held no audio before the ending", file: file, line: line)
        XCTAssertLessThanOrEqual(
            accepted,
            expectedAudio.count,
            "\(cell): the take held more audio than the accepted input",
            file: file,
            line: line
        )
        XCTAssertEqual(
            acceptedAudio,
            Array(expectedAudio.prefix(accepted)),
            "\(cell): the published prefix is not exactly the accepted audio",
            file: file,
            line: line
        )
        if outcome == .rebuilt {
            XCTAssertEqual(engine.installCount, 2, "\(cell): the route did not rebuild the tap", file: file, line: line)
        }
        XCTAssertEqual(
            recorder.state,
            .stopping,
            "\(cell): the ending did not claim the take on the caller's turn",
            file: file,
            line: line
        )
        if let claim {
            XCTAssertEqual(
                claim.publishedSamples,
                accepted,
                "\(cell): the claim published a different prefix than the take held",
                file: file,
                line: line
            )
        }
        drain.releaseHook()
        let cutoff = try XCTUnwrap(
            recorder.takePendingStopCutoff(),
            "\(cell): the ending handed over no cutoff",
            file: file,
            line: line
        )
        // Open the delivery for the drain's answer, then join the one cutoff.
        gate.release()
        await cutoff.value
        XCTAssertNil(
            recorder.takePendingStopCutoff(),
            "\(cell): a second cutoff was handed over",
            file: file,
            line: line
        )
        XCTAssertEqual(
            engine.stopCount,
            stopsBefore + 1,
            "\(cell): the take was drained more or less than once",
            file: file,
            line: line
        )
        await waitUntil { recorder.state == .idle }
        XCTAssertEqual(recorder.state, .idle, "\(cell): the take did not reach idle", file: file, line: line)
        XCTAssertTrue(
            failures.isEmpty,
            "\(cell): the ended take published a failure: \(failures)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            deviceChanges.isEmpty,
            "\(cell): the ended take published a device change: \(deviceChanges)",
            file: file,
            line: line
        )
        XCTAssertFalse(
            hud.isVisible,
            "\(cell): a message was drawn for the ended take",
            file: file,
            line: line
        )

        // A rejection episode has one deadline. The ending-first order takes
        // the take back before the answer lands, which ends the episode, so
        // only the answer-first order arms one. A rebuilt take has none.
        let expectedDeadlines: Int
        switch outcome {
        case .rebuilt:
            expectedDeadlines = 0
        case .rejectedWithAudio, .rejectedWithoutAudio:
            expectedDeadlines = order == .answerFirst ? 1 : 0
        }
        XCTAssertEqual(
            clock.totalScheduled,
            expectedDeadlines,
            "\(cell): the rejected take armed \(clock.totalScheduled) deadlines, expected \(expectedDeadlines)",
            file: file,
            line: line
        )
        // The deadline that outlived the ending must do nothing: its token
        // belongs to the take that already ended.
        let stopsAfterDrain = engine.stopCount
        clock.advance(to: 2.0)
        while clock.scheduledCount > 0 {
            clock.runNext()
        }
        recorder.drainAudioQueueForTesting()
        XCTAssertEqual(
            engine.stopCount,
            stopsAfterDrain,
            "\(cell): an old recovery deadline stopped the engine",
            file: file,
            line: line
        )
        XCTAssertTrue(
            failures.isEmpty,
            "\(cell): an old recovery deadline ended the take again: \(failures)",
            file: file,
            line: line
        )

        switch ending {
        case .stop:
            let resolved = await claim?.result
            guard case .drained(let recording)? = resolved else {
                return XCTFail(
                    "\(cell): the claim delivered no take: \(String(describing: resolved))",
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(
                Array(recording.samples.prefix(accepted)),
                acceptedAudio,
                "\(cell): the drain changed the accepted prefix",
                file: file,
                line: line
            )
            XCTAssertEqual(
                recording.samples,
                expectedAudio,
                "\(cell): the final PCM is not exactly the accepted audio, or a rejected device's frames changed it",
                file: file,
                line: line
            )
            XCTAssertEqual(
                recording.deviceUID,
                "device-selected",
                "\(cell): the take was labelled by a device that did not supply its audio",
                file: file,
                line: line
            )
            XCTAssertFalse(
                recording.spannedDevices,
                "\(cell): a single-device take was marked mixed",
                file: file,
                line: line
            )
            let target = AppDelegate.calibrationTarget(for: recording)
            XCTAssertEqual(
                target,
                "device-selected",
                "\(cell): the accepted device was not the calibration target",
                file: file,
                line: line
            )
            XCTAssertNotEqual(
                target,
                "device-other",
                "\(cell): a rejected device was taught the take's calibration",
                file: file,
                line: line
            )
        case .quit:
            let resolved = await claim?.result
            guard case .abandoned? = resolved else {
                return XCTFail(
                    "\(cell): the quit did not abandon its claim: \(String(describing: resolved))",
                    file: file,
                    line: line
                )
            }
            XCTAssertTrue(
                recorder.stop().samples.isEmpty,
                "\(cell): the quit delivered a take",
                file: file,
                line: line
            )
            XCTAssertTrue(
                failures.isEmpty,
                "\(cell): a recovery ended a take the quit had claimed",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    func testASuccessfulRebuildThenStopEndsOnceInBothDeliveryOrders() async throws {
        for order in DeliveryOrder.allCases {
            try await assertRouteEndingCell(.rebuilt, .stop, order)
        }
    }

    @MainActor
    func testASuccessfulRebuildThenQuitPublishesNothingInBothDeliveryOrders() async throws {
        for order in DeliveryOrder.allCases {
            try await assertRouteEndingCell(.rebuilt, .quit, order)
        }
    }

    @MainActor
    func testARejectionWithAudioThenStopKeepsOnlyAcceptedAudioInBothDeliveryOrders() async throws {
        for order in DeliveryOrder.allCases {
            try await assertRouteEndingCell(.rejectedWithAudio, .stop, order)
        }
    }

    @MainActor
    func testARejectionWithAudioThenQuitPublishesNothingInBothDeliveryOrders() async throws {
        for order in DeliveryOrder.allCases {
            try await assertRouteEndingCell(.rejectedWithAudio, .quit, order)
        }
    }

    @MainActor
    func testARejectionWithoutAudioThenStopKeepsOnlyAcceptedAudioInBothDeliveryOrders() async throws {
        for order in DeliveryOrder.allCases {
            try await assertRouteEndingCell(.rejectedWithoutAudio, .stop, order)
        }
    }

    @MainActor
    func testARejectionWithoutAudioThenQuitPublishesNothingInBothDeliveryOrders() async throws {
        for order in DeliveryOrder.allCases {
            try await assertRouteEndingCell(.rejectedWithoutAudio, .quit, order)
        }
    }

    /// The first readback is unreadable; later ones report the engine's device.
    private final class FirstReadbackUnknown: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        func read(_ engine: CaptureEngine) -> String? {
            lock.lock()
            calls += 1
            let first = calls == 1
            lock.unlock()
            return first ? nil : engine.currentDeviceUID()
        }
    }

    /// Repeated rejections arm one deadline, and the take ends once at 2.0 s.
    @MainActor
    func testRepeatedRejectionsArmOneDeadlineAndEndOnceAtTwoSeconds() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let clock = ManualRecoveryClock()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        var failures: [String] = []
        let ended = expectation(description: "the take ended once")
        recorder.onFailure = { message in
            failures.append(message)
            ended.fulfill()
        }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)
        let expected = try expectedAudio([440])

        func reject() async {
            NotificationCenter.default.post(
                name: .AVAudioEngineConfigurationChange,
                object: engine.configurationIdentity
            )
            recorder.drainAudioQueueForTesting()
            await drainMainActor()
        }

        engine.holdDevice("device-other")
        try engine.setFormat(44_100)
        await reject()
        await waitUntil { clock.scheduledCount == 1 }
        XCTAssertEqual(clock.scheduledDelays, [2.0], "the first rejection armed a different deadline")
        let syncPasses = recorder.synchronousCapturePasses

        for second in [1.0, 2.0, 3.0, 4.0] {
            clock.advance(to: second)
            await reject()
            XCTAssertEqual(
                clock.totalScheduled,
                1,
                "a rejection at \(second) s reset the deadline"
            )
            if second == 2.0 {
                clock.runNext()
                await fulfillment(of: [ended], timeout: 5)
                XCTAssertFalse(recorder.isRecording, "the take did not end at its first deadline")
            } else if second < 2.0 {
                XCTAssertTrue(recorder.isRecording, "the take ended before \(second) s")
            } else {
                XCTAssertFalse(recorder.isRecording, "the ended take came back at \(second) s")
            }
        }
        // Rejections after the end add nothing.
        clock.advance(to: 5.0)
        await reject()
        XCTAssertEqual(clock.totalScheduled, 1, "a rejection after the end armed a new deadline")
        XCTAssertEqual(failures.count, 1, "the take ended more than once")
        XCTAssertEqual(
            recorder.synchronousCapturePasses,
            syncPasses,
            "the deadline ended the take through the synchronous capture path"
        )
        let recording = recorder.stop()
        XCTAssertEqual(recording.samples, expected)
        XCTAssertEqual(recording.deviceUID, "device-selected")
    }

    /// A recovery that wins before the deadline leaves the take running.
    @MainActor
    func testARecoveryBeforeTheDeadlineLeavesTheTakeRunning() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let clock = ManualRecoveryClock()
        let gate = DeliveryGate()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { gate.deliver($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        var failures: [String] = []
        recorder.onFailure = { failures.append($0) }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await gate.waitForHeld(1)
        gate.release()
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)

        gate.hold()
        engine.holdDevice("device-other")
        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await gate.waitForHeld(1)
        gate.release()
        await waitUntil { clock.scheduledCount == 1 }
        XCTAssertTrue(recorder.isRecording)

        // At 1.9 s the requested device is back. Its reconciliation runs on the
        // audio queue before the deadline check queued at 2.0 s.
        clock.advance(to: 1.9)
        engine.resumeSelection()
        engine.setDevice("device-selected")
        try engine.setFormat(48_000)
        gate.hold()
        recorder.checkForFormatChange()
        await gate.waitForHeld(1)
        recorder.drainAudioQueueForTesting()

        clock.advance(to: 2.0)
        clock.runNext()
        recorder.drainAudioQueueForTesting()
        XCTAssertTrue(recorder.isRecording, "the deadline ended a take the recovery had saved")

        gate.release()
        await drainMainActor()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(failures.isEmpty, "a recovered take published a failure: \(failures)")
        try feed(engine, frequency: 1_320)
        let recording = recorder.stop()
        XCTAssertEqual(recording.samples, try expectedAudio([440, 1_320]))
        XCTAssertEqual(recording.deviceUID, "device-selected")
        XCTAssertEqual(recorder.sampleCount, 0)
    }

    /// A rejection that follows a recovery is a new episode, and the old
    /// deadline cannot end it.
    ///
    /// Both the recovery's answer and the second rejection's answer are held on
    /// their way to the main actor, so the recovery has already happened on the
    /// audio queue when the second rejection lands. The first episode's deadline
    /// is still live on main. When it fires it must find that the take is in
    /// another episode and leave it alone; the second episode gets its own full
    /// two seconds from its own rejection.
    @MainActor
    func testANewRejectionEpisodeGetsItsOwnDeadline() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let clock = ManualRecoveryClock()
        let gate = DeliveryGate()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { gate.deliver($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        var failures: [String] = []
        recorder.onFailure = { failures.append($0) }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await gate.waitForHeld(1)
        gate.release()
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)
        let accepted = try expectedAudio([440])

        // Episode 1: rejected at 0 s, its deadline is armed at 2.0 s.
        engine.holdDevice("device-other")
        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { clock.scheduledCount == 1 }
        XCTAssertEqual(clock.scheduledDelays, [2.0])
        XCTAssertTrue(recorder.isRecording)

        // At 1.9 s the requested device comes back. Its answer is held.
        clock.advance(to: 1.9)
        engine.resumeSelection()
        engine.setDevice("device-selected")
        try engine.setFormat(48_000)
        gate.hold()
        recorder.checkForFormatChange()
        await gate.waitForHeld(1)

        // At 1.95 s the device is taken away again. That answer is held too,
        // so main has not settled either answer when the second rejection is
        // already the live episode on the audio queue.
        clock.advance(to: 1.95)
        engine.holdDevice("device-other")
        try engine.setFormat(44_100)
        recorder.checkForFormatChange()
        await gate.waitForHeld(2)

        // Episode 1's deadline passes while episode 2 is already the live
        // episode on the audio queue and both answers are still pending on
        // main. The deadline belongs to an episode that is over, so it must
        // not end the take.
        clock.advance(to: 2.0)
        clock.runNext()
        recorder.drainAudioQueueForTesting()
        await drainMainActor()
        XCTAssertTrue(recorder.isRecording, "the old episode's deadline ended the new one")
        XCTAssertTrue(failures.isEmpty, "the old episode's deadline published a failure: \(failures)")

        // Main hears both answers now. The recovery ends episode 1, and the
        // second rejection asks for episode 2's deadline. It is measured from
        // the rejection at 1.95 s, not from this delivery at 2.0 s, so the
        // take has 1.95 s left instead of a fresh two.
        gate.release()
        await waitUntil { clock.totalScheduled == 2 }
        XCTAssertTrue(recorder.isRecording, "the second rejection ended the take outright")
        XCTAssertEqual(
            clock.scheduledCount,
            1,
            "the new episode did not own exactly one deadline"
        )
        XCTAssertEqual(
            clock.scheduledDelays.first ?? 0,
            1.95,
            accuracy: 0.0001,
            "the new episode's deadline was not measured from its own rejection"
        )

        // Episode 2 gets its own 2.0 s from 1.95 s, and it ends the take once.
        clock.advance(to: 3.95)
        clock.runNext()
        recorder.drainAudioQueueForTesting()
        await drainMainActor()
        XCTAssertFalse(recorder.isRecording, "the second episode never reached its deadline")
        XCTAssertEqual(failures.count, 1, "the take ended more or less than once")
        let recording = recorder.stop()
        XCTAssertEqual(
            recording.samples,
            accepted,
            "the audio accepted before the first rejection was not preserved exactly"
        )
        XCTAssertEqual(recording.deviceUID, "device-selected")
    }

    /// A deadline message that arrives after the next take started does nothing.
    @MainActor
    func testAStaleDeadlineMessageDoesNotEndTheNextTake() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let clock = ManualRecoveryClock()
        let gate = DeliveryGate()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { gate.deliver($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        var failures: [String] = []
        recorder.onFailure = { failures.append($0) }
        let answered = expectation(description: "the first start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await gate.waitForHeld(1)
        gate.release()
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)

        gate.hold()
        engine.holdDevice("device-other")
        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await gate.waitForHeld(1)
        gate.release()
        await waitUntil { clock.scheduledCount == 1 }

        // The deadline cuts the take off on the audio queue and its message is
        // held before the main actor.
        gate.hold()
        clock.advance(to: 2.0)
        clock.runNext()
        await gate.waitForHeld(1)

        // A stop claims the already stopped take. Its drain returns the
        // preserved audio and its answer is held behind the stale message.
        let claim = try XCTUnwrap(recorder.claimStop(), "the stopped take could not be claimed")
        await gate.waitForHeld(2)
        gate.releaseHeld(at: 1)
        guard case .drained = await claim.result else {
            return XCTFail("the claim did not return the preserved audio")
        }
        await waitUntil { recorder.state == .idle }

        // The next take starts while the old message is still held.
        engine.resumeSelection()
        engine.setDevice("device-selected")
        try engine.setFormat(48_000)
        var report: Recorder.StartReport?
        let nextAnswered = expectation(description: "the next start was answered")
        recorder.start(deviceUID: "device-selected") { value in
            report = value
            nextAnswered.fulfill()
        }
        await gate.waitForHeld(2)
        gate.releaseHeld(at: 1)
        await fulfillment(of: [nextAnswered], timeout: 5)
        guard case .success? = report?.result else {
            return XCTFail("the next take did not start: \(String(describing: report))")
        }
        let count = recorder.sampleCount

        // The stale message arrives last. It belongs to the take that ended.
        gate.releaseHeld(at: 0)
        XCTAssertEqual(recorder.state, .recording, "the stale deadline ended the next take")
        XCTAssertEqual(recorder.sampleCount, count, "the stale deadline changed the next take")
        XCTAssertTrue(
            failures.isEmpty,
            "the stale deadline published a failure for the next take: \(failures)"
        )

        try feed(engine, frequency: 1_320)
        let recording = recorder.stop()
        XCTAssertEqual(recording.samples, try expectedAudio([1_320]))
        XCTAssertEqual(recording.deviceUID, "device-selected")
    }

    /// A clock and scheduler the recovery deadline is measured with.
    private final class ManualRecoveryClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0
        private var pending: [(delay: TimeInterval, work: @Sendable () -> Void)] = []
        private var total = 0

        func nowValue() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return seconds
        }

        /// Every deadline ever armed, including one a later teardown cancelled.
        ///
        /// A cancelled token leaves its scheduled block behind, so the pending
        /// count cannot tell an unarmed take from a cancelled deadline. This
        /// counter is what bounds the number of recoveries a route can start.
        var totalScheduled: Int {
            lock.lock()
            defer { lock.unlock() }
            return total
        }

        func advance(to value: TimeInterval) {
            lock.lock()
            seconds = value
            lock.unlock()
        }

        func schedule(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
            lock.lock()
            pending.append((delay, work))
            total += 1
            lock.unlock()
        }

        var scheduledCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return pending.count
        }

        var scheduledDelays: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return pending.map(\.delay)
        }

        /// Fires the oldest scheduled check, if any.
        func runNext() {
            lock.lock()
            let work = pending.isEmpty ? nil : pending.removeFirst().work
            lock.unlock()
            work?()
        }
    }

    /// A rejected route ends the take at the deadline, and not before it.
    @MainActor
    func testARejectedRouteEndsVisiblyAtTheRecoveryDeadline() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let clock = ManualRecoveryClock()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        var failure: String?
        let ended = expectation(description: "the rejected route ended the take")
        recorder.onFailure = { message in
            failure = message
            ended.fulfill()
        }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)
        let expected = try expectedAudio([440])

        engine.holdDevice("device-other")
        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { clock.scheduledCount == 1 }
        XCTAssertEqual(clock.scheduledDelays, [2.0])
        XCTAssertTrue(recorder.isRecording, "the take ended before the recovery deadline")

        clock.advance(to: 1.999)
        clock.runNext()
        await waitUntil { clock.scheduledCount == 1 }
        XCTAssertTrue(recorder.isRecording, "the take ended before 2.0 s")
        XCTAssertNil(failure)

        let syncPasses = recorder.synchronousCapturePasses
        clock.advance(to: 2.0)
        clock.runNext()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(
            recorder.synchronousCapturePasses,
            syncPasses,
            "the deadline ended the take through the synchronous capture path"
        )
        let recording = recorder.stop()
        XCTAssertEqual(recording.samples, expected)
        XCTAssertEqual(recording.deviceUID, "device-selected")
    }

    /// A route that comes back inside the window cancels the deadline.
    @MainActor
    func testARecoveredRejectionCancelsTheRecoveryDeadline() async throws {
        let previous = installSelectedDeviceCache()
        defer { MicrophoneCatalog.cache = previous }
        let engine = try StubEngine(startDelay: 0)
        let clock = ManualRecoveryClock()
        let gate = DeliveryGate()
        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engine },
                isAuthorized: { true },
                deliver: { gate.deliver($0) },
                now: { clock.nowValue() },
                scheduleRecovery: { delay, work in clock.schedule(delay, work) }
            )
        )
        var failure: String?
        recorder.onFailure = { failure = $0 }
        let answered = expectation(description: "the start was answered")
        recorder.start(deviceUID: "device-selected") { _ in answered.fulfill() }
        await gate.waitForHeld(1)
        gate.release()
        await fulfillment(of: [answered], timeout: 5)
        try feed(engine, frequency: 440)

        gate.hold()
        engine.holdDevice("device-other")
        try engine.setFormat(44_100)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine.configurationIdentity
        )
        await waitUntil { gate.heldCount == 1 }
        XCTAssertEqual(gate.heldCount, 1, "the rejection answer did not reach the delivery gate")
        gate.release()
        await waitUntil { clock.scheduledCount == 1 }
        XCTAssertTrue(recorder.isRecording)

        clock.advance(to: 1.0)
        engine.resumeSelection()
        engine.setDevice("device-selected")
        try engine.setFormat(48_000)
        gate.hold()
        recorder.checkForFormatChange()
        await waitUntil { gate.heldCount == 1 }
        XCTAssertEqual(gate.heldCount, 1, "the recovery answer did not reach the delivery gate")
        gate.release()
        XCTAssertTrue(recorder.isRecording, "the recovered route ended the take")

        clock.advance(to: 2.0)
        clock.runNext()
        try feed(engine, frequency: 1_320)
        let recording = recorder.stop()
        XCTAssertNil(failure, "a recovered route ended the take at the old deadline")
        XCTAssertEqual(recording.samples, try expectedAudio([440, 1_320]))
        XCTAssertEqual(recording.deviceUID, "device-selected")
    }

    @MainActor
    func testCancelWhileRecordingDoesNotBlockMainThreadAndAllowsImmediateRestart() async throws {
        let engineA = try StubEngine(startDelay: 0)
        let engineB = try StubEngine(startDelay: 0)
        let engines = EngineQueue([engineA, engineB])
        let drainEntered = DispatchSemaphore(value: 0)
        let releaseDrain = DispatchSemaphore(value: 0)
        final class DrainGate: @unchecked Sendable {
            private let lock = NSLock()
            private var hold = true
            func takeHold() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                let current = hold
                hold = false
                return current
            }
        }
        let gate = DrainGate()

        let recorder = Recorder(
            environment: Recorder.Environment(
                makeEngine: { engines.next() },
                isAuthorized: { true },
                deliver: { MainThreadTick.run($0) },
                beforeDrain: {
                    guard gate.takeHold() else { return }
                    drainEntered.signal()
                    _ = releaseDrain.wait(timeout: .now() + 5)
                }
            )
        )

        let firstStarted = expectation(description: "first start answered")
        var firstReport: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report in
            firstReport = report
            firstStarted.fulfill()
        }
        await fulfillment(of: [firstStarted], timeout: 5)
        guard case .success = firstReport?.result else {
            return XCTFail("expected first start to succeed, got \(String(describing: firstReport))")
        }

        let cancelStartedAt = CACurrentMediaTime()
        recorder.cancel()
        let cancelDuration = CACurrentMediaTime() - cancelStartedAt
        XCTAssertLessThan(cancelDuration, 0.1, "recorder.cancel() blocked the main actor (\(cancelDuration)s)")
        XCTAssertEqual(recorder.state, .stopping)

        XCTAssertEqual(
            drainEntered.wait(timeout: .now() + 2),
            .success,
            "first take drain did not enter beforeDrain"
        )

        let secondStarted = expectation(description: "second start answered")
        var secondReport: Recorder.StartReport?
        recorder.start(deviceUID: nil) { report in
            secondReport = report
            secondStarted.fulfill()
        }
        XCTAssertEqual(recorder.state, .starting)

        releaseDrain.signal()
        await fulfillment(of: [secondStarted], timeout: 5)
        guard case .success = secondReport?.result else {
            return XCTFail("restart from abandoned stop failed: \(String(describing: secondReport))")
        }
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(engineA.stopCount, 1)
        XCTAssertEqual(engineB.stopCount, 0)
        recorder.cancel()
        await waitUntil { recorder.state == .idle }
    }

    private func toneSamples() throws -> [Int16] {
        (0..<16_000).map { index in
            Int16(2_000 * sin(2 * Double.pi * 440 * Double(index) / 16_000))
        }
    }

    private func string(_ value: LogValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    private func double(_ value: LogValue?) -> Double? {
        if case .double(let number)? = value { return number }
        return nil
    }

    @MainActor
    private func waitUntil(
        _ predicate: () -> Bool,
        timeout: TimeInterval = 5,
        message: String = "the condition never became true"
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), message)
    }

    /// The app's source, for the invariants that are wiring rather than logic.
    private func appDelegateSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Dot/AppDelegate.swift"),
            encoding: .utf8
        )
    }

    /// The text from a declaration up to the next member of the type.
    private func functionBody(_ signature: String, in text: String) -> String? {
        guard let start = text.range(of: signature) else { return nil }
        let tail = text[start.upperBound...]
        let boundaries = ["\n    func ", "\n    private func ", "\n    nonisolated ", "\n    /// "]
            .compactMap { tail.range(of: $0)?.lowerBound }
        guard let end = boundaries.min() else { return String(tail) }
        return String(tail[..<end])
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The text from `start` up to the next declaration at the same level.
    private func body(of start: String, in text: String) -> String? {
        guard let startRange = text.range(of: start) else { return nil }
        let tail = text[startRange.upperBound...]
        let end = tail.range(of: "\n    /// Watches for the two things that change the answer.")
            ?? tail.range(of: "\n    private func startObserving()")
        guard let end else { return String(tail) }
        return String(tail[..<end.lowerBound])
    }
}
