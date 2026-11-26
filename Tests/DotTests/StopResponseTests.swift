import AppKit
import AVFoundation
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
        var drainedTakes: [Recorder.Recording] = []
        var book: [String: MicrophoneCalibration] = [:]
        var providerError: Error?
        var terminated = false
        var ownsCard = true
        var live: Task<Void, Never>?
        /// The take an already-drained handoff performs, set by `makeHandoff`.
        private var recording = Recorder.Recording(samples: [], duration: 0, peakDBFS: -.infinity)
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
            recording: Recorder.Recording? = nil,
            ledger: TranscriptLedger,
            deviceUID: String? = nil,
            book: [String: MicrophoneCalibration],
            providerText: String = "tail words"
        ) -> StopHandoff {
            self.hud = hud
            if var take = recording {
                take.deviceUID = deviceUID
                self.recording = take
            }
            return StopHandoff(
                hud: hud,
                ledger: ledger,
                liveTask: live,
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
                drained: { [weak self] take in
                    self?.record("drained")
                    self?.drainedTakes.append(take)
                },
                deliver: { [weak self] text, source, _ in
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

        /// Runs the production orchestration for a take that is already drained.
        func perform(_ handoff: StopHandoff) -> Task<Void, Never> {
            StopResponse.perform(handoff, recording: recording)
        }

        /// Runs the production orchestration for a take that is still draining.
        func perform(_ handoff: StopHandoff, claim: Recorder.StopClaim) -> Task<Void, Never> {
            StopResponse.perform(handoff, claim: claim)
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

        let task = host.perform(handoff)
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

    func testStopDoesNotLearnFromATakeThatSpannedMicrophones() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        let host = Host()
        defer { host.releaseAll() }
        host.calibrationGate.open()
        host.providerGate.open()
        let samples = speech(seconds: 1)
        let recording = Recorder.Recording(
            samples: samples, duration: 1, peakDBFS: -10, spannedDevices: true, deviceUID: "device"
        )
        let handoff = host.makeHandoff(
            hud: hud, recording: recording, ledger: TranscriptLedger(commitSeconds: 1),
            deviceUID: "device", book: [:]
        )

        await awaitFinish(host.perform(handoff))
        XCTAssertEqual(host.calibrationCalls, 0)
        XCTAssertTrue(host.book.isEmpty)
        XCTAssertEqual(host.deliveries.count, 1, "Mixed-device audio must still be transcribed.")
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

        _ = host.perform(handoff)
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

        let task = host.perform(handoff)
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

        let task = host.perform(handoff)
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

        let task = host.perform(handoff)
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

        let task = host.perform(handoff)
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

        let task = host.perform(handoff)
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

        let task = host.perform(handoff)
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

        let task = host.perform(handoff)
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

        let task = host.perform(handoff)
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

        let task = host.perform(handoff)
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

    // MARK: - A stop claimed before the take is drained

    /// The card leaves recording on the turn Stop is accepted, and once.
    ///
    /// The samples the take had already published are enough to know it is not
    /// empty, so the transcribing state is shown before the audio queue answers;
    /// the drain that follows cannot add a second transcribing frame.
    func testAClaimedStopShowsTranscribingOnceBeforeTheTakeIsDrained() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")
        XCTAssertTrue(isRecording(hud))

        let host = Host()
        defer { host.releaseAll() }
        host.calibrationGate.open()
        host.providerGate.open()
        host.live = Task { @MainActor in await host.calibrationGate.wait() }
        let samples = silence(seconds: 1)
        var ledger = TranscriptLedger(commitSeconds: 1)
        ledger.recordProvisional(range: 0..<(samples.count / 2), text: "live words")
        let handoff = host.makeHandoff(hud: hud, ledger: ledger, book: [:])
        let claim = Recorder.StopClaim(publishedSamples: samples.count)

        let task = host.perform(handoff, claim: claim)

        XCTAssertTrue(isWorking(hud), "the claimed stop did not leave recording")
        XCTAssertFalse(isRecording(hud))
        XCTAssertEqual(workingFrames(hud), 1, "the claimed stop showed transcribing more than once")
        XCTAssertEqual(host.state, "working")
        XCTAssertFalse(host.menuRecording)
        XCTAssertTrue(host.live?.isCancelled ?? false)
        XCTAssertTrue(host.drainedTakes.isEmpty, "the take was drained before the card left recording")
        XCTAssertTrue(host.deliveries.isEmpty)

        claim.resolve(.drained(Recorder.Recording(
            samples: samples, duration: 1, peakDBFS: -80, deviceUID: "device"
        )))
        await awaitFinish(task)

        XCTAssertEqual(workingFrames(hud), 1, "the drain showed transcribing a second time")
        XCTAssertEqual(host.drainedTakes.count, 1)
        XCTAssertEqual(host.deliveries.count, 1)
        XCTAssertEqual(host.deliveries[0].text, "live words")
        XCTAssertEqual(host.deliveries[0].source, .live)
        XCTAssertEqual(host.providerCalls, 0)
    }

    /// A take with nothing published waits for the drain, and an empty take is
    /// never shown as transcribing.
    func testAClaimedStopWithNothingPublishedNeverFlashesTranscribingWhenEmpty() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")
        XCTAssertTrue(isRecording(hud))

        let host = Host()
        defer { host.releaseAll() }
        let handoff = host.makeHandoff(hud: hud, ledger: TranscriptLedger(commitSeconds: 1), book: [:])
        let claim = Recorder.StopClaim(publishedSamples: 0)

        let task = host.perform(handoff, claim: claim)

        XCTAssertFalse(isRecording(hud), "the card kept showing a recording it could no longer read")
        XCTAssertTrue(isMessage(hud), "a take with nothing published left the card on the recording")
        XCTAssertEqual(messageText(hud), "Finishing recording…")
        XCTAssertFalse(isWorking(hud), "a take with nothing published was shown as transcribing")
        XCTAssertFalse(historyEnteredWorking(hud))
        XCTAssertEqual(host.state, "working")
        XCTAssertFalse(host.menuRecording, "the claimed stop left the menu saying it was recording")
        XCTAssertEqual(host.finishEmptyCalls, 0, "the take was declared empty before it was drained")
        XCTAssertEqual(host.deliveries.count, 0)
        XCTAssertTrue(host.drainedTakes.isEmpty)

        claim.resolve(.drained(Recorder.Recording(samples: [], duration: 0, peakDBFS: -120)))
        await awaitFinish(task)

        XCTAssertEqual(messageText(hud), "Nothing was recorded.")
        XCTAssertFalse(historyEnteredWorking(hud), "a genuinely empty take flashed transcribing")
        XCTAssertEqual(host.finishEmptyCalls, 1)
        XCTAssertTrue(host.deliveries.isEmpty)
        XCTAssertEqual(host.calibrationCalls, 0)
    }

    /// A take whose audio was still in the converter is not declared empty: the
    /// drain's tail is what it transcribes, and the card is shown once.
    func testAClaimedStopWithNothingPublishedShowsTranscribingOnceWhenTheTailArrives() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")
        XCTAssertTrue(isRecording(hud))

        let host = Host()
        defer { host.releaseAll() }
        host.providerGate.open()
        let handoff = host.makeHandoff(hud: hud, ledger: TranscriptLedger(commitSeconds: 1), book: [:])
        let claim = Recorder.StopClaim(publishedSamples: 0)

        let task = host.perform(handoff, claim: claim)
        XCTAssertEqual(messageText(hud), "Finishing recording…")
        XCTAssertFalse(isRecording(hud))
        XCTAssertFalse(historyEnteredWorking(hud))
        XCTAssertTrue(hud.debugModel.isVisible, "the card was taken down while the take was still finishing")

        claim.resolve(.drained(Recorder.Recording(
            samples: speech(seconds: 1), duration: 1, peakDBFS: -6
        )))
        await awaitFinish(task)

        XCTAssertEqual(workingFrames(hud), 1, "the late tail was shown as transcribing more than once")
        XCTAssertTrue(isWorking(hud), "the late tail never reached the transcribing card")
        XCTAssertTrue(hud.debugModel.isVisible, "the card was closed and reopened around the drain")
        XCTAssertEqual(host.finishEmptyCalls, 0, "the late tail was declared empty")
        XCTAssertEqual(host.deliveries.count, 1)
        XCTAssertEqual(host.deliveries[0].source, .tail)
    }

    /// A delivery that was taken back is not a transcript and touches nothing.
    func testAClaimedStopWhoseDeliveryIsTakenBackShowsNothingMore() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")

        let host = Host()
        defer { host.releaseAll() }
        let samples = speech(seconds: 1)
        let handoff = host.makeHandoff(hud: hud, ledger: TranscriptLedger(commitSeconds: 1), book: [:])
        let claim = Recorder.StopClaim(publishedSamples: samples.count)
        let task = host.perform(handoff, claim: claim)
        XCTAssertEqual(workingFrames(hud), 1)

        claim.resolve(.abandoned)
        await awaitFinish(task)

        XCTAssertEqual(workingFrames(hud), 1)
        XCTAssertTrue(host.drainedTakes.isEmpty)
        XCTAssertTrue(host.deliveries.isEmpty)
        XCTAssertTrue(host.deletions.isEmpty)
        XCTAssertEqual(host.finishEmptyCalls, 0)
    }

    /// A quit takes the stop back: the take is drained but nothing is pasted,
    /// shown or finished, and the card is not left for someone else to close.
    func testAQuitDuringAClaimedStopDeliversNothing() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")

        let host = Host()
        defer { host.releaseAll() }
        host.calibrationGate.open()
        host.providerGate.open()
        let samples = speech(seconds: 1)
        let handoff = host.makeHandoff(hud: hud, ledger: TranscriptLedger(commitSeconds: 1), book: [:])
        let claim = Recorder.StopClaim(publishedSamples: samples.count)
        let task = host.perform(handoff, claim: claim)
        XCTAssertEqual(workingFrames(hud), 1)

        host.terminated = true
        claim.resolve(.drained(Recorder.Recording(
            samples: samples, duration: 1, peakDBFS: -6, deviceUID: "device"
        )))
        await awaitFinish(task)

        XCTAssertEqual(host.drainedTakes.count, 1, "the take was not drained for the quit")
        XCTAssertTrue(host.deliveries.isEmpty, "a quit pasted a transcript")
        XCTAssertEqual(host.finishEmptyCalls, 0)
        XCTAssertEqual(host.deletions, ["abandon"], "the quit left the card to finish itself")
        XCTAssertEqual(workingFrames(hud), 1)
    }

    /// A stop that lost the card to a newer owner cannot finish or hide it.
    func testAClaimedStopThatLostTheCardDoesNotAbandonTheNewOwner() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")

        let host = Host()
        defer { host.releaseAll() }
        host.calibrationGate.open()
        host.providerGate.open()
        let samples = speech(seconds: 1)
        let handoff = host.makeHandoff(hud: hud, ledger: TranscriptLedger(commitSeconds: 1), book: [:])
        let claim = Recorder.StopClaim(publishedSamples: samples.count)
        let task = host.perform(handoff, claim: claim)

        host.ownsCard = false
        hud.showMessage(text: "new owner", action: nil)
        claim.resolve(.drained(Recorder.Recording(
            samples: samples, duration: 1, peakDBFS: -6, deviceUID: "device"
        )))
        await awaitFinish(task)

        XCTAssertTrue(host.deliveries.isEmpty)
        XCTAssertTrue(host.deletions.isEmpty)
        XCTAssertEqual(host.calibrationCalls, 0, "a stop that lost the card learned from its audio")
        XCTAssertEqual(host.providerCalls, 0, "a stop that lost the card sent its audio")
        XCTAssertEqual(host.drainedTakes.count, 1, "the take was not drained for its own log line")
        XCTAssertTrue(isMessage(hud))
    }

    /// A normal stop leaves recording while the audio queue is still reconciling.
    ///
    /// The route change is held inside the engine's own restart, on the audio
    /// queue, which is the slowest thing the queue can be doing when Stop is
    /// pressed. The card, the menu and the app state must have left recording
    /// before that gate is dropped, and the drain that follows the reconcile
    /// must be the only one and must carry the take's own audio and device.
    func testANormalStopLeavesRecordingWhileTheAudioQueueIsReconciling() async throws {
        _ = NSApplication.shared
        let previousCache = MicrophoneCatalog.cache
        let catalog = CatalogCache(discovery: {
            CatalogCache.Snapshot(devices: [], defaultInputUID: nil)
        })
        MicrophoneCatalog.cache = catalog
        defer { MicrophoneCatalog.cache = previousCache }
        await waitUntil { catalog.snapshot().isLoaded }

        let engine = try StopEngine()
        engine.setDevice("device-a")
        let gate = DeliveryGate()
        let recorder = Recorder(environment: Recorder.Environment(
            makeEngine: { engine },
            isAuthorized: { true },
            deliver: { gate.deliver($0) }
        ))

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

        // A route change is being reconciled on the audio queue, and the engine
        // restart it needs is held there: the queue is busy for as long as a
        // device takes to come back.
        gate.hold()
        let restart = engine.blockNextStart()
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        XCTAssertEqual(
            restart.entered.wait(timeout: .now() + 5),
            .success,
            "the route change never reached the audio queue"
        )
        defer {
            restart.release.signal()
            gate.release()
        }
        let stopsBeforeDrain = engine.stopCount

        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")
        XCTAssertTrue(isRecording(hud))
        let host = Host()
        defer { host.releaseAll() }
        host.calibrationGate.open()
        host.providerGate.open()
        host.live = Task { @MainActor in await host.calibrationGate.wait() }
        let handoff = host.makeHandoff(
            hud: hud,
            ledger: TranscriptLedger(commitSeconds: 1),
            book: [:],
            providerText: "tail words"
        )

        // The route's replacement converter flushed the accepted tail before
        // its start was held, so the take now holds the whole accepted audio;
        // the claim publishes the samples that are in the take at Stop.
        let beforeClaim = recorder.sampleCount
        XCTAssertGreaterThanOrEqual(beforeClaim, published)
        let claimedAt = CACurrentMediaTime()
        let claim = try XCTUnwrap(recorder.claimStop())
        let task = StopResponse.perform(handoff, claim: claim)
        let claimedMilliseconds = (CACurrentMediaTime() - claimedAt) * 1000

        // Everything the person sees has left recording, and the queue is still
        // held: nothing below waited for the reconcile.
        XCTAssertLessThan(
            claimedMilliseconds,
            100,
            "the stop waited \(Int(claimedMilliseconds)) ms for the audio queue"
        )
        XCTAssertEqual(claim.publishedSamples, beforeClaim)
        XCTAssertTrue(isWorking(hud), "the card stayed on recording while the audio queue reconciled")
        XCTAssertEqual(workingFrames(hud), 1, "the stop showed transcribing more than once")
        XCTAssertFalse(host.menuRecording)
        XCTAssertEqual(host.state, "working")
        XCTAssertTrue(host.live?.isCancelled ?? false)
        XCTAssertEqual(recorder.state, .stopping)
        XCTAssertEqual(recorder.routeObserverCount, 0)
        XCTAssertTrue(host.drainedTakes.isEmpty, "the take was drained before the reconcile finished")
        XCTAssertTrue(host.deliveries.isEmpty)
        XCTAssertEqual(host.finishEmptyCalls, 0)
        XCTAssertNil(recorder.claimStop(), "a second stop claimed the take again")

        // Drop the gate: the reconcile finishes, the one drain runs behind it,
        // and both answers reach the main actor in the order the queue wrote
        // them.
        restart.release.signal()
        await gate.waitForHeld(2)
        gate.release()
        await awaitFinish(task)

        XCTAssertEqual(host.drainedTakes.count, 1, "the take was drained more than once")
        let drained = try XCTUnwrap(host.drainedTakes.first)
        XCTAssertEqual(
            Array(drained.samples.prefix(published)),
            expected,
            "the drain lost or reordered the audio that was already published"
        )
        XCTAssertEqual(drained.deviceUID, "device-a")
        XCTAssertFalse(drained.spannedDevices)
        XCTAssertEqual(
            engine.stopCount,
            stopsBeforeDrain + 1,
            "the engine was stopped more than once for a single stop"
        )
        XCTAssertTrue(deviceChanges.isEmpty, "a route answer from the stopped take was applied")
        XCTAssertEqual(host.deliveries.count, 1, "the stop delivered more than once")
        XCTAssertEqual(host.deliveries[0].text, "tail words")
        XCTAssertEqual(host.deliveries[0].source, .tail)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertNil(recorder.claimStop(), "a stop was claimed after the take had ended")
    }

    /// A quit before a zero-sample drain publishes nothing, not even a finish.
    ///
    /// The neutral card is not a claim about the take: when the quit takes the
    /// stop back, a late tail that arrives afterwards must not be shown as
    /// transcribing, delivered, or finished with the empty message.
    func testAQuitBeforeTheZeroSampleDrainNeitherTranscribesNorFinishes() async {
        _ = NSApplication.shared
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.showRecording(elapsed: "0:00")

        let host = Host()
        defer { host.releaseAll() }
        host.providerGate.open()
        let handoff = host.makeHandoff(hud: hud, ledger: TranscriptLedger(commitSeconds: 1), book: [:])
        let claim = Recorder.StopClaim(publishedSamples: 0)
        let task = host.perform(handoff, claim: claim)
        XCTAssertEqual(messageText(hud), "Finishing recording…")

        host.terminated = true
        claim.resolve(.drained(Recorder.Recording(
            samples: speech(seconds: 1), duration: 1, peakDBFS: -6
        )))
        await awaitFinish(task)

        XCTAssertEqual(workingFrames(hud), 0, "a quit showed the late tail as transcribing")
        XCTAssertTrue(host.deliveries.isEmpty, "a quit delivered the late tail")
        XCTAssertEqual(host.finishEmptyCalls, 0, "a quit finished the late tail as empty")
        XCTAssertEqual(host.deletions, ["abandon"])
        XCTAssertEqual(host.providerCalls, 0)
    }

    /// An engine the composition test can hold inside its own restart.
    private final class StopEngine: CaptureEngine, @unchecked Sendable {
        private let lock = NSLock()
        private let format: AVAudioFormat
        private var device: String?
        private var tap: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
        private var running = false
        private var stops = 0
        private var startGate: (entered: DispatchSemaphore, release: DispatchSemaphore)?
        private let notificationIdentity = NSObject()

        /// The object a real configuration notification names for this engine.
        var configurationIdentity: AnyObject? { notificationIdentity }

        /// Points the input at a device, the way a real open does before the
        /// format is read.
        func selectInputDevice(uid: String) throws {
            lock.lock()
            device = uid
            lock.unlock()
        }

        init() throws {
            format = try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 48_000,
                    channels: 1,
                    interleaved: false
                )
            )
        }

        /// Holds the next engine start, and reports when the audio queue
        /// entered it.
        func blockNextStart() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
            let gate = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
            lock.lock()
            startGate = gate
            lock.unlock()
            return gate
        }

        func setDevice(_ uid: String?) {
            lock.lock()
            device = uid
            lock.unlock()
        }

        var stopCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return stops
        }

        var installedTap: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return tap
        }

        func inputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat { format }

        func installTap(
            onBus bus: AVAudioNodeBus,
            bufferSize: AVAudioFrameCount,
            format: AVAudioFormat?,
            block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
        ) {
            lock.lock()
            tap = block
            lock.unlock()
        }

        func removeTap(onBus bus: AVAudioNodeBus) {
            lock.lock()
            tap = nil
            lock.unlock()
        }

        func prepare() {}

        func start() throws {
            lock.lock()
            let gate = startGate
            startGate = nil
            lock.unlock()
            gate?.entered.signal()
            _ = gate?.release.wait(timeout: .now() + 5)
            lock.lock()
            running = true
            lock.unlock()
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

        func currentDeviceUID() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return device
        }
    }

    /// Holds the recorder's answers to the main actor, the seam the app uses.
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

    /// Pushes one block of audio through the tap the recorder installed.
    private func feed(_ engine: StopEngine, frames: Int = 4_800) throws {
        let tap = try XCTUnwrap(engine.installedTap, "the recorder installed no tap")
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
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

    private func messageText(_ hud: HUD) -> String? {
        if case .message(let text, _) = hud.debugMode { return text }
        return nil
    }

    private func workingFrames(_ hud: HUD) -> Int {
        hud.debugModeHistory.filter { mode in
            if case .working = mode { return true }
            return false
        }.count
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "the condition never became true")
    }
}
