import AVFoundation
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
        private let lock = NSLock()
        private let startDelay: TimeInterval
        private var format: AVAudioFormat
        private var deviceUID: String?
        private var tapBlock: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
        private var deviceOnStart: String?
        private var feedOnStart = false
        private var formatOnStart: AVAudioFormat?
        private var tapFormat: AVAudioFormat?
        private var starts = 0
        private var stops = 0
        private var installs = 0
        private var running = false

        init(startDelay: TimeInterval) throws {
            self.startDelay = startDelay
            self.format = try Self.makeFormat(48_000)
        }

        static func makeFormat(_ rate: Double) throws -> AVAudioFormat {
            try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: rate,
                    channels: 1,
                    interleaved: false
                )
            )
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

        func currentDeviceUID() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return deviceUID
        }

        /// Switches the device the engine reports, inside the next start.
        func switchDeviceOnStart(_ uid: String) {
            lock.lock()
            deviceOnStart = uid
            lock.unlock()
        }

        /// Pushes one block of audio through the tap inside the next start.
        func feedAudioOnStart() {
            lock.lock()
            feedOnStart = true
            lock.unlock()
        }

        /// Changes the format now, the way a route change does.
        func setFormat(_ rate: Double) throws {
            let next = try Self.makeFormat(rate)
            lock.lock()
            format = next
            lock.unlock()
        }

        func inputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat {
            lock.lock()
            defer { lock.unlock() }
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
            // The sleep runs on the audio control queue, which is the point: it
            // is the stand-in for a device that has to be opened.
            Thread.sleep(forTimeInterval: startDelay)
            lock.lock()
            if let formatOnStart { format = formatOnStart }
            starts += 1
            running = true
            let tap = tapBlock
            let feed = feedOnStart
            let device = deviceOnStart
            deviceOnStart = nil
            lock.unlock()
            // A device that is already delivering audio while the engine opens,
            // or that changes under it.
            if feed, let tap, let format = try? StubEngine.makeFormat(48_000) {
                Self.pushBlock(tap, format: format)
            }
            if let device {
                setDevice(device)
            }
        }

        /// Pushes one block of audio through an installed tap.
        static func pushBlock(
            _ tap: (AVAudioPCMBuffer, AVAudioTime) -> Void,
            format: AVAudioFormat,
            frames: Int = 4_800
        ) {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ), let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            for frame in 0..<frames {
                channel[frame] = 0.3 * Float(sin(2 * Double.pi * 440 * Double(frame) / format.sampleRate))
            }
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
        }

        func stop() {
            lock.lock()
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
        recorder.start(deviceUID: nil) { value in
            report = value
            answered.fulfill()
        }
        XCTAssertEqual(recorder.state, .starting)
        recorder.cancel()
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
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
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
        // A route change arrives while the take is starting.
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
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
        engine.setDevice("device-c")
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

        guard case .success? = report?.result else {
            return XCTFail("the take should have recorded on the default input, got \(String(describing: report))")
        }
        XCTAssertEqual(report?.openedDeviceUID, "device-c")
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

    /// Pushes one block of audio through the tap the recorder installed.
    private func feed(_ engine: StubEngine, frames: Int = 4_800) throws {
        let tap = try XCTUnwrap(engine.installedTap, "the recorder installed no tap")
        let format = try StubEngine.makeFormat(48_000)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        )
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<frames {
            channel[frame] = 0.3 * Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000))
        }
        tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
    }

    /// A take that crossed devices while its route change was still on its way
    /// to the app is a spanning take.
    ///
    /// The device change is decided where the audio is, on the audio queue, so a
    /// stop that lands before the app has heard about the change still knows the
    /// take ran on both devices.
    @MainActor
    func testAStopBeforeTheRouteChangeIsDeliveredStillSpans() async throws {
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
            return XCTFail("the take should have started, got \(String(describing: report))")
        }
        try feed(engine)
        XCTAssertGreaterThan(recorder.sampleCount, 0, "the tap produced no samples")

        // The route stops the engine and it starts again on B, same format. The
        // outcome is held at the gate, so the app has not heard about it yet.
        gate.hold()
        engine.stop()
        engine.setDevice("device-b")
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        await gate.waitForHeld(1)

        // The stop lands in that gap, before the app learned about the change.
        let recording = recorder.stop()
        gate.release()

        XCTAssertTrue(
            recording.spannedDevices,
            "the take recorded on two devices and was not marked as spanning"
        )
        XCTAssertNil(
            AppDelegate.calibrationTarget(for: recording),
            "a take that crossed devices would teach one of them its mixed floor"
        )
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
        engine.switchDeviceOnStart("device-b")
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
    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "the condition never became true")
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
