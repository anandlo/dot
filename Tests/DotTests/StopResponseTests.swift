import AppKit
import XCTest
@testable import Dot
import DotCore

/// Production stop orchestration with an offscreen HUD and held dependencies.
@MainActor
final class StopResponseTests: XCTestCase {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            guard !isOpen else {
                lock.unlock()
                return
            }
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for waiter in pending { waiter.resume() }
        }
    }

    private enum Source: Equatable {
        case complete
        case live
        case tail
        case fallback
    }

    private struct Event: Equatable {
        let name: String
        let mode: String
    }

    @MainActor
    private final class Host {
        weak var hud: HUD?
        var events: [Event] = []
        var state = "recording"
        var menuRecording = true
        var ledgerCleared = false
        var finishEmptyCalls = 0
        var calibrationCalls = 0
        var providerCalls = 0
        var deletions: [String] = []
        var deliveries: [(text: String, source: Source)] = []
        var book: [String: MicrophoneCalibration] = [:]
        var providerError: Error?
        var terminated = false
        var ownsCard = true
        var live: Task<Void, Never>?
        let calibrationGate = Gate()
        let providerGate = Gate()

        func record(_ name: String) {
            let mode = hud.map { String(describing: $0.debugMode) } ?? "missing"
            events.append(Event(name: name, mode: mode))
        }

        func event(_ name: String) -> Event? {
            events.first { $0.name == name }
        }

        func makeHandoff(
            hud: HUD,
            recording: Recorder.Recording,
            ledger: TranscriptLedger,
            deviceUID: String?,
            book: [String: MicrophoneCalibration],
            providerText: String = "tail words"
        ) -> StopHandoff {
            self.hud = hud
            return StopHandoff(
                hud: hud,
                recording: recording,
                ledger: ledger,
                liveTask: live,
                deviceUID: deviceUID,
                capturedBook: book,
                currentBook: { [weak self] in self?.book ?? [:] },
                isTerminating: { [weak self] in self?.terminated ?? false },
                ownsCard: { [weak self] in self?.ownsCard ?? false },
                enterWorking: { [weak self] in
                    self?.record("enterWorking")
                    self?.state = "working"
                },
                markMenuNotRecording: { [weak self] in
                    self?.record("markMenuNotRecording")
                    self?.menuRecording = false
                },
                clearLedger: { [weak self] in
                    self?.record("clearLedger")
                    self?.ledgerCleared = true
                },
                finishEmpty: { [weak self] in
                    self?.record("finishEmpty")
                    self?.finishEmptyCalls += 1
                },
                applyCalibration: { [weak self] nextBook, _ in
                    self?.record("applyCalibration")
                    self?.book = nextBook
                },
                observe: { [weak self] _, _, _, _, at in
                    guard let self else { return nil }
                    record("observe")
                    calibrationCalls += 1
                    await calibrationGate.wait()
                    return StopCalibrationLearning(
                        observation: MicrophoneObservation(noiseFloorDBFS: -50, peakDBFS: -10),
                        book: MicrophoneCalibrationBook.folding(
                            book,
                            observation: MicrophoneObservation(noiseFloorDBFS: -50, peakDBFS: -10),
                            device: deviceUID,
                            now: at
                        ),
                        at: at
                    )
                },
                transcribe: { [weak self] _, _ in
                    guard let self else { return "" }
                    record("transcribe")
                    providerCalls += 1
                    await providerGate.wait()
                    if let providerError { throw providerError }
                    return providerText
                },
                deliver: { [weak self] text, source in
                    guard let self else { return }
                    record("deliver")
                    let recorded: Source
                    switch source {
                    case .complete: recorded = .complete
                    case .live: recorded = .live
                    case .tail: recorded = .tail
                    case .fallback: recorded = .fallback
                    }
                    deliveries.append((text: text, source: recorded))
                },
                abandon: { [weak self] in
                    guard let self else { return }
                    record("abandon")
                    deletions.append("abandon")
                },
                fail: { [weak self] _ in
                    guard let self else { return }
                    record("fail")
                    deletions.append("fail")
                }
            )
        }

        func releaseAll() {
            calibrationGate.open()
            providerGate.open()
            live?.cancel()
        }
    }

    private func isWorking(_ hud: HUD) -> Bool {
        if case .working = hud.debugMode { return true }
        return false
    }

    private func isRecording(_ hud: HUD) -> Bool {
        if case .recording = hud.debugMode { return true }
        return false
    }

    private func isMessage(_ hud: HUD) -> Bool {
        if case .message = hud.debugMode { return true }
        return false
    }

    private func historyEnteredWorking(_ hud: HUD) -> Bool {
        hud.debugModeHistory.contains { mode in
            if case .working = mode { return true }
            return false
        }
    }

    private func silence(seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * Double(WAVSpec.sampleRate)))
    }

    private func speech(seconds: Double) -> [Int16] {
        let count = Int(seconds * Double(WAVSpec.sampleRate))
        return (0..<count).map { index in
            index.isMultiple(of: 2) ? 16_000 : -16_000
        }
    }

    private func waitForEntry(
        _ description: String,
        task: Task<Void, Never>,
        host: Host,
        until entered: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !entered(), clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(1))
        }
        guard entered() else {
            XCTFail("\(description) was not entered", file: file, line: line)
            task.cancel()
            host.releaseAll()
            await awaitFinish(task)
            return false
        }
        return true
    }

    private func awaitFinish(_ task: Task<Void, Never>) async {
        var done = false
        let expectation = expectation(description: "stop task finished")
        Task { @MainActor in
            await task.value
            done = true
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertTrue(done)
    }

    func testRealStopHandoffLeavesRecordingBeforeHeldCalibrationAndDeliversCandidate() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")
        XCTAssertTrue(isRecording(hud))

        let host = Host()
        defer { host.releaseAll() }
        host.live = Task { @MainActor in await host.calibrationGate.wait() }
        let samples = silence(seconds: 1)
        var ledger = TranscriptLedger(commitSeconds: 1)
        ledger.recordProvisional(range: 0..<(samples.count / 2), text: "live words")
        let recording = Recorder.Recording(samples: samples, duration: 1, peakDBFS: -80)
        let handoff = host.makeHandoff(
            hud: hud,
            recording: recording,
            ledger: ledger,
            deviceUID: "device",
            book: [:]
        )

        let task = StopResponse.perform(handoff)
        guard await waitForEntry("Calibration", task: task, host: host, until: { host.calibrationCalls > 0 }) else { return }

        XCTAssertTrue(isWorking(hud), "the real card stayed in recording while calibration was held")
        XCTAssertEqual(host.state, "working")
        XCTAssertFalse(host.menuRecording)
        XCTAssertTrue(host.live?.isCancelled ?? false)
        XCTAssertTrue(host.deliveries.isEmpty)
        XCTAssertEqual(host.providerCalls, 0)
        guard let menuEvent = host.event("markMenuNotRecording"),
              let observeIndex = host.events.firstIndex(where: { $0.name == "observe" }),
              let menuIndex = host.events.firstIndex(where: { $0.name == "markMenuNotRecording" })
        else {
            XCTFail("menu and observe events were not recorded: \(host.events)")
            return
        }
        XCTAssertTrue(menuEvent.mode.contains("working"))
        XCTAssertLessThan(menuIndex, observeIndex)

        host.calibrationGate.open()
        await awaitFinish(task)
        XCTAssertEqual(host.deliveries.count, 1)
        XCTAssertEqual(host.deliveries[0].text, "live words")
        XCTAssertEqual(host.deliveries[0].source, .live)
        XCTAssertTrue(host.ledgerCleared)
        XCTAssertEqual(host.providerCalls, 0)
    }

    func testEmptyStopHandoffDoesNotFlashWorking() {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")
        XCTAssertTrue(isRecording(hud))

        let host = Host()
        let handoff = host.makeHandoff(
            hud: hud,
            recording: Recorder.Recording(samples: [], duration: 0, peakDBFS: -120),
            ledger: TranscriptLedger(commitSeconds: 1),
            deviceUID: "device",
            book: [:]
        )

        _ = StopResponse.perform(handoff)
        XCTAssertTrue(isMessage(hud))
        XCTAssertFalse(isWorking(hud))
        XCTAssertFalse(isRecording(hud))
        XCTAssertFalse(historyEnteredWorking(hud))
        XCTAssertEqual(host.state, "working")
        XCTAssertEqual(host.finishEmptyCalls, 1)
        guard let finishEvent = host.event("finishEmpty") else {
            XCTFail("finishEmpty was not recorded")
            return
        }
        XCTAssertTrue(finishEvent.mode.contains("message"))
        XCTAssertEqual(host.calibrationCalls, 0)
        XCTAssertTrue(host.deliveries.isEmpty)
    }

    func testNilDeviceSkipsCalibrationAndSpokenTailUsesHeldProvider() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")
        XCTAssertTrue(isRecording(hud))
        let host = Host()
        defer { host.releaseAll() }
        let samples = speech(seconds: 1)
        let handoff = host.makeHandoff(
            hud: hud,
            recording: Recorder.Recording(samples: samples, duration: 1, peakDBFS: -6),
            ledger: TranscriptLedger(commitSeconds: 1),
            deviceUID: nil,
            book: [:]
        )

        let task = StopResponse.perform(handoff)
        XCTAssertTrue(isWorking(hud), "showTranscribing must run before perform returns")
        XCTAssertFalse(isRecording(hud))
        guard await waitForEntry("Final transcription", task: task, host: host, until: { host.providerCalls > 0 }) else { return }

        XCTAssertEqual(host.calibrationCalls, 0)
        XCTAssertEqual(host.providerCalls, 1)
        XCTAssertTrue(isWorking(hud))
        XCTAssertFalse(isRecording(hud))
        XCTAssertTrue(host.deliveries.isEmpty)

        host.providerGate.open()
        await awaitFinish(task)
        XCTAssertEqual(host.deliveries.count, 1)
        XCTAssertEqual(host.deliveries[0].text, "tail words")
        XCTAssertEqual(host.deliveries[0].source, .tail)
    }

    func testCancelledObservationCannotPublish() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        let host = Host()
        defer { host.releaseAll() }
        let samples = speech(seconds: 1)
        let handoff = host.makeHandoff(
            hud: hud,
            recording: Recorder.Recording(samples: samples, duration: 1, peakDBFS: -6),
            ledger: TranscriptLedger(commitSeconds: 1),
            deviceUID: "device",
            book: [:]
        )

        let task = StopResponse.perform(handoff)
        guard await waitForEntry("Calibration", task: task, host: host, until: { host.calibrationCalls > 0 }) else { return }
        task.cancel()
        host.calibrationGate.open()
        await awaitFinish(task)

        XCTAssertEqual(host.deletions, ["abandon"])
        XCTAssertTrue(host.deliveries.isEmpty)
        XCTAssertEqual(host.providerCalls, 0)
    }

    func testCompleteCoverageUsesTheCapturedLedgerSnapshot() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")
        XCTAssertTrue(isRecording(hud))
        let host = Host()
        defer { host.releaseAll() }
        let samples = silence(seconds: 1)
        var ledger = TranscriptLedger(commitSeconds: 1)
        ledger.commit(range: 0..<samples.count, text: "captured words")
        let handoff = host.makeHandoff(
            hud: hud,
            recording: Recorder.Recording(samples: samples, duration: 1, peakDBFS: -80),
            ledger: ledger,
            deviceUID: nil,
            book: [:]
        )
        ledger.commit(range: 0..<samples.count, text: "later words")

        let task = StopResponse.perform(handoff)
        XCTAssertTrue(isWorking(hud))
        XCTAssertFalse(isRecording(hud))
        await awaitFinish(task)

        XCTAssertEqual(host.calibrationCalls, 0)
        XCTAssertEqual(host.deliveries.count, 1)
        XCTAssertEqual(host.deliveries[0].text, "captured words")
        XCTAssertEqual(host.deliveries[0].source, .complete)
        XCTAssertFalse(host.deliveries.contains { $0.text == "later words" })
        XCTAssertEqual(host.providerCalls, 0)
    }

    func testSuccessfulTailAfterOwnershipLossPublishesNothing() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        let host = Host()
        defer { host.releaseAll() }
        let handoff = host.makeHandoff(
            hud: hud,
            recording: Recorder.Recording(
                samples: speech(seconds: 1),
                duration: 1,
                peakDBFS: -6
            ),
            ledger: TranscriptLedger(commitSeconds: 1),
            deviceUID: nil,
            book: [:]
        )

        let task = StopResponse.perform(handoff)
        guard await waitForEntry("Final transcription", task: task, host: host, until: { host.providerCalls > 0 }) else { return }
        host.ownsCard = false
        hud.showMessage(text: "new owner", action: nil)
        host.providerGate.open()
        await awaitFinish(task)

        XCTAssertTrue(host.deliveries.isEmpty)
        XCTAssertTrue(host.deletions.isEmpty)
        XCTAssertTrue(isMessage(hud))
    }

    func testOrdinaryProviderErrorAfterOwnershipLossPublishesNothing() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        let host = Host()
        defer { host.releaseAll() }
        host.providerError = NSError(domain: "StopResponseTests", code: 7)
        let handoff = host.makeHandoff(
            hud: hud,
            recording: Recorder.Recording(
                samples: speech(seconds: 1),
                duration: 1,
                peakDBFS: -6
            ),
            ledger: TranscriptLedger(commitSeconds: 1),
            deviceUID: nil,
            book: [:]
        )

        let task = StopResponse.perform(handoff)
        guard await waitForEntry("Final transcription", task: task, host: host, until: { host.providerCalls > 0 }) else { return }
        host.ownsCard = false
        hud.showMessage(text: "new owner", action: nil)
        host.providerGate.open()
        await awaitFinish(task)

        XCTAssertTrue(host.deliveries.isEmpty)
        XCTAssertTrue(host.deletions.isEmpty)
        XCTAssertTrue(isMessage(hud))
    }

    func testProviderCancellationAfterOwnershipLossDoesNotAbandonNewOwner() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        let host = Host()
        defer { host.releaseAll() }
        host.providerError = CancellationError()
        let handoff = host.makeHandoff(
            hud: hud,
            recording: Recorder.Recording(
                samples: speech(seconds: 1),
                duration: 1,
                peakDBFS: -6
            ),
            ledger: TranscriptLedger(commitSeconds: 1),
            deviceUID: nil,
            book: [:]
        )

        let task = StopResponse.perform(handoff)
        guard await waitForEntry("Final transcription", task: task, host: host, until: { host.providerCalls > 0 }) else { return }
        host.ownsCard = false
        hud.showMessage(text: "new owner", action: nil)
        host.providerGate.open()
        await awaitFinish(task)

        XCTAssertTrue(host.deliveries.isEmpty)
        XCTAssertTrue(host.deletions.isEmpty)
        XCTAssertTrue(isMessage(hud))
    }

    func testOwnerCancellationAfterProviderStillAbandons() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        let host = Host()
        defer { host.releaseAll() }
        let handoff = host.makeHandoff(
            hud: hud,
            recording: Recorder.Recording(
                samples: speech(seconds: 1),
                duration: 1,
                peakDBFS: -6
            ),
            ledger: TranscriptLedger(commitSeconds: 1),
            deviceUID: nil,
            book: [:]
        )

        let task = StopResponse.perform(handoff)
        guard await waitForEntry("Final transcription", task: task, host: host, until: { host.providerCalls > 0 }) else { return }
        task.cancel()
        host.providerGate.open()
        await awaitFinish(task)

        XCTAssertEqual(host.deletions, ["abandon"])
        XCTAssertTrue(host.deliveries.isEmpty)
    }

    func testOwnerTerminationAfterProviderStillAbandons() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        let host = Host()
        defer { host.releaseAll() }
        let handoff = host.makeHandoff(
            hud: hud,
            recording: Recorder.Recording(
                samples: speech(seconds: 1),
                duration: 1,
                peakDBFS: -6
            ),
            ledger: TranscriptLedger(commitSeconds: 1),
            deviceUID: nil,
            book: [:]
        )

        let task = StopResponse.perform(handoff)
        guard await waitForEntry("Final transcription", task: task, host: host, until: { host.providerCalls > 0 }) else { return }
        host.terminated = true
        host.providerGate.open()
        await awaitFinish(task)

        XCTAssertEqual(host.deletions, ["abandon"])
        XCTAssertTrue(host.deliveries.isEmpty)
    }

    func testOrdinaryProviderErrorStillUsesFallbackForOwner() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        let host = Host()
        defer { host.releaseAll() }
        host.providerError = NSError(domain: "StopResponseTests", code: 8)
        let samples = speech(seconds: 1)
        var ledger = TranscriptLedger(commitSeconds: 1)
        ledger.recordProvisional(range: 0..<(samples.count / 2), text: "kept words")
        let handoff = host.makeHandoff(
            hud: hud,
            recording: Recorder.Recording(samples: samples, duration: 1, peakDBFS: -6),
            ledger: ledger,
            deviceUID: nil,
            book: [:]
        )

        let task = StopResponse.perform(handoff)
        guard await waitForEntry("Final transcription", task: task, host: host, until: { host.providerCalls > 0 }) else { return }
        host.providerGate.open()
        await awaitFinish(task)

        XCTAssertEqual(host.deliveries.count, 1)
        XCTAssertEqual(host.deliveries[0].text, "kept words")
        XCTAssertEqual(host.deliveries[0].source, .fallback)
        XCTAssertTrue(host.deletions.isEmpty)
    }

    func testConcurrentCalibrationLearningMatchesDirectComposition() async {
        let samples = speech(seconds: 1)
        let book: [String: MicrophoneCalibration] = [:]
        let now = Date()
        let learned = stopCalibrationLearning(
            samples: samples,
            peakDBFS: -3,
            deviceUID: "device",
            book: book,
            at: now
        )
        let observation = MicrophoneCalibrationBook.observation(
            samples: samples,
            peakDBFS: -3
        )
        let expectedBook = MicrophoneCalibrationBook.folding(
            book,
            observation: observation!,
            device: "device",
            now: now
        )
        XCTAssertEqual(learned?.observation, observation)
        XCTAssertEqual(learned?.book, expectedBook)
        XCTAssertEqual(learned?.at, now)

        let noObservation = stopCalibrationLearning(
            samples: [],
            peakDBFS: -3,
            deviceUID: "device",
            book: book,
            at: now
        )
        XCTAssertNil(noObservation)
    }

    func testResetDuringObservationIsNotUndone() {
        let now = Date()
        let entry = MicrophoneCalibration(
            noiseFloorDBFS: -60,
            peakDBFS: -12,
            observedSamples: 2,
            updatedAt: now
        )
        let learning = StopCalibrationLearning(
            observation: MicrophoneObservation(noiseFloorDBFS: -50, peakDBFS: -10),
            book: ["device": entry],
            at: now
        )

        XCTAssertNil(StopResponse.calibrationBookAfterObservation(
            capturedBook: ["device": entry],
            currentBook: [:],
            deviceUID: "device",
            learning: learning
        ))
        let otherEntry = MicrophoneCalibration(
            noiseFloorDBFS: -70,
            peakDBFS: -20,
            observedSamples: 4,
            updatedAt: now
        )
        let currentBook = ["device": entry, "other": otherEntry]
        let expectedBook = MicrophoneCalibrationBook.folding(
            currentBook,
            observation: learning.observation,
            device: "device",
            now: learning.at
        )
        let merged = StopResponse.calibrationBookAfterObservation(
            capturedBook: ["device": entry],
            currentBook: currentBook,
            deviceUID: "device",
            learning: learning
        )
        XCTAssertEqual(merged?["device"], expectedBook["device"])
        XCTAssertEqual(merged?["other"], currentBook["other"])
    }
}
